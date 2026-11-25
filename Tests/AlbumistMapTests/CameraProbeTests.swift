import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// The camera probe of the prototype page (`CameraProbe`): its still cameras are the fourth web
/// draft's low holds, heights and steepest tilt over Iceland and its Rome, and its words say what
/// was asked, what MapKit gave back and when the map was ready, for the page and the clipboard.
/// The flight is in CameraProbeFlightTests.
@Suite("Camera probe")
struct CameraProbeTests {
    @Test func theStepsAreTheFlightThenTheStillCameras() {
        let steps = CameraProbe.steps
        #expect(steps.count == 17)
        #expect(steps.first == .flight)
        #expect(Array(steps.dropFirst()) == CameraProbe.shots.map(CameraProbeStep.still))
        #expect(steps.filter { $0 == .flight }.count == 1)
    }

    @Test func theStillCamerasAreTheDraftsOverIcelandAndRome() {
        let shots = CameraProbe.shots
        #expect(shots.count == 16)
        for shot in shots {
            #expect(shot.distanceMeters >= 300 && shot.distanceMeters <= 163_000, "\(shot.place)")
            #expect(shot.elevationDegrees >= 17 && shot.elevationDegrees <= 40, "\(shot.place)")
            #expect(shot.pitchDegrees == 90 - shot.elevationDegrees)
            #expect(shot.headingDegrees >= 0 && shot.headingDegrees < 360)
            let iceland = shot.center.latitude > 63 && shot.center.latitude < 67 && shot.center.longitude > -25 && shot.center.longitude < -13
            let rome = abs(shot.center.latitude - 41.89) < 0.01 && abs(shot.center.longitude - 12.49) < 0.01
            #expect(iceland || rome, "\(shot.place)")
            #expect(!shot.place.isEmpty && !shot.purpose.isEmpty)
        }
        #expect(Set(shots).count == shots.count)
        // The four low holds after a photo: 15 km, 17°, at the draft's four stops.
        let holds = shots.filter { $0.purpose == "tiefer Halt nach dem Foto" }
        #expect(holds.map(\.place) == ["Reykjavík", "Seljalandsfoss", "Jökulsárlón", "Dettifoss"])
        #expect(holds.allSatisfy { $0.distanceMeters == 15_000 && $0.elevationDegrees == 17 })
        // The draft's median flight and the third draft's angle at the same place, its highest
        // camera, and the steepest tilt at five distances over that place.
        let middle = shots.first { $0.purpose == "mitten im Flug" }, third = shots.first { $0.purpose.hasPrefix("wie Entwurf 3") }
        #expect(middle?.distanceMeters == 54_000 && middle?.elevationDegrees == 28 && third?.elevationDegrees == 40)
        #expect(middle?.center == third?.center && middle?.headingDegrees == third?.headingDegrees)
        #expect(shots.map(\.distanceMeters).max() == 163_000)
        let steepest = shots.filter { $0.purpose == "Neigung je Abstand" }
        #expect(steepest.map(\.distanceMeters) == [15_000, 30_000, 60_000, 100_000, 160_000])
        #expect(steepest.allSatisfy { $0.pitchDegrees == 73 && $0.center == middle?.center })
        // Rome from 300 m and 2.8 km, the draft's range for a city trip.
        #expect(shots.filter { $0.place == "Rom, Kolosseum" }.map(\.distanceMeters) == [300, 2_800])
    }

    @Test func theCameraIsTheShotInMapKitsTerms() {
        let shot = CameraProbe.shots[4]
        #expect(shot.place == "Jökulsárlón" && shot.purpose == "Anflug zum Höhepunkt")
        let camera = shot.camera
        #expect(camera.center == shot.center)
        #expect(camera.distanceMeters == 30_000)
        #expect(camera.pitchDegrees == 69)
        #expect(camera.headingDegrees == 71)
    }

    @Test func thePageSaysWhatWasAsked() {
        #expect(CameraProbe.title(index: 0) == "1 von 17 · Jökulsárlón bis Dettifoss · Flug wie im Film (33 bis 44 s)")
        #expect(CameraProbe.title(index: 1) == "2 von 17 · Reykjavík · tiefer Halt nach dem Foto")
        #expect(CameraProbe.title(index: 16) == "17 von 17 · Rom, Kolosseum · Stadt, im Flug")
        #expect(CameraProbe.title(index: 17) == "" && CameraProbe.title(index: -1) == "")
        let shots = CameraProbe.shots
        #expect(CameraProbe.asked(shots[0]) == "Verlangt: 15 km weit, 17° über dem Horizont (Neigung 73°), Blick nach Nordosten")
        #expect(CameraProbe.asked(shots[3]) == "Verlangt: 15 km weit, 17° über dem Horizont (Neigung 73°), Blick nach Südwesten")
        #expect(CameraProbe.asked(shots[14]) == "Verlangt: 0,3 km weit, 17° über dem Horizont (Neigung 73°), Blick nach Nordwesten")
        #expect(CameraProbe.asked(shots[15]) == "Verlangt: 2,8 km weit, 28° über dem Horizont (Neigung 62°), Blick nach Nordwesten")
    }

