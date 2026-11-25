import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The history line in the App (`HistoryLineTests`).
extension HistoryLineTests {
    // MARK: In the app

    /// The app only maps each part to its words, a plural of the catalog with the number grouped
    /// ("1.234"), joined with ", " as before; the row shows the line of the plan.
    @Test func theAppMapsThePartsToTheCatalog() throws {
        let counted = AppSource.code(try AppSource.read("App/Albumist/DesignSystem/Counted.swift"), keepStrings: true)
        let body = try #require(AppSource.body(of: "static func historyLine(", in: counted))
        let line = String(body.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
        for mapping in ["case.created(letcount):String(localized:\"\\(count)neu\")",
                        "case.extended(letcount):String(localized:\"\\(count)ergänzt\")",
                        "case.renamed(letcount):String(localized:\"\\(count)\\(count.formatted())umbenannt\")",
                        "case.moved(letcount):String(localized:\"\\(count)\\(count.formatted())verschoben\")",
                        "case.photos(letcount):String(localized:\"\\(count)\\(count.formatted())Fotos\")",
                        "case.removed(letcount):String(localized:\"\\(count)\\(count.formatted())entfernt\")",
                        "case.takenOut(letcount):String(localized:\"\\(count)\\(count.formatted())Fotosherausgenommen\")",
                        "case.nothingChanged:String(localized:\"Nichtsgeändert\")",
                        "case.nothingRemoved:String(localized:\"Nichtsentfernt\")"] {
            #expect(line.contains(mapping), "\(mapping)")
        }
        #expect(line.contains("join(HistoryLine.parts(of:plan).map{partin"), "the app decides the parts itself")
        #expect(line.hasSuffix(",separator:\",\")}"))
        let settings = AppSource.code(try AppSource.read("App/Albumist/Views/SettingsView.swift"), keepStrings: true)
        #expect(settings.contains("Text(Counted.historyLine(plan))"))
        #expect(!settings.contains("historyLine(plan.appliedSummary)"))
    }

    /// The new words, with English and their one and many forms, the number grouped (`%lld %@`:
    /// the integer picks the form, the text shows it).
    @Test(arguments: [("%lld %@ entfernt", "%2$@ entfernt", "%2$@ entfernt", "%2$@ removed", "%2$@ removed"),
                      ("%lld %@ Fotos herausgenommen", "%2$@ Foto herausgenommen", "%2$@ Fotos herausgenommen",
                       "%2$@ photo taken out", "%2$@ photos taken out"),
                      ("%lld %@ umbenannt", "%2$@ umbenannt", "%2$@ umbenannt", "%2$@ renamed", "%2$@ renamed"),
                      ("%lld %@ verschoben", "%2$@ verschoben", "%2$@ verschoben", "%2$@ moved", "%2$@ moved")])
    func theNewWordsAreInTheCatalog(key: String, germanOne: String, germanOther: String, englishOne: String, englishOther: String) throws {
        let catalog = try StringCatalogTests.catalog()
        let entry = try #require(catalog[key], "\(key) is not in the catalog")
        func plural(_ language: String, _ form: String) -> String? {
            let localization = StringCatalogTests.localization(entry, language)
            let value = (localization?["stringUnit"] as? [String: Any])?["value"] as? String
            let name = value.flatMap { $0.hasPrefix("%#@") && $0.hasSuffix("@") ? String($0.dropFirst(3).dropLast()) : nil }
            let substitution = name.flatMap { (localization?["substitutions"] as? [String: Any])?[$0] as? [String: Any] }
            #expect(substitution?["argNum"] as? Int == 1 && substitution?["formatSpecifier"] as? String == "lld", "\(language)")
            let variations = (substitution?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            return ((variations?[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(plural("de", "one") == germanOne)
        #expect(plural("de", "other") == germanOther)
        #expect(plural("en", "one") == englishOne)
        #expect(plural("en", "other") == englishOther)
    }

    /// The words of a change of nothing, with English (review M2).
    @Test(arguments: [("Nichts geändert", "Nothing changed"), ("Nichts entfernt", "Nothing removed")])
    func theWordsOfNothingAreInTheCatalog(german: String, english: String) throws {
        let catalog = try StringCatalogTests.catalog()
        let entry = try #require(catalog[german], "\(german) is not in the catalog")
        let value = (StringCatalogTests.localization(entry, "en")?["stringUnit"] as? [String: Any])?["value"] as? String
        #expect(value == english)
    }
}
