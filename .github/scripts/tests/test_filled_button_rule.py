"""Unit tests for .github/scripts/filled_button_rule.py, and the rule over the app's views
(design rule 3, DS-04b: at most one filled main button per page; the overview showed two full
coloured buttons at once in screenshot ui-06 of 18.11.). The counter-test of the design package
("Gegenprobe: Die Prüfung schlägt bei einer Testseite mit zwei farbigen Knöpfen an") is
`test_gegenprobe_a_test_page_with_two_filled_buttons_fails`."""
import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import filled_button_rule as rule  # noqa: E402

REPO = pathlib.Path(HERE).parents[2]

TWO_FILLED = """struct TestPage: View {
    var body: some View {
        VStack {
            Button("Anlegen") {}
                .buttonStyle(PrimaryButtonStyle())
            Button("Teilen") {}
                .buttonStyle(.borderedProminent)
        }
    }
}
"""


def files(*texts):
    """Swift files as the rule reads them: path → text, one file per text."""
    return {f"App/Albumist/Views/File{number}.swift": text for number, text in enumerate(texts)}


def page(body: str, members: str = "", name: str = "Page") -> str:
    """A view named `name` whose body is `body` (and more `members`)."""
    return f"struct {name}: View {{\n    var body: some View {{\n{body}\n    }}\n{members}}}\n"


def button(words: str, style: str = "PrimaryButtonStyle()") -> str:
    return f'Button("{words}") {{}}.buttonStyle({style})'


def together(*texts):
    """(page, [the two buttons' words]) for each pair the rule reports, from Swift `texts`."""
    app = rule.App(files(*texts))
    return [(found.label, sorted(leaf.title or leaf.name for leaf in (first, second)))
            for found, first, second in app.together()]


def advices(*texts):
    return [advice for _, _, advice in rule.offenders_in(files(*texts))]


@contextlib.contextmanager
def no_entries():
    """The rule without the app's own `TAKE_TURNS` and `SHOWN_ONCE`."""
    with mock.patch.object(rule, "TAKE_TURNS", {}), mock.patch.object(rule, "SHOWN_ONCE", {}):
        yield


def write_repo(root: pathlib.Path, sources: dict):
    for path, text in sources.items():
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")


class GegenprobeTests(unittest.TestCase):
    """The rule run as CI runs it, on a repository with a test page."""

    def run_rule(self, sources: dict):
        with tempfile.TemporaryDirectory() as folder, no_entries():
            write_repo(pathlib.Path(folder), sources)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = rule.main(["filled_button_rule.py", folder])
        return code, out.getvalue()

    def test_gegenprobe_a_test_page_with_two_filled_buttons_fails(self):
        code, out = self.run_rule({"App/Albumist/Views/TestPage.swift": TWO_FILLED})
        self.assertEqual(code, 1)
        self.assertIn("::error file=App/Albumist/Views/TestPage.swift,line=1::TestPage: „Anlegen“ "
                      "(App/Albumist/Views/TestPage.swift:5) and „Teilen“ (App/Albumist/Views/TestPage.swift:7) "
                      "can show at once.", out)
        self.assertIn("FILLED_BUTTON_RULE 1 offenders", out)

    def test_the_same_page_with_one_filled_button_passes(self):
        text = TWO_FILLED.replace(".buttonStyle(.borderedProminent)", ".buttonStyle(SecondaryButtonStyle())")
        code, out = self.run_rule({"App/Albumist/Views/TestPage.swift": text})
        self.assertEqual((code, out.strip()), (0, "FILLED_BUTTON_RULE 0 offenders"))

    def test_the_advice_says_how_to_fix_it(self):
        found = advices(TWO_FILLED)
        self.assertEqual(len(found), 1)
        self.assertIn("make one of them SecondaryButtonStyle(), or CardActionButtonStyle() on a card", found[0])
        self.assertIn("TAKE_TURNS of filled_button_rule.py", found[0])


