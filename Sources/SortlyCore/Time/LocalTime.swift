import Foundation

/// Days, months and years on the clock where a photo was taken (review P1-15, decision of
/// 19.11.2026 "Ortszeit wie in Apple Fotos"): a photo taken in New York at 23:00 on 31 January
/// belongs to January and to that day, also on an iPhone set to German time, and the iPhone's
/// time zone during an analysis changes no album.
///
/// The stored capture dates stay what they are, real instants: the time between two photos,
/// trips and the order of the grid are measured in real time. Only where a photo's day, month or
/// year is asked, its instant is read on its own clock: shifted by its zone's offset at that
/// instant and read in UTC (its "wall clock", `wallClock`). Two photos taken at 23:00 on the same
/// day in Munich and in New York have the same wall clock.
///
/// A photo's zone (`AssetFacts.timeZone`, `zone(of:at:)`): its place's own zone from the online
/// lookup; else the zone of its country there (`CountryTimeZones`, offline); else, without a
/// place, the home time zone: the iPhone's at the first analysis, kept when the iPhone travels.
public enum LocalTime {
    /// The zone a place tells: its own zone from the online lookup, else the zone of its country
    /// (or disputed area) where the photo was taken. Nil when neither tells (no place, a code the
    /// table does not know, a country with several zones without a location).
    public static func zone(of place: PlaceComponents?, at location: GeoCoordinate?) -> TimeZone? {
        guard let place else { return nil }
        if let identifier = place.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) { return zone }
        let identifier: String?
        if let country = place.isoCountryCode {
            identifier = CountryTimeZones.zone(country: country, near: location)
        } else if let area = place.disputedArea {
            identifier = CountryTimeZones.zone(disputedArea: area, near: location)
        } else {
            identifier = nil
        }
        return identifier.flatMap(TimeZone.init(identifier:))
    }

    /// `date` as a clock in `zone` shows it, as an instant read in UTC: its year, month, day,
    /// hour and weekday in UTC are those of `date` in `zone`.
    public static func wallClock(_ date: Date, in zone: TimeZone) -> Date {
        date.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: date)))
    }

    /// The days of `interval`, given as instants in `zone` (a search's "Januar 2026", which the
    /// iPhone's calendar gives), as wall clocks: the same calendar days on any photo's clock.
    public static func wallClock(_ interval: DateInterval, in zone: TimeZone) -> DateInterval {
        let start = wallClock(interval.start, in: zone), end = wallClock(interval.end, in: zone)
        return DateInterval(start: start, end: max(start, end))
    }

    /// The calendar to read wall clocks with: `calendar`'s rules (first weekday, ISO weeks) in UTC.
    public static func wallCalendar(_ calendar: Calendar) -> Calendar {
        var c = calendar
        c.timeZone = utc
        return c
    }

    static let utc = TimeZone(secondsFromGMT: 0)!

    /// The calendar day of a wall clock as a number (days since 1 January 2001): equal for two
    /// photos taken on the same day, wherever they were taken.
    public static func day(_ wallClock: Date) -> Int {
        Int((wallClock.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }
}

/// `LocalTime.zone(of:at:)` for many photos: remembers the zone of each country and spot (in a
/// country with several zones a lookup measures the distance to up to a few hundred places).
public struct TimeZoneFinder: Sendable {
    private struct Key: Hashable {
        var country: String?
        var area: String?
        var located = false
        var latitude = 0.0
        var longitude = 0.0
    }
    private var known: [Key: TimeZone?] = [:]

    public init() {}

    public mutating func zone(of place: PlaceComponents?, at location: GeoCoordinate?) -> TimeZone? {
        guard let place else { return nil }
        if let identifier = place.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) { return zone }
        var key = Key(country: place.isoCountryCode, area: place.isoCountryCode == nil ? place.disputedArea : nil)
        let country = key.country ?? key.area.flatMap { CountryTimeZones.areas[$0] }
        if let location, let country, CountryTimeZones.dependsOnPlace(country: country) {
            // The rounding `CountryTimeZones` measures from: equal keys, equal zones.
            let point = CountryTimeZones.rounded(location)
            (key.located, key.latitude, key.longitude) = (true, point.latitude, point.longitude)
        }
        if let zone = known[key] { return zone }
        let zone = LocalTime.zone(of: place, at: location)
        known[key] = zone
        return zone
    }
}

extension AssetFacts {
    /// The capture date on the photo's own clock (`LocalTime.wallClock`): in its time zone, or in
    /// `fallback` (the calendar's zone) for facts made without zones.
    public func wallClock(or fallback: TimeZone) -> Date? {
        asset.creationDate.map { LocalTime.wallClock($0, in: timeZone ?? fallback) }
    }
}
