import Foundation

/// One photo of a photo grid (design wave 3, DS-21 and DS-06b): "Unsortiert" and the photos of
/// a suggestion show their photos by day in one shared grid (`PhotoGrid` in the app).
public struct PhotoGridEntry: Identifiable, Hashable, Sendable {
    public let id: AssetID
    /// The capture date on the clock where the photo was taken (`LocalTime.wallClock`), read in
    /// UTC: what its name for VoiceOver says, on the day its header says. Nil without a date.
    public let wallClock: Date?

    public init(id: AssetID, wallClock: Date?) {
        self.id = id
        self.wallClock = wallClock
    }
}

/// One day of a photo grid: its header ("Samstag, 12. Oktober", "3 Fotos") and its photos in
/// the grid's order.
public struct PhotoGridSection: Identifiable, Equatable, Sendable {
    /// The day's number (`LocalTime.day`); `Int.max` for the photos without a capture date.
    public let id: Int
    public let title: String
    /// "3 Fotos" / "3 photos": all photos of the day.
    public let countText: String
    public let entries: [PhotoGridEntry]

    public init(id: Int, title: String, countText: String, entries: [PhotoGridEntry]) {
        self.id = id
        self.title = title
        self.countText = countText
        self.entries = entries
    }

    /// A suggestion's days (`PhotoDays.group`: oldest day first, its photos in the suggestion's
    /// order) as the grid's sections, each photo with its wall clock (`wallClock`, from its facts).
    public static func sections(_ days: [PhotoDay], wallClock: (AssetID) -> Date?) -> [PhotoGridSection] {
        days.map { day in
            PhotoGridSection(id: day.id, title: day.title, countText: day.countText,
                             entries: day.ids.map { PhotoGridEntry(id: $0, wallClock: wallClock($0)) })
        }
    }
}

/// The photos of the tab "Unsortiert" (each of its filters) by day, as Photos shows its days
/// (design wave 3, DS-21 "Unsortiert nach Tagen wie in Fotos").
///
/// - Each photo is on the day of the clock where it was taken (decision of 19.11.2026,
///   "Ortszeit wie in Apple Fotos"), read as the photo view reads it (`PhotoTitle`): with facts
///   on the clock of its facts (`AssetFacts.timeZone`, the iPhone's for facts made without
///   one); a photo Albumist has no facts of yet on the clock its facts will get
///   (`PhotoTitle.zoneWithoutFacts`: the home clock once the analysis keeps one). So a photo
///   keeps its day when the analysis reaches it; only a place found later moves it to the day
///   of that place's clock, as it moves its title in the photo view.
/// - The newest day first: the tab is an inbox of what is left to sort, it opens at the top
///   with its filters and count, and the photos taken last are the ones most often sorted next
///   (Mail and Messages list the newest first too). Within a day the photos run in the order
///   they were taken, as Photos and the suggestion's days show a day. The photos without a
///   capture date come last, under "Ohne Datum".
/// - The headers say "Heute" and "Gestern" for the two latest days on the iPhone's clock, else
///   the weekday and date ("Samstag, 12. Oktober"), with the year when it is not this year.
///
/// Made off the main thread (`AppModel.inboxDays`): grouping 100,000 photos reads every photo's
/// facts. The grid shows whole days page by page (`shownDays`).
public struct InboxDays: Equatable, Sendable {
    /// The days in the grid's order.
    public let sections: [PhotoGridSection]
    /// How many photos come before each day.
    private let before: [Int]
    /// All photos of all days.
    public let photoCount: Int

    public init() {
        self.init(sections: [])
    }

    init(sections: [PhotoGridSection]) {
        self.sections = sections
        var before: [Int] = []
        before.reserveCapacity(sections.count)
        var count = 0
        for section in sections {
            before.append(count)
            count += section.entries.count
        }
        self.before = before
        photoCount = count
    }

