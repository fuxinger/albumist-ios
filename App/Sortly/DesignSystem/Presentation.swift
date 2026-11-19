import SwiftUI
import SortlyCore
import SortlyEngine

/// User-facing texts and symbols for core values. UI strings live in the app's string
/// catalog (German source, English translation); album titles come from the core.
extension OrganizationArea {
    /// Areas the app offers today. People and pets need identity grouping (opt-in), which
    /// ships in a later version (see docs/ROADMAP.md); until then the area is not shown.
    static var available: [OrganizationArea] { allCases.filter { $0 != .peopleAndPets } }

    var title: LocalizedStringKey {
        switch self {
        case .places: "Länder und Orte"
        case .trips: "Reisen"
        case .frequentPlaces: "Häufige Orte"
        case .peopleAndPets: "Personen und Tiere"
        case .messenger: "Messenger"
        case .screenshots: "Screenshots"
        case .imageCategories: "Themen"
        case .documents: "Dokumente"
        case .chronology: "Jahre und Monate"
        case .mediaTypes: "Medientypen"
        }
    }

    var symbol: String {
        switch self {
        case .places: "mappin.and.ellipse"
        case .trips: "airplane"
        case .frequentPlaces: "house"
        case .peopleAndPets: "pawprint"
        case .messenger: "bubble.left.and.bubble.right"
        case .screenshots: "rectangle.dashed"
        case .imageCategories: "square.grid.2x2"
        case .documents: "doc.text"
        case .chronology: "calendar"
        case .mediaTypes: "film.stack"
        }
    }

    var tint: Color {
        switch self {
        case .trips, .frequentPlaces: Theme.tint(for: .trips)
        case .places: Theme.tint(for: .places)
        case .documents, .screenshots, .messenger: Theme.tint(for: .documents)
        default: Theme.tint(for: .neutral)
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .places: "Alben für die Länder, in denen du fotografiert hast. Städte auf Wunsch."
        case .trips: "Erkennt Reisen und Ausflüge und trennt sie vom Alltag zu Hause."
        case .frequentPlaces: "Orte, an denen du oft fotografierst. Du gibst ihnen selbst einen Namen."
        case .peopleAndPets: "Haustiere und – nur wenn du es einschaltest – Gesichter."
        case .messenger: "Fotos aus WhatsApp, Signal und Co., nur mit klaren Hinweisen."
        case .screenshots: "Screenshots nach Inhalt: Bestellungen, Tickets, Rezepte …"
        case .imageCategories: "Themen wie Hunde, Strand, Essen oder Autos."
        case .documents: "Rechnungen, Verträge und Kassenbons. Sensible Dokumente nur auf Wunsch."
        case .chronology: "Alben nach Jahr und Monat."
        case .mediaTypes: "Videos, Live Photos, Panoramen, Zeitlupe und mehr."
        }
    }
}

extension MatchStatus {
    var label: LocalizedStringKey {
        switch self {
        case .alreadyComplete: "Schon vollständig vorhanden"
        case .extendable: "Vorhandenes Album wird ergänzt"
        // Not "passt vermutlich": a possible match gets an album of its own (review 16.11.).
        case .possibleMatch: "Ähnliches Album gefunden"
        case .multipleMatches: "Mehrere passende Alben"
        case .nameConflict: "Gleicher Name, anderer Inhalt"
        case .newAlbumRequired: "Neues Album"
        case .ambiguous: "Nicht eindeutig"
        case .notEditable: "Album nicht bearbeitbar"
        }
    }

    var tint: Color {
        switch self {
        case .alreadyComplete, .extendable: Theme.accent
        case .newAlbumRequired, .possibleMatch: Theme.tint(for: .places)
        default: Theme.tint(for: .documents)
        }
    }
}

extension Reliability {
    var label: LocalizedStringKey {
        switch self {
        case .certain: "Sicher"
        case .likely: "Wahrscheinlich"
        case .plausible: "Möglich"
        case .uncertain: "Unsicher"
        }
    }

