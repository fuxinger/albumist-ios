import Foundation

/// "Reise anpassen" as a timeline of the trip's days (design wave 3, DS-14): what each day shows
/// beside the split `TripWorkshop` makes. Pure, so the sheet only draws it.
///
/// - A day: its date, where it was (the town as Photos names a photo's place,
///   `PhotoTitle.placeName`; a second town when it holds at least a third of the day's photos
///   with a place, as on a day trip), and up to `photosPerDay` larger photos spread over the
///   day (`PreviewPicker.pick`: ordinary photos first, screenshots and documents only to fill,
///   sensitive ones never); "Vorschau ausgeblendet" for a day of nothing but sensitive ones.
/// - Between two days: the days without photos ("1 Tag ohne Fotos").
/// - Where the trip can be split: before every day but the first (`TripWorkshop.split`).
/// - Between this trip and a neighbour: the days without photos a merge would bridge.
/// - All of it at once (`content(of:…)`), so the sheet makes it off the main thread, not in its
///   body at every tap (review G6); the line beside the days (`lines(_:at:cut:)`).
public enum TripTimeline {
    /// One day of the trip as the timeline shows it.
    public struct Day: Hashable, Sendable, Identifiable {
        /// The day and its photos, as the split takes them.
        public var day: TripWorkshop.Day
        /// Where the day was: one town, or two; empty when no photo of it has a place.
        public var places: [String]
        /// The photos it shows, oldest first; empty when it hides its preview.
        public var photos: [AssetID]
        /// Every photo of the day is a sensitive document: "Vorschau ausgeblendet".
        public var hidesPreview: Bool
        /// Calendar days without photos between the day before and this one.
        public var quietDaysBefore: Int
        /// A new trip can start with this day ("Reise teilen"): every day but the first.
        public var canStartNewTrip: Bool

        public var id: Date { day.start }
    }

    /// Photos a day shows at most: three side by side, each larger than a list thumbnail.
    public static let photosPerDay = 3

    /// The timeline of `days` (`TripWorkshop.days`, in `calendar`).
    public static func days(_ days: [TripWorkshop.Day], facts: FactsByID, ranks: [AssetID: PreviewRank],
                            dates: [AssetID: Date], calendar: Calendar, photosPerDay: Int = photosPerDay) -> [Day] {
        days.enumerated().map { index, day in
            let hidden = !day.assetIDs.isEmpty && day.assetIDs.allSatisfy { ranks[$0] == .sensitive }
            return Day(day: day,
                       places: places(of: day.assetIDs, facts: facts),
                       photos: hidden ? [] : PreviewPicker.pick(day.assetIDs, dates: dates, cover: nil, count: photosPerDay, ranks: ranks),
                       hidesPreview: hidden,
                       quietDaysBefore: index == 0 ? 0 : quietDays(from: days[index - 1].start, to: day.start, calendar: calendar),
                       canStartNewTrip: index > 0)
        }
    }

    /// The towns of `ids` (oldest first): the one with the most photos with a place, and a second
    /// one when it holds at least a third of them; equal counts in the order they were reached.
    static func places(of ids: [AssetID], facts: FactsByID) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for id in ids {
            guard let name = PhotoTitle.placeName(facts[id]?.gpsPlace) else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let located = counts.values.reduce(0, +)
        let ranked = order.enumerated()
            .sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map(\.element)
        guard let first = ranked.first else { return [] }
        let second = ranked.dropFirst().first.flatMap { 3 * counts[$0]! >= located ? $0 : nil }
        return [first] + (second.map { [$0] } ?? [])
    }

