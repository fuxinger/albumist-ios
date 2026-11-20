"""Unit tests for .github/scripts/suggestion_actions_rule.py, and the rule over the app's suggestion
and texts (review P3-06: six actions in a column, the last half behind the tab bar; second review:
texts that sent the user to „Anpassen“ behind „…“)."""
import os
import pathlib
import sys
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import suggestion_actions_rule as rule  # noqa: E402

REPO = pathlib.Path(HERE).parents[2]

# The suggestion as built until 20.11.: six actions in a column below the card, and the album
# card's hint pointing at "Anpassen" without a way there.
COLUMN = textwrap.dedent('''\
    struct ProposalDetailView: View {
        @State private var confirmOftenHere = false
        var body: some View {
            ScrollView {
                VStack {
                    Card { Text("Neues Album") }
                    Card { matchContent }
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

        @ViewBuilder
        private var matchContent: some View {
            Text("Albumist legt ein neues Album an und ändert „Hunde“ nicht. Unter „Anpassen“ kannst du stattdessen „Hunde“ ergänzen.")
            Button { rejecting = true } label: { Text("„Hunde“ nicht mehr anbieten") }
        }
    }
    ''')

# The two buttons in view and the album card with its way to "Anpassen": members of the view.
MEMBERS = '''
    private var actions: some View {
        VStack {
            Button("Album anlegen") { apply() }.buttonStyle(PrimaryButtonStyle())
            Button("Nicht jetzt") { reject() }.buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var matchContent: some View {
        Text("Albumist legt ein neues Album an und ändert „Hunde“ nicht.")
        Button { showAdjust = true } label: { Text("Stattdessen „Hunde“ ergänzen …") }
        Button { rejecting = true } label: { Text("„Hunde“ nicht mehr anbieten") }
    }
'''

# Two buttons in view, the rest behind "…" at the top right.
MENU = textwrap.dedent('''\
    struct ProposalDetailView: View {
        @State private var confirmOftenHere = false
        var body: some View {
            ScrollView {
                VStack {
                    // A comment may name "Anpassen" and "Reise teilen oder zusammenlegen".
                    Card { Text("Neues Album") }
                    Card { matchContent }
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
                                Label("Keine Reise, hier bin ich öfter", systemImage: "mappin.and.ellipse")
                                if let reason { Text(reason) }
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
    ''') + MEMBERS + textwrap.dedent('''\
    }

    struct AdjustProposalView: View {
        var body: some View {
            Form { Button("Neues Album wählen") {} }.navigationTitle("Anpassen")
        }
    }
    ''')

