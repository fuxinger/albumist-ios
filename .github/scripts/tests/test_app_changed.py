"""Unit tests for .github/scripts/app_changed.py (no git needed for the decision)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import app_changed  # noqa: E402


class DecideTests(unittest.TestCase):
    def test_website_only_since_the_last_build_starts_nothing(self):
        changed, reason = app_changed.decide("build-40", ["website/index.html", "website/EINSTELLUNGEN.txt"])
        self.assertFalse(changed)
        self.assertIn("build-40", reason)

    def test_docs_and_markdown_only_start_nothing(self):
        self.assertFalse(app_changed.decide("build-40", ["docs/IMPROVEMENTS.md", "README.md", "App/notes.md"])[0])

    def test_any_app_file_counts(self):
        self.assertTrue(app_changed.decide("build-40", ["website/a.html", "App/Sortly/Model/AppModel.swift"])[0])

    def test_pipeline_and_project_files_count(self):
        for path in [".github/workflows/testflight.yml", "project.yml", "Package.swift", "Sources/SortlyCore/X.swift"]:
            self.assertTrue(app_changed.decide("build-40", [path])[0], path)

    def test_without_an_earlier_build_everything_is_new(self):
        self.assertTrue(app_changed.decide(None, [])[0])

    def test_nothing_changed_since_the_tag_starts_nothing(self):
        self.assertFalse(app_changed.decide("build-40", [])[0])


if __name__ == "__main__":
    unittest.main()
