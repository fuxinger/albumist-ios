"""Unit tests for .github/scripts/fast_gate.py (which changes may take the fast gate).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import fast_gate  # noqa: E402


class RefusedTests(unittest.TestCase):
    def test_views_map_texts_tests_and_documents_may_change(self):
        ok = ["App/Albumist/Views/LibraryView.swift", "App/Albumist/DesignSystem/Colors.swift",
              "App/Albumist/Map/Globe/Globe.swift", "App/Albumist/Resources/Localizable.xcstrings",
              "Sources/AlbumistMap/Route.swift", "Sources/AlbumistWorldMap/Coast.swift",
              "App/AlbumistUITests/FlowUITests.swift", "Tests/AlbumistCoreTests/X.swift",
              "docs/TESTFLIGHT_NOTES.md", "README.md", "website/index.html"]
        self.assertEqual(fast_gate.refused(ok), [])

    def test_analysis_counting_albums_purchases_and_data_are_refused(self):
        # The owner's rule of 26.11.: never through the fast gate.
        risky = ["Sources/AlbumistCore/Analysis/Pass.swift", "Sources/AlbumistCore/Execution/Apply.swift",
                 "Sources/AlbumistCore/Planning/Plan.swift", "Sources/AlbumistEngine/RecountState.swift",
                 "Sources/AlbumistStore/Migrations.swift", "Sources/CSQLite/sqlite3.c",
                 "App/Albumist/Platform/Purchases.swift", "App/Albumist/Platform/PhotoKitLibrary.swift",
                 "App/Albumist/Model/AppModel.swift", "App/StoreKit/Albumist.storekit",
                 "Package.swift", "Package.resolved", "App/project.yml"]
        self.assertEqual(fast_gate.refused(risky), risky)

    def test_it_fails_closed_for_new_places_the_pipeline_and_privacy(self):
        # A folder nobody listed, the gates themselves (also their documents) and the privacy manifest.
        paths = ["Sources/AlbumistNew/Thing.swift", ".github/workflows/testflight.yml",
                 ".github/scripts/fast_gate.py", ".github/rules.md", "App/Albumist/Resources/PrivacyInfo.xcprivacy"]
        self.assertEqual(fast_gate.refused(paths), paths)

    def test_views_that_buy_apply_undo_or_change_albums_are_refused(self):
        # Second review 26.11.: these views call the purchase, the plan, the undo and the album and
        # trip changes; the permission texts are what Apple reviews. Every denied path still exists.
        self.assertEqual(fast_gate.refused(list(fast_gate.DENIED)), list(fast_gate.DENIED))
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
        for path in fast_gate.DENIED:
            with self.subTest(path=path):
                self.assertTrue(os.path.exists(os.path.join(root, path)), f"{path} moved: update DENIED")

    def test_the_fast_build_is_for_internal_testers_only_in_app_store_connect(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
        with open(os.path.join(root, ".github", "workflows", "testflight.yml"), encoding="utf-8") as f:
            workflow = f.read()
        self.assertIn('if [ "$GATE" = fast ]; then\n            plutil -insert testFlightInternalTestingOnly -bool YES', workflow)


class CheckTests(unittest.TestCase):
    def git(self, tags, changed):
        def run(*args):
            if args[0] == "tag":
                return "\n".join(tags) + "\n"
            if args[0] == "diff":
                self.diffed = args[-1]
                return "\n".join(changed) + "\n"
            raise AssertionError(args)
        return run

    def check(self, tags, changed):
        summary = tempfile.NamedTemporaryFile("w+", delete=False)
        self.addCleanup(os.remove, summary.name)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = fast_gate.check("HEAD", run=self.git(tags, changed), summary=summary.name)
        return code, out.getvalue(), open(summary.name, encoding="utf-8").read()

    def test_compares_with_the_newest_build_tag(self):
        code, out, _ = self.check(["build-9", "build-41", "build-40", "other"], ["App/Albumist/Views/A.swift"])
        self.assertEqual(code, 0)
        self.assertEqual(self.diffed, "build-41..HEAD")
        self.assertIn("allowed", out)

    def test_a_risky_change_is_refused_with_its_paths(self):
        code, out, summary = self.check(["build-41"], ["App/Albumist/Views/A.swift", "Sources/AlbumistStore/Migrations.swift"])
        self.assertEqual(code, 1)
        self.assertIn("Sources/AlbumistStore/Migrations.swift", out)
        self.assertIn("small or the big gate", out)
        self.assertIn("`Sources/AlbumistStore/Migrations.swift`", summary)
        self.assertNotIn("Views/A.swift`", summary)

    def test_no_earlier_build_refuses(self):
        self.assertEqual(self.check([], ["docs/x.md"])[0], 1)


if __name__ == "__main__":
    unittest.main()
