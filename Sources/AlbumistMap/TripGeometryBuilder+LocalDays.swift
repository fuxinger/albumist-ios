import Foundation
import AlbumistCore

// The local day of each photo for `TripGeometryBuilder` (`LocalDayFinder`): from the offset of
// its zone, looked up once per stretch of time the zone keeps it, not with a calendar per photo.

extension TripGeometryBuilder {
    // MARK: Local days

    /// The local day of many photos (`LocalDay(_:place:fallback:)`, decision 19.11.2026: the day
    /// where the photo was taken) without a calendar per photo.
    ///
    /// A zone keeps one offset from GMT between two of its transitions (Foundation names them: of
    /// summer time, or any other change of the offset). So the offset looked up for one photo
    /// serves every photo from the zone's transition before it (looked for up to a year back) to
    /// the one after it: a trip asks Foundation a few times per zone, in whatever order its
    /// photos come. The day then follows from the offset and the Gregorian calendar in plain
    /// arithmetic. Outside 1900 to 2200 (dates no camera stored, or broken ones) it asks
    /// `LocalDay` itself, so it always gives what `LocalDay` gives.
    struct LocalDayFinder {
        /// How far back a stretch is looked for its start: a year holds a zone's summer and
        /// winter time.
        static let reach: TimeInterval = 366 * 86_400

        /// By number (`ZoneNumbers`), the fallback last.
        private var zones: [Zone]

        /// 1900-01-01 to 2200-01-01 UTC, in seconds since 1970: the proleptic Gregorian arithmetic
        /// and Foundation's calendar agree there (the Julian calendar ends in 1582).
        static let arithmeticRange: Range<TimeInterval> = -2_208_988_800 ..< 7_258_118_400

        /// - Parameters:
        ///   - zones: the zones of the photos' places by number (`ZoneNumbers`); nil for an
        ///     identifier Foundation does not know, which counts as none.
        ///   - fallback: the trip's zone, for photos whose place has none.
        init(zones: [TimeZone?], fallback: TimeZone) {
            self.zones = zones.map { Zone(zone: $0 ?? fallback) } + [Zone(zone: fallback)]
        }

        /// The local day of `date` in the zone numbered `zone`, or in the fallback for -1.
        mutating func day(_ date: Date, zone: Int) -> LocalDay {
            let index = zone >= 0 ? zone : zones.count - 1
            let seconds = date.timeIntervalSince1970
            guard seconds >= Self.arithmeticRange.lowerBound && seconds < Self.arithmeticRange.upperBound else {
                return LocalDay(date, timeZone: zones[index].zone)
            }
            return Self.civilDay(Int(((seconds + zones[index].offset(at: date)) / 86_400).rounded(.down)))
        }

        /// The Gregorian date `days` after 1970-01-01 (H. Hinnant's `civil_from_days`).
        static func civilDay(_ days: Int) -> LocalDay {
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let dayOfEra = z - era * 146_097
            let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let monthIndex = (5 * dayOfYear + 2) / 153
            let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
            let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
            return LocalDay(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
        }
    }
}

extension TripGeometryBuilder.LocalDayFinder {
    /// A stretch of time in which a zone keeps one offset: from `from` up to `until` (not
    /// included), in seconds since the reference date (as `Date` compares).
    struct Stretch {
        var from: TimeInterval
        var until: TimeInterval
        var offset: TimeInterval
    }

    struct Zone {
        let zone: TimeZone
        var stretches: [Stretch] = []

        /// The zone's offset from GMT at `date`, in seconds.
        mutating func offset(at date: Date) -> TimeInterval {
            let time = date.timeIntervalSinceReferenceDate
            for stretch in stretches where stretch.from <= time && time < stretch.until { return stretch.offset }
            // The last transition at or before `date` within `reach`, else `reach` back (no
            // transition in between); and the first one after it.
            var from = date.addingTimeInterval(-TripGeometryBuilder.LocalDayFinder.reach)
            var next = zone.nextDaylightSavingTimeTransition(after: from)
            while let transition = next, transition <= date, transition > from {
                from = transition
                next = zone.nextDaylightSavingTimeTransition(after: transition)
            }
            let offset = TimeInterval(zone.secondsFromGMT(for: date))
            let until = next?.timeIntervalSinceReferenceDate ?? .infinity
            // Kept only when it holds `date` (transitions out of order would be no stretch).
            if time < until { stretches.append(Stretch(from: from.timeIntervalSinceReferenceDate, until: until, offset: offset)) }
            return offset
        }
    }
}
