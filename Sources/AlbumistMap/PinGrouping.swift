import Foundation
import AlbumistCore

// Which pins the globe shows (concept §4.2): the farther away the view, the coarser the pins
// (a world region, a country, a trip, a place of a trip), never more than
// `MapSummary.maxVisiblePins` at once (concept §9), pins close together on screen shown as one.

extension MapPins {
    /// From this view width on, a pin per world region ("Südeuropa · 5 Länder"): the view then
    /// shows about a continent or more.
    public static let regionWidthMeters = 7_000_000.0
    /// From this view width on (below `regionWidthMeters`), a pin per country.
    public static let countryWidthMeters = 2_500_000.0
    /// From this view width on (below `countryWidthMeters`), a pin per trip; closer, a pin per
    /// place of a trip.
    public static let tripWidthMeters = 250_000.0

    /// The level of the pins for a view this wide on the ground. A width that is not a number
    /// (a broken camera state) gets the coarsest level, the one with the fewest pins.
    public static func level(forWidth meters: Double) -> MapPinLevel {
        if meters.isNaN || meters >= regionWidthMeters { return .worldRegion }
        if meters >= countryWidthMeters { return .country }
        if meters >= tripWidthMeters { return .trip }
        return .place
    }

    /// The pins the globe shows in `viewport`: those of the level its width calls for
    /// (`level(forWidth:)`), close ones grouped (`visible`). `pins` are the summary's, all levels.
    public static func onGlobe(_ pins: [MapPin], in viewport: MapViewport, limit: Int = MapSummary.maxVisiblePins) -> [MapPinGroup] {
        let level = level(forWidth: viewport.widthMeters)
        return visible(pins.filter { $0.level == level }, in: viewport, limit: limit)
    }

    /// `pins` drawn in `viewport`, close ones grouped. They are taken as given, whatever their
    /// level: the globe passes the pins of one level (`onGlobe`), a trip's own map its places.
    ///
    /// The pins are placed on the screen with the azimuthal equidistant projection around the
    /// view's centre (`viewport.widthPoints / viewport.widthMeters` points per metre), which is
    /// right across the antimeridian and near the poles. Dropped: pins more than 90° from the
    /// centre (the far side of the globe) and pins outside the view by more than half
    /// `spacingPoints` (a pin cut by the edge still shows half of itself).
    ///
    /// Grouping is greedy: pins in the order of `count`, highest first (ties: the smaller id),
    /// each joins the group whose shown pin is nearest on screen and at most `spacingPoints`
    /// away (ties: the group made first), or else shows itself as a new group. So every group
    /// shows its pin with the highest count and its members add up to the visible pins. With
    /// more groups than `limit`, the spacing grows by half and the pins are grouped again; it
    /// ends at the latest when the spacing spans the view and all pins are one group.
    ///
    /// Groups come in the order they were made (their shown pins by count, highest first), each
    /// group's members in the order they joined, the shown one first. Pins are expected to have
    /// distinct ids (`MapPins.build`); of a repeated id only the first in that order counts.
    /// Pins without a finite coordinate are not drawn. About linear: the pins are sorted once,
    /// and each pin looks only at the groups in its own and the 8 neighbouring squares of a grid
    /// as wide as the spacing (wider when the pins lie so far apart that it would take more than
    /// about two squares per pin).
    public static func visible(_ pins: [MapPin], in viewport: MapViewport, limit: Int = MapSummary.maxVisiblePins,
                               spacingPoints: Double = 44) -> [MapPinGroup] {
        guard limit > 0 else { return [] }
        let initialSpacing = spacingPoints.isNaN ? 44 : max(spacingPoints, 1)
        let onScreen = PinGrouping.project(pins, in: viewport, marginPoints: initialSpacing / 2)
        guard !onScreen.isEmpty else { return [] }
        var spacing = initialSpacing
        var groups = PinGrouping.group(onScreen, spacing: spacing)
        while groups.count > limit {
            spacing *= 1.5
            groups = PinGrouping.group(onScreen, spacing: spacing)
        }
        return groups.map { members in
            MapPinGroup(pin: pins[onScreen[members[0]].index], memberIDs: members.map { pins[onScreen[$0].index].id })
        }
    }

