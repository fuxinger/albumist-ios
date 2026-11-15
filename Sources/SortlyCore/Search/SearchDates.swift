import Foundation

/// Holidays people search their photos by. Each is a window around the day (photos of a
/// New Year's Eve party are taken after midnight too) plus, where Vision recognizes it,
/// the scene itself: a Christmas tree photographed on 18 December is a Christmas photo.
public enum Holiday: String, Sendable, Hashable, CaseIterable {
    case christmasEve, christmas, newYearsEve, newYearsDay, easter, pentecost, carnival, halloween,
         valentinesDay, stNicholas, thanksgiving

    public var german: String {
        switch self {
        case .christmasEve: "Heiligabend"
        case .christmas: "Weihnachten"
        case .newYearsEve: "Silvester"
        case .newYearsDay: "Neujahr"
        case .easter: "Ostern"
        case .pentecost: "Pfingsten"
        case .carnival: "Karneval"
        case .halloween: "Halloween"
        case .valentinesDay: "Valentinstag"
        case .stNicholas: "Nikolaus"
        case .thanksgiving: "Thanksgiving"
        }
    }

    public var english: String {
        switch self {
        case .christmasEve: "Christmas Eve"
        case .christmas: "Christmas"
        case .newYearsEve: "New Year's Eve"
        case .newYearsDay: "New Year's Day"
        case .easter: "Easter"
        case .pentecost: "Pentecost"
        case .carnival: "Carnival"
        case .halloween: "Halloween"
        case .valentinesDay: "Valentine's Day"
        case .stNicholas: "St. Nicholas"
        case .thanksgiving: "Thanksgiving"
        }
    }

    /// Vision identifiers that show the holiday itself, whatever the date.
    var labels: [String] {
        switch self {
        case .christmas: ["christmas_tree", "christmas_decoration", "santa_claus"]
        case .easter: ["easter_egg"]
        case .halloween: ["jack_o_lantern"]
        case .carnival: ["carnival"]
        case .thanksgiving: ["thanksgiving"]
        default: []
        }
    }

