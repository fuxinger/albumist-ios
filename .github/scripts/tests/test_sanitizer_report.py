"""Unit tests for sanitizer_report.py (the opt-in Thread Sanitizer run, sanitize.yml).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import sanitizer_report  # noqa: E402

RACE = """Test Case '-[SortlyTests.ThumbnailTests testBatch]' started.
==================
WARNING: ThreadSanitizer: Swift access race (pid=4242)
  Modifying access of Swift variable at 0x7b0c00001234 by thread T3:
    #0 ThumbnailCache.store(_:for:) ThumbnailCache.swift:41 (Sortly:arm64+0x1000)
    #1 closure #1 in ThumbnailLoader.load() ThumbnailLoader.swift:88 (Sortly:arm64+0x2000)

  Previous read of size 8 at 0x7b0c00001234 by main thread:
    #0 ThumbnailCache.image(for:) ThumbnailCache.swift:30 (Sortly:arm64+0x3000)

SUMMARY: ThreadSanitizer: Swift access race ThumbnailCache.swift:41 in ThumbnailCache.store(_:for:)
==================
Test Case '-[SortlyTests.ThumbnailTests testBatch]' passed (0.512 seconds).
"""


class ReportTests(unittest.TestCase):
    def test_clean_log_passes(self):
        markdown, marks = sanitizer_report.summary({"app.log": "Test Suite 'All tests' passed\n"})
        self.assertEqual(marks, 0)
        self.assertIn("No ThreadSanitizer report", markdown)

    def test_a_race_is_shown_with_both_stacks_and_fails(self):
        markdown, marks = sanitizer_report.summary({"app.log": RACE})
        self.assertEqual(marks, 2)
        self.assertIn("1x Swift access race ThumbnailCache.swift:41", markdown)
        self.assertIn("#1 closure #1 in ThumbnailLoader.load()", markdown)
        self.assertIn("Previous read of size 8", markdown)

    def test_same_race_twice_is_one_entry_with_its_count(self):
        markdown, _ = sanitizer_report.summary({"a.log": RACE, "b.log": RACE + RACE})
        self.assertIn("3x Swift access race", markdown)
        self.assertIn("**1 distinct report(s)**", markdown)

    def test_lines_outside_a_block_still_fail(self):
        text = "FATAL: ThreadSanitizer: unexpected memory mapping 0x7f0000000000-0x7f0000001000\n"
        markdown, marks = sanitizer_report.summary({"core.log": text})
        self.assertEqual(marks, 1)
        self.assertIn("unexpected memory mapping", markdown)

    def test_an_unrelated_fence_does_not_hide_the_log(self):
        text = "==================\nsome banner\n==================\nThreadSanitizer: reported 1 warnings\n"
        blocks, loose = sanitizer_report.reports(text)
        self.assertEqual(blocks, [])
        self.assertEqual(loose, ["ThreadSanitizer: reported 1 warnings"])

    def test_exit_status(self):
        with tempfile.TemporaryDirectory() as folder:
            clean, dirty = os.path.join(folder, "clean.log"), os.path.join(folder, "dirty.log")
            open(clean, "w").write("ok\n")
            open(dirty, "w").write(RACE)
            with open(os.devnull, "w") as null:
                stdout, stderr = sys.stdout, sys.stderr
                sys.stdout = sys.stderr = null
                try:
                    self.assertEqual(sanitizer_report.main([clean]), 0)
                    self.assertEqual(sanitizer_report.main([clean, dirty]), 1)
                finally:
                    sys.stdout, sys.stderr = stdout, stderr


if __name__ == "__main__":
    unittest.main()
