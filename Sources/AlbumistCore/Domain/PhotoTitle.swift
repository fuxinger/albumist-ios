import Foundation

/// The photo view's title (design wave 2, DS-10: "Datum und Ort als Titel", as in Apple's Photos
/// app; before: "1 von 176"). The place where the photo was taken is the title when Albumist
/// knows it, with the day and the time on the line below ("München" / "12. Oktober 2024 ·
/// 14:32"); without a place the day is the title and the time the line below.
///
/// Day and time are those of the clock where the photo was taken (decision of 19.11.2026,
/// "Ortszeit am Aufnahmeort wie Apple Fotos", `LocalTime`): a photo taken in New York at 23:00
/// says 23:00 on an iPhone set to German time. The days of the last week say "Heute", "Gestern"
/// or their weekday, older days their date, with the year only when it is not this year; a day
/// after today (a camera clock set wrong, a photo from Tokyo) says its date, never "Morgen".
///
/// Only a place from the photo's location or one the user chose counts (`AssetFacts.gpsPlace`):
/// one guessed from the picture says nothing about where it was taken. Names stay whole here;
/// the bar shortens them on screen, VoiceOver reads them whole (`spoken`).
public struct PhotoTitle: Equatable, Sendable {
    /// The clock the time is told on: the iPhone's setting; without one, the language's usual
    /// clock (German 24 hours, English 12 hours).
    public enum Clock: Equatable, Sendable {
        case twentyFourHour, twelveHour
    }

    /// The bar's first line: the place; else the day; else "Ohne Datum" (no capture date) or
    /// "Foto" (nothing known of the photo yet).
    public let title: String
    /// The line below: day and time under a place, the time under a day; nil without a date.
    public let subtitle: String?
    /// What VoiceOver reads, in order: place, day, time.
    private let parts: [String]

    private init(title: String, subtitle: String?, parts: [String]) {
        self.title = title
        self.subtitle = subtitle
        self.parts = parts
    }

    /// - Parameters:
    ///   - date: The capture instant; nil when the photo has none.
    ///   - zone: The zone of the clock where it was taken (`AssetFacts.timeZone`); nil: the
    ///     iPhone's zone counts, as for facts made without zones.
    ///   - now: This moment; `currentZone` the iPhone's zone, whose day is "Heute".
    public init(date: Date?, zone: TimeZone?, place: PlaceComponents?, now: Date, currentZone: TimeZone,
                words: ProposalWords = .german, clock: Clock? = nil) {
        let placeName = Self.placeName(place)
        guard let date else {
            let title = placeName ?? words.noDate
            self.init(title: title, subtitle: nil, parts: [title])
            return
        }
        let wallClock = LocalTime.wallClock(date, in: zone ?? currentZone)
        let today = CalendarDay(wallClock: LocalTime.wallClock(now, in: currentZone))
        let day = Self.day(CalendarDay(wallClock: wallClock), today: today, words: words)
        let time = Self.time(wallClock, clock: clock ?? (words.isGerman ? .twentyFourHour : .twelveHour))
        if let placeName {
            self.init(title: placeName, subtitle: day + " · " + time, parts: [placeName, day, time])
        } else {
            self.init(title: day, subtitle: time, parts: [day, time])
        }
    }

    /// The title of a photo by what Albumist knows of it; without facts (not analysed yet):
    /// "Foto", as the photo itself is called.
    public init(facts: AssetFacts?, now: Date, currentZone: TimeZone, words: ProposalWords = .german, clock: Clock? = nil) {
        guard let facts else {
            let photo = words.t("Foto", "Photo")
            self.init(title: photo, subtitle: nil, parts: [photo])
            return
        }
        self.init(date: facts.asset.creationDate, zone: facts.timeZone, place: facts.gpsPlace, now: now,
                  currentZone: currentZone, words: words, clock: clock)
    }

    /// Title and line as one sentence for VoiceOver ("München, 12. Oktober 2024, 14:32"); a
    /// Live Photo says so at the end.
    public func spoken(live: Bool = false) -> String {
        (parts + (live ? ["Live Photo"] : [])).joined(separator: ", ")
    }

    /// The place's name as Photos names a photo's place: the town; on the water the lake or the
    /// sea; else the region; else the country. Neither a district nor a street, never a blank.
    public static func placeName(_ place: PlaceComponents?) -> String? {
        guard let place else { return nil }
        let names = [place.locality, place.inlandWater, place.ocean, place.administrativeArea, place.country]
        for name in names {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return nil
    }

    // MARK: Day and time

    /// "Heute", "Gestern", the weekday for the rest of the last week, else the date, with the
    /// year when it is not this year's.
    private static func day(_ day: CalendarDay, today: CalendarDay, words: ProposalWords) -> String {
        switch today.number - day.number {
        case 0: return words.t("Heute", "Today")
        case 1: return words.t("Gestern", "Yesterday")
        case 2...6: return words.weekday(day.weekday)
        default: return words.span(from: day, to: day, withYear: day.year != today.year)
        }
    }

    /// "14:32" / "2:32 PM" (a narrow space before the AM or PM, as iOS writes it).
    private static func time(_ wallClock: Date, clock: Clock) -> String {
        let midnight = Double(LocalTime.day(wallClock)) * 86_400
        let seconds = min(max(Int((wallClock.timeIntervalSinceReferenceDate - midnight).rounded(.down)), 0), 86_399)
        let hour = seconds / 3_600, minute = seconds % 3_600 / 60
        let minutes = minute < 10 ? "0\(minute)" : "\(minute)"
        switch clock {
        case .twentyFourHour:
            return (hour < 10 ? "0\(hour)" : "\(hour)") + ":" + minutes
        case .twelveHour:
            let shown = hour % 12 == 0 ? 12 : hour % 12
            return "\(shown):\(minutes)\u{202F}" + (hour < 12 ? "AM" : "PM")
        }
    }
}
