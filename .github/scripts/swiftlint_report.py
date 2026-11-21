"""Job summary of the SwiftLint report (ci.yml, "SwiftLint report").

Usage: python3 .github/scripts/swiftlint_report.py --status N violations.json >> "$GITHUB_STEP_SUMMARY"

SwiftLint (pinned, .github/lint-tools.json) runs report-only for now: its findings do not fail the
job. The job fails only when SwiftLint itself did not work, so a broken or missing tool is seen at
once instead of reading as "no findings":
  - its exit status is neither 0 (no error-level finding) nor 2 (error-level findings);
  - its JSON report cannot be read.
The summary counts the findings by rule and by folder. The baseline SwiftLint writes in the same
run (artifact "swiftlint") is what a later step commits, so that only new findings fail.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys

RAN = (0, 2)  # SwiftLint's exit status when it linted: 2 = error-level findings exist


def folder(path: str) -> str:
    """The first two parts of a repository path ("Sources/AlbumistCore"), or the file itself."""
    if os.path.isabs(path):
        path = os.path.relpath(path)
    parts = path.replace(os.sep, "/").split("/")
    return "/".join(parts[:2]) if len(parts) > 2 else path


def summary(findings: list[dict], top: int = 25) -> str:
    severities = collections.Counter(str(f.get("severity", "")).lower() for f in findings)
    files = {f.get("file") for f in findings}
    lines = ["## SwiftLint (report only)", ""]
    if not findings:
        lines.append("No findings.")
        return "\n".join(lines) + "\n"
    lines.append(f"{len(findings)} findings in {len(files)} files: {severities.get('error', 0)} errors, "
                 f"{severities.get('warning', 0)} warnings. Nothing fails on them yet; the baseline of this run "
                 "(artifact \"swiftlint\") is the starting point for failing only on new ones.")
    by_rule = collections.Counter((f.get("rule_id", "?"), str(f.get("severity", "")).lower()) for f in findings)
    lines += ["", "| Rule | Severity | Findings |", "|---|---|---|"]
    for (rule, severity), count in by_rule.most_common(top):
        lines.append(f"| {rule} | {severity} | {count} |")
    if len(by_rule) > top:
        rest = sum(count for _, count in by_rule.most_common()[top:])
        lines.append(f"| {len(by_rule) - top} more rules | | {rest} |")
    by_folder = collections.Counter(folder(str(f.get("file", "?"))) for f in findings)
    lines += ["", "| Folder | Findings |", "|---|---|"]
    for name, count in sorted(by_folder.items(), key=lambda item: (-item[1], item[0])):
        lines.append(f"| {name} | {count} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--status", type=int, required=True, help="SwiftLint's exit status")
    parser.add_argument("report", help="SwiftLint's JSON report")
    args = parser.parse_args(argv)
    if args.status not in RAN:
        print(f"::error title=SwiftLint::SwiftLint stopped with exit status {args.status}, so it did not lint "
              "(see its output above)", file=sys.stderr)
        return 1
    try:
        with open(args.report, encoding="utf-8") as f:
            findings = json.load(f)
        if not isinstance(findings, list):
            raise ValueError("not a list")
    except (OSError, ValueError) as error:
        print(f"::error title=SwiftLint::its report {args.report} cannot be read: {error}", file=sys.stderr)
        return 1
    print(f"SWIFTLINT findings={len(findings)}", file=sys.stderr)
    sys.stdout.write(summary(findings))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
