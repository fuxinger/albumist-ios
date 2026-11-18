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
from test_ui_groups import FLOW, repo  # noqa: E402

os.environ.setdefault("GITHUB_REPOSITORY", "owner/repo")
os.environ.setdefault("GH_TOKEN", "unused")

HEAD = repo()
APP = ui_groups.app_fingerprint(HEAD)
FPS = ui_groups.Groups(HEAD).fingerprints()
NAMES = ["device", "full", "other", "small"]
TITLES = {"device": "device conditions", "full": "full flow", "other": "other flows", "small": "small iPhone"}
# A test-only commit after HEAD: a shorter wait in FlowUITests.swift (groups full, other, small).
TEST_ONLY = repo(**{"App__SortlyUITests__FlowUITests.swift": FLOW + "\n// waits 20 s, measured in run 1\n"})
TEST_ONLY_FPS = ui_groups.Groups(TEST_ONLY).fingerprints()


def name(group, app=APP, tests=None, prefix=""):
    tests = tests or FPS[group]
    return f"{prefix}UI {TITLES[group]} [{group} app {app[:12]} tests {tests[:12]}]"


def job(group, conclusion="success", step="success", job_id=None, end="2026-11-17T12:00:00Z", **kw):
    steps = [{"name": "Set up job", "conclusion": "success"}, {"name": "Wait for the simulator", "conclusion": "success"},
             {"name": "Run UI tests", "conclusion": step, "started_at": "2026-11-17T11:00:00Z"}]
    if conclusion == "boot":
        conclusion = "failure"
        steps[1]["conclusion"], steps[2] = "failure", {"name": "Run UI tests", "conclusion": "skipped"}
    return {"id": job_id or hash((group, end, conclusion)) % 10**9, "name": name(group, **kw), "conclusion": conclusion,
            "started_at": "2026-11-17T11:00:00Z", "completed_at": end, "steps": steps, "run_attempt": 1,
            "html_url": f"https://example/job/{group}"}


def run(run_id, sha, jobs, event="workflow_dispatch", workflow="ui.yml", repo_name="owner/repo"):
    return ({"id": run_id, "run_number": run_id, "head_sha": sha, "event": event, "path": f".github/workflows/{workflow}",
             "created_at": "2026-11-17T10:00:00Z", "head_repository": {"full_name": repo_name}}, jobs)


class FakeVerifier:
    """sha -> (app, group fingerprints) as git would compute them."""

    def __init__(self, commits):
        self.commits = commits

    def app(self, sha):
        return self.commits.get(sha, (None, {}))[0]

    def matches(self, entry):
        app, groups = self.commits.get(entry["sha"], (None, {}))
        return bool(app) and app[:12] == entry["app"] and groups.get(entry["group"], "")[:12] == entry["tests"]


VERIFIER = FakeVerifier({"a" * 40: (APP, FPS), "b" * 40: (APP, TEST_ONLY_FPS), "c" * 40: ("f" * 64, {})})


def fake_api(runs, annotations=None, fail=False):
    calls = []

    def call(path, **params):
        calls.append(path)
        if fail:
            raise ui_evidence.ApiError("down")
        match = re.fullmatch(r"actions/workflows/(\S+)/runs", path)
        if match:
            return {"workflow_runs": [r for r, _ in runs if r["path"].endswith(match.group(1))]}
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
        # No test ran: a simulator that did not boot, or a cancelled run.
        self.assertEqual(ui_evidence.classify(job("device", "boot")), "none")
        self.assertEqual(ui_evidence.classify(job("device", "cancelled", "cancelled")), "none")

    def test_job_names_from_ui_yml_are_found(self):
        workflow = open(os.path.join(ui_groups.ROOT, ".github", "workflows", "ui.yml"), encoding="utf-8").read()
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
        runs = [run(1, "a" * 40, [job("other", "failure", "failure", end="2026-11-17T10:00:00Z")]),
                run(2, "a" * 40, [job("other", end="2026-11-17T12:00:00Z")])]
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
                run(4, "a" * 40, [job("small")], event="pull_request"),  # merge commit: always read
                run(9, "a" * 40, [job("other")], workflow="testflight.yml")]
        call = fake_api(runs)
        history = ui_evidence.fetch_history(APP, 9, VERIFIER, call=call, now=datetime(2026, 11, 18, tzinfo=timezone.utc))
        self.assertEqual(sorted(r["id"] for r, _ in history), [1, 4, 9])
        self.assertNotIn("actions/runs/2/jobs", call.calls)


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
        return open(path, encoding="utf-8").read() if os.path.exists(path) else ""

    def outputs(self):
        return dict(line.split("=", 1) for line in self.read(self.output).splitlines())

    def plan(self, choice, runs, tree=TEST_ONLY, fail=False):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.plan(choice, call=fake_api(runs, fail=fail), verifier=VERIFIER, tree=tree)
        return code, log.getvalue()

    def gate(self, runs, tree=TEST_ONLY, run_id=9, annotations=None):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(run_id, call=fake_api(runs, annotations), verifier=VERIFIER, tree=tree)
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
        self.assertTrue(text.startswith("UI groups: device reused from run 1 (aaaaaaa); full here"), text)
        self.assertIn("::warning title=Flaky in a reused UI group::device (run 1)", log)
        self.assertIn("passed only on a repeat", self.read(self.summary))

    def test_gate_refuses_a_missing_group_and_a_rerun_red(self):
        code, log = self.gate([run(9, "b" * 40, [job("full", tests=TEST_ONLY_FPS["full"])], workflow="testflight.yml")])
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI device::no green result", log)
        red_then_green = self.NIGHT + [
            run(8, "b" * 40, [job("other", "failure", "failure", tests=TEST_ONLY_FPS["other"], end="2026-11-17T13:00:00Z")]),
            run(9, "b" * 40, [job(g, tests=TEST_ONLY_FPS[g], end="2026-11-17T15:00:00Z") for g in ["full", "other", "small"]],
                workflow="testflight.yml")]
        code, log = self.gate(red_then_green)
        self.assertEqual(code, 1)
        self.assertIn("::error title=UI other::red for this app and this test code", log)
        self.assertIn("**Not uploaded**", self.read(self.summary))

    def test_gate_fails_closed_without_the_api(self):
        with contextlib.redirect_stdout(io.StringIO()) as log:
            code = ui_evidence.gate(9, call=fake_api([], fail=True), verifier=VERIFIER, tree=TEST_ONLY)
        self.assertEqual(code, 1)
        self.assertIn("re-run this job", log.getvalue())


if __name__ == "__main__":
    unittest.main()
