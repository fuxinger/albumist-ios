"""Unit tests for .github/scripts/suggestion_actions_rule.py, and the rule over the app's suggestion
(review P3-06: six actions in a column, the last half behind the tab bar)."""
import os
import pathlib
import sys
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import suggestion_actions_rule as rule  # noqa: E402

REPO = pathlib.Path(HERE).parents[2]

# The suggestion as built until 20.11.: six actions in a column below the card.
COLUMN = textwrap.dedent('''\
    struct ProposalDetailView: View {
        @State private var confirmOftenHere = false
        var body: some View {
            ScrollView {
                VStack {
                    Card { Text("Neues Album") }
                    actions
                    Button { showWorkshop = true } label: {
                        Label("Reise teilen oder zusammenlegen", systemImage: "scissors")
                    }
                    Button { confirmOftenHere = true } label: {
                        Label("Keine Reise, hier bin ich öfter", systemImage: "mappin.and.ellipse")
                    }
                    .confirmationDialog("Keine Reise?", isPresented: $confirmOftenHere) {
                        Button("Keine Reise, hier bin ich öfter") { answer() }
                    }
                }
            }
            .navigationTitle("Vorschlag")
        }

        private var actions: some View {
            VStack {
                Button("Album anlegen") { apply() }.buttonStyle(PrimaryButtonStyle())
                HStack {
                    Button("Anpassen") { showAdjust = true }.buttonStyle(SecondaryButtonStyle())
                    Button("Nicht jetzt") { reject() }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button { accept() } label: { Text("Auswählen und später anlegen") }
            }
        }
    }
    ''')

# Two buttons in view, the rest behind "…" at the top right.
MENU = textwrap.dedent('''\
    struct ProposalDetailView: View {
        @State private var confirmOftenHere = false
        var body: some View {
            ScrollView {
                VStack {
                    // A comment may name "Anpassen" and "Reise teilen oder zusammenlegen".
                    Card { Text("Neues Album") }
                    actions
                }
            }
            .navigationTitle("Vorschlag")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button { showAdjust = true } label: { Label("Anpassen", systemImage: "slider.horizontal.3") }
                            Button { accept() } label: { Label("Auswählen und später anlegen", systemImage: "checkmark.circle") }
                        }
                        Section {
                            Button { showWorkshop = true } label: { Label("Reise teilen oder zusammenlegen", systemImage: "scissors") }
                            Button { confirmOftenHere = true } label: {
                                Label {
                                    Text("Keine Reise, hier bin ich öfter")
                                    if let reason { Text(reason) }
                                } icon: { Image(systemName: "mappin.and.ellipse") }
                            }
                        }
                    } label: {
                        Label("Weitere Aktionen", systemImage: "ellipsis")
                    }
                }
            }
            .confirmationDialog("Keine Reise?", isPresented: $confirmOftenHere, titleVisibility: .visible) {
                Button("Keine Reise, hier bin ich öfter") { answer() }
            } message: {
                Text("Aufenthalte an diesem Ort werden keine Reisen mehr.")
            }
        }

        private var actions: some View {
            VStack {
                Button("Album anlegen") { apply() }.buttonStyle(PrimaryButtonStyle())
                Button("Nicht jetzt") { reject() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    struct AdjustProposalView: View {
        var body: some View {
            Form { Button("Neues Album wählen") {} }.navigationTitle("Anpassen")
        }
    }
    ''')


