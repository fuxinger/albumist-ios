import Foundation

/// The photo view's title (design wave 2, DS-10: "Datum und Ort als Titel", as in Apple's Photos
/// app; before: "1 von 176"). The place where the photo was taken is the title when Albumist
/// knows it, with the day and the time on the line below ("München" / "12. Oktober 2024 ·
/// 14:32"); without a place the day is the title and the time the line below.
///
/// Day and time are those of the clock where the photo was taken (decision of 19.11.2026,
/// "Ortszeit am Aufnahmeort wie Apple Fotos", `LocalTime`): a photo taken in New York at 23:00
/// says 23:00 on an iPhone set to German time. "Heute" and "Gestern" are read on that same clock
/// (review D, M1: a photo taken a minute ago in another zone said its date). The days of the
/// last week say "Heute", "Gestern" or their weekday, older days their date, with the year only
/// when it is not this year; a day after today on that clock (a camera clock set wrong) says its
/// date, never "Morgen".
///
/// Only a place from the photo's location or one the user chose counts (`AssetFacts.gpsPlace`):
/// one guessed from the picture says nothing about where it was taken. Names stay whole here;
/// the bar shortens them on screen, VoiceOver reads them whole (`spoken`).
public struct PhotoTitle: Equatable, Sendable {
    /// The clock the time is told on: the iPhone's setting; without one, the language's usual
    /// clock (German 24 hours, English 12 hours).
    public enum Clock: Equatable, Sendable {
        case twentyFourHour, twelveHour

        /// The clock of an hour cycle (`Locale.current.hourCycle`: the iPhone's choice in
        /// Settings › General › Date & Time, else its region's; review D, L2): 0–11 and 1–12
        /// are the 12-hour clock.
        public init(hourCycle: Locale.HourCycle) {
            self = hourCycle == .zeroToEleven || hourCycle == .oneToTwelve ? .twelveHour : .twentyFourHour
        }
    }

    /// The bar's first line: the place; else the day; else "Ohne Datum" (no capture date) or
    /// "Foto" (nothing known of the photo yet).
    public let title: String
    /// The line below: day and time under a place, the time under a day; nil without a date.
    public let subtitle: String?
    /// Both in their shortest form, for a bar too narrow for the long one (review D, L1: on a
    /// 375-point iPhone the line was cut, and what was cut was the time): an older day in
    /// numbers ("30.09.2024", "01.01.") or with the month's short name ("Sep 30, 2024");
    /// "Heute", "Gestern", the weekdays and the place stay as they are. The time is never
    /// shortened. VoiceOver reads the long form (`spoken`).
    public let shortTitle: String
    public let shortSubtitle: String?
    /// What VoiceOver reads, in order: place, day, time.
    private let parts: [String]

    private init(title: String, subtitle: String?, parts: [String], shortTitle: String? = nil, shortSubtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.parts = parts
        self.shortTitle = shortTitle ?? title
        self.shortSubtitle = shortSubtitle ?? subtitle
    }

    /// - Parameters:
    ///   - date: The capture instant; nil when the photo has none.
    ///   - zone: The zone of the clock where it was taken (`AssetFacts.timeZone`); nil: the
    ///     iPhone's zone counts, as for facts made without zones.
    ///   - now: This moment: "Heute" is its day on the photo's clock (`zone`, else
    ///     `currentZone`, the iPhone's zone).
    public init(date: Date?, zone: TimeZone?, place: PlaceComponents?, now: Date, currentZone: TimeZone,
                words: ProposalWords = .german, clock: Clock? = nil) {
        let placeName = Self.placeName(place)
        guard let date else {
            let title = placeName ?? words.noDate
            self.init(title: title, subtitle: nil, parts: [title])
            return
        }
        let clockZone = zone ?? currentZone
        let wallClock = LocalTime.wallClock(date, in: clockZone)
        let today = CalendarDay(wallClock: LocalTime.wallClock(now, in: clockZone))
        let photoDay = CalendarDay(wallClock: wallClock)
        let day = Self.day(photoDay, today: today, words: words)
        let shortDay = Self.shortDay(photoDay, today: today, words: words) ?? day
        let time = Self.time(wallClock, clock: clock ?? (words.isGerman ? .twentyFourHour : .twelveHour))
        if let placeName {
            self.init(title: placeName, subtitle: day + " · " + time, parts: [placeName, day, time],
                      shortSubtitle: shortDay + " · " + time)
        } else {
            self.init(title: day, subtitle: time, parts: [day, time], shortTitle: shortDay)
        }
    }

