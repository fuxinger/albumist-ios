import Foundation
import AlbumistCore

/// The arcs of our own globe as 3D curves and as the vertex data of glowing ribbons (concept §4.2,
/// §7: "Bögen sind echte Kurven über der Erde mit weichem Schein", like Flighty). Each `MapArc`
/// follows the great circle from home to the destination and rises above the Earth in the
/// middle (`sin(π t)` along it); the rise grows with the arc's angle and levels off, so a short
/// hop stays low, a long-haul arc floats high, and even an arc half way round the Earth stays in
/// the view at the whole-Earth camera (`maximumLift`). Units are Earth radii, in the globe's space
/// (`GlobeVector`).
public enum GlobeArcGeometry {
    /// The apex lift approaches this for ever longer arcs ...
    static let liftCeiling = 0.25
    /// ... and reaches half of it at this angle (radians, about 8,000 km).
    static let liftHalfAngle = 1.25
    /// The highest apex, of an arc half way round the Earth: about 0.18 Earth radii.
    public static let maximumLift = lift(forAngle: .pi)

    /// The apex height above the surface of an arc spanning `angle` radians:
    /// `0.25 · angle / (angle + 1.25)`, about 18 % of the arc's length for short hops, 11 % at
    /// 6,000 km, 0.18 Earth radii half way round. 0 for no angle or one that is no number.
    public static func lift(forAngle angle: Double) -> Double {
        guard angle.isFinite, angle > 0 else { return 0 }
        let a = min(angle, .pi)
        return liftCeiling * a / (a + liftHalfAngle)
    }

    /// A segment spans at most this angle, so the curve looks round at every zoom of our globe.
    public static let maximumSegmentDegrees = 1.25
    public static let minimumSegments = 8
    public static let maximumSegments = 144

    /// Segments for an arc spanning `angle` radians: one per `maximumSegmentDegrees`, an even
    /// number (so the apex is a point of the curve), within `minimumSegments...maximumSegments`.
    public static func segmentCount(forAngle angle: Double) -> Int {
        guard angle.isFinite, angle > 0 else { return minimumSegments }
        let wanted = (angle * 180 / .pi / maximumSegmentDegrees / 2).rounded(.up) * 2
        return Int(min(max(wanted, Double(minimumSegments)), Double(maximumSegments)))
    }

    /// The arc's curve: `segmentCount + 1` points from `from` to `to`, both on the surface, the
    /// lift symmetric round the middle. Identical endpoints give the point itself every time;
    /// opposite ones (no single great circle) the path through the point a quarter turn north
    /// of the start (east of it at a pole), so every input has one defined curve. Coordinates
    /// that are not numbers give no points.
    public static func curve(from: GeoCoordinate, to: GeoCoordinate) -> [GlobeVector] {
        guard from.latitude.isFinite, from.longitude.isFinite, to.latitude.isFinite, to.longitude.isFinite else { return [] }
        let a = GlobeVector(from), b = GlobeVector(to)
        let angle = a.angle(to: b)
        let lift = lift(forAngle: angle)
        let segments = segmentCount(forAngle: angle)
        return (0...segments).map { i in
            if i == 0 { return a }
            if i == segments { return b }
            let t = Double(i) / Double(segments)
            return slerp(a, b, t) * (1 + lift * sin(.pi * t))
        }
    }

    /// The point a share `t` of the way from `a` to `b` along their great circle (unit vectors).
    /// The same point for identical ones; for opposite ones (or nearly: closer than 10⁻⁹ to a half
    /// turn) the path through `quarterTurn(from: a)`.
    public static func slerp(_ a: GlobeVector, _ b: GlobeVector, _ t: Double) -> GlobeVector {
        let angle = a.angle(to: b)
        if angle < 1e-12 { return a }
        if Double.pi - angle < 1e-9 {
            let middle = quarterTurn(from: a)
            return a * cos(.pi * t) + middle * sin(.pi * t)
        }
        let s = sin(angle)
        return a * (sin((1 - t) * angle) / s) + b * (sin(t * angle) / s)
    }

    /// The unit vector a quarter turn from `a` towards the North Pole; at a pole, towards 0° N 0° E.
    static func quarterTurn(from a: GlobeVector) -> GlobeVector {
        let north = GlobeVector(0, 1, 0)
        let towards = north - a * a.dot(north)
        if towards.length > 1e-9 { return towards.normalized }
        let meridian = GlobeVector(0, 0, 1)
        return (meridian - a * a.dot(meridian)).normalized
    }

    /// How much stronger an arc is drawn for its weight (`MapArc.weight`, its trips): 1 for one
    /// trip, growing with the logarithm (two trips 1.35, four 1.7), at most 2.
    public static func strength(forWeight weight: Int) -> Double {
        guard weight > 1 else { return 1 }
        return min(2, 1 + 0.35 * log2(Double(weight)))
    }

    /// The vertex data of the glowing ribbons of `arcs`, for one draw call (`GlobeArcMesh`).
    /// Arcs without a length (identical ends, which draw nothing) or with broken coordinates
    /// are left out. The same arcs always give the same data.
    public static func ribbons(_ arcs: [MapArc]) -> GlobeArcMesh {
        var vertices: [Float] = []
        var indices: [UInt32] = []
        var drawn = 0
        for (index, arc) in arcs.enumerated() {
            let points = curve(from: arc.from, to: arc.to)
            guard points.count >= 2 else { continue }
            let angle = points[0].angle(to: points[points.count - 1])
            guard angle > 1e-7 else { continue }
            let strength = Float(strength(forWeight: arc.weight))
            // A golden-ratio spread of the travelling light's start along the arcs.
            let phase = Float((Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1))
            let base = UInt32(vertices.count / GlobeArcMesh.floatsPerVertex)
            let last = points.count - 1
            for i in 0...last {
                let t = Double(i) / Double(last)
                let previous = points[max(i - 1, 0)], next = points[min(i + 1, last)]
                for side in [Float(-1), Float(1)] {
                    vertices += [Float(points[i].x), Float(points[i].y), Float(points[i].z),
                                 Float(previous.x), Float(previous.y), Float(previous.z),
                                 Float(next.x), Float(next.y), Float(next.z),
                                 side, Float(t), strength, phase, Float(t * angle)]
                }
            }
            for i in 0..<UInt32(last) {
                let v = base + 2 * i
                indices += [v, v + 1, v + 2, v + 1, v + 3, v + 2]
            }
            drawn += 1
        }
        return GlobeArcMesh(vertices: vertices, indices: indices, arcCount: drawn)
    }
}

/// Vertex data of the arcs' ribbons, widened on screen in the vertex shader: each curve point
/// twice (sides −1 and +1), and two triangles per segment.
///
/// Per vertex `floatsPerVertex` 32-bit floats, in the order of the shader's struct (all 4-byte
/// aligned, 56 bytes, so `packed_float3` reads the vectors): position (3), previous point (3),
/// next point (3) along the curve (the point itself at the ends), side (−1 or 1), t (0 at home,
/// 1 at the destination), strength (`GlobeArcGeometry.strength(forWeight:)`), phase (where the
/// arc's travelling light starts, 0 to 1), distance from home along the surface (radians).
public struct GlobeArcMesh: Hashable, Sendable {
    public static let floatsPerVertex = 14

    public var vertices: [Float]
    public var indices: [UInt32]
    /// Arcs with a ribbon.
    public var arcCount: Int

    public init(vertices: [Float], indices: [UInt32], arcCount: Int) {
        self.vertices = vertices
        self.indices = indices
        self.arcCount = arcCount
    }

    public var vertexCount: Int { vertices.count / Self.floatsPerVertex }
}
