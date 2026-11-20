import Foundation
import SortlyCore

/// The pins of the map: building them (`MapPins.build`), choosing their level by the view's
/// width and grouping those close together on screen (`MapPins.visible`).
public enum MapPins {}

/// The data of the four share motifs (concept §4.11): never home, never a place near it.
public enum MapShare {}

extension CountryGeometry {
    /// Too small for arcs on a share image, or not known: the middle of a small country is almost
    /// the user's home, and without data privacy wins (concept §8).
    public func isSmall(_ code: String) -> Bool {
        guard let area = squareKilometers[code.uppercased()] else { return true }
        return area < Self.smallCountrySquareKilometers
    }

    /// Where arcs start on a share image for a home in `countryCode`: the country's middle, or
    /// `nil` (no arcs) when the country is unknown or small.
    public func shareOrigin(countryCode: String?) -> GeoCoordinate? {
        guard let code = countryCode?.uppercased(), !isSmall(code) else { return nil }
        return centers[code]
    }
}

extension EarthComparison {
    /// Once round the Earth at the equator.
    public static let earthCircumferenceMeters = 40_075_000.0
    /// The mean distance to the Moon ("bis zum Mond").
    public static let moonDistanceMeters = 384_400_000.0

    /// The comparison for a distance (concept §5): below a quarter of the Earth none, then
    /// "ein Viertel", "halb", from once round the Earth the times with one decimal rounded down
    /// (never more than was travelled), from the Moon's distance the times to the Moon.
    public init(meters: Double) {
        guard meters.isFinite, meters > 0 else { self = .none; return }
        let earths = meters / Self.earthCircumferenceMeters
        if meters >= Self.moonDistanceMeters {
            self = .toTheMoon(times: Self.oneDecimalDown(meters / Self.moonDistanceMeters))
        } else if earths >= 1 {
            self = .aroundTheEarth(times: Self.oneDecimalDown(earths))
        } else if earths >= 0.5 {
            self = .half
        } else if earths >= 0.25 {
            self = .quarter
        } else {
            self = .none
        }
    }

    static func oneDecimalDown(_ value: Double) -> Double { (value * 10 + 1e-9).rounded(.down) / 10 }
}

/// How distances are shown (concept §5 and §8): great-circle, rounded to 100 km, with "ca.".
public enum MapDistance {
    /// "ca. 2.600 km": rounded to the nearest 100 km; `nil` below 100 km, where the app says
    /// "in der Nähe" instead of a number (a distance from home must not narrow home down).
    public static func aboutKilometers(_ meters: Double) -> Int? {
        guard meters.isFinite, meters >= 100_000 else { return nil }
        return roundedKilometers(meters)
    }

    /// Totals ("88.800 km", "rund 1.000 km"): rounded to the nearest 100 km, half up; 0 below 50 km.
    public static func roundedKilometers(_ meters: Double) -> Int {
        guard meters.isFinite, meters > 0 else { return 0 }
        return Int((meters / 100_000).rounded(.toNearestOrAwayFromZero)) * 100
    }
}
