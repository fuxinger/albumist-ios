"""Counts the wall-clock time limits a Swift test run only reported (rule of 26.11.).

  python3 .github/scripts/timing_report.py LOG [LOG ...] >> "$GITHUB_STEP_SUMMARY"

In runs on a pull request (ALBUMIST_TIMING=report) an exceeded limit of TimingLimit prints
`TIMING_OVER <what>: <measured> over <limit> at <file>:<line>` instead of failing. Each such
line becomes a GitHub warning (a finding of its own, never silent) and a line of the job
summary; the count is printed even when it is 0. A missing log counts nothing (the test step
did not get that far; its own result says why). Never fails the job: the hard limits run in
the merge gate, on main, in TestFlight and at night.
"""
from __future__ import annotations

import re
import sys

TIMING_OVER = re.compile(r"TIMING_OVER (.+?)\s*$")


def reported(texts: list[str]) -> list[str]:
    """The distinct TIMING_OVER findings in the order they first appear."""
    seen: list[str] = []
    for text in texts:
        for line in text.splitlines():
            match = TIMING_OVER.search(line)
            if match and match.group(1) not in seen:
                seen.append(match.group(1))
    return seen


def main(argv: list[str]) -> int:
    texts = []
    for path in argv:
        try:
            with open(path, encoding="utf-8", errors="replace") as log:
                texts.append(log.read())
        except OSError:
            continue
    found = reported(texts)
    for finding in found:
        print(f"::warning title=Time limit exceeded (reported only, a finding)::{finding}", file=sys.stderr)
    print(f"\n**Time limits on the wall clock reported only:** {len(found)}")
    for finding in found:
        print(f"- TIMING_OVER {finding}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
