"""Unit tests for tools/rename_albumist.py (the one-shot rename of the working name Sortly to
Albumist): the case-aware mapping, the exclusions (stored names, outside names, the repository's
URLs only with --repo-renamed), --apply in a scratch repository (moves, idempotence, a dirty tree
is refused), and that the plan over this repository builds (no spelling without a mapping, no
two files landing on one path)."""
import contextlib
import io
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = pathlib.Path(HERE).parents[2]
sys.path.insert(0, str(REPO / "tools"))
import rename_albumist as ra  # noqa: E402


def rename(text, repo_renamed=False):
    return ra.rename_text(text, repo_renamed).text


class MappingTests(unittest.TestCase):
    def test_each_spelling_keeps_its_case(self):
        self.assertEqual(rename("Sortly sortly SORTLY"), "Albumist albumist ALBUMIST")

    def test_inside_longer_names(self):
        cases = {
            "struct SortlyID": "struct AlbumistID",
            "import SortlyCore": "import AlbumistCore",
            "state.addedBySortly.count": "state.addedByAlbumist.count",
            "Calendar.sortlyDefault": "Calendar.albumistDefault",
            "TEST_RUNNER_SORTLY_UI_QUICK: '1'": "TEST_RUNNER_ALBUMIST_UI_QUICK: '1'",
            '["-SortlyUITestUnlocked"]': '["-AlbumistUITestUnlocked"]',
            'withExtension: "sortlymap"': 'withExtension: "albumistmap"',
            "-scheme SortlyUI": "-scheme AlbumistUI",
            "pgrep -f \"Sortly.app/Sortly\"": "pgrep -f \"Albumist.app/Albumist\"",
        }
        for old, new in cases.items():
            self.assertEqual(rename(old), new, old)

    def test_a_spelling_without_mapping_stops(self):
        with self.assertRaises(ra.RenameError):
            rename("SortLy")

    def test_paths(self):
        self.assertEqual(ra.map_path("App/Sortly/App/SortlyApp.swift"), "App/Albumist/App/AlbumistApp.swift")
        self.assertEqual(ra.map_path("Sources/SortlyWorldMap/Resources/world.sortlymap"),
                         "Sources/AlbumistWorldMap/Resources/world.albumistmap")
        self.assertEqual(ra.map_path("docs/ARCHITECTURE.md"), "docs/ARCHITECTURE.md")

    def test_counts_by_token(self):
        result = ra.rename_text("SortlyID SortlyID SortlyCore")
        self.assertEqual(result.count, 3)
        self.assertEqual(result.replaced["SortlyID -> AlbumistID"], 2)

    def test_text_without_the_name_is_unchanged(self):
        result = ra.rename_text("Albumist shortly sorts")
        self.assertEqual((result.text, result.count, result.kept), ("Albumist shortly sorts", 0, []))


