"""Unit tests for .github/scripts/check_strings.py: the keys the app's unit tests look up stay in
the catalog (second review of P3-09: three Mac tests still built their expected text from the
removed keys "von %lld Fotos", "%lld Orte" and "%lld Fotos von zu Hause").

Run: python3 -m unittest discover -s .github/scripts/tests -v
"""
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import check_strings  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

CATALOG = {"strings": {
    "von %lld %@ Fotos": {},
    "%lld %@ Orte": {},
    "Gleich fertig": {},
    "Abbrechen": {},
}}


def found(test_source):
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(f"{root}/App/AlbumistTests")
        with open(f"{root}/App/AlbumistTests/SomeTests.swift", "w") as f:
            f.write(test_source)
        return check_strings.missing_in_tests(root, set(CATALOG["strings"]))


class TestKeysTests(unittest.TestCase):
    def test_a_removed_key_is_found_with_its_line(self):
        src = 'import Testing\n#expect(x == String(localized: "von \\(1) Fotos"))\n'
        self.assertEqual(found(src), [("App/AlbumistTests/SomeTests.swift:2", "von # Fotos")])

    def test_the_count_pair_finds_its_key(self):
        src = ('#expect(x == String(localized: "von \\(1) \\(1.formatted()) Fotos"))\n'
               '#expect(y == String(localized: "\\(38) \\(38.formatted()) Orte"))\n')
        self.assertEqual(found(src), [])

    def test_a_text_and_a_lookup_by_key_are_checked(self):
        src = ('let a = Text("Gleich fertig")\nlet b = Text("Bald fertig")\n'
               'bundle.localizedString(forKey: "Abbrechen", value: nil, table: nil)\n'
               'bundle.localizedString(forKey: "Abbruch", value: nil, table: nil)\n')
        self.assertEqual(found(src), [("App/AlbumistTests/SomeTests.swift:2", "Bald fertig"),
                                      ("App/AlbumistTests/SomeTests.swift:4", "Abbruch")])

    def test_test_data_and_defaults_keys_are_not_texts(self):
        src = ('let page = recognizedText("Rechnung Nr. 4711")\n'
               'defaults.data(forKey: "purchases.ledger")\n'
               'let n = String(localized: "\\(count)")\n')
        self.assertEqual(found(src), [])


def found_in_app(app_source):
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(f"{root}/App/Albumist")
        with open(f"{root}/App/Albumist/SomeView.swift", "w") as f:
            f.write(app_source)
        return check_strings.missing_in_app(root, {check_strings.norm(k) for k in CATALOG["strings"]})


class MultiLineLiteralTests(unittest.TestCase):
    """A text too long for one line of code (SwiftLint's line_length) is a multi-line literal whose
    lines end in a backslash: it is the same key, and it is checked like any other."""

    def test_a_continued_literal_is_the_key_of_its_joined_lines(self):
        src = ('let a = Text("""\n'
               '    Gleich \\\n'
               '    fertig\n'
               '    """)\n'
               'let b = String(localized: """\n'
               '        von \\(n) \\(n.formatted()) \\\n'
               '        Fotos\n'
               '        """)\n')
        self.assertEqual(found_in_app(src), {})

    def test_a_continued_literal_missing_from_the_catalog_is_found(self):
        src = 'let a = Text("""\n    Bald \\\n    fertig, \"wirklich\"\n    """)\n'
        self.assertEqual(found_in_app(src), {'Bald fertig, "wirklich"': "SomeView.swift"})

    def test_a_line_break_in_a_literal_stays_in_its_key(self):
        src = 'let a = Text("""\n    Gleich\n    fertig\n    """)\n'
        self.assertEqual(found_in_app(src), {"Gleich\\nfertig": "SomeView.swift"})

    def test_the_lines_after_a_literal_keep_their_numbers(self):
        src = ('#expect(a == String(localized: """\n'
               '    Gleich \\\n'
               '    fertig\n'
               '    """))\n'
               '#expect(b == String(localized: "Bald fertig"))\n')
        self.assertEqual(found(src), [("App/AlbumistTests/SomeTests.swift:5", "Bald fertig")])


class RealRepositoryTests(unittest.TestCase):
    def test_every_key_the_app_tests_look_up_is_in_the_catalog(self):
        catalog = check_strings.load(REPO)
        missing = check_strings.missing_in_tests(REPO, set(catalog["strings"]))
        self.assertEqual(missing, [], "\n".join(f"{place} | {key}" for place, key in missing))


if __name__ == "__main__":
    unittest.main()