    /// One sentence for the info popover next to the label.
    var explanation: LocalizedStringKey {
        switch self {
        case .certain: "Sicher heißt: Die Fotos gehören eindeutig zusammen."
        case .likely: "Wahrscheinlich heißt: Es passt fast sicher. Ein kurzer Blick auf die Fotos lohnt sich."
        case .plausible: "Möglich heißt: Es könnte passen. Bitte die Fotos kurz prüfen."
        case .uncertain: "Unsicher heißt: Hier entscheidest du. Albumist übernimmt das nie von selbst."
        }
    }
}

extension AnalysisPipeline.Stage {
    var label: LocalizedStringKey {
        switch self {
        case .inventory: "Mediathek wird gelesen"
        case .patterns: "Reisen werden erkannt"
        case .places: "Orte werden bestimmt"
        case .content: "Bildinhalte werden erkannt"
        case .text: "Text auf Screenshots wird gelesen"
        case .groups: "Gruppen werden gebildet"
        case .proposals: "Vorschläge werden erstellt"
        }
    }
}

extension PauseReason {
    var label: LocalizedStringKey {
        switch self {
        case .userPaused: "Pausiert"
        case .thermal: "Pausiert, weil das Gerät warm ist"
        case .lowPower: "Pausiert im Stromsparmodus"
        case .batteryLow: "Pausiert bei niedrigem Akku"
        case .timeBudget: "Wird später fortgesetzt"
        case .accessRevoked: "Kein Zugriff auf die Fotos"
        }
    }
}

extension InboxBucket {
    var label: LocalizedStringKey {
        switch self {
        case .all: "Alle"
        case .unorganized: "Nicht sortiert"
        case .suggestions: "Vorschläge"
        case .organized: "Sortiert"
        case .uncertain: "Unsicher"
        case .ignored: "Ignoriert"
        case .excluded: "Ausgeschlossen"
        }
    }
}

enum ReasonText {
    static func text(_ reason: ProposalReason) -> String {
        let dates = Date.FormatStyle(date: .numeric, time: .omitted)
        switch reason {
        case .photosInPlaceDuringPeriod(let count, let place, let start, let end):
            return String(localized: "\(count) Fotos zwischen \(start.formatted(dates)) und \(end.formatted(dates)) in \(place).")
        case .photosInPlace(let count, let place):
            return String(localized: "\(count) Fotos in \(place).")
        case .photosInPeriod(let count, let start, let end):
            return String(localized: "\(count) Fotos zwischen \(start.formatted(dates)) und \(end.formatted(dates)).")
        case .recurringPlace(let count, let days):
            return String(localized: "\(count) Fotos an \(days) verschiedenen Tagen am selben Ort.")
        case .recognizedContent(let count, let label):
            return String(localized: "\(count) Fotos zeigen „\(label)“.")
        case .recognizedText(let count, let label):
            return String(localized: "\(count) Fotos enthalten Text zu „\(label)“.")
        case .mediaType(let count, let label):
            return String(localized: "\(count) Fotos und Videos: \(label).")
        case .confirmedGroup(let count, let name):
            return String(localized: "\(count) Fotos von \(name).")
        case .ruleMatched(let count, let rule):
            return String(localized: "\(count) Fotos passen zur Regel „\(rule)“.")
        case .inferredWithoutLocation(let count):
            return String(localized: "\(count) Fotos ohne Ort passen zeitlich dazu und sind nur vorgeschlagen.")
        case .disputedArea(let place):
            return String(localized: "Umstrittenes Gebiet: Zu welchem Land es gehört, ist nicht sicher. Albumist ordnet „\(place)“ darum keinem Land zu.")
        }
    }