class ExclusionTests(unittest.TestCase):
    def test_stored_json_keys_keep_their_names_the_swift_names_change(self):
        self.assertEqual(rename('case addedBySortly = "addedBySortly"\ncase createdBySortly = "createdBySortly"'),
                         'case addedByAlbumist = "addedBySortly"\ncase createdByAlbumist = "createdBySortly"')
        raw = '#"{"addedBySortly":["a-1"],"createdBySortly":true}"#'
        self.assertEqual(rename(raw), raw)

    def test_the_legacy_database_name_stays_the_current_one_changes(self):
        src = ('public static let name = "sortly.sqlite"\n'
               'public static let legacyName = "sortly.sqlite"\n')
        self.assertEqual(rename(src), 'public static let name = "albumist.sqlite"\n'
                                      'public static let legacyName = "sortly.sqlite"\n')

    def test_outside_names_stay(self):
        for text in ("if: github.ref == 'refs/heads/claude/sortly-app'",
                     'select(.note == "sortly-ci")', "-F \"note=sortly-ci\"",
                     "/// sortly-review/alben-und-bedienung-2026-11-16/BEFUNDE.md.",
                     "Der App-Name ist Albumist („Sortly“ ist", "„Sortly“ ist vergeben"):
            self.assertEqual(rename(text), text)

    def test_the_old_name_as_a_scheme_name_in_quotes_changes(self):
        self.assertEqual(rename("open Sortly.xcodeproj  # Schema „Sortly“"), "open Albumist.xcodeproj  # Schema „Albumist“")

    def test_only_the_outside_part_of_a_line_stays(self):
        line = '-F "file=@build/Sortly-simulator.zip" -F "note=sortly-ci"'
        result = ra.rename_text(line)
        self.assertEqual(result.text, '-F "file=@build/Albumist-simulator.zip" -F "note=sortly-ci"')
        self.assertEqual([key for _, key, _ in result.kept], ["appetize-note"])

    def test_repository_urls_only_with_repo_renamed(self):
        src = ('return URL(string: "https://fuxinger.github.io/sortly-ios/en/privacy.html")\n'
               "url: https://github.com/fuxinger/sortly-ios/security/advisories/new\n"
               "/Users/runner/work/sortly-ios/sortly-ios/App/SortlyUITests/X.swift\n")
        self.assertEqual(rename(src), src.replace("App/SortlyUITests", "App/AlbumistUITests"))
        self.assertEqual(rename(src, repo_renamed=True),
                         'return URL(string: "https://fuxinger.github.io/albumist-ios/en/privacy.html")\n'
                         "url: https://github.com/fuxinger/albumist-ios/security/advisories/new\n"
                         "/Users/runner/work/albumist-ios/albumist-ios/App/AlbumistUITests/X.swift\n")

    def test_a_keep_block_stays(self):
        src = ("SortlyCore\n<!-- rename:keep-begin -->\nformer name Sortly, sortly.sqlite\n<!-- rename:keep-end -->\n"
               "SortlyCore\n")
        self.assertEqual(rename(src), src.replace("SortlyCore", "AlbumistCore"))

    def test_every_exclusion_has_a_reason(self):
        for rule in ra.EXCLUSIONS + [ra.REPO_EXCLUSION]:
            self.assertGreater(len(rule.reason), 40, rule.key)


