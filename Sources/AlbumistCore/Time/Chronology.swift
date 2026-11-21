import Foundation

/// Chronological granularities (prompt §4.9).
public enum ChronologyGranularity: String, Sendable, Codable, CaseIterable, Comparable {
    case decade, year, halfYear, quarter, season, month, isoWeek, day

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Meteorological seasons. Hemisphere-aware: a photo taken in Sydney in January is summer.
public enum Season: String, Sendable, Codable, CaseIterable {
    case spring, summer, autumn, winter
}

/// Identity of one chronological bucket, e.g. year 2026 / month 3.
public struct ChronologyKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public var granularity: ChronologyGranularity
    /// Sortable components, e.g. [2026, 3] for March 2026, [2020] for the 2020s.
    public var components: [Int]

    public init(_ granularity: ChronologyGranularity, _ components: [Int]) {
        self.granularity = granularity
        self.components = components
    }

    public var description: String { "\(granularity.rawValue):" + components.map(String.init).joined(separator: "-") }

    /// Third component of a season on the southern hemisphere ([year, season, 1]).
    public static let southernHemisphere = 1

    /// A season of the southern hemisphere.
    public var isSouthernSeason: Bool {
        granularity == .season && components.count > 2 && components[2] == Self.southernHemisphere
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.granularity != rhs.granularity { return lhs.granularity < rhs.granularity }
        return lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct ChronologyGrouper: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .albumistDefault) {
        self.calendar = calendar
    }

    /// Bucket for a date. Returns `nil` when the asset has no capture date –
    /// unknown dates are never invented (§4.9).
    public func key(for date: Date?, granularity: ChronologyGranularity, latitude: Double? = nil) -> ChronologyKey? {
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .weekOfYear, .yearForWeekOfYear], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        switch granularity {
        case .decade: return ChronologyKey(.decade, [Int((Double(year) / 10).rounded(.down)) * 10])
        case .year: return ChronologyKey(.year, [year])
        case .halfYear: return ChronologyKey(.halfYear, [year, month <= 6 ? 1 : 2])
        case .quarter: return ChronologyKey(.quarter, [year, (month - 1) / 3 + 1])
        case .month: return ChronologyKey(.month, [year, month])
        case .day: return ChronologyKey(.day, [year, month, day])
        case .isoWeek:
            guard let week = c.weekOfYear, let weekYear = c.yearForWeekOfYear else { return nil }
            return ChronologyKey(.isoWeek, [weekYear, week])
        case .season:
            let southern = (latitude ?? 1) < 0
            let (season, seasonYear) = Self.season(month: month, year: year, southernHemisphere: southern)
            // The hemisphere is part of the key: the winter in Sydney (July) is not the winter
            // in Munich (January), nor is Sydney's summer Munich's (review P1-04). Northern keys
            // are as before, so the ids of their suggestions stay.
            let index = Season.allCases.firstIndex(of: season)!
            return ChronologyKey(.season, southern ? [seasonYear, index, ChronologyKey.southernHemisphere] : [seasonYear, index])
        }
    }

    /// Meteorological season; December belongs to the season of the following year (the
    /// northern Winter 2025/26 and the southern Summer 2025/26 are keyed as 2026) so a season
    /// is never split in two.
    public static func season(month: Int, year: Int, southernHemisphere: Bool) -> (Season, Int) {
        let northern: Season
        switch month {
        case 3...5: northern = .spring
        case 6...8: northern = .summer
        case 9...11: northern = .autumn
        default: northern = .winter
        }
        let season: Season
        if southernHemisphere {
            switch northern {
            case .spring: season = .autumn
            case .summer: season = .winter
            case .autumn: season = .spring
            case .winter: season = .summer
            }
        } else {
            season = northern
        }
        let seasonYear = (month == 12 && northern == .winter) ? year + 1 : year
        return (season, seasonYear)
    }

    /// Groups assets into nested buckets. `levels` must be ordered coarse → fine,
    /// e.g. [.year, .month]. Assets without date land in `undated`.
    public func group(_ assets: [AssetSnapshot], levels: [ChronologyGranularity]) -> (buckets: [[ChronologyKey]: [AssetID]], undated: [AssetID]) {
        group(assets.lazy.map { ($0.id, $0.creationDate, $0.usableLocation?.latitude) }, levels: levels)
    }

    /// Groups photos by the days, months and years of their own clocks (review P1-15,
    /// `LocalTime`): a photo taken in New York at 23:00 on 31 January is January's, whatever
    /// `calendar`'s zone. Facts without a zone are read in `calendar`'s zone, as `group(_:levels:)`.
    public func group(_ facts: [AssetFacts], levels: [ChronologyGranularity]) -> (buckets: [[ChronologyKey]: [AssetID]], undated: [AssetID]) {
        let zone = calendar.timeZone
        let wall = ChronologyGrouper(calendar: LocalTime.wallCalendar(calendar))
        return wall.group(facts.lazy.map { ($0.id, $0.wallClock(or: zone), $0.asset.usableLocation?.latitude) }, levels: levels)
    }

    private func group(_ items: some Sequence<(AssetID, Date?, Double?)>,
                       levels: [ChronologyGranularity]) -> (buckets: [[ChronologyKey]: [AssetID]], undated: [AssetID]) {
        var buckets: [[ChronologyKey]: [AssetID]] = [:]
        var undated: [AssetID] = []
        for (id, date, latitude) in items {
            var path: [ChronologyKey] = []
            for level in levels {
                guard let key = key(for: date, granularity: level, latitude: latitude) else { break }
                path.append(key)
            }
            if path.count == levels.count {
                buckets[path, default: []].append(id)
            } else {
                undated.append(id)
            }
        }
        return (buckets, undated)
    }
}

/// A user-defined period ("Elternzeit", "Hausbau 2024–2025").
public struct CustomPeriod: Hashable, Sendable, Codable, Identifiable {
    public var id: AlbumistID
    public var title: String
    public var start: Date
    public var end: Date

    public init(id: AlbumistID = AlbumistID(), title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public func contains(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date >= start && date <= end
    }
}