    static func text(_ reason: MatchReason) -> String {
        switch reason {
        case .albumContains(let album, let contained, let total):
            return String(localized: "Dein Album „\(album)“ enthält schon \(contained) von \(total) Fotos.")
        case .missingItems(let count):
            return String(localized: "\(count) passende Fotos fehlen noch und werden ergänzt.")
        case .albumHasOtherItems(let album, let count):
            return String(localized: "„\(album)“ enthält \(count) weitere Fotos, die nicht dazugehören. Sie bleiben unverändert.")
        case .albumIsBroaderCollection(let album, let siblings):
            return String(localized: "„\(album)“ ist eine größere Sammlung über \(siblings) Ereignisse und wird nicht als Reisealbum verwendet.")
        case .sameNameDifferentContent(let album, let shared):
            return String(localized: "Es gibt schon ein Album „\(album)“, aber mit anderem Inhalt (\(shared) gemeinsame Fotos).")
        case .albumNotEditable(let album):
            return String(localized: "„\(album)“ kann nicht bearbeitet werden (z. B. geteiltes Album).")
        case .severalAlbumsMatch(let count):
            return String(localized: "\(count) Alben passen ähnlich gut. Albumist ergänzt erst, wenn du eines ausgewählt hast.")
        case .weakOverlapOnly(let album, let shared):
            return String(localized: "„\(album)“ hat nur \(shared) gemeinsame Fotos.")
        case .noExistingAlbum:
            return String(localized: "Es gibt noch kein passendes Album.")
        case .keptUnchangedUntilChosen(let album):
            return String(localized: "Albumist legt ein neues Album an und ändert „\(album)“ nicht. Unter „Anpassen“ kannst du stattdessen „\(album)“ ergänzen.")
        }
    }
}

extension ProposalDecision {
    var isCreatingNew: Bool {
        if case .createNew = self { return true }
        return false
    }
}

extension OverallStatus {
    var label: LocalizedStringKey {
        switch self {
        case .fullyOrganized: "Sortiert"
        case .partiallyOrganized: "Teilweise sortiert"
        case .unorganized: "Nicht sortiert"
        case .ignored: "Ignoriert"
        case .excluded: "Ausgeschlossen"
        case .pending: "Analyse läuft"
        }
    }
}

// MARK: Analysis card (progress display v3)

extension AnalysisStep {
    /// The card's heading: what is happening now.
    var label: LocalizedStringKey {
        switch self {
        case .library: "Mediathek wird gelesen"
        case .trips: "Reisen werden erkannt"
        case .places: "Orte werden bestimmt"
        case .content: "Bildinhalte werden erkannt"
        case .text: "Text auf Screenshots wird gelesen"
        case .proposals: "Vorschläge werden erstellt"
        }
    }

    var labelText: String {
        switch self {
        case .library: String(localized: "Mediathek wird gelesen")
        case .trips: String(localized: "Reisen werden erkannt")
        case .places: String(localized: "Orte werden bestimmt")
        case .content: String(localized: "Bildinhalte werden erkannt")
        case .text: String(localized: "Text auf Screenshots wird gelesen")
        case .proposals: String(localized: "Vorschläge werden erstellt")
        }
    }

    /// The Details sheet lists the steps (a list, not a state: T14).
    var listName: LocalizedStringKey {
        switch self {
        case .library: "Mediathek lesen"
        case .trips: "Reisen erkennen"
        case .places: "Orte bestimmen"
        case .content: "Bildinhalte erkennen"
        case .text: "Text auf Screenshots lesen"
        case .proposals: "Vorschläge erstellen"
        }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .library: "Welche Fotos es gibt, mit Datum und Ort."
        case .trips: "Aus Datum und Ort deiner Fotos."
        case .places: "Länder auf dem iPhone, Städtenamen von Apple."
        case .content: "Was auf den Fotos zu sehen ist. Der längste Schritt."
        case .text: "Nur Screenshots und Dokumente."
        case .proposals: "Alben, die zu deinen Fotos passen."
        }
    }
}

/// Texts of the analysis card, shared with the Lock Screen (one source for both).
enum AnalysisText {
    /// "von 5.683 Fotos" (the unit of the step, singular and plural in the catalog: T6, T7).
    static func ofTotal(_ total: Int, _ unit: AnalysisStep.Unit) -> String {
        switch unit {
        case .photos: String(localized: "von \(total) Fotos")
        case .places: String(localized: "von \(total) Orten")
        case .screenshots: String(localized: "von \(total) Screenshots")
        case .none: ""
        }
    }

