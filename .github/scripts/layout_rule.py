"""Finds SF Symbols with a fixed width in points in the app's views.

Review P3-12 / G3-07 (18.11.): in the search suggestions the symbol had `.frame(width: 24)`.
At the largest text size the symbol grows with the font, the frame does not, and the symbol
is drawn over the word next to it. A width next to text must grow with the text size:
`@ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 24` and
`.frame(width: symbolWidth)` (same width at the default size).

The rule reads every `Image(systemName: …)` and its modifier chain (the lines below it that
start with a dot) and reports a `.frame(width: <number>…)` in that chain. A symbol whose size
is fixed on purpose carries `// layout-rule: fixed (<reason>)` on the frame's line.

Usage: layout_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import glob
import re
import sys

FIXED_WIDTH = re.compile(r"\.frame\(\s*width:\s*\d+(?:\.\d+)?\s*[,)]")
ALLOWED = "// layout-rule: fixed ("


def offenders_in(text):
    """(line, code) for each SF Symbol in `text` whose modifier chain sets a width in points."""
    lines = text.split("\n")
    found = []
    for index, line in enumerate(lines):
        start = line.find("Image(systemName:")
        if start < 0:
            continue
        # The chain: the rest of this line, then each following line that starts with a dot.
        chain = [(index, line[start:])]
        following = index + 1
        while following < len(lines) and lines[following].lstrip().startswith("."):
            chain.append((following, lines[following]))
            following += 1
        for number, code in chain:
            if FIXED_WIDTH.search(code) and ALLOWED not in code:
                found.append((number + 1, code.strip()))
    return found


def offenders(root):
    """(file, line, code) for every fixed symbol width in App/Sortly."""
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
        print(f"FIXED_SYMBOL_WIDTH {path}:{line} | {code} | use a @ScaledMetric width")
    print(f"LAYOUT_RULE {len(found)} fixed symbol widths")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
