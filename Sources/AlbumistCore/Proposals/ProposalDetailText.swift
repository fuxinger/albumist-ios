import Foundation

/// What the open suggestion says under its cover (E2): the sign that nothing is in Photos yet,
/// the count with the days ("16 Fotos · 12. bis 16. Oktober") and where the album goes ("Kommt
/// als neues Album in „Reisen“").
public struct ProposalDetailText: Equatable, Sendable {
    /// "Vorschlag · noch nicht in Fotos"; for the user's own album "Vorschlag · noch nicht
    /// ergänzt", or "Vorschlag · noch nicht geändert" when it gets a new name or folder; with
    /// everything in it already "Schon in Fotos". It stays until the album is created (test
    /// cases of the design report, slice 2).
    public let pill: String
    /// "16 Fotos · 12. bis 16. Oktober": the year only where the title does not name it.
    public let facts: String
    /// Where the photos go, from the plan's own folder and album (`ProposalOutcome`).
    public let destination: String

    public init(card: ProposalCardText, days: [PhotoDay], words: ProposalWords = .german) {
        pill = Self.pill(of: card.outcome, words: words)
        var facts = [words.photos(card.photoCount)]
        let dated = days.compactMap(\.day)
        if let first = dated.min(), let last = dated.max() {
            let a = CalendarDay(wallClock: Date(timeIntervalSinceReferenceDate: Double(first) * 86_400))
            let b = CalendarDay(wallClock: Date(timeIntervalSinceReferenceDate: Double(last) * 86_400))
            // "Kyoto, Oktober 2024" names its year; "Lissabon" and "Haus 20245" do not.
            let named = a.year == b.year && Self.names(a.year, in: card.title)
            facts.append(words.span(from: a, to: b, withYear: !named))
        }
        self.facts = facts.joined(separator: " · ")
        destination = Self.destination(of: card.outcome, words: words)
    }

    private static func pill(of outcome: ProposalOutcome, words: ProposalWords) -> String {
        switch outcome {
        case .addsTo: words.notAddedYet
        case .alreadyIn: words.alreadyInPhotos
        case .renames, .moves: words.notChangedYet
        case .newAlbum, .needsName, .chooseAlbum: words.notInPhotosYet
        }
    }

    private static func destination(of outcome: ProposalOutcome, words: ProposalWords) -> String {
        switch outcome {
        case .newAlbum(_, let path), .needsName(let path): words.newAlbum(in: path)
        case .addsTo(_, let title, _): words.addsTo(album: title)
        case .alreadyIn(_, let title): words.alreadyIn(album: title)
        case .renames(_, let from, let to): words.renamed(album: from, to: to)
        case .moves(_, let title, let path): words.moved(album: title, to: path)
        case .chooseAlbum: words.severalAlbums
        }
    }

    /// Whether `title` names `year` as a word of its own ("Kyoto, 2024", "2024: Kyoto"), not
    /// inside a longer one ("Haus 20245", "Kyoto2024").
    static func names(_ year: Int, in title: String) -> Bool {
        let word = String(year)
        return title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == word }
    }
}

/// The photos of one day, as Photos shows its days: each photo on the day of the clock where it
/// was taken (`LocalTime`, decision of 19.11.2026 "Ortszeit wie in Apple Fotos").
public struct PhotoDay: Equatable, Sendable, Identifiable {
    /// The day's number (`LocalTime.day`); nil for the photos without a capture date.
    public let day: Int?
    /// "Samstag, 12. Oktober" / "Saturday, October 12"; "Ohne Datum".
    public let title: String
    /// "3 Fotos" / "3 photos".
    public let countText: String
    /// Its photos in the order they were given (the suggestion's: oldest first).
    public let ids: [AssetID]

    public var id: Int { day ?? .max }
}

public enum PhotoDays {
    /// `ids` by day, oldest day first; the photos of a day keep their order. A photo's day is
    /// that of its own clock (`AssetFacts.wallClock(or:)`; `fallback` for facts made without
    /// a time zone): a photo taken at 23:00 in New York is on that day, also on an iPhone set to
    /// German time. Photos without a capture date (or without facts) come last, under "Ohne
    /// Datum". The headers name the year only when the photos span several years.
    public static func group(_ ids: [AssetID], facts: [AssetID: AssetFacts], fallback: TimeZone,
                             words: ProposalWords = .german) -> [PhotoDay] {
        group(ids, fallback: fallback, words: words) { facts[$0] }
    }

    /// The same with the model's facts by id (`AppModel.factsByID`).
    public static func group(_ ids: [AssetID], facts: FactsByID, fallback: TimeZone,
                             words: ProposalWords = .german) -> [PhotoDay] {
        group(ids, fallback: fallback, words: words) { facts[$0] }
    }

    private static func group(_ ids: [AssetID], fallback: TimeZone, words: ProposalWords,
                              facts: (AssetID) -> AssetFacts?) -> [PhotoDay] {
        var byDay: [Int: [AssetID]] = [:]
        var undated: [AssetID] = []
        for id in ids {
            guard let wall = facts(id)?.wallClock(or: fallback) else {
                undated.append(id)
                continue
            }
            byDay[LocalTime.day(wall), default: []].append(id)
        }
        // The date of each day once, not of each photo.
        let calendarDays = byDay.keys.sorted().map(CalendarDay.init(number:))
        let years = Set(calendarDays.map(\.year))
        var result = calendarDays.compactMap { day -> PhotoDay? in
            guard let members = byDay[day.number] else { return nil }
            return PhotoDay(day: day.number, title: words.dayTitle(day, withYear: years.count > 1),
                            countText: words.photos(members.count), ids: members)
        }
        if !undated.isEmpty {
            result.append(PhotoDay(day: nil, title: words.noDate, countText: words.photos(undated.count), ids: undated))
        }
        return result
    }
}
