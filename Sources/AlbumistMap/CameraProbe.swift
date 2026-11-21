import Foundation
import AlbumistCore

/// One camera of the probe (`CameraProbe`): a place of the demo trip, what the camera stands for
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

/// What MapKit made of a shot: its camera once the map had rendered (or once the wait ran out),
/// and how long the map took.
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

/// The camera probe of the prototype page (concept 2.0 §13, wave 0) for the heights of "Reise
/// abspielen" in the fourth web draft: does Apple's 3D satellite map keep the angle and the
/// distance the film flies at, how does the map look there, and how long until it is sharp? The
/// review of the third draft asked for this on an iPhone before more polish ("it decides whether
/// the film has a look"). Six fixed cameras over Iceland, no photo and no place of the user; the
/// words for the page and the clipboard are made and tested here, the app only sets each camera
/// and reads back what MapKit made of it.
public enum CameraProbe {
    /// The draft's heights, measured at 390 × 844: low after a photo (15 km, 17°), the way down to
    /// the trip's best place (29 km, 22°), the middle of the flight (54 km, 28°) and the same at the
    /// third draft's 40° for comparison, high over a long leg (135 km) and the highest (190 km),
    /// both at 29°. Each looks the way the film would fly there.
    public static let shots: [CameraProbeShot] = [
        CameraProbeShot(place: "Jökulsárlón", purpose: "tief nach einem Foto", center: GeoCoordinate(latitude: 64.048, longitude: -16.179),
                        distanceMeters: 15_000, elevationDegrees: 17, headingDegrees: 300),
        CameraProbeShot(place: "Dettifoss", purpose: "Anflug zum schönsten Ort", center: GeoCoordinate(latitude: 65.814, longitude: -16.385),
                        distanceMeters: 29_000, elevationDegrees: 22, headingDegrees: 10),
        CameraProbeShot(place: "Kirkjubæjarklaustur", purpose: "mitten im Flug", center: GeoCoordinate(latitude: 63.790, longitude: -18.050),
                        distanceMeters: 54_000, elevationDegrees: 28, headingDegrees: 80),
        CameraProbeShot(place: "Kirkjubæjarklaustur", purpose: "wie Entwurf 3, zum Vergleich", center: GeoCoordinate(latitude: 63.790, longitude: -18.050),
                        distanceMeters: 54_000, elevationDegrees: 40, headingDegrees: 80),
        CameraProbeShot(place: "Mývatn", purpose: "hoch über einer langen Strecke", center: GeoCoordinate(latitude: 65.604, longitude: -16.996),
                        distanceMeters: 135_000, elevationDegrees: 29, headingDegrees: 90),
        CameraProbeShot(place: "Hochland", purpose: "am höchsten", center: GeoCoordinate(latitude: 64.900, longitude: -18.600),
                        distanceMeters: 190_000, elevationDegrees: 29, headingDegrees: 60),
    ]

    /// How long the page waits for a fully rendered map before it says the map did not load.
    public static let waitSeconds = 12.0
    /// MapKit keeps the pitch when it gives back within this many degrees,
    public static let pitchToleranceDegrees = 0.5
    /// and the distance within this share of it.
    public static let distanceTolerance = 0.02

    /// "2 von 6 · Dettifoss · Anflug zum schönsten Ort"; "" for an index that is not a shot.
    public static func title(index: Int) -> String {
        guard shots.indices.contains(index) else { return "" }
        let shot = shots[index]
        return "\(index + 1) von \(shots.count) · \(shot.place) · \(shot.purpose)"
    }

    /// "Verlangt: 29 km weit, 22° über dem Horizont (Neigung 68°), Blick nach Norden".
    public static func asked(_ shot: CameraProbeShot) -> String {
        "Verlangt: \(kilometers(shot.distanceMeters)) weit, \(degrees(shot.elevationDegrees)) über dem Horizont "
            + "(Neigung \(degrees(shot.pitchDegrees))), Blick nach \(direction(shot.headingDegrees))"
    }

    /// "MapKit: 29,0 km, Neigung 68,0°", and what MapKit changed: "· Neigung begrenzt" (flatter
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

    /// One line of the clipboard: "2 Dettifoss, 29 km, 22°: MapKit 29,0 km, Neigung 68,0°, Karte
    /// fertig nach 2,4 s"; a shot not looked at yet says "noch nicht angesehen".
    public static func line(index: Int, _ result: CameraProbeResult?) -> String {
        guard shots.indices.contains(index) else { return "" }
        let shot = shots[index]
        let head = "\(index + 1) \(shot.place), \(kilometers(shot.distanceMeters)), \(degrees(shot.elevationDegrees))"
        guard let result else { return "\(head): noch nicht angesehen" }
        let got = got(shot, result).replacingOccurrences(of: "MapKit: ", with: "MapKit ")
        return "\(head): \(got), \(readiness(result))"
    }

    public static func keepsPitch(_ shot: CameraProbeShot, _ result: CameraProbeResult) -> Bool {
        abs(result.pitchDegrees - shot.pitchDegrees) <= pitchToleranceDegrees
    }

    public static func keepsDistance(_ shot: CameraProbeShot, _ result: CameraProbeResult) -> Bool {
        abs(result.distanceMeters - shot.distanceMeters) <= distanceTolerance * shot.distanceMeters
    }

    // MARK: Words and numbers

    static let directions = ["Norden", "Nordosten", "Osten", "Südosten", "Süden", "Südwesten", "Westen", "Nordwesten"]

    /// The nearest of the eight directions to a heading ("Norden" for 10°).
    static func direction(_ heading: Double) -> String {
        guard heading.isFinite else { return directions[0] }
        let eighth = Int((heading.truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
        return directions[(eighth + 8) % 8]
    }

    /// "29 km": whole kilometres.
    static func kilometers(_ meters: Double) -> String {
        guard meters.isFinite, abs(meters) < 1e15 else { return "– km" }
        return "\(Int((meters / 1_000).rounded())) km"
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