class FilledStyleTests(unittest.TestCase):
    def test_every_filled_style_counts(self):
        for name in rule.FILLED_STYLES:
            style = name if name.startswith(".") else name + "()"
            with self.subTest(style=style):
                text = page(f'VStack {{ {button("Anlegen")}\n{button("Teilen", style)} }}')
                self.assertEqual(together(text), [("Page", ["Anlegen", "Teilen"])])

    def test_no_other_style_counts(self):
        for name in rule.NOT_FILLED:
            style = name if name.startswith(".") else name + "()"
            with self.subTest(style=style):
                text = page(f'VStack {{ {button("Anlegen")}\n{button("Teilen", style)} }}')
                self.assertEqual(advices(text), [])

    def test_the_two_lists_do_not_overlap(self):
        self.assertEqual(set(rule.FILLED_STYLES) & set(rule.NOT_FILLED), set())

    def test_a_button_without_a_style_is_not_filled(self):
        self.assertEqual(advices(page(f'VStack {{ {button("Anlegen")}\nButton("Teilen") {{}} }}')), [])

    def test_a_style_on_a_container_fills_every_button_in_it(self):
        text = page('HStack {\n    Button("Teilen") {}\n    Button("Anlegen") {}\n}\n.buttonStyle(PrimaryButtonStyle())')
        self.assertEqual(together(text), [("Page", ["Anlegen", "Teilen"])])

    def test_a_buttons_own_style_wins_over_its_containers(self):
        text = page('HStack {\n    Button("Teilen") {}.buttonStyle(.plain)\n    Button("Anlegen") {}\n}\n'
                    '.buttonStyle(PrimaryButtonStyle())')
        self.assertEqual(advices(text), [])

    def test_a_style_on_an_app_view_fills_its_buttons(self):
        card = page('Button("Ausprobieren") {}', name="OfferCard")
        text = page(f'VStack {{ OfferCard().buttonStyle(.borderedProminent)\n{button("Anlegen")} }}')
        self.assertEqual(together(card, text), [("Page", ["Anlegen", "Ausprobieren"])])

    def test_the_toolbars_confirmation_counts(self):
        text = page('NavigationStack {\n'
                    f'    Form {{ {button("Speichern")} }}\n'
                    '        .toolbar {\n'
                    '            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") {} }\n'
                    '            ToolbarItem(placement: .confirmationAction) { Button("Fertig") {} }\n'
                    '        }\n'
                    '}')
        self.assertEqual(together(text), [("Page", ["Fertig", "Speichern"])])

    def test_a_toolbar_with_a_cancellation_beside_the_main_button_passes(self):
        text = page(f'NavigationStack {{\n    Form {{ {button("Speichern")} }}\n'
                    '        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") {} } }\n}')
        self.assertEqual(advices(text), [])

    def test_a_button_with_the_confirm_role_counts(self):
        text = page(f'VStack {{\n    Button("Sichern", role: .confirm) {{}}\n    {button("Anlegen")}\n}}')
        self.assertEqual(together(text), [("Page", ["Anlegen", "Sichern"])])

    def test_a_filled_menu_is_one_button_and_its_items_are_the_systems(self):
        text = page(f'VStack {{\n    {button("Anlegen")}\n'
                    '    Menu("Mehr") { Button("Teilen") {}; Button("Kopieren") {} }.buttonStyle(.borderedProminent)\n}')
        self.assertEqual(together(text), [("Page", ["Anlegen", "Mehr"])])
        around = page('HStack {\n    Button("Anlegen") {}\n    Menu { Button("Teilen") {} } label: { Text("Mehr") }\n}\n'
                      '.buttonStyle(PrimaryButtonStyle())')
        self.assertEqual(together(around), [("Page", ["Anlegen", "Mehr"])])
        plain = page(f'VStack {{\n    {button("Anlegen")}\n    Menu("Mehr") {{ Button("Teilen") {{}} }}\n}}')
        self.assertEqual(advices(plain), [])

    def test_comments_and_strings_are_not_read(self):
        text = page('VStack {\n'
                    '    // Button("Alt") {}.buttonStyle(PrimaryButtonStyle())\n'
                    '    Text(".buttonStyle(PrimaryButtonStyle())")\n'
                    '    /* Button("Auch alt") {}.buttonStyle(.borderedProminent) */\n'
                    f'    {button("Anlegen")}\n'
                    '}')
        self.assertEqual(advices(text), [])


