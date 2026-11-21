import Foundation
import AlbumistCore

/// One still camera of the probe (`CameraProbe`): a fixed demo place, what the camera stands for
/// in the film, and the camera in the web draft's own measure: the distance from the camera to the
/// place it looks at (the draft's D) and the angle above the horizon (its E). MapKit counts its
/// pitch from looking straight down, so the pitch is 90° minus that angle.
public struct CameraProbeShot: Hashable, Sendable {
    public var place: String
    public var purpose: String
    public var center: GeoCoordinate
    public var distanceMeters: Double
    public var elevationDegrees: Double
    /// Degrees clockwise from north the camera faces.
    public var headingDegrees: Double

    /// MapKit's pitch: degrees from looking straight down.
    public var pitchDegrees: Double { 90 - elevationDegrees }

    /// The camera as `MKMapCamera(lookingAtCenter:fromDistance:pitch:heading:)` takes it.
    public var camera: PlaybackCamera {
        PlaybackCamera(center: center, distanceMeters: distanceMeters, pitchDegrees: pitchDegrees, headingDegrees: headingDegrees)
    }
}

/// What MapKit made of a still camera: its camera once the map had rendered (or once the wait ran
/// out), and how long the map took.
public struct CameraProbeResult: Hashable, Sendable {
    public var distanceMeters: Double
    public var pitchDegrees: Double
    /// From setting the camera to the first fully rendered map; `nil` when `CameraProbe.waitSeconds`
    /// ran out first.
    public var readySeconds: Double?

    public init(distanceMeters: Double, pitchDegrees: Double, readySeconds: Double?) {
        self.distanceMeters = distanceMeters
        self.pitchDegrees = pitchDegrees
        self.readySeconds = readySeconds
    }
}

/// One step of the probe: the flight (`CameraProbe.flight`) or a still camera.
public enum CameraProbeStep: Hashable, Sendable {
    case flight
    case still(CameraProbeShot)
}

/// The camera probe of the prototype page (concept 2.0 §13, wave 0) for "Reise abspielen" in the
/// fourth web draft. Its second review (Fable, 21.11.) asked to settle on an iPhone, before a fifth
/// draft, what Apple's 3D satellite map does at the film's heights: the tilt it allows at each
/// distance, whether it loads in time while the camera climbs and falls, whether the low view
/// after a photo is a picture, and how a city looks from 300 m. So the probe first flies one
/// stretch of the draft in real time (Jökulsárlón to Dettifoss, `CameraProbe.flight`), then sets
/// still cameras one after another: the four low holds, the draft's heights, the steepest tilt at
/// five distances, and Rome. Fixed demo places only, no photo and no place of the user; the words
/// for the page and the clipboard are made and tested here, the app sets the cameras and reads
/// back what MapKit made of them.
public enum CameraProbe {
    /// The still cameras, in the order the page shows them after the flight.
    public static let shots: [CameraProbeShot] = lowHolds + flightHeights + steepest + city

    /// Every step of the page: the flight first, while Apple's map has loaded nothing of its way
    /// yet (a second flight runs over a warm map), then the still cameras.
    public static var steps: [CameraProbeStep] { [.flight] + shots.map(CameraProbeStep.still) }

    /// After each photo the draft holds the camera 15 km away and 17° above the horizon, facing
    /// the way on, at its four stops (headings as the draft's camera has them then).
    static let lowHolds: [CameraProbeShot] = [
        still(Spot.reykjavik, "tiefer Halt nach dem Foto", 15_000, 17, 55),
        still(Spot.seljalandsfoss, "tiefer Halt nach dem Foto", 15_000, 17, 90),
        still(Spot.jokulsarlon, "tiefer Halt nach dem Foto", 15_000, 17, 40),
        still(Spot.dettifoss, "tiefer Halt nach dem Foto", 15_000, 17, 210),
    ]

