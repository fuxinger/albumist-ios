import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The camera model of our own globe (`GlobeOptics`): the width across the view's centre line is
/// exact up to the disc's edge (so the handover meets Apple's map on the same area), the disc
/// narrows in proportion beyond it, and screen points, matrices and broken input agree.
@Suite("Globe optics")
struct GlobeOpticsTests {
    static let width = 390.0, height = 844.0

    func optics(_ latitude: Double, _ longitude: Double, _ meters: Double) -> GlobeOptics {
        GlobeOptics(camera: GlobeCamera(center: GeoCoordinate(latitude: latitude, longitude: longitude), widthMeters: meters),
                    widthPoints: Self.width, heightPoints: Self.height)
    }

    static let centers: [(Double, Double)] = [(0, 0), (64.1, -19), (-33.9, 151.2), (10, 179.9), (-45, -179.95), (84.9, 30), (-84.9, -120)]

    // MARK: Width and distance

    @Test(arguments: [1_000.0, 10_000, 300_000, 3_000_000, 5_000_000, 12_000_000, GlobeOptics.limbWidthMeters * 0.999_999])
    func theWidthAcrossTheCentreLineIsExact(meters: Double) throws {
        for (latitude, longitude) in Self.centers {
            let optics = optics(latitude, longitude, meters)
            let left = try #require(optics.unproject(x: 0, y: Self.height / 2))
            let right = try #require(optics.unproject(x: Self.width, y: Self.height / 2))
            #expect(abs(GeoMath.distance(left, right) - meters) <= max(1e-6 * meters, 0.01), "\(latitude), \(longitude)")
            // Half of it on each side of the centre.
            let middle = try #require(optics.unproject(x: Self.width / 2, y: Self.height / 2))
            #expect(GeoMath.distance(middle, optics.camera.center) < 0.01)
            #expect(abs(GeoMath.distance(left, middle) - meters / 2) <= max(1e-6 * meters, 0.01))
        }
    }

    /// At the handover our globe shows what Apple's map region of 3,000 km shows across.
    @Test func theHandoverWidthMeetsApplesMap() throws {
        let iceland = optics(64.9, -18.6, GlobeCamera.handoverWidthMeters)
        let left = try #require(iceland.unproject(x: 0, y: Self.height / 2))
        let right = try #require(iceland.unproject(x: Self.width, y: Self.height / 2))
        #expect(abs(GeoMath.distance(left, right) - 3_000_000) < 0.01)
        // The eye stands about 1.74 Earth radii above the ground there, and the whole view is Earth.
        #expect(abs(iceland.distance - 2.744) < 0.01)
        for (x, y) in [(0.0, 0.0), (Self.width, 0), (0, Self.height), (Self.width, Self.height)] {
            #expect(iceland.unproject(x: x, y: y) != nil)
        }
    }

    @Test func beyondTheLimbTheDiscNarrowsInProportion() {
        for meters in [GlobeOptics.limbWidthMeters, GlobeCamera.wholeEarthWidthMeters, GlobeCamera.wholeEarth.widthMeters,
                       2 * GlobeCamera.wholeEarthWidthMeters, GlobeCamera.maximumWidthMeters] {
            let optics = optics(20, 40, meters)
            let fraction = GlobeOptics.limbWidthMeters / meters
            #expect(abs(optics.discWidthFraction - fraction) < 1e-9, "\(meters)")
            // The disc's edge on the centre line: just inside hits the Earth, just outside misses.
            let half = fraction * Self.width / 2
            #expect(optics.unproject(x: Self.width / 2 + half * 0.999, y: Self.height / 2) != nil)
            #expect(optics.unproject(x: Self.width / 2 - half * 0.999, y: Self.height / 2) != nil)
            #expect(optics.unproject(x: Self.width / 2 + half * 1.001, y: Self.height / 2) == nil)
            #expect(optics.unproject(x: Self.width / 2 - half * 1.001, y: Self.height / 2) == nil)
        }
        // The disc of the first view fills about 80 % of the width; the limb is reached a little
        // before the whole Earth's width.
        #expect(abs(optics(30, 10, GlobeCamera.wholeEarth.widthMeters).discWidthFraction - 0.797) < 0.001)
        #expect(GlobeOptics.limbWidthMeters < GlobeCamera.wholeEarthWidthMeters)
        #expect(GlobeOptics.limbWidthMeters > 0.9 * GlobeCamera.wholeEarthWidthMeters)
    }

