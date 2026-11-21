"""Unit tests for .github/scripts/navigation_rule.py on small Swift files."""
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import navigation_rule  # noqa: E402


class NavigationRuleTests(unittest.TestCase):
    def check(self, files):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for name, text in files.items():
                path = root / "App" / "Albumist" / "Views" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            return [(file.split("/")[-1], line) for file, line, _ in navigation_rule.offenders(root)]

    def test_presented_destinations_are_found(self):
        found = self.check({"A.swift": "List {}\n"
                                        "    .navigationDestination(isPresented: $showPlan) {\n"
                                        "        PlanReviewView(prebuilt: plan)\n"
                                        "    }\n"
                                        "    .navigationDestination(item: $tappedCountry) { code in\n"})
        self.assertEqual(found, [("A.swift", 2), ("A.swift", 5)])

    def test_a_presented_destination_split_over_lines_is_found(self):
        self.assertEqual(self.check({"A.swift": "List {}\n    .navigationDestination(\n        isPresented: $show\n    ) {}\n"}),
                         [("A.swift", 2)])

    def test_a_presented_destination_without_a_leading_dot_is_found(self):
        self.assertEqual(self.check({"A.swift": "content\nnavigationDestination(isPresented: $show) { X() }\n"}),
                         [("A.swift", 2)])

    def test_value_links_are_found(self):
        self.assertEqual(self.check({"A.swift": "NavigationLink(value: screen) { Text(\"x\") }\n"}), [("A.swift", 1)])

    def test_a_value_link_with_a_title_is_found(self):
        self.assertEqual(self.check({"A.swift": "NavigationLink(\"Plan\", value: AppScreen.plan)\n"}), [("A.swift", 1)])

    def test_a_value_link_with_a_call_in_its_title_is_found(self):
        self.assertEqual(self.check({"A.swift": "NavigationLink(String(localized: \"Plan\"), value: x)\n"}), [("A.swift", 1)])

    def test_a_value_link_split_over_lines_is_found(self):
        self.assertEqual(self.check({"A.swift": "Section {\n    NavigationLink(\n        value: screen\n    ) { Text(\"x\") }\n}\n"}),
                         [("A.swift", 2)])

    def test_code_after_a_string_with_slashes_is_read(self):
        found = self.check({"A.swift": "let url = \"https://albumist.app\"; NavigationLink(value: x) {}\n"
                                        "Text(\"a \\(b ? \"//\" : \"c\")\").navigationDestination(isPresented: $s) {}\n"})
        self.assertEqual(found, [("A.swift", 1), ("A.swift", 2)])

    def test_a_plain_stack_is_found_outside_its_home(self):
        self.assertEqual(self.check({"A.swift": "        NavigationStack { SettingsView() }\n"}), [("A.swift", 1)])

    def test_a_comment_does_not_allow_a_stack(self):
        self.assertEqual(self.check({"A.swift": "NavigationStack(path: $p) { // navigation-rule: own path (x)\n"}),
                         [("A.swift", 1)])

    def test_value_paths_comments_and_strings_pass(self):
        found = self.check({
            "A.swift": "/// Not `navigationDestination(isPresented:)`, see NavigationStack.\n"
                       "    // .navigationDestination(item: $x)\n"
                       "/* NavigationLink(value: x)\n   /* nested */ NavigationStack { } */\n"
                       "NavigationRoot { LibraryView() }\n"
                       "root.navigationDestination(for: AppScreen.self) { $0.destination }\n"
                       "Navigator.push(.prebuiltPlan(PlanToken(plan)), on: navigator) // not navigationDestination(isPresented:)\n"
                       "Text(\"NavigationLink(value: x) and NavigationStack\")\n"
                       "let raw = #\"navigationDestination(item: \"x\")\"#\n"
                       "let long = \"\"\"\n    NavigationStack \"quoted\"\n    \"\"\"\n"
                       "NavigationLink { Detail() } label: { Text(\"value: 3\") }\n",
            "Navigation.swift": "NavigationStack(path: $navigator.path) {\n",
            "OnboardingView.swift": "NavigationStack(path: $path) {\n",
        })
        self.assertEqual(found, [])

    def test_line_numbers_survive_blanked_comments_and_strings(self):
        found = self.check({"A.swift": "/* one\ntwo */\nlet s = \"\"\"\nthree\n\"\"\"\nNavigationStack {}\n"})
        self.assertEqual(found, [("A.swift", 6)])

    def test_the_app_follows_the_rule(self):
        repo = pathlib.Path(__file__).resolve().parents[3]
        self.assertEqual(navigation_rule.offenders(repo), [])


if __name__ == "__main__":
    unittest.main()
