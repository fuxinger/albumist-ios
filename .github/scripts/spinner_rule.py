#!/usr/bin/env python3
"""Every spinner without its own text says what it waits for, or is hidden next to a text that does.

A bare `ProgressView()` is an element with no description for VoiceOver and Apple's
accessibility audit (the photo viewer's loading spinner failed the audit on a slow runner).
Rule: within the modifiers that follow it (up to 5 lines), a `ProgressView()` needs
`.accessibilityLabel(` or `.accessibilityHidden(true)`.
Usage: spinner_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import pathlib
import re
import sys

BARE = re.compile(r"\bProgressView\(\)")
OK = re.compile(r"\.accessibility(Label\(|Hidden\(true\))")


def offenders(root: pathlib.Path):
    found = []
    for path in sorted((root / "App" / "Sortly").rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines):
            if not BARE.search(line) or line.lstrip().startswith("//"):
                continue
            window = [line]
            for follow in lines[i + 1:i + 6]:
                if not follow.lstrip().startswith("."):
                    break
                window.append(follow)
            if not any(OK.search(w) for w in window):
                found.append(f"{path.relative_to(root)}:{i + 1}")
    return found


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    bad = offenders(root)
    for spot in bad:
        print(f"::error file={spot.split(':')[0]},line={spot.split(':')[1]}::Spinner without "
              "description: add .accessibilityLabel(Text(\"… wird geladen\")) or "
              ".accessibilityHidden(true) when a text beside it says what runs")
    print(f"SPINNERS_CHECKED {len(bad)} without description")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
