import Foundation
import Testing
import AlbumistTestSupport

/// Three findings of the full UI run 44862187776 (design waves 1 and 2, 21.11.2026). The views
/// run only on a Mac; the guards read their code.
@Suite("UI run 44862187776: all suggestions, the folder label, the purchase sheet")
struct UIRunFindingsSourceTests {
    private static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The start page's last row says "Alle Vorschläge" and opens the list of every suggestion,
    /// which was titled "Vorschläge" like the start page itself: the screen seemed not to change
    /// (the tap-through sweep: "Row 'Alle Vorschläge …' on Vorschläge did nothing"), and Back
    /// led from "Vorschläge" to "Vorschläge". The list says what the row said, as Photos' and
    /// Settings' pushed screens repeat the row that opened them; one area's list keeps its name.
    @Test func theListOfEverySuggestionIsTitledAsItsRow() throws {
        let source = AppSource.code(try AppSource.read("App/Albumist/Views/ProposalViews.swift"), keepStrings: true)
        let body = try #require(AppSource.body(of: ["struct ProposalListView", "var body: some View"], in: source), "no ProposalListView.body")
        let squeezed = Self.squeezed(body)
        #expect(squeezed.contains(".navigationTitle(area?.title??\"AlleVorschläge\")"), "the list of every suggestion is not titled \"Alle Vorschläge\": \(squeezed.suffix(400))")
        #expect(!squeezed.contains(".navigationTitle(area?.title??\"Vorschläge\")"), "the list of every suggestion still has the start page's title")
        // The row that opens it says the same words.
        let start = AppSource.code(try AppSource.read("App/Albumist/Views/Start/StartSections.swift"), keepStrings: true)
        let row = try #require(AppSource.body(of: "struct StartAllSuggestionsRow", in: start), "no StartAllSuggestionsRow")
        #expect(row.contains("\"Alle Vorschläge\""), "the start page's row no longer says \"Alle Vorschläge\"")
        // The start page itself stays "Vorschläge" (the tab's name and the UI tests' anchor).
        let overview = AppSource.code(try AppSource.read("App/Albumist/Views/OverviewView.swift"), keepStrings: true)
        #expect(Self.squeezed(overview).contains(".navigationTitle(\"Vorschläge\")"), "the start page lost its title")
    }

    /// "Ordner für neue Alben" in the settings was cut to one line at the largest text size
    /// ("300 pt wide on one line, it needs 493 pt"; the run before showed it on two lines). The
    /// label wraps whatever the row proposes: no line limit of its own or from around it, and as
    /// tall as its lines need.
    @Test func theFolderLabelWrapsAtTheLargestText() throws {
        let source = AppSource.code(try AppSource.read("App/Albumist/Views/SettingsView.swift"), keepStrings: true)
        let squeezed = Self.squeezed(source)
        let label = try #require(squeezed.range(of: "Text(\"OrdnerfürneueAlben\")"), "no folder label in the settings")
        let after = squeezed[label.upperBound...].prefix(260)
        #expect(after.hasPrefix(".lineLimit(nil).fixedSize(horizontal:false,vertical:true)"),
                "the folder label can still be cut to one line: \(after)")
        #expect(after.contains(".accessibilityIdentifier(\"settings.rootFolder.label\")"), "the folder label lost the name the UI test finds it by")
    }

    /// "Anlegen" with the free albums used up asks for the purchase sheet through
    /// `QuickCreateState.purchase`. The tabs read it only inside the sheet's binding, and the
    /// sheet did not come (locked test 8: "Not within 15 s: purchase sheet after Anlegen").
    /// SwiftUI tracks what `body` reads: the tabs read it there, so a new request redraws them.
    @Test func thePurchaseSheetOfAnlegenIsReadInTheTabsBody() throws {
        let source = AppSource.code(try AppSource.read("App/Albumist/Views/RootView.swift"), keepStrings: true)
        let body = try #require(AppSource.body(of: ["struct MainTabs", "var body: some View"], in: source), "no MainTabs.body")
        let squeezed = Self.squeezed(body)
        let read = try #require(squeezed.range(of: "letpurchase=model.quickCreatePurchase"), "the tabs do not read the purchase request in body: \(squeezed.prefix(300))")
        let sheet = try #require(squeezed.range(of: ".sheet(item:Binding(get:{purchase},set:{model.quickCreatePurchase=$0})){requestin"),
                                 "the purchase sheet does not show what body read")
        #expect(read.lowerBound < sheet.lowerBound, "the purchase request is read after the sheet")
        #expect(!squeezed.contains("Binding(get:{model.quickCreatePurchase}"), "the sheet still reads the request only inside its binding")
    }
}
