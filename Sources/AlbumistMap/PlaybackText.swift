import Foundation

/// The words of "Reise abspielen" (concept §4.4). The prototype is German only and stays out of
/// the string catalog (prototype brief), so its few sentences are made here, tested, and shown
/// verbatim: "Tag 3 von 9 · Skógafoss", the local date, "+46", and the numbers of the
/// "Willkommen zurück" card. Kilometres are always rounded, never metres (concept §5).
public enum PlaybackText {
    static let weekdays = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]

    /// "Tag 3 von 9 · Skógafoss" for day `index` (from 0) of `count`; without a place name (or an
    /// empty one) "Tag 3 von 9".
    public static func dayTitle(index: Int, of count: Int, place: String?) -> String {
        let total = max(count, 1)
        let number = min(max(index, 0), total - 1) + 1
        let title = "Tag \(number) von \(total)"
        guard let place = place?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty else { return title }
        return "\(title) · \(place)"
    }

    /// "Mittwoch, 14. Juni 2023": the local calendar day, as the clocks where the photos were
    /// taken saw it (decision 19.11.2026), without any time zone of the iPhone.
    public static func date(_ day: LocalDay) -> String {
        // 1 January 1970 was a Thursday (3, counting from Monday at 0).
        let weekday = ((day.dayNumber % 7) + 7 + 3) % 7
        // The day as a calendar would carry a month out of range (`LocalDay.dayNumber`).
        let normal = LocalDay(dayNumber: day.dayNumber)
        return "\(weekdays[weekday]), \(normal.day). \(months[normal.month - 1]) \(normal.year)"
    }

    /// "+46": the day's photos beyond the `shown` ones beside the dot; `nil` when there are none.
    public static func more(dayPhotos: Int, shown: Int) -> String? {
        let rest = dayPhotos - max(shown, 0)
        return rest > 0 ? "+\(grouped(rest))" : nil
    }

    /// A distance on the "Willkommen zurück" card: from 100 km rounded to 100 km ("ca. 1.000 km",
    /// as `MapDistance.roundedKilometers`), from 10 km to 10 km ("ca. 30 km"), below that
    /// "unter 10 km"; never metres.
    public static func kilometers(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 10_000 else { return "unter 10 km" }
        if meters >= 100_000 { return "ca. \(grouped(MapDistance.roundedKilometers(meters))) km" }
        let tens = Int((meters / 10_000).rounded(.toNearestOrAwayFromZero)) * 10
        return "ca. \(grouped(tens)) km"
    }

    /// "9 Tage · 412 Fotos · ca. 1.000 km vor Ort" (the end card, concept §4.4: "Tage, Fotos, km").
    public static func summary(days: Int, photos: Int, metersOnSite: Double) -> String {
        let dayWord = days == 1 ? "Tag" : "Tage"
        let photoWord = photos == 1 ? "Foto" : "Fotos"
        return "\(grouped(days)) \(dayWord) · \(grouped(photos)) \(photoWord) · \(kilometers(metersOnSite)) vor Ort"
    }

    /// The end card's line for a trip.
    public static func summary(of trip: MapTrip) -> String {
        summary(days: trip.geometry.days, photos: trip.geometry.photoCount, metersOnSite: trip.stats.metersOnSite)
    }

    /// A whole number with German thousands points: 1.000, 12.300, -4.500.
    public static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var result = ""
        for (i, digit) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { result.append(".") }
            result.append(digit)
        }
        return value < 0 ? "-" + result : result
    }
}