    /// `items` (an area of `LibraryBuckets`, newest first) by day. `facts`: the model's facts by
    /// id; `homeZone`: the clock the analysis keeps for photos without a place
    /// (`AppModel.homeTimeZone`), nil before the first analysis kept one; `now` and
    /// `currentZone` say which day is "Heute". `shouldStop` is asked every few thousand photos:
    /// `true` ends the work early with nil (newer photos are on their way).
    public static func make(_ items: [LibraryBuckets.Item], facts: FactsByID, homeZone: TimeZone?, now: Date,
                            currentZone: TimeZone, words: ProposalWords = .german,
                            shouldStop: () -> Bool = { false }) -> InboxDays? {
        if shouldStop() { return nil }
        // Photos of a day in the order given (newest first), turned around below.
        var byDay: [Int: [PhotoGridEntry]] = [:]
        var undated: [PhotoGridEntry] = []
        for (index, item) in items.enumerated() {
            if index % 5_000 == 4_999, shouldStop() { return nil }
            guard let date = item.date else {
                undated.append(PhotoGridEntry(id: item.id, wallClock: nil))
                continue
            }
            let zone = clock(of: facts[item.id], homeZone: homeZone, currentZone: currentZone)
            let wall = LocalTime.wallClock(date, in: zone)
            byDay[LocalTime.day(wall), default: []].append(PhotoGridEntry(id: item.id, wallClock: wall))
        }
        if shouldStop() { return nil }
        let today = CalendarDay(wallClock: LocalTime.wallClock(now, in: currentZone))
        var sections: [PhotoGridSection] = []
        sections.reserveCapacity(byDay.count + 1)
        for number in byDay.keys.sorted(by: >) {
            guard let newestFirst = byDay[number] else { continue }
            let day = CalendarDay(number: number)
            sections.append(PhotoGridSection(id: number, title: title(of: day, today: today, words: words),
                                             countText: words.photos(newestFirst.count), entries: newestFirst.reversed()))
        }
        if !undated.isEmpty {
            sections.append(PhotoGridSection(id: .max, title: words.noDate, countText: words.photos(undated.count),
                                             entries: undated))
        }
        return InboxDays(sections: sections)
    }

    /// The zone of the clock a photo is read on, as the photo view reads it (`PhotoTitle`): its
    /// facts' (the iPhone's for facts made without a zone); without facts the one its facts will
    /// get (`PhotoTitle.zoneWithoutFacts`). Whether Photos knows its location is not known here:
    /// it counts as without one, the home clock, which is the iPhone's until an analysis keeps
    /// another one.
    public static func clock(of facts: AssetFacts?, homeZone: TimeZone?, currentZone: TimeZone) -> TimeZone {
        guard let facts else {
            return PhotoTitle.zoneWithoutFacts(located: false, homeZone: homeZone, currentZone: currentZone)
        }
        return facts.timeZone ?? currentZone
    }

    /// "Heute" and "Gestern" for today and yesterday; else the day as the suggestion's days head
    /// theirs ("Samstag, 12. Oktober"), with the year when it is not this year. A day after
    /// today (a camera clock set wrong) says its date, never "Morgen".
    static func title(of day: CalendarDay, today: CalendarDay, words: ProposalWords) -> String {
        switch today.number - day.number {
        case 0: return words.t("Heute", "Today")
        case 1: return words.t("Gestern", "Yesterday")
        default: return words.dayTitle(day, withYear: day.year != today.year)
        }
    }

    /// How many days the grid shows when `photos` photos are asked for: whole days, up to and
    /// including the day that reaches that number, so a day's header never counts photos that
    /// are not shown yet. At least one day while there is one.
    public func shownDays(forPhotos photos: Int) -> Int {
        guard !sections.isEmpty else { return 0 }
        guard photos < photoCount else { return sections.count }
        // The last day that starts before `photos` photos are shown.
        var low = 0, high = sections.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if before[mid] < photos { low = mid } else { high = mid - 1 }
        }
        return max(1, low + 1)
    }

    /// The photos of the first `days` days.
    public func photos(inFirst days: Int) -> Int {
        guard days > 0 else { return 0 }
        guard days < sections.count else { return photoCount }
        return before[days]
    }
}
