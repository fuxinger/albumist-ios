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
        os.makedirs(f"{root}/App/SortlyTests")
        with open(f"{root}/App/SortlyTests/SomeTests.swift", "w") as f:
            f.write(test_source)
        return check_strings.missing_in_tests(root, set(CATALOG["strings"]))


class TestKeysTests(unittest.TestCase):
    def test_a_removed_key_is_found_with_its_line(self):
        src = 'import Testing\n#expect(x == String(localized: "von \\(1) Fotos"))\n'
        self.assertEqual(found(src), [("App/SortlyTests/SomeTests.swift:2", "von # Fotos")])

    def test_the_count_pair_finds_its_key(self):
        src = ('#expect(x == String(localized: "von \\(1) \\(1.formatted()) Fotos"))\n'
               '#expect(y == String(localized: "\\(38) \\(38.formatted()) Orte"))\n')
        self.assertEqual(found(src), [])

    def test_a_text_and_a_lookup_by_key_are_checked(self):
        src = ('let a = Text("Gleich fertig")\nlet b = Text("Bald fertig")\n'
               'bundle.localizedString(forKey: "Abbrechen", value: nil, table: nil)\n'
               'bundle.localizedString(forKey: "Abbruch", value: nil, table: nil)\n')
        self.assertEqual(found(src), [("App/SortlyTests/SomeTests.swift:2", "Bald fertig"),
                                      ("App/SortlyTests/SomeTests.swift:4", "Abbruch")])

    def test_test_data_and_defaults_keys_are_not_texts(self):
        src = ('let page = recognizedText("Rechnung Nr. 4711")\n'
               'defaults.data(forKey: "purchases.ledger")\n'
               'let n = String(localized: "\\(count)")\n')
        self.assertEqual(found(src), [])


class RealRepositoryTests(unittest.TestCase):
    def test_every_key_the_app_tests_look_up_is_in_the_catalog(self):
        catalog = check_strings.load(REPO)
        missing = check_strings.missing_in_tests(REPO, set(catalog["strings"]))
        self.assertEqual(missing, [], "\n".join(f"{place} | {key}" for place, key in missing))


if __name__ == "__main__":
    unittest.main()
