import Foundation

public enum GeoMath {
    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Spherical centroid – correct across the antimeridian.
    public static func centroid<S: Sequence>(_ coordinates: S) -> GeoCoordinate? where S.Element == GeoCoordinate {
        var x = 0.0, y = 0.0, z = 0.0, n = 0.0
        for c in coordinates {
            let lat = c.latitude * .pi / 180
            let lon = c.longitude * .pi / 180
            x += cos(lat) * cos(lon)
            y += cos(lat) * sin(lon)
            z += sin(lat)
            n += 1
        }
        guard n > 0 else { return nil }
        x /= n; y /= n; z /= n
        let hyp = sqrt(x * x + y * y)
        guard hyp > 1e-12 || abs(z) > 1e-12 else { return nil }
        return GeoCoordinate(latitude: atan2(z, hyp) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
    }

    /// Metres per degree of latitude (approximately constant).
    public static let metersPerDegreeLatitude = 111_320.0

    /// At most this many photos of one day are compared to find where the day was (`dayPoint`).
    public static let daySample = 15

    /// Where a day was: the most central of its photos (the one with the smallest sum of
    /// distances to the others), robust against a few far-away photos that day. `coordinates`
    /// are the day's photos in time order. A day with more than `daySample` photos is
    /// represented by `daySample` photos spread evenly over all of them, so each part of the day
    /// counts by its number of photos and the place of most of the day's photos wins; a burst at
    /// the start of the day no longer decides (review 18.11.2026, G1-02: only the first 15
    /// were read, and 8 early photos at work 49 km away moved home there). The cost stays at
    /// `daySample`² distances per day, however many photos the day has.
    public static func dayPoint(_ coordinates: [GeoCoordinate]) -> GeoCoordinate? {
        let sample = daySampleIndices(count: coordinates.count).map { coordinates[$0] }
        var best: (index: Int, sum: Double)?
        for (i, candidate) in sample.enumerated() {
            let sum = sample.reduce(0) { $0 + distance($1, candidate) }
            if best == nil || sum < best!.sum { best = (i, sum) }
        }
        return best.map { sample[$0.index] }
    }

    /// The photos `dayPoint` compares: all up to `daySample`, otherwise the middle photo of each
    /// of `daySample` equal parts of the day's photos.
    static func daySampleIndices(count: Int) -> [Int] {
        guard count > daySample else { return Array(0..<count) }
        return (0..<daySample).map { ((2 * $0 + 1) * count) / (2 * daySample) }
    }
}

/// Quantized geographic cell. Used as spatial index for clustering and as cache key for
/// reverse geocoding ("a resolved place is not re-requested for every photo", §4.1).
public struct GeoCell: Hashable, Sendable, Codable, CustomStringConvertible {
    public let x: Int
    public let y: Int
    public let sizeMeters: Double

    public init(x: Int, y: Int, sizeMeters: Double) {
        self.x = x
        self.y = y
        self.sizeMeters = sizeMeters
    }

    public init(_ c: GeoCoordinate, sizeMeters: Double) {
        let latStep = sizeMeters / GeoMath.metersPerDegreeLatitude
        let yIndex = Int((c.latitude / latStep).rounded(.down))
        // Use the cell's latitude band so the longitude step is stable within a band.
        let bandLat = (Double(yIndex) + 0.5) * latStep
        let lonStep = latStep / max(cos(bandLat * .pi / 180), 0.01)
        self.x = Int((c.longitude / lonStep).rounded(.down))
        self.y = yIndex
        self.sizeMeters = sizeMeters
    }

    public var description: String { "\(Int(sizeMeters))m:\(x):\(y)" }

    /// The 3×3 neighbourhood including this cell.
    public var neighbourhood: [GeoCell] {
        var cells: [GeoCell] = []
        cells.reserveCapacity(9)
        for dy in -1...1 {
            let ny = y + dy
            for dx in -1...1 {
                cells.append(GeoCell(x: x + dx, y: ny, sizeMeters: sizeMeters))
            }
        }
        return cells
    }
}