    /// The title of a photo by what is known of it. Without facts (Albumist has not analysed it
    /// yet) the date Photos keeps for it (`photoDate`) counts (review D, M7: such a photo said
    /// only "Foto"), on the clock its facts will have (`zoneWithoutFacts`); with neither: "Foto",
    /// as the photo itself is called.
    /// - Parameters:
    ///   - photoLocated: Photos knows where the photo was taken (its location).
    ///   - homeZone: The clock the analysis tells photos without a place on (P1-15), once known.
    public init(facts: AssetFacts?, photoDate: Date? = nil, photoLocated: Bool = false, homeZone: TimeZone? = nil,
                now: Date, currentZone: TimeZone, words: ProposalWords = .german, clock: Clock? = nil) {
        guard let facts else {
            if let photoDate {
                let zone = Self.zoneWithoutFacts(located: photoLocated, homeZone: homeZone, currentZone: currentZone)
                self.init(date: photoDate, zone: zone, place: nil, now: now, currentZone: currentZone, words: words, clock: clock)
                return
            }
            let photo = words.t("Foto", "Photo")
            self.init(title: photo, subtitle: nil, parts: [photo])
            return
        }
        self.init(date: facts.asset.creationDate, zone: facts.timeZone, place: facts.gpsPlace, now: now,
                  currentZone: currentZone, words: words, clock: clock)
    }

    /// The clock of a photo Albumist has no facts of yet: the one its facts will have, so its
    /// title does not change clock once it is analysed (review D2, N10). Without a location the
    /// analysis tells it on the home clock, as every photo without a place (P1-15): `homeZone`
    /// once the analysis has one, before that the iPhone's, which the first analysis keeps as
    /// the home clock. With a location it gets its place's clock, and a photo not analysed yet
    /// was mostly taken a moment ago, where the iPhone is: the iPhone's clock.
    public static func zoneWithoutFacts(located: Bool, homeZone: TimeZone?, currentZone: TimeZone) -> TimeZone {
        located ? currentZone : homeZone ?? currentZone
    }

    /// The photo's info, "Aufgenommen": the whole date and the time on the photo's clock, as the
    /// title tells them ("14. Mai 2024 um 09:18", "May 14, 2024 at 9:18 AM"), never "Heute" or a
    /// weekday. `zone`: the clock where it was taken (`AssetFacts.timeZone`); nil: the iPhone's
    /// (`currentZone`), as in the title. Before, the info told the iPhone's clock and could say
    /// another time than the title above it (design run of 25.11.).
    public static func takenAt(_ date: Date, zone: TimeZone?, currentZone: TimeZone, words: ProposalWords = .german,
                               clock: Clock? = nil) -> String {
        let wallClock = LocalTime.wallClock(date, in: zone ?? currentZone)
        let day = CalendarDay(wallClock: wallClock)
        let time = Self.time(wallClock, clock: clock ?? (words.isGerman ? .twentyFourHour : .twelveHour))
        return words.span(from: day, to: day, withYear: true) + words.t(" um ", " at ") + time
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

    /// An older day in its short form: "30.09.2024" or "01.01." in this year; "Sep 30, 2024" or
    /// "Jan 1". Nil for the days of the last week (and later days): their words are short already.
    private static func shortDay(_ day: CalendarDay, today: CalendarDay, words: ProposalWords) -> String? {
        guard !(0...6).contains(today.number - day.number), (1...12).contains(day.month) else { return nil }
        let withYear = day.year != today.year
        if words.isGerman {
            func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
            return "\(twoDigits(day.day)).\(twoDigits(day.month))." + (withYear ? "\(day.year)" : "")
        }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[day.month - 1]) \(day.day)" + (withYear ? ", \(day.year)" : "")
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
