#!/usr/bin/env python3
"""A selection mode shows its actions in the system bottom bar, and the tab bar goes while selecting.

Review P3-01 = G3-04 (18.11.): "N aus Vorschlag entfernen" sat in `ToolbarItem(placement:
.bottomBar)` of the suggestion's photos while the tab bar stayed, so the button lay behind the
tab bar (screenshot ui-08a-suggestion-photos). The library had a floating bar of its own above
the tab bar instead (ui-16-selection). Apple's way, as in the Photos app: while selecting, the
tab bar is hidden (`.toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)`) and the
actions are in the system bottom bar.

Rules for every view (each top-level type) in App/Sortly, read without comments and string
contents (navigation_rule.code_only):
  1. a view with a selection mode (`@State … var selecting` or `isSelecting`) puts its actions
     in the system bottom bar (`placement: .bottomBar`), not in a bar of its own;
  2. a view with a `.bottomBar` toolbar, or with a selection mode, hides the tab bar while it
     selects: `.toolbarVisibility(…, for: .tabBar)` whose visibility is `.hidden` and, with a
     selection mode, depends on it (never hidden for good).
A view whose bottom bar never stands under a tab bar (one shown only in a sheet) goes in
`NO_TAB_BAR` with the reason.

Usage: selection_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from navigation_rule import code_only  # noqa: E402

# A type declared at the start of a line: one view's code runs to the next one.
DECLARATION = re.compile(
    r"^(?:@\w+\s+)*(?:(?:private|fileprivate|public|internal|final)\s+)*(?:struct|class|enum|extension|actor)\s+(\w+)",
    re.MULTILINE)
SELECTION_STATE = re.compile(r"@State\s+(?:(?:private|fileprivate)\s+)?var\s+(selecting|isSelecting)\b")
BOTTOM_BAR = re.compile(r"\bplacement\s*:\s*\.bottomBar\b")
TAB_BAR_VISIBILITY = re.compile(r"\.toolbarVisibility\s*\(\s*((?:[^()]|\([^()]*\))*?)\s*,\s*for\s*:\s*\.tabBar\s*\)")
# Views whose bottom bar is never under the tab bar, and why.
NO_TAB_BAR: dict[str, str] = {}

ACTIONS_IN_BOTTOM_BAR = ("Put the actions of the selection in the system bottom bar "
                         "(ToolbarItem(placement: .bottomBar)), not in a bar of its own")
HIDE_TAB_BAR = ("Hide the tab bar while selecting, or the bottom bar lies behind it: "
                ".toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)")


def views(code: str):
    """(name, start offset, code) of each top-level type in `code`."""
    starts = [(m.start(), m.group(1)) for m in DECLARATION.finditer(code)]
    for index, (start, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(code)
        yield name, start, code[start:end]


def offenders_in(text: str):
    """(line, view, advice) for each view in the Swift source `text` that breaks a rule."""
    code = code_only(text)
    found = []
    for name, start, body in views(code):
        if name in NO_TAB_BAR:
            continue
        state = SELECTION_STATE.search(body)
        bar = BOTTOM_BAR.search(body)
        if not state and not bar:
            continue
        line = code.count("\n", 0, start + (bar or state).start()) + 1
        if state and not bar:
            found.append((line, name, ACTIONS_IN_BOTTOM_BAR))
        hides = False
        for visibility in TAB_BAR_VISIBILITY.finditer(body):
            argument = visibility.group(1)
            if ".hidden" in argument and (not state or re.search(rf"\b{state.group(1)}\b", argument)):
                hides = True
        if not hides:
            found.append((line, name, HIDE_TAB_BAR))
    return found


def offenders(root):
    """(file, line, view, advice) for every view in App/Sortly that breaks a rule."""
    root = pathlib.Path(root)
    found = []
    for path in sorted((root / "App" / "Sortly").rglob("*.swift")):
        for line, name, advice in offenders_in(path.read_text(encoding="utf-8")):
            found.append((str(path.relative_to(root)), line, name, advice))
    return found


def main(argv) -> int:
    root = argv[1] if len(argv) > 1 else "."
    found = offenders(root)
    for file, line, name, advice in found:
        print(f"::error file={file},line={line}::{name}: {advice}")
    print(f"SELECTION_RULE {len(found)} offenders")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
