"""Unit tests for .github/scripts/swift_test_watch.py (hang report of the core tests).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import swift_test_watch  # noqa: E402


class TrackerTests(unittest.TestCase):
    def test_swift_testing_and_xctest_lines(self):
        now = [0.0]
        tracker = swift_test_watch.Tracker(clock=lambda: now[0])
        for line in ["◇ Suite FullRunDisplayTests started.",
                     "◇ Test rebuildAfterCompleteRun() started.",
                     "◇ Test fastOne() started.",
                     "✔ Test fastOne() passed after 0.002 seconds.",
                     "◇ Test failing() started.",
                     "✘ Test failing() failed after 0.1 seconds with 1 issue.",
                     "Test Case '-[CoreTests.OldTests testHang]' started.",
                     "Test Case '-[CoreTests.OldTests testOk]' started.",
                     "Test Case '-[CoreTests.OldTests testOk]' passed (0.01 seconds)."]:
            tracker.feed(line + "\n")
            now[0] += 1
        self.assertEqual([n for n, _ in tracker.running()],
                         ["rebuildAfterCompleteRun()", "Case '-[CoreTests.OldTests testHang]'"])
        self.assertEqual(tracker.running()[0][1], 8)

    def test_a_name_started_twice_stays_open_until_both_end(self):
        tracker = swift_test_watch.Tracker()
        for line in ["◇ Test same() started.", "◇ Test same() started.", "✔ Test same() passed after 1 seconds."]:
            tracker.feed(line)
        self.assertEqual([n for n, _ in tracker.running()], ["same()"])


class RunTests(unittest.TestCase):
    def run_watch(self, script, seconds):
        with tempfile.TemporaryDirectory() as folder:
            log = os.path.join(folder, "log.txt")
            summary = os.path.join(folder, "summary.md")
            os.environ["GITHUB_STEP_SUMMARY"] = summary
            self.addCleanup(os.environ.pop, "GITHUB_STEP_SUMMARY", None)
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = swift_test_watch.main(["--seconds", str(seconds), "--grace", "2", "--log", log, "--",
                                              sys.executable, "-c", script])
            with open(log, encoding="utf-8") as f:
                logged = f.read()
            text = open(summary, encoding="utf-8").read() if os.path.exists(summary) else ""
            return code, out.getvalue(), logged, text

    def test_a_hang_names_the_running_test_and_fails(self):
        script = ("import time,sys\nprint('◇ Test quick() started.');print('✔ Test quick() passed after 0.1 seconds.')\n"
                  "print('◇ Test rebuildAfterCompleteRun() started.', flush=True)\ntime.sleep(60)\n")
        code, out, logged, summary = self.run_watch(script, 2)
        self.assertEqual(code, 124)
        self.assertIn("TEST_HANG rebuildAfterCompleteRun() running for", out)
        self.assertNotIn("TEST_HANG quick()", out)
        self.assertIn("::error title=Tests hung::swift test ran longer than 0 min; still running: rebuildAfterCompleteRun()", out)
        self.assertIn("rebuildAfterCompleteRun() started", logged)
        self.assertIn("**Tests hung**", summary)

    def test_without_a_hang_the_status_is_the_commands(self):
        code, out, logged, summary = self.run_watch("print('◇ Test a() started.');print('✘ Test a() failed after 1 seconds.');"
                                                    "raise SystemExit(1)", 30)
        self.assertEqual(code, 1)
        self.assertNotIn("TEST_HANG", out)
        self.assertIn("Test a() failed", out)
        self.assertEqual(summary, "")
        code, *_ = self.run_watch("print('ok')", 30)
        self.assertEqual(code, 0)

    def test_quiet_writes_only_the_log(self):
        with tempfile.TemporaryDirectory() as folder:
            log = os.path.join(folder, "load.log")
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = swift_test_watch.main(["--seconds", "30", "--quiet", "--log", log, "--",
                                              sys.executable, "-c", "print('LOAD_ 1')"])
            self.assertEqual(code, 0)
            self.assertEqual(out.getvalue(), "")
            self.assertIn("LOAD_ 1", open(log, encoding="utf-8").read())


if __name__ == "__main__":
    unittest.main()
