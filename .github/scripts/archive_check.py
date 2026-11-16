"""Checks that a release archive is the app of one commit and build number (testflight.yml).

Usage: python3 archive_check.py ARCHIVE [--sha SHA --build N] [--build-info FILE] [--print-binary-hash]

  --sha/--build      the app's Info.plist (inside ARCHIVE/Products/Applications/*.app) must say
                     AlbumistCommit = SHA and CFBundleVersion = N (set by the archive build).
  --build-info FILE  the app's executable must have the SHA-256 that the archive job wrote to
                     FILE as "app_sha256=..." (the archive was not rebuilt or changed on the way).
  --print-binary-hash  prints "app_sha256=<hex>" for build-info.txt.
Exit 1 with ::error lines when anything differs.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import os
import plistlib
import sys


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


def binary_hash(app: str, info: dict) -> str:
    digest = hashlib.sha256()
    with open(os.path.join(app, info["CFBundleExecutable"]), "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def recorded_hash(build_info: str) -> str | None:
    for line in build_info.splitlines():
        if line.startswith("app_sha256="):
            return line.split("=", 1)[1].strip()
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--sha")
    parser.add_argument("--build")
    parser.add_argument("--build-info")
    parser.add_argument("--print-binary-hash", action="store_true")
    args = parser.parse_args(argv)
    app = find_app(args.archive)
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    problems = info_problems(info, args.sha, args.build) if args.sha or args.build else []
    if args.build_info:
        with open(args.build_info, encoding="utf-8") as f:
            expected = recorded_hash(f.read())
        actual = binary_hash(app, info)
        if expected != actual:
            problems.append(f"the app's executable has SHA-256 {actual}, the archive job recorded {expected}")
    for problem in problems:
        print(f"::error title=Release archive::{problem}")
    if problems:
        return 1
    if args.print_binary_hash:
        print(f"app_sha256={binary_hash(app, info)}")
    elif args.sha or args.build_info:
        print(f"{os.path.basename(app)}: commit {info.get('AlbumistCommit')}, build {info.get('CFBundleVersion')}"
              + (", executable as archived" if args.build_info else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
