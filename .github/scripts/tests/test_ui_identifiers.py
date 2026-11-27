"""Fixed identifiers in the UI tests (rebuild stage 2, decided by the owner 26.11.2026; guideline
docs/UI_IDENTIFIERS.md, helpers App/AlbumistUITests/UIID.swift).

A UI test that finds an element by the words on screen turns red when the wording, the language,
the text size or the layout changes, although the app is right, and each such red costs a Mac run.
These rules run on Linux in seconds:

- every fixed identifier a UI test asks for is set somewhere in the app, so a renamed or mistyped
  identifier is red here, not after 25 minutes on a Mac;
- the identifiers the app sets follow one pattern ("screen.element", lower camel case parts);
- the lookups by visible words go down, file by file: a new one needs a fixed identifier instead,
  or says with "// text:" why the words themselves are what the test checks.
"""
from __future__ import annotations

import glob
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
APP = os.path.join(ROOT, "App", "Albumist")
UI_TESTS = os.path.join(ROOT, "App", "AlbumistUITests")

# "screen.element" or "screen.element.part": lower camel case parts joined by dots.
PATTERN = re.compile(r"^[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+$")
# Looks like an identifier (dotted, no spaces): what a test asks for by identifier, not by words.
ID_SHAPED = re.compile(r"^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+$")
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
KINDS = ("buttons|staticTexts|otherElements|cells|images|switches|toggles|textFields|secureTextFields|textViews|"
         "searchFields|navigationBars|tabBars|scrollViews|collectionViews|tables|links|sheets|alerts|"
         "segmentedControls|menuItems|steppers|sliders|pickers|windows|any|keys")
SUBSCRIPT = re.compile(r"\b(?:" + KINDS + r")\[\s*\"((?:[^\"\\]|\\.)*)\"\s*\]")
MATCHING = re.compile(r"(?:matching|containing)\(\s*identifier:\s*\"((?:[^\"\\]|\\.)*)\"")
HELPER = re.compile(r"\b(?:element|elements|waitFor|tap)\(\s*id:\s*\"((?:[^\"\\]|\\.)*)\"")
LABEL = re.compile(r"\blabel\s+(?:CONTAINS|BEGINSWITH|ENDSWITH|LIKE|MATCHES|==)")
TEXT_NOTE = "// text:"

# Lookups by visible words per file on 26.11.2026 (subscripts and matching(identifier:) with words,
# and predicates on the label). The count may only go down; lower it here when a file's lookups get
# fixed identifiers (not enforced as equal, so a strand that converts lookups never turns another
# strand's branch red). A lookup with "// text:" on its line checks the words on purpose and is not
# counted (a wording test, the English texts, an alert of iOS that has no identifier of ours).
CEILING = {
    "AccessibilityUITests.swift": 15,
    "AlbumistFlowUITests.swift": 152,
    "AlbumistLockedUITests.swift": 23,
    "DeviceConditionUITests.swift": 65,
    "MapPrototypeUITests.swift": 11,
    "PerformanceUITests.swift": 1,
    "ReleaseSmokeUITests.swift": 3,
    "SearchUITests.swift": 6,
    "UITestKeyboardTip.swift": 3,
    "UITestOnboarding.swift": 12,
    "UITestSuggestions.swift": 4,
    # The design branch's files (PR #28, counted when main with this rule was merged in, 26.11.2026).
    "AlbumistLockedUITests+Counts.swift": 6,
    "FrameUITests+LongPress.swift": 7,
    "FrameUITests.swift": 3,
    "PhotoGridUITests+DragToSelect.swift": 1,
    "PhotoGridUITests+Zoom.swift": 3,
    "PhotoGridUITests.swift": 4,
    "ShowAndHandwritingUITests+Handwriting.swift": 7,
    "ShowAndHandwritingUITests.swift": 4,
    "UITestScreens+Analysis.swift": 6,
    "UITestScreens+StartPage.swift": 9,
    "UITestScreens+UnsortedAndAlbums.swift": 17,
    "UITestScreens.swift": 4,
}


def code(line: str) -> str:
    """The line without a trailing // comment (a // inside a string literal is kept)."""
    out, quoted, i = [], False, 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and quoted:
            out.append(line[i:i + 2])
            i += 2
            continue
        if ch == '"':
            quoted = not quoted
        elif not quoted and line.startswith("//", i):
            break
        out.append(ch)
        i += 1
    return "".join(out)


def swift_files(folder: str) -> list[str]:
    return sorted(glob.glob(os.path.join(folder, "**", "*.swift"), recursive=True))


