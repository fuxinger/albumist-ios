"""Albums are looked for by name in one way only (coordinator's rule of 27.11.2026).

Twice on 27.11. a UI test did not find an album that was there: PR 31's test08 in the night and
PR 28's test08 in UI run 45971115191. Both looked only at what was on screen, by its words and
with a few swipes up, while the shelf "Von Albumist" builds only the tiles on screen and keeps the
rest behind "Alle N". `UITestScreens.Albums.find` looks on the shelf, behind "Alle N" and under
"Deine Alben", and says where it found the album.

These rules run on Linux in seconds:

- `album.tile` is matched only in the helper's file;
- a function that opens the tab "Alben" does not look for something by a name held in a variable
  (`label CONTAINS %@", title`, `anything(title)`, ...): that is an album by name, which goes
  through `find`. Fixed words ("Zuletzt gesichert", "[0-9]+ Fotos") are not names and stay.
"""
from __future__ import annotations

import glob
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
UI_TESTS = os.path.join(ROOT, "App", "AlbumistUITests")
HELPER = "UITestScreens+UnsortedAndAlbums.swift"

FUNC = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|static|override|public|internal)\s+)*func\s+(\w+)", re.M)
ALBUMS_TAB = re.compile(r'tabButton\("Alben"\)|tabBars\.buttons\["Alben"\]|Tabs\.german\.albums')
# A lookup by a name in a variable: the predicate's argument or anything()'s is not a literal.
BY_NAME = re.compile(r'label (?:CONTAINS|BEGINSWITH|MATCHES|==)(?:\[c\])? %@", (?!")[^)]*\)'
                     r'|\banything\((?!")[a-zA-Z_][\w.]*\)'
                     r'|\bbutton\((?!")[a-zA-Z_][\w.]*\)')
TILE = re.compile(r'"album\.tile"')


def functions(text: str) -> list[tuple[str, str]]:
    """(name, body) of each function of a Swift file: from its `func` to the next one."""
    starts = [(m.start(), m.group(1)) for m in FUNC.finditer(text)]
    return [(name, text[start:(starts[i + 1][0] if i + 1 < len(starts) else len(text))])
            for i, (start, name) in enumerate(starts)]


def code(text: str) -> str:
    """The Swift text without its line comments (a "//" inside a string literal stays)."""
    lines = []
    for line in text.splitlines():
        cut = line.find("//")
        while cut >= 0 and line[:cut].count('"') % 2 == 1:
            cut = line.find("//", cut + 2)
        lines.append(line if cut < 0 else line[:cut])
    return "\n".join(lines)


def violations(name: str, text: str) -> list[str]:
    found = []
    if name != HELPER:
        for m in TILE.finditer(code(text)):
            found.append(f"{name}: \"album.tile\" outside {HELPER}; use UITestScreens.Albums.find")
        for func, body in functions(code(text)):
            if ALBUMS_TAB.search(body) and BY_NAME.search(body):
                found.append(f"{name} {func}(): opens the tab \"Alben\" and looks for a name "
                             f"({BY_NAME.search(body).group(0)}); use UITestScreens.Albums.find")
    return found


class AlbumLookupTests(unittest.TestCase):
    def test_albums_are_found_by_name_only_through_find(self):
        files = sorted(glob.glob(os.path.join(UI_TESTS, "*.swift")))
        self.assertTrue(files)
        found = []
        for path in files:
            with open(path, encoding="utf-8") as f:
                found += violations(os.path.basename(path), f.read())
        self.assertEqual(found, [], "\n".join(found))

    def test_find_looks_inside_the_tile(self):
        # The tile is a container without a label; its body says "Title, 2 Fotos". A match on the
        # tile's own label finds nothing (second review of 27.11.), so test07's "the album is gone"
        # would pass without looking.
        with open(os.path.join(UI_TESTS, HELPER), encoding="utf-8") as f:
            helper = code(f.read())
        find = helper[helper.index("static func find("):]
        self.assertRegex(find, r'matching\(identifier: "album\.tile"\)\s*\.containing\(NSPredicate')
        self.assertNotRegex(find, r'matching\(identifier: "album\.tile"\)\s*\.matching\(NSPredicate')

    def test_the_rule_sees_a_lookup_on_screen_only(self):
        old = '''
    private func albumExists(_ title: String) -> Bool {
        guard tap(tabButton("Alben"), "albums tab for \\(title)") else { return false }
        let album = anything(title)
        return album.exists
    }
'''
        self.assertEqual(len(violations("X.swift", old)), 1)
        by_predicate = old.replace("anything(title)", 'app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch')
        self.assertEqual(len(violations("X.swift", by_predicate)), 1)
        tile = 'let t = app.descendants(matching: .any).matching(identifier: "album.tile")'
        self.assertEqual(len(violations("X.swift", tile)), 1)
        self.assertEqual(violations(HELPER, tile), [])

    def test_fixed_words_and_other_tabs_stay(self):
        fixed = '''
    func history() {
        guard tap(tabButton("Alben"), "albums tab") else { return }
        let saved = anything("Zuletzt gesichert")
        let album = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+ Fotos?")).firstMatch
    }
    func elsewhere(_ title: String) {
        let row = anything(title)
    }
'''
        self.assertEqual(violations("X.swift", fixed), [])
        found = '''
    func albumExists(_ title: String) -> Bool {
        guard tap(tabButton("Alben"), "albums tab") else { return false }
        return UITestScreens.Albums.find(app, titled: title) != nil
    }
'''
        self.assertEqual(violations("X.swift", found), [])


if __name__ == "__main__":
    unittest.main()
