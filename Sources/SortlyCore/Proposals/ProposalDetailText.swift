import Foundation

/// What the open suggestion says under its cover (E2): the sign that nothing is in Photos yet,
/// the count with the days ("16 Fotos · 12. bis 16. Oktober") and where the album goes ("Kommt
/// als neues Album in „Reisen“").
public struct ProposalDetailText: Equatable, Sendable {
    /// "Vorschlag · noch nicht in Fotos"; for the user's own album "Vorschlag · noch nicht
    /// ergänzt"; with everything in it already "Schon in Fotos". It stays until the album is
    /// created (test cases of the design report, slice 2).
    public let pill: String
    /// "16 Fotos · 12. bis 16. Oktober": the year only where the title does not name it.
    public let facts: String
    /// Where the photos go, from the plan's own folder and album (`ProposalOutcome`).
    public let destination: String

    public init(card: ProposalCardText, days: [PhotoDay], words: ProposalWords = .german) {
        switch card.outcome {
        case .addsTo: pill = words.notAddedYet
        case .alreadyIn: pill = words.alreadyInPhotos
        case .newAlbum, .needsName, .chooseAlbum: pill = words.notInPhotosYet
        }

        var facts = [words.photos(card.photoCount)]
        let dated = days.compactMap(\.day)
        if let first = dated.min(), let last = dated.max() {
            let a = CalendarDay(wallClock: Date(timeIntervalSinceReferenceDate: Double(first) * 86_400))
            let b = CalendarDay(wallClock: Date(timeIntervalSinceReferenceDate: Double(last) * 86_400))
            // "Kyoto, Oktober 2024" names its year; "Lissabon" does not.
            let named = a.year == b.year && card.title.contains(String(a.year))
            facts.append(words.span(from: a, to: b, withYear: !named))
        }
        self.facts = facts.joined(separator: " · ")

        switch card.outcome {
        case .newAlbum(_, let path), .needsName(let path): destination = words.newAlbum(in: path)
        case .addsTo(_, let title, _): destination = words.addsTo(album: title)
        case .alreadyIn(_, let title): destination = words.alreadyIn(album: title)
        case .chooseAlbum: destination = words.severalAlbums
        }
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
        var byDay: [Int: [AssetID]] = [:]
        var calendarDays: [Int: CalendarDay] = [:]
        var undated: [AssetID] = []
        for id in ids {
            guard let wall = facts[id]?.wallClock(or: fallback) else {
                undated.append(id)
                continue
            }
            let day = CalendarDay(wallClock: wall)
            byDay[day.number, default: []].append(id)
            if calendarDays[day.number] == nil { calendarDays[day.number] = day }
        }
        let numbers = byDay.keys.sorted()
        let years = Set(calendarDays.values.map(\.year))
        var result = numbers.compactMap { number -> PhotoDay? in
            guard let members = byDay[number], let day = calendarDays[number] else { return nil }
            return PhotoDay(day: number, title: words.dayTitle(day, withYear: years.count > 1),
                            countText: words.photos(members.count), ids: members)
        }
        if !undated.isEmpty {
            result.append(PhotoDay(day: nil, title: words.noDate, countText: words.photos(undated.count), ids: undated))
        }
        return result
    }
}