    /// The draft's camera in flight, where it is (390 × 844, film seconds): the way down to the
    /// trip's best place (26.9 s), the middle of the flight at the draft's median 54 km and 28°
    /// (22.6 s), the same at the third draft's 40° for comparison, high over the long leg to
    /// Egilsstaðir (36.9 s) and the highest of the film (50.0 s), both at 29°.
    static let flightHeights: [CameraProbeShot] = [
        still(Spot.jokulsarlon, "Anflug zum Höhepunkt", 30_000, 21, 71),
        still(Spot.myrdalssandur, "mitten im Flug", 54_000, 28, 86),
        still(Spot.myrdalssandur, "wie Entwurf 3, zum Vergleich", 54_000, 40, 86),
        still(Spot.beforeEgilsstadir, "hoch über einer langen Strecke", 145_000, 29, 21),
        still(Spot.northWest, "am höchsten", 163_000, 29, 239),
    ]

    /// The steepest camera the draft asks for (17° above the horizon, pitch 73°) at five distances,
    /// over the middle of the flight: what MapKit gives back is the tilt it allows there.
    static let steepest: [CameraProbeShot] = [15_000.0, 30_000, 60_000, 100_000, 160_000].map {
        still(Spot.myrdalssandur, "Neigung je Abstand", $0, 17, 86)
    }

    /// A city trip (the draft's Rome, 0.3 to 2.8 km): low after a photo and in flight.
    static let city: [CameraProbeShot] = [
        still(Spot.colosseum, "Stadt, tiefer Halt", 300, 17, 300),
        still(Spot.colosseum, "Stadt, im Flug", 2_800, 28, 300),
    ]

    /// How long the page waits for a fully rendered map before it says the map did not load.
    public static let waitSeconds = 12.0
    /// MapKit keeps the pitch when it gives back within this many degrees,
    public static let pitchToleranceDegrees = 0.5
    /// and the distance within this share of it.
    public static let distanceTolerance = 0.02

    /// "2 von 17 · Reykjavík · tiefer Halt nach dem Foto"; "" for an index that is not a step.
    public static func title(index: Int) -> String {
        let steps = steps
        guard steps.indices.contains(index) else { return "" }
        let head = "\(index + 1) von \(steps.count) · "
        switch steps[index] {
        case .flight: return head + "\(flight.from) bis \(flight.to) · \(flight.purpose)"
        case .still(let shot): return head + "\(shot.place) · \(shot.purpose)"
        }
    }

    /// "Verlangt: 15 km weit, 17° über dem Horizont (Neigung 73°), Blick nach Nordosten".
    public static func asked(_ shot: CameraProbeShot) -> String {
        "Verlangt: \(kilometers(shot.distanceMeters)) weit, \(degrees(shot.elevationDegrees)) über dem Horizont "
            + "(Neigung \(degrees(shot.pitchDegrees))), Blick nach \(direction(shot.headingDegrees))"
    }

    /// "MapKit: 15,0 km, Neigung 73,0°", and what MapKit changed: "· Neigung begrenzt" (flatter
    /// than asked), "· Neigung geändert" (steeper), "· Abstand geändert".
    public static func got(_ shot: CameraProbeShot, _ result: CameraProbeResult) -> String {
        var text = "MapKit: \(decimal(result.distanceMeters / 1_000)) km, Neigung \(decimal(result.pitchDegrees))°"
        if !keepsPitch(shot, result) {
            text += result.pitchDegrees < shot.pitchDegrees ? " · Neigung begrenzt" : " · Neigung geändert"
        }
        if !keepsDistance(shot, result) { text += " · Abstand geändert" }
        return text
    }

    /// "Karte fertig nach 2,4 s", or "Karte nach 12 s nicht ganz geladen".
    public static func readiness(_ result: CameraProbeResult) -> String {
        guard let seconds = result.readySeconds else { return "Karte nach \(Int(waitSeconds)) s nicht ganz geladen" }
        return "Karte fertig nach \(decimal(seconds)) s"
    }

