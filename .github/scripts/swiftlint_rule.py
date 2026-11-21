#!/usr/bin/env python3
"""SwiftLint is only loosened together with an entry in docs/IMPROVEMENTS.md.

The SwiftLint job (ci.yml, swiftlint_report.py) fails on findings beyond the committed counts in
.github/swiftlint-baseline.json. Two changes would turn it green without making the code better:
raising a count there, and switching a rule off or loosening it in .github/swiftlint.yml. Like a
longer time limit in a test (time_limit_rule.py, review P5-13), neither is silent:
  - a count that goes up, or a file and rule that are new in the baseline, needs an added row in
    docs/IMPROVEMENTS.md that says "SwiftLint gelockert" and names the file;
  - any change to .github/swiftlint.yml needs an added line there that names swiftlint.yml (its
    reason, which the file itself also carries as a comment).
Lowering counts needs nothing. The first baseline (none at the base) is the starting point.

  python3 .github/scripts/swiftlint_rule.py --base auto|<sha> [--head <sha>]
      --base auto (ci.yml): as in time_limit_rule.py, a pull request against the branch it goes
      into, a push against the commit before it; other events have no change to check.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

from time_limit_rule import auto_base, git, have

ENTRY_FILE = "docs/IMPROVEMENTS.md"
MARKER = "SwiftLint gelockert"
BASELINE = ".github/swiftlint-baseline.json"
CONFIG = ".github/swiftlint.yml"


def counts_at(sha: str, cwd: str | None = None) -> dict | None:
    try:
        text = git("show", f"{sha}:{BASELINE}", cwd=cwd)
    except RuntimeError:
        return None
    return json.loads(text)["files"]


def raised(base: dict, head: dict) -> list[tuple[str, str, int, int]]:
    """(file, rule, before, after) for every count in head above the one in base."""
    out = []
    for path, rules in sorted(head.items()):
        for rule, n in sorted(rules.items()):
            before = base.get(path, {}).get(rule, 0)
            if n > before:
                out.append((path, rule, before, n))
    return out


def added_lines(base: str, head: str, cwd: str | None = None) -> list[str]:
    diff = git("diff", "-U0", "--no-color", base, head, "--", ENTRY_FILE, cwd=cwd)
    return [line[1:] for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++")]


def check(base: str, head: str, cwd: str | None = None, out=print) -> int:
    for sha in (base, head):
        if not have(sha, cwd):
            out(f"::error title=SwiftLint rule::commit {sha} not found; the change cannot be checked")
            return 1
    added = added_lines(base, head, cwd)
    failed = False
    before, after = counts_at(base, cwd), counts_at(head, cwd)
    if before is None:
        out(f"SWIFTLINT_RULE no baseline at the base: {'first baseline' if after is not None else 'none yet'}")
    elif after is None:
        out(f"::error title=SwiftLint baseline removed::{BASELINE} is gone, so SwiftLint would only report. "
            f"Lower counts instead, or add a row with \"{MARKER}\" to {ENTRY_FILE}")
        failed = not any(MARKER in line for line in added)
    else:
        entries = [line for line in added if MARKER in line]
        for path, rule, old, new in raised(before, after):
            named = any(os.path.basename(path) in line for line in entries)
            out(f"SWIFTLINT_RULE raised {path} {rule} {old} -> {new} ({'entry' if named else 'NO ENTRY'})")
            if not named:
                failed = True
                out(f"::error file={BASELINE},title=SwiftLint baseline raised without an entry::{path} {rule} "
                    f"{old} -> {new}. Fix the finding, or add a row to {ENTRY_FILE} that says \"{MARKER}\" and "
                    f"names {os.path.basename(path)}, with the reason")
    if git("diff", "--name-only", base, head, "--", CONFIG, cwd=cwd).strip():
        named = any("swiftlint.yml" in line for line in added)
        out(f"SWIFTLINT_RULE {CONFIG} changed ({'entry' if named else 'NO ENTRY'})")
        if not named:
            failed = True
            out(f"::error file={CONFIG},title=SwiftLint settings changed without an entry::add a line to "
                f"{ENTRY_FILE} that names swiftlint.yml and says what changed and why")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", required=True, help="auto (from the CI event) or a commit")
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args(argv)
    head = git("rev-parse", args.head).strip()
    base = auto_base(head) if args.base == "auto" else args.base
    if not base:
        print(f"SWIFTLINT_RULE no change to check for event {os.environ.get('GITHUB_EVENT_NAME') or '(none)'}")
        return 0
    return check(base, head)


if __name__ == "__main__":
    sys.exit(main())
