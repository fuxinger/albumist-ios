"""Checks that a release archive is the app of one commit, build number and Xcode (testflight.yml).

Usage: python3 archive_check.py ARCHIVE [--sha SHA --build N] [--pinned-xcode] [--build-info FILE]
                                        [--print-hashes] [--manifest FILE]

  --sha/--build      the app's Info.plist (inside ARCHIVE/Products/Applications/*.app) must say
                     AlbumistCommit = SHA and CFBundleVersion = N (set by the archive build).
  --pinned-xcode     the app's Info.plist must say DTXcodeBuild = the build of the pinned Xcode
                     in .github/toolchain.json (Xcode writes the build number of the Xcode that
                     built the app there; App Store Connect reads it too).
  --build-info FILE  the whole .app must be the one the archive job recorded in FILE:
                     "app_tree_sha256=..." (every file, see `manifest`) and "app_sha256=..."
                     (the executable alone, kept for a quick look). With --manifest FILE2 (the
                     manifest the archive job wrote), a difference names the files.
  --print-hashes     prints "app_sha256=<hex>" and "app_tree_sha256=<hex>" for build-info.txt.
  --manifest FILE    with --print-hashes: writes the manifest of the .app to FILE.
Exit 1 with ::error lines when anything differs.

What the tree hash covers, and why nothing is left out: the manifest lists every directory,
file and symbolic link under the .app by its path relative to the .app, sorted, with the
SHA-256 of each file's bytes, the owner's executable bit (tar keeps it; umask can only take
away group and other bits, which are not recorded) and each link's target (not followed). File
times, owners and extended attributes are not part of the app's content and are not recorded.
The check runs on the unsigned archive, before `xcodebuild -exportArchive` signs it, in the
upload job as in the archive job; between the two only tar and the artifact store touch it.
Code signing would change the app: it embeds a signature in every Mach-O file (the executable,
frameworks, app extensions), writes _CodeSignature/CodeResources in each bundle and adds
embedded.mobileprovision. Leaving those out would leave out the executable itself, so the
comparison is made before signing and EXCLUDED stays empty; the signed .ipa is never compared.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import os
import plistlib
import stat
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pick_simulator import pins  # noqa: E402

# Paths (relative to the .app) left out of the manifest. Empty on purpose; see the module doc.
EXCLUDED: tuple[str, ...] = ()


def find_app(archive: str) -> str:
    apps = glob.glob(os.path.join(archive, "Products", "Applications", "*.app"))
    if len(apps) != 1:
        raise SystemExit(f"::error::expected one app in {archive}/Products/Applications, found {len(apps)}")
    return apps[0]


def info_problems(info: dict, sha: str, build: str) -> list[str]:
    problems = []
    if info.get("AlbumistCommit") != sha:
        problems.append(f"the app says commit {info.get('AlbumistCommit')!r}, not {sha}")
    if str(info.get("CFBundleVersion")) != str(build):
        problems.append(f"the app has build number {info.get('CFBundleVersion')!r}, not {build}")
    return problems


def xcode_problems(info: dict, pin: dict) -> list[str]:
    if info.get("DTXcodeBuild") != pin["build"]:
        return [f"the app was built with Xcode build {info.get('DTXcodeBuild')!r}, the pinned Xcode "
                f"{pin['version']} is {pin['build']} (.github/toolchain.json)"]
    return []


def file_hash(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def binary_hash(app: str, info: dict) -> str:
    return file_hash(os.path.join(app, info["CFBundleExecutable"]))


def manifest(app: str) -> str:
    """One line per entry under `app`, sorted by path, fields separated by tabs:
    "PATH  file  x|-  SHA256", "PATH  link  TARGET" or "PATH  dir" (PATH relative to the .app,
    '/' separated)."""
    lines = []
    for root, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, app).replace(os.sep, "/")
            if rel in EXCLUDED or any(rel.startswith(e + "/") for e in EXCLUDED):
                continue
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                fields = ["link", os.readlink(path)]
            elif stat.S_ISDIR(mode):
                fields = ["dir"]
            elif stat.S_ISREG(mode):
                fields = ["file", "x" if mode & stat.S_IXUSR else "-", file_hash(path)]
            else:
                fields = ["other", f"{stat.S_IFMT(mode):o}"]
            lines.append("\t".join([rel] + fields))
    def by_path(line: str) -> bytes:
        return line.split("\t", 1)[0].encode("utf-8", "surrogateescape")
    return "".join(line + "\n" for line in sorted(lines, key=by_path))


def tree_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def recorded(build_info: str, key: str) -> str | None:
    for line in build_info.splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return None


def manifest_differences(recorded_text: str, actual_text: str, limit: int = 20) -> list[str]:
    """Paths that were added, removed or changed between two manifests (at most `limit`)."""
    def entries(text):
        return {line.split("\t", 1)[0]: line for line in text.splitlines() if line}
    before, after = entries(recorded_text), entries(actual_text)
    out = []
    for path in sorted(set(before) | set(after)):
        if path not in after:
            out.append(f"missing: {path}")
        elif path not in before:
            out.append(f"added: {path}")
        elif before[path] != after[path]:
            out.append(f"changed: {path}")
    return out[:limit] + ([f"... and {len(out) - limit} more"] if len(out) > limit else [])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--sha")
    parser.add_argument("--build")
    parser.add_argument("--pinned-xcode", action="store_true")
    parser.add_argument("--build-info")
    parser.add_argument("--print-hashes", action="store_true")
    parser.add_argument("--manifest")
    args = parser.parse_args(argv)
    app = find_app(args.archive)
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    problems = info_problems(info, args.sha, args.build) if args.sha or args.build else []
    if args.pinned_xcode:
        problems += xcode_problems(info, pins()["xcode"])
    tree = manifest(app)
    if args.build_info:
        with open(args.build_info, encoding="utf-8") as f:
            build_info = f.read()
        expected, actual = recorded(build_info, "app_sha256"), binary_hash(app, info)
        if expected != actual:
            problems.append(f"the app's executable has SHA-256 {actual}, the archive job recorded {expected}")
        expected, actual = recorded(build_info, "app_tree_sha256"), tree_hash(tree)
        if expected != actual:
            problems.append(f"the app's files have tree SHA-256 {actual}, the archive job recorded {expected}")
            if args.manifest and os.path.exists(args.manifest):
                with open(args.manifest, encoding="utf-8", errors="surrogateescape") as f:
                    problems += [f"  {d}" for d in manifest_differences(f.read(), tree)]
    for problem in problems:
        print(f"::error title=Release archive::{problem}")
    if problems:
        return 1
    if args.print_hashes:
        if args.manifest:
            with open(args.manifest, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(tree)
        print(f"app_sha256={binary_hash(app, info)}")
        print(f"app_tree_sha256={tree_hash(tree)}")
    elif args.sha or args.build_info or args.pinned_xcode:
        print(f"{os.path.basename(app)}: commit {info.get('AlbumistCommit')}, build {info.get('CFBundleVersion')}, "
              f"Xcode build {info.get('DTXcodeBuild')}"
              + (f", all {tree.count(chr(10))} entries as archived" if args.build_info else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
