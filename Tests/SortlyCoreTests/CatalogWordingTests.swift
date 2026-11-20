import Foundation
import Testing
import SortlyTestSupport

/// One word per thing (review P3-09 of 18.11.2026, decision Fuchs 17.11. „Unsortiert“ überall):
/// the German texts had four words for taking something back („Rückgängig machen“,
/// „zurücknehmen“, „Widerrufen“, „Aufheben“), leftovers of „Umsetzen“ beside „Anlegen“, three
/// names for the one setting of what counts as sorted („Hauptsortierung“, „Hauptbereiche“,
/// „Zählt als sortiert“) and three for the trial year („Probelauf“, „Anfangen mit“, „Albumist
/// arbeitet mit“). The word list, German → English:
/// - „Rückgängig machen“ → "Undo" for everything Albumist did (also „Alles rückgängig machen“,
///   "Undo Everything"); „Widerrufen“ → "Undo" only in the short note right after an action
///   (as in iOS);
/// - „Anlegen“, „angelegt“ → "creating albums", "created" („Vollständig angelegt“, „Angelegt am“);
///   a removal from „Alben von Albumist“ is „Entfernen“, "removal"; „Vorgang“ → "run";
/// - „Unsortiert“ → "Unsorted";
/// - „sortiert“ → "sorted" is where a photo stands (the ring, the lists, the status);
///   „einsortiert“ → "sorted" is what Albumist did when it put photos into albums;
/// - „Zählt als sortiert“ → "Counts as Sorted" is the setting; its items are „Bereiche“, "areas";
/// - „Albumist arbeitet mit“ → "Albumist works with" is the choice of one year or the whole
///   library, in the start and in the settings.
@Suite("Catalog wording")
struct CatalogWordingTests {
    /// The German texts of an entry: its own German values (plural forms, substitutions) if it
    /// has any, else the key, which is the German text.
    static func german(_ key: String, _ entry: [String: Any]) -> [String] {
        let own = texts(StringCatalogTests.localization(entry, "de"))
        return own.isEmpty ? [key] : own
    }

    static func english(_ entry: [String: Any]) -> [String] {
        texts(StringCatalogTests.localization(entry, "en"))
    }

    /// Every value under a localization: the plain one, plural forms and substitutions.
    static func texts(_ node: Any?) -> [String] {
        guard let node = node as? [String: Any] else { return [] }
        var out: [String] = []
        if let value = (node["stringUnit"] as? [String: Any])?["value"] as? String { out.append(value) }
        for (name, child) in node where name != "stringUnit" {
            out += texts(child)
        }
        return out
    }

    /// Words that are gone, each with the word that replaced it.
    static let forbiddenGerman: [(pattern: String, instead: String)] = [
        ("umgesetzt", "angelegt"),
        ("\\bumsetzen\\b", "Anlegen"),
        ("\\bnicht sortiert\\b", "Unsortiert (Fuchs 17.11.)"),
        ("hauptsortierung", "Zählt als sortiert"),
        ("hauptbereich", "Zählt als sortiert, Bereiche"),
        ("zurück(zu)?nehm|zurückgenommen|\\bnimmt\\b[^.]*\\bzurück\\b", "rückgängig machen"),
        ("\\bprobelauf\\b", "Albumist arbeitet mit"),
        ("\\banfangen mit\\b", "Albumist arbeitet mit"),
        ("\\baufheben\\b(?<!auswahl aufheben)|\\baufgehoben\\b", "rückgängig machen („Auswahl aufheben“ stays, as in iOS)"),
    ]

    static let forbiddenEnglish: [(pattern: String, instead: String)] = [
        ("\\b(take|takes|taking|taken|took)( \\w+)? back\\b", "undo"),
        ("\\bapplied\\b", "created"),
        ("^not sorted$", "Unsorted"),
        ("\\bmain (area|areas|sorting)\\b", "Counts as Sorted, areas"),
        ("\\btest run\\b", "Albumist works with"),
    ]

