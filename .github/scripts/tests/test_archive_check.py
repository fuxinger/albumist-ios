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
PINNED_XCODE_BUILD = archive_check.pins()["xcode"]["build"]


class ArchiveCheckTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.archive = os.path.join(self.folder.name, "Albumist.xcarchive")
        self.app = os.path.join(self.archive, "Products", "Applications", "Albumist.app")
        os.makedirs(self.app)
        self.write_app(SHA, "77", b"binary-1")

    def tearDown(self):
        self.folder.cleanup()

    def write_app(self, sha, build, binary, xcode_build=PINNED_XCODE_BUILD):
        with open(os.path.join(self.app, "Info.plist"), "wb") as f:
            plistlib.dump({"AlbumistCommit": sha, "CFBundleVersion": build, "CFBundleExecutable": "Albumist",
                           "DTXcodeBuild": xcode_build}, f, fmt=plistlib.FMT_BINARY)
        with open(os.path.join(self.app, "Albumist"), "wb") as f:
            f.write(binary)
        os.chmod(os.path.join(self.app, "Albumist"), 0o755)

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

    def test_the_app_must_be_built_with_the_pinned_xcode(self):
        self.assertEqual(self.run_check("--pinned-xcode")[0], 0)
        self.write_app(SHA, "77", b"binary-1", xcode_build="27E5000a")
        code, out = self.run_check("--sha", SHA, "--build", "77", "--pinned-xcode")
        self.assertEqual(code, 1)
        self.assertIn("27E5000a", out)
        self.assertIn(PINNED_XCODE_BUILD, out)
        self.write_app(SHA, "77", b"binary-1", xcode_build=None)
        self.assertEqual(self.run_check("--pinned-xcode")[0], 1)


if __name__ == "__main__":
    unittest.main()
