"""Checks that a release archive is the app of one commit, build number and Xcode (testflight.yml).

Usage: python3 archive_check.py ARCHIVE [--sha SHA --build N] [--pinned-xcode]

  --sha/--build      the app's Info.plist (inside ARCHIVE/Products/Applications/*.app) must say
                     AlbumistCommit = SHA and CFBundleVersion = N (set by the archive build).
  --pinned-xcode     the app's Info.plist must say DTXcodeBuild = the build of the pinned Xcode
                     in .github/toolchain.json (Xcode writes the build number of the Xcode that
                     built the app there; App Store Connect reads it too).
Exit 1 with ::error lines when anything differs.

The TestFlight run archives, checks and exports (signs and uploads) in one job on one Mac, so
the archive never leaves that machine between the check and the upload. Until 17.11. it was
built in one job and uploaded in another, and this script also compared every file of the app
(SHA-256 manifest) across that hand-over; with one job there is nothing to compare.
"""
from __future__ import annotations

import argparse
import glob
import os
import plistlib
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pick_simulator import pins  # noqa: E402


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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--sha")
    parser.add_argument("--build")
    parser.add_argument("--pinned-xcode", action="store_true")
    args = parser.parse_args(argv)
    app = find_app(args.archive)
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    problems = info_problems(info, args.sha, args.build) if args.sha or args.build else []
    if args.pinned_xcode:
        problems += xcode_problems(info, pins()["xcode"])
    for problem in problems:
        print(f"::error title=Release archive::{problem}")
    if problems:
        return 1
    print(f"{os.path.basename(app)}: commit {info.get('AlbumistCommit')}, build {info.get('CFBundleVersion')}, "
          f"Xcode build {info.get('DTXcodeBuild')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
