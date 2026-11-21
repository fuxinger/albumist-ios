import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// A `GlobeCamera` in Apple's maps (`MapKitCamera`): the region after the handover and back, the
/// camera distance of Apple's globe and its calibration, and the globe's test spin.
@Suite("MapKit camera")
struct MapKitCameraTests {
    static let iceland = GeoCoordinate(latitude: 64, longitude: -19)
    static let radius = GeoMath.earthRadiusMeters

    static func relative(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(abs(b), 1e-300) }

    // MARK: Region

    @Test func theRegionFollowsTheSharedConvention() {
        let camera = GlobeCamera(center: Self.iceland, widthMeters: 2_900_000)
        let region = MapKitCamera.region(for: camera, widthPoints: 390, heightPoints: 844)
        #expect(region.center == Self.iceland)
        #expect(region.longitudinalMeters == 2_900_000)
        #expect(Self.relative(region.latitudinalMeters, 2_900_000 * 844 / 390) < 1e-12)
        #expect(Self.relative(region.latitudeDelta, region.latitudinalMeters / 111_320) < 1e-12)
        #expect(Self.relative(region.longitudeDelta, 2_900_000 / (111_320 * cos(64 * Double.pi / 180))) < 1e-12)
        // A landscape view is as wide and less high.
        let wide = MapKitCamera.region(for: camera, widthPoints: 844, heightPoints: 390)
        #expect(wide.longitudeDelta == region.longitudeDelta && wide.latitudeDelta < region.latitudeDelta)
    }

    @Test func aRegionsWidthComesBack() {
        for latitude in [-89.0, -60, -33.9, 0, 12.5, 45, 64.1, 78.2, 89] {
            for width in [1_000.0, 25_000, 300_000, 2_999_999, 3_000_000] {
                let camera = GlobeCamera(center: GeoCoordinate(latitude: latitude, longitude: 170), widthMeters: width)
                let region = MapKitCamera.region(for: camera, widthPoints: 390, heightPoints: 844)
                guard region.longitudeDelta < MapKitCamera.maximumLongitudeDelta else { continue }
                let back = MapKitCamera.widthMeters(centerLatitude: region.center.latitude, longitudeDelta: region.longitudeDelta)
                #expect(back.map { Self.relative($0, width) < 1e-9 } == true, "\(latitude) \(width)")
                let again = MapKitCamera.camera(center: region.center, longitudeDelta: region.longitudeDelta)
                #expect(again?.center == camera.center)
                #expect(again.map { Self.relative($0.widthMeters, width) < 1e-9 } == true)
            }
        }
    }

    @Test func aRegionStaysWithinMapKitsLimits() {
        let cameras = [
            GlobeCamera(center: GeoCoordinate(latitude: 90, longitude: 0), widthMeters: 3_000_000),       // the pole
            GlobeCamera(center: GeoCoordinate(latitude: -89.999, longitude: 0), widthMeters: 3_000_000),
            GlobeCamera(center: GeoCoordinate(latitude: 0, longitude: 179.9), widthMeters: GlobeCamera.maximumWidthMeters),
            GlobeCamera(center: GeoCoordinate(latitude: 10, longitude: 10), widthMeters: 1),                // below the minimum
            GlobeCamera(center: GeoCoordinate(latitude: .nan, longitude: .infinity), widthMeters: .nan),    // broken
            GlobeCamera(center: GeoCoordinate(latitude: 120, longitude: 540), widthMeters: 1e30),
        ]
        for camera in cameras {
            for (w, h) in [(390.0, 844.0), (0, 844), (.nan, 1), (390, 1e12), (-1, -1)] {
                let region = MapKitCamera.region(for: camera, widthPoints: w, heightPoints: h)
                #expect(region.latitudeDelta.isFinite && region.latitudeDelta >= MapKitCamera.minimumDelta && region.latitudeDelta <= 180)
                #expect(region.longitudeDelta.isFinite && region.longitudeDelta >= MapKitCamera.minimumDelta && region.longitudeDelta <= 360)
                #expect(region.center.latitude.isFinite && abs(region.center.latitude) <= 90)
                #expect(region.center.longitude >= -180 && region.center.longitude < 180)
            }
        }
        // At the pole a degree of longitude is no metres: the whole circle.
        #expect(MapKitCamera.region(for: cameras[0], widthPoints: 390, heightPoints: 844).longitudeDelta == 360)
        // A view size that is no number counts as square.
        let square = MapKitCamera.region(for: GlobeCamera(center: Self.iceland, widthMeters: 100_000), widthPoints: .nan, heightPoints: 844)
        #expect(square.latitudinalMeters == square.longitudinalMeters)
    }

