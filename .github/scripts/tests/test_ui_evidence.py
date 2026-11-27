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
from unittest import mock
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
# A test-only commit after HEAD: a longer wait in FlowUITests.swift (groups full, other, small).
TEST_ONLY = repo(**{"App__AlbumistUITests__FlowUITests.swift":
                    FLOW.replace("func test2_Other() throws {}", "func test2_Other() throws { sleep(20) }")})
TEST_ONLY_FPS = ui_groups.Groups(TEST_ONLY).fingerprints()
# A commit after HEAD that only changes comments and indentation in the same file: not a fix.
COMMENT_ONLY = repo(**{"App__AlbumistUITests__FlowUITests.swift":
                       FLOW.replace("    func test2_Other", "    // waits 20 s, measured in run 1\n  func test2_Other")})
COMMENT_ONLY_FPS = ui_groups.Groups(COMMENT_ONLY).fingerprints()
# The same app where the device group reads the quick switch (ALBUMIST_UI_QUICK, test02 skips).
QUICK_DEVICE = DEVICE.replace("func test02_Cold() {", 'func test02_Cold() {\n        if env["ALBUMIST_UI_QUICK"] == "1" { return }')
QUICK = repo(**{"App__AlbumistUITests__DeviceUITests.swift": QUICK_DEVICE})
QUICK_FULL, QUICK_FAST = ui_groups.Groups(QUICK).fingerprints(), ui_groups.Groups(QUICK).fingerprints(quick=True)
NOW = datetime(2026, 11, 20, tzinfo=timezone.utc)
FAILED_LOG = "Test Case '-[AlbumistUITests.DeviceUITests test01_Hot]' failed (3.0 seconds).\n"


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
                         "k" * 40: (APP, COMMENT_ONLY_FPS),
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

    def test_a_comment_change_is_no_fix_and_the_red_stays(self):
        # Prüfer B G5-04: a red (flaky) test must not get out of its lock by a comment edit in its
        # test file and one green run. The comment commit has the same key, so its green does not count.
        self.assertEqual(COMMENT_ONLY_FPS, FPS)
        runs = [run(1, "a" * 40, [job("other", "failure", "failure", end="2026-11-19T10:00:00Z")]),
                run(2, "k" * 40, [job("other", tests=COMMENT_ONLY_FPS["other"], end="2026-11-19T12:00:00Z")])]
        d = self.decide("other", runs, COMMENT_ONLY_FPS)
        self.assertEqual(d["state"], "red")
        self.assertEqual([e["run_id"] for e in d["reds"]], [1])
        self.assertEqual(d["older_reds"], [])

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
        # Three listings (ui.yml, testflight.yml, ui-stress.yml), run 9, one older run.
        ui_evidence.MAX_CALLS = ui_evidence.RESERVED_CALLS + 5
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
        self.assertEqual(self.entries({11: stamp + "UI_LIVE /x.swift:3: error: -[AlbumistUITests.DeviceUITests test01_Hot] : "
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
        cancelled = "Test Case '-[AlbumistUITests.DeviceUITests test01_Hot]' started.\n##[error]The operation was canceled.\n"
        self.assertEqual(self.entries({11: cancelled}), "none")
        # ui_tests.py's own result line decides: a testmanagerd crash in every pass shows a
        # failed test case but is no result.
        self.assertEqual(self.entries({11: FAILED_LOG + "UI_RESULT device infra\n"}), "none")
        self.assertEqual(self.entries({11: "UI_RESULT device fail\n"}), "red")
        # A log GitHub no longer has (HTTP 404 or 410): red, as its result cannot be checked.
        self.assertEqual(self.entries({11: ui_evidence.LogGone("HTTP Error 410: Gone")}), "red")

    def test_a_log_the_api_did_not_answer_for_is_no_verdict(self):
        # Review P5-08 (d): a log read that failed three times (HTTP 502, a timeout) made a job
        # that was cancelled with nothing failed red, and the gate said "red for this app and this
        # test code ... fix it" though no test had failed and the next call would have read it.
        with self.assertRaises(ui_evidence.ApiError):
            self.entries({11: ui_evidence.ApiError("GitHub API: actions/jobs/11/logs: HTTP Error 502: Bad Gateway")})
        # The same for a job that failed in "Run UI tests": its log tells a test result from a
        # runner that crashed before the tests.
        runs = [run(1, "a" * 40, [job("device", "failure", "failure", job_id=11)])]
        call = fake_api(runs, logs={11: ui_evidence.ApiError("HTTP Error 502: Bad Gateway")})
        with self.assertRaises(ui_evidence.ApiError):
            ui_evidence.results(runs, logs=ui_evidence.log_reader(call))

    def test_the_api_tells_a_gone_log_from_no_answer(self):
        import urllib.error
        from unittest import mock

        def answer(code):
            def urlopen(request, timeout):
                raise urllib.error.HTTPError(request.full_url, code, "x", {}, None)
            return urlopen
        with mock.patch.object(ui_evidence.urllib.request, "urlopen", answer(410)), \
                mock.patch.object(ui_evidence.time, "sleep", lambda s: None):
            with self.assertRaises(ui_evidence.LogGone):
                ui_evidence.api("actions/jobs/11/logs")
            # Not a log: gone, but no LogGone.
            with self.assertRaises(ui_evidence.ApiError) as raised:
                ui_evidence.api("actions/runs/11")
            self.assertNotIsInstance(raised.exception, ui_evidence.LogGone)
        with mock.patch.object(ui_evidence.urllib.request, "urlopen", answer(502)), \
                mock.patch.object(ui_evidence.time, "sleep", lambda s: None):
            with self.assertRaises(ui_evidence.ApiError) as raised:
                ui_evidence.api("actions/jobs/11/logs")
            self.assertNotIsInstance(raised.exception, ui_evidence.LogGone)

    def test_a_red_from_a_gone_log_says_so(self):
        runs = [run(1, "a" * 40, [dict(job("device", "cancelled", "cancelled", job_id=11))])]
        entry = ui_evidence.results(runs, logs=ui_evidence.log_reader(fake_api(runs, logs={11: ui_evidence.LogGone("410")})))[0]
        self.assertEqual((entry["result"], entry["log"]), ("red", "gone"))
        self.assertIn("log gone", ui_evidence.where(entry))

    def test_a_late_log_is_asked_for_again(self):
        """Run 45938312628: the log of a job cancelled two minutes before was not there yet."""
        now = ui_evidence.datetime.now(ui_evidence.timezone.utc)
        ended = (now - ui_evidence.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        started = (now - ui_evidence.timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
        runs = [run(1, "a" * 40, [dict(job("device", "cancelled", "cancelled", job_id=11), started_at=started, completed_at=ended)])]
        ui_evidence.late_tries_left[0] = ui_evidence.LOG_LATE_TRIES
        answers = [None, None, "UI_PASS device first\nThe operation was canceled.\n"]
        waits = []
        with mock.patch.object(ui_evidence.time, "sleep", waits.append):
            entry = ui_evidence.results(runs, logs=lambda job_id: answers.pop(0))[0]
        self.assertEqual((entry["result"], entry["log"]), ("none", ""))
        self.assertEqual(waits, [ui_evidence.LOG_LATE_WAIT] * 2)

    def test_an_old_missing_log_is_not_waited_for_and_stays_red(self):
        runs = [run(1, "a" * 40, [dict(job("device", "cancelled", "cancelled", job_id=11), started_at="2026-11-20T02:30:00Z",
                                        completed_at="2026-11-20T03:00:00Z")])]
        with mock.patch.object(ui_evidence.time, "sleep", lambda s: self.fail("waited for an old log")):
            entry = ui_evidence.results(runs, logs=lambda job_id: None)[0]
        self.assertEqual((entry["result"], entry["log"]), ("red", "gone"))

    def test_a_log_still_missing_after_the_waits_stays_red(self):
        now = ui_evidence.datetime.now(ui_evidence.timezone.utc)
        ended = (now - ui_evidence.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        started = (now - ui_evidence.timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ")
        runs = [run(1, "a" * 40, [dict(job("device", "cancelled", "cancelled", job_id=11), started_at=started, completed_at=ended)])]
        ui_evidence.late_tries_left[0] = ui_evidence.LOG_LATE_TRIES
        waits = []
        with mock.patch.object(ui_evidence.time, "sleep", waits.append):
            entry = ui_evidence.results(runs, logs=lambda job_id: None)[0]
            # The tries are spent: a second late job is not waited for.
            again = ui_evidence.results(runs, logs=lambda job_id: None)[0]
        self.assertEqual(again["result"], "red")
        self.assertEqual((entry["result"], entry["log"]), ("red", "gone"))
        self.assertEqual(len(waits), ui_evidence.LOG_LATE_TRIES)

    def test_only_an_approved_job_without_a_log_is_no_result(self):
        """Coordinator 27.11.: device job 140302168847 of run 45936196002, cancelled by a newer
        push, GitHub never stored its log. Listed, it counts as no result (never green); any other
        job without a log stays red."""
        self.assertIn(140302168847, ui_evidence.approved_unreadable())
        listed = [run(1, "a" * 40, [dict(job("device", "cancelled", "cancelled", job_id=140302168847))])]
        other = [run(2, "a" * 40, [dict(job("device", "cancelled", "cancelled", job_id=140302168848))])]
        with mock.patch.object(ui_evidence.time, "sleep", lambda s: None):
            entry = ui_evidence.results(listed, logs=lambda job_id: None)[0]
            self.assertEqual((entry["result"], entry["log"]), ("none", "gone, approved as no result"))
            self.assertEqual(ui_evidence.results(other, logs=lambda job_id: None)[0]["result"], "red")
            # A listed job whose log is there is read as any other.
            red_log = "UI_RESULT device fail\n"
            self.assertEqual(ui_evidence.results(listed, logs=lambda job_id: red_log)[0]["result"], "red")

    def test_every_approved_entry_says_why_and_who(self):
        with open(ui_evidence.UNREADABLE_FILE, encoding="utf-8") as file:
            jobs = json.load(file)["jobs"]
        for job_id, entry in jobs.items():
            self.assertTrue(job_id.isdigit(), job_id)
            for key in ("group", "run", "why", "approved"):
                self.assertTrue(entry.get(key), f"{job_id}: {key} missing")


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

    def test_plan_names_the_groups_already_red_for_this_key(self):
        # Tempo plan 20.11. (8b71209): a group red for this app and test code makes the verdict
        # red whatever this run shows; the plan says so at once for ui.yml's "UI known red".
        red = self.NIGHT + [run(8, "b" * 40, [job("other", "failure", "failure", tests=TEST_ONLY_FPS["other"],
                                                    end="2026-11-19T13:00:00Z")])]
        code, log = self.plan("auto", red)
        self.assertEqual(code, 0)
        self.assertEqual(self.outputs()["known_red"], "other")
        self.assertTrue(self.outputs()["known_red_text"].startswith("other red in "), self.outputs())
        # The red group still runs (its result is shown, its green does not count).
        self.assertIn("other", [e["group"] for e in json.loads(self.outputs()["matrix"])["include"]])
        os.remove(self.output)
        self.plan("auto", self.NIGHT)
        self.assertEqual(self.outputs()["known_red"], "")
        os.remove(self.output)
        # No reading of earlier results (a choice by name, or the API down): nothing is known.
        self.plan("all", red)
        self.assertEqual(self.outputs()["known_red"], "")
        os.remove(self.output)
        self.plan("auto", red, fail=True)
        self.assertEqual(self.outputs()["known_red"], "")

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

    def test_a_draft_runs_only_the_smoke_test(self):
        # Stage 1 (26.11.2026): a draft pull request runs the two smoke tests, quick, one Mac,
        # and reads no earlier result.
        smoke = repo(**{"App__AlbumistUITests__AlbumistFlowUITests.swift":
                        "import XCTest\nfinal class AlbumistFlowUITests: XCTestCase {\n"
                        "    func test1_FullFlow() throws {}\n    func test1c_UndoFromHistory() throws {}\n}\n"})
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.plan("auto", call=fake_api([], fail=True), verifier=VERIFIER, tree=smoke, smoke=True)
        self.assertEqual(code, 0, log.getvalue())
        matrix = json.loads(self.outputs()["matrix"])
        self.assertEqual(len(matrix["include"]), 1)
        entry = matrix["include"][0]
        self.assertEqual((entry["group"], entry["quick"], entry["device"]), ("smoke", True, "pro"))
        self.assertEqual(entry["only"], "AlbumistFlowUITests/test1_FullFlow AlbumistFlowUITests/test1c_UndoFromHistory")
        self.assertEqual(entry["app"], ui_groups.app_fingerprint(smoke)[:12])
        # Its own test key, never a group's: its result is no evidence for a group.
        smoke_fp = ui_groups.Groups(smoke).smoke_fingerprint()
        self.assertEqual(entry["tests"], smoke_fp[:12])
        self.assertNotIn(smoke_fp[:12], [fp[:12] for q in (False, True)
                                         for fp in ui_groups.Groups(smoke).fingerprints(q).values()])
        self.assertEqual((self.outputs()["count"], self.outputs()["known_red"]), ("1", ""))
        self.assertIn("ready for review", self.read(self.summary))
        smoke_job = job("device", tests=smoke_fp)
        smoke_job["name"] = f"UI smoke test, full flow and undo (quick) [smoke app {APP[:12]} tests {smoke_fp[:12]}]"
        entries = ui_evidence.results([run(5, "a" * 40, [smoke_job])])
        self.assertEqual([e["group"] for e in entries], ["smoke"])
        for quick in (True, False):
            found = ui_evidence.decide_mode("device", APP, ui_groups.Groups(HEAD), entries, VERIFIER, quick)
            self.assertEqual(found["state"], "missing")

    def test_a_red_smoke_test_blocks_the_verdicts_of_this_content(self):
        # Second review 26.11.: marking a draft ready must not re-run a red smoke test to green.
        groups = ui_groups.Groups(TEST_ONLY)
        key = groups.smoke_fingerprint()
        red_job = job("device", "failure", "failure", tests=key, end="2026-11-19T13:00:00Z")
        red_job["name"] = f"UI smoke test, full flow and undo (quick) [smoke app {APP[:12]} tests {key[:12]}]"
        green_here = [job(g, tests=TEST_ONLY_FPS[g], job_id=200 + i) for i, g in enumerate(NAMES)]
        runs = [run(8, "b" * 40, [red_job], event="pull_request"), run(9, "b" * 40, green_here)]
        self.assertEqual(self.gate(runs)[0], 1)
        self.assertIn("smoke", self.read(self.summary))
        # The plan says so at once ("UI known red").
        code, _ = self.plan("auto", runs)
        self.assertEqual((code, self.outputs()["known_red"]), (0, "smoke"))
        # A green smoke test changes nothing: the groups decide.
        os.remove(self.output)
        green_smoke = dict(red_job, conclusion="success", steps=job("device")["steps"])
        self.assertEqual(self.gate([run(8, "b" * 40, [green_smoke], event="pull_request"), run(9, "b" * 40, green_here)])[0], 0)
        # Changed smoke test code (another key) no longer blocks.
        other = dict(red_job, name=red_job["name"].replace(key[:12], "f" * 12))
        self.assertEqual(self.gate([run(8, "b" * 40, [other], event="pull_request"), run(9, "b" * 40, green_here)])[0], 0)

    def test_the_fast_gate_checks_only_the_smoke_test(self):
        # testflight.yml gate fast (26.11.2026): the smoke test of this app and smoke test code
        # green, from this run; no group and no stress pass needed; a red one blocks.
        groups = ui_groups.Groups(TEST_ONLY)
        key = groups.smoke_fingerprint()[:12]
        smoke_job = job("device", tests=key, job_id=300)
        smoke_job["name"] = f"UI flow / UI smoke test, full flow and undo (quick) [smoke app {APP[:12]} tests {key}]"

        verifier = FakeVerifier(dict(VERIFIER.commits, **{"b" * 40: (APP, TEST_ONLY_FPS, {"smoke": key})}))

        def smoke_gate(runs):
            with contextlib.redirect_stdout(io.StringIO()) as log:
                code = ui_evidence.gate(9, call=fake_api(runs), verifier=verifier, tree=TEST_ONLY, now=NOW,
                                        smoke_only=True)
            return code, log.getvalue()

        self.assertEqual(smoke_gate([run(9, "b" * 40, [smoke_job], workflow="testflight.yml")])[0], 0)
        self.assertIn("smoke test only (fast gate)", self.read(self.summary))
        # Without a smoke result (the groups alone are no smoke test) it is not green.
        groups_only = [run(9, "b" * 40, [job(g, tests=TEST_ONLY_FPS[g], job_id=310 + i) for i, g in enumerate(NAMES)],
                           workflow="testflight.yml")]
        self.assertEqual(smoke_gate(groups_only)[0], 1)
        red = dict(smoke_job, id=301, conclusion="failure", completed_at="2026-11-19T13:00:00Z",
                   steps=job("device", "failure", "failure")["steps"])
        self.assertEqual(smoke_gate([run(8, "b" * 40, [red], event="pull_request"),
                                     run(9, "b" * 40, [smoke_job], workflow="testflight.yml")])[0], 1)
        # Never mixed with groups or a stress pass.
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ui_evidence.main(["gate", "--smoke-only", "--stress", "10000-15"]), 1)

    def test_a_smoke_test_that_was_renamed_stops_the_plan(self):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.plan("auto", tree=HEAD, smoke=True)
        self.assertEqual(code, 1)
        self.assertIn("AlbumistFlowUITests/test1_FullFlow", log.getvalue())

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

    def test_a_skipped_or_missing_group_is_never_green(self):
        # G5-08 (review of 18.11.2026): a group job that GitHub skipped, a job whose "Run UI tests"
        # step was skipped, and a group without any job are never green: the gate blocks and the
        # plan runs them. (A group whose tests all skipped themselves fails in ui_tests.py.)
        here = [job(g, tests=TEST_ONLY_FPS[g], job_id=500 + i) for i, g in enumerate(["full", "other"])]
        skipped = dict(job("small", tests=TEST_ONLY_FPS["small"], job_id=510), conclusion="skipped", steps=[])
        step_skipped = job("device", tests=TEST_ONLY_FPS["device"], job_id=511)
        step_skipped["steps"][2] = {"name": "Run UI tests", "conclusion": "skipped"}
        runs = [run(9, "b" * 40, here + [skipped, step_skipped], workflow="testflight.yml")]
        code, log = self.gate(runs)
        self.assertEqual(code, 1)
        for g in ("device", "small"):
            self.assertIn(f"::error title=UI {g}::no green full result", log)
        self.assertIn("device missing; full here; other here; small missing", self.outputs()["text"])
        os.remove(self.output)
        self.assertEqual(self.gate([run(9, "b" * 40, here, workflow="testflight.yml")])[0], 1)
        os.remove(self.output)
        self.plan("auto", runs)
        self.assertEqual([e["group"] for e in json.loads(self.outputs()["matrix"])["include"]], ["device", "small"])

    def gate_only(self, runs, only):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(9, call=fake_api(runs), verifier=VERIFIER, tree=TEST_ONLY, now=NOW, only=only)
        return code, log.getvalue()

    def test_the_small_gate_checks_its_groups_by_the_same_rules_and_names_the_others(self):
        # The daily build (testflight.yml, gate small; decision 10 of 18.11.2026): only the named
        # groups must be green for this app and their test code, and a red of theirs still blocks.
        here = [job("full", tests=TEST_ONLY_FPS["full"], job_id=400)]
        code, log = self.gate_only([run(9, "b" * 40, here, workflow="testflight.yml")], "full")
        self.assertEqual(code, 0, log)
        self.assertEqual(self.outputs()["text"], "UI groups (full, only full): full here; not checked: device other small")
        self.assertIn("(full, only full): green", self.read(self.summary))
        self.assertIn("Not checked by this gate: device, other, small.", self.read(self.summary))
        os.remove(self.output)
        red_other = [run(8, "b" * 40, [job("other", "failure", "failure", tests=TEST_ONLY_FPS["other"], job_id=401)]),
                     run(9, "b" * 40, here, workflow="testflight.yml")]
        self.assertEqual(self.gate_only(red_other, "full")[0], 0)
        code, log = self.gate_only(red_other, "full other")
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI other::red for this app and this test code", log)
        code, log = self.gate_only(red_other, "full flow")
        self.assertEqual(code, 1)
        self.assertIn("unknown group(s) flow", log)
        # Without --groups every group counts, as before.
        self.assertEqual(self.gate([run(9, "b" * 40, here, workflow="testflight.yml")])[0], 1)

    def test_a_pull_request_leaves_out_the_groups_that_run_only_before_uploads(self):
        # 27.11. (speed first): large-library has "pull_requests": false. Here "small" plays it.
        from unittest import mock
        with mock.patch.object(ui_groups.Groups, "on_pull_requests", lambda self, name: name != "small"):
            with contextlib.redirect_stdout(io.StringIO()) as log:
                code = ui_evidence.plan("auto", call=fake_api(self.NIGHT), verifier=VERIFIER, tree=TEST_ONLY, now=NOW, pr=True)
            self.assertEqual(code, 0, log.getvalue())
            self.assertEqual([e["group"] for e in json.loads(self.outputs()["matrix"])["include"]], ["full", "other"])
            self.assertIn("UI_PLAN not in a pull request's run: small", log.getvalue())
            self.assertIn("Not in a pull request's run: small", self.read(self.summary))
            # Also "all" and a choice by name leave it out of a pull request's run.
            for choice in ("all", "small full"):
                os.remove(self.output)
                with contextlib.redirect_stdout(io.StringIO()):
                    ui_evidence.plan(choice, call=fake_api([]), verifier=VERIFIER, tree=TEST_ONLY, now=NOW, pr=True)
                self.assertNotIn("small", [e["group"] for e in json.loads(self.outputs()["matrix"])["include"]], choice)
            # Without --pr (TestFlight, the night, by hand) it runs as every group.
            os.remove(self.output)
            self.plan("auto", self.NIGHT)
            self.assertIn("small", [e["group"] for e in json.loads(self.outputs()["matrix"])["include"]])
            # The verdict of a pull request does not check it; every other gate does.
            here = [job(g, tests=TEST_ONLY_FPS[g], job_id=600 + i) for i, g in enumerate(["full", "other"])]
            runs = self.NIGHT + [run(9, "b" * 40, here)]
            os.remove(self.output)
            with contextlib.redirect_stdout(io.StringIO()) as log:
                code = ui_evidence.gate(9, call=fake_api(runs), verifier=VERIFIER, tree=TEST_ONLY, now=NOW, pr=True)
            self.assertEqual(code, 0, log.getvalue())
            self.assertIn("not checked: small", self.outputs()["text"])
            os.remove(self.output)
            code, log = self.gate(runs)
            self.assertEqual(code, 1)
            self.assertIn("::error title=UI small::no green full result", log)
            # A red of it still blocks every gate that checks it (the pull request's does not).
            red = runs + [run(10, "b" * 40, [job("small", "failure", "failure", tests=TEST_ONLY_FPS["small"], job_id=620)])]
            os.remove(self.output)
            self.assertEqual(self.gate(red)[0], 1)

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
        own = FakeVerifier(VERIFIER.commits, changed={"a" * 40: ["App/AlbumistUITests/DeviceUITests.swift"]})
        self.assertNotIn("red cleared", self.gate(red + [run(9, "b" * 40, here, workflow="testflight.yml")],
                                                   verifier=own)[1])

    def test_the_gate_names_why_a_red_has_no_log(self):
        # Review P5-08 (d): a red from a log GitHub deleted stays until the app or the test
        # changes; the gate says that this is the reason, not a failed test it could show.
        cancelled = [run(1, "b" * 40, [job("device", "cancelled", "cancelled", tests=TEST_ONLY_FPS["device"], job_id=77)])]
        here = [job(g, tests=TEST_ONLY_FPS[g], job_id=100 + i) for i, g in enumerate(NAMES)]
        runs = cancelled + [run(9, "b" * 40, here, workflow="testflight.yml")]
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(9, call=fake_api(runs, logs={77: ui_evidence.LogGone("HTTP Error 410: Gone")}),
                                    verifier=VERIFIER, tree=TEST_ONLY, now=NOW)
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI device::red for this app and this test code", log.getvalue())
        self.assertIn("its log is gone", log.getvalue())
        self.assertIn("log gone", self.read(self.summary))
        # The API did not answer for the log: no verdict, and the gate says to run it again.
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(9, call=fake_api(runs, logs={77: ui_evidence.ApiError("HTTP Error 502")}),
                                    verifier=VERIFIER, tree=TEST_ONLY, now=NOW)
        self.assertEqual(code, 1)
        self.assertNotIn("::error title=UI device::red", log.getvalue())
        self.assertIn("re-run this job when the API answers", log.getvalue())

    def test_the_call_budget_is_named_as_the_reason(self):
        # Review P5-08 (d): beyond MAX_CALLS the gate has no verdict, and "re-run this job when
        # the API answers" sent the reader to a re-run that ends the same way.
        saved = ui_evidence.MAX_CALLS
        ui_evidence.MAX_CALLS = 1
        self.addCleanup(setattr, ui_evidence, "MAX_CALLS", saved)
        here = [job(g, tests=TEST_ONLY_FPS[g], job_id=100 + i) for i, g in enumerate(NAMES)]
        code, log = self.gate([run(9, "b" * 40, here, workflow="testflight.yml")])
        self.assertEqual(code, 1)
        self.assertNotIn("re-run this job when the API answers", log)
        self.assertIn("MAX_CALLS", log)
        self.assertIn("a re-run ends the same way", log)

    def test_gate_fails_closed_without_the_api(self):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(9, call=fake_api([], fail=True), verifier=VERIFIER, tree=TEST_ONLY, now=NOW)
        self.assertEqual(code, 1)
        self.assertIn("re-run this job", log.getvalue())


class MergeContentTests(unittest.TestCase):
    """The full pass before the merge (decision 20.11.2026): its greens stand for the merge only
    when merging into main keeps the app fingerprint and every group's full test fingerprint."""

    def test_differences(self):
        self.assertEqual(ui_evidence.content_differences(HEAD, HEAD), [])
        docs = repo(**{"docs__NOTES.md": "# notes"})
        self.assertEqual(ui_evidence.content_differences(HEAD, docs), [])
        # The fixture lists the stress test in no group by name, so its key follows every group's.
        self.assertEqual(ui_evidence.content_differences(HEAD, TEST_ONLY),
                         [f"the test code of {g}" for g in ("full", "other", "small")] + ["the stress pass's test code"])
        app = repo(**{"App__Albumist__App__AlbumistApp.swift": "@main struct AlbumistApp { let x = 1 }"})
        self.assertEqual(ui_evidence.content_differences(HEAD, app)[0], "the app")

    def git(self, folder, *args):
        import subprocess
        done = subprocess.run(["git", *args], cwd=folder, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def commit(self, folder, files, message):
        for path, text in files.items():
            os.makedirs(os.path.join(folder, os.path.dirname(path)), exist_ok=True)
            with open(os.path.join(folder, path), "w", encoding="utf-8") as f:
                f.write(text)
        self.git(folder, "add", "-A")
        self.git(folder, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message)

    def test_merge_into_a_main_that_moved(self):
        with tempfile.TemporaryDirectory() as folder:
            self.git(folder, "init", "-q", "-b", "main")
            self.commit(folder, HEAD.contents, "base")
            self.git(folder, "checkout", "-q", "-b", "branch")
            self.commit(folder, {"App/Albumist/App/Feature.swift": "struct Feature {}"}, "branch work")
            self.git(folder, "checkout", "-q", "main")
            self.commit(folder, {"docs/NOTES.md": "# notes"}, "docs on main")
            self.git(folder, "checkout", "-q", "branch")
            with contextlib.redirect_stdout(io.StringIO()) as log:
                self.assertEqual(ui_evidence.merge_content("main", cwd=folder), 0)
            self.assertIn("UI_MERGE_CONTENT same app and test fingerprints", log.getvalue())
            # main changes the app: the branch's greens no longer stand for the merge.
            self.git(folder, "checkout", "-q", "main")
            self.commit(folder, {"Sources/AlbumistCore/Core.swift": "public struct Core { let y = 2 }"}, "app on main")
            self.git(folder, "checkout", "-q", "branch")
            with contextlib.redirect_stdout(io.StringIO()) as log:
                self.assertEqual(ui_evidence.merge_content("main", cwd=folder), 1)
            self.assertIn("::error title=UI merge content::merging into main changes the app", log.getvalue())
            # A conflict is no merge content at all.
            self.commit(folder, {"Sources/AlbumistCore/Core.swift": "public struct Core { let z = 3 }"}, "conflict")
            with contextlib.redirect_stdout(io.StringIO()) as log:
                self.assertEqual(ui_evidence.merge_content("main", cwd=folder), 1)
            self.assertIn("does not merge cleanly", log.getvalue())


STRESS = ui_evidence.stress_keys(ui_groups.Groups(HEAD))
STRESS_VERIFIER = FakeVerifier(dict(VERIFIER.commits, **{"s" * 40: (APP, {**FPS, **STRESS})}))


def stress_job(conclusion="success", step="success", job_id=700, tests=None, end="2026-11-19T12:00:00Z"):
    tests = tests or STRESS["stress-10000-15"]
    return {"id": job_id, "name": f"Stress pass / UI stress 10000 photos [stress-10000-15 app {APP[:12]} tests {tests[:12]}]",
            "conclusion": conclusion, "started_at": "2026-11-19T11:00:00Z", "completed_at": end, "run_attempt": 1,
            "steps": [{"name": "Set up job", "conclusion": "success"},
                      {"name": "Stress run", "conclusion": step, "started_at": "2026-11-19T11:05:00Z"}],
            "html_url": "https://example/job/stress"}


class StressEvidenceTests(unittest.TestCase):
    """The owner's decision of 20.11.2026, 17:20: the stress pass runs once before the merge, and
    TestFlight takes its green by content (app fingerprint and stress test fingerprint)."""

    setUp, read, outputs = CommandTests.setUp, CommandTests.read, CommandTests.outputs

    def test_the_key(self):
        groups = ui_groups.Groups(HEAD)
        small, full = STRESS["stress-10000-15"], STRESS["stress-50000-45"]
        self.assertNotEqual(small, full)
        self.assertEqual(ui_evidence.stress_fingerprint(groups, "10000", "15"), small)
        self.assertNotEqual(ui_evidence.stress_fingerprint(groups, "10000", "16"), small)
        docs = ui_groups.Groups(repo(**{"docs__NOTES.md": "# notes"}))
        self.assertEqual(ui_evidence.stress_keys(docs), STRESS)
        device = ui_groups.Groups(repo(**{"App__AlbumistUITests__DeviceUITests.swift": DEVICE + "\n// x\nfunc more() {}\n"}))
        self.assertNotEqual(ui_evidence.stress_keys(device)["stress-10000-15"], small)
        self.assertTrue(ui_evidence.is_stress("stress-10000-15"))
        self.assertFalse(ui_evidence.is_stress("device"))

    def test_results_read_the_stress_step(self):
        found = ui_evidence.results([run(5, "s" * 40, [stress_job()], workflow="ui-stress.yml")])
        self.assertEqual([(e["group"], e["result"]) for e in found], [("stress-10000-15", "green")])
        red = stress_job("failure", "failure", job_id=701)
        found = ui_evidence.results([run(6, "s" * 40, [red], workflow="ui-stress.yml")],
                                    logs=lambda _: "UI_RESULT stress fail\n")
        self.assertEqual(found[0]["result"], "red")
        found = ui_evidence.results([run(6, "s" * 40, [red], workflow="ui-stress.yml")],
                                    logs=lambda _: "UI_RESULT stress infra\n")
        self.assertEqual(found[0]["result"], "none")

    def stress_gate(self, runs, stress_only=False, only=""):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(None, call=fake_api(runs), verifier=STRESS_VERIFIER, tree=HEAD, now=NOW,
                                    only=only, stress="10000-15", stress_only=stress_only)
        return code, log.getvalue()

    def test_the_gate_takes_a_green_pass_by_content(self):
        groups = run(1, "a" * 40, [job(g) for g in NAMES])
        before = run(2, "s" * 40, [stress_job()], workflow="ui-stress.yml")
        code, log = self.stress_gate([groups, before])
        self.assertEqual(code, 0, log)
        self.assertIn("stress-10000-15 reused from run 2", self.outputs()["text"])
        os.remove(self.output)
        code, log = self.stress_gate([groups])
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI stress-10000-15::no green full result", log)
        os.remove(self.output)
        red = run(3, "s" * 40, [stress_job("failure", "failure", job_id=702, end="2026-11-19T13:00:00Z")],
                  workflow="ui-stress.yml")
        code, log = self.stress_gate([groups, before, red])
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI stress-10000-15::red for this app and this test code", log)
        os.remove(self.output)
        code, log = self.stress_gate([before], stress_only=True)
        self.assertEqual(code, 0, log)
        self.assertEqual(self.outputs()["text"], "UI groups (stress pass 10000-15 only): stress-10000-15 reused from run 2 (sssssss)")

    def plan_stress(self, runs, reuse=True, fail=False):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.stress_plan("10000", "15", reuse, call=fake_api(runs, fail=fail),
                                           verifier=STRESS_VERIFIER, tree=HEAD, now=NOW)
        return code, log.getvalue()

    def test_the_stress_plan(self):
        before = run(2, "s" * 40, [stress_job()], workflow="ui-stress.yml")
        self.assertEqual(self.plan_stress([before])[0], 0)
        out = self.outputs()
        self.assertEqual((out["group"], out["app"], out["tests"], out["run"]),
                         ("stress-10000-15", APP[:12], STRESS["stress-10000-15"][:12], "false"))
        for runs, reuse, fail in (([], True, False), ([before], False, False), ([before], True, True)):
            with self.subTest(runs=len(runs), reuse=reuse, fail=fail):
                os.remove(self.output)
                self.assertEqual(self.plan_stress(runs, reuse, fail)[0], 0)
                self.assertEqual(self.outputs()["run"], "true")
        os.remove(self.output)
        red = run(3, "s" * 40, [stress_job("failure", "failure", job_id=703, end="2026-11-19T13:00:00Z")],
                  workflow="ui-stress.yml")
        code, log = self.plan_stress([before, red])
        self.assertEqual(self.outputs()["run"], "true")
        self.assertIn("red before for this key", log)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ui_evidence.stress_plan("10000", "1e3", True, tree=HEAD), 1)


if __name__ == "__main__":
    unittest.main()
