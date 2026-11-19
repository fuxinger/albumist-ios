"""Unit tests for the text of .github/scripts/testflight_notes.py (no App Store Connect call).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import os
import subprocess
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

    def test_a_long_text_keeps_the_limit_and_the_build_line(self):
        text = testflight_notes.render(self.notes("Danke fürs Testen!\n\n" + "- Punkt\n" * 900), 42, SHA)
        self.assertTrue(text.startswith("Danke fürs Testen!"))
        self.assertTrue(text.endswith("…\n\nBuild 42 · 902f101"))
        self.assertLessEqual(len(text), testflight_notes.LIMIT)

    def test_there_is_no_forced_mode(self):
        # The emergency "force" (upload without tests) was removed (the owner's decision 17.11.,
        # G5-02/G6-02); so was the warning text for such a build.
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "testflight_notes.py")
        run = subprocess.run([sys.executable, script, "text", "--notes", self.notes("Hallo"), "--build", "1",
                              "--sha", SHA, "--forced"], capture_output=True, text=True)
        self.assertEqual(run.returncode, 2)
        self.assertIn("unrecognized arguments: --forced", run.stderr)


if __name__ == "__main__":
    unittest.main()