    @Test func distancesAreWholeKilometresFromTenOnAndOneDecimalBelow() {
        #expect(CameraProbe.kilometers(163_000) == "163 km")
        #expect(CameraProbe.kilometers(15_000) == "15 km" && CameraProbe.kilometers(14_550) == "15 km")
        #expect(CameraProbe.kilometers(9_960) == "10 km" && CameraProbe.kilometers(9_940) == "9,9 km")
        #expect(CameraProbe.kilometers(2_800) == "2,8 km" && CameraProbe.kilometers(300) == "0,3 km")
    }

    @Test func thePageSaysWhatMapKitGaveBackAndWhatItChanged() {
        let shot = CameraProbe.shots[4]
        let kept = CameraProbeResult(distanceMeters: 30_000, pitchDegrees: 69, readySeconds: 2.43)
        #expect(CameraProbe.got(shot, kept) == "MapKit: 30,0 km, Neigung 69,0°")
        #expect(CameraProbe.readiness(kept) == "Karte fertig nach 2,4 s")
        // MapKit rounds a little: still kept.
        let rounded = CameraProbeResult(distanceMeters: 30_400, pitchDegrees: 68.6, readySeconds: 0.04)
        #expect(CameraProbe.keepsPitch(shot, rounded) && CameraProbe.keepsDistance(shot, rounded))
        #expect(CameraProbe.got(shot, rounded) == "MapKit: 30,4 km, Neigung 68,6°")
        // A flatter camera than asked, from farther away, and a map that did not load in time.
        let clamped = CameraProbeResult(distanceMeters: 32_500, pitchDegrees: 52.34, readySeconds: nil)
        #expect(!CameraProbe.keepsPitch(shot, clamped) && !CameraProbe.keepsDistance(shot, clamped))
        #expect(CameraProbe.got(shot, clamped) == "MapKit: 32,5 km, Neigung 52,3° · Neigung begrenzt · Abstand geändert")
        #expect(CameraProbe.readiness(clamped) == "Karte nach 12 s nicht ganz geladen")
        // Steeper than asked is a change, not a limit.
        let steeper = CameraProbeResult(distanceMeters: 30_000, pitchDegrees: 75, readySeconds: 1)
        #expect(CameraProbe.got(shot, steeper) == "MapKit: 30,0 km, Neigung 75,0° · Neigung geändert")
    }

    @Test func theClipboardHasTheDeviceAFlightLineAndALinePerStillWithNumbersOnly() {
        let result = CameraProbeResult(distanceMeters: 15_000, pitchDegrees: 73, readySeconds: 2.43)
        #expect(CameraProbe.line(index: 1, result) == "2 Reykjavík, 15 km, 17°: MapKit 15,0 km, Neigung 73,0°, Karte fertig nach 2,4 s")
        #expect(CameraProbe.line(index: 15, nil) == "16 Rom, Kolosseum, 0,3 km, 17°: noch nicht angesehen")
        #expect(CameraProbe.line(index: 0, result) == "" && CameraProbe.line(index: 17, result) == "")
        let text = CameraProbe.clipboard(device: "iPhone17,1 · iOS 27.1", stills: [1: result], flights: [])
        let lines = text.components(separatedBy: "\n")
        #expect(lines.count == 18)
        #expect(lines[0] == "Kamera-Probe (Reise abspielen, Entwurf 4) · iPhone17,1 · iOS 27.1")
        #expect(lines[1] == "1 Flug Jökulsárlón bis Dettifoss: noch nicht geflogen")
        #expect(lines[2] == CameraProbe.line(index: 1, result))
        #expect(lines[17] == "17 Rom, Kolosseum, 2,8 km, 28°: noch nicht angesehen")
        // No coordinate leaves the probe: the fixed demo places' names stand for them.
        let everything = CameraProbe.clipboard(device: "iPhone", stills: Dictionary(uniqueKeysWithValues: (1...16).map { ($0, result) }),
                                               flights: [])
        for shot in CameraProbe.shots {
            for format in ["%.2f", "%.3f", "%.4f"] {
                let latitude = String(format: format, shot.center.latitude)
                #expect(!everything.contains(latitude) && !everything.contains(latitude.replacingOccurrences(of: ".", with: ",")))
            }
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