class SameTimeTests(unittest.TestCase):
    def test_the_branches_of_an_if_show_one_at_a_time(self):
        text = page('VStack {\n    if ready {\n'
                    f'        {button("Anlegen")}\n'
                    '    } else if waiting {\n'
                    f'        {button("Weiter")}\n'
                    '    } else {\n'
                    f'        {button("Einstellungen öffnen")}\n'
                    '    }\n}')
        self.assertEqual(advices(text), [])

    def test_two_ifs_add_up(self):
        text = page(f'VStack {{\n    if ready {{ {button("Anlegen")} }}\n    if waiting {{ {button("Weiter")} }}\n}}')
        self.assertEqual(together(text), [("Page", ["Anlegen", "Weiter"])])

    def test_a_button_beside_an_if_adds_up_with_each_branch(self):
        text = page(f'VStack {{\n    if ready {{ {button("Anlegen")} }} else {{ {button("Weiter")} }}\n'
                    f'    {button("Teilen")}\n}}')
        self.assertEqual(together(text), [("Page", ["Anlegen", "Teilen"]), ("Page", ["Teilen", "Weiter"])])

    def test_the_cases_of_a_switch_show_one_at_a_time(self):
        text = page('switch state {\n'
                    f'case .ready:\n    {button("Anlegen")}\n'
                    f'case .waiting, .paused:\n    {button("Weiter")}\n'
                    f'default:\n    {button("Neu prüfen")}\n'
                    '}')
        self.assertEqual(advices(text), [])

    def test_the_views_of_a_view_that_fits_show_one_at_a_time(self):
        text = page('ViewThatFits {\n'
                    f'    HStack {{ {button("Anlegen")} }}\n'
                    f'    VStack {{ {button("Anlegen")} }}\n'
                    '}')
        self.assertEqual(advices(text), [])

    def test_a_bool_given_where_the_view_is_used_picks_its_branch(self):
        unlock = ('struct UnlockButton: View {\n'
                  '    var prominent = false\n'
                  '    var body: some View {\n'
                  '        if prominent {\n'
                  '            Button("Freischalten") {}.buttonStyle(PrimaryButtonStyle())\n'
                  '        } else {\n'
                  '            Button("Freischalten") {}.buttonStyle(SecondaryButtonStyle())\n'
                  '        }\n'
                  '    }\n'
                  '}\n')
        sheet = page("UnlockButton(prominent: true)", name="UnlockSheet")
        settings = page(f'VStack {{\n    {button("Sichern")}\n    UnlockButton()\n}}', name="Settings")
        self.assertEqual(advices(unlock, sheet, settings), [])
        prominent = settings.replace("UnlockButton()", "UnlockButton(prominent: true)")
        self.assertEqual(together(unlock, sheet, prominent), [("Settings", ["Freischalten", "Sichern"])])

    def test_every_row_of_a_list_shows_its_button(self):
        for body in (f'List {{\n    ForEach(items) {{ item in\n        {button("Anlegen")}\n    }}\n}}',
                     f'List(items) {{ item in\n    {button("Anlegen")}\n}}'):
            with self.subTest(body=body.split("\n")[0]):
                found = rule.offenders_in(files(page(body)))
                self.assertEqual(len(found), 1)
                self.assertIn("Page: „Anlegen“ (App/Albumist/Views/File0.swift:", found[0][2])
                self.assertIn("shows in every row of a list", found[0][2])

    def test_a_list_without_data_shows_its_buttons_once(self):
        self.assertEqual(advices(page(f'List {{\n    {button("Anlegen")}\n}}')), [])

    def test_a_list_row_whose_button_shows_once_passes_with_its_reason(self):
        big = page(button("Alben anlegen"), name="StarterSetCard")
        sections = page('VStack {\n    ForEach(sections) { section in\n        StarterSetCard()\n    }\n}',
                        name="StartSections")
        with no_entries():
            self.assertEqual(len(advices(big, sections)), 1)
            with mock.patch.object(rule, "SHOWN_ONCE", {("StartSections.body", "StarterSetCard.body"): ("why", [])}):
                self.assertEqual(advices(big, sections), [])
            # The entry is for that list only.
            with mock.patch.object(rule, "SHOWN_ONCE", {("Other.body", "StarterSetCard.body"): ("why", [])}):
                self.assertEqual(len(advices(big, sections)), 1)


