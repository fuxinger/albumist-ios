"""Unit tests for .github/scripts/ci_gate.py (the release gate); no network, the API is faked.

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


class CiPartTests(unittest.TestCase):
    """Point 1 alone decides when CI is red or its iOS job never ran: the UI run is not looked at."""

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
                raise AssertionError("a red CI run must not wait for the UI run")
            return {"jobs": [{"name": "iOS build and tests (macOS)", "status": "completed", "conclusion": ios}]}
        return api

    def test_red_ci_stops(self):
        ci_gate.api = self.fake("failure", "failure")
        self.assertEqual(ci_gate.check()[:2], (True, False))

    def test_a_re_run_ci_attempt_is_not_green(self):
        # Fable P5-01: build 36 went out after a red run was re-run to green.
        api = self.fake("success", "success")
        ci_gate.api = lambda path, **params: (
            {"workflow_runs": [dict(r, run_attempt=2) for r in api(path)["workflow_runs"]]}
            if path == "actions/workflows/ci.yml/runs" else api(path, **params))
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("attempt 2", reason)

    def test_a_new_green_run_after_a_red_one_is_not_green(self):
        api = self.fake("success", "success")
        red = {"id": 6, "run_number": 11, "name": "CI", "event": "workflow_dispatch", "html_url": "https://example/6",
               "head_sha": os.environ["SHA"], "status": "completed", "conclusion": "failure"}
        cancelled = dict(red, id=5, run_number=10, conclusion="cancelled")
        ci_gate.api = lambda path, **params: (
            {"workflow_runs": api(path)["workflow_runs"] + [red, cancelled]}
            if path == "actions/workflows/ci.yml/runs" else api(path, **params))
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("#11", reason)
        self.assertIn("never re-run to green", reason)

    def test_a_red_run_re_run_to_green_then_a_new_run_is_not_green(self):
        # Second review 18.11.: #11 red, re-run to green (attempt 2), then #12 skips the iOS job.
        api = self.fake("success", "skipped")
        rerun = {"id": 6, "run_number": 11, "run_attempt": 2, "name": "CI", "event": "pull_request",
                 "html_url": "https://example/6", "head_sha": os.environ["SHA"], "status": "completed",
                 "conclusion": "success"}
        ci_gate.api = lambda path, **params: (
            {"workflow_runs": api(path)["workflow_runs"] + [rerun]} if path == "actions/workflows/ci.yml/runs"
            else {"jobs": [{"name": "iOS build and tests (macOS)", "conclusion": "success"}]} if path == "actions/runs/6/jobs"
            else api(path, **params))
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("#11", reason)
        self.assertIn("attempt 2", reason)

    def test_skipped_ios_job_is_not_green(self):
        ci_gate.api = self.fake("success", "skipped")
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("did not run", reason)


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

    def fake(self, ci=("completed", "success"), ui=None, verdict=("full", "success"), more=()):
        """ui: None (no UI flow run for this commit) or (status, conclusion). Callables are re-read each call.
        verdict: (mode, conclusion) of its "UI verdict" job, or None. more: older UI runs
        (number, status, conclusion, verdict)."""
        def api(path, **params):
            ci_state = ci() if callable(ci) else ci
            ui_state = ui() if callable(ui) else ui
            ui_runs = [(12, *ui_state, verdict)] if ui_state else []
            ui_runs += list(more)
            if path == "actions/workflows/ci.yml/runs":
                return {"workflow_runs": [self.run_("ci", *ci_state)] if ci_state else []}
            if path == "actions/workflows/ui.yml/runs":
                return {"workflow_runs": [dict(self.run_("ui", s, c, n), id=100 + n) for n, s, c, _ in ui_runs]}
            if path == "actions/runs/7/jobs":
                return {"jobs": [{"name": "iOS build and tests (macOS)", "status": "completed",
                                  "conclusion": "success"}]}
            for n, _, _, v in ui_runs:
                if path == f"actions/runs/{100 + n}/jobs":
                    return {"jobs": [{"name": "UI plan (which groups run)", "conclusion": "success"}]
                            + ([{"name": f"UI verdict ({v[0]})", "conclusion": v[1]}] if v else [])}
            raise AssertionError(path)
        return api

    def test_a_quick_ui_run_never_counts(self):
        ci_gate.api = self.fake(ui=("completed", "success"), verdict=("quick", "success"))
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (False, False))
        self.assertTrue(reason.startswith("no UI flow run in full mode"), reason)
        self.assertIn("1 quick run(s)", reason)
        # An older full run of the same commit decides.
        ci_gate.api = self.fake(ui=("completed", "success"), verdict=("quick", "success"),
                                more=[(10, "completed", "success", ("full", "success"))])
        self.assertEqual(ci_gate.check()[:2], (True, True))

    def test_a_draft_smoke_run_never_counts(self):
        # Stage 1 (26.11.2026): a draft's smoke run is skipped like a quick one; an older full
        # run of the same commit decides.
        ci_gate.api = self.fake(ui=("completed", "success"), verdict=("smoke", "success"),
                                more=[(10, "completed", "success", ("full", "success"))])
        self.assertEqual(ci_gate.check()[:2], (True, True))
        ci_gate.api = self.fake(ui=("in_progress", None), verdict=("smoke", None),
                                more=[(10, "completed", "success", ("full", "success"))])
        self.assertEqual(ci_gate.check()[:2], (True, True))

    def test_a_ui_run_without_a_green_full_verdict_is_not_green(self):
        # A skipped or cancelled verdict job checked nothing (G5-08): never green either.
        for verdict in (("full", "failure"), ("full", "skipped"), ("full", "cancelled"), None):
            with self.subTest(verdict=verdict):
                ci_gate.api = self.fake(ui=("completed", "success"), verdict=verdict)
                done, ok, reason = ci_gate.check()
                self.assertEqual((done, ok), (True, False))
                self.assertIn("no green 'UI verdict (full)' job", reason)

    def test_a_re_run_ui_attempt_is_not_green(self):
        api = self.fake(ui=("completed", "success"))
        ci_gate.api = lambda path, **params: (
            {"workflow_runs": [dict(r, run_attempt=3) for r in api(path)["workflow_runs"]]}
            if path == "actions/workflows/ui.yml/runs" else api(path, **params))
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("attempt 3", reason)

    def test_an_earlier_red_ui_run_is_not_cleared_by_a_new_one(self):
        for older in ((10, "completed", "failure", ("full", "failure")), (10, "completed", "failure", ("quick", "failure"))):
            with self.subTest(older=older):
                ci_gate.api = self.fake(ui=("completed", "success"), more=[older])
                done, ok, reason = ci_gate.check()
                self.assertEqual((done, ok), (True, False))
                self.assertIn("never re-run to green", reason)

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

    def test_a_skipped_ui_run_is_not_green(self):
        # G5-08: a UI flow run that GitHub skipped ran no group.
        ci_gate.api = self.fake(ui=("completed", "skipped"))
        done, ok, reason = ci_gate.check()
        self.assertEqual((done, ok), (True, False))
        self.assertIn("ended with 'skipped'", reason)

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
        self.assertIn("'UI verdict (full)'", output)
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