    @Test func aBrokenRegionHasNoWidth() {
        #expect(MapKitCamera.widthMeters(centerLatitude: .nan, longitudeDelta: 1) == nil)
        #expect(MapKitCamera.widthMeters(centerLatitude: 10, longitudeDelta: .infinity) == nil)
        #expect(MapKitCamera.widthMeters(centerLatitude: 95, longitudeDelta: 10).map { $0 < 1e-6 } == true)
        #expect(MapKitCamera.widthMeters(centerLatitude: 0, longitudeDelta: 400) == MapKitCamera.widthMeters(centerLatitude: 0, longitudeDelta: 360))
        #expect(MapKitCamera.widthMeters(centerLatitude: 0, longitudeDelta: -3) == 0)
        #expect(MapKitCamera.camera(center: GeoCoordinate(latitude: .nan, longitude: 0), longitudeDelta: 1) == nil)
    }

    @Test func zoomingOutBeyondATenthOverTheHandoverGoesBackToTheGlobe() {
        #expect(abs(MapKitCamera.backToGlobeWidthMeters - 3_300_000) < 1e-6)
        #expect(!MapKitCamera.isBackToGlobe(widthMeters: 2_999_999))
        #expect(!MapKitCamera.isBackToGlobe(widthMeters: 3_300_000))
        #expect(MapKitCamera.isBackToGlobe(widthMeters: 3_300_001))
        #expect(MapKitCamera.isBackToGlobe(widthMeters: .infinity))
        #expect(!MapKitCamera.isBackToGlobe(widthMeters: .nan))
        // The width a handover starts at is far from it.
        let start = MapKitCamera.region(for: GlobeCamera(center: Self.iceland, widthMeters: 2_999_000), widthPoints: 390, heightPoints: 844)
        #expect(!MapKitCamera.isBackToGlobe(widthMeters: MapKitCamera.widthMeters(centerLatitude: 64, longitudeDelta: start.longitudeDelta) ?? 0))
    }

    // MARK: Camera distance

    @Test func distanceAndWidthAreInverse() {
        for factor in [0.6, 1.2, MapKitCamera.assumedDistanceFactor, 4.0] {
            var previous = 0.0
            for width in [1_000.0, 10_000, 300_000, 3_000_000, 8_000_000, 15_000_000, 19_000_000, GlobeCamera.wholeEarthWidthMeters,
                          GlobeCamera.wholeEarth.widthMeters, 2 * GlobeCamera.wholeEarthWidthMeters, GlobeCamera.maximumWidthMeters] {
                let distance = MapKitCamera.distance(forWidth: width, factor: factor)
                #expect(distance > previous, "\(factor) \(width)")
                previous = distance
                #expect(Self.relative(MapKitCamera.widthMeters(forDistance: distance, factor: factor), width) < 1e-6, "\(factor) \(width)")
            }
        }
    }