    /// The window of the holiday in `year`, in the calendar's time zone.
    func window(year: Int, calendar: Calendar) -> DateInterval? {
        func day(_ month: Int, _ day: Int, _ y: Int = year) -> Date? {
            calendar.date(from: DateComponents(year: y, month: month, day: day))
        }
        func days(_ start: Date?, _ count: Int, extraHours: Int = 0) -> DateInterval? {
            guard let start, let end = calendar.date(byAdding: DateComponents(day: count, hour: extraHours), to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        let easterSunday = Self.easterSunday(year: year).flatMap { day($0.month, $0.day) }
        func fromEaster(_ offset: Int) -> Date? { easterSunday.flatMap { calendar.date(byAdding: .day, value: offset, to: $0) } }
        switch self {
        case .christmasEve: return days(day(12, 24), 1, extraHours: 3)
        // In German-speaking countries Christmas is celebrated from the evening of the 24th.
        case .christmas: return days(day(12, 24), 3)
        // Midnight and the first hours of the new year belong to the party.
        case .newYearsEve: return days(day(12, 31), 1, extraHours: 6)
        case .newYearsDay: return days(day(1, 1), 1)
        // Good Friday to Easter Monday.
        case .easter: return days(fromEaster(-2), 4)
        // Whit Sunday and Whit Monday.
        case .pentecost: return days(fromEaster(49), 2)
        // Weiberfastnacht (Thursday) to Shrove Tuesday.
        case .carnival: return days(fromEaster(-52), 6)
        case .halloween: return days(day(10, 31), 1, extraHours: 3)
        case .valentinesDay: return days(day(2, 14), 1)
        case .stNicholas: return days(day(12, 6), 1)
        case .thanksgiving:
            // Fourth Thursday of November.
            guard let first = day(11, 1) else { return nil }
            let weekday = calendar.component(.weekday, from: first)   // 1 = Sunday … 5 = Thursday
            let firstThursday = 1 + (5 - weekday + 7) % 7
            return days(day(11, firstThursday + 21), 1)
        }
    }

    /// Easter Sunday in the Gregorian calendar (anonymous Gregorian algorithm).
    static func easterSunday(year: Int) -> (month: Int, day: Int)? {
        guard year > 1582 else { return nil }
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return (month, day)
    }
}

/// Meteorological seasons, as people mean them ("Sommer" = June to August).
enum SearchSeason: Int, Sendable, CaseIterable {
    case spring, summer, autumn, winter

    var months: [Int] {
        switch self {
        case .spring: [3, 4, 5]
        case .summer: [6, 7, 8]
        case .autumn: [9, 10, 11]
        case .winter: [12, 1, 2]
        }
    }

    var german: String { ["Frühling", "Sommer", "Herbst", "Winter"][rawValue] }
    var english: String { ["Spring", "Summer", "Autumn", "Winter"][rawValue] }

    /// The season that starts in `year` (winter: December of `year` to February).
    func occurrence(year: Int, calendar: Calendar) -> DateInterval? {
        let startMonth = months[0]
        guard let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1)),
              let end = calendar.date(byAdding: .month, value: 3, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The most recent season of this kind that is over ("letzten Sommer" in November is
    /// this year's summer, in July it is last year's).
    func last(before now: Date, calendar: Calendar) -> DateInterval? {
        let year = calendar.component(.year, from: now)
        for y in stride(from: year, through: year - 2, by: -1) {
            if let o = occurrence(year: y, calendar: calendar), o.end <= now { return o }
        }
        return nil
    }

    /// The season of this kind in the current year ("diesen Sommer"); for winter the one
    /// that runs now or starts this December.
    func current(at now: Date, calendar: Calendar) -> DateInterval? {
        let year = calendar.component(.year, from: now)
        if self == .winter, calendar.component(.month, from: now) <= 2 { return occurrence(year: year - 1, calendar: calendar) }
        return occurrence(year: year, calendar: calendar)
    }
}

/// Readable forms of resolved periods for the interpretation chips, so the user sees what
/// "letzte Woche" was taken to mean.
enum SearchDateFormat {
    static func locale(_ english: Bool) -> Locale { Locale(identifier: english ? "en_US" : "de_DE") }

    static func formatter(_ format: String, english: Bool, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale(english)
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(format)
        return f
    }

    static func day(_ date: Date, english: Bool, calendar: Calendar) -> String {
        formatter("yMMMd", english: english, calendar: calendar).string(from: date)
    }

    static func month(_ month: Int, english: Bool) -> String {
        let f = DateFormatter()
        f.locale = locale(english)
        return f.standaloneMonthSymbols[(month - 1 + 12) % 12]
    }

    static func weekday(_ weekday: Int, english: Bool) -> String {
        let f = DateFormatter()
        f.locale = locale(english)
        return f.standaloneWeekdaySymbols[(weekday - 1 + 7) % 7]
    }

    /// "14. Nov. 2026", "2.–8. Nov. 2026", "Juli 2025", "2024".
    static func interval(_ interval: DateInterval, english: Bool, calendar: Calendar) -> String {
        let start = interval.start
        let last = interval.end.addingTimeInterval(-1)
        let sameDay = calendar.isDate(start, inSameDayAs: last)
        if sameDay { return day(start, english: english, calendar: calendar) }
        if let year = calendar.dateInterval(of: .year, for: start), year.start == start, year.end == interval.end {
            return String(calendar.component(.year, from: start))
        }
        if let month = calendar.dateInterval(of: .month, for: start), month.start == start, month.end == interval.end {
            return formatter("yMMMM", english: english, calendar: calendar).string(from: start)
        }
        let f = DateIntervalFormatter()
        f.locale = locale(english)
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: start, to: last)
    }
}