    /// One line of the clipboard for a still camera: "2 Reykjavík, 15 km, 17°: MapKit 15,0 km,
    /// Neigung 73,0°, Karte fertig nach 2,4 s"; one not looked at yet says "noch nicht angesehen".
    /// "" for the flight's index or one that is not a step (the flight has `flightLines`).
    public static func line(index: Int, _ result: CameraProbeResult?) -> String {
        let steps = steps
        guard steps.indices.contains(index), case .still(let shot) = steps[index] else { return "" }
        let head = "\(index + 1) \(shot.place), \(kilometers(shot.distanceMeters)), \(degrees(shot.elevationDegrees))"
        guard let result else { return "\(head): noch nicht angesehen" }
        let got = got(shot, result).replacingOccurrences(of: "MapKit: ", with: "MapKit ")
        return "\(head): \(got), \(readiness(result))"
    }

    /// What "Werte kopieren" puts on the clipboard: a head with the iPhone's model and system,
    /// a line for each flight flown (or one saying none was), and a line for each still camera.
    public static func clipboard(device: String, stills: [Int: CameraProbeResult], flights: [CameraProbeFlightResult]) -> String {
        let head = "Kamera-Probe (Reise abspielen, Entwurf 4) · " + device
        let stillLines = steps.indices.compactMap { index -> String? in
            guard case .still = steps[index] else { return nil }
            return line(index: index, stills[index])
        }
        return ([head] + flightLines(flights) + stillLines).joined(separator: "\n")
    }

    public static func keepsPitch(_ shot: CameraProbeShot, _ result: CameraProbeResult) -> Bool {
        abs(result.pitchDegrees - shot.pitchDegrees) <= pitchToleranceDegrees
    }

    public static func keepsDistance(_ shot: CameraProbeShot, _ result: CameraProbeResult) -> Bool {
        abs(result.distanceMeters - shot.distanceMeters) <= distanceTolerance * shot.distanceMeters
    }

    /// A demo place of the probe and the point its cameras look at: the draft's places, three
    /// points on its route (the camera's centre at the film second named in `flightHeights`), and
    /// the Colosseum.
    struct Spot {
        let name: String
        let center: GeoCoordinate

        static let reykjavik = Spot("Reykjavík", 64.1466, -21.9426)
        static let seljalandsfoss = Spot("Seljalandsfoss", 63.6156, -19.9886)
        static let jokulsarlon = Spot("Jökulsárlón", 64.0485, -16.1806)
        static let dettifoss = Spot("Dettifoss", 65.8146, -16.3846)
        static let myrdalssandur = Spot("Mýrdalssandur", 63.4421, -18.9260)
        static let beforeEgilsstadir = Spot("vor Egilsstaðir", 65.0746, -14.5482)
        static let northWest = Spot("zwischen Akureyri und Borgarnes", 64.9683, -20.4960)
        static let colosseum = Spot("Rom, Kolosseum", 41.8902, 12.4922)

        init(_ name: String, _ latitude: Double, _ longitude: Double) {
            self.name = name
            self.center = GeoCoordinate(latitude: latitude, longitude: longitude)
        }
    }

    private static func still(_ spot: Spot, _ purpose: String, _ meters: Double, _ elevation: Double, _ heading: Double) -> CameraProbeShot {
        CameraProbeShot(place: spot.name, purpose: purpose, center: spot.center, distanceMeters: meters, elevationDegrees: elevation,
                        headingDegrees: heading)
    }

    // MARK: Words and numbers

    static let directions = ["Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten"]

    /// The nearest of the eight directions to a heading ("Norden" for 10°).
    static func direction(_ heading: Double) -> String {
        guard heading.isFinite else { return directions[0] }
        let eighth = Int((heading.truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return directions[(eighth + 8) % 8]
    }

    /// "29 km": whole kilometres from 10 km on, below that one decimal ("2,8 km", "0,3 km").
    static func kilometers(_ meters: Double) -> String {
        guard meters.isFinite, abs(meters) < 1e15 else { return "– km" }
        let km = meters / 1_000
        return abs(km) < 9.95 ? "\(decimal(km)) km" : "\(Int(km.rounded())) km"
    }

    /// "22°": whole degrees.
    static func degrees(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e15 else { return "–°" }
        return "\(Int(value.rounded()))°"
    }

    /// "29,0": one decimal with a German comma; "–" for a broken number.
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "–" }
        return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}
