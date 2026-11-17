#!/usr/bin/env python3
"""Screens are opened by value on a NavigationRoot's path, never by a presented destination.

`navigationDestination(isPresented:)` and `navigationDestination(item:)` were presented again
and again inside SwiftUI's navigation updates: the main thread stood up to 352 s while the
preview or the atlas map was drawn thousands of times (UI runs 44055738268, 44066730498).
A screen that opens another one in code pushes an `AppScreen` through the `Navigator`
(App/Sortly/Views/Navigation.swift). Rules for every Swift file in App/Sortly, read without
comments and string contents (a small lexer: `//` inside a string is no comment), over the
whole file (a call split over lines counts too):
  1. no `navigationDestination(isPresented:` and no `navigationDestination(item:`;
  2. no `NavigationLink(…value:…)` (rows that push a value are `PushLink`s, DECISIONS);
  3. every stack is a `NavigationRoot`: `NavigationStack` only in the files of `OWN_STACKS`.
Usage: navigation_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import pathlib
import re
import sys

RULES = [
    (re.compile(r"\bnavigationDestination\s*\(\s*(?:isPresented|item)\s*:"),
     "Push an AppScreen with Navigator.push(_:on:) instead of navigationDestination(isPresented:/item:)"),
    (re.compile(r"\bNavigationLink\s*\((?:[^()]|\([^()]*\))*?\bvalue\s*:"),
     "Use PushLink(AppScreen) or NavigationLink { destination } label: { … } instead of NavigationLink(value:)"),
    (re.compile(r"\bNavigationStack\b"),
     "Use NavigationRoot { … } so the stack has a Navigator and the AppScreen destinations"),
]
STACK_RULE = 2
# Files that may make a NavigationStack, and why.
OWN_STACKS = {
    "Navigation.swift": "NavigationRoot itself",
    "OnboardingView.swift": "the onboarding pages on their own path; no PushLink there",
}

OPENING = re.compile(r'(#*)("""|")')


def code_only(text: str) -> str:
    """`text` with comments and the contents of string literals blanked (newlines kept, so
    line numbers stay). Knows `//`, nested `/* */`, "…", \"\"\"…\"\"\", raw #"…"# strings and
    `\\(…)` interpolations, whose code is kept."""
    out: list[str] = []
    stack: list[list] = []  # ["str", hashes, multiline] or ["interp", open parentheses]
    i, n = 0, len(text)

    def blank(chunk: str) -> str:
        return "".join("\n" if ch == "\n" else " " for ch in chunk)

    while i < n:
        top = stack[-1] if stack else None
        if top is None or top[0] == "interp":
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                out.append(blank(text[i:end]))
                i = end
                continue
            if text.startswith("/*", i):
                depth, j = 0, i
                while j < n:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                        if depth == 0:
                            break
                    else:
                        j += 1
                out.append(blank(text[i:j]))
                i = j
                continue
            opening = OPENING.match(text, i)
            if opening:
                stack.append(["str", len(opening.group(1)), opening.group(2) == '"""'])
                out.append(opening.group(0))
                i = opening.end()
                continue
            char = text[i]
            if top is not None:
                if char == "(":
                    top[1] += 1
                elif char == ")":
                    top[1] -= 1
                    if top[1] == 0:
                        stack.pop()
            out.append(char)
            i += 1
            continue
        hashes, multiline = top[1], top[2]
        close = ('"""' if multiline else '"') + "#" * hashes
        if text.startswith(close, i):
            stack.pop()
            out.append(close)
            i += len(close)
            continue
        escape = "\\" + "#" * hashes
        if text.startswith(escape + "(", i):
            stack.append(["interp", 1])
            out.append(escape + "(")
            i += len(escape) + 1
            continue
        if text.startswith(escape, i):
            out.append(blank(text[i:i + len(escape) + 1]))
            i += len(escape) + 1
            continue
        if text[i] == "\n" and not multiline:
            stack.pop()  # an unclosed one-line string ends with its line
        out.append(blank(text[i]))
        i += 1
    return "".join(out)


def offenders(root: pathlib.Path):
    found = []
    for path in sorted((root / "App" / "Sortly").rglob("*.swift")):
        code = code_only(path.read_text(encoding="utf-8"))
        for number, (pattern, advice) in enumerate(RULES):
            if number == STACK_RULE and path.name in OWN_STACKS:
                continue
            for match in pattern.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                found.append((f"{path.relative_to(root)}", line, advice))
    return sorted(found)


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    bad = offenders(root)
    for file, line, advice in bad:
        print(f"::error file={file},line={line}::{advice}")
    print(f"NAVIGATION_CHECKED {len(bad)} offenders")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
