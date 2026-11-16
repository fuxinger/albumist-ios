"""Finds ThreadSanitizer reports in test logs, prints them for the job summary and fails on any.

Used by .github/workflows/sanitize.yml (the opt-in Thread Sanitizer run):

  python3 .github/scripts/sanitizer_report.py LOG... >> "$GITHUB_STEP_SUMMARY"

Every line that contains "ThreadSanitizer:" counts: a data race, a race on a Swift access
("Swift access race"), a lock-order inversion, a use of a destroyed mutex, a FATAL or CHECK
failure of the runtime itself, and the closing "ThreadSanitizer: reported N warnings". Nothing
is suppressed. A report is the block between two "==================" lines (as TSan prints it,
with both stacks and the SUMMARY line); reports with the same SUMMARY line are shown once with
their count. Exit status 1 if any line was found, 0 otherwise (also for a missing log, which
the workflow's test step reports by itself).
"""
from __future__ import annotations

import re
import sys

MARK = "ThreadSanitizer:"
FENCE = re.compile(r"^\s*={10,}\s*$")
# xcodebuild and swift test print the runtime's lines unchanged; a timestamp or a "[n/m]" may
# precede them in some logs.
SUMMARY = re.compile(r"SUMMARY: ThreadSanitizer: (.*)$")
BLOCK_LINES = 120


def reports(text: str) -> tuple[list[list[str]], list[str]]:
    """(report blocks, lines with the mark outside any block)."""
    blocks: list[list[str]] = []
    loose: list[str] = []
    current: list[str] | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if FENCE.match(line):
            # TSan opens and closes each report with a fence (two reports: four fences).
            if current is None:
                current = []
            else:
                if any(MARK in l for l in current):
                    blocks.append(current)
                current = None
            continue
        if current is not None:
            current.append(line)
            if len(current) > 2000:  # a fence that was not TSan's: never swallow the log
                loose += [l for l in current if MARK in l]
                current = None
        elif MARK in line:
            loose.append(line)
    if current is not None:
        if any(MARK in l for l in current):
            blocks.append(current)
    return blocks, loose


def title(block: list[str]) -> str:
    for line in block:
        found = SUMMARY.search(line)
        if found:
            return found.group(1).strip()
    for line in block:
        if MARK in line:
            return line.strip()
    return "ThreadSanitizer report"


def summary(logs: dict[str, str]) -> tuple[str, int]:
    """Markdown for the job summary and the number of lines with the mark."""
    groups: dict[str, dict] = {}
    loose_all: list[str] = []
    marks = 0
    for name, text in logs.items():
        marks += sum(1 for line in text.splitlines() if MARK in line)
        blocks, loose = reports(text)
        for block in blocks:
            key = title(block)
            entry = groups.setdefault(key, {"count": 0, "block": block, "logs": set()})
            entry["count"] += 1
            entry["logs"].add(name)
        loose_all += [f"{name}: {line.strip()}" for line in loose]
    out = ["### Thread Sanitizer", ""]
    if not marks:
        out.append("No ThreadSanitizer report in " + ", ".join(f"`{n}`" for n in logs) + ".")
        return "\n".join(out) + "\n", 0
    out.append(f"**{len(groups)} distinct report(s)**, {marks} line(s) with `{MARK}` "
               f"in " + ", ".join(f"`{n}`" for n in logs) + ".")
    out.append("")
    for key, entry in sorted(groups.items(), key=lambda kv: -kv[1]["count"]):
        out.append(f"<details><summary>{entry['count']}x {escape(key)} ({', '.join(sorted(entry['logs']))})"
                   "</summary>")
        out.append("")
        out.append("```")
        block = entry["block"]
        out += block[:BLOCK_LINES]
        if len(block) > BLOCK_LINES:
            out.append(f"... {len(block) - BLOCK_LINES} more line(s) in the log")
        out.append("```")
        out.append("</details>")
        out.append("")
    if loose_all:
        out.append("Lines outside a report block:")
        out.append("")
        out.append("```")
        out += loose_all[:200]
        out.append("```")
    return "\n".join(out) + "\n", marks


def escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main(argv: list[str]) -> int:
    logs: dict[str, str] = {}
    for path in argv:
        try:
            with open(path, encoding="utf-8", errors="replace") as log:
                logs[path] = log.read()
        except OSError as error:
            print(f"::warning title=Thread Sanitizer::{path} not readable ({error})", file=sys.stderr)
    markdown, marks = summary(logs)
    print(markdown)
    if marks:
        print(f"::error title=Thread Sanitizer::{marks} line(s) with '{MARK}' (reports in the job summary)",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
