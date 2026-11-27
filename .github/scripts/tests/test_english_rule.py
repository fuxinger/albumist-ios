"""Unit tests for .github/scripts/english_rule.py, and the rule over the real catalog
(review P3-10 / G3-10: "Safe" for "Sicher", lowercase buttons, British spelling)."""
import json
import os
import pathlib
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import english_rule  # noqa: E402

REPO = pathlib.Path(HERE).parents[2]


def entry(english):
    return {"localizations": {"en": {"stringUnit": {"state": "translated", "value": english}}}}


class ButtonTitlesTests(unittest.TestCase):
    def titles(self, src):
        return [literal for _, literal in english_rule.button_titles_in(src)]

    def test_a_titled_button_is_read(self):
        self.assertEqual(self.titles('Button("Nicht jetzt") { dismiss() }'), ["Nicht jetzt"])

    def test_a_titled_button_with_a_role_is_read(self):
        self.assertEqual(self.titles('Button("Entfernen", role: .destructive) { x = 1 }'), ["Entfernen"])

    def test_both_titles_of_a_choice_are_read(self):
        self.assertEqual(self.titles('Button(selecting ? "Fertig" : "Auswählen") { toggle() }'), ["Fertig", "Auswählen"])

    def test_a_label_closure_with_one_text_is_read(self):
        src = 'Button {\n    go()\n} label: {\n    Label("Stimmt", systemImage: "checkmark")\n}\n'
        self.assertEqual(self.titles(src), ["Stimmt"])

    def test_a_role_button_with_a_label_closure_is_read(self):
        src = 'Button(role: .destructive) { confirm = true } label: { Text("\\(n) aus Vorschlag entfernen") }'
        self.assertEqual(self.titles(src), ["\\(n) aus Vorschlag entfernen"])

    def test_card_buttons_are_read(self):
        src = 'Button { pause() } label: { CardTextButton("Pause") }\nButton { a() } label: { TapTarget("Neu prüfen") }'
        self.assertEqual(sorted(self.titles(src)), ["Neu prüfen", "Pause"])

    def test_a_row_of_texts_is_not_a_title(self):
        src = 'Button { pick() } label: {\n    VStack { Text(album.title); Text("\\(n) gemeinsame Fotos") }\n}'
        self.assertEqual(self.titles(src), [])

    def test_labeled_content_is_not_a_button(self):
        src = 'LabeledContent {\n    Text("\\(n) Alben")\n} label: {\n    Text("Noch kostenlos")\n}\nButton("Code einlösen") { r = true }'
        self.assertEqual(self.titles(src), ["Code einlösen"])

    def test_a_button_without_a_title_is_skipped(self):
        self.assertEqual(self.titles('Button(action: go) { Image(systemName: "x") }'), [])


class TitleCaseTests(unittest.TestCase):
    def test_title_case_passes(self):
        for text in ["Create Album", "Not Now", "Restore Purchase", "Add to Album", "Open the Photos App",
                     "Select %lld Recommended", "Create the First %lld Now for Free", "OK", "Undo the Rest",
                     "Don’t Offer It for This Suggestion Again", "Turn On iCloud"]:
            self.assertIsNone(english_rule.title_case_problem(text), text)

    def test_lowercase_words_fail(self):
        self.assertEqual(english_rule.title_case_problem("Create album"), "album")
        self.assertEqual(english_rule.title_case_problem("Not now"), "now")
        self.assertEqual(english_rule.title_case_problem("Review %lld suggestions"), "suggestions")

    def test_a_small_word_at_the_end_is_capitalized(self):
        self.assertEqual(english_rule.title_case_problem("Sign in"), "in")


class CatalogTests(unittest.TestCase):
    def offenders(self, strings, swift):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            catalog = root / english_rule.CATALOG
            catalog.parent.mkdir(parents=True)
            catalog.write_text(json.dumps({"sourceLanguage": "de", "strings": strings}), encoding="utf-8")
            (root / "App" / "Albumist" / "Views").mkdir(parents=True, exist_ok=True)
            (root / "App" / "Albumist" / "Views" / "A.swift").write_text(swift, encoding="utf-8")
            return [(key, problem.split(" ")[0]) for key, _, problem in english_rule.offenders(root)]

    def test_safe_british_spelling_trial_run_and_take_back_are_found(self):
        found = self.offenders({"Sicher": entry("Safe"), "Läuft": entry("Analysing new photos"),
                                "Probelauf": entry("Trial run: 2024"), "Alles zurücknehmen": entry("Take Everything Back"),
                                "Fortsetzen": entry("Albumist safely continues")}, "")
        self.assertEqual(sorted(key for key, _ in found), ["Alles zurücknehmen", "Läuft", "Probelauf", "Sicher"])

    def test_a_lowercase_button_is_found_and_plain_text_is_not(self):
        found = self.offenders({"Nicht jetzt": entry("Not now"), "Hinweis": entry("Not now, later")},
                               'Button("Nicht jetzt") { }\nText("Hinweis")\n')
        self.assertEqual(found, [("Nicht jetzt", "button")])

    def test_every_plural_form_of_a_button_is_checked(self):
        plural = {"localizations": {"en": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "Review %lld Suggestion"}},
            "other": {"stringUnit": {"state": "translated", "value": "Review %lld suggestions"}}}}}}}
        found = self.offenders({"%lld Vorschläge prüfen": plural}, 'Button { } label: { Text("\\(n) Vorschläge prüfen") }')
        self.assertEqual(found, [("%lld Vorschläge prüfen", "button")])


class RealCatalogTests(unittest.TestCase):
    """The app's own catalog: what the review of 18.11. found must stay fixed."""

    @classmethod
    def setUpClass(cls):
        cls.catalog = english_rule.load_catalog(REPO)

    def english(self, key):
        return english_rule.english_values(self.catalog[key])

    def test_the_catalog_breaks_no_rule(self):
        found = english_rule.offenders(REPO)
        self.assertEqual(found, [], "\n".join(f"{k} | {v} | {p}" for k, v, p in found))

    def test_sicher_is_certain(self):
        self.assertEqual(self.english("Sicher"), ["Certain"])

    def test_the_buttons_the_review_named_are_title_case(self):
        expected = {"Album anlegen": "Create Album", "Nicht jetzt": "Not Now", "Neu prüfen": "Check Again",
                    "Kauf wiederherstellen": "Restore Purchase", "Analyse starten": "Start Analysis", "Zu Album hinzufügen": "Add to Album",
                    "Code einlösen": "Redeem Code", "Alles rückgängig machen": "Undo Everything"}
        for key, english in expected.items():
            self.assertEqual(self.english(key), [english], key)

    def test_the_review_buttons_are_found_in_the_code(self):
        keys = english_rule.button_keys(REPO)
        # "Vorschläge prüfen" is gone since design wave 1: the start page shows the suggestions itself.
        for key in ["Nicht jetzt", "Neu prüfen", "Kauf wiederherstellen", "Analyse starten",
                    "Zu Album hinzufügen", "Code einlösen", "Alles rückgängig machen", "Album anlegen"]:
            self.assertIn(key, keys)


if __name__ == "__main__":
    unittest.main()
