"""Unit tests for the early stages (--ci, --linux) of .github/scripts/ci_gate.py (no network: the API is faked).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import sys
import unittest

os.environ.setdefault("GITHUB_REPOSITORY", "owner/repo")
os.environ.setdefault("SHA", "0123456789abcdef0123456789abcdef01234567")
os.environ.setdefault("GH_TOKEN", "unused")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import ci_gate  # noqa: E402


def fake(run_status, jobs):
    run = {"id": 7, "run_number": 12, "name": "CI", "event": "pull_request", "html_url": "https://example/7",
           "status": run_status, "conclusion": None}

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
               "status": "completed", "conclusion": conclusion}

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


if __name__ == "__main__":
    unittest.main()