    @Test func theDistanceIsContinuousAndGrowsWithTheWidth() {
        var previous = 1.0
        let steps = 4_000
        let low = log(GlobeCamera.minimumWidthMeters), high = log(GlobeCamera.maximumWidthMeters)
        for i in 0...steps {
            let meters = exp(low + (high - low) * Double(i) / Double(steps))
            let distance = GlobeOptics.distance(forWidth: meters)
            #expect(distance > previous, "\(meters)")
            #expect(distance.isFinite)
            // The inverse gives the width back.
            #expect(abs(GlobeOptics.width(forDistance: distance) - meters) <= 1e-6 * meters)
            previous = distance
        }
        // Both branches meet at the limb: 1 / sin(7.5°).
        let limb = GlobeOptics.limbWidthMeters
        let below = GlobeOptics.distance(forWidth: limb * (1 - 1e-12)), above = GlobeOptics.distance(forWidth: limb * (1 + 1e-12))
        #expect(abs(below - above) < 1e-9)
        #expect(abs(GlobeOptics.distance(forWidth: limb) - 1 / sin(7.5 * .pi / 180)) < 1e-12)
        // A small step in width is a small step in distance on both sides of the limb.
        for meters in [limb * 0.99, limb, limb * 1.01] {
            let step = GlobeOptics.distance(forWidth: meters * 1.001) - GlobeOptics.distance(forWidth: meters)
            #expect(step > 0 && step < 0.02)
        }
    }

    @Test func tinyAndHugeWidthsStayDrawable() {
        for meters in [0.0, 1, -5, 1e-300, 1e300, GlobeCamera.maximumWidthMeters * 10] {
            let optics = optics(48, 11, meters)
            #expect(optics.distance > 1 && optics.distance.isFinite)
            #expect(optics.viewProjectionMatrix.values.allSatisfy { $0.isFinite })
            #expect(optics.depthRange.near > 0 && optics.depthRange.near < optics.depthRange.far)
            #expect(optics.haloHalfSize.isFinite && optics.haloHalfSize > 0)
        }
        #expect(optics(48, 11, 1).camera.widthMeters == GlobeCamera.minimumWidthMeters)
        #expect(optics(48, 11, 1e300).camera.widthMeters == GlobeCamera.maximumWidthMeters)
        // The closest view still stands above the ground, the farthest a few dozen radii away.
        #expect(GlobeOptics.distance(forWidth: GlobeCamera.minimumWidthMeters) - 1 > 1e-5)
        #expect(GlobeOptics.distance(forWidth: GlobeCamera.maximumWidthMeters) < 30)
    }

    @Test func brokenInputFallsBackToTheWholeEarth() {
        let broken = GlobeOptics(camera: GlobeCamera(center: GeoCoordinate(latitude: .nan, longitude: .infinity), widthMeters: .nan),
                                 widthPoints: .nan, heightPoints: -3)
        #expect(broken.camera == GlobeCamera.wholeEarth)
        #expect(broken.widthPoints == 1 && broken.heightPoints == 1)
        #expect(broken.viewMatrix.values.allSatisfy { $0.isFinite } && broken.projectionMatrix.values.allSatisfy { $0.isFinite })
        let infinite = optics(10, 10, .infinity)
        #expect(infinite.camera.widthMeters == GlobeCamera.wholeEarth.widthMeters)
        #expect(optics(.nan, 10, 5_000_000).camera.center == GlobeCamera.wholeEarth.center)
        let nowhere = infinite.project(GeoCoordinate(latitude: .nan, longitude: 3))
        #expect(!nowhere.isVisible)
        #expect(infinite.unproject(x: .nan, y: 10) == nil)
        #expect(infinite.cameraPlacing(GeoCoordinate(latitude: .nan, longitude: 0), atX: 100, y: 100) == nil)
        #expect(infinite.rotated(byX: .nan, y: 3) == infinite.camera)
    }