def app_identifiers(files: list[str]) -> set[str]:
    """Every identifier the app sets: the string literals on a line that sets one
    (`.accessibilityIdentifier(...)`, also `a ? "x.y" : "x.z"`) or passes one on
    (`identifier: "x.y"`, `var identifier = "x.y"`)."""
    found: set[str] = set()
    for path in files:
        with open(path, encoding="utf-8") as f:
            for line in f:
                text = code(line)
                if "accessibilityIdentifier" in text or re.search(r"\bidentifier\b", text):
                    found.update(s for s in LITERAL.findall(text) if ID_SHAPED.match(s))
    return found


def asked_for(files: list[str]) -> dict[str, list[str]]:
    """Identifier-shaped keys the UI tests ask for, with where."""
    asked: dict[str, list[str]] = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                text = code(line)
                for key in SUBSCRIPT.findall(text) + MATCHING.findall(text) + HELPER.findall(text):
                    if ID_SHAPED.match(key):
                        asked.setdefault(key, []).append(f"{os.path.basename(path)}:{number}")
    return asked


def text_lookups(source: str) -> int:
    """Lookups by visible words in one file: subscripts and matching(identifier:) whose key is
    words, not an identifier, and predicates on the label; lines with "// text:" excepted."""
    count = 0
    for line in source.splitlines():
        if TEXT_NOTE in line:
            continue
        text = code(line)
        keys = SUBSCRIPT.findall(text) + MATCHING.findall(text)
        count += sum(1 for key in keys if not ID_SHAPED.match(key))
        count += len(LABEL.findall(text))
    return count


# What a UI test looks for by its words: subscripts of the element kinds and the tests' helpers
# button(...), anything(...), anything(exactly:), tabButton(...) (they match by "label CONTAINS").
# Exact: a subscript of an element kind (app.buttons["X"]) and tabButton("X") (a subscript of the
# tab bar's buttons). Part of a label: the helpers button(...), anything(...) ("label CONTAINS").
EXACT_USE = re.compile(r'(?:\b(?:' + KINDS + r')\[|\btabButton\(|anything\(exactly:\s*)\s*"((?:[^"\\]|\\.)*)"')
PART_USE = re.compile(r'\b(?:button|anything)\(\s*"((?:[^"\\]|\\.)*)"')
FORMAT = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)")
# Texts of iOS itself (no string of the app): an alert's or a popover's own parts.
SYSTEM_TEXTS = {"PopoverDismissRegion"}


NUMBER = re.compile(r"[0-9][0-9.,]*")


def normal(text: str) -> str:
    """Numbers and format places ("%lld", "3.348") as one "#", so "7 Fotos konnten" is found in
    "%lld Fotos konnten noch nicht gelesen werden"."""
    return NUMBER.sub("#", FORMAT.sub("#", text))


