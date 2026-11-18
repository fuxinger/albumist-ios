"""Unit tests for .github/scripts/ui_evidence.py (which UI groups run, and the upload gate); the
GitHub API and git are faked.

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import json
import os
import re
import sys
import tempfile
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ui_evidence  # noqa: E402
import ui_groups  # noqa: E402
from test_ui_groups import DEVICE, FLOW, repo  # noqa: E402

# The fixtures belong to "owner/repo". On GitHub, GITHUB_REPOSITORY is the real repository, and
# setdefault kept it, so every run of another repository looked like a fork (CI 44229902956).
_REPOSITORY = {}


def setUpModule():
    _REPOSITORY["before"] = os.environ.get("GITHUB_REPOSITORY")
    os.environ["GITHUB_REPOSITORY"] = "owner/repo"


def tearDownModule():
    if _REPOSITORY.get("before") is None:
        os.environ.pop("GITHUB_REPOSITORY", None)
    else:
        os.environ["GITHUB_REPOSITORY"] = _REPOSITORY["before"]
os.environ.setdefault("GH_TOKEN", "unused")

HEAD = repo()
APP = ui_groups.app_fingerprint(HEAD)
FPS = ui_groups.Groups(HEAD).fingerprints()
NAMES = ["device", "full", "other", "small"]
TITLES = {"device": "device conditions", "full": "full flow", "other": "other flows", "small": "small iPhone"}
# A test-only commit after HEAD: a shorter wait in FlowUITests.swift (groups full, other, small).
TEST_ONLY = repo(**{"App__SortlyUITests__FlowUITests.swift": FLOW + "\n// waits 20 s, measured in run 1\n"})
TEST_ONLY_FPS = ui_groups.Groups(TEST_ONLY).fingerprints()
# The same app where the device group reads the quick switch (SORTLY_UI_QUICK, test02 skips).
QUICK_DEVICE = DEVICE.replace("func test02_Cold() {", 'func test02_Cold() {\n        if env["SORTLY_UI_QUICK"] == "1" { return }')
QUICK = repo(**{"App__SortlyUITests__DeviceUITests.swift": QUICK_DEVICE})
QUICK_FULL, QUICK_FAST = ui_groups.Groups(QUICK).fingerprints(), ui_groups.Groups(QUICK).fingerprints(quick=True)
NOW = datetime(2026, 11, 20, tzinfo=timezone.utc)
FAILED_LOG = "Test Case '-[SortlyUITests.DeviceUITests test01_Hot]' failed (3.0 seconds).\n"


def name(group, app=APP, tests=None, prefix=""):
    tests = tests or FPS[group]
    return f"{prefix}UI {TITLES[group]} [{group} app {app[:12]} tests {tests[:12]}]"


def job(group, conclusion="success", step="success", job_id=None, end="2026-11-19T12:00:00Z", **kw):
    steps = [{"name": "Set up job", "conclusion": "success"}, {"name": "Wait for the simulator", "conclusion": "success"},
             {"name": "Run UI tests", "conclusion": step, "started_at": "2026-11-19T11:00:00Z"}]
    if conclusion == "boot":
        conclusion = "failure"
        steps[1]["conclusion"], steps[2] = "failure", {"name": "Run UI tests", "conclusion": "skipped"}
    return {"id": job_id or hash((group, end, conclusion)) % 10**9, "name": name(group, **kw), "conclusion": conclusion,
            "started_at": "2026-11-19T11:00:00Z", "completed_at": end, "steps": steps, "run_attempt": 1,
            "html_url": f"https://example/job/{group}"}


def run(run_id, sha, jobs, event="workflow_dispatch", workflow="ui.yml", repo_name="owner/repo",
        created="2026-11-19T10:00:00Z", merge=None):
    """A run; a pull request run tests `merge` (its run-name ends "[merge <sha>]"), by default `sha`."""
    title = f"[merge {merge or sha}] A pull request" if event == "pull_request" and merge != "" else "A title"
    return ({"id": run_id, "run_number": run_id, "head_sha": sha, "event": event, "path": f".github/workflows/{workflow}",
             "created_at": created, "display_title": title, "status": "completed", "run_attempt": 1,
             "head_repository": {"full_name": repo_name}}, jobs)


class FakeVerifier:
    """sha -> (app, group fingerprints[, quick fingerprints]) as git would compute them."""

    def __init__(self, commits, changed=None):
        self.commits, self.changed = commits, changed or {}

    def app(self, sha):
        return self.commits.get(sha, (None, {}))[0]

    def matches(self, entry):
        app, *fps = self.commits.get(entry["sha"], (None, {}))
        keys = {f.get(entry["group"], "")[:12] for f in fps} - {""}
        return bool(app) and app[:12] == entry["app"] and entry["tests"] in keys

    def changed_since(self, sha):
        return self.changed.get(sha)

    def test_keys(self, sha):
        _, *fps = self.commits.get(sha, (None, {}))
        return {v[:12] for f in fps for v in f.values()}


VERIFIER = FakeVerifier({"a" * 40: (APP, FPS), "b" * 40: (APP, TEST_ONLY_FPS), "c" * 40: ("f" * 64, {}),
                         "q" * 40: (APP, QUICK_FULL, QUICK_FAST)})


def fake_api(runs, annotations=None, fail=False, per_page=None, logs=None):
    """The REST API over `runs`. logs: job id -> log text, or an exception to raise; a job not
    in it has a log with a failed test case."""
    calls = []

    def call(path, **params):
        calls.append(path)
        if fail:
            raise ui_evidence.ApiError("down")
        match = re.fullmatch(r"actions/workflows/(\S+)/runs", path)
        if match:
            low, high = params["created"].split("..")
            listed = [r for r, _ in runs if r["path"].endswith(match.group(1)) and low <= r["created_at"] <= high]
            listed.sort(key=lambda r: r["created_at"], reverse=True)
            size = per_page or params.get("per_page", 100)
            page = params.get("page", 1)
            return {"total_count": len(listed), "workflow_runs": listed[(page - 1) * size:page * size]}
        match = re.fullmatch(r"actions/jobs/(\d+)/logs", path)
        if match:
            text = (logs or {}).get(int(match.group(1)), FAILED_LOG)
            if isinstance(text, Exception):
                raise text
            return text
        match = re.fullmatch(r"actions/runs/(\d+)/jobs", path)
        if match:
            jobs = next(j for r, j in runs if r["id"] == int(match.group(1)))
            return {"total_count": len(jobs), "jobs": jobs}
        match = re.fullmatch(r"actions/runs/(\d+)", path)
        if match:
            return next(r for r, _ in runs if r["id"] == int(match.group(1)))
        if path.startswith("check-runs/"):
            return (annotations or {}).get(path, [])
        raise AssertionError(path)
    call.calls = calls
    return call


class ClassifyTests(unittest.TestCase):
    def test_results(self):
        self.assertEqual(ui_evidence.classify(job("device")), "green")
        self.assertEqual(ui_evidence.classify(job("device", "failure", "failure")), "red")
        # A timeout stops the running test step: red, like earlier_attempts.py.
        self.assertEqual(ui_evidence.classify(job("device", "failure", "cancelled")), "red")
        # Cancelled while the tests ran (a run cancelled by hand, a lost runner): red as well.
        self.assertEqual(ui_evidence.classify(job("device", "cancelled", "cancelled")), "red")
        self.assertEqual(ui_evidence.classify(job("device", "timed_out", "cancelled")), "red")
        # No test ran: a simulator that did not boot, a run cancelled before the step, a job that
        # still runs, or "No test result (...)" (ui_tests.py exit 75, step green).
        self.assertEqual(ui_evidence.classify(job("device", "boot")), "none")
        before = job("device", "cancelled", "cancelled")
        before["steps"][2] = {"name": "Run UI tests", "conclusion": "skipped"}
        self.assertEqual(ui_evidence.classify(before), "none")
        never = job("device", "cancelled")
        del never["steps"][2]
        self.assertEqual(ui_evidence.classify(never), "none")
        self.assertEqual(ui_evidence.classify(dict(job("device"), status="in_progress", conclusion=None)), "none")
        lost = job("device", "failure")
        lost["steps"].append({"name": "No test result (simulator or XCTest failed in every pass)", "conclusion": "failure"})
        self.assertEqual(ui_evidence.classify(lost), "none")

    def test_job_names_from_ui_yml_are_found(self):
        with open(os.path.join(ui_groups.ROOT, ".github", "workflows", "ui.yml"), encoding="utf-8") as f:
            workflow = f.read()
        template = re.search(r"\n    name: (UI \$\{\{ matrix.title \}\} .*)\n", workflow).group(1)
        rendered = (template.replace("${{ matrix.title }}", "device conditions").replace("${{ matrix.group }}", "device")
                    .replace("${{ matrix.app }}", "0123456789ab").replace("${{ matrix.tests }}", "ba9876543210"))
        for prefix in ("", "UI flow / "):  # on its own, and called by testflight.yml
            match = ui_evidence.JOB_NAME.search(prefix + rendered)
            self.assertEqual(match.groups(), ("device", "0123456789ab", "ba9876543210"))
        self.assertIsNone(ui_evidence.JOB_NAME.search("UI summary (retries and flaky tests)"))

    def test_carried_over_jobs_count_once(self):
        green = job("device", job_id=1)
        again = dict(green, id=2, run_attempt=2)
        self.assertEqual(len(ui_evidence.results([run(5, "a" * 40, [green, again])])), 1)


class DecideTests(unittest.TestCase):
    def decide(self, group, runs, fps=FPS):
        return ui_evidence.decide(group, APP, fps[group], ui_evidence.results(runs), VERIFIER)

    def test_green_from_another_run_is_evidence(self):
        d = self.decide("device", [run(1, "a" * 40, [job("device")])])
        self.assertEqual(d["state"], "green")
        self.assertEqual(d["evidence"]["run_id"], 1)

    def test_a_red_rerun_to_green_without_a_fix_stays_red(self):
        runs = [run(1, "a" * 40, [job("other", "failure", "failure", end="2026-11-19T10:00:00Z")]),
                run(2, "a" * 40, [job("other", end="2026-11-19T12:00:00Z")])]
        d = self.decide("other", runs)
        self.assertEqual(d["state"], "red")
        self.assertEqual([e["run_id"] for e in d["reds"]], [1])

    def test_a_fixed_test_has_a_new_key_and_its_old_red_is_only_listed(self):
        runs = [run(1, "a" * 40, [job("other", "failure", "failure")]),
                run(2, "b" * 40, [job("other", tests=TEST_ONLY_FPS["other"])])]
        d = self.decide("other", runs, TEST_ONLY_FPS)
        self.assertEqual(d["state"], "green")
        self.assertEqual([e["run_id"] for e in d["older_reds"]], [1])

    def test_greens_that_do_not_match_their_commit_or_other_apps_do_not_count(self):
        # The name claims this app, but git says commit c has another app.
        self.assertEqual(self.decide("device", [run(1, "c" * 40, [job("device")])])["state"], "missing")
        self.assertEqual(len(self.decide("device", [run(1, "c" * 40, [job("device")])])["unverified"]), 1)
        self.assertEqual(self.decide("device", [run(1, "a" * 40, [job("device", app="e" * 64)])])["state"], "missing")
        # No test ran: no result.
        self.assertEqual(self.decide("device", [run(1, "a" * 40, [job("device", "boot")])])["state"], "missing")


class HistoryTests(unittest.TestCase):
    def test_forks_and_other_apps_are_left_out_and_the_current_run_is_read(self):
        runs = [run(1, "a" * 40, [job("device")]),
                run(2, "c" * 40, [job("device")]),                      # another app: its jobs are not even read
                run(3, "d" * 40, [job("full")], event="pull_request", repo_name="fork/repo"),
                run(4, "e" * 40, [job("small")], event="pull_request", merge="a" * 40),  # tests merge commit a
                run(5, "e" * 40, [job("small")], event="pull_request", merge="c" * 40),  # merge with another app
                run(6, "e" * 40, [job("small")], event="pull_request", merge=""),        # older run: merge unknown
                run(7, "9" * 40, [job("small")]),                       # commit unknown to git (rebased away)
                run(8, "a" * 40, [job("full")], created="2026-11-17T23:00:00Z"),  # before any fingerprint
                run(9, "c" * 40, [job("other")], workflow="testflight.yml")]  # the current run: always
        call = fake_api(runs)
        history = ui_evidence.fetch_history(APP, 9, VERIFIER, call=call, now=NOW)
        self.assertEqual(sorted(r["id"] for r, _ in history), [1, 4, 6, 7, 9])
        self.assertNotIn("actions/runs/2/jobs", call.calls)
        self.assertNotIn("actions/runs/5/jobs", call.calls)
        # A pull request's results are those of the merge commit it tested.
        entries = ui_evidence.results(history)
        self.assertEqual({e["run_id"]: e["sha"] for e in entries}[4], "a" * 40)

    def test_every_page_and_every_range_is_read(self):
        runs = [run(i, "a" * 40, [job("device", job_id=i)], created=f"2026-11-19T{i:02d}:00:00Z") for i in range(1, 8)]
        call = fake_api(runs, per_page=3)
        history = ui_evidence.fetch_history(APP, None, VERIFIER, call=call, now=NOW)
        self.assertEqual(sorted(r["id"] for r, _ in history), list(range(1, 8)))
        self.assertEqual(call.calls.count("actions/workflows/ui.yml/runs"), 3)
        # More runs than the API lists for one filter: the range is split, nothing is left out.
        saved = ui_evidence.MAX_LISTED
        ui_evidence.MAX_LISTED = 2
        self.addCleanup(setattr, ui_evidence, "MAX_LISTED", saved)
        call = fake_api(runs, per_page=3)
        history = ui_evidence.fetch_history(APP, None, VERIFIER, call=call, now=NOW)
        self.assertEqual(sorted(r["id"] for r, _ in history), list(range(1, 8)))
        # Only within one second it cannot be split.
        same = [run(i, "a" * 40, [], created="2026-11-19T01:00:00Z") for i in range(1, 4)]
        with self.assertRaisesRegex(ui_evidence.CoverageError, "within one second"):
            ui_evidence.fetch_history(APP, None, VERIFIER, call=fake_api(same), now=NOW)

    def test_runs_with_only_older_test_code_are_read_while_calls_are_left(self):
        older = FakeVerifier(dict(VERIFIER.commits, **{"o" * 40: (APP, {g: "0" * 64 for g in NAMES})}))
        runs = [run(i, "o" * 40, [job("device", tests="0" * 64, job_id=i)], created=f"2026-11-19T0{i}:00:00Z")
                for i in range(1, 5)]
        runs.append(run(9, "a" * 40, [job("device", job_id=9)]))
        keys = ui_evidence.keys(ui_groups.Groups(HEAD))
        info = {}
        history = ui_evidence.fetch_history(APP, None, older, call=fake_api(runs), now=NOW, keys=keys, info=info)
        self.assertEqual(len(history), 5)
        self.assertEqual(info["older_skipped"], 0)
        saved = ui_evidence.MAX_CALLS
        ui_evidence.MAX_CALLS = ui_evidence.RESERVED_CALLS + 4  # two listings, run 9, one older run
        self.addCleanup(setattr, ui_evidence, "MAX_CALLS", saved)
        history = ui_evidence.fetch_history(APP, None, older, call=fake_api(runs), now=NOW, keys=keys, info=info)
        self.assertEqual(sorted(r["id"] for r, _ in history), [4, 9])
        self.assertEqual(info["older_skipped"], 3)

    def test_the_call_budget(self):
        runs = [run(i, "a" * 40, [job("device", job_id=i)]) for i in range(1, 6)]
        call = ui_evidence.counted(fake_api(runs), limit=3)
        with self.assertRaisesRegex(ui_evidence.CoverageError, "more than 3 API calls"):
            ui_evidence.fetch_history(APP, None, VERIFIER, call=call, now=NOW)


class RedFromTheLogTests(unittest.TestCase):
    """A job stopped in "Run UI tests" is red only when its log shows a test result."""

    def entries(self, logs, **changes):
        runs = [run(1, "a" * 40, [dict(job("device", "cancelled", "cancelled", job_id=11), **changes)])]
        return ui_evidence.results(runs, logs=ui_evidence.log_reader(fake_api(runs, logs=logs)))[0]["result"]

    def test_the_last_result_line_of_this_group_decides(self):
        stamp = "2026-11-19T02:01:06.8217400Z "
        self.assertEqual(self.entries({11: stamp + "UI_RESULT device fail\n"}), "red")
        self.assertEqual(self.entries({11: stamp + "UI_RESULT device infra\n" + FAILED_LOG}), "none")
        # Another group's line, a line that only quotes one, or an earlier line do not decide.
        self.assertEqual(self.entries({11: stamp + "UI_RESULT contrast fail\n"}), "none")
        self.assertEqual(self.entries({11: stamp + "echo UI_RESULT device fail\n"}), "none")
        self.assertEqual(self.entries({11: stamp + "UI_RESULT device fail\n" + stamp + "UI_RESULT device pass\n"}),
                         "none")
        # An assertion echoed while its test (continueAfterFailure) still ran, then a cancel: red.
        self.assertEqual(self.entries({11: stamp + "UI_LIVE /x.swift:3: error: -[SortlyUITests.DeviceUITests test01_Hot] : "
                                           "XCTAssertTrue failed\n" + stamp + "##[error]The operation was canceled.\n"}),
                         "red")
        # A failure echoed while the pass ran (UI_LIVE), then a cancel: red.
        self.assertEqual(self.entries({11: stamp + "UI_LIVE " + FAILED_LOG + stamp + "##[error]The operation was canceled.\n"}),
                         "red")

    def test_a_job_stopped_by_its_time_limit_is_red(self):
        cancelled = "##[error]The operation was canceled.\n"
        self.assertEqual(self.entries({11: cancelled}, started_at="2026-11-19T09:00:00Z",
                                      completed_at="2026-11-19T11:30:00Z"), "red")
        self.assertEqual(self.entries({11: cancelled}, started_at="2026-11-19T09:00:00Z",
                                      completed_at="2026-11-19T10:00:00Z"), "none")
        # Any conclusion but success after the full limit.
        self.assertEqual(self.entries({11: cancelled}, conclusion="failure", started_at="2026-11-19T09:00:00Z",
                                      completed_at="2026-11-19T11:30:00Z"), "red")

    def test_logs(self):
        self.assertEqual(self.entries({}), "red")  # a failed test case
        self.assertEqual(self.entries({11: "UI_VERDICT device first: fail (a test failed)\n"}), "red")
        self.assertEqual(self.entries({11: "UI_RESULT device fail\n"}), "red")
        # Cancelled while a test ran, no result in the log: no result.
        cancelled = "Test Case '-[SortlyUITests.DeviceUITests test01_Hot]' started.\n##[error]The operation was canceled.\n"
        self.assertEqual(self.entries({11: cancelled}), "none")
        # ui_tests.py's own result line decides: a testmanagerd crash in every pass shows a
        # failed test case but is no result.
        self.assertEqual(self.entries({11: FAILED_LOG + "UI_RESULT device infra\n"}), "none")
        self.assertEqual(self.entries({11: "UI_RESULT device fail\n"}), "red")
        # A log that cannot be read: red.
        self.assertEqual(self.entries({11: ui_evidence.ApiError("gone")}), "red")


class QuickTests(unittest.TestCase):
    """A quick run (pull requests) may take a full green; a full check never takes a quick one; a
    red in either mode blocks both."""

    def decide(self, runs, quick):
        groups = ui_groups.Groups(QUICK)
        return ui_evidence.decide_mode("device", APP, groups, ui_evidence.results(runs), VERIFIER, quick)

    def test_modes(self):
        quick_green = [run(1, "q" * 40, [job("device", tests=QUICK_FAST["device"])])]
        full_green = [run(2, "q" * 40, [job("device", tests=QUICK_FULL["device"])])]
        self.assertNotEqual(QUICK_FAST["device"], QUICK_FULL["device"])
        self.assertEqual(self.decide(quick_green, quick=True)["state"], "green")
        self.assertEqual(self.decide(quick_green, quick=False)["state"], "missing")
        self.assertEqual(self.decide(full_green, quick=True)["state"], "green")
        self.assertEqual(self.decide(full_green, quick=False)["state"], "green")
        quick_red = [run(3, "q" * 40, [job("device", "failure", "failure", tests=QUICK_FAST["device"])])]
        full_red = [run(4, "q" * 40, [job("device", "failure", "failure", tests=QUICK_FULL["device"])])]
        for red in (quick_red, full_red):
            for quick in (True, False):
                with self.subTest(red=red[0][0]["id"], quick=quick):
                    found = self.decide(red + quick_green + full_green, quick=quick)
                    self.assertEqual(found["state"], "red")
                    self.assertEqual(found["older_reds"], [])


class CommandTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.output, self.summary = os.path.join(folder.name, "out"), os.path.join(folder.name, "summary")
        saved = {k: os.environ.get(k) for k in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY")}
        os.environ.update(GITHUB_OUTPUT=self.output, GITHUB_STEP_SUMMARY=self.summary)
        self.addCleanup(lambda: [os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
                                 for k, v in saved.items()])

    def read(self, path):
        if not os.path.exists(path):
            return ""
        with open(path, encoding="utf-8") as f:
            return f.read()

    def outputs(self):
        return dict(line.split("=", 1) for line in self.read(self.output).splitlines())

    def plan(self, choice, runs, tree=TEST_ONLY, fail=False, verifier=VERIFIER, quick=False):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.plan(choice, call=fake_api(runs, fail=fail), verifier=verifier, tree=tree,
                                    quick=quick, now=NOW)
        return code, log.getvalue()

    def gate(self, runs, tree=TEST_ONLY, run_id=9, annotations=None, verifier=VERIFIER, quick=False):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(run_id, call=fake_api(runs, annotations), verifier=verifier, tree=tree,
                                    quick=quick, now=NOW)
        return code, log.getvalue()

    # Last night: a full UI run on commit a, then a test-only commit b (FlowUITests.swift).
    NIGHT = [run(1, "a" * 40, [job(g) for g in NAMES], event="pull_request")]

    def test_a_test_only_commit_runs_only_the_groups_of_the_changed_file(self):
        code, log = self.plan("auto", self.NIGHT)
        self.assertEqual(code, 0)
        matrix = json.loads(self.outputs()["matrix"])
        self.assertEqual([e["group"] for e in matrix["include"]], ["full", "other", "small"])
        self.assertEqual(self.outputs()["count"], "3")
        self.assertEqual(matrix["include"][0]["tests"], TEST_ONLY_FPS["full"][:12])
        self.assertIn("UI_PLAN reuse device: green in [run 1", log)
        self.assertIn("Not run again: device", self.read(self.summary))

    def test_plan_choices(self):
        self.assertEqual(self.plan("all", self.NIGHT)[0], 0)
        self.assertEqual(self.outputs()["count"], "4")
        os.remove(self.output)
        self.assertEqual(self.plan("small device", [])[0], 0)
        self.assertEqual([e["group"] for e in json.loads(self.outputs()["matrix"])["include"]], ["device", "small"])
        os.remove(self.output)
        self.assertEqual(self.plan("auto", self.NIGHT, tree=HEAD)[0], 0)
        self.assertEqual(self.outputs()["count"], "0")
        self.assertEqual([e["group"] for e in json.loads(self.outputs()["matrix"])["include"]], ["none"])
        for wrong in ("everything", "auto device"):
            with self.subTest(choice=wrong):
                self.assertEqual(self.plan(wrong, [])[0], 1)

    def test_plan_runs_everything_when_the_api_does_not_answer(self):
        code, log = self.plan("auto", self.NIGHT, fail=True)
        self.assertEqual(code, 0)
        self.assertEqual(self.outputs()["count"], "4")
        self.assertIn("every group runs", log)

    def test_gate_takes_this_run_and_reused_results(self):
        here = [job(g, tests=TEST_ONLY_FPS[g], job_id=100 + i) for i, g in enumerate(["full", "other", "small"])]
        runs = self.NIGHT + [run(9, "b" * 40, here, workflow="testflight.yml")]
        flaky = {"check-runs/%d/annotations" % self.NIGHT[0][1][0]["id"]:
                 [{"title": "UI device flaky", "message": "1 test(s) passed only on the repeat: test04"}]}
        code, log = self.gate(runs, annotations=flaky)
        self.assertEqual(code, 0, log)
        text = self.outputs()["text"]
        self.assertTrue(text.startswith("UI groups (full): device reused from run 1 (aaaaaaa); full here"), text)
        self.assertIn("::warning title=Flaky in a reused UI group::device (run 1)", log)
        self.assertIn("passed only on a repeat", self.read(self.summary))

    def test_gate_refuses_a_missing_group_and_a_rerun_red(self):
        code, log = self.gate([run(9, "b" * 40, [job("full", tests=TEST_ONLY_FPS["full"])], workflow="testflight.yml")])
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI device::no green full result", log)
        red_then_green = self.NIGHT + [
            run(8, "b" * 40, [job("other", "failure", "failure", tests=TEST_ONLY_FPS["other"], end="2026-11-19T13:00:00Z")]),
            run(9, "b" * 40, [job(g, tests=TEST_ONLY_FPS[g], end="2026-11-19T15:00:00Z") for g in ["full", "other", "small"]],
                workflow="testflight.yml")]
        code, log = self.gate(red_then_green)
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI other::red for this app and this test code", log)
        self.assertIn("**Not green** (no upload, no release)", self.read(self.summary))

    def test_history_that_cannot_be_read_runs_everything_and_fails_the_gate(self):
        saved = ui_evidence.MAX_CALLS
        ui_evidence.MAX_CALLS = 1
        self.addCleanup(setattr, ui_evidence, "MAX_CALLS", saved)
        code, log = self.plan("auto", self.NIGHT)
        self.assertEqual((code, self.outputs()["count"]), (0, "4"))
        self.assertIn("more than 1 API calls", log)
        os.remove(self.output)
        here = [job(g, tests=TEST_ONLY_FPS[g], job_id=100 + i) for i, g in enumerate(NAMES)]
        code, log = self.gate([run(9, "b" * 40, here, workflow="testflight.yml")])
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI gate::", log)

    def test_gate_full_does_not_take_quick_greens(self):
        quick = [run(9, "q" * 40, [job(g, tests=QUICK_FAST[g], job_id=200 + i) for i, g in enumerate(NAMES)])]
        self.assertEqual(self.gate(quick, tree=QUICK, quick=True)[0], 0)
        code, log = self.gate(quick, tree=QUICK)
        self.assertEqual(code, 1)
        # Every group: a quick fingerprint differs from the full one also where no file reads the switch.
        for g in NAMES:
            self.assertIn(f"::error title=UI {g}::no green full result", log)

    def test_a_red_cleared_only_by_a_shared_file_is_flagged(self):
        # Red for this app with older test code (another key); since then only the shared runner
        # changed (the fake verifier's diff), none of the device group's own test files.
        red = [run(1, "a" * 40, [job("device", "failure", "failure", tests="0" * 64, end="2026-11-19T10:00:00Z")])]
        verifier = FakeVerifier(VERIFIER.commits, changed={"a" * 40: [".github/scripts/ui_tests.py"]})
        here = [job(g, tests=TEST_ONLY_FPS[g], job_id=300 + i) for i, g in enumerate(NAMES)]
        code, log = self.gate(red + [run(9, "b" * 40, here, workflow="testflight.yml")], verifier=verifier)
        self.assertEqual(code, 0, log)
        self.assertIn("::warning title=UI red cleared by a shared change::device: red for this app in run 1", log)
        own = FakeVerifier(VERIFIER.commits, changed={"a" * 40: ["App/SortlyUITests/DeviceUITests.swift"]})
        self.assertNotIn("red cleared", self.gate(red + [run(9, "b" * 40, here, workflow="testflight.yml")],
                                                   verifier=own)[1])

    def test_gate_fails_closed_without_the_api(self):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(9, call=fake_api([], fail=True), verifier=VERIFIER, tree=TEST_ONLY, now=NOW)
        self.assertEqual(code, 1)
        self.assertIn("re-run this job", log.getvalue())


if __name__ == "__main__":
    unittest.main()
