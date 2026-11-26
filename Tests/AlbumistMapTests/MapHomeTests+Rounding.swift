import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistTestSupport

/// Rounding home to the centre of its 10 km cell: within the cell, twice the same, across the
/// antimeridian, at the poles and beyond, in the southern hemisphere, from broken coordinates.
extension MapHomeTests {
    // MARK: Rounding

    /// Two points 1 km apart in one cell give the same point, the cell's centre, in the north, the
    /// south, near the antimeridian and far north.
    @Test func pointsOfOneCellRoundToItsCentre() {
        for place in [Places.regensburg, Self.hamburg, Places.reykjavik, Places.auckland, Places.ushuaia, Places.suva, Places.longyearbyen] {
            let centre = MapHome.rounded(place)
            #expect(centre != place)
            let half = 500 / GeoMath.metersPerDegreeLatitude
            let halfLongitude = half / cos(centre.latitude * .pi / 180)
            let north = Self.at(centre.latitude + half, centre.longitude), south = Self.at(centre.latitude - half, centre.longitude)
            let east = Self.at(centre.latitude, centre.longitude + halfLongitude), west = Self.at(centre.latitude, centre.longitude - halfLongitude)
            #expect(abs(GeoMath.distance(north, south) - 1_000) < 5)
            #expect(abs(GeoMath.distance(east, west) - 1_000) < 5)
            for point in [north, south, east, west] { #expect(MapHome.rounded(point) == centre) }
        }
    }

    /// Every band of the grid, at the corners of its first cell: they round to the cell's centre,
    /// at most half a cell's diagonal away (7.07 km for a flat 10 km square; a little more near
    /// the poles, where a cell's meridians converge), and a whole number of equally wide cells
    /// goes round the Earth, so no sliver of a cell is left at 180°.
    @Test func everyPointLiesWithinHalfACellDiagonalOfItsCentre() {
        let step = MapHome.gridMeters / GeoMath.metersPerDegreeLatitude
        var worst = 0.0, worstUpTo88 = 0.0
        var failures: [Int] = []
        for band in Int((-90 / step).rounded(.down))...Int((90 / step).rounded(.down)) {
            let lower = max(Double(band) * step, -90), upper = min(Double(band + 1) * step, 90)
            let inset = (upper - lower) * 1e-6
            let first = MapHome.rounded(Self.at(lower + inset, -180))
            let width = 2 * (first.longitude + 180)
            let cells = 360 / width
            let last = MapHome.rounded(Self.at(upper - inset, 180 - 1e-9))
            if abs(cells - cells.rounded()) > 1e-6 || abs(last.longitude - (180 - width / 2)) > 1e-9 || last.latitude != first.latitude {
                failures.append(band)
            }
            for latitude in [lower + inset, upper - inset] {
                for longitude in [-180 + width * 1e-6, -180 + width * (1 - 1e-6)] {
                    let point = Self.at(latitude, longitude)
                    if MapHome.rounded(point) != first { failures.append(band) }
                    let distance = GeoMath.distance(point, first)
                    worst = max(worst, distance)
                    if abs(first.latitude) <= 88 { worstUpTo88 = max(worstUpTo88, distance) }
                }
            }
        }
        #expect(failures.isEmpty)
        #expect(worstUpTo88 > 7_000 && worstUpTo88 < 7_130)
        #expect(worst < 7_250)
    }

    /// Rounding twice changes nothing, bit for bit, anywhere on Earth; the result is always a
    /// valid coordinate with its longitude in [-180, 180).
    @Test func roundingTwiceChangesNothing() {
        var random = MapRandom(seed: 42)
        var points = [Self.at(0, -180), Self.at(0, 179.999_999_9), Self.at(-16.8, 180), Self.at(90, 0), Self.at(-90, 45), Self.at(89.99, -179.99),
                      Self.at(-89.99, 179.99), Self.hamburg, Places.regensburg, Places.suva, Places.apia, Places.longyearbyen, Places.ushuaia]
        for _ in 0..<20_000 { points.append(Self.at(random.unit() * 180 - 90, random.unit() * 360 - 180)) }
        var failures: [GeoCoordinate] = []
        for point in points {
            let once = MapHome.rounded(point)
            if MapHome.rounded(once) != once || !(-90...90).contains(once.latitude) || !(once.longitude >= -180 && once.longitude < 180) {
                failures.append(point)
            }
        }
        #expect(failures.isEmpty)
    }

    /// The antimeridian is no seam: the cells on either side of 180° are whole cells (a home in
    /// Fiji is not given away to within metres by a sliver of a cell), their centres lie on the
    /// map (never at 180.04°), and every longitude is wrapped.
    @Test func theAntimeridianIsNoSeam() {
        let latitude = -16.8 // Taveuni, Fiji, which the 180th meridian crosses
        let west = Self.at(latitude, 179.999), east = Self.at(latitude, -179.999)
        let a = MapHome.rounded(west), b = MapHome.rounded(east)
        for (point, centre) in [(west, a), (east, b)] {
            #expect(centre.longitude >= -180 && centre.longitude < 180)
            #expect(GeoMath.distance(point, centre) < 7_100)
        }
        #expect(a.longitude > 179 && b.longitude < -179)
        #expect(abs(GeoMath.distance(a, b) - 10_000) < 50)
        #expect(MapHome.rounded(Self.at(latitude, 180)) == MapHome.rounded(Self.at(latitude, -180)))
        #expect(MapHome.rounded(Self.at(latitude, 180.001)) == b)
        #expect(MapHome.rounded(Self.at(latitude, 540)) == MapHome.rounded(Self.at(latitude, -180)))
        #expect(MapHome.rounded(Self.at(latitude, -190)) == MapHome.rounded(Self.at(latitude, 170)))
        #expect(MapHome.rounded(Self.at(latitude, -539.999)) == b)
    }

    /// At the poles the cells meet: any longitude there rounds to a centre a few kilometres away;
    /// a latitude beyond ±90° counts as the pole.
    @Test func thePolesAndBeyond() {
        for pole in [90.0, -90.0] {
            let centre = MapHome.rounded(Self.at(pole, 0))
            #expect(abs(centre.latitude) <= 90 && abs(centre.latitude) > 89.9)
            #expect(centre.latitude.sign == pole.sign)
            for longitude in stride(from: -180.0, to: 180, by: 7.5) {
                let point = Self.at(pole, longitude)
                let other = MapHome.rounded(point)
                #expect(GeoMath.distance(point, other) < 5_000)
                #expect(MapHome.rounded(other) == other)
            }
            #expect(MapHome.rounded(Self.at(pole * 1.05, 0)) == centre)
        }
        let svalbard = MapHome.rounded(Places.longyearbyen)
        #expect(GeoMath.distance(Places.longyearbyen, svalbard) < 7_100)
    }

    /// The southern hemisphere: its own cells, counted away from the equator, not towards it (a
    /// truncating index would make one cell twice as high on either side of the equator).
    @Test func theSouthernHemisphere() {
        for place in [Places.auckland, Places.ushuaia, Places.suva, Places.apia] {
            let centre = MapHome.rounded(place)
            #expect(centre.latitude < 0)
            #expect(GeoMath.distance(place, centre) < 7_100)
            #expect(MapHome.rounded(centre) == centre)
        }
        let north = MapHome.rounded(Self.at(Self.equator.latitude + 0.01, Self.equator.longitude))
        let south = MapHome.rounded(Self.at(Self.equator.latitude - 0.01, Self.equator.longitude))
        #expect(north.latitude > 0 && south.latitude < 0)
        #expect(abs(north.latitude + south.latitude) < 1e-12)
        #expect(abs(GeoMath.distance(north, south) - 10_000) < 50)
    }

    /// A coordinate that is not a number (never one of the library's) still gives a point on the
    /// map rather than stopping the app.
    @Test func brokenCoordinatesStillGiveAPoint() {
        for point in [Self.at(.nan, 10), Self.at(10, .nan), Self.at(.infinity, -.infinity)] {
            let centre = MapHome.rounded(point)
            #expect(centre.latitude.isFinite && centre.longitude.isFinite)
            #expect(MapHome.rounded(centre) == centre)
        }
    }
}