    // MARK: Poles and antimeridian

    @Test func northStaysUpNearThePoles() {
        for latitude in [90.0, 89.99, 120, -90, -1_000] {
            let optics = optics(latitude, 0, 5_000_000)
            #expect(abs(optics.camera.center.latitude) == GlobeOptics.latitudeLimit)
            #expect(optics.up.y > 0)
            #expect(optics.right.length > 0.999 && abs(optics.right.dot(optics.up)) < 1e-12 && abs(optics.right.dot(optics.back)) < 1e-12)
        }
        // From a camera at 85° N the North Pole lies straight above the centre.
        let north = optics(90, 25, 5_000_000).project(GeoCoordinate(latitude: 90, longitude: 0))
        #expect(north.isVisible && abs(north.x - Self.width / 2) < 1e-6 && north.y < Self.height / 2)
        let south = optics(-90, 25, 5_000_000).project(GeoCoordinate(latitude: -90, longitude: 0))
        #expect(south.isVisible && abs(south.x - Self.width / 2) < 1e-6 && south.y > Self.height / 2)
    }

    @Test func theAntimeridianIsNoEdge() throws {
        let optics = optics(-17, 179.5, 3_000_000)
        // Fiji's east, across the date line, lies right of the centre (east is right).
        let east = optics.project(GeoCoordinate(latitude: -17, longitude: -179.5))
        #expect(east.isVisible && east.x > Self.width / 2 && east.x < Self.width)
        let west = optics.project(GeoCoordinate(latitude: -17, longitude: 178.5))
        #expect(west.isVisible && west.x < Self.width / 2)
        let right = try #require(optics.unproject(x: Self.width * 0.75, y: Self.height / 2))
        #expect(right.longitude < -170 && right.longitude > -178)
        // A camera given past the date line wraps round.
        #expect(GlobeOptics.sanitized(GlobeCamera(center: GeoCoordinate(latitude: 0, longitude: 190), widthMeters: 3e6)).center.longitude == -170)
    }

    // MARK: Screen and matrices

    @Test func screenPointsRoundTrip() throws {
        for (latitude, longitude) in Self.centers {
            for meters in [3_000_000.0, 9_000_000, GlobeCamera.wholeEarth.widthMeters] {
                let optics = optics(latitude, longitude, meters)
                for x in stride(from: 0.0, through: Self.width, by: 39) {
                    for y in stride(from: 0.0, through: Self.height, by: 84.4) {
                        guard let coordinate = optics.unproject(x: x, y: y) else { continue }
                        let back = optics.project(coordinate)
                        #expect(back.isVisible || back.horizonMargin > -1e-9)
                        #expect(abs(back.x - x) < 1e-6 && abs(back.y - y) < 1e-6, "\(x), \(y)")
                    }
                }
                let center = optics.project(optics.camera.center)
                #expect(abs(center.x - Self.width / 2) < 1e-9 && abs(center.y - Self.height / 2) < 1e-9)
                #expect(abs(center.horizonMargin - 1) < 1e-12)
                // The antipode is hidden, as is everything beyond the horizon.
                let antipode = GeoCoordinate(latitude: -optics.camera.center.latitude, longitude: MapHome.normalizedLongitude(optics.camera.center.longitude + 180))
                #expect(!optics.project(antipode).isVisible)
            }
        }
    }

