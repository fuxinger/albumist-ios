import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The flight of the camera probe (`CameraProbe.flight`, `CameraProbeFlightRun`): the fourth web
/// draft's camera from Jökulsárlón to Dettifoss as MapKit takes it, what a run measures from
/// MapKit's rendering callbacks and the display link, and the words for the page and clipboard.
@Suite("Camera probe flight")
struct CameraProbeFlightTests {
    private let flight = CameraProbe.flight

    @Test func theFlightIsTheDraftsStretchFromJokulsarlonToDettifoss() throws {
        #expect(abs(flight.seconds - 10.39) < 1e-9)
        #expect(abs(flight.groundKm - 282.4) < 1e-9)
        #expect(zip(flight.keys, flight.keys.dropFirst()).allSatisfy { $0.seconds < $1.seconds && $0.routeKm <= $1.routeKm })
        let distances = flight.keys.map(\.distanceMeters), angles = flight.keys.map(\.elevationDegrees)
        let nearest = try #require(distances.min()), farthest = try #require(distances.max())
        #expect(nearest > 14_000 && farthest < 146_000)
        #expect(angles.min() == 17 && angles.max() == 29)
        // The camera climbs to 145 km within 3.5 s and comes back to 15 km: the stretch the review
        // asked to fly on the iPhone; the ground never runs faster than 100 km a second.
        let peak = try #require(flight.keys.first { $0.distanceMeters == farthest })
        #expect(peak.seconds <= 3.5)
        #expect(zip(flight.keys, flight.keys.dropFirst()).allSatisfy { ($1.routeKm - $0.routeKm) / ($1.seconds - $0.seconds) <= 100 })
        #expect(flight.waypoints.map(\.name) == ["Jökulsárlón", "Höfn", "Egilsstaðir", "Dettifoss"])
        #expect(flight.keys.first?.routeKm == flight.waypoints.first?.routeKm && flight.keys.last?.routeKm == flight.waypoints.last?.routeKm)
        #expect(flight.coveredFrom > 6 && flight.coveredUntil < flight.seconds)
    }

    @Test func theCameraLooksAtTheDotFromTheDraftsDistanceAngleAndHeading() {
        let start = flight.camera(at: 0)
        #expect(start.center == flight.waypoints[0].coordinate)
        #expect(start.distanceMeters == 14_630 && start.pitchDegrees == 73 && abs(start.headingDegrees - 41.6) < 1e-9)
        let top = flight.camera(at: 3.5)
        #expect(top.distanceMeters == 144_630 && top.pitchDegrees == 61)
        let end = flight.camera(at: flight.seconds)
        #expect(end.center == flight.waypoints[3].coordinate)
        #expect(end.distanceMeters == 14_600 && end.pitchDegrees == 73 && abs(end.headingDegrees - 209.1) < 1e-9)
        // Between two keys the distance changes by the same factor each second, the rest in a
        // straight line; headings are within 0° and 360°.
        let between = flight.camera(at: 0.125)
        #expect(abs(between.distanceMeters - (14_630.0 * 14_910).squareRoot()) < 1e-6)
        #expect(abs(between.pitchDegrees - 73) < 1e-9 && abs(between.headingDegrees - 42.1) < 1e-9)
        #expect(abs(flight.camera(at: 8.5).headingDegrees - 235.6) < 1e-9)
        for step in 0...1_040 {
            let heading = flight.camera(at: Double(step) / 100).headingDegrees
            #expect(heading >= 0 && heading < 360, "\(step)")
        }
        // Before the start, after the end and at no time: the first or the last camera.
        #expect(flight.camera(at: -5) == start && flight.camera(at: .nan) == start)
        #expect(flight.camera(at: 100) == end && flight.camera(at: .infinity) == end)
    }