class PageTests(unittest.TestCase):
    def test_a_sheet_is_a_page_of_its_own(self):
        for presentation in ("sheet(isPresented: $showing)", "fullScreenCover(isPresented: $showing)",
                             "popover(isPresented: $showing)", "sheet(item: $item)",
                             "navigationDestination(isPresented: $showing)", "inspector(isPresented: $showing)"):
            word = presentation.split("(")[0]
            with self.subTest(presentation=word):
                one = page(f'{button("Anlegen")}\n    .{presentation} {{\n        {button("Freischalten")}\n    }}')
                self.assertEqual(advices(one), [])
                two = page(f'{button("Anlegen")}\n    .{presentation} {{\n        VStack {{\n'
                           f'            {button("Freischalten")}\n            {button("Kaufen")}\n        }}\n    }}')
                found = rule.offenders_in(files(two))
                self.assertEqual([(path, line) for path, line, _ in found], [("App/Albumist/Views/File0.swift", 4)])
                self.assertIn(f"Page: .{word}: „Freischalten“", found[0][2])

    def test_a_sheet_of_a_view_that_takes_turns_is_still_its_own_page(self):
        with no_entries():
            text = page(f'VStack {{ {button("Anlegen")} }}\n    .sheet(isPresented: $showing) {{ UnlockSheet() }}')
            sheet = page(button("Freischalten"), name="UnlockSheet")
            self.assertEqual(advices(text, sheet), [])

    def test_navigation_destinations_and_tabs_are_pages_of_their_own(self):
        detail = page(button("Anlegen"), name="Detail")
        for body in ('NavigationLink { Detail() } label: { Text("Mehr") }',
                     'NavigationLink("Mehr", destination: Detail())',
                     'TabView {\n    Tab("Start", systemImage: "house") { Detail() }\n'
                     '    Tab("Alben", systemImage: "square.stack") { Detail() }\n}'):
            with self.subTest(body=body.split("\n")[0]):
                text = page(f'VStack {{\n    {button("Teilen")}\n    {body}\n}}')
                self.assertEqual(advices(detail, text), [])

    def test_alerts_dialogs_and_context_menus_count_nowhere(self):
        text = page('VStack {\n'
                    f'    {button("Löschen")}\n'
                    '    Text("Foto").contextMenu { Button("Kopieren", role: .confirm) {} }\n'
                    '}\n'
                    '.alert("Löschen?", isPresented: $asking) { Button("Löschen", role: .confirm) {} }\n'
                    '.confirmationDialog("Wirklich?", isPresented: $asking) { Button("Ja", role: .confirm) {} }\n'
                    '.swipeActions { Button("Weg", role: .confirm) {} }')
        self.assertEqual(advices(text), [])

    def test_views_from_other_files_add_up(self):
        card = page(button("Mit Beispielfotos ausprobieren"), name="EmptyLibraryCard")
        start = page(f'VStack {{\n    EmptyLibraryCard()\n    {button("Rest anlegen")}\n}}', name="Overview")
        found = rule.offenders_in(files(card, start))
        self.assertEqual([(path, line) for path, line, _ in found], [("App/Albumist/Views/File1.swift", 1)])
        self.assertIn("Overview: „Mit Beispielfotos ausprobieren“ (App/Albumist/Views/File0.swift:3) and "
                      "„Rest anlegen“ (App/Albumist/Views/File1.swift:5) can show at once", found[0][2])
        tinted = card.replace("PrimaryButtonStyle()", "CardActionButtonStyle()")
        self.assertEqual(advices(tinted, start), [])

    def test_a_pair_is_reported_once_at_the_smallest_page(self):
        start = page(f'VStack {{\n    {button("Anlegen")}\n    {button("Teilen")}\n}}', name="Start")
        root = page("NavigationStack { Start() }", name="Root")
        found = rule.offenders_in(files(root, start))
        self.assertEqual([(path, line) for path, line, _ in found], [("App/Albumist/Views/File1.swift", 1)])
        self.assertTrue(found[0][2].startswith("Start: "))

    def test_properties_functions_and_extensions_in_other_files_are_followed(self):
        review = page("ScrollView { content }\n    .safeAreaInset(edge: .bottom) { applyBar }",
                      members=f'    var content: some View {{ row(1) }}\n'
                              f'    @ViewBuilder func row(_ number: Int) -> some View {{ {button("Öffnen", ".borderedProminent")} }}\n',
                      name="Review")
        extension = f'extension Review {{\n    var applyBar: some View {{\n        {button("Anlegen")}\n    }}\n}}\n'
        self.assertEqual(together(review, extension), [("Review", ["Anlegen", "Öffnen"])])

    def test_a_local_of_the_same_name_is_not_the_views_property(self):
        text = page('VStack {\n    ForEach(items) { finished in Text(finished.title) }\n'
                    f'    {button("Teilen")}\n}}',
                    members='    var finished: some View {\n'
                            f'        {button("Zu den Reisen")}\n'
                            '    }\n')
        # The property is never shown: it is reported as a button on no page, not as a pair.
        self.assertEqual(together(text), [])
        self.assertEqual(len(advices(text)), 1)
        self.assertIn("is on no page the rule can see", advices(text)[0])

    def test_static_view_members_are_followed(self):
        text = page(f'VStack {{\n    Self.action\n    {button("Teilen")}\n}}',
                    members=f'    static var action: some View {{ {button("Anlegen")} }}\n', name="Banner")
        other = page(f'VStack {{ Banner.action\n{button("Weiter")} }}', name="Other")
        self.assertEqual(together(text, other), [("Banner", ["Anlegen", "Teilen"]), ("Other", ["Anlegen", "Weiter"])])

    def test_the_apps_view_modifiers_are_part_of_the_page(self):
        modifier = ('extension View {\n    func quickBanner() -> some View {\n'
                    f'        safeAreaInset(edge: .bottom) {{ {button("Anlegen")} }}\n    }}\n}}\n')
        text = page(f'List {{ {button("Teilen")} }}\n    .quickBanner()')
        self.assertEqual(together(modifier, text), [("Page", ["Anlegen", "Teilen"])])

    def test_bars_overlays_and_backgrounds_are_part_of_the_page(self):
        for modifier in ("safeAreaInset(edge: .bottom)", "overlay", "background"):
            with self.subTest(modifier=modifier):
                text = page(f'List {{ {button("Teilen")} }}\n    .{modifier} {{ {button("Anlegen")} }}')
                self.assertEqual(together(text), [("Page", ["Anlegen", "Teilen"])])

    def test_private_views_of_two_files_are_kept_apart(self):
        first = ('private struct Bar: View {\n    var body: some View { Button("A") {}.buttonStyle(PrimaryButtonStyle()) }\n}\n'
                 + page('VStack { Bar() }', name="One"))
        second = ('private struct Bar: View {\n    var body: some View { Text("B") }\n}\n'
                  + page(f'VStack {{ Bar()\n{button("C")} }}', name="Two"))
        self.assertEqual(advices(first, second), [])

    def test_the_app_store_build_is_read(self):
        text = page('VStack {\n'
                    f'    {button("Anlegen")}\n'
                    '    #if DEBUG\n'
                    f'    {button("Testdaten", ".borderedProminent")}\n'
                    '    #endif\n'
                    '    #if targetEnvironment(simulator)\n'
                    f'    {button("Demo", ".borderedProminent")}\n'
                    '    #else\n'
                    '    Text("Gerät")\n'
                    '    #endif\n'
                    '}')
        self.assertEqual(advices(text), [])
        release = text.replace("#if DEBUG", "#if !DEBUG")
        found = rule.offenders_in(files(release))
        self.assertEqual(len(found), 1)
        self.assertIn("„Testdaten“ (App/Albumist/Views/File0.swift:6)", found[0][2])  # lines kept
        other = text.replace("#if DEBUG", "#if canImport(UIKit)")
        self.assertEqual(together(other), [("Page", ["Anlegen", "Testdaten"])])

    def test_the_release_value_of_conditions(self):
        cases = {"DEBUG": False, "!DEBUG": True, "targetEnvironment(simulator)": False,
                 "DEBUG || targetEnvironment(simulator)": False, "!(DEBUG)": True, "os(iOS)": None,
                 "DEBUG && os(iOS)": False, "DEBUG || os(iOS)": None, "!targetEnvironment(simulator) && !DEBUG": True}
        for condition, value in cases.items():
            with self.subTest(condition=condition):
                self.assertIs(rule.release_value(condition), value)


