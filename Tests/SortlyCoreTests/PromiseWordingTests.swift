import Foundation
import Testing
@testable import SortlyCore

/// What Albumist promises, against what it does (decisions Fuchs 18.11.2026, reviews P2-03,
/// P3-02, G7-01). Place names come from Apple's map service, on by default with a switch, so
/// "Nichts wird hochgeladen" became "Kein Foto wird hochgeladen", and the onboarding says in one
/// sentence what leaves the device. Only country albums are made by default, so the store
/// texts say "Länder, auf Wunsch auch Städte".
@Suite("Promise wording")
struct PromiseWordingTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static let placeNamesDE = "Für Ortsnamen schickt iOS einzelne Aufnahmeorte (nur Koordinaten) an Apples Kartendienst"

    /// The files that make promises to the user: the app's strings, the store, the website.
    static let promises = [
        "App/Sortly/Resources/Localizable.xcstrings", "App/Sortly/Views/OnboardingView.swift", "App/Sortly/Views/SettingsView.swift",
        "docs/launch/APP_STORE_DE.md", "docs/launch/APP_STORE_EN.md", "docs/PRIVACY.md",
        "website/pages/de/index.html", "website/pages/en/index.html", "website/pages/de/support.html",
        "website/pages/en/support.html", "website/pages/de/datenschutz.html", "website/pages/en/privacy.html",
    ]

    @Test func noPromiseThatNothingIsUploaded() throws {
        for path in Self.promises {
            let text = try Self.text(path)
            for wrong in ["Nichts wird hochgeladen", "Nothing is uploaded", "Keine Fotos werden hochgeladen", "Alles bleibt auf deinem"] {
                #expect(!text.contains(wrong), "\(path): \(wrong)")
            }
        }
    }

    @Test func onboardingSaysWhatLeavesTheDevice() throws {
        let onboarding = try Self.text("App/Sortly/Views/OnboardingView.swift")
        #expect(onboarding.contains("Kein Foto wird hochgeladen."))
        #expect(onboarding.contains(Self.placeNamesDE))
        #expect(onboarding.contains("in den Einstellungen ausschalten"))
        // The switch it points to is in the settings, and on by default.
        #expect(try Self.text("App/Sortly/Views/SettingsView.swift").contains("$model.settings.privacy.allowOnlineGeocoding"))
        #expect(PrivacySettings().allowOnlineGeocoding)
    }

    @Test func theSentencesHaveEnglish() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("App/Sortly/Resources/Localizable.xcstrings"))
        let catalog = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: [String: Any]])
        let keys = catalog.keys.filter { $0.contains("Kein Foto wird hochgeladen") || $0.contains(Self.placeNamesDE) }
        #expect(keys.count >= 3)
        for key in keys {
            let english = ((catalog[key]?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = try #require(english?["value"] as? String, "\(key)")
            #expect(value.contains("photo"), "\(key): \(value)")
        }
    }

    @Test func storeTextsPromiseCountriesAndCitiesOnlyOnRequest() throws {
        #expect(PlaceSettings().levels == [.country], "the default stays: countries only")
        let de = try Self.text("docs/launch/APP_STORE_DE.md"), en = try Self.text("docs/launch/APP_STORE_EN.md")
        #expect(de.contains("LÄNDER, AUF WUNSCH AUCH STÄDTE"))
        #expect(!de.contains("in Ländern und Städten"))
        #expect(en.contains("CITIES IF YOU LIKE"))
        #expect(!en.contains("in countries and cities automatically"))
        for page in ["website/pages/de/index.html", "website/pages/en/index.html"] {
            let html = try Self.text(page)
            #expect(!html.contains("Länder, Städte,") && !html.contains("countries, cities,"), "\(page)")
        }
    }
}