    @Test func theDotRunsStraightFromPlaceToPlace() {
        let jokulsarlon = flight.waypoints[0].coordinate, hofn = flight.waypoints[1].coordinate
        #expect(flight.position(atKm: 425.4) == hofn)
        let share = (400 - 374.0) / (425.4 - 374.0)
        let point = flight.position(atKm: 400)
        #expect(abs(point.latitude - (jokulsarlon.latitude + (hofn.latitude - jokulsarlon.latitude) * share)) < 1e-12)
        #expect(abs(point.longitude - (jokulsarlon.longitude + (hofn.longitude - jokulsarlon.longitude) * share)) < 1e-12)
        #expect(flight.position(atKm: 0) == jokulsarlon && flight.position(atKm: 1e9) == flight.waypoints[3].coordinate)
        #expect(flight.position(atKm: .nan) == jokulsarlon)
    }

    @Test func thePhotoCoversTheMapAtDettifossOnly() {
        #expect(!flight.isCovered(at: 6) && flight.isCovered(at: 7) && flight.isCovered(at: 9.8) && !flight.isCovered(at: 9.89))
    }

    @Test func thePageSaysWhatTheFlightAsksAndHowFarItIs() {
        #expect(CameraProbe.flightAsked == "Verlangt: 10,4 s in echter Zeit, 282 km Weg, Abstand 15 bis 145 km, 17° bis 29° über dem Horizont")
        #expect(CameraProbe.flightProgress(seconds: 3.5) == "Flug: 3,5 von 10,4 s · 145 km weit")
        #expect(CameraProbe.flightProgress(seconds: 7) == "Flug: 7,0 von 10,4 s · 73 km weit · im Film unter dem Foto")
    }

    // MARK: A run

    /// A run as an iPhone would give it: the start map after 2.1 s, two renderings in flight (the
    /// second still going at the landing), 600 frames with two left out, the map whole 1.41 s
    /// after the landing.
    private func typicalRun() -> CameraProbeFlightRun {
        var run = CameraProbeFlightRun(shownAt: 100)
        run.renderingStarted(at: 100.05)
        #expect(!run.readyToTakeOff)
        run.renderingFinished(at: 102.1, fully: true)
        #expect(run.readyToTakeOff && abs((run.startReadySeconds ?? 0) - 2.1) < 1e-9)
        run.takeOff(at: 102.1)
        var time = 102.1
        for frame in 0..<600 {
            time += frame == 300 ? 3.0 / 60 : 1.0 / 60
            run.frame(at: time, expected: 1.0 / 60)
        }
        run.renderingStarted(at: 103)
        run.renderingFinished(at: 104.5, fully: true)
        run.renderingStarted(at: 110)
        run.land(at: 112.49)
        run.renderingFinished(at: 113.9, fully: true)
        run.settle(at: 114)
        #expect(run.phase == .landing)
        run.settle(at: 114.5)
        return run
    }