    /// Texts of `AppModel.swift`, which other work changes at the same time: to be reworded
    /// there („rückgängig machen“), then removed here. Each is still in the catalog.
    static let rewordedElsewhere: [String: String] = [
        "Ein früheres Zurücknehmen wurde unterbrochen. Entscheide in der Übersicht, wie es weitergeht; danach geht es hier weiter.":
            "AppModel.swift (other work): „Ein früheres Rückgängigmachen …“",
        "Nicht alles ließ sich zurücknehmen. Der unterbrochene Vorgang steht jetzt unter Einstellungen › Verlauf und Rückgängig. Dort kannst du den Rest zurücknehmen.":
            "AppModel.swift (other work): „… rückgängig machen. … den Rest rückgängig machen.“",
        "Albumist konnte den unterbrochenen Vorgang gerade nicht zurücknehmen. Er steht jetzt unter Einstellungen › Verlauf und Rückgängig. Dort kannst du ihn zurücknehmen.":
            "AppModel.swift (other work): „… nicht rückgängig machen. … ihn rückgängig machen.“",
        "Erst das unterbrochene Zurücknehmen abschließen":
            "AppModel.swift (other work); PlanReviewView already says „Erst das unterbrochene Rückgängigmachen abschließen“",
        "Albumist hat zurückgenommen, was sicher von Albumist war.":
            "AppModel.swift (other work): „Albumist hat rückgängig gemacht, …“",
    ]

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @Test func noGermanTextUsesAWordThatIsGone() throws {
        var found: [String] = []
        for (key, entry) in try StringCatalogTests.catalog() where Self.rewordedElsewhere[key] == nil {
            for text in Self.german(key, entry) {
                for (pattern, instead) in Self.forbiddenGerman where Self.matches(text, pattern) {
                    found.append("\(key): „\(text)“ (\(instead))")
                }
            }
        }
        #expect(found.isEmpty, "\(found.sorted().joined(separator: "\n"))")
    }

    @Test func noEnglishTextUsesAWordThatIsGone() throws {
        var found: [String] = []
        for (key, entry) in try StringCatalogTests.catalog() where Self.rewordedElsewhere[key] == nil {
            for text in Self.english(entry) {
                for (pattern, instead) in Self.forbiddenEnglish where Self.matches(text, pattern) {
                    found.append("\(key): \"\(text)\" (\(instead))")
                }
            }
        }
        #expect(found.isEmpty, "\(found.sorted().joined(separator: "\n"))")
    }

    /// The App's own string literals (comments do not count), so a text written in code
    /// without a catalog entry cannot bring a word back either.
    @Test func noAppLiteralUsesAWordThatIsGone() throws {
        var found: [String] = []
        let elsewhere = Set(Self.rewordedElsewhere.keys)
        for path in AppSource.swiftFiles(under: "App/Sortly") {
            let source = try AppSource.read(path)
            let code = AppSource.code(source, keepStrings: true)
            for literal in Self.literals(code) where !elsewhere.contains(literal) {
                for (pattern, instead) in Self.forbiddenGerman where Self.matches(literal, pattern) {
                    found.append("\(path): „\(literal)“ (\(instead))")
                }
            }
        }
        #expect(found.isEmpty, "\(found.sorted().joined(separator: "\n"))")
    }

    /// The exceptions above are still there; one that is gone must leave the list.
    @Test func everyExceptionIsStillInTheCatalog() throws {
        let catalog = try StringCatalogTests.catalog()
        let gone = Self.rewordedElsewhere.keys.filter { catalog[$0] == nil }
        #expect(gone.isEmpty, "reworded, remove from the list: \(gone)")
    }

    /// The string literals of Swift code whose comments are blanked (`AppSource.code`).
    static func literals(_ code: String) -> [String] {
        let pattern = try! Regex(#""((?:[^"\\\n]|\\.)*)""#)
        return code.matches(of: pattern).map { String($0.output[1].substring ?? "") }
    }

    // MARK: - One name for the setting, the trial year and „Unsortiert“

    static func value(_ key: String, _ language: String) throws -> String? {
        let entry = try #require(try StringCatalogTests.catalog()[key], "\(key) is missing")
        if language == "de", StringCatalogTests.localization(entry, "de") == nil { return key }
        return (StringCatalogTests.localization(entry, language)?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    @Test(arguments: [
        // The setting and the words that point to it.
        ("Zählt als sortiert", "Counts as Sorted"),
        ("Kein Bereich zählt als sortiert", "No area counts as sorted"),
        // The status of a photo and the list of the library.
        ("Unsortiert", "Unsorted"),
        // The choice of the year, in the start and in the settings.
        ("Albumist arbeitet mit", "Albumist works with"),
        ("Ganze Mediathek", "Whole library"),
        // The undo of an interrupted plan.
        ("Alles rückgängig machen", "Undo Everything"),
        ("Rest rückgängig machen", "Undo the Rest"),
        // Right after „Ignorieren“, as in iOS.
        ("Widerrufen", "Undo"),
        // The receipt.
        ("Vollständig angelegt", "Fully Created"),
        ("Angelegt am %@", "Created on %@"),
    ])
    func oneWordInBothLanguages(_ pair: (german: String, english: String)) throws {
        #expect(try Self.value(pair.german, "en") == pair.english)
    }
}
