"""Unit tests for .github/scripts/archive_check.py (a fake archive on disk, no Xcode).

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import contextlib
import io
import os
import plistlib
import shutil
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
        self.app = os.path.join(self.archive, "Products", "Applications", "Sortly.app")
        os.makedirs(self.app)
        self.write_app(SHA, "77", b"binary-1")

    def tearDown(self):
        self.folder.cleanup()

    def write_app(self, sha, build, binary, xcode_build=PINNED_XCODE_BUILD):
        with open(os.path.join(self.app, "Info.plist"), "wb") as f:
            plistlib.dump({"AlbumistCommit": sha, "CFBundleVersion": build, "CFBundleExecutable": "Sortly",
                           "DTXcodeBuild": xcode_build}, f, fmt=plistlib.FMT_BINARY)
        with open(os.path.join(self.app, "Sortly"), "wb") as f:
            f.write(binary)
        os.chmod(os.path.join(self.app, "Sortly"), 0o755)

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
        info = self.record()
        self.assertEqual(self.verify(info)[0], 0)
        self.write_app(SHA, "77", b"binary-2")
        self.assertEqual(self.verify(info)[0], 1)

    def test_a_build_info_without_a_hash_fails(self):
        info = os.path.join(self.folder.name, "build-info.txt")
        with open(info, "w") as f:
            f.write(f"sha={SHA}\nbuild=77\n")
        self.assertEqual(self.run_check("--build-info", info)[0], 1)

    # The whole .app, not only its executable (review 16.11.).

    def add_bundle_content(self):
        """Resources, an embedded framework with its own executable and a symbolic link, as in a real app."""
        os.makedirs(os.path.join(self.app, "Frameworks", "Lib.framework", "Versions", "A"))
        os.makedirs(os.path.join(self.app, "de.lproj"))
        self.write(os.path.join("Frameworks", "Lib.framework", "Versions", "A", "Lib"), b"lib-binary", 0o755)
        os.symlink("Versions/A/Lib", os.path.join(self.app, "Frameworks", "Lib.framework", "Lib"))
        self.write(os.path.join("de.lproj", "Localizable.strings"), b'"a" = "b";')
        self.write("Assets.car", b"assets")
        self.write("worldmap.bin", b"map")

    def write(self, rel, data, mode=0o644):
        path = os.path.join(self.app, rel)
        with open(path, "wb") as f:
            f.write(data)
        os.chmod(path, mode)

    def record(self):
        """What the archive job does: build-info.txt with the hashes, plus the manifest."""
        self.manifest = os.path.join(self.folder.name, "app-manifest.txt")
        code, lines = self.run_check("--print-hashes", "--manifest", self.manifest)
        self.assertEqual(code, 0)
        self.assertIn("app_tree_sha256=", lines)
        info = os.path.join(self.folder.name, "build-info.txt")
        with open(info, "w") as f:
            f.write(f"sha={SHA}\nbuild=77\nxcode=Xcode-27.2-27B52\n{lines}")
        return info

    def verify(self, info):
        """What the upload job does before signing."""
        return self.run_check("--sha", SHA, "--build", "77", "--pinned-xcode", "--build-info", info,
                              "--manifest", self.manifest)

    def test_every_file_of_the_app_is_compared(self):
        self.add_bundle_content()
        info = self.record()
        self.assertEqual(self.verify(info)[0], 0)
        changes = [
            ("changed: de.lproj/Localizable.strings", lambda: self.write(os.path.join("de.lproj", "Localizable.strings"), b'"a" = "c";')),
            ("changed: Frameworks/Lib.framework/Versions/A/Lib",
             lambda: self.write(os.path.join("Frameworks", "Lib.framework", "Versions", "A", "Lib"), b"other", 0o755)),
            ("added: extra.plist", lambda: self.write("extra.plist", b"")),
            ("missing: worldmap.bin", lambda: os.remove(os.path.join(self.app, "worldmap.bin"))),
            ("changed: Assets.car", lambda: os.chmod(os.path.join(self.app, "Assets.car"), 0o755)),
            ("changed: Frameworks/Lib.framework/Lib", lambda: (
                os.remove(os.path.join(self.app, "Frameworks", "Lib.framework", "Lib")),
                os.symlink("Versions/B/Lib", os.path.join(self.app, "Frameworks", "Lib.framework", "Lib")))),
            ("added: PlugIns", lambda: os.makedirs(os.path.join(self.app, "PlugIns"))),
        ]
        for expected, change in changes:
            with self.subTest(expected):
                backup = os.path.join(self.folder.name, "backup.app")
                shutil.copytree(self.app, backup, symlinks=True)
                try:
                    change()
                    code, out = self.verify(info)
                    self.assertEqual(code, 1)
                    self.assertIn("tree SHA-256", out)
                    self.assertIn(expected, out)
                finally:
                    shutil.rmtree(self.app)
                    shutil.move(backup, self.app)
        self.assertEqual(self.verify(info)[0], 0)

    def test_the_tree_hash_is_deterministic(self):
        # Same content written in another order, with other file times and group/other bits
        # (umask after tar): the same manifest.
        self.add_bundle_content()
        first = archive_check.manifest(self.app)
        copy = os.path.join(self.folder.name, "copy", "Sortly.app")
        os.makedirs(copy)
        for rel in sorted((line.split("\t")[0] for line in first.splitlines()), reverse=True):
            source, target = os.path.join(self.app, rel), os.path.join(copy, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.islink(source):
                os.symlink(os.readlink(source), target)
            elif os.path.isdir(source):
                os.makedirs(target, exist_ok=True)
            else:
                shutil.copyfile(source, target)
                os.chmod(target, 0o700 if os.stat(source).st_mode & 0o100 else 0o600)
                os.utime(target, (1, 1))
        self.assertEqual(archive_check.manifest(copy), first)
        self.assertEqual(len(archive_check.tree_hash(first)), 64)

    def test_nothing_is_left_out(self):
        # Compared before signing, so nothing that signing changes needs to be excluded.
        self.assertEqual(archive_check.EXCLUDED, ())
        os.makedirs(os.path.join(self.app, "_CodeSignature"))
        self.write(os.path.join("_CodeSignature", "CodeResources"), b"x")
        self.write("embedded.mobileprovision", b"x")
        listed = archive_check.manifest(self.app)
        self.assertIn("_CodeSignature/CodeResources\t", listed)
        self.assertIn("embedded.mobileprovision\t", listed)

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