    /// Calendar days without photos between the day of `earlier` and the day of `later`: none
    /// when `later` is the next day (or the same, or before).
    public static func quietDays(from earlier: Date, to later: Date, calendar: Calendar) -> Int {
        let apart = calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier), to: calendar.startOfDay(for: later)).day ?? 0
        return max(0, apart - 1)
    }

    /// From the first to the last photo of `ids` that has a date; nil when none has one.
    public static func span(of ids: some Collection<AssetID>, dates: [AssetID: Date]) -> DateInterval? {
        var first: Date?, last: Date?
        for id in ids {
            guard let date = dates[id] else { continue }
            if first.map({ date < $0 }) ?? true { first = date }
            if last.map({ date > $0 }) ?? true { last = date }
        }
        guard let first, let last else { return nil }
        return DateInterval(start: first, end: last)
    }

    // MARK: All at once

    /// What the timeline shows of a trip, made in one piece (`content(of:…)`).
    public struct Content: Hashable, Sendable {
        /// The trip's days, oldest first (`days(_:facts:ranks:dates:calendar:)`).
        public var days: [Day]
        /// Calendar days without photos between the trip before it and its first photo; nil
        /// without a trip before, or when either has no dated photo.
        public var quietDaysFromBefore: Int?
        /// Calendar days without photos between its last photo and the trip after it; nil the same.
        public var quietDaysToAfter: Int?

        public init(days: [Day] = [], quietDaysFromBefore: Int? = nil, quietDaysToAfter: Int? = nil) {
            self.days = days
            self.quietDaysFromBefore = quietDaysFromBefore
            self.quietDaysToAfter = quietDaysToAfter
        }
    }

    /// What the timeline reads of the library: the photos' facts, their preview ranks and dates,
    /// and the calendar the split uses.
    public struct Library: Sendable {
        public var facts: FactsByID
        public var ranks: [AssetID: PreviewRank]
        public var dates: [AssetID: Date]
        public var calendar: Calendar

        public init(facts: FactsByID, ranks: [AssetID: PreviewRank], dates: [AssetID: Date], calendar: Calendar) {
            self.facts = facts
            self.ranks = ranks
            self.dates = dates
            self.calendar = calendar
        }
    }

    /// The timeline of the trip of `photos`, with the trips right `before` and `after` it (their
    /// photos; nil: none): its days as the split takes them (`TripWorkshop.days`), what each one
    /// shows, and the days without photos a merge would bridge. One pass over the trip's photos,
    /// one over each neighbour's.
    public static func content(of photos: some Collection<AssetID>, before: Set<AssetID>?, after: Set<AssetID>?,
                               in library: Library) -> Content {
        let (dates, calendar) = (library.dates, library.calendar)
        let made = days(TripWorkshop.days(of: photos, dates: dates, calendar: calendar), facts: library.facts,
                        ranks: library.ranks, dates: dates, calendar: calendar)
        let trip = span(of: photos, dates: dates)
        let earlier = before.flatMap { span(of: $0, dates: dates) }
        let later = after.flatMap { span(of: $0, dates: dates) }
        return Content(days: made,
                       quietDaysFromBefore: trip.flatMap { trip in earlier.map { quietDays(from: $0.end, to: trip.start, calendar: calendar) } },
                       quietDaysToAfter: trip.flatMap { trip in later.map { quietDays(from: trip.end, to: $0.start, calendar: calendar) } })
    }

    // MARK: The line

    /// How the line beside the days runs: solid between two days of the trip, dotted over days
    /// without photos.
    public enum Stroke: Hashable, Sendable {
        case solid, dotted
    }

    /// The line at one day of the timeline (`lines(_:at:cut:)`); nil: none.
    public struct Lines: Hashable, Sendable {
        /// From the top of the day's row to its mark.
        public var above: Stroke?
        /// From the day's mark to the bottom of its row.
        public var below: Stroke?
        /// Through the days without photos right before the day (`Day.quietDaysBefore`).
        public var gap: Stroke?

        public init(above: Stroke? = nil, below: Stroke? = nil, gap: Stroke? = nil) {
            self.above = above
            self.below = below
            self.gap = gap
        }
    }

    /// How the line runs at day `index` of `days` when the second trip of a split begins with day
    /// `cut` (nil: no split chosen). Solid between two days, dotted over the days without photos
    /// between them; none above the first day or below the last (the trips before and after it
    /// are sections of their own). None between the two trips the split makes: not above the
    /// day it begins with, not below the day before, and not over the days without photos
    /// between them (review G8: the dotted line ran on into the cut there).
    public static func lines(_ days: [Day], at index: Int, cut: Int?) -> Lines {
        guard days.indices.contains(index) else { return Lines() }
        let quietBefore = days[index].quietDaysBefore > 0
        let above: Stroke? = index == 0 || cut == index ? nil : (quietBefore ? .dotted : .solid)
        let below: Stroke? = index == days.count - 1 || cut == index + 1
            ? nil : (days[index + 1].quietDaysBefore > 0 ? .dotted : .solid)
        let gap: Stroke? = quietBefore && cut != index ? .dotted : nil
        return Lines(above: above, below: below, gap: gap)
    }
}