    @Test func theMatricesAgreeWithTheProjection() {
        for (latitude, longitude) in Self.centers {
            for meters in [3_000_000.0, GlobeCamera.wholeEarth.widthMeters, GlobeCamera.maximumWidthMeters] {
                let optics = optics(latitude, longitude, meters)
                let matrix = optics.viewProjectionMatrix
                for coordinate in [GeoCoordinate(latitude: latitude + 3, longitude: longitude - 4), optics.camera.center,
                                   GeoCoordinate(latitude: 0, longitude: 179.99), GeoCoordinate(latitude: -60, longitude: -60)] {
                    let p = GlobeVector(coordinate)
                    let clip = matrix.transform(p.x, p.y, p.z, 1)
                    let point = optics.project(coordinate)
                    let x = (clip.x / clip.w + 1) / 2 * Self.width, y = (1 - clip.y / clip.w) / 2 * Self.height
                    #expect(abs(x - point.x) < 1e-6 && abs(y - point.y) < 1e-6)
                    // Every point of the Earth and of an arc lies between the near and far planes.
                    #expect(clip.z / clip.w > 0 && clip.z / clip.w < 1)
                    let lifted = p * (1 + GlobeArcGeometry.maximumLift)
                    let high = matrix.transform(lifted.x, lifted.y, lifted.z, 1)
                    #expect(high.z / high.w > 0 && high.z / high.w < 1)
                }
                // The eye is the camera's origin.
                let eye = optics.viewMatrix.transform(optics.eye.x, optics.eye.y, optics.eye.z, 1)
                #expect(abs(eye.x) < 1e-9 && abs(eye.y) < 1e-9 && abs(eye.z) < 1e-9)
                #expect(optics.viewProjectionMatrix.floats.count == 16)
                // The sky turns with the camera but does not move: the centre's direction is straight ahead.
                let ahead = optics.skyMatrix.transform(-optics.back.x, -optics.back.y, -optics.back.z, 0)
                #expect(abs(ahead.x) < 1e-9 && abs(ahead.y) < 1e-9 && ahead.w > 0)
            }
        }
        let a = Matrix4(columns: (0..<16).map(Double.init)), identity = Matrix4.identity
        #expect(a * identity == a && identity * a == a)
        #expect(Matrix4(columns: [1, 2]) == .identity)
    }

    /// The halo's square holds every ray that passes the Earth within the halo's radius.
    @Test func theHaloSquareHoldsTheGlow() {
        for meters in [3_000_000.0, GlobeCamera.wholeEarth.widthMeters, GlobeCamera.maximumWidthMeters] {
            let optics = optics(10, 10, meters)
            let d = optics.distance, r = GlobeOptics.haloRadius
            let needed = d * r / (d * d - r * r).squareRoot()
            #expect(optics.haloHalfSize >= needed)
        }
    }

    // MARK: Pins

    @Test func pinsStandOnTheirPlacesAndFadeAtTheHorizon() throws {
        let optics = optics(48, 11, GlobeCamera.wholeEarth.widthMeters)
        func group(_ id: String, _ latitude: Double, _ longitude: Double) -> MapPinGroup {
            MapPinGroup(pin: MapPin(id: id, level: .trip, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude), count: 3), memberIDs: [id])
        }
        // 82° from the centre towards the right: just before the horizon (84° at this distance).
        let angle = 82 * Double.pi / 180
        let limbPoint = (optics.back * cos(angle) + optics.right * sin(angle)).coordinate
        let placed = optics.place([group("near", 48, 11), group("far", -48, -169), group("limb", limbPoint.latitude, limbPoint.longitude),
                                   group("rome", 41.9, 12.5)])
        let ids = placed.map(\.id)
        #expect(!ids.contains("far"))
        #expect(ids.contains("near") && ids.contains("rome") && ids.contains("limb"))
        let near = try #require(placed.first { $0.id == "near" })
        #expect(abs(near.x - Self.width / 2) < 1e-6 && abs(near.y - Self.height / 2) < 1e-6 && near.opacity == 1)
        let limb = try #require(placed.first { $0.id == "limb" })
        #expect(limb.opacity > 0 && limb.opacity < 1 && limb.x > Self.width / 2)
        // Nearer pins come last, so they are drawn on top.
        #expect(ids == ["limb", "rome", "near"])
        // A view of the demo at the whole Earth places only pins in front of the horizon.
        let scene = GlobeScene.demo()
        let groups = MapPins.onGlobe(scene.pins, in: optics.camera.viewport(widthPoints: Self.width, heightPoints: Self.height))
        let demo = optics.place(groups)
        #expect(!demo.isEmpty && demo.count <= groups.count)
        for pin in demo {
            #expect(optics.project(pin.group.pin.coordinate).isVisible)
            #expect(pin.opacity > 0 && pin.opacity <= 1)
        }
    }
}