class ReportedTests(unittest.TestCase):
    def test_an_unknown_style_is_reported_where_it_is_declared_and_used(self):
        text = ('struct FancyButtonStyle: ButtonStyle {\n'
                '    func makeBody(configuration: Configuration) -> some View { configuration.label }\n'
                '}\n'
                + page('VStack {\n    Button("A") {}.buttonStyle(FancyButtonStyle())\n'
                       '    Button("B") {}.buttonStyle(prominent ? .borderedProminent : .bordered)\n}'))
        found = rule.offenders_in(files(text))
        self.assertEqual([line for _, line, _ in found], [1, 7, 8])
        self.assertIn("Button style FancyButtonStyle is in neither", found[0][2])
        self.assertIn("Button style FancyButtonStyle is in neither", found[1][2])
        self.assertIn("Button style prominent ? .borderedProminent : .bordered is in neither", found[2][2])

    def test_a_filled_button_on_no_page_is_reported(self):
        text = page('Text("Hallo")', members=f'    var unused: some View {{\n        {button("Anlegen")}\n    }}\n')
        found = rule.offenders_in(files(text))
        self.assertEqual([(path, line) for path, line, _ in found], [("App/Albumist/Views/File0.swift", 6)])
        self.assertIn("Filled button App/Albumist/Views/File0.swift:6 is on no page", found[0][2])


