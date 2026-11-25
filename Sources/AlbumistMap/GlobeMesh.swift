import Foundation
import AlbumistCore

/// The fixed geometry of our own globe: the Earth's sphere with the coordinates of its image, and
/// the stars round it. Plain numbers made once, so the app only copies them into Metal buffers.
public enum GlobeMesh {
    /// Per sphere vertex: position x, y, z on the unit sphere (`GlobeVector`), then u, v of the
    /// equirectangular Earth image (u = (lon + 180) / 360, v = (90 − lat) / 180, the image's
    /// left edge at −180°, north up).
    public static let floatsPerSphereVertex = 5

    /// A sphere of `longitudeSegments` × `latitudeSegments` quads (at least 3 × 2), rows from the
    /// North Pole down, each row from −180° to 180° with the seam's vertex twice (u = 0 and
    /// u = 1), so the image never wraps inside a triangle. The poles' rows have one triangle per
    /// quad (the other would have no area). Triangles turn counter-clockwise seen from outside.
    /// 192 × 96 makes the outline round to far below a pixel on any iPhone and costs about 18,700
    /// vertices.
    public static func sphere(longitudeSegments: Int = 192, latitudeSegments: Int = 96) -> (vertices: [Float], indices: [UInt32]) {
        let columns = max(longitudeSegments, 3), rows = max(latitudeSegments, 2)
        var vertices: [Float] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1) * floatsPerSphereVertex)
        for row in 0...rows {
            let v = Double(row) / Double(rows)
            let latitude = 90 - 180 * v
            for column in 0...columns {
                let u = Double(column) / Double(columns)
                let p = GlobeVector(GeoCoordinate(latitude: latitude, longitude: -180 + 360 * u))
                vertices += [Float(p.x), Float(p.y), Float(p.z), Float(u), Float(v)]
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(columns * rows * 6)
        let stride = UInt32(columns + 1)
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt32(row) * stride + UInt32(column)   // north-west
                let b = a + 1                                    // north-east
                let c = a + stride                               // south-west
                let d = c + 1                                    // south-east
                if row > 0 { indices += [a, c, b] }
                if row < rows - 1 { indices += [b, c, d] }
            }
        }
        return (vertices, indices)
    }

    /// Per star: its direction x, y, z (unit length) and its brightness (0 to 1).
    public static let floatsPerStar = 4

    /// `count` stars spread evenly over the sky, the same ones for a seed every time: most of
    /// them faint, a few bright, as a real night sky. The camera's narrow view shows about one
    /// in a hundred of them at a time, so the sky needs thousands.
    public static func stars(count: Int = 6_000, seed: UInt64 = 0x5EED_57A2) -> [Float] {
        var generator = SplitMix64(seed: seed)
        var values: [Float] = []
        values.reserveCapacity(max(count, 0) * floatsPerStar)
        for _ in 0..<max(count, 0) {
            let z = 2 * generator.nextUnit() - 1
            let angle = 2 * Double.pi * generator.nextUnit()
            let r = max(0, 1 - z * z).squareRoot()
            let brightness = 0.08 + 0.92 * pow(generator.nextUnit(), 5)
            values += [Float(r * cos(angle)), Float(r * sin(angle)), Float(z), Float(brightness)]
        }
        return values
    }
}

/// A small, fast, well-mixed generator (Steele, Lea, Flood 2014) for reproducible stars.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in [0, 1) with 53 random bits.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