    /// The first camera of the globe (concept §4.10, "Kleiner Anfang": with a few trips the
    /// globe moves close to the visited countries): a great-circle cap around the middle of
    /// `coordinates` (`GeoMath.centroid`, right across the antimeridian) wide enough to hold
    /// them all, at least `minimumFocusRadiusMeters`. Nil for none. Coordinates the library
    /// cannot have (`GeoCoordinate.isPlausible`) are left out. Should the coordinates have no
    /// middle (spread evenly round the Earth), the cap is centred on the first of them by
    /// latitude, then longitude. Any order of the same coordinates gives the same focus.
    public static func focus(on coordinates: [GeoCoordinate]) -> MapFocus? {
        // Sorted, so the floating-point sums of the centroid do not depend on the order.
        let points = coordinates.filter(\.isPlausible).sorted { ($0.latitude, $0.longitude) < ($1.latitude, $1.longitude) }
        guard let first = points.first else { return nil }
        let center = GeoMath.centroid(points) ?? first
        let farthest = points.reduce(0) { max($0, GeoMath.distance(center, $1)) }
        return MapFocus(center: center, radiusMeters: max(farthest, minimumFocusRadiusMeters))
    }

    /// The focus of a single trip or of trips close together is a cap of at least this radius:
    /// the view is then about 600 km wide, where it shows trips rather than single places
    /// (`tripWidthMeters`) and where the house and the arcs are shown (concept §8: from 300 km
    /// view width on). Never a street.
    static let minimumFocusRadiusMeters = 300_000.0
}

/// The work of `MapPins.visible`.
enum PinGrouping {
    /// A pin on the screen: which one (into the pins given), its count, and where it is, in
    /// points from the view's centre (x east, y north).
    struct Placed: Sendable {
        var index: Int
        var count: Int
        var x: Double
        var y: Double
    }

    /// The pins on screen, in grouping order: `count` highest first, then the smaller id (then
    /// the coordinate and level, so even repeated ids give one order); a repeated id only once.
    static func project(_ pins: [MapPin], in viewport: MapViewport, marginPoints: Double) -> [Placed] {
        guard viewport.center.latitude.isFinite, viewport.center.longitude.isFinite,
              viewport.widthMeters.isFinite, viewport.widthMeters > 0,
              viewport.widthPoints.isFinite, viewport.widthPoints > 0,
              viewport.heightPoints.isFinite, viewport.heightPoints > 0 else { return [] }
        let pointsPerMeter = viewport.widthPoints / viewport.widthMeters
        // Every position, and the distance between any two (half the Earth round at most), stays
        // a finite number.
        guard (4 * .pi * GeoMath.earthRadiusMeters * pointsPerMeter).isFinite else { return [] }
        let halfWidth = viewport.widthPoints / 2 + marginPoints
        let halfHeight = viewport.heightPoints / 2 + marginPoints
        let projection = AzimuthalEquidistantProjection(center: viewport.center)
        var placed: [Placed] = []
        for index in pins.indices {
            let c = pins[index].coordinate
            guard c.latitude.isFinite, c.longitude.isFinite, abs(c.latitude) <= 90 else { continue }
            let p = projection.project(c)
            // The far side of the globe: more than 90° from the centre.
            guard p.angle <= .pi / 2 else { continue }
            let x = p.x * pointsPerMeter, y = p.y * pointsPerMeter
            guard abs(x) <= halfWidth, abs(y) <= halfHeight else { continue }
            placed.append(Placed(index: index, count: pins[index].count, x: x, y: y))
        }
        // Small entries sorted; a pin's id and coordinate are read only on a tie.
        placed.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            let p = pins[a.index].id, q = pins[b.index].id
            if p != q { return p < q }
            let u = pins[a.index].coordinate, v = pins[b.index].coordinate
            return (u.latitude, u.longitude, pins[a.index].level.rawValue) < (v.latitude, v.longitude, pins[b.index].level.rawValue)
        }
        var seen = Set<String>()
        seen.reserveCapacity(placed.count)
        return placed.filter { seen.insert(pins[$0.index].id).inserted }
    }

    /// Greedy grouping of pins already in grouping order (see `MapPins.visible`): each group's
    /// members as positions in `pins`, the shown one first, groups in the order they were made.
    static func group(_ pins: [Placed], spacing: Double) -> [[Int]] {
        guard !pins.isEmpty else { return [] }
        let grid = Grid(pins, spacing: spacing)
        let reach = spacing * spacing
        var members: [[Int]] = []
        // Per group: its shown pin, and the group made before it in the same square; per square:
        // the newest group made in it. Linked lists in flat arrays, no hashing.
        var shown: [Int] = []
        var previous: [Int] = []
        var newest = [Int](repeating: -1, count: grid.columns * grid.rows)
        for (position, pin) in pins.enumerated() {
            let (column, row) = grid.square(of: pin)
            var nearest = -1, nearestDistance = Double.infinity
            // A shown pin within `spacing` lies in this square or one of the 8 around it.
            for c in max(0, column - 1)...min(grid.columns - 1, column + 1) {
                for r in max(0, row - 1)...min(grid.rows - 1, row + 1) {
                    var g = newest[r * grid.columns + c]
                    while g >= 0 {
                        let other = pins[shown[g]]
                        let dx = other.x - pin.x, dy = other.y - pin.y
                        let d = dx * dx + dy * dy
                        if d <= reach, d < nearestDistance || (d == nearestDistance && g < nearest) {
                            nearest = g
                            nearestDistance = d
                        }
                        g = previous[g]
                    }
                }
            }
            if nearest >= 0 {
                members[nearest].append(position)
            } else {
                let square = row * grid.columns + column
                previous.append(newest[square])
                newest[square] = shown.count
                shown.append(position)
                members.append([position])
            }
        }
        return members
    }

    /// Squares at least `spacing` wide over the pins' extent: as wide as the spacing, or wider
    /// when that would take more than about two squares per pin (pins spread far apart, or an
    /// absurd view). A wider square only holds more groups to compare; none within `spacing` is
    /// ever outside the 3×3 squares around a pin.
    struct Grid {
        let minX: Double
        let minY: Double
        let side: Double
        let columns: Int
        let rows: Int

        init(_ pins: [Placed], spacing: Double) {
            var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
            for pin in pins {
                minX = Swift.min(minX, pin.x)
                maxX = Swift.max(maxX, pin.x)
                minY = Swift.min(minY, pin.y)
                maxY = Swift.max(maxY, pin.y)
            }
            let budget = Double(Swift.max(64, 2 * pins.count))
            var side = spacing
            while ((maxX - minX) / side + 1) * ((maxY - minY) / side + 1) > budget { side *= 2 }
            self.minX = minX
            self.minY = minY
            self.side = side
            columns = Int((maxX - minX) / side) + 1
            rows = Int((maxY - minY) / side) + 1
        }

        func square(of pin: Placed) -> (column: Int, row: Int) {
            (Swift.min(columns - 1, Int((pin.x - minX) / side)), Swift.min(rows - 1, Int((pin.y - minY) / side)))
        }
    }
}

