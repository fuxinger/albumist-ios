import Foundation
import Testing

/// Design review W5 (15.11.2026): counts read "1 Fotos und Videos" or "von 1 Schritten"
/// because their catalog entries had no plural forms. Strings with several numbers use
/// substitutions (`%#@name@`), which only Xcode checks; this test checks them on Linux too:
/// every substitution a value names is defined with an argument number and both plural forms,
/// and every count string listed below varies by plural in German and English.
@Suite("String catalog")
struct StringCatalogTests {
    static func catalog() throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("App/Sortly/Resources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["strings"] as? [String: [String: Any]])
    }

    static func localization(_ entry: [String: Any], _ language: String) -> [String: Any]? {
        (entry["localizations"] as? [String: Any])?[language] as? [String: Any]
    }

    static func hasPluralForms(_ node: [String: Any]?) -> Bool {
        guard let plural = (node?["variations"] as? [String: Any])?["plural"] as? [String: Any] else { return false }
        return plural["one"] != nil && plural["other"] != nil
    }

    @Test func everySubstitutionIsDefined() throws {
        let pattern = try Regex("%#@([A-Za-z0-9_]+)@")
        var problems: [String] = []
        for (key, entry) in try Self.catalog() {
            for language in ["de", "en"] {
                guard let loc = Self.localization(entry, language),
                      let value = (loc["stringUnit"] as? [String: Any])?["value"] as? String else { continue }
                let named = Set(value.matches(of: pattern).map { String($0.output[1].substring ?? "") })
                let defined = loc["substitutions"] as? [String: [String: Any]] ?? [:]
                if named != Set(defined.keys) { problems.append("\(language) \(key): uses \(named.sorted()), defines \(defined.keys.sorted())") }
                for (name, sub) in defined {
                    if sub["argNum"] as? Int == nil { problems.append("\(language) \(key): \(name) has no argNum") }
                    if !Self.hasPluralForms(sub) { problems.append("\(language) \(key): \(name) lacks one/other") }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Counts that can be 1 and were singled out by the design review.
    static let countStrings = [
        "%lld Fotos und Videos",
        "%lld Vorschläge für %lld Fotos und Videos",
        "Erledigt: %lld von %lld Schritten",
        "Unterbrochen: %lld von %lld Schritten erledigt",
        "%lld von %lld Schritten",
        "von %lld Alben fertig",
        "%lld von %lld Alben fertig, %lld Fotos einsortiert",
        "%lld Fotos ignoriert",
        "Vorschlag mit %lld Fotos",
        "%lld gemeinsame Fotos",
        "Für diese Auswahl brauchst du %lld Alben. Kostenlos sind noch %lld. Mit einem einmaligen Kauf sortierst du unbegrenzt, ohne Abo.",
    ]

    @Test(arguments: countStrings)
    func countVariesByPlural(_ key: String) throws {
        let entry = try #require(try Self.catalog()[key], "\(key) is missing")
        for language in ["de", "en"] {
            let loc = try #require(Self.localization(entry, language), "\(key) has no \(language)")
            let subs = loc["substitutions"] as? [String: [String: Any]] ?? [:]
            #expect(Self.hasPluralForms(loc) || (!subs.isEmpty && subs.values.allSatisfy(Self.hasPluralForms)),
                    "\(language) \(key) does not vary by plural")
        }
    }

    /// Design review W4: one word for photos. "Aufnahmen", "Bilder" and "Medien" are gone from
    /// the catalog, except in the analysis show that is rebuilt elsewhere (ScanShow).
    @Test func photosAreCalledFotos() throws {
        let allowed: Set<String> = ["%lld Aufnahmen"]
        let words = try Regex("\\b(Aufnahmen|Bilder|Medien)\\b")
        let left = try Self.catalog().keys.filter { $0.contains(words) && !allowed.contains($0) }
        #expect(left.isEmpty, "\(left.sorted())")
    }
}
