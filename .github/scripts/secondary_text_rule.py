"""Finds small text in the system grey in the app's views (review P3-14).

The system grey (`.secondary`, `secondaryLabel`) reaches 3.4:1 on a white card and 3.1:1 on
the grouped background in light mode; WCAG 1.4.3 asks 4.5:1 for text below 18 pt, and the
small styles are all below it. `Theme.noteText` (`.foregroundStyle(.noteText)`) holds 4.6:1 or
more on every card, list row, grouped background and grey fill chip, in light and dark mode and
with Increase Contrast, and stays lighter than the primary text (`tests/test_secondary_text_rule.py`
computes it from the colours in Theme.swift). On the photo colour wash the darker
`Theme.secondaryText` is used instead.

The rule reads every `.foregroundStyle(…)` / `.foregroundColor(…)` that uses `.secondary`,
`Color.secondary` or `secondaryLabel`, together with its modifier chain (the line it stands on,
the lines above it while it starts with a dot, and the lines below it that start with a dot),
and reports it when that chain sets a small font: `.footnote`, `.caption`, `.caption2` or
`.subheadline`. Where the system grey is right on purpose (text the system itself draws on
its own background), the line carries `// secondary-text: system (<reason>)`.

Usage: secondary_text_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import glob
import re
import sys

FOREGROUND = re.compile(r"\.foreground(?:Style|Color)\(")
# `.secondary`, `Color.secondary`, `.secondaryLabel`; not `.secondaryText`, `.noteText` or `.secondarySystemFill`.
SYSTEM_GREY = re.compile(r"(?<![\w])(?:Color)?\.secondary(?:Label)?\b")
# Also `.font(selected ? .subheadline.weight(.semibold) : .subheadline)`.
SMALL_FONT = re.compile(r"\.font\([^)]*?(?<![\w])\.(?:footnote|caption2?|subheadline)\b")
ALLOWED = "// secondary-text: system ("


def _code(line):
    """The line without a trailing comment (keeps the allow marker out of the match)."""
    cut = line.find("//")
    return line if cut < 0 else line[:cut]


def grey_arguments(code):
    """The argument lists of the foreground calls in `code` that use the system grey.

    The argument is read up to its closing parenthesis, so the grey also counts inside
    `AnyShapeStyle(.secondary)` or `Color(uiColor: .secondaryLabel)`."""
    found = []
    for match in FOREGROUND.finditer(code):
        depth, end = 1, match.end()
        while end < len(code) and depth:
            depth += {"(": 1, ")": -1}.get(code[end], 0)
            end += 1
        argument = code[match.end():end - 1]
        if SYSTEM_GREY.search(argument):
            found.append((match.end(), end - 1))
    return found


def offenders_in(text):
    """(line, code) for each system-grey foreground whose modifier chain sets a small font."""
    lines = text.split("\n")
    found = []
    for index, line in enumerate(lines):
        if line.lstrip().startswith("//") or not grey_arguments(_code(line)):
            continue
        if ALLOWED in line:
            continue
        # The chain: up while the line is a modifier line, then the lines below that start with a dot.
        start = index
        while start > 0 and lines[start].lstrip().startswith("."):
            start -= 1
        end = index + 1
        while end < len(lines) and lines[end].lstrip().startswith("."):
            end += 1
        chain = [_code(code) for code in lines[start:end]]
        if any(SMALL_FONT.search(code) for code in chain):
            found.append((index + 1, line.strip()))
    return found


def offenders(root):
    """(file, line, code) for every small system-grey text in App/Sortly."""
    found = []
    for path in sorted(glob.glob(f"{root}/App/Sortly/**/*.swift", recursive=True)):
        with open(path, encoding="utf-8") as file:
            text = file.read()
        for line, code in offenders_in(text):
            found.append((path, line, code))
    return found


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    found = offenders(root)
    for path, line, code in found:
        print(f"SMALL_SYSTEM_GREY {path}:{line} | {code} | use .foregroundStyle(.noteText)")
    print(f"SECONDARY_TEXT_RULE {len(found)} small texts in the system grey")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
