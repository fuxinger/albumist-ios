import Foundation
import Testing
@testable import AlbumistCore

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

    /// Swift source without its comments (string literals kept), so a sentence in a comment
    /// cannot stand in for the one on screen (review of bundle-i, 19.11.).
    static func withoutComments(_ source: String) -> String {
        var out = "", chars = Array(source), i = 0, inString = false
        while i < chars.count {
            let c = chars[i], next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inString {
                out.append(c)
                if c == "\\", let next { out.append(next); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
            } else if c == "\"" {
                inString = true; out.append(c); i += 1
            } else if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if c == "/", next == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    /// What goes to Apple: the photo locations and the language the names should come in
    /// (`SystemGeocoder` passes `preferredLocale`), nothing else from Albumist (second review
    /// of 752ba07: "nur Koordinaten" left out the language).
    static let placeNamesDE = "Für Ortsnamen schickt iOS einzelne Aufnahmeorte (nur Koordinaten und die Sprache der Ortsnamen) an Apples Kartendienst"
    static let placeNamesEN = "For place names, iOS sends single photo locations (only coordinates and the language for place names) to Apple’s map service"
    /// The app says how many go, as the privacy pages do ("etwa einen pro Gegend", "roughly one
    /// per area"; editing of the texts, 26.11.: "single photo locations" read as every photo's
    /// place). The store texts and the other pages follow with the texts' own pull request.
    static let placeNamesAppDE = "Für Ortsnamen schickt iOS einzelne Aufnahmeorte, etwa einen pro Gegend (nur Koordinaten und die Sprache der Ortsnamen) an Apples Kartendienst"
    static let placeNamesAppEN = "For place names, iOS sends a sample of photo locations, roughly one per area (only coordinates and the language for place names) to Apple’s map service"

    /// Whitespace folded, so a sentence wrapped across lines in Markdown is still found.
    static func flat(_ path: String) throws -> String {
        try said(text(path), path: path).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What a file says to the user: a Swift or YAML file without its comments (string
    /// literals kept).
    static func said(_ text: String, path: String) -> String {
        if path.hasSuffix(".swift") { return withoutComments(text) }
        if path.hasSuffix(".yml") || path.hasSuffix(".yaml") { return withoutYAMLComments(text) }
        return text
    }

    /// YAML without its comments: a `#` at the start of a line or after a space, outside double
    /// quotes, ends the line. A `#` in a single-quoted value is cut too: that can only fail the
    /// check, never pass it.
    static func withoutYAMLComments(_ yaml: String) -> String {
        yaml.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var inQuotes = false, previous: Character = " "
            for index in line.indices {
                let c = line[index]
                if c == "\"", previous != "\\" { inQuotes.toggle() }
                if c == "#", !inQuotes, previous == " " || previous == "\t" { return line[..<index] }
                previous = c
            }
            return line
        }.joined(separator: "\n")
    }

    @Test func aCommentDoesNotCountAsTheSentence() {
        let source = """
        // Kein Foto wird hochgeladen.
        /* Kein Foto wird hochgeladen. */
        Text("Deine Fotos // bleiben")
        """
        let code = Self.withoutComments(source)
        #expect(!code.contains("Kein Foto"))
        #expect(code.contains("Text(\"Deine Fotos // bleiben\")"))
    }

    /// The same for the system's question in `App/project.yml` (second review of bundle-i: a
    /// YAML comment above the value passed the check).
    @Test func aYAMLCommentDoesNotCountAsTheSentence() {
        let yaml = """
        # Kein Foto wird hochgeladen, Originale werden nie verändert.
        NSPhotoLibraryUsageDescription: "Albumist liest deine Fotos." # Kein Foto wird hochgeladen
        Website: "https://albumist.app/#datenschutz"
        """
        let said = Self.said(yaml, path: "App/project.yml")
        #expect(!said.contains("Kein Foto"))
        #expect(said.contains("NSPhotoLibraryUsageDescription: \"Albumist liest deine Fotos.\""))
        #expect(said.contains("\"https://albumist.app/#datenschutz\""))
    }

    /// The files that make promises to the user: the app's strings, the store, the website.
    static let promises = [
        "App/Albumist/Resources/Localizable.xcstrings", "App/Albumist/Views/OnboardingView.swift", "App/Albumist/Views/SettingsView.swift",
        "docs/launch/APP_STORE_DE.md", "docs/launch/APP_STORE_EN.md", "docs/PRIVACY.md",
        "website/pages/de/index.html", "website/pages/en/index.html", "website/pages/de/support.html",
        "website/pages/en/support.html", "website/pages/de/datenschutz.html", "website/pages/en/privacy.html",
        "App/project.yml", "App/Albumist/Resources/InfoPlist.xcstrings",
    ]

    @Test func noPromiseThatNothingIsUploaded() throws {
        for path in Self.promises {
            let text = try Self.text(path)
            for wrong in ["Nichts wird hochgeladen", "Nothing is uploaded", "Keine Fotos werden hochgeladen", "Alles bleibt auf deinem",
                          "Es werden keine Fotos hochgeladen", "No photos are uploaded"] {
                #expect(!text.contains(wrong), "\(path): \(wrong)")
            }
        }
    }

    @Test func onboardingSaysWhatLeavesTheDevice() throws {
        let onboarding = Self.withoutComments(try Self.text("App/Albumist/Views/OnboardingView.swift"))
        #expect(onboarding.contains("Kein Foto wird hochgeladen."))
        #expect(onboarding.contains(Self.placeNamesAppDE))
        #expect(onboarding.contains("in den Einstellungen ausschalten"))
        // The switch it points to is in the settings, and on by default.
        #expect(Self.withoutComments(try Self.text("App/Albumist/Views/SettingsView.swift")).contains("$model.settings.privacy.allowOnlineGeocoding"))
        #expect(PrivacySettings().allowOnlineGeocoding)
    }

    /// The sentences themselves, where each promise is made (second review of 752ba07: the
    /// old texts in the settings, the privacy pages and PRIVACY.md passed the test unchanged).
    // A constant, not an inline list: the coverage map reads a test's name after its arguments.
    static let sentences: [(String, [String])] = [
        ("App/Albumist/Views/SettingsView.swift", [
            "Die Analyse läuft immer auf deinem Gerät. \(placeNamesAppDE), nie ein Foto.",
            "\(placeNamesAppDE). Das ist ab Werk eingeschaltet und lässt sich unter „Orte online genauer bestimmen“ ausschalten. Albumist lädt keine Fotos hoch.",
        ]),
        ("App/Albumist/Views/OnboardingView.swift", ["Deine Fotos bleiben auf deinem Gerät. Kein Foto wird hochgeladen.",
                                                   "\(placeNamesAppDE) – das kannst du in den Einstellungen ausschalten."]),
        ("docs/PRIVACY.md", ["Kein Foto wird hochgeladen;", "\(placeNamesDE); das ist ab Werk an und in den Einstellungen abschaltbar",
                             "und die Sprache der Ortsnamen", "IP-Adresse"]),
        ("website/pages/de/datenschutz.html", ["Kein Foto wird hochgeladen. \(placeNamesDE) – das ist ab Werk eingeschaltet",
                                               "nur Koordinaten und die Sprache der Ortsnamen, keine Fotos und keine Namen", "IP-Adresse",
                                               "Einstellungen › Datenschutz › Orte online genauer bestimmen"]),
        ("website/pages/en/privacy.html", ["No photo is ever uploaded. \(placeNamesEN). This is on by default",
                                           "only coordinates and the language for place names, no photos and no names", "IP address"]),
        ("website/pages/de/index.html", ["Kein Foto wird hochgeladen.", "\(placeNamesDE) – das kannst du in der App ausschalten.",
                                         "<h3>Länder, auf Wunsch auch Städte</h3>"]),
        ("website/pages/en/index.html", ["No photo is ever uploaded.", "\(placeNamesEN); you can turn this off in the app.",
                                         "<h3>Countries, and cities if you like</h3>"]),
        ("website/pages/de/support.html", ["Nein, kein Foto wird hochgeladen.", "Nur f\(placeNamesDE.dropFirst()) – das kannst du in der App unter"]),
        ("website/pages/en/support.html", ["No, no photo is ever uploaded.", "Only f\(placeNamesEN.dropFirst()); you can turn this off in the app under"]),
        ("docs/launch/APP_STORE_DE.md", ["Kein Foto wird hochgeladen", "\(placeNamesDE) – das kannst du in den Einstellungen ausschalten"]),
        ("docs/launch/APP_STORE_EN.md", ["No photo is ever uploaded", "\(placeNamesEN); you can turn this off in Settings."]),
        // The system's question for photo access (review of bundle-i, 19.11.).
        ("App/project.yml", ["Kein Foto wird hochgeladen, Originale bleiben unverändert."]),
        ("App/Albumist/Resources/InfoPlist.xcstrings", ["No photo is ever uploaded, and your originals are never changed."]),
    ]

    @Test(arguments: sentences)
    func everyPromiseSaysTheSameSentence(path: String, sentences: [String]) throws {
        let text = try Self.flat(path)
        for sentence in sentences { #expect(text.contains(sentence), "\(path): \(sentence)") }
    }

    /// The geocoder is `CLGeocoder` (Apple's map service), not MapKit, and the language goes
    /// along, so no text says that nothing else is sent.
    @Test func noTextNamesMapKitOrDeniesTheLanguage() throws {
        for path in Self.promises + ["docs/launch/APP_REVIEW_NOTES.md", "docs/launch/LAUNCH_CHECKLIST.md"] {
            let text = try Self.flat(path)
            for wrong in ["MapKit", "keine anderen Daten", "No photos, names or other data", "(nur Koordinaten)", "(coordinates only)"] {
                #expect(!text.contains(wrong), "\(path): \(wrong)")
            }
        }
    }

    @Test func theSentencesHaveEnglish() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("App/Albumist/Resources/Localizable.xcstrings"))
        let catalog = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: [String: Any]])
        let keys = catalog.keys.filter { $0.contains("Kein Foto wird hochgeladen") || $0.contains(Self.placeNamesAppDE) }
        #expect(keys.count >= 3)
        for key in keys {
            let english = ((catalog[key]?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let value = try #require(english?["value"] as? String, "\(key)")
            #expect(value.contains("photo"), "\(key): \(value)")
            if key.contains(Self.placeNamesAppDE) { #expect(value.contains(Self.placeNamesAppEN), "\(key): \(value)") }
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