    @Test func aSmallViewIsThePinholeCamera() {
        let factor = MapKitCamera.assumedDistanceFactor
        #expect(Self.relative(factor, 1.866_025_403_784_438_6) < 1e-12)  // a field of view of 30°
        #expect(Self.relative(MapKitCamera.distance(forWidth: 1_000, factor: factor), 1_000 * factor) < 1e-3)
        #expect(Self.relative(MapKitCamera.distance(forWidth: 1_000, factor: 3), 3_000) < 1e-3)
        // At the handover width the width is the arc the view's edges see (no stretch to speak of).
        let distance = MapKitCamera.distance(forWidth: GlobeCamera.handoverWidthMeters, factor: factor)
        let half = atan(1 / (2 * factor))
        let arc = asin((Self.radius + distance) * sin(half) / Self.radius) - half
        #expect(Self.relative(2 * Self.radius * arc, GlobeCamera.handoverWidthMeters) < 1e-4)
    }

    @Test func theWholeEarthIsTheDiscAsWideAsTheView() {
        let factor = MapKitCamera.assumedDistanceFactor
        let half = atan(1 / (2 * factor))
        // The disc's edges touch the view's edges: seen at the half field of view.
        let whole = MapKitCamera.distance(forWidth: GlobeCamera.wholeEarthWidthMeters, factor: factor)
        #expect(Self.relative(asin(Self.radius / (Self.radius + whole)), half) < 1e-9)
        // Twice as wide: the disc half as wide (`GlobeCamera`'s convention).
        let twice = MapKitCamera.distance(forWidth: 2 * GlobeCamera.wholeEarthWidthMeters, factor: factor)
        let discShare = tan(asin(Self.radius / (Self.radius + twice))) / tan(half)
        #expect(abs(discShare - 0.5) < 1e-9)
        // The prototype's first view of the whole Earth is about 21,700 km away with the assumed lens.
        let first = MapKitCamera.distance(forWidth: GlobeCamera.wholeEarth.widthMeters)
        #expect(first > 21_000_000 && first < 22_500_000)
    }

    @Test func brokenNumbersGiveNoCamera() {
        #expect(MapKitCamera.distance(forWidth: .nan) == 0)
        #expect(MapKitCamera.distance(forWidth: -5) == 0)
        #expect(MapKitCamera.distance(forWidth: 0) == 0)
        #expect(MapKitCamera.distance(forWidth: .infinity) == .infinity)
        #expect(MapKitCamera.widthMeters(forDistance: .nan) == 0)
        #expect(MapKitCamera.widthMeters(forDistance: -1) == 0)
        #expect(MapKitCamera.widthMeters(forDistance: .infinity) == .infinity)
        // A factor that is no number is the assumed one; an absurd one is held in range.
        #expect(MapKitCamera.distance(forWidth: 50_000, factor: .nan) == MapKitCamera.distance(forWidth: 50_000))
        #expect(MapKitCamera.distance(forWidth: 50_000, factor: -2) == MapKitCamera.distance(forWidth: 50_000))
        #expect(MapKitCamera.distance(forWidth: 50_000, factor: 1e9) == MapKitCamera.distance(forWidth: 50_000, factor: 50))
    }

    @Test func whatMapKitReportsCalibratesTheFactor() {
        for factor in [0.8, 1.2, MapKitCamera.assumedDistanceFactor, 3.0, 7.5] {
            for width in [800.0, 40_000, 600_000, 2_000_000, 3_000_000] {
                let distance = MapKitCamera.distance(forWidth: width, factor: factor)
                let measured = MapKitCamera.distanceFactor(distance: distance, widthMeters: width)
                #expect(measured.map { Self.relative($0, factor) < 1e-6 } == true, "\(factor) \(width)")
            }
        }
        // A small view: distance over width.
        #expect(MapKitCamera.distanceFactor(distance: 1_500, widthMeters: 1_000).map { Self.relative($0, 1.5) < 1e-3 } == true)
        // No calibration from a wide view, broken numbers or an absurd ratio.
        #expect(MapKitCamera.distanceFactor(distance: 9_000_000, widthMeters: 5_000_000) == nil)
        #expect(MapKitCamera.distanceFactor(distance: .nan, widthMeters: 1_000) == nil)
        #expect(MapKitCamera.distanceFactor(distance: 1_000, widthMeters: 0) == nil)
        #expect(MapKitCamera.distanceFactor(distance: -1, widthMeters: 1_000) == nil)
        #expect(MapKitCamera.distanceFactor(distance: 1, widthMeters: 1_000_000) == nil)
        #expect(MapKitCamera.distanceFactor(distance: 1_000_000, widthMeters: 1) == nil)
    }