# The menu in a property the toolbar item names.
NAMED = textwrap.dedent('''\
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
    ''') + MEMBERS + "}\n"


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
            # "Anpassen" on the page is no way from the album card.
            rule.NO_WAY_TO_ADJUST,
        ]))

    def test_the_third_large_button_is_named_by_its_line(self):
        third = COLUMN.splitlines().index('                .buttonStyle(SecondaryButtonStyle())') + 1
        self.assertIn((third, rule.TOO_MANY), rule.offenders_in(COLUMN))

    def test_two_buttons_and_the_rest_in_the_menu_pass(self):
        self.assertEqual(rule.offenders_in(MENU), [])

    def test_a_menu_in_a_property_the_toolbar_item_names_counts(self):
        self.assertEqual(rule.offenders_in(NAMED), [])
        # The same menu in a property the toolbar does not name is no menu at the top right.
        unnamed = NAMED.replace("{ moreActions }", "{ EmptyView() }")
        self.assertEqual(sorted(self.advice(unnamed)),
                         sorted([rule.NO_MENU] + [rule.OUTSIDE.format(title) for title in rule.MENU_ACTIONS]))

    def test_a_menu_in_a_function_the_toolbar_item_calls_counts(self):
        called = NAMED.replace("{ moreActions }", "{ moreActions() }").replace(
            "private var moreActions: some View {", "private func moreActions() -> some View {")
        self.assertIn("private func moreActions() -> some View {", called)
        self.assertEqual(rule.offenders_in(called), [])
        # A call with arguments is not followed: the menu is reported missing, never passed.
        given = called.replace("{ moreActions() }", "{ moreActions(for: proposal) }")
        self.assertIn(rule.NO_MENU, self.advice(given))

    def test_a_menu_at_the_bottom_is_no_menu_at_the_top_right(self):
        bottom = MENU.replace("placement: .topBarTrailing", "placement: .bottomBar")
        # Its actions are outside the menu at the top right too; the dialog's button is not.
        self.assertEqual(sorted(self.advice(bottom)),
                         sorted([rule.NO_MENU] + [rule.OUTSIDE.format(title) for title in rule.MENU_ACTIONS]))

    def test_the_primary_action_placement_is_at_the_top_right_too(self):
        self.assertEqual(rule.offenders_in(MENU.replace(".topBarTrailing", ".primaryAction")), [])

    def test_a_toolbar_item_group_at_the_top_right_counts(self):
        group = MENU.replace("ToolbarItem(placement: .topBarTrailing)", "ToolbarItemGroup(placement: .topBarTrailing)")
        self.assertIn("ToolbarItemGroup(", group)
        self.assertEqual(rule.offenders_in(group), [])

    def test_a_menu_with_its_content_in_the_arguments_counts(self):
        arguments = NAMED.replace('Menu("Weitere Aktionen", systemImage: "ellipsis") {', "Menu(content: {").replace(
            '            Button("Keine Reise, hier bin ich öfter") { oftenHere() }\n        }\n',
            '            Button("Keine Reise, hier bin ich öfter") { oftenHere() }\n'
            '        }, label: { Label("Weitere Aktionen", systemImage: "ellipsis") })\n')
        self.assertIn("}, label: {", arguments)
        self.assertEqual(rule.offenders_in(arguments), [])

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
        # Arguments with parentheses of their own do not hide the card.
        padded = asked.replace("Card {\n", "Card(padding: .init(top: 4)) {\n", 1)
        self.assertIn("Card(padding: .init(top: 4)) {", padded)
        self.assertEqual(rule.offenders_in(padded), [])

    def test_a_large_button_in_a_card_that_asks_nothing_counts(self):
        # Second review of P3-06: the album card asks nothing, a large button there is a third one.
        card = ('Card {\n'
                '                        Text("Neues Album")\n'
                '                        Button("Stattdessen ergänzen") { adjust() }.buttonStyle(SecondaryButtonStyle())\n'
                '                    }')
        self.assertEqual(self.advice(MENU.replace('Card { Text("Neues Album") }', card, 1)), [rule.TOO_MANY])
        # A question in a comment is no question of the card.
        commented = card.replace('Text("Neues Album")', '// Bist du hier öfter?\n                        Text("Neues Album")')
        self.assertEqual(self.advice(MENU.replace('Card { Text("Neues Album") }', commented, 1)), [rule.TOO_MANY])

    def test_the_album_card_offers_its_way_to_anpassen(self):
        line = '        Button { showAdjust = true } label: { Text("Stattdessen „Hunde“ ergänzen …") }\n'
        self.assertIn(line, MENU)
        self.assertEqual(self.advice(MENU.replace(line, "")), [rule.NO_WAY_TO_ADJUST])
        # A button there that opens something else is no way to "Anpassen".
        other = MENU.replace("Button { showAdjust = true } label: { Text(\"Stattdessen",
                             "Button { showWorkshop = true } label: { Text(\"Stattdessen")
        self.assertEqual(self.advice(other), [rule.NO_WAY_TO_ADJUST])
        # The action given as an argument counts.
        argument = MENU.replace('Button { showAdjust = true } label: { Text("Stattdessen „Hunde“ ergänzen …") }',
                                'Button(action: { showAdjust = true }) { Text("Stattdessen „Hunde“ ergänzen …") }')
        self.assertEqual(rule.offenders_in(argument), [])
        # No album card at all is reported, not passed.
        start = MENU.index("    @ViewBuilder\n    private var matchContent")
        end = MENU.index("}\n\nstruct AdjustProposalView")
        self.assertEqual(self.advice(MENU[:start] + MENU[end:]), [rule.NO_WAY_TO_ADJUST])

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

    def test_a_text_that_names_a_menu_action_says_where_it_is(self):
        source = textwrap.dedent('''\
            struct PlanReviewView: View {
                var body: some View {
                    // Ändere dazu den Vorschlag unter „Anpassen“: a comment is no text.
                    Text("Erst die markierten Punkte klären. Ändere dazu den Vorschlag unter „Anpassen“.")
                    Text("Erst die markierten Punkte klären. Das geht im Vorschlag oben rechts unter „…“ › „Anpassen“.")
                    Button("Anpassen") { adjust() }
                    Text(String(localized: "Tippe auf „Keine Reise, hier bin ich öfter“, wenn \\(place) keine Reise ist."))
                    Text("„Keine Reise“ geht, sobald die Analyse fertig ist.")
                }
            }
            ''')
        self.assertEqual(rule.text_offenders_in(source), [
            (4, rule.HIDDEN.format("Anpassen")),
            (7, rule.HIDDEN.format("Keine Reise, hier bin ich öfter")),
        ])

    def test_the_old_hint_of_the_album_card_is_found(self):
        hint = next(number for number, text in enumerate(COLUMN.splitlines(), 1) if "Unter „Anpassen“" in text)
        self.assertEqual(rule.text_offenders_in(COLUMN), [(hint, rule.HIDDEN.format("Anpassen"))])
        self.assertEqual(rule.text_offenders_in(MENU), [])

    def test_the_apps_suggestion_shows_two_buttons_and_the_rest_in_a_menu(self):
        found = rule.view_offenders(REPO)
        self.assertEqual(found, [], "\n".join(f"{file}:{line}: {advice}" for file, line, advice in found))

    def test_the_apps_texts_say_where_the_menu_actions_are(self):
        found = rule.text_offenders(REPO)
        self.assertEqual(found, [], "\n".join(f"{file}:{line}: {advice}" for file, line, advice in found))


if __name__ == "__main__":
    unittest.main()
