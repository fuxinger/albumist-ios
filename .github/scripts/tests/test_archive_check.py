"""Unit tests for .github/scripts/archive_check.py (a fake archive on disk, no Xcode).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import os
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import archive_check  # noqa: E402

SHA = "902f10142f3d6abce01921d006ef42dd2250ed70"


class ArchiveCheckTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.archive = os.path.join(self.folder.name, "Albumist.xcarchive")
        self.app = os.path.join(self.archive, "Products", "Applications", "Sortly.app")
        os.makedirs(self.app)
        self.write_app(SHA, "77", b"binary-1")

    def tearDown(self):
        self.folder.cleanup()

    def write_app(self, sha, build, binary):
        with open(os.path.join(self.app, "Info.plist"), "wb") as f:
            plistlib.dump({"AlbumistCommit": sha, "CFBundleVersion": build, "CFBundleExecutable": "Sortly"}, f,
                          fmt=plistlib.FMT_BINARY)
        with open(os.path.join(self.app, "Sortly"), "wb") as f:
            f.write(binary)

    def run_check(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = archive_check.main([self.archive, *args])
        return code, out.getvalue()

    def test_the_gated_commit_and_build_pass(self):
        self.assertEqual(self.run_check("--sha", SHA, "--build", "77")[0], 0)

    def test_another_commit_or_build_fails(self):
        code, out = self.run_check("--sha", "0" * 40, "--build", "77")
        self.assertEqual(code, 1)
        self.assertIn("::error", out)
        self.assertEqual(self.run_check("--sha", SHA, "--build", "78")[0], 1)
        self.write_app("local", "77", b"binary-1")
        self.assertEqual(self.run_check("--sha", SHA, "--build", "77")[0], 1)

    def test_the_executable_must_be_the_archived_one(self):
        code, line = self.run_check("--print-binary-hash")
        self.assertEqual(code, 0)
        info = os.path.join(self.folder.name, "build-info.txt")
        with open(info, "w") as f:
            f.write(f"sha={SHA}\nbuild=77\nxcode=Xcode-27.2-27B52\n{line}")
        self.assertEqual(self.run_check("--sha", SHA, "--build", "77", "--build-info", info)[0], 0)
        self.write_app(SHA, "77", b"binary-2")
        self.assertEqual(self.run_check("--sha", SHA, "--build", "77", "--build-info", info)[0], 1)

    def test_a_build_info_without_a_hash_fails(self):
        info = os.path.join(self.folder.name, "build-info.txt")
        with open(info, "w") as f:
            f.write(f"sha={SHA}\nbuild=77\n")
        self.assertEqual(self.run_check("--build-info", info)[0], 1)


if __name__ == "__main__":
    unittest.main()
