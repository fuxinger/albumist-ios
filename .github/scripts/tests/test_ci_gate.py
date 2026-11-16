"""Unit tests for .github/scripts/ci_gate.py: the full gate and its early stages (--ci, --linux); no network, the API is faked.

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import io
import os
import sys
import tempfile
import unittest
import unittest.mock
from contextlib import redirect_stdout

os.environ.setdefault("GITHUB_REPOSITORY", "owner/repo")
os.environ.setdefault("SHA", "0123456789abcdef0123456789abcdef01234567")
os.environ.setdefault("GH_TOKEN", "unused")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ci_gate  # noqa: E402


def fake(run_status, jobs):
    run = {"id": 7, "run_number": 12, "name": "CI", "event": "pull_request", "html_url": "https://example/7",
           "head_sha": os.environ["SHA"], "status": run_status, "conclusion": None}

    def api(path, **params):
        if path.startswith("actions/workflows/"):
            return {"workflow_runs": [run]}
        if path == "actions/runs/7/jobs":
            return {"jobs": [{"name": n, "status": s, "conclusion": c} for n, s, c in jobs]}
        raise AssertionError(path)
    return api


class LinuxStageTests(unittest.TestCase):
    def setUp(self):
        self.original = ci_gate.api

    def tearDown(self):
        ci_gate.api = self.original

    def test_both_linux_jobs_green_while_the_mac_job_still_runs(self):
        ci_gate.api = fake("in_progress", [("Core tests (Linux)", "completed", "success"),
                                           ("App rules and strings", "completed", "success"),
                                           ("iOS build and tests (macOS)", "in_progress", None)])
        done, ok, _ = ci_gate.check_linux()
        self.assertEqual((done, ok), (True, True))

    def test_waits_while_the_core_tests_run(self):
        ci_gate.api = fake("in_progress", [("Core tests (Linux)", "in_progress", None),
                                           ("App rules and strings", "completed", "success")])
        self.assertEqual(ci_gate.check_linux()[:2], (False, False))

    def test_failed_core_tests_stop_the_wait(self):
        ci_gate.api = fake("in_progress", [("Core tests (Linux)", "completed", "failure"),
                                           ("App rules and strings", "completed", "success")])
        done, ok, reason = ci_gate.check_linux()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("failure", reason)

    def test_cancelled_run_without_linux_result_is_not_green(self):
        ci_gate.api = fake("completed", [("App rules and strings", "completed", "success")])
        self.assertEqual(ci_gate.check_linux()[:2], (True, False))

    def test_no_ci_run_yet(self):
        ci_gate.api = lambda path, **params: {"workflow_runs": []}
        self.assertEqual(ci_gate.check_linux()[:2], (False, False))


class CiStageTests(unittest.TestCase):
    """--ci: CI green with its iOS job, the UI run is not looked at."""

    def setUp(self):
        self.original = ci_gate.api

    def tearDown(self):
        ci_gate.api = self.original

    def fake(self, conclusion, ios):
        run = {"id": 7, "run_number": 12, "name": "CI", "event": "pull_request", "html_url": "https://example/7",
               "head_sha": os.environ["SHA"], "status": "completed", "conclusion": conclusion}

        def api(path, **params):
            if path == "actions/workflows/ci.yml/runs":
                return {"workflow_runs": [run]}
            if path == "actions/workflows/ui.yml/runs":
                raise AssertionError("--ci must not wait for the UI run")
            return {"jobs": [{"name": "iOS build and tests (macOS)", "status": "completed", "conclusion": ios}]}
        return api

    def test_green_ci_is_enough(self):
        ci_gate.api = self.fake("success", "success")
        self.assertEqual(ci_gate.check(ui_too=False)[:2], (True, True))

    def test_red_ci_stops(self):
        ci_gate.api = self.fake("failure", "failure")
        self.assertEqual(ci_gate.check(ui_too=False)[:2], (True, False))

    def test_skipped_ios_job_is_not_green(self):
        ci_gate.api = self.fake("success", "skipped")
        self.assertEqual(ci_gate.check(ui_too=False)[:2], (True, False))


class FullGateTests(unittest.TestCase):
    """The full gate: CI with its iOS job and a green UI flow run on exactly this commit, always."""

    def setUp(self):
        self.original = (ci_gate.api, ci_gate.time, ci_gate.NO_RUN, ci_gate.WAIT)

    def tearDown(self):
        ci_gate.api, ci_gate.time, ci_gate.NO_RUN, ci_gate.WAIT = self.original

    @staticmethod
    def run_(workflow, status, conclusion, number=12):
        return {"id": 7 if workflow == "ci" else 8, "run_number": number, "name": workflow, "event": "push",
                "html_url": f"https://example/{workflow}", "head_sha": os.environ["SHA"], "status": status, "conclusion": conclusion}

    def fake(self, ci=("completed", "success"), ui=None):
        """ui: None (no UI flow run for this commit) or (status, conclusion). Callables are re-read each call."""
        def api(path, **params):
            ci_state = ci() if callable(ci) else ci
            ui_state = ui() if callable(ui) else ui
            if path == "actions/workflows/ci.yml/runs":
                return {"workflow_runs": [self.run_("ci", *ci_state)] if ci_state else []}
            if path == "actions/workflows/ui.yml/runs":
                return {"workflow_runs": [self.run_("ui", *ui_state)] if ui_state else []}
            if path == "actions/runs/7/jobs":
                return {"jobs": [{"name": "iOS build and tests (macOS)", "status": "completed",
                                  "conclusion": "success"}]}
            raise AssertionError(path)
        return api

    def test_no_ui_run_is_not_green(self):
        # A push to main (merge commit) has no UI flow run; before 16.11. CI alone made it green.
        ci_gate.api = self.fake(ui=None)
        done, ok, reason = ci_gate.check()
        self.assertFalse(ok)
        self.assertFalse(done, "waits NO_RUN_MINUTES for a UI run to appear")
        self.assertTrue(reason.startswith("no UI flow run"), reason)

    def test_green_ui_run_on_this_commit_is_green(self):
        ci_gate.api = self.fake(ui=("completed", "success"))
        self.assertEqual(ci_gate.check()[:2], (True, True))

    def test_red_ui_run_stops(self):
        ci_gate.api = self.fake(ui=("completed", "failure"))
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("failure", reason)

    def test_running_ui_run_waits(self):
        ci_gate.api = self.fake(ui=("in_progress", None))
        self.assertEqual(ci_gate.check()[:2], (False, False))

    def run_main(self, clock):
        class FakeTime:
            @staticmethod
            def monotonic():
                return clock[0]

            @staticmethod
            def sleep(seconds):
                clock[0] += seconds
        ci_gate.time = FakeTime
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "out")
            env = {"GITHUB_OUTPUT": out, "GITHUB_STEP_SUMMARY": os.path.join(tmp, "summary")}
            saved = {k: os.environ.get(k) for k in env}
            os.environ.update(env)
            argv, sys.argv = sys.argv, ["ci_gate.py"]
            try:
                with redirect_stdout(io.StringIO()) as printed:
                    code = ci_gate.main()
            finally:
                sys.argv = argv
                for k, v in saved.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v
            with open(out, encoding="utf-8") as f:
                return code, f.read(), printed.getvalue()

    def test_release_without_waiting_reports_the_missing_ui_run(self):
        # release.yml: WAIT_MINUTES=0, NO_RUN_MINUTES=0.
        ci_gate.api = self.fake(ui=None)
        ci_gate.NO_RUN, ci_gate.WAIT = 0, 0
        code, output, printed = self.run_main([0.0])
        self.assertEqual(code, 0)
        self.assertIn("ok=false", output)
        self.assertIn("needs a green UI flow run on exactly this commit", output)
        self.assertIn("start 'UI flow' by hand on this commit", output)
        self.assertIn("Not green", printed)

    def test_missing_ui_run_is_waited_for_from_when_ci_passed(self):
        # CI takes longer than NO_RUN_MINUTES; the wait for the UI run starts only once CI passed,
        # and a UI run started by hand in that window is still taken.
        clock = [0.0]
        ci_gate.NO_RUN, ci_gate.WAIT = 15 * 60, 180 * 60
        ci_state = lambda: ("in_progress", None) if clock[0] < 20 * 60 else ("completed", "success")
        ui_state = lambda: None if clock[0] < 30 * 60 else ("completed", "success")
        ci_gate.api = self.fake(ci=ci_state, ui=ui_state)
        code, output, _ = self.run_main(clock)
        self.assertIn("ok=true", output)

        clock[0] = 0.0
        ci_gate.api = self.fake(ci=ci_state, ui=None)
        code, output, _ = self.run_main(clock)
        self.assertIn("ok=false", output)
        self.assertIn("no UI flow run", output)
        self.assertGreaterEqual(clock[0], 35 * 60)
        self.assertLess(clock[0], 40 * 60)


class ExactCommitTests(unittest.TestCase):
    def test_a_run_of_another_commit_never_counts(self):
        other = {"id": 9, "run_number": 99, "name": "CI", "event": "push", "html_url": "https://example/9",
                 "head_sha": "f" * 40, "status": "completed", "conclusion": "success"}
        with unittest.mock.patch.object(ci_gate, "api", lambda path, **params: {"workflow_runs": [other]}):
            self.assertEqual(ci_gate.runs("ci.yml"), [])


if __name__ == "__main__":
    unittest.main()

