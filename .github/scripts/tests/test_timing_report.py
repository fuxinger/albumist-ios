import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import timing_report  # noqa: E402

LOG = """\
✔ Test a() passed
TIMING_OVER Pause: 1.2 seconds over 1.0 seconds at AlbumistEngineTests/LoadTests.swift:318
TIMING_OVER Pause: 1.2 seconds over 1.0 seconds at AlbumistEngineTests/LoadTests.swift:318
TIMING_OVER labels later: 11.0 seconds over 10.0 seconds at AlbumistEngineTests/LabelsLaterTests.swift:269
"""


class TimingReportTests(unittest.TestCase):
    def test_counts_each_finding_once_in_order(self):
        self.assertEqual(timing_report.reported([LOG]), [
            "Pause: 1.2 seconds over 1.0 seconds at AlbumistEngineTests/LoadTests.swift:318",
            "labels later: 11.0 seconds over 10.0 seconds at AlbumistEngineTests/LabelsLaterTests.swift:269"])

    def test_warns_and_writes_the_summary_never_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "core.log")
            with open(path, "w") as f:
                f.write(LOG)
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                status = timing_report.main([path, os.path.join(folder, "missing.log")])
        self.assertEqual(status, 0)
        self.assertIn("reported only:** 2", out.getvalue())
        self.assertEqual(err.getvalue().count("::warning title=Time limit exceeded"), 2)

    def test_zero_is_said_too(self):
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            timing_report.main([])
        self.assertIn("reported only:** 0", out.getvalue())

    def test_workflows_report_only_on_pull_requests(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
        for name in ("ci.yml", "ui.yml"):
            with open(os.path.join(root, ".github", "workflows", name)) as f:
                text = f.read()
            self.assertIn("ALBUMIST_TIMING: ${{ (!inputs.release && github.event_name == 'pull_request') && 'report' || 'hard' }}",
                          text, name)
            self.assertIn("timing_report.py", text, name)
        with open(os.path.join(root, ".github", "workflows", "ui.yml")) as f:
            ui = f.read()
        # The merge gate holds the limits hard: macOS core tests and the load test in a full run.
        self.assertIn("core-macos:", ui)
        self.assertIn("needs: [plan, ui, core-macos]", ui)
        self.assertIn("Load test, hard limits", ui.split("core-macos:", 1)[1].split("\n  build:", 1)[0])
        for name in ("nightly.yml", "testflight.yml", "ui-stress.yml"):
            with open(os.path.join(root, ".github", "workflows", name)) as f:
                self.assertNotIn("ALBUMIST_TIMING", f.read(), name)


if __name__ == "__main__":
    unittest.main()
