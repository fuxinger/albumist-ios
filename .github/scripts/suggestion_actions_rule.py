#!/usr/bin/env python3
"""A suggestion shows two large buttons; its other actions are in the "…" menu at the top right.

Review P3-06 (18.11.): a suggestion showed up to six actions in a column ("Album anlegen",
"Anpassen", "Nicht jetzt", "Auswählen und später anlegen", "Reise teilen oder zusammenlegen",
"Keine Reise, hier bin ich öfter"); the last lay half behind the tab bar (screenshot
ui-08c-trip-detail), and a user read six choices to create one album. Apple's way, as in Photos
and Files: one or two actions in view, the rest in a "…" menu in the toolbar (`Menu`). Decision 9
of 18.11. (no basket, "Auswählen" as in Photos) leaves "Anlegen" and "Nicht jetzt" on a suggestion.

Rules for `ProposalDetailView` in App/Sortly/Views/ProposalViews.swift (its extensions in the same
file count for it), read without comments (navigation_rule.code_only; titles are read from the
string literals the code has there):
  1. at most two large buttons (`PrimaryButtonStyle`, `SecondaryButtonStyle`, the system's
     `.borderedProminent` and `.glassProminent`) outside a `Card`: a card that asks a question
     ("Bist du hier öfter?") keeps its two answers;
  2. a `Menu` in a `ToolbarItem` at the top right (`placement: .topBarTrailing` or
     `.primaryAction`), written there or in a property or function of the view that the item
     names, holds every title of `MENU_ACTIONS`;
  3. no title of `MENU_ACTIONS` stands anywhere else in the view, except in a dialog
     (`.confirmationDialog`, `.alert`), whose button confirms the action of the menu.
An action that leaves the suggestion for good leaves `MENU_ACTIONS` with it (decision 9:
"Auswählen und später anlegen" goes once the list of suggestions selects as in Photos).
Not seen: a button style set once on a container of several buttons (counts once), and buttons
of a helper view in another type. In CI through test_suggestion_actions_rule.py, which runs the
rule over the app ("CI scripts (unit tests)" in ci.yml), as selection_rule.py.

Usage: suggestion_actions_rule.py <repo root>; prints offenders and exits 1 if there are any.
"""
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from navigation_rule import code_only  # noqa: E402
from selection_rule import DECLARATION  # noqa: E402

FILE = "App/Sortly/Views/ProposalViews.swift"
VIEW = "ProposalDetailView"
# The actions of a suggestion besides its two buttons, by their German titles.
MENU_ACTIONS = (
    "Anpassen",
    "Auswählen und später anlegen",
    "Reise teilen oder zusammenlegen",
    "Keine Reise, hier bin ich öfter",
)
MOST_LARGE_BUTTONS = 2

LARGE_BUTTON = re.compile(
    r"\.buttonStyle\s*\(\s*(?:PrimaryButtonStyle\s*\(\s*\)|SecondaryButtonStyle\s*\(\s*\)|\.borderedProminent|\.glassProminent)\s*\)")
CARD = re.compile(r"\bCard\b\s*(?:\([^()]*\)\s*)?\{")
TOOLBAR = re.compile(r"\.toolbar\s*\{")
TOP_RIGHT_ITEM = re.compile(r"\bToolbarItem\s*\(\s*placement\s*:\s*\.(?:topBarTrailing|primaryAction)\s*\)\s*\{")
MENU = re.compile(r"\bMenu\b")
DIALOG = re.compile(r"\.(?:confirmationDialog|alert)\s*\(")

TOO_MANY = ("More than two large buttons on the suggestion: keep \"Album anlegen\" and \"Nicht jetzt\" "
            "and put the other actions in the \"…\" menu at the top right")
NO_MENU = ("No \"…\" menu at the top right: put the other actions in a Menu in "
           "ToolbarItem(placement: .topBarTrailing)")
MISSING = "\"{}\" is missing in the \"…\" menu: every action of a suggestion stays reachable"
OUTSIDE = "\"{}\" stands on the suggestion outside the \"…\" menu"
NO_VIEW = f"{VIEW} not found in {FILE}"


def closing(code: str, start: int) -> int:
    """Index of the bracket that closes the one at `start` (comments and strings blanked)."""
    opening = code[start]
    close = {"{": "}", "(": ")", "[": "]"}[opening]
    depth = 0
    for index in range(start, len(code)):
        if code[index] == opening:
            depth += 1
        elif code[index] == close:
            depth -= 1
            if depth == 0:
                return index
    return len(code) - 1


def skip_space(code: str, index: int) -> int:
    while index < len(code) and code[index].isspace():
        index += 1
    return index


def view_ranges(code: str, name: str):
    """(start, end) of the declaration of `name` and of its extensions in `code`, each up to the
    next declaration at the start of a line (as selection_rule.views)."""
    starts = [(m.start(), m.group(1)) for m in DECLARATION.finditer(code)]
    return [(start, starts[index + 1][0] if index + 1 < len(starts) else len(code))
            for index, (start, found) in enumerate(starts) if found == name]