class ScratchRepo(unittest.TestCase):
    """--apply in a small git repository shaped like this one."""

    FILES = {
        "Package.swift": 'let package = Package(name: "SortlyKit", targets: [.target(name: "SortlyCore")])\n',
        "Sources/SortlyCore/Identifiers.swift": "public struct SortlyID {}\n",
        "Sources/SortlyStore/DatabaseFile.swift": ('public static let name = "sortly.sqlite"\n'
                                                   'public static let legacyName = "sortly.sqlite"\n'),
        "App/Sortly/App/SortlyApp.swift": "import SortlyCore\n@main struct SortlyApp {}\n",
        "App/Sortly/App/AppInfo.swift": ('/// Product identity in one place. The product is called Albumist (chosen 14.11.2026); the\n'
                                         '/// bundle identifiers keep the old working name "sortly" until the App Store record exists.\n'
                                         'let url = "https://fuxinger.github.io/sortly-ios/en/privacy.html"\n'),
        "docs/NOTES.md": "Plain text, nothing to rename.\n",
        "tools/rename_albumist.py": "# the script names Sortly\n",
        "logo.bin": b"\x89PNG\x00sortly",
    }

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        for path, content in self.FILES.items():
            full = os.path.join(self.root, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(content if isinstance(content, bytes) else content.encode())
        self.git("init", "-q")
        self.git("add", "-A")
        self.commit("start")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", self.root, "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                              check=True, capture_output=True, text=True).stdout

    def commit(self, message):
        self.git("commit", "-q", "-m", message)

    def run_script(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = ra.main(["--root", self.root, *args])
        return code, out.getvalue(), err.getvalue()

    def read(self, path):
        with open(os.path.join(self.root, path), encoding="utf-8") as f:
            return f.read()

    def test_dry_run_changes_nothing_and_shows_the_plan(self):
        code, out, _ = self.run_script()
        self.assertEqual(code, 0)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertIn("App/Sortly/ -> App/Albumist/", out)
        self.assertIn("Sources/SortlyCore/ -> Sources/AlbumistCore/", out)
        self.assertIn("App/Sortly/App/SortlyApp.swift -> App/Albumist/App/AlbumistApp.swift", out)
        self.assertIn("SortlyID -> AlbumistID", out)
        self.assertIn("[legacy-database-name]", out)
        self.assertIn("logo.bin: binary file", out)
        self.assertIn("tools/rename_albumist.py: This script", out)

    def test_apply_moves_replaces_and_a_second_run_finds_nothing(self):
        code, out, err = self.run_script("--apply")
        self.assertEqual(code, 0, err)
        status = self.git("status", "--porcelain")
        self.assertIn("App/Albumist/App/AlbumistApp.swift", status)
        self.assertFalse(os.path.exists(os.path.join(self.root, "App", "Sortly")))
        self.assertEqual(self.read("App/Albumist/App/AlbumistApp.swift"), "import AlbumistCore\n@main struct AlbumistApp {}\n")
        self.assertEqual(self.read("Sources/AlbumistStore/DatabaseFile.swift"),
                         'public static let name = "albumist.sqlite"\npublic static let legacyName = "sortly.sqlite"\n')
        info = self.read("App/Albumist/App/AppInfo.swift")
        self.assertTrue(info.startswith("/// Product identity in one place. The product is called Albumist (chosen 14.11.2026).\nlet"))
        self.assertIn("github.io/sortly-ios/", info)
        self.assertEqual(self.read("tools/rename_albumist.py"), "# the script names Sortly\n")
        self.git("add", "-A")
        self.commit("rename")
        code, out, _ = self.run_script("--apply")
        self.assertEqual(code, 0)
        self.assertIn("Nothing to rename", out)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_repo_renamed_later_changes_only_the_urls(self):
        self.assertEqual(self.run_script("--apply")[0], 0)
        self.git("add", "-A")
        self.commit("rename")
        code, out, err = self.run_script("--apply", "--repo-renamed")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.git("status", "--porcelain").split(), ["M", "App/Albumist/App/AppInfo.swift"])
        self.assertIn("github.io/albumist-ios/", self.read("App/Albumist/App/AppInfo.swift"))

    def test_a_dirty_tree_is_refused(self):
        with open(os.path.join(self.root, "docs/NOTES.md"), "a") as f:
            f.write("work in progress\n")
        code, _, err = self.run_script("--apply")
        self.assertEqual(code, 2)
        self.assertIn("Refused", err)
        self.assertTrue(os.path.exists(os.path.join(self.root, "App", "Sortly", "App", "SortlyApp.swift")))
        # An untracked file counts as well.
        self.git("checkout", "--", "docs/NOTES.md")
        with open(os.path.join(self.root, "new.txt"), "w") as f:
            f.write("x\n")
        self.assertEqual(self.run_script("--apply")[0], 2)

    def test_a_target_that_exists_already_stops_the_plan(self):
        os.makedirs(os.path.join(self.root, "App", "Albumist", "App"))
        with open(os.path.join(self.root, "App", "Albumist", "App", "AlbumistApp.swift"), "w") as f:
            f.write("x\n")
        self.git("add", "-A")
        self.commit("clash")
        code, _, err = self.run_script("--apply")
        self.assertEqual(code, 1)
        self.assertIn("the target already exists", err)


class ThisRepositoryTests(unittest.TestCase):
    def test_the_plan_over_this_repository_builds(self):
        # Every spelling has a mapping and no two files land on one path; before the rename the plan
        # moves the app folder, after it the plan is empty.
        plan = ra.build_plan(str(REPO))
        if plan.moves:
            self.assertIn(("App/Sortly/Model/AppModel.swift", "App/Albumist/Model/AppModel.swift"), plan.moves)

    def test_each_rewritten_sentence_is_still_there_or_done(self):
        # A sentence changed in the meantime would otherwise get the plain mapping silently.
        for edit in ra.SPECIAL_EDITS:
            for path in (REPO / edit.path, REPO / ra.map_path(edit.path)):
                if path.exists():
                    text = path.read_text(encoding="utf-8")
                    self.assertTrue(edit.old in text or edit.new in text, edit.path)


if __name__ == "__main__":
    unittest.main()
