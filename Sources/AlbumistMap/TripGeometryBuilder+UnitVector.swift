import Foundation
import AlbumistCore

// Points on the unit sphere for `TripGeometryBuilder` (`UnitVector`): the running centre of a
// day's photos, whether two points lie within a place's radius, and the route's simplification.

extension TripGeometryBuilder {
    // MARK: Points on the sphere

    /// A point on the unit sphere: the running centre of a day's group of photos (a spherical
    /// mean, right across the antimeridian and near the poles), the test whether two points lie
    /// within a place's radius, and the route's simplification.
    struct UnitVector: Sendable {
        var x: Double
        var y: Double
        var z: Double

        init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        init(_ c: GeoCoordinate) {
            let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
            self.init(x: cos(lat) * cos(lon), y: cos(lat) * sin(lon), z: sin(lat))
        }

        /// The coordinate it points to (any length); `nil` for the null vector.
        var coordinate: GeoCoordinate? {
            let horizontal = (x * x + y * y).squareRoot()
            guard horizontal > 1e-12 || abs(z) > 1e-12 else { return nil }
            return GeoCoordinate(latitude: atan2(z, horizontal) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
        }

        var length: Double { (x * x + y * y + z * z).squareRoot() }

        /// Of length 1; `nil` for (almost) the null vector, which points nowhere.
        var normalized: UnitVector? {
            let length = length
            return length > 1e-12 ? scaled(1 / length) : nil
        }

        static func + (a: UnitVector, b: UnitVector) -> UnitVector { UnitVector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        static func += (a: inout UnitVector, b: UnitVector) {
            a.x += b.x
            a.y += b.y
            a.z += b.z
        }
        func scaled(_ factor: Double) -> UnitVector { UnitVector(x: x * factor, y: y * factor, z: z * factor) }
        func dot(_ o: UnitVector) -> Double { x * o.x + y * o.y + z * o.z }
        func cross(_ o: UnitVector) -> UnitVector { UnitVector(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x) }
        /// The angle between two unit vectors, exact for small and large angles alike.
        func angle(to o: UnitVector) -> Double { atan2(cross(o).length, dot(o)) }
        /// The square of the straight line to `o`: for two unit vectors, it grows with the angle
        /// between them (`2 sin(angle / 2)`, squared) and stays exact for short distances.
        func chordSquared(to o: UnitVector) -> Double {
            let dx = x - o.x, dy = y - o.y, dz = z - o.z
            return dx * dx + dy * dy + dz * dz
        }
    }
}
