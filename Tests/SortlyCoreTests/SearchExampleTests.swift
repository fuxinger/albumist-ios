import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Design review W6 (15.11.2026): the search examples on the empty search screen were fixed
/// German texts, so English devices saw "Strand 2024". They are now translated in the string
/// catalog (`SearchView.examples`); every example in both languages must be understood
/// completely, or a tap on it would end in "Suchbegriff nicht erkannt".
@Suite("Search examples")
struct SearchExampleTests {
    /// Keep in step with `SearchView.examples` and their English entries in Localizable.xcstrings.
    static let examples: [(german: String, english: String)] = [
        ("Strand 2024", "Beach 2024"),
        ("Italien", "Italy"),
        ("Rechnungen", "Invoices"),
        ("Videos", "Videos"),
        ("Nicht sortiert", "Not sorted"),
        ("Screenshots Bestellung", "Screenshots order"),
    ]

    static let lab = SearchLab.build()
    static let index = SearchIndex(facts: lab.facts, calendar: SearchLab.calendar)

    @Test(arguments: examples.flatMap { [$0.german, $0.english] })
    func everyExampleIsUnderstood(_ example: String) {
        let result = Self.index.search(example, now: SearchLab.now, statuses: Self.lab.statuses)
        let ignored = result.tokens.filter { $0.kind == .ignored }.map(\.label)
        #expect(ignored.isEmpty, "\(example): not understood \(ignored)")
        #expect(!result.tokens.isEmpty, "\(example): no term understood")
    }

    @Test func germanAndEnglishExampleMeanTheSame() {
        for (german, english) in Self.examples {
            let de = Self.index.search(german, now: SearchLab.now, statuses: Self.lab.statuses)
            let en = Self.index.search(english, now: SearchLab.now, statuses: Self.lab.statuses)
            #expect(Set(de.ids) == Set(en.ids), "\(german) / \(english) find different photos")
            #expect(de.tokens.map(\.kind) == en.tokens.map(\.kind), "\(german) / \(english) understood differently")
        }
    }

    /// The list above is the one the app shows: read from `SearchView.swift` and the string
    /// catalog, so a changed example cannot slip past these tests.
    @Test func listMatchesTheAppAndItsCatalog() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("App/Sortly/Views/SearchView.swift"), encoding: .utf8)
        let line = try #require(view.split(separator: "\n").first { $0.contains("examples: [LocalizedStringResource] = [") })
        let german = line.split(separator: "[").last!.split(separator: "\"", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(german == Self.examples.map(\.german))

        let data = try Data(contentsOf: root.appendingPathComponent("App/Sortly/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        for (de, en) in Self.examples {
            let entry = strings[de] as? [String: Any]
            let english = ((entry?["localizations"] as? [String: Any])?["en"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
            #expect(english == en, "\(de): catalog says \(english ?? "nothing")")
        }
    }
}
