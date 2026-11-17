#!/usr/bin/env python3
"""Screens are opened by value on a NavigationRoot's path, never by a presented destination.

`navigationDestination(isPresented:)` and `navigationDestination(item:)` were presented again
and again inside SwiftUI's navigation updates: the main thread stood up to 352 s while the
preview or the atlas map was drawn thousands of times (UI runs 44055738268, 44066730498).
A screen that opens another one in code pushes an `AppScreen` through the `Navigator`
(App/Sortly/Views/Navigation.swift). Rules for App/Sortly (comment lines are skipped):
  1. no `navigationDestination(isPresented:` and no `navigationDestination(item:`;
  2. no `NavigationLink(value:` (rows that push a value are `PushLink`s, DECISIONS);
  3. every stack is a `NavigationRoot`: `NavigationStack` only in Navigation.swift, or on a
     line that says why with `// navigation-rule: own path (…)`.
Usage: navigation_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import pathlib
import re
import sys

RULES = [
    (re.compile(r"\.navigationDestination\(\s*(isPresented|item)\s*:"),
     "Push an AppScreen with Navigator.push(_:on:) instead of navigationDestination(isPresented:/item:)"),
    (re.compile(r"\bNavigationLink\(\s*value\s*:"),
     "Use PushLink(AppScreen) or NavigationLink { destination } label: { … } instead of NavigationLink(value:)"),
    (re.compile(r"\bNavigationStack\b"),
     "Use NavigationRoot { … } so the stack has a Navigator and the AppScreen destinations"),
]
STACK_HOME = "Navigation.swift"
OWN_PATH = "// navigation-rule: own path"


def code_part(line: str) -> str:
    """The line without a trailing `//` comment (good enough for these patterns)."""
    index = line.find("//")
    return line if index < 0 else line[:index]


def offenders(root: pathlib.Path):
    found = []
    for path in sorted((root / "App" / "Sortly").rglob("*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line.lstrip().startswith("//"):
                continue
            code = code_part(line)
            for pattern, advice in RULES:
                if not pattern.search(code):
                    continue
                if "NavigationStack" in pattern.pattern and (path.name == STACK_HOME or OWN_PATH in line):
                    continue
                found.append((f"{path.relative_to(root)}", number, advice))
    return found


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    bad = offenders(root)
    for file, line, advice in bad:
        print(f"::error file={file},line={line}::{advice}")
    print(f"NAVIGATION_CHECKED {len(bad)} offenders")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
