"""Unit tests for swiftlint_report.py (ci.yml, "SwiftLint report")."""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import swiftlint_report  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def finding(rule, path, severity="Warning"):
    return {"rule_id": rule, "file": path, "severity": severity, "line": 1, "character": 1, "reason": "r", "type": "t"}


class ReportTests(unittest.TestCase):
    def run_main(self, status, findings=None, text=None):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "findings.json")
            if findings is not None or text is not None:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text if text is not None else json.dumps(findings))
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                code = swiftlint_report.main(["--status", str(status), path])
            return code, out.getvalue(), err.getvalue()

    def test_findings_do_not_fail(self):
        findings = [finding("line_length", "Sources/AlbumistCore/A.swift"),
                    finding("line_length", "Sources/AlbumistCore/B.swift"),
                    finding("force_cast", "App/Albumist/C.swift", "Error")]
        for status in (0, 2):
            code, out, err = self.run_main(status, findings)
            self.assertEqual(code, 0)
            self.assertIn("3 findings in 3 files: 1 errors, 2 warnings", out)
            self.assertIn("| line_length | warning | 2 |", out)
            self.assertIn("| Sources/AlbumistCore | 2 |", out)
            self.assertIn("SWIFTLINT findings=3", err)

    def test_no_findings(self):
        code, out, _ = self.run_main(0, [])
        self.assertEqual(code, 0)
        self.assertIn("No findings.", out)

    def test_swiftlint_that_did_not_lint_fails(self):
        for status in (1, 3, 127):
            code, _, err = self.run_main(status, [])
            self.assertEqual(code, 1, status)
            self.assertIn("did not lint", err)

    def test_unreadable_report_fails(self):
        self.assertEqual(self.run_main(0)[0], 1)  # no file
        self.assertEqual(self.run_main(0, text="Linting Swift files")[0], 1)
        self.assertEqual(self.run_main(2, text="{}")[0], 1)

    def test_long_rule_list_is_cut(self):
        findings = [finding(f"rule_{n:02d}", "Tests/X/A.swift") for n in range(30)]
        out = swiftlint_report.summary(findings, top=25)
        self.assertIn("| 5 more rules | | 5 |", out)

    def test_absolute_paths_are_made_relative(self):
        self.assertEqual(swiftlint_report.folder(os.path.join(os.getcwd(), "Sources", "AlbumistCore", "A.swift")),
                         "Sources/AlbumistCore")
        self.assertEqual(swiftlint_report.folder("Package.swift"), "Package.swift")


class WorkflowTests(unittest.TestCase):
    """The job is report-only on purpose: nothing waits for it, and it never runs in a release."""

    def test_job_wiring(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ci.yml"), encoding="utf-8") as f:
            text = f.read()
        job = text[text.index("\n  swiftlint:\n"):text.index("\n  changes:\n")]
        self.assertIn("if: ${{ !inputs.release }}", job)
        self.assertIn("--no-cache", job)
        self.assertIn("--config .github/swiftlint.yml", job)
        self.assertIn("toolchain.py swiftlint", job)
        self.assertNotIn("actions/cache", job)
        self.assertNotIn("continue-on-error", job)
        self.assertNotRegex(text, r"needs:[^\n]*swiftlint")
        self.assertIn("persist-credentials: false", job)
        self.assertIn("| tee -a \"$GITHUB_STEP_SUMMARY\"", job)
        self.assertIn("shell: bash", job)  # GitHub's "bash" runs with -o pipefail


if __name__ == "__main__":
    unittest.main()