    /// The label of a phase of its own after a stop (`ResumedRun.NewWork`): the number starts
    /// again from this phase's own start, and the label says why.
    static func newWork(_ cause: ResumedRun.NewWork) -> String {
        switch cause {
        case .newPhotos: String(localized: "Neue Fotos werden analysiert")
        case .afterUpdate: String(localized: "Analyse nach Update")
        case .moreNewPhotos: String(localized: "Weitere neue Fotos werden analysiert")
        case .afterUpdateAgain: String(localized: "Analyse nach erneutem Update")
        case .newAreas: String(localized: "Fotos werden für die neuen Bereiche angesehen")
        }
    }

    /// "12.000 von 50.233 mit der Karte geprüft": the places step's pass over the offline map.
    static func mapChecked(_ pass: AnalysisPipeline.MapPass) -> String {
        String(localized: "\(pass.checked.formatted()) von \(pass.of.formatted()) mit der Karte geprüft")
    }

    /// "Ortsnamen: Apple erlaubt nur einige Abfragen pro Minute · weiter in 25 s": the places step
    /// waits for the limit of Apple's geocoder (the overnight refinement only). Whole seconds up
    /// to a minute, whole minutes above ("weiter in 2 Minuten"), rounded up (`AppleWaitCountdown`):
    /// never less than is left, never 0 while it still waits.
    static func appleWait(_ left: Duration) -> String {
        switch AppleWaitCountdown(left) {
        case .seconds(let seconds):
            String(localized: "Ortsnamen: Apple erlaubt nur einige Abfragen pro Minute · weiter in \(seconds) s")
        case .minutes(let minutes):
            String(localized: "Ortsnamen: Apple erlaubt nur einige Abfragen pro Minute · weiter in \(minutes) Minuten")
        }
    }

    /// "2.431 von 5.683 Fotos", number first.
    static func count(_ position: AnalysisCardState.Position) -> String {
        position.completed.formatted() + " " + ofTotal(position.total, position.step.unit)
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// "Fertig gegen 23:40", "Fertig morgen gegen 7:10", "Fertig Dienstag gegen 9:00",
    /// "Gleich fertig" (point 1).
    static func finish(_ estimate: FinishEstimate, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch estimate {
        case .soon:
            return String(localized: "Gleich fertig")
        case .at(let date):
            let time = time(date)
            switch FinishEstimate.day(of: date, now: now, calendar: calendar) {
            case .today: return String(localized: "Fertig gegen \(time)")
            case .tomorrow: return String(localized: "Fertig morgen gegen \(time)")
            case .weekday: return String(localized: "Fertig \(date.formatted(.dateTime.weekday(.wide))) gegen \(time)")
            case .date: return String(localized: "Fertig \(date.formatted(.dateTime.day().month())) gegen \(time)")
            }
        }
    }

    /// The Lock Screen while running (point 5): "2.431 von 5.683 Fotos · fertig gegen 23:40";
    /// without a time to trust only the count.
    static func lockScreen(_ position: AnalysisCardState.Position, finish: FinishEstimate?, now: Date = Date()) -> String {
        let count = count(position)
        switch finish {
        case nil: return count
        case .soon?: return String(localized: "\(count) · gleich fertig")
        case .at(let date)?:
            let time = time(date)
            switch FinishEstimate.day(of: date, now: now, calendar: .current) {
            case .today: return String(localized: "\(count) · fertig gegen \(time)")
            case .tomorrow: return String(localized: "\(count) · fertig morgen gegen \(time)")
            default: return count
            }
        }
    }

    /// "noch etwa 12 Min." (Details, at the running step), at least a minute.
    static func left(_ duration: Duration, width: Duration.UnitsFormatStyle.UnitWidth = .abbreviated) -> String {
        let minutes = max(1, Int((Double(duration.components.seconds) / 60).rounded()))
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: width))
    }

    /// "51 Reisen, 38 Orte" (point 3); parts that are zero are left out.
    static func alreadyDone(_ done: AlreadyDone) -> String {
        var parts: [String] = []
        if done.trips > 0 { parts.append(String(localized: "\(done.trips) Reisen")) }
        if done.places > 0 { parts.append(String(localized: "\(done.places) Orte")) }
        return Counted.join(parts, separator: ", ")
    }
}
