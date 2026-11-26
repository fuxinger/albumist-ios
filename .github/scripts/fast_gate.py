"""Whether a commit may go to TestFlight through the fast gate (testflight.yml, gate fast).

The fast gate (the owner's decision of 26.11.2026, rule text approved by the coordinator the same
day): a build only for the owner as internal tester, in about 30 minutes: CI with every fast test
(data safety, undo and purchases included, hard time limits on macOS), the Release build smoke
test and the smoke test of the UI flow (ui_groups.SMOKE_TESTS), no 10,000-photo stress pass and no
other UI group. It never goes to external testers or the App Store.

A build that changes analysis, counting, creating or undoing albums, purchases or stored data may
never take it: then the small or the big gate applies. This script checks that by the paths that
changed since the last TestFlight build (the newest tag build-N), and it fails closed: only the
paths in ALLOWED may change. A path outside them (a new folder too) refuses the fast gate, so no
risky change can slip through because nobody listed it.

  python3 fast_gate.py check [--head HEAD]

Exit 0: allowed. Exit 1: refused (the paths are named), or no earlier build tag (nothing to
compare with). Writes a short table to $GITHUB_STEP_SUMMARY when set.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

# What may change for a fast build: what the owner sees and the map, texts, tests and documents.
# Not here, so refused: the core library (analysis, counting, plans, proposals, rules), the
# engine, the store and SQLite, the app's model and platform code (Photos, purchases, background
# work, deletion log, Vision), StoreKit, the package and project files, and the build pipeline
# itself (.github: a fast build must not be able to change its own gates).
ALLOWED = (
    "App/Albumist/Views/",
    "App/Albumist/DesignSystem/",
    "App/Albumist/Map/",
    "App/Albumist/Resources/",
    "Sources/AlbumistMap/",
    "Sources/AlbumistWorldMap/",
    "App/AlbumistUITests/",
    "App/AlbumistTests/",
    "Tests/",
    "docs/",
    "website/",
)
# Refused although under ALLOWED: what Apple reviews about data and privacy.
DENIED = ("App/Albumist/Resources/PrivacyInfo.xcprivacy",)
DOCUMENT = re.compile(r"\.md$")
TAG = re.compile(r"^build-(\d+)$")


def refused(paths: list[str]) -> list[str]:
    """The changed paths the fast gate does not allow (every path outside ALLOWED, documents
    anywhere excepted, but never a document under .github, which may hold gate text)."""
    bad = []
    for path in paths:
        if path.startswith(".github/") or path in DENIED:
            bad.append(path)
        elif DOCUMENT.search(path) or path.startswith(ALLOWED):
            continue
        else:
            bad.append(path)
    return bad


def git(*args: str) -> str:
    out = subprocess.run(["git", *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {out.stderr.strip()}")
    return out.stdout


def last_build_tag(tags: list[str]) -> str | None:
    numbered = [(int(m.group(1)), t) for t in tags if (m := TAG.match(t.strip()))]
    return max(numbered)[1] if numbered else None


def check(head: str = "HEAD", run=git, summary: str | None = None) -> int:
    tag = last_build_tag(run("tag", "--list", "build-*").splitlines())
    if tag is None:
        print("::error title=Fast gate::no earlier TestFlight build (tag build-N) to compare with; use the small or big gate")
        return 1
    paths = [p for p in run("diff", "--name-only", "--no-renames", f"{tag}..{head}").splitlines() if p.strip()]
    bad = refused(paths)
    lines = [f"### Fast gate: {len(paths)} path(s) changed since {tag}"]
    if bad:
        shown = ", ".join(bad[:20]) + (f" and {len(bad) - 20} more" if len(bad) > 20 else "")
        print(f"::error title=Fast gate refused::{len(bad)} changed path(s) outside what a fast build may "
              f"change since {tag} (analysis, counting, albums, purchases, stored data or the pipeline): {shown}. "
              "Use the small or the big gate.")
        lines += ["", "Refused, outside what a fast build may change:", ""] + [f"- `{p}`" for p in bad]
    else:
        print(f"Fast gate allowed: {len(paths)} path(s) changed since {tag}, all of them view, map, text, test or document")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("check")
    c.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    try:
        return check(args.head, summary=os.environ.get("GITHUB_STEP_SUMMARY"))
    except RuntimeError as error:
        print(f"::error title=Fast gate::{error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