/// The azimuthal equidistant projection around `center`: every point at its true great-circle
/// distance from the centre, in its true direction. Continuous across the antimeridian and
/// round the poles, so neither the pins of a view centred on 180° nor a country ring round a
/// pole need any longitude unwrapped. Used for the pins on screen and for the middles of
/// countries (`CountryGeometryBuilder`).
struct AzimuthalEquidistantProjection: Sendable {
    let center: GeoCoordinate
    private let sinLatitude: Double
    private let cosLatitude: Double
    private let longitude: Double

    init(center: GeoCoordinate) {
        self.center = center
        let latitude = center.latitude * .pi / 180
        sinLatitude = sin(latitude)
        cosLatitude = cos(latitude)
        longitude = center.longitude * .pi / 180
    }

    /// Metres east (`x`) and north (`y`) of the centre on the projection, and the great-circle
    /// angle from the centre in radians (more than π/2: the far side of the globe). The point
    /// opposite the centre has no direction; it is put due north.
    func project(_ coordinate: GeoCoordinate) -> (x: Double, y: Double, angle: Double) {
        let latitude = coordinate.latitude * .pi / 180
        let dLongitude = coordinate.longitude * .pi / 180 - longitude
        let sinLat = sin(latitude), cosLat = cos(latitude)
        let east = cosLat * sin(dLongitude)
        let north = cosLatitude * sinLat - sinLatitude * cosLat * cos(dLongitude)
        let along = sinLatitude * sinLat + cosLatitude * cosLat * cos(dLongitude)
        let across = (east * east + north * north).squareRoot()
        let angle = atan2(across, along)
        let meters = angle * GeoMath.earthRadiusMeters
        guard across > 0 else { return (0, angle > .pi / 2 ? meters : 0, angle) }
        return (east / across * meters, north / across * meters, angle)
    }

    /// The point `x` metres east and `y` metres north of the centre on the projection. The
    /// longitude in the form of the azimuthal projections' inverse (Snyder, "Map Projections: A
    /// Working Manual", USGS 1987), which stays exact with the centre on a pole; the
    /// destination-point form subtracts two nearly equal roundings there.
    func unproject(x: Double, y: Double) -> GeoCoordinate {
        let meters = (x * x + y * y).squareRoot()
        guard meters > 0 else { return center }
        let angle = meters / GeoMath.earthRadiusMeters
        let bearing = atan2(x, y)
        let sinAngle = sin(angle), cosAngle = cos(angle)
        let latitude = asin(min(1, max(-1, sinLatitude * cosAngle + cosLatitude * sinAngle * cos(bearing))))
        let dLongitude = atan2(sin(bearing) * sinAngle, cosLatitude * cosAngle - sinLatitude * sinAngle * cos(bearing))
        return GeoCoordinate(latitude: latitude * 180 / .pi, longitude: MapHome.normalizedLongitude((longitude + dLongitude) * 180 / .pi))
    }
}
