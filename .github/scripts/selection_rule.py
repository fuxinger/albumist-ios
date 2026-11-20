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
`NO_TAB_BAR` with the reason. A view that hides the tab bar for good by design, because its own
buttons stand where the tab bar was, goes in `HIDDEN_FOR_GOOD` with the reason: for it,
`.toolbarVisibility(.hidden, for: .tabBar)` counts as hiding the tab bar while it selects.

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
# `.toolbarVisibility(…, for: …)` or the older `.toolbar(…, for: …)`, for one bar or several.
# The bar list has one way to match each text, so no input makes it backtrack (CodeQL alert 10).
TAB_BAR_VISIBILITY = re.compile(
    r"\.toolbar(?:Visibility)?\s*\(\s*((?:[^(),]|\([^()]*\))*?)\s*,\s*for\s*:\s*(\.\w+(?:\s*,\s*\.\w+)*)\s*,?\s*\)")
# `condition ? whenTrue : whenFalse`
TERNARY = re.compile(r"^(.*?)\?(.*?):(.*)$", re.DOTALL)
# Views whose bottom bar is never under the tab bar, and why.
NO_TAB_BAR: dict[str, str] = {}
# Views that hide the tab bar for good, and why: a selection there needs no tab bar of its own.
HIDDEN_FOR_GOOD: dict[str, str] = {
    "ProposalDetailView": ("the open suggestion has its two buttons where the tab bar was "
                           "(design E2, decision 6B); while it picks photos, the system bottom bar takes their place"),
}

ACTIONS_IN_BOTTOM_BAR = ("Put the actions of the selection in the system bottom bar "
                         "(ToolbarItem(placement: .bottomBar)), not in a bar of its own")
HIDE_TAB_BAR = ("Hide the tab bar while selecting, or the bottom bar lies behind it: "
                ".toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)")


def views(code: str):
    """(name, [(start offset, code)]) of each top-level type in `code`, its extensions in the same
    file included, so a toolbar moved into an extension still counts for its view (second
    review of P3-01)."""
    starts = [(m.start(), m.group(1)) for m in DECLARATION.finditer(code)]
    parts: dict[str, list[tuple[int, str]]] = {}
    for index, (start, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(code)
        parts.setdefault(name, []).append((start, code[start:end]))
    yield from parts.items()


def first(pattern, parts):
    """(offset in the file, match) of the first match of `pattern` in the parts, or None."""
    for start, body in parts:
        match = pattern.search(body)
        if match:
            return start + match.start(), match
    return None


def hides_while(argument: str, state) -> bool:
    """Whether the visibility `argument` is `.hidden` while selecting: with a selection mode the
    `.hidden` branch is the one taken while `state` is true, never a tab bar hidden for good."""
    if state is None:
        return ".hidden" in argument
    ternary = TERNARY.match(argument)
    if not ternary:
        return False
    condition, when_true, when_false = (part.strip() for part in ternary.groups())
    if re.fullmatch(rf"\(?\s*{state}\s*\)?", condition):
        return ".hidden" in when_true and ".hidden" not in when_false
    if re.fullmatch(rf"!\s*\(?\s*{state}\s*\)?", condition):
        return ".hidden" in when_false and ".hidden" not in when_true
    return False


def offenders_in(text: str):
    """(line, view, advice) for each view in the Swift source `text` that breaks a rule."""
    code = code_only(text)
    found = []
    for name, parts in views(code):
        if name in NO_TAB_BAR:
            continue
        state = first(SELECTION_STATE, parts)
        bar = first(BOTTOM_BAR, parts)
        if not state and not bar:
            continue
        line = code.count("\n", 0, (bar or state)[0]) + 1
        if state and not bar:
            found.append((line, name, ACTIONS_IN_BOTTOM_BAR))
        # A tab bar hidden for good by design (`HIDDEN_FOR_GOOD`) is hidden while selecting too.
        selecting = state[1].group(1) if state and name not in HIDDEN_FOR_GOOD else None
        hides = any(".tabBar" in re.findall(r"\.\w+", visibility.group(2))
                    and hides_while(visibility.group(1), selecting)
                    for _, body in parts for visibility in TAB_BAR_VISIBILITY.finditer(body))
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
