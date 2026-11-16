"""Selects the pinned Xcode on a Mac job and checks it, or stops the job.

Usage: python3 .github/scripts/toolchain.py xcode [--runtime]
       python3 .github/scripts/toolchain.py id      (prints the id below, nothing else)

Every Mac job calls this instead of picking "the newest Xcode" (which on image xcode-27-arm64
20261112 is a beta, and a beta build is refused by App Store Connect). It:
  - fails when the pinned Xcode.app (.github/toolchain.json) is not on the runner, listing the
    ones that are;
  - runs `sudo xcode-select -s` on it and checks `xcodebuild -version` for the pinned version
    and build number (a symlink or an updated app with the same path fails here);
  - with --runtime, also checks that the pinned iOS simulator runtime (identifier and build) is
    installed and available, for the jobs that test on a simulator;
  - writes `id=<Xcode version and build>` to $GITHUB_OUTPUT (cache keys, build-info.txt).
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pick_simulator import pins  # noqa: E402


def xcode_problem(version_output: str, pin: dict) -> str | None:
    """Why `xcodebuild -version` does not show the pinned Xcode, or None."""
    version = re.search(r"^Xcode (\S+)", version_output, re.M)
    build = re.search(r"^Build version (\S+)", version_output, re.M)
    if not version or not build:
        return f"could not read `xcodebuild -version`: {version_output.strip()[:200]!r}"
    if (version.group(1), build.group(1)) != (pin["version"], pin["build"]):
        return (f"{pin['app']} is Xcode {version.group(1)} ({build.group(1)}), "
                f"pinned is {pin['version']} ({pin['build']})")
    return None


def runtime_problem(runtimes: dict, pin: dict) -> str | None:
    """Why `simctl list runtimes -j` does not offer the pinned runtime, or None."""
    listed = runtimes.get("runtimes", [])
    for r in listed:
        if r.get("identifier") == pin["identifier"]:
            if not r.get("isAvailable", False):
                return f"runtime {pin['identifier']} is installed but not available: {r.get('availabilityError', '?')}"
            if (r.get("version"), r.get("buildversion")) != (pin["version"], pin["build"]):
                return (f"runtime {pin['identifier']} is {r.get('version')} ({r.get('buildversion')}), "
                        f"pinned is {pin['version']} ({pin['build']})")
            return None
    offered = ", ".join(f"{r.get('identifier')} {r.get('buildversion')}" for r in listed) or "none"
    return f"runtime {pin['identifier']} is not installed (installed: {offered})"


def fail(message: str) -> int:
    print(f"::error title=Pinned toolchain::{message}. Update .github/toolchain.json on purpose.", flush=True)
    return 1


def xcode_id(pin: dict) -> str:
    return f"Xcode-{pin['version']}-{pin['build']}"


def main(argv: list[str]) -> int:
    if argv[:1] == ["id"]:
        print(xcode_id(pins()["xcode"]))
        return 0
    if not argv or argv[0] != "xcode":
        print(__doc__)
        return 2
    toolchain = pins()
    pin = toolchain["xcode"]
    if not os.path.isdir(pin["app"]):
        installed = ", ".join(sorted(glob.glob("/Applications/Xcode*.app"))) or "none"
        return fail(f"Xcode {pin['version']} ({pin['build']}) is not at {pin['app']} (installed: {installed})")
    subprocess.run(["sudo", "xcode-select", "-s", pin["app"]], check=True)
    output = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    print(output.strip())
    problem = xcode_problem(output, pin)
    if problem:
        return fail(problem)
    if "--runtime" in argv:
        listing = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"], capture_output=True, text=True).stdout
        try:
            problem = runtime_problem(json.loads(listing), toolchain["runtime"])
        except ValueError:
            problem = f"could not read `simctl list runtimes -j`: {listing.strip()[:200]!r}"
        if problem:
            return fail(problem)
        print(f"iOS simulator runtime {toolchain['runtime']['identifier']} {toolchain['runtime']['build']}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write(f"id={xcode_id(pin)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