class EntryTests(unittest.TestCase):
    CARD = page(button("Einstellungen öffnen"), name="FullAccessCard")
    REVIEW = page('VStack {\n    if ready { applyBar } else { Text("Warten") }\n    FullAccessCard()\n}',
                  members=f'    var applyBar: some View {{ {button("Anlegen")} }}\n', name="Review")
    OTHER = page(f'VStack {{\n    FullAccessCard()\n    {button("Teilen")}\n}}', name="Other")
    ENTRY = {"Review": [({"Review.applyBar", "FullAccessCard.body"}, "why", [])]}

    def test_buttons_that_take_turns_pass_on_their_page_only(self):
        with no_entries():
            self.assertEqual(together(self.CARD, self.REVIEW, self.OTHER),
                             [("Review", ["Anlegen", "Einstellungen öffnen"]),
                              ("Other", ["Einstellungen öffnen", "Teilen"])])
            with mock.patch.object(rule, "TAKE_TURNS", self.ENTRY):
                self.assertEqual(together(self.CARD, self.REVIEW, self.OTHER),
                                 [("Other", ["Einstellungen öffnen", "Teilen"])])
                # A page that shows the view keeps what the view says.
                root = page("NavigationStack { Review() }", name="Root")
                self.assertEqual(together(self.CARD, self.REVIEW, root), [])

    def check_entries(self, take_turns, shown_once, sources):
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(rule, "TAKE_TURNS", take_turns), \
                mock.patch.object(rule, "SHOWN_ONCE", shown_once):
            write_repo(pathlib.Path(folder), sources)
            app = rule.App(rule.app_sources(folder))
            return [advice for _, _, advice in rule.entry_offenders(app, folder)]

    def test_an_entry_that_holds_is_not_reported(self):
        entry = {"Review": [({"Review.applyBar", "FullAccessCard.body"}, "why",
                             [("App/Albumist/Views/File1.swift", r"if ready \{ applyBar \}")])]}
        self.assertEqual(self.check_entries(entry, {}, files(self.CARD, self.REVIEW)), [])

    def test_an_entry_whose_button_is_gone_is_reported(self):
        entry = {"Review": [({"Review.applyBar", "Review.oldBar"}, "why", [])]}
        found = self.check_entries(entry, {}, files(self.CARD, self.REVIEW))
        self.assertEqual(found, [rule.GONE.format(entry="TAKE_TURNS['Review']", button="Review.oldBar", page="Review")])

    def test_an_entry_whose_code_is_gone_is_reported(self):
        missing = ("App/Albumist/Views/File1.swift", r"if waiting \{")
        no_file = ("Sources/AlbumistCore/Gone.swift", r"x")
        in_a_comment = ("App/Albumist/Views/File0.swift", r"if ready")
        card = "// if ready, the card hides\n" + self.CARD
        entry = {"Review": [({"Review.applyBar", "FullAccessCard.body"}, "why", [missing, no_file, in_a_comment])]}
        found = self.check_entries(entry, {}, files(card, self.REVIEW))
        self.assertEqual(sorted(found), sorted(
            rule.NO_WITNESS.format(entry="TAKE_TURNS['Review']", pattern=pattern, path=path)
            for path, pattern in (missing, no_file, in_a_comment)))

    def test_a_shown_once_entry_whose_list_no_longer_shows_the_button_is_reported(self):
        big = page(button("Alben anlegen"), name="StarterSetCard")
        sections = page('VStack {\n    ForEach(sections) { section in Text(section.title) }\n}', name="StartSections")
        found = self.check_entries({}, {("StartSections.body", "StarterSetCard.body"): ("why", [])},
                                   files(big, sections))
        self.assertEqual(found, [rule.GONE.format(entry="SHOWN_ONCE['StartSections.body']",
                                                  button="StarterSetCard.body", page="StartSections.body")])


