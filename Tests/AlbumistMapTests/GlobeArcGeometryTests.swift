import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The arcs of our own globe (`GlobeArcGeometry`): great-circle curves that start and end on the
/// ground, rise symmetrically with their length, never leave the whole-Earth view, have one
/// defined path for any two ends, and become the vertex data the arc shader reads.
@Suite("Globe arc geometry")
struct GlobeArcGeometryTests {
    static let regensburg = GeoCoordinate(latitude: 49.0, longitude: 12.1)

    func arc(_ id: String, from: GeoCoordinate, to: GeoCoordinate, weight: Int = 1) -> MapArc {
        MapArc(id: id, from: from, to: to, tripIDs: (0..<weight).map { AlbumistID("\(id)-\($0)") }, years: [2024])
    }

    @Test func curvesStartAndEndOnTheGround() {
        for arc in GlobeScene.demo().arcs {
            let curve = GlobeArcGeometry.curve(from: arc.from, to: arc.to)
            #expect(curve.count == GlobeArcGeometry.segmentCount(forAngle: GlobeVector(arc.from).angle(to: GlobeVector(arc.to))) + 1)
            #expect(curve.first == GlobeVector(arc.from) && curve.last == GlobeVector(arc.to))
            #expect(abs(curve[0].length - 1) < 1e-12 && abs(curve[curve.count - 1].length - 1) < 1e-12)
            // Above the ground everywhere between, highest in the middle.
            let heights = curve.map { $0.length - 1 }
            #expect(heights.dropFirst().dropLast().allSatisfy { $0 > 0 })
            let apex = GlobeArcGeometry.lift(forAngle: GlobeVector(arc.from).angle(to: GlobeVector(arc.to)))
            #expect(abs((heights.max() ?? 0) - apex) < 1e-12)
            #expect(abs(heights[heights.count / 2] - apex) < 1e-12)
        }
    }

    @Test func theLiftIsSymmetric() {
        let pairs = [(Self.regensburg, GeoCoordinate(latitude: -33.87, longitude: 151.21)),
                     (GeoCoordinate(latitude: 64.1, longitude: -21.9), GeoCoordinate(latitude: 21.3, longitude: -157.9)),
                     (GeoCoordinate(latitude: -17, longitude: 179), GeoCoordinate(latitude: -18, longitude: -178))]
        for (from, to) in pairs {
            let curve = GlobeArcGeometry.curve(from: from, to: to)
            let n = curve.count - 1
            for i in 0...n {
                #expect(abs(curve[i].length - curve[n - i].length) < 1e-12)
            }
            // Backwards it is the same curve.
            let back = GlobeArcGeometry.curve(from: to, to: from)
            for i in 0...n {
                #expect((curve[i] - back[n - i]).length < 1e-12)
            }
        }
    }

    @Test func theLiftGrowsWithTheAngleAndLevelsOff() {
        var last = 0.0
        for i in 1...360 {
            let lift = GlobeArcGeometry.lift(forAngle: Double(i) * .pi / 360)
            #expect(lift > last)
            last = lift
        }
        #expect(GlobeArcGeometry.maximumLift == last && abs(last - 0.179) < 0.001)
        // A short hop rises about 18 % of its length, 6,000 km about 11 %.
        let hop = 300_000 / GeoMath.earthRadiusMeters
        #expect(abs(GlobeArcGeometry.lift(forAngle: hop) / hop - 0.19) < 0.01)
        let long = 6_000_000 / GeoMath.earthRadiusMeters
        #expect(abs(GlobeArcGeometry.lift(forAngle: long) / long - 0.11) < 0.01)
        for broken in [0.0, -1, .nan, .infinity] {
            #expect(GlobeArcGeometry.lift(forAngle: broken) == 0)
        }
        #expect(GlobeArcGeometry.lift(forAngle: 10) == GlobeArcGeometry.maximumLift)
    }

    @Test func segmentCountsStayInBounds() {
        var last = 0
        for i in 0...400 {
            let count = GlobeArcGeometry.segmentCount(forAngle: Double(i) * .pi / 400)
            #expect(count >= GlobeArcGeometry.minimumSegments && count <= GlobeArcGeometry.maximumSegments)
            #expect(count >= last && count % 2 == 0)
            last = count
        }
        #expect(GlobeArcGeometry.segmentCount(forAngle: 0) == GlobeArcGeometry.minimumSegments)
        #expect(GlobeArcGeometry.segmentCount(forAngle: .pi) == GlobeArcGeometry.maximumSegments)
        #expect(GlobeArcGeometry.segmentCount(forAngle: 49.9 * .pi / 180) == 40)
        for broken in [Double.nan, -3, .infinity] {
            #expect(GlobeArcGeometry.segmentCount(forAngle: broken) == GlobeArcGeometry.minimumSegments)
        }
    }

