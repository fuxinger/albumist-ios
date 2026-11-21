import Foundation
import AlbumistCore

// The space of our own globe: its vectors (`GlobeVector`) and the 4×4 matrices of the camera
// (`Matrix4`). Apart from `GlobeOptics`, which builds on them, as plain arithmetic.

/// A point or direction in the space of our own globe: the Earth is the unit sphere round the
/// origin, +y runs through the North Pole, +z through latitude 0° and longitude 0°, +x through
/// 0° N 90° E (right-handed). The globe's vertices, its arcs and its camera all live in it, so the
/// renderer, the pins above it and the gestures agree on every point.
public struct GlobeVector: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// The point of `coordinate` on the unit sphere.
    public init(_ coordinate: GeoCoordinate) {
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        self.init(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))
    }

    public static let zero = GlobeVector(0, 0, 0)

    /// The latitude and longitude of the direction (longitude in [-180, 180]); the zero vector
    /// gives 0° N 0° E.
    public var coordinate: GeoCoordinate {
        let horizontal = (x * x + z * z).squareRoot()
        return GeoCoordinate(latitude: atan2(y, horizontal) * 180 / .pi, longitude: atan2(x, z) * 180 / .pi)
    }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }

    /// The same direction with length 1; the zero vector (or one that is not finite) stays as it is.
    public var normalized: GlobeVector {
        let length = length
        guard length > 0, length.isFinite else { return self }
        return GlobeVector(x / length, y / length, z / length)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public func dot(_ other: GlobeVector) -> Double { x * other.x + y * other.y + z * other.z }

    public func cross(_ other: GlobeVector) -> GlobeVector {
        GlobeVector(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x)
    }

    public static func + (a: GlobeVector, b: GlobeVector) -> GlobeVector { GlobeVector(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: GlobeVector, b: GlobeVector) -> GlobeVector { GlobeVector(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: GlobeVector, s: Double) -> GlobeVector { GlobeVector(a.x * s, a.y * s, a.z * s) }
    public static prefix func - (a: GlobeVector) -> GlobeVector { GlobeVector(-a.x, -a.y, -a.z) }

    /// The angle between two directions in radians, exact for tiny and nearly opposite angles
    /// (atan2 of the cross and the dot product, not the arc cosine).
    public func angle(to other: GlobeVector) -> Double {
        atan2(cross(other).length, dot(other))
    }
}

/// A 4×4 matrix, column-major like Metal's `float4x4` (`values[column * 4 + row]`), so the app
/// copies `floats` straight into its uniforms or builds a `simd_float4x4` from its columns.
public struct Matrix4: Hashable, Sendable {
    /// Sixteen values, column by column.
    public var values: [Double]

    /// `columns` holds 16 values, column by column; anything else gives the identity.
    public init(columns: [Double]) {
        values = columns.count == 16 ? columns : Matrix4.identity.values
    }

    public static let identity = Matrix4(columns: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public subscript(row: Int, column: Int) -> Double { values[column * 4 + row] }

    public static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        var result = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 { sum += a[row, k] * b[k, column] }
                result[column * 4 + row] = sum
            }
        }
        return Matrix4(columns: result)
    }

    /// The matrix times the column vector (x, y, z, w).
    public func transform(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> Column {
        Column(x: self[0, 0] * x + self[0, 1] * y + self[0, 2] * z + self[0, 3] * w,
               y: self[1, 0] * x + self[1, 1] * y + self[1, 2] * z + self[1, 3] * w,
               z: self[2, 0] * x + self[2, 1] * y + self[2, 2] * z + self[2, 3] * w,
               w: self[3, 0] * x + self[3, 1] * y + self[3, 2] * z + self[3, 3] * w)
    }

    /// A column vector of four values, as `transform` gives it.
    public struct Column: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var z: Double
        public var w: Double
    }

    /// The values as 32-bit floats, column by column, for a uniform buffer.
    public var floats: [Float] { values.map { Float($0) } }
}
