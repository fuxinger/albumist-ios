"""Unit tests for .github/scripts/selection_rule.py, and the rule over the app's views
(review P3-01 = G3-04: "N aus Vorschlag entfernen" in the bottom bar lay behind the tab bar,
and the library had a floating selection bar of its own above it)."""
import os
import pathlib
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import selection_rule  # noqa: E402

REPO = pathlib.Path(HERE).parents[2]


class SelectionRuleTests(unittest.TestCase):
    def found(self, text):
        return [(view, advice) for _, view, advice in selection_rule.offenders_in(text)]

    def test_a_bottom_bar_under_the_tab_bar_is_found(self):
        src = ("struct Photos: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        Grid()\n"
               "            .toolbar {\n"
               "                if selecting {\n"
               "                    ToolbarItem(placement: .bottomBar) { Button(\"Entfernen\") {} }\n"
               "                }\n"
               "            }\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [("Photos", selection_rule.HIDE_TAB_BAR)])

    def test_the_line_of_the_bottom_bar_is_named(self):
        src = "struct A: View {\n    var body: some View {\n        X().toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n    }\n}\n"
        self.assertEqual([line for line, _, _ in selection_rule.offenders_in(src)], [3])

    def test_a_selection_with_a_bar_of_its_own_is_found(self):
        src = ("struct Library: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        Grid().safeAreaInset(edge: .bottom) { if selecting { SelectionBar() } }\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [("Library", selection_rule.ACTIONS_IN_BOTTOM_BAR),
                                           ("Library", selection_rule.HIDE_TAB_BAR)])

    def test_the_tab_bar_hidden_while_selecting_passes(self):
        src = ("struct Photos: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        Grid()\n"
               "            .toolbar { if selecting { ToolbarItem(placement: .bottomBar) { Y() } } }\n"
               "            .toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [])

    def test_a_tab_bar_hidden_for_good_does_not_count_for_a_selection(self):
        src = ("struct Photos: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        Grid()\n"
               "            .toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n"
               "            .toolbarVisibility(.hidden, for: .tabBar)\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [("Photos", selection_rule.HIDE_TAB_BAR)])

    def test_a_bottom_bar_without_selection_needs_the_tab_bar_hidden(self):
        src = ("struct Detail: View {\n"
               "    var body: some View {\n"
               "        X().toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n"
               "            .toolbarVisibility(.hidden, for: .tabBar)\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [])

    def test_a_hidden_navigation_bar_is_not_the_tab_bar(self):
        src = ("struct Photos: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        X().toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n"
               "            .toolbarVisibility(selecting ? .hidden : .visible, for: .navigationBar)\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [("Photos", selection_rule.HIDE_TAB_BAR)])

    def test_each_view_of_a_file_is_judged_on_its_own(self):
        src = ("struct Good: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        X().toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n"
               "            .toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)\n"
               "    }\n"
               "}\n"
               "\n"
               "private struct Bad: View {\n"
               "    var body: some View {\n"
               "        X().toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [("Bad", selection_rule.HIDE_TAB_BAR)])

    def test_comments_and_strings_do_not_count(self):
        src = ("struct Note: View {\n"
               "    // ToolbarItem(placement: .bottomBar) was here\n"
               "    var body: some View { Text(\"placement: .bottomBar\") }\n"
               "}\n")
        self.assertEqual(self.found(src), [])

    def test_a_toolbar_in_an_extension_counts_for_its_view(self):
        # Second review: an extension of the view was judged as a view of its own.
        src = ("struct Library: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        Grid().toolbar { if selecting { selectionActions } }\n"
               "            .toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)\n"
               "    }\n"
               "}\n"
               "\n"
               "extension Library {\n"
               "    @ToolbarContentBuilder var selectionActions: some ToolbarContent {\n"
               "        ToolbarItem(placement: .bottomBar) { Y() }\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [])

    def test_the_tab_bar_shown_while_selecting_is_found(self):
        # Second review: the inverted condition hid the tab bar only when not selecting.
        src = ("struct Photos: View {\n"
               "    @State private var selecting = false\n"
               "    var body: some View {\n"
               "        X().toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n"
               "            .toolbarVisibility(selecting ? .automatic : .hidden, for: .tabBar)\n"
               "    }\n"
               "}\n")
        self.assertEqual(self.found(src), [("Photos", selection_rule.HIDE_TAB_BAR)])

    def test_the_older_toolbar_spelling_and_several_bars_pass(self):
        for modifier in (".toolbar(selecting ? .hidden : .automatic, for: .tabBar)",
                         ".toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar, .navigationBar)",
                         ".toolbarVisibility(!selecting ? .automatic : .hidden, for: .navigationBar, .tabBar)"):
            with self.subTest(modifier):
                src = ("struct Photos: View {\n"
                       "    @State private var selecting = false\n"
                       "    var body: some View {\n"
                       "        X().toolbar { ToolbarItem(placement: .bottomBar) { Y() } }\n"
                       f"            {modifier}\n"
                       "    }\n"
                       "}\n")
                self.assertEqual(self.found(src), [])

    def test_the_apps_selections_keep_their_actions_in_view(self):
        found = selection_rule.offenders(REPO)
        self.assertEqual(found, [], "\n".join(f"{path}:{line} {view}: {advice}" for path, line, view, advice in found))


if __name__ == "__main__":
    unittest.main()