    @Test func identicalAndOppositeEndsHaveADefinedPath() {
        let same = GlobeArcGeometry.curve(from: Self.regensburg, to: Self.regensburg)
        #expect(same.count == GlobeArcGeometry.minimumSegments + 1 && same.allSatisfy { $0 == GlobeVector(Self.regensburg) })
        // Opposite points on the equator: through the North Pole.
        let opposite = GlobeArcGeometry.curve(from: GeoCoordinate(latitude: 0, longitude: 0), to: GeoCoordinate(latitude: 0, longitude: 180))
        #expect(opposite.allSatisfy { $0.isFinite })
        let middle = opposite[opposite.count / 2]
        #expect(middle.coordinate.latitude > 89.999 && abs(middle.length - 1 - GlobeArcGeometry.maximumLift) < 1e-12)
        // Pole to pole: through 0° N 0° E.
        let poles = GlobeArcGeometry.curve(from: GeoCoordinate(latitude: 90, longitude: 40), to: GeoCoordinate(latitude: -90, longitude: 0))
        #expect(poles.allSatisfy { $0.isFinite })
        let through = poles[poles.count / 2].coordinate
        #expect(abs(through.latitude) < 1e-9 && abs(through.longitude) < 1e-9)
        // Nearly opposite: a smooth path that still ends where it should.
        let nearly = GlobeArcGeometry.curve(from: GeoCoordinate(latitude: 10, longitude: 20), to: GeoCoordinate(latitude: -10, longitude: -160 + 1e-12))
        #expect(nearly.allSatisfy { $0.isFinite } && nearly.last == GlobeVector(GeoCoordinate(latitude: -10, longitude: -160 + 1e-12)))
        // Broken coordinates give nothing.
        #expect(GlobeArcGeometry.curve(from: GeoCoordinate(latitude: .nan, longitude: 0), to: Self.regensburg).isEmpty)
        #expect(GlobeArcGeometry.curve(from: Self.regensburg, to: GeoCoordinate(latitude: 0, longitude: .infinity)).isEmpty)
    }

    @Test func ribbonsHaveTheShadersLayout() {
        let arcs = [arc("a", from: Self.regensburg, to: GeoCoordinate(latitude: 40.7, longitude: -74.0), weight: 4),
                    arc("same", from: Self.regensburg, to: Self.regensburg),
                    arc("broken", from: Self.regensburg, to: GeoCoordinate(latitude: .nan, longitude: 1)),
                    arc("b", from: Self.regensburg, to: GeoCoordinate(latitude: 48.2, longitude: 16.4)),
                    arc("opposite", from: GeoCoordinate(latitude: 0, longitude: 0), to: GeoCoordinate(latitude: 0, longitude: 180))]
        let mesh = GlobeArcGeometry.ribbons(arcs)
        #expect(mesh.arcCount == 3)
        let drawn = [arcs[0], arcs[3], arcs[4]]
        let points = drawn.map { GlobeArcGeometry.curve(from: $0.from, to: $0.to).count }
        #expect(mesh.vertexCount == points.reduce(0) { $0 + 2 * $1 })
        #expect(mesh.vertices.count == mesh.vertexCount * GlobeArcMesh.floatsPerVertex)
        #expect(mesh.indices.count == points.reduce(0) { $0 + 6 * ($1 - 1) })
        #expect(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
        #expect(mesh.vertices.allSatisfy { $0.isFinite })
        func vertex(_ i: Int) -> ArraySlice<Float> {
            mesh.vertices[(i * GlobeArcMesh.floatsPerVertex)..<((i + 1) * GlobeArcMesh.floatsPerVertex)]
        }
        // The first arc: home first, both sides, its previous point itself, t 0, its weight's strength.
        let first = Array(vertex(0)), second = Array(vertex(1))
        #expect(first[9] == -1 && second[9] == 1)
        #expect(Array(first[0..<3]) == Array(first[3..<6]) && first[10] == 0 && first[13] == 0)
        #expect(abs(Double(first[11]) - GlobeArcGeometry.strength(forWeight: 4)) < 1e-6)
        let home = GlobeVector(Self.regensburg)
        #expect(abs(Double(first[0]) - home.x) < 1e-6 && abs(Double(first[1]) - home.y) < 1e-6 && abs(Double(first[2]) - home.z) < 1e-6)
        // Its last point: t 1, next point itself, the whole angle from home.
        let lastIndex = 2 * points[0] - 1
        let last = Array(vertex(lastIndex))
        #expect(last[10] == 1 && Array(last[0..<3]) == Array(last[6..<9]))
        let angle = home.angle(to: GlobeVector(GeoCoordinate(latitude: 40.7, longitude: -74.0)))
        #expect(abs(Double(last[13]) - angle) < 1e-5)
        // Phases differ between arcs and lie in [0, 1).
        let phases = Set([vertex(0)[vertex(0).startIndex + 12], vertex(2 * points[0])[vertex(2 * points[0]).startIndex + 12]])
        #expect(phases.count == 2 && phases.allSatisfy { $0 >= 0 && $0 < 1 })
        // The same arcs, the same data.
        #expect(GlobeArcGeometry.ribbons(arcs) == mesh)
        #expect(GlobeArcGeometry.ribbons([]).vertices.isEmpty)
        // The demo's 150 arcs stay small.
        let demo = GlobeArcGeometry.ribbons(GlobeScene.demo().arcs)
        #expect(demo.arcCount == 150 && demo.vertexCount < 30_000)
    }