    // MARK: Test spin

    @Test func theSpinTurnsSixHundredDegreesInAMinute() {
        let steps = MapKitCamera.spin(fromLongitude: 10)
        let animated = steps.filter { $0.seconds > 0 }
        #expect(abs(animated.reduce(0) { $0 + $1.seconds } - 60) < 1e-9)
        #expect(animated.allSatisfy { $0.seconds <= 2 + 1e-9 })
        // Like the Earth: the centre's longitude falls; 600° in all, across the antimeridian twice.
        var longitude = 10.0, turned = 0.0, jumps = 0
        for step in steps {
            #expect(step.longitude >= -180 && step.longitude <= 180)
            if step.seconds == 0 {
                // Only at the antimeridian, from just west of it to just east (no animation).
                #expect(abs(longitude) > 179.99 && abs(step.longitude) > 179.99 && longitude.sign != step.longitude.sign)
                jumps += 1
            } else {
                let change = step.longitude - longitude
                // No animated step crosses the antimeridian: the change is the turn itself.
                #expect(change < 0 && abs(-change - 10 * step.seconds) < 1e-9)
                turned -= change
            }
            longitude = step.longitude
        }
        #expect(abs(turned - 600) < 1e-6 && jumps == 2)
        #expect(abs(longitude - 130) < 0.01)
    }

    @Test func theSpinTurnsTheOtherWayAndFromAnyLongitude() {
        let steps = MapKitCamera.spin(fromLongitude: 539, degreesPerSecond: -30, seconds: 10, stepSeconds: 3)
        // 539° is 179°; 300° east: across once.
        var longitude = 179.0, turned = 0.0
        for step in steps {
            if step.seconds > 0 {
                #expect(step.longitude - longitude > 0 && step.seconds <= 3 + 1e-9)
                turned += step.longitude - longitude
            }
            longitude = step.longitude
        }
        #expect(abs(turned - 300) < 1e-6)
        #expect(abs(longitude - (179 + 300 - 360)) < 0.01)
        #expect(steps.filter { $0.seconds == 0 }.count == 1)
        // Right at the antimeridian, it starts by jumping across.
        let edge = MapKitCamera.spin(fromLongitude: 180, degreesPerSecond: 10, seconds: 1)
        #expect(edge.first?.seconds == 0 && edge.count == 2 && abs((edge.last?.longitude ?? 0) - 169.999) < 1e-9)
    }

    @Test func noSpinFromBrokenNumbers() {
        #expect(MapKitCamera.spin(fromLongitude: .nan).isEmpty)
        #expect(MapKitCamera.spin(fromLongitude: 0, degreesPerSecond: 0).isEmpty)
        #expect(MapKitCamera.spin(fromLongitude: 0, degreesPerSecond: .infinity).isEmpty)
        #expect(MapKitCamera.spin(fromLongitude: 0, seconds: 0).isEmpty)
        #expect(MapKitCamera.spin(fromLongitude: 0, seconds: -1).isEmpty)
        #expect(MapKitCamera.spin(fromLongitude: 0, stepSeconds: .nan).isEmpty)
        // A step longer than the spin: one step.
        #expect(MapKitCamera.spin(fromLongitude: 0, seconds: 1, stepSeconds: 5) == [MapKitCamera.SpinStep(longitude: -10, seconds: 1)])
    }
}