class AppTests(unittest.TestCase):
    """The rule over App/Albumist as it is."""

    @classmethod
    def setUpClass(cls):
        cls.app = rule.App(rule.app_sources(REPO))

    def test_the_app_shows_one_filled_button_per_page(self):
        found = rule.offenders(REPO)
        self.assertEqual(found, [], "\n".join(f"{file}:{line}: {advice}" for file, line, advice in found))

    def test_every_entry_still_holds(self):
        found = rule.entry_offenders(self.app, REPO)
        self.assertEqual(found, [], "\n".join(advice for _, _, advice in found))

    def test_the_rule_sees_the_apps_filled_buttons(self):
        # Not an empty pass: the main buttons of the app are found, each on a page.
        self.assertGreaterEqual(len(self.app.leaves), 15)
        for source in self.app.sources:
            for offset in source.filled_styles:
                self.assertIn((source.path, offset), self.app.placed, f"{source.path}:{source.line(offset)}")

    def test_the_start_page_is_read_across_files(self):
        shown = next(found for found in self.app.pages.values() if found.label == "OverviewView")
        names = {self.app.leaves[number].name for number in shown.node.leaves}
        self.assertTrue({"InterruptedPlanCard.body", "EmptyLibraryCard.body", "StarterSetCard.body"} <= names, names)

    def test_every_button_style_of_the_app_is_named(self):
        named = set(rule.FILLED_STYLES) | set(rule.NOT_FILLED)
        declared = {name for _, _, name in self.app.button_styles}
        self.assertIn("PrimaryButtonStyle", declared)
        self.assertEqual(declared - named, set())

    def test_every_entry_names_a_view_of_the_app(self):
        views = {info.name for info in self.app.types.values() if info.is_view}
        self.assertEqual(set(rule.TAKE_TURNS) - views, set())
        for page_name, groups in rule.TAKE_TURNS.items():
            for names, reason, witnesses in groups:
                with self.subTest(page=page_name, names=sorted(names)):
                    self.assertGreaterEqual(len(names), 2)
                    self.assertTrue(reason.strip())
                    self.assertTrue(witnesses, "an entry says which code keeps the buttons apart")
        for (owner, _), (reason, witnesses) in rule.SHOWN_ONCE.items():
            with self.subTest(owner=owner):
                self.assertIn(owner.split(".")[0], views)
                self.assertTrue(reason.strip() and witnesses)


if __name__ == "__main__":
    unittest.main()