    @Test func strengthGrowsWithTheWeight() {
        #expect(GlobeArcGeometry.strength(forWeight: 1) == 1 && GlobeArcGeometry.strength(forWeight: 0) == 1 && GlobeArcGeometry.strength(forWeight: -4) == 1)
        #expect(abs(GlobeArcGeometry.strength(forWeight: 2) - 1.35) < 1e-12 && abs(GlobeArcGeometry.strength(forWeight: 4) - 1.7) < 1e-12)
        #expect(GlobeArcGeometry.strength(forWeight: 1_000) == 2)
    }

    /// Even the highest arcs, seen from any side at the whole-Earth camera, stay inside the
    /// view with the ribbon's glow (`haloPoints` on each side).
    @Test func arcsNeverLeaveTheWholeEarthView() {
        let haloPoints = 8.0
        var arcs = GlobeScene.demo().arcs
        // Half way round, every way.
        for longitude in stride(from: -180.0, to: 180, by: 15) {
            arcs.append(arc("pole-\(longitude)", from: GeoCoordinate(latitude: 89.9, longitude: longitude),
                            to: GeoCoordinate(latitude: -89.9, longitude: longitude)))
            arcs.append(arc("equator-\(longitude)", from: GeoCoordinate(latitude: 0, longitude: longitude),
                            to: GeoCoordinate(latitude: 0, longitude: MapHome.normalizedLongitude(longitude + 179.9))))
        }
        let curves = arcs.map { GlobeArcGeometry.curve(from: $0.from, to: $0.to) }
        var outside: [String] = []
        var points = 0
        var narrowest = Double.infinity
        for latitude in stride(from: -80.0, through: 80, by: 40) {
            for longitude in stride(from: -180.0, to: 180, by: 45) {
                let optics = GlobeOptics(camera: GlobeCamera(center: GeoCoordinate(latitude: latitude, longitude: longitude),
                                                             widthMeters: GlobeCamera.wholeEarth.widthMeters),
                                         widthPoints: 390, heightPoints: 844)
                for curve in curves {
                    for point in curve {
                        points += 1
                        guard let screen = optics.screenPoint(point) else {
                            outside.append("behind the camera at \(latitude), \(longitude)")
                            continue
                        }
                        narrowest = min(narrowest, screen.x, 390 - screen.x)
                        if screen.x < haloPoints || screen.x > 390 - haloPoints || screen.y < 0 || screen.y > 844 {
                            outside.append("\(Int(screen.x)), \(Int(screen.y)) at \(latitude), \(longitude)")
                        }
                    }
                }
            }
        }
        #expect(points > 100_000)
        #expect(outside.isEmpty, "\(outside.prefix(5))")
        // The highest arcs come close to the sides: the lift is not wasted.
        #expect(narrowest < 30)
    }
}
