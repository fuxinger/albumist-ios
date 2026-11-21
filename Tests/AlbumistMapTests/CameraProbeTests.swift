import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The camera probe of the prototype page (`CameraProbe`): its cameras are the fourth web draft's
/// heights over Iceland, and its words say what was asked, what MapKit gave back and when the map
/// was ready, for the page and the clipboard.
@Suite("Camera probe")
struct CameraProbeTests {
    @Test func theShotsAreTheDraftsHeightsOverIceland() {
        let shots = CameraProbe.shots
        #expect(shots.count == 6)
        for shot in shots {
            #expect(shot.distanceMeters >= 15_000 && shot.distanceMeters <= 190_000, "\(shot.place)")
            #expect(shot.elevationDegrees >= 17 && shot.elevationDegrees <= 40, "\(shot.place)")
            #expect(shot.pitchDegrees == 90 - shot.elevationDegrees)
            #expect(shot.headingDegrees >= 0 && shot.headingDegrees < 360)
            #expect(shot.center.latitude > 63 && shot.center.latitude < 67, "\(shot.place)")
            #expect(shot.center.longitude > -25 && shot.center.longitude < -13, "\(shot.place)")
            #expect(!shot.place.isEmpty && !shot.purpose.isEmpty)
        }
        // The draft's low view, its typical flight and its highest camera, and the third draft's
        // angle at the same place for comparison.
        #expect(shots.contains { $0.distanceMeters == 15_000 && $0.elevationDegrees == 17 })
        #expect(shots.contains { $0.distanceMeters == 54_000 && $0.elevationDegrees == 28 })
        #expect(shots.contains { $0.distanceMeters == 190_000 && $0.elevationDegrees == 29 })
        let typical = shots.first { $0.elevationDegrees == 28 }, third = shots.first { $0.elevationDegrees == 40 }
        #expect(typical?.center == third?.center && typical?.distanceMeters == third?.distanceMeters)
        #expect(Set(shots).count == shots.count)
    }

    @Test func theCameraIsTheShotInMapKitsTerms() {
        let shot = CameraProbe.shots[1]
        let camera = shot.camera
        #expect(camera.center == shot.center)
        #expect(camera.distanceMeters == 29_000)
        #expect(camera.pitchDegrees == 68)
        #expect(camera.headingDegrees == 10)
    }

    @Test func thePageSaysWhatWasAsked() {
        #expect(CameraProbe.title(index: 1) == "2 von 6 · Dettifoss · Anflug zum schönsten Ort")
        #expect(CameraProbe.asked(CameraProbe.shots[1]) == "Verlangt: 29 km weit, 22° über dem Horizont (Neigung 68°), Blick nach Norden")
        #expect(CameraProbe.asked(CameraProbe.shots[0]) == "Verlangt: 15 km weit, 17° über dem Horizont (Neigung 73°), Blick nach Nordwesten")
        #expect(CameraProbe.title(index: 6) == "" && CameraProbe.title(index: -1) == "")
    }

    @Test func thePageSaysWhatMapKitGaveBackAndWhatItChanged() {
        let shot = CameraProbe.shots[1]
        let kept = CameraProbeResult(distanceMeters: 29_000, pitchDegrees: 68, readySeconds: 2.43)
        #expect(CameraProbe.got(shot, kept) == "MapKit: 29,0 km, Neigung 68,0°")
        #expect(CameraProbe.readiness(kept) == "Karte fertig nach 2,4 s")
        // MapKit rounds a little: still kept.
        let rounded = CameraProbeResult(distanceMeters: 29_400, pitchDegrees: 67.6, readySeconds: 0.04)
        #expect(CameraProbe.keepsPitch(shot, rounded) && CameraProbe.keepsDistance(shot, rounded))
        #expect(CameraProbe.got(shot, rounded) == "MapKit: 29,4 km, Neigung 67,6°")
        // A flatter camera than asked, from farther away, and a map that did not load in time.
        let clamped = CameraProbeResult(distanceMeters: 31_500, pitchDegrees: 52.34, readySeconds: nil)
        #expect(!CameraProbe.keepsPitch(shot, clamped) && !CameraProbe.keepsDistance(shot, clamped))
        #expect(CameraProbe.got(shot, clamped) == "MapKit: 31,5 km, Neigung 52,3° · Neigung begrenzt · Abstand geändert")
        #expect(CameraProbe.readiness(clamped) == "Karte nach 12 s nicht ganz geladen")
        // Steeper than asked is a change, not a limit.
        let steeper = CameraProbeResult(distanceMeters: 29_000, pitchDegrees: 75, readySeconds: 1)
        #expect(CameraProbe.got(shot, steeper) == "MapKit: 29,0 km, Neigung 75,0° · Neigung geändert")
    }

    @Test func theClipboardHasALinePerShotWithTheDemoPlaceAndNumbersOnly() {
        let result = CameraProbeResult(distanceMeters: 29_000, pitchDegrees: 68, readySeconds: 2.43)
        #expect(CameraProbe.line(index: 1, result) == "2 Dettifoss, 29 km, 22°: MapKit 29,0 km, Neigung 68,0°, Karte fertig nach 2,4 s")
        #expect(CameraProbe.line(index: 4, nil) == "5 Mývatn, 135 km, 29°: noch nicht angesehen")
        #expect(CameraProbe.line(index: 9, result) == "")
        // No coordinate leaves the probe: the fixed demo place's name stands for it.
        for index in CameraProbe.shots.indices {
            let line = CameraProbe.line(index: index, result)
            let shot = CameraProbe.shots[index]
            #expect(!line.contains(String(format: "%.3f", shot.center.latitude)) && !line.contains("64,"), "\(line)")
        }
    }

    @Test func brokenNumbersAndHeadingsStayCalm() {
        let shot = CameraProbe.shots[2]
        let broken = CameraProbeResult(distanceMeters: .nan, pitchDegrees: .infinity, readySeconds: .nan)
        #expect(CameraProbe.got(shot, broken) == "MapKit: – km, Neigung –° · Neigung geändert · Abstand geändert")
        #expect(CameraProbe.readiness(broken) == "Karte fertig nach – s")
        #expect(CameraProbe.kilometers(1e300) == "– km" && CameraProbe.degrees(-.infinity) == "–°")
        #expect(CameraProbe.direction(.nan) == "Norden")
        #expect(CameraProbe.direction(1e300).isEmpty == false)
    }

    @Test func aHeadingIsTheNearestOfEightDirections() {
        let cases: [(Double, String)] = [
            (0, "Norden"), (10, "Norden"), (22, "Norden"), (23, "Nordosten"), (60, "Nordosten"), (80, "Osten"), (90, "Osten"),
            (135, "Südosten"), (180, "Süden"), (225, "Südwesten"), (270, "Westen"), (300, "Nordwesten"), (338, "Norden"),
            (360, "Norden"), (-45, "Nordwesten"), (-90, "Westen"), (725, "Norden"),
        ]
        for (heading, name) in cases {
            #expect(CameraProbe.direction(heading) == name, "\(heading)")
        }
    }
}
