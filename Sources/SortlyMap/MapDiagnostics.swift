import Foundation
import SortlyCore

/// The map's section of the diagnostic report a user can send (concept §8: "Der Diagnosebericht
/// enthält keine Koordinaten"; §9: the build time is measured on the device): counts only, in
/// English like the rest of the report. Nothing about home, no coordinate, no place, trip or
/// country name and no country code: what leaves the device says nothing about where the user
/// lives or travels.
public enum MapDiagnostics {
    /// Three lines: the summary's state, what it holds, its pins and routes. `buildMilliseconds`
    /// is how long `MapSummary.build` took; "?" when not measured (or negative, a clock set back),
    /// as the report writes what it does not know.
    public static func lines(for summary: MapSummary, buildMilliseconds: Int?) -> [String] {
        let trips = summary.trips
        let places = trips.reduce(0) { $0 + $1.geometry.places.count }
        let longestRoute = trips.reduce(0) { max($0, $1.geometry.route.count) }
        let airborne = trips.reduce(0) { $0 + $1.geometry.airborneCount }
        var pinsPerLevel: [MapPinLevel: Int] = [:]
        for pin in summary.pins { pinsPerLevel[pin.level, default: 0] += 1 }
        let pins = MapPinLevel.allCases.map { "\(name($0)) \(pinsPerLevel[$0] ?? 0)" }
        let build = buildMilliseconds.map { $0 >= 0 ? "\($0) ms" : "?" } ?? "?"
        return [
            "map summary format \(summary.formatVersion), build \(build), preliminary \(summary.numbers.isPreliminary)",
            "map trips \(trips.count), places \(places), countries \(summary.countries.count), arcs \(summary.arcs.count), years \(summary.years.count)",
            "map pins " + pins.joined(separator: ", ") + "; longest route \(longestRoute) points, photos in flight left out \(airborne)",
        ]
    }

    /// The level's name in the report.
    static func name(_ level: MapPinLevel) -> String {
        switch level {
        case .worldRegion: "world region"
        case .country: "country"
        case .trip: "trip"
        case .place: "place"
        }
    }
}