def inside(offset: int, ranges) -> bool:
    return any(start <= offset < end for start, end in ranges)


def card_ranges(code: str, ranges):
    found = []
    for start, end in ranges:
        for card in CARD.finditer(code, start, end):
            found.append((card.start(), closing(code, card.end() - 1) + 1))
    return found


def menus_between(code: str, start: int, end: int):
    """The content of each `Menu` between `start` and `end`: the first closure after `Menu` and its
    arguments (`Menu { … } label: { … }`, `Menu("…", systemImage: "…") { … }`)."""
    found = []
    for menu in MENU.finditer(code, start, end):
        index = skip_space(code, menu.end())
        if index < end and code[index] == "(":
            index = skip_space(code, closing(code, index) + 1)
        if index < end and code[index] == "{":
            found.append((index, closing(code, index) + 1))
    return found


def member_body(code: str, ranges, name: str):
    """(start, end) of the body of the property or function `name` of the view, or None."""
    declaration = re.compile(rf"\b(?:var|func)\s+{re.escape(name)}\b[^{{]*\{{")
    for start, end in ranges:
        found = declaration.search(code, start, end)
        if found:
            return found.end() - 1, closing(code, found.end() - 1) + 1
    return None


def top_right_menus(code: str, ranges):
    """The content of every Menu in a ToolbarItem at the top right of the view, written in the
    item or in a property or function of the view that the item names."""
    found = []
    for start, end in ranges:
        for toolbar in TOOLBAR.finditer(code, start, end):
            toolbar_end = closing(code, toolbar.end() - 1)
            for item in TOP_RIGHT_ITEM.finditer(code, toolbar.end(), toolbar_end):
                item_start, item_end = item.end(), closing(code, item.end() - 1)
                found += menus_between(code, item_start, item_end)
                named = re.fullmatch(r"\s*(?:self\.)?(\w+)\s*", code[item_start:item_end])
                body = member_body(code, ranges, named.group(1)) if named else None
                if body:
                    found += menus_between(code, *body)
    return found


def dialog_ranges(code: str, ranges):
    """Each `.confirmationDialog(…) { … }` and `.alert(…) { … }`: its arguments and the closure of
    its buttons."""
    found = []
    for start, end in ranges:
        for dialog in DIALOG.finditer(code, start, end):
            stop = closing(code, dialog.end() - 1)
            after = skip_space(code, stop + 1)
            if after < len(code) and code[after] == "{":
                stop = closing(code, after)
            found.append((dialog.start(), stop + 1))
    return found


def literals(text: str, code: str, title: str, ranges):
    """Offsets of the string literal `"title"` in the view: in code, not in a comment."""
    wanted = f'"{title}"'
    found = []
    index = text.find(wanted)
    while index >= 0:
        last = index + len(wanted) - 1
        if inside(index, ranges) and code[index] == '"' and code[last] == '"':
            found.append(index)
        index = text.find(wanted, index + 1)
    return found


def offenders_in(text: str):
    """(line, advice) for each rule the suggestion view in the Swift source `text` breaks."""
    code = code_only(text)

    def line(offset):
        return code.count("\n", 0, offset) + 1

    ranges = view_ranges(code, VIEW)
    if not ranges:
        return [(1, NO_VIEW)]
    found = []
    cards = card_ranges(code, ranges)
    large = [m.start() for start, end in ranges for m in LARGE_BUTTON.finditer(code, start, end)
             if not inside(m.start(), cards)]
    if len(large) > MOST_LARGE_BUTTONS:
        found.append((line(large[MOST_LARGE_BUTTONS]), TOO_MANY))
    menus = top_right_menus(code, ranges)
    if not menus:
        found.append((line(ranges[0][0]), NO_MENU))
    dialogs = dialog_ranges(code, ranges)
    for title in MENU_ACTIONS:
        places = literals(text, code, title, ranges)
        if menus and not any(inside(offset, menus) for offset in places):
            found.append((line(menus[0][0]), MISSING.format(title)))
        for offset in places:
            if not inside(offset, menus) and not inside(offset, dialogs):
                found.append((line(offset), OUTSIDE.format(title)))
    return sorted(found)


def offenders(root):
    """(file, line, advice) for every rule the suggestion breaks."""
    path = pathlib.Path(root) / FILE
    if not path.exists():
        return [(FILE, 1, NO_VIEW)]
    return [(FILE, line, advice) for line, advice in offenders_in(path.read_text(encoding="utf-8"))]


def main(argv) -> int:
    root = argv[1] if len(argv) > 1 else "."
    found = offenders(root)
    for file, line, advice in found:
        print(f"::error file={file},line={line}::{VIEW}: {advice}")
    print(f"SUGGESTION_ACTIONS_RULE {len(found)} offenders")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