    @Test func aRunMeasuresTheStartTheFlightAndTheLanding() throws {
        let run = typicalRun()
        #expect(run.phase == .done)
        let result = try #require(run.result(network: .init(wifiBytes: 14_200_000), heat: .nominal))
        #expect(abs((result.startReadySeconds ?? 0) - 2.1) < 1e-9)
        #expect(abs(result.flownSeconds - 10.39) < 1e-9)
        #expect(abs(result.unfinishedSeconds - (1.5 + 2.49)) < 1e-9)
        #expect(result.frames == 600 && result.droppedFrames == 2)
        #expect(abs((result.landedReadySeconds ?? 0) - 1.41) < 1e-9)
        #expect(result.incompleteRenderings == 0)
        #expect(CameraProbe.flightGot(result) == "Karte nicht fertig 4,0 von 10,4 s · 58 Bilder je s, 2 ausgelassen")
        #expect(CameraProbe.flightReadiness(result)
                == "Start fertig nach 2,1 s · nach der Landung fertig nach 1,4 s · 14,2 MB über WLAN · Wärme normal")
    }

    @Test func aMapThatNeverLoadsStillFliesAndSaysSo() throws {
        var run = CameraProbeFlightRun(shownAt: 0)
        run.renderingStarted(at: 0.1)
        run.renderingFinished(at: 3, fully: false)
        #expect(!run.readyToTakeOff)
        run.takeOff(at: 12)
        run.renderingStarted(at: 12.5)
        run.renderingFinished(at: 14, fully: false)
        run.renderingStarted(at: 15)
        run.land(at: 22.39)
        run.settle(at: 30)
        #expect(run.phase == .landing)
        run.settle(at: 34.5)
        let result = try #require(run.result(network: .init(wifiBytes: 0, cellularBytes: 3_000_000), heat: .serious))
        #expect(result.startReadySeconds == nil && result.landedReadySeconds == nil)
        #expect(abs(result.unfinishedSeconds - (1.5 + 7.39)) < 1e-9)
        #expect(result.incompleteRenderings == 1)
        #expect(CameraProbe.flightGot(result) == "Karte nicht fertig 8,9 von 10,4 s · 1× nicht ganz geladen · 0 Bilder je s, 0 ausgelassen")
        #expect(CameraProbe.flightReadiness(result)
                == "Start nach 12 s nicht ganz geladen · nach der Landung nicht ganz geladen · 3,0 MB über Mobilfunk · Wärme ernst")
    }

    @Test func aMapAtRestAtTheLandingIsReadyAtOnce() throws {
        var run = CameraProbeFlightRun(shownAt: 0)
        run.renderingStarted(at: 0)
        run.renderingFinished(at: 1, fully: true)
        run.takeOff(at: 1)
        run.land(at: 11.39)
        run.settle(at: 11.6)
        #expect(run.phase == .landing && run.result(network: nil, heat: .nominal) == nil)
        run.settle(at: 11.95)
        let result = try #require(run.result(network: nil, heat: .fair))
        #expect(result.landedReadySeconds == 0 && result.unfinishedSeconds == 0)
        #expect(CameraProbe.flightReadiness(result).hasSuffix("nach der Landung fertig nach 0,0 s · Datenmenge unbekannt · Wärme erhöht"))
    }

    @Test func aRunTakesItsStepsInOrderOnly() {
        var run = CameraProbeFlightRun(shownAt: 5)
        // A rendering that finished but never started after the camera was set is the one before.
        run.renderingFinished(at: 5.2, fully: true)
        #expect(!run.readyToTakeOff)
        run.frame(at: 5.3, expected: 1.0 / 60)
        run.land(at: 5.4)
        run.settle(at: 30)
        #expect(run.phase == .starting && run.frames == 0)
        run.takeOff(at: 6)
        run.takeOff(at: 7)
        #expect(run.flown(at: 8) == 2)
        run.land(at: 9)
        run.frame(at: 9.5, expected: 1.0 / 60)
        #expect(run.frames == 0 && run.flown(at: 20) == 3)
    }

    @Test func networkWordsNameTheLargerNetwork() {
        #expect(CameraProbe.megabytes(nil) == "Datenmenge unbekannt")
        #expect(CameraProbe.megabytes(.init()) == "0,0 MB")
        #expect(CameraProbe.megabytes(.init(wifiBytes: 1_000_000, cellularBytes: 2_500_000)) == "3,5 MB über Mobilfunk")
        #expect(CameraProbe.megabytes(.init(wifiBytes: 2_000_000, cellularBytes: 2_000_000)) == "4,0 MB über WLAN")
    }

    @Test func theClipboardHasALinePerFlight() throws {
        let result = try #require(typicalRun().result(network: .init(wifiBytes: 14_200_000), heat: .nominal))
        #expect(CameraProbe.flightLines([]) == ["1 Flug Jökulsárlón bis Dettifoss: noch nicht geflogen"])
        let lines = CameraProbe.flightLines([result, result])
        #expect(lines.count == 2)
        #expect(lines[0] == "1 Flug Jökulsárlón bis Dettifoss, Lauf 1: Start fertig nach 2,1 s, nach der Landung fertig nach 1,4 s, "
                + "14,2 MB über WLAN, Wärme normal, Karte nicht fertig 4,0 von 10,4 s, 58 Bilder je s, 2 ausgelassen")
        #expect(lines[1].hasPrefix("1 Flug Jökulsárlón bis Dettifoss, Lauf 2: "))
        let text = CameraProbe.clipboard(device: "iPhone17,1 · iOS 27.1", stills: [:], flights: [result])
        #expect(text.components(separatedBy: "\n")[1] == lines[0])
    }
}
