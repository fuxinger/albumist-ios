import Foundation

extension TripCorrections {
    /// Splits and merges the user made (photos taken out of trips are counted elsewhere).
    public var changeCount: Int { forcedBreaks.count + forcedJoins.count }

    /// "Reise teilen": a new trip starts at `date`. A split always wins over an earlier merge
    /// (`TripDetector` checks breaks first), so nothing else has to change.
    public func splitting(at date: Date) -> TripCorrections {
        var copy = self
        if !copy.forcedBreaks.contains(date) {
            copy.forcedBreaks.append(date)
            copy.forcedBreaks.sort()
        }
        return copy
    }

    /// "Zusammenlegen": everything inside `interval` stays one trip. Splits the user made
    /// inside it earlier are dropped, otherwise they would still cut the merged trip.
    public func merging(_ interval: DateInterval) -> TripCorrections {
        var copy = self
        copy.forcedBreaks.removeAll { $0 > interval.start && $0 <= interval.end }
        copy.forcedJoins.removeAll { interval.start <= $0.start && $0.end <= interval.end }
        copy.forcedJoins.append(interval)
        copy.forcedJoins.sort { $0.start < $1.start }
        return copy
    }

    /// The user's splits and merges at a trip: a split at its start or shortly after its end
    /// (the other side of a split it came from), a merge over it. Oldest first.
    public func changes(around trip: DateInterval, margin: TimeInterval = 7 * 86_400) -> [TripChange] {
        let window = DateInterval(start: trip.start.addingTimeInterval(-margin), end: trip.end.addingTimeInterval(margin))
        let splits = forcedBreaks.filter { window.contains($0) }.map(TripChange.split)
        let merges = forcedJoins.filter { $0.intersects(trip) }.map(TripChange.merge)
        return (splits + merges).sorted { $0.date < $1.date }
    }

    /// "Aufheben": one split or merge is forgotten, the trips around it are detected again.
    public func removing(_ change: TripChange) -> TripCorrections {
        var copy = self
        switch change {
        case .split(let date): copy.forcedBreaks.removeAll { $0 == date }
        case .merge(let interval): copy.forcedJoins.removeAll { $0 == interval }
        }
        return copy
    }

    /// Back to automatic detection; photos the user took out of trips stay out.
    public func withoutSplitsAndMerges() -> TripCorrections {
        TripCorrections(excludedAssets: excludedAssets)
    }
}

/// One change the user made to the trips.
public enum TripChange: Hashable, Sendable {
    /// A new trip starts at this instant.
    case split(Date)
    /// Everything in this span is one trip.
    case merge(DateInterval)

    public var date: Date {
        switch self {
        case .split(let date): date
        case .merge(let interval): interval.start
        }
    }
}

/// "Reise-Werkstatt" (I07): the pure part of splitting a trip at a day and merging two
/// neighbouring trips. The app shows the days and the preview; the corrections are kept in
/// time (not in ids), so they hold for every later analysis.
public enum TripWorkshop {
    /// One calendar day of a trip with its photos, oldest first.
    public struct Day: Hashable, Sendable, Identifiable {
        public var start: Date
        public var assetIDs: [AssetID]
        public var id: Date { start }
        public var count: Int { assetIDs.count }
    }

    /// One side of a split or the merged trip: its time span and how many photos it holds.
    public struct Part: Hashable, Sendable {
        public var start: Date
        public var end: Date
        public var count: Int
    }

    /// The photos of a trip by calendar day.
    public static func days(of members: some Collection<AssetID>, dates: [AssetID: Date], calendar: Calendar) -> [Day] {
        var byDay: [Date: [(AssetID, Date)]] = [:]
        for id in members {
            guard let date = dates[id] else { continue }
            byDay[calendar.startOfDay(for: date), default: []].append((id, date))
        }
        return byDay.keys.sorted().map { day in
            let photos = byDay[day]!.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            return Day(start: day, assetIDs: photos.map(\.0))
        }
    }

    /// The two trips a split makes.
    public struct Split: Hashable, Sendable {
        public var first: Part
        public var second: Part
    }

    /// The two trips a split before `days[index]` makes. Nil when that would leave one side
    /// empty (the first day cannot start a new trip).
    public static func split(_ days: [Day], before index: Int, dates: [AssetID: Date]) -> Split? {
        guard index > 0, index < days.count else { return nil }
        func part(_ slice: ArraySlice<Day>) -> Part? {
            let ids = slice.flatMap(\.assetIDs)
            let times = ids.compactMap { dates[$0] }
            guard let start = times.min(), let end = times.max() else { return nil }
            return Part(start: start, end: end, count: ids.count)
        }
        guard let first = part(days[..<index]), let second = part(days[index...]) else { return nil }
        return Split(first: first, second: second)
    }

    /// The instant a split before `day` is stored as: the start of that calendar day.
    public static func splitInstant(before day: Day) -> Date { day.start }

    /// The time span that keeps two trips together: from the first photo of the earlier one
    /// to the last photo of the later one (the trips' own spans as a fallback).
    public static func mergeInterval(_ a: DateInterval, _ b: DateInterval,
                                     members: some Collection<AssetID>, dates: [AssetID: Date]) -> DateInterval {
        let times = members.compactMap { dates[$0] }
        let start = ([a.start, b.start] + times).min()!
        let end = ([a.end, b.end] + times).max()!
        return DateInterval(start: start, end: end)
    }

    /// The trips right before and after `trip` (by time) that are close enough to be one
    /// journey with a pause: at most `maxGap` between the end of one and the start of the other.
    public static func neighbours(of trip: DateInterval, among others: [DateInterval],
                                  maxGap: TimeInterval = 14 * 86_400) -> (before: Int?, after: Int?) {
        var before: Int?
        var after: Int?
        for (index, other) in others.enumerated() where other != trip {
            if other.end <= trip.start, trip.start.timeIntervalSince(other.end) <= maxGap {
                if before.map({ others[$0].end < other.end }) ?? true { before = index }
            } else if other.start >= trip.end, other.start.timeIntervalSince(trip.end) <= maxGap {
                if after.map({ others[$0].start > other.start }) ?? true { after = index }
            }
        }
        return (before, after)
    }

    /// What a split, a merge, "Aufheben" and "Reisen wieder automatisch erkennen" wait for. A
    /// change is applied by an analysis, so none is taken while one runs (it read the changes
    /// before) or while albums are made (a check follows them); each change starts a check
    /// itself, so right after one the next waits. The screens grey these controls and say why
    /// next to them until it ends (UI run 44375768011: right after a split the merge row was
    /// off, looked tappable and said nothing).
    public enum Wait: Hashable, Sendable {
        /// A check works out the trips again: the one a change starts, or one for new photos.
        /// Soon done.
        case tripsAgain
        /// The first analysis, or one that goes on after an interruption: until it is done,
        /// which can take a while.
        case analysis
        /// Albumist makes albums in Photos.
        case creatingAlbums
    }

    /// Nil when a change can be made now. `check`: the running analysis is a check after a
    /// complete one, not the first or a resumed one.
    public static func wait(creatingAlbums: Bool, analysing: Bool, check: Bool) -> Wait? {
        if creatingAlbums { return .creatingAlbums }
        guard analysing else { return nil }
        return check ? .tripsAgain : .analysis
    }
}
