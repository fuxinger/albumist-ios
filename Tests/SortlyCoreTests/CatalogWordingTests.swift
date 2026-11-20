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
///
/// Counts that can pass 999 show the locale's thousands separator: „1.354 Fotos von zu Hause“,
/// not „1354“ beside „82 von 1.176“. `%lld` shows no separator, so such a sentence takes its
/// number twice: the integer picks the plural form, `n.formatted()` is what is shown (key
/// `"%lld %@ Fotos von zu Hause"`, called as `"\(n) \(n.formatted()) Fotos von zu Hause"`).
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

    /// Texts of files that other work changes at the same time: to be reworded there, then
    /// removed here. Each is still in the catalog. Empty: the texts of `AppModel.swift` say
    /// „rückgängig machen“ too (second review of P3-09).
    static let rewordedElsewhere: [String: String] = [:]

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
        // The message that points to it.
        ("Nicht alles ließ sich rückgängig machen. Der unterbrochene Vorgang steht jetzt unter Einstellungen › Verlauf und Rückgängig. Dort kannst du den Rest rückgängig machen.",
         "Not everything could be undone. The interrupted run is now in Settings › History and Undo, where you can undo the rest."),
        // Right after „Ignorieren“, as in iOS.
        ("Widerrufen", "Undo"),
        // The receipt.
        ("Vollständig angelegt", "Fully Created"),
        ("Angelegt am %@", "Created on %@"),
        ("Nicht vollständig angelegt", "Not fully created"),
        // The receipt of an undo (second review of P3-09: it said „Vollständig angelegt“).
        ("Vollständig rückgängig gemacht", "Fully Undone"),
        ("Teilweise rückgängig gemacht", "Partly Undone"),
        ("Nicht vollständig rückgängig gemacht", "Not fully undone"),
    ])
    func oneWordInBothLanguages(_ pair: (german: String, english: String)) throws {
        #expect(try Self.value(pair.german, "en") == pair.english)
    }

    /// The receipt, its album rows and its shared text name the kind of work
    /// (`PlanReceipt.Kind`): an undo says „rückgängig gemacht“ (second review of P3-09: the
    /// receipt of an undo said „Vollständig angelegt“, its rows „Nicht vollständig angelegt“).
    @Test func theReceiptOfAnUndoSaysUndone() throws {
        let source = AppSource.code(try AppSource.read("App/Sortly/Views/PlanReceiptView.swift"), keepStrings: true)
        let literals = Set(Self.literals(source))
        let missing = ["Vollständig rückgängig gemacht", "Teilweise rückgängig gemacht", "Nicht vollständig rückgängig gemacht"]
            .filter { !literals.contains($0) }
        #expect(missing.isEmpty, "PlanReceiptView.swift does not say \(missing)")
        // The kind decides the word, not a flag that only knows removals.
        let byFlag = source.contains("isRemoval"), byKind = source.contains("PlanReceipt.Kind")
        #expect(!byFlag && byKind, "PlanReceiptView.swift picks its words by isRemoval, not by PlanReceipt.Kind")
    }

    // MARK: - Thousands separators

    /// A count directly before one of these words can pass 999 (photos of a library, of a
    /// country, of a check; places, documents, days with photos).
    static let largeNouns = "(Fotos?|Orte|Orten|Dokumente|Tage|Aufnahmen|Screenshots)"

    /// Integer counts before such a word that stay, each with its reason.
    static let smallOrElsewhere: [String: String] = [
        "Albumist sieht erst %lld Fotos. Für ein Album braucht es mehr Fotos von einem Ort oder einer Reise.":
            "said only while there are too few photos for an album",
        "%lld Beispielfotos anlegen": "the sample photos, about 100",
        "Albumist legt %lld Beispielfotos von vier Reisen in deiner Fotos-Mediathek an. Das ist nötig, damit Albumist daraus Alben anlegen kann. Du kannst sie jederzeit wieder entfernen: nur diese Beispielfotos und die Alben, die Albumist daraus gemacht hat.":
            "the sample photos, about 100",
        "Legt etwa %lld Beispielfotos mit Reisen, Screenshots und Dokumenten an. Nur im Simulator.": "simulator only, about 100",
        "%lld Fotos bleiben in Fotos: Name oder Aufnahmedatum passen nicht zu den Beispielfotos von Albumist. Albumist löscht nur, was sicher ein Beispielfoto ist.":
            "some of the sample photos",
        "%lld Fotos bleiben im Album „%@“.": "sample photos; AppModel.swift (other work)",
        "Ein Teil hat weniger als %lld Fotos mit Ort. Er wird kein eigener Reise-Vorschlag; seine Fotos bleiben in den Länder- und Orte-Alben.":
            "the minimum of a trip, a small fixed number",
        "%lld Tage": "the days of one trip",
        "%lld Tage mit Fotos": "HomeSettingsView.swift (other work): switch to „%lld %@ Tage mit Fotos“",
        "%lld Fotos": "SortingShow.swift (other work): the sorting show still uses it; everything else says „%lld %@ Fotos“",
        "%lld Fotos einsortiert": "SortingShow.swift (other work)",
        "%lld von %lld Alben fertig, %lld Fotos einsortiert": "SortingShow.swift (other work)",
        "%lld Fotos ignoriert": "AppModel.swift (other work): the announcement; the note in the library is grouped",
    ]

    @Test func largeCountsAreGrouped() throws {
        let integerBeforeNoun = "%(\\d\\$)?lld (\\p{L}+ )?\(Self.largeNouns)\\b"
        let catalog = try StringCatalogTests.catalog()
        let ungrouped = catalog.keys.filter { key in
            Self.smallOrElsewhere[key] == nil && key.range(of: integerBeforeNoun, options: .regularExpression) != nil
        }
        #expect(ungrouped.isEmpty, "count without thousands separator: \(ungrouped.sorted().joined(separator: "\n"))")
        // Counts said without a noun after them.
        for key in ["Dazu %lld teilweise sortiert", "%lld von %lld", "%lld ausgewählt", "%lld aus Vorschlag entfernen"] {
            #expect(catalog[key] == nil, "\(key): count without thousands separator")
        }
        let stale = Self.smallOrElsewhere.keys.filter { catalog[$0] == nil }
        #expect(stale.isEmpty, "gone, remove from the list: \(stale)")
    }

    /// A grouped count (`%lld %@`): German and English pick their plural form with the integer
    /// and show the text. A form that showed `%arg` would show „1354“ again.
    @Test func groupedCountsPickTheirFormByTheNumberAndShowTheText() throws {
        var problems: [String] = []
        let specifier = try Regex("%(?:\\d+\\$)?(?:lld|ld|d|@|f|\\.\\d+f)")
        var pairs = 0
        for (key, entry) in try StringCatalogTests.catalog() where key.contains("%lld %@") {
            // The argument number of each integer that a text follows (1-based).
            let kinds = key.matches(of: specifier).map { String(key[$0.range]) }
            let counts = kinds.indices.filter { kinds[$0] == "%lld" && $0 + 1 < kinds.count && kinds[$0 + 1] == "%@"
                && key.contains("\(kinds[$0]) \(kinds[$0 + 1])") }
            pairs += counts.count
            for language in ["de", "en"] {
                guard let loc = StringCatalogTests.localization(entry, language) else {
                    problems.append("\(language) \(key): no \(language) text (the key would show both numbers)")
                    continue
                }
                let subs = loc["substitutions"] as? [String: [String: Any]] ?? [:]
                for count in counts {
                    let argNum = count + 1
                    let chosen = subs.filter { ($0.value["argNum"] as? Int) == argNum }
                    if chosen.isEmpty || chosen.values.contains(where: { $0["formatSpecifier"] as? String != "lld" }) {
                        problems.append("\(language) \(key): no plural form picked by argument \(argNum)")
                    }
                    for (name, sub) in chosen {
                        let plural = (sub["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
                        let other = Self.texts(plural["other"])
                        if other.isEmpty || other.contains(where: { $0.contains("%arg") || !$0.contains("%\(argNum + 1)$@") }) {
                            problems.append("\(language) \(key): \(name) „other“ must show %\(argNum + 1)$@, not %arg: \(other)")
                        }
                    }
                }
            }
        }
        #expect(pairs > 0)
        #expect(problems.isEmpty, "\(problems.sorted().joined(separator: "\n"))")
    }

    /// In the App the shown text is the same number as the integer before it:
    /// `"\(n) \(n.formatted()) Fotos"`, never `"\(n) \(m.formatted()) Fotos"`.
    @Test func theShownNumberIsTheCountedOne() throws {
        let pair = try Regex(#"\\\(([^()]*(?:\([^()]*\))?[^()]*)\) \\\(([^()]*(?:\([^()]*\))?[^()]*)\.formatted\(\)\)"#)
        var found = 0, wrong: [String] = []
        for path in AppSource.swiftFiles(under: "App/Sortly") {
            let code = AppSource.code(try AppSource.read(path), keepStrings: true)
            for match in code.matches(of: pair) {
                let counted = String(match.output[1].substring ?? ""), shown = String(match.output[2].substring ?? "")
                found += 1
                if shown != counted && shown != "(\(counted))" { wrong.append("\(path): \\(\(counted)) \\(\(shown).formatted())") }
            }
        }
        #expect(found > 0)
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    }
}