class SuggestionActionsRuleTests(unittest.TestCase):
    def advice(self, text):
        return [advice for _, advice in rule.offenders_in(text)]

    def test_six_actions_in_a_column_are_found(self):
        self.assertEqual(sorted(self.advice(COLUMN)), sorted([
            rule.TOO_MANY,
            rule.NO_MENU,
            rule.OUTSIDE.format("Anpassen"),
            rule.OUTSIDE.format("Auswählen und später anlegen"),
            rule.OUTSIDE.format("Reise teilen oder zusammenlegen"),
            # The button on the page; the one in its dialog confirms and is no action of its own.
            rule.OUTSIDE.format("Keine Reise, hier bin ich öfter"),
        ]))

    def test_the_third_large_button_is_named_by_its_line(self):
        third = COLUMN.splitlines().index('                .buttonStyle(SecondaryButtonStyle())') + 1
        self.assertIn((third, rule.TOO_MANY), rule.offenders_in(COLUMN))

    def test_two_buttons_and_the_rest_in_the_menu_pass(self):
        self.assertEqual(rule.offenders_in(MENU), [])

    def test_a_menu_in_a_property_the_toolbar_item_names_counts(self):
        named = textwrap.dedent('''\
            struct ProposalDetailView: View {
                var body: some View {
                    ScrollView { actions }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) { moreActions }
                        }
                }

                private var moreActions: some View {
                    Menu("Weitere Aktionen", systemImage: "ellipsis") {
                        Button("Anpassen") { adjust() }
                        Button("Auswählen und später anlegen") { accept() }
                        Button("Reise teilen oder zusammenlegen") { reshape() }
                        Button("Keine Reise, hier bin ich öfter") { oftenHere() }
                    }
                }

                private var actions: some View {
                    VStack {
                        Button("Album anlegen") { apply() }.buttonStyle(PrimaryButtonStyle())
                        Button("Nicht jetzt") { reject() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            ''')
        self.assertEqual(rule.offenders_in(named), [])
        # The same menu in a property the toolbar does not name is no menu at the top right.
        unnamed = named.replace("{ moreActions }", "{ EmptyView() }")
        self.assertEqual(sorted(self.advice(unnamed)),
                         sorted([rule.NO_MENU] + [rule.OUTSIDE.format(title) for title in rule.MENU_ACTIONS]))

    def test_a_menu_at_the_bottom_is_no_menu_at_the_top_right(self):
        bottom = MENU.replace("placement: .topBarTrailing", "placement: .bottomBar")
        # Its actions are outside the menu at the top right too; the dialog's button is not.
        self.assertEqual(sorted(self.advice(bottom)),
                         sorted([rule.NO_MENU] + [rule.OUTSIDE.format(title) for title in rule.MENU_ACTIONS]))

    def test_the_primary_action_placement_is_at_the_top_right_too(self):
        self.assertEqual(rule.offenders_in(MENU.replace(".topBarTrailing", ".primaryAction")), [])

    def test_an_action_left_out_of_the_menu_is_named(self):
        without = MENU.replace(
            '                        Button { showAdjust = true } label: { Label("Anpassen", systemImage: "slider.horizontal.3") }\n', "")
        self.assertEqual(self.advice(without), [rule.MISSING.format("Anpassen")])

    def test_an_action_back_on_the_page_is_found(self):
        back = MENU.replace('Button("Nicht jetzt") { reject() }',
                            'Button("Nicht jetzt") { reject() }\n            Button("Anpassen") { showAdjust = true }')
        self.assertEqual(self.advice(back), [rule.OUTSIDE.format("Anpassen")])

    def test_a_third_large_button_is_found(self):
        third = MENU.replace('Button("Nicht jetzt") { reject() }.buttonStyle(SecondaryButtonStyle())',
                             'Button("Nicht jetzt") { reject() }.buttonStyle(SecondaryButtonStyle())\n'
                             '            Button("Teilen") { share() }.buttonStyle(.borderedProminent)')
        self.assertEqual(self.advice(third), [rule.TOO_MANY])

    def test_a_card_that_asks_keeps_its_answers(self):
        card = ('Card {\n'
                '                        Text("Bist du hier öfter?")\n'
                '                        Button("Ja, hier bin ich öfter") { yes() }.buttonStyle(SecondaryButtonStyle())\n'
                '                        Button("Nein, das sind Reisen") { no() }.buttonStyle(SecondaryButtonStyle())\n'
                '                    }\n'
                '                    Card { Text("Neues Album") }')
        asked = MENU.replace('Card { Text("Neues Album") }', card, 1)
        self.assertEqual(rule.offenders_in(asked), [])

    def test_titles_in_comments_and_other_views_do_not_count(self):
        # MENU names "Anpassen" in a comment and as the title of AdjustProposalView.
        self.assertIn('// A comment may name "Anpassen"', MENU)
        self.assertEqual(rule.offenders_in(MENU), [])

    def test_an_extension_of_the_view_counts_for_it(self):
        start = MENU.index("    private var actions: some View {")
        end = MENU.index("}\n\nstruct AdjustProposalView")
        split = MENU[:start] + "}\n\nextension ProposalDetailView {\n" + MENU[start:end] + MENU[end:]
        self.assertEqual(rule.offenders_in(split), [])
        crowded = split.replace('Button("Nicht jetzt") { reject() }', 'Button("Anpassen") { adjust() }.buttonStyle(SecondaryButtonStyle())\n            Button("Nicht jetzt") { reject() }')
        self.assertEqual(sorted(self.advice(crowded)), sorted([rule.TOO_MANY, rule.OUTSIDE.format("Anpassen")]))

    def test_a_missing_view_is_reported_not_passed(self):
        self.assertEqual(self.advice("struct Other: View { var body: some View { Text(\"x\") } }\n"), [rule.NO_VIEW])

    def test_the_apps_suggestion_shows_two_buttons_and_the_rest_in_a_menu(self):
        found = rule.offenders(REPO)
        self.assertEqual(found, [], "\n".join(f"{file}:{line}: {advice}" for file, line, advice in found))


if __name__ == "__main__":
    unittest.main()
