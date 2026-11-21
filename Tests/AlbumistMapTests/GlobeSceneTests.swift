import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// What a globe shows and where it looks (`GlobeScene`, `GlobeCamera`): the same scene for our
/// globe, Apple's globe and the map after the handover, and the prototype's demo load.
@Suite("Globe scene and camera")
struct GlobeSceneTests {
    @Test func theDemoIsThePrototypesLoad() {
        let scene = GlobeScene.demo()
        #expect(scene.arcs.count == 150)
        #expect(scene.pins.filter { $0.level == .trip }.count == 60)
        #expect(Set(scene.arcs.map(\.id)).count == scene.arcs.count)
        #expect(Set(scene.pins.map(\.id)).count == scene.pins.count)
        // Every arc starts at a rounded home, never an exact one.
        for arc in scene.arcs { #expect(MapHome.rounded(arc.from) == arc.from) }
        #expect(scene.home.map { MapHome.rounded($0.coordinate) == $0.coordinate } ?? false)
        // Country and region pins above the trips, each country pin counting its trips.
        let countryPins = scene.pins.filter { $0.level == .country }
        #expect(!countryPins.isEmpty && scene.pins.contains { $0.level == .worldRegion })
        #expect(countryPins.reduce(0) { $0 + $1.count } == 60)
        #expect(Set(countryPins.compactMap(\.countryKey)) == scene.visitedCountryCodes)
        // The same scene every time (measurements on two iPhones compare).
        #expect(GlobeScene.demo() == scene)
        #expect(GlobeScene.demo(arcCount: 10, pinCount: 5).arcs.count == 10)
        #expect(GlobeScene.demo(arcCount: 0, pinCount: 0).pins.isEmpty)
        // At the whole Earth the demo shows at most the visible limit of pins.
        let groups = MapPins.visible(scene.pins, in: GlobeCamera.wholeEarth.viewport(widthPoints: 390, heightPoints: 844))
        #expect(!groups.isEmpty && groups.count <= MapSummary.maxVisiblePins)
    }

    @Test func theFirstCameraShowsTheFocusOrTheWholeEarth() {
        #expect(GlobeScene.demo().firstCamera == .wholeEarth)
        let near = GlobeCamera.showing(MapFocus(center: GeoCoordinate(latitude: 64, longitude: -19), radiusMeters: 300_000))
        #expect(near.center == GeoCoordinate(latitude: 64, longitude: -19))
        // A small start comes close, but never past the handover to Apple's map ...
        #expect(near.widthMeters == GlobeCamera.handoverWidthMeters && !near.isHandedOver)
        // ... and a wide one never past the whole Earth.
        let wide = GlobeCamera.showing(MapFocus(center: GeoCoordinate(latitude: 0, longitude: 0.5), radiusMeters: 15_000_000))
        #expect(wide.widthMeters == GlobeCamera.wholeEarth.widthMeters)
        let middle = GlobeCamera.showing(MapFocus(center: GeoCoordinate(latitude: 45, longitude: 10), radiusMeters: 2_000_000))
        #expect(abs(middle.widthMeters - 5_000_000) < 1)
        for broken in [MapFocus(center: GeoCoordinate(latitude: .nan, longitude: 0), radiusMeters: 1_000_000),
                       MapFocus(center: GeoCoordinate(latitude: 10, longitude: 10), radiusMeters: .infinity),
                       MapFocus(center: GeoCoordinate(latitude: 10, longitude: 10), radiusMeters: 0)] {
            #expect(GlobeCamera.showing(broken) == .wholeEarth)
        }
    }

    @Test func aCameraIsKeptInRange() {
        let wild = GlobeCamera(center: GeoCoordinate(latitude: 120, longitude: 540), widthMeters: 1e12).clamped
        #expect(wild.center.latitude == 90 && wild.center.longitude == -180)  // [-180, 180)
        #expect(wild.widthMeters == GlobeCamera.maximumWidthMeters)
        let close = GlobeCamera(center: GeoCoordinate(latitude: -10, longitude: -190), widthMeters: 1).clamped
        #expect(close.center.longitude == 170 && close.widthMeters == GlobeCamera.minimumWidthMeters && close.isHandedOver)
        let broken = GlobeCamera(center: GeoCoordinate(latitude: .nan, longitude: .infinity), widthMeters: .nan).clamped
        #expect(broken.center == GeoCoordinate(latitude: 0, longitude: 0) && broken.widthMeters == GlobeCamera.wholeEarth.widthMeters)
        // The handover's width is the house's upper limit.
        #expect(GlobeCamera.handoverWidthMeters == MapHome.houseMaximumWidthMeters)
        #expect(GlobeCamera(center: GeoCoordinate(latitude: 0, longitude: 0), widthMeters: 2_999_999).isHandedOver)
        #expect(!GlobeCamera(center: GeoCoordinate(latitude: 0, longitude: 0), widthMeters: 3_000_000).isHandedOver)
    }

    @Test func aSummarysSceneIsTheSummary() {
        let demo = GlobeScene.demo()
        let summary = MapSummary(computedAt: Date(timeIntervalSince1970: 0), home: demo.home, trips: [], countries: demo.countries,
                                 arcs: demo.arcs, pins: demo.pins, numbers: WorldNumbers(year: 2026), years: [], focus: MapFocus(center: GeoCoordinate(latitude: 48, longitude: 11), radiusMeters: 900_000))
        let scene = GlobeScene(summary: summary)
        #expect(scene.arcs == summary.arcs && scene.pins == summary.pins && scene.countries == summary.countries)
        #expect(scene.home == summary.home && scene.focus == summary.focus && scene.trips.isEmpty)
        #expect(scene.firstCamera.center == GeoCoordinate(latitude: 48, longitude: 11))
    }
}
