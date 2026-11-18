"""Unit tests for the text of .github/scripts/testflight_notes.py (no App Store Connect call).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import testflight_notes  # noqa: E402

SHA = "902f10142f3d6abce01921d006ef42dd2250ed70"


class RenderTests(unittest.TestCase):
    def notes(self, body):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        path = os.path.join(folder.name, "notes.md")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# Kopf\n\nNicht für Tester.\n\n<!-- testflight:start -->\n{body}\n<!-- testflight:end -->\n\nAlt.\n")
        return path

    def test_only_the_marked_part_as_plain_text_with_build_and_commit(self):
        text = testflight_notes.render(self.notes("## Neu\n\n- **Pause** geht [hier](https://x.example)"), 41, SHA)
        self.assertEqual(text, "Neu\n\n• Pause geht hier (https://x.example)\n\nBuild 41 · 902f101")
        self.assertNotIn(testflight_notes.FORCED_MARK, text)

    def test_a_forced_build_says_so_first_and_last_and_keeps_the_limit(self):
        text = testflight_notes.render(self.notes("Danke fürs Testen!\n\n" + "- Punkt\n" * 900), 42, SHA, forced=True)
        self.assertTrue(text.startswith(testflight_notes.FORCED_WARNING + "\n\nDanke fürs Testen!"))
        self.assertTrue(text.endswith(f"Build 42 · 902f101 · {testflight_notes.FORCED_MARK}"))
        self.assertIn("FORCED – untested", testflight_notes.FORCED_WARNING)
        self.assertLessEqual(len(text), testflight_notes.LIMIT)


if __name__ == "__main__":
    unittest.main()