def app_texts() -> str:
    """Every string literal of the app's Swift and every key and value of its string catalogs
    (all languages), joined, with numbers and format places as "#" (`normal`)."""
    import json
    texts: list[str] = []
    for path in swift_files(APP):
        with open(path, encoding="utf-8") as f:
            # Code only: a text quoted in a comment is no string of the app.
            texts += [t for line in f for t in LITERAL.findall(code(line))]

    def values(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "value" and isinstance(value, str):
                    texts.append(value)
                values(value)
        elif isinstance(node, list):
            for value in node:
                values(value)
    for path in sorted(glob.glob(os.path.join(APP, "**", "*.xcstrings"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            catalog = json.load(f)
        for key, entry in catalog.get("strings", {}).items():
            texts.append(key)
            values(entry)
    return "\n".join(normal(t) for t in texts)


def missing_texts(files: list[str], blob: str) -> dict[str, list[str]]:
    """{text: ["File.swift:line"]} of every word lookup whose text is in no string of the app: a
    whole string for an exact lookup (a subscript), a part of one for "label CONTAINS" (button,
    anything). Lookups with a variable instead of a literal are not checked here."""
    whole = set(blob.split("\n"))
    missing: dict[str, list[str]] = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            for number, line in enumerate(f, 1):
                found = [(t, True) for t in EXACT_USE.findall(code(line))] + [(t, False) for t in PART_USE.findall(code(line))]
                for text, exact in found:
                    if "\\(" in text or not text.strip() or ID_SHAPED.match(text) or text in SYSTEM_TEXTS:
                        continue
                    if (normal(text) in whole) if exact else (normal(text) in blob):
                        continue
                    missing.setdefault(text, []).append(f"{os.path.basename(path)}:{number}")
    return missing


class UIIdentifierRuleTests(unittest.TestCase):
    def test_every_identifier_a_test_asks_for_is_set_in_the_app(self):
        set_in_app = app_identifiers(swift_files(APP))
        missing = {k: v for k, v in asked_for(swift_files(UI_TESTS)).items() if k not in set_in_app}
        self.assertEqual(missing, {}, "identifiers the UI tests ask for that the app never sets "
                                      "(renamed or mistyped; set it with .accessibilityIdentifier)")

    def test_the_app_identifiers_follow_one_pattern(self):
        wrong = sorted(i for i in app_identifiers(swift_files(APP)) if not PATTERN.match(i))
        self.assertEqual(wrong, [], 'identifiers are "screen.element", lower camel case parts')

    def test_lookups_by_visible_words_only_go_down(self):
        for path in swift_files(UI_TESTS):
            name = os.path.basename(path)
            with open(path, encoding="utf-8") as f:
                count = text_lookups(f.read())
            ceiling = CEILING.get(name, 0)
            with self.subTest(file=name):
                self.assertLessEqual(count, ceiling, f"{name}: {count} lookups by visible words, at most {ceiling}. "
                                     "Use a fixed identifier (app.element(id:), docs/UI_IDENTIFIERS.md), or "
                                     "add // text: <why> when the words are what the test checks.")


class UITextRuleTests(unittest.TestCase):
    """27.11. (gap of the stress run 45864829992: test12 looked for the chips "Nicht sortiert",
    "Sortiert" and "Alle" that the new design no longer had, and failed after 1.5 h on a Mac):
    every text a UI test looks for by its words is a string of the app (an exact lookup: a whole
    string; a "label CONTAINS" helper: part of one). It catches a text that left the app or was
    reworded; it would NOT have caught that case itself (those chips were looked up through a
    variable, and their words are still used elsewhere): a text that only moved to another
    screen still needs a fixed identifier (docs/UI_IDENTIFIERS.md)."""

    def test_every_text_a_ui_test_looks_for_is_in_the_app(self):
        blob = app_texts()
        self.assertIn("Beispiel-Mediathek anlegen", blob)
        missing = missing_texts(swift_files(UI_TESTS), blob)
        self.assertEqual(missing, {}, "UI tests look for texts that no string of the app has (renamed or removed? "
                                      "use a fixed identifier, docs/UI_IDENTIFIERS.md)")

    def test_finds_a_text_that_left_the_app(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "X.swift")
            with open(path, "w", encoding="utf-8") as f:
                f.write('let a = app.buttons["Nur Lieblinge"]\nlet b = button("Weiter")\nlet c = anything("3 Fotos konnten")\n'
                        'let d = app.buttons["plan.apply"]\nlet e = anything("\\(n) Fotos")\nlet f = app.buttons["Weit"]\n'
                        'let g = app.buttons["Weiter"] // app.buttons["Gone"]\n')
            blob = "\n".join(normal(t) for t in ("Weiter", "%lld Fotos konnten noch nicht gelesen werden"))
            # "Weit" is only part of a string: an exact lookup misses it; a comment is no lookup.
            self.assertEqual(missing_texts([path], blob), {"Nur Lieblinge": ["X.swift:1"], "Weit": ["X.swift:6"]})


class HelperTests(unittest.TestCase):
    def test_comment_is_cut_but_not_inside_a_string(self):
        self.assertEqual(code('app.buttons["a//b"] // note'), 'app.buttons["a//b"] ')
        self.assertEqual(code('x // y'), "x ")

    def test_counts_words_but_not_identifiers(self):
        source = "\n".join([
            'app.buttons["Weiter"].tap()',
            'app.buttons["plan.apply"].tap()',
            'app.staticTexts.matching(identifier: "Rückgängig machen")',
            'app.element(id: "viewer.position")',
            'NSPredicate(format: "label CONTAINS %@", "von")',
            'app.staticTexts["Fertig"] // text: the wording is the test',
        ])
        self.assertEqual(text_lookups(source), 3)

    def test_finds_identifiers_set_by_a_condition_or_a_variable(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "V.swift")
            with open(path, "w", encoding="utf-8") as f:
                f.write('.accessibilityIdentifier(on ? "a.on" : "a.off")\n'
                        'var identifier = "a.note"\n'
                        'Text("Hallo.Welt")\n'
                        '// .accessibilityIdentifier("a.comment")\n')
            self.assertEqual(app_identifiers([path]), {"a.on", "a.off", "a.note"})

    def test_finds_what_the_helpers_ask_for(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "T.swift")
            with open(path, "w", encoding="utf-8") as f:
                f.write('app.tap(id: "plan.apply", timeout: 10)\napp.waitFor(id: "x.y", timeout: 5)\n'
                        'app.buttons["Weiter"]\n')
            self.assertEqual(sorted(asked_for([path])), ["plan.apply", "x.y"])


if __name__ == "__main__":
    unittest.main()
