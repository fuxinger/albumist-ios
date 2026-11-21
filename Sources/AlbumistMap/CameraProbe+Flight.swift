import Foundation
import AlbumistCore

/// The flight of the camera probe (`CameraProbe.flight`): one stretch of the fourth web draft's
/// camera, flown in real time over Apple's map. Its second review asked for exactly this stretch
/// (film seconds 33.4 to 43.8 at 390 × 844): the dot leaves Jökulsárlón 15 km below the camera,
/// the camera climbs to 145 km within 3.5 s, comes down towards Dettifoss, turns there under the
/// photo (in the film a photo covers the map from `coveredFrom` to `coveredUntil`) and holds low
/// at 15 km, 282 km of ground in 10.4 s. Whether Apple's satellite map keeps up with that decides
/// how the draft may fly.
public struct CameraProbeFlight: Hashable, Sendable {
    /// One moment of the draft's camera: seconds since the start, kilometres along the draft's
    /// route, the distance from the camera to the dot, the angle above the horizon and the
    /// heading, unwrapped (it turns on past -180° as the draft's camera turns).
    public struct Key: Hashable, Sendable {
        public var seconds: Double
        public var routeKm: Double
        public var distanceMeters: Double
        public var elevationDegrees: Double
        public var headingDegrees: Double
    }

    /// A place on the draft's route, and its kilometre: the route runs straight from place to
    /// place in degrees, as the draft draws it.
    public struct Waypoint: Hashable, Sendable {
        public var name: String
        public var coordinate: GeoCoordinate
        public var routeKm: Double
    }

    public var from: String
    public var to: String
    public var purpose: String
    public var waypoints: [Waypoint]
    /// In time order, at least two.
    public var keys: [Key]
    /// In the film the photo of the place reached covers the map from here
    public var coveredFrom: Double
    /// until here (seconds since the start).
    public var coveredUntil: Double

    /// How long the flight takes.
    public var seconds: Double { keys.last?.seconds ?? 0 }

    /// The ground the dot covers, in kilometres.
    public var groundKm: Double { (keys.last?.routeKm ?? 0) - (keys.first?.routeKm ?? 0) }

    /// The camera at a moment of the flight (before the start the first, after the end the last):
    /// between two keys the dot's kilometre, the angle and the heading in a straight line, the
    /// distance by the same factor each second (as a zoom looks even), looking at the dot.
    public func camera(at time: Double) -> PlaybackCamera {
        guard let first = keys.first, let last = keys.last else {
            return PlaybackCamera(center: GeoCoordinate(latitude: 0, longitude: 0), distanceMeters: 0, pitchDegrees: 0, headingDegrees: 0)
        }
        let time = time.isNaN ? first.seconds : min(max(time, first.seconds), last.seconds)
        let after = keys.firstIndex { $0.seconds > time } ?? keys.count - 1
        let a = keys[max(after - 1, 0)], b = keys[after]
        let share = b.seconds > a.seconds ? min(max((time - a.seconds) / (b.seconds - a.seconds), 0), 1) : 1
        let km = Self.mix(a.routeKm, b.routeKm, share)
        let distance: Double
        if share == 0 || share == 1 || a.distanceMeters <= 0 || b.distanceMeters <= 0 {
            distance = Self.mix(a.distanceMeters, b.distanceMeters, share)
        } else {
            distance = exp(Self.mix(log(a.distanceMeters), log(b.distanceMeters), share))
        }
        let elevation = Self.mix(a.elevationDegrees, b.elevationDegrees, share)
        let northUp = Self.mix(a.headingDegrees, b.headingDegrees, share).truncatingRemainder(dividingBy: 360)
        return PlaybackCamera(center: position(atKm: km), distanceMeters: distance, pitchDegrees: 90 - elevation,
                              headingDegrees: northUp < 0 ? northUp + 360 : northUp)
    }

    /// The dot at a kilometre of the route, kept within the waypoints.
    public func position(atKm km: Double) -> GeoCoordinate {
        guard let first = waypoints.first, let last = waypoints.last else { return GeoCoordinate(latitude: 0, longitude: 0) }
        let km = km.isNaN ? first.routeKm : min(max(km, first.routeKm), last.routeKm)
        let after = waypoints.firstIndex { $0.routeKm > km } ?? waypoints.count - 1
        let a = waypoints[max(after - 1, 0)], b = waypoints[after]
        let share = b.routeKm > a.routeKm ? min(max((km - a.routeKm) / (b.routeKm - a.routeKm), 0), 1) : 1
        return GeoCoordinate(latitude: Self.mix(a.coordinate.latitude, b.coordinate.latitude, share),
                             longitude: Self.mix(a.coordinate.longitude, b.coordinate.longitude, share))
    }

    /// From `a` (share 0) to `b` (share 1) in a straight line, exactly `a` and `b` at the ends.
    static func mix(_ a: Double, _ b: Double, _ share: Double) -> Double {
        a * (1 - share) + b * share
    }

    /// Whether the film covers the map with a photo at this moment.
    public func isCovered(at time: Double) -> Bool {
        time >= coveredFrom && time < coveredUntil
    }
}

extension CameraProbe {
    /// The draft's camera from the dot leaving Jökulsárlón (33.36 s) to it leaving Dettifoss
    /// (43.75 s), every quarter of a second, read from the draft's own measurement at 390 × 844
    /// (its review, data/m390.json): kilometre of the route, distance, angle above the horizon,
    /// heading. The Dettifoss photo covers the map from 40.1 to 43.25 s.
    public static let flight = CameraProbeFlight(
        from: "Jökulsárlón", to: "Dettifoss", purpose: "Flug wie im Film (33 bis 44 s)",
        waypoints: [
            waypoint("Jökulsárlón", 64.0485, -16.1806, 374.0),
            waypoint("Höfn", 64.2539, -15.2082, 425.4),
            waypoint("Egilsstaðir", 65.2653, -14.3948, 544.2),
            waypoint("Dettifoss", 65.8146, -16.3846, 656.4),
        ],
        keys: [
            key(0.00, 374.0, 14_630, 17.0, 41.6), key(0.25, 374.8, 14_910, 17.0, 42.6), key(0.50, 376.9, 15_700, 17.1, 43.2),
            key(0.75, 380.6, 17_430, 17.3, 43.4), key(1.00, 385.4, 20_550, 17.9, 43.4), key(1.25, 391.2, 25_560, 19.4, 43.2),
            key(1.50, 398.7, 32_950, 22.0, 42.5), key(1.75, 408.5, 43_100, 25.3, 41.3), key(2.00, 421.3, 56_560, 27.8, 39.1),
            key(2.25, 435.3, 74_110, 28.7, 36.2), key(2.50, 451.0, 96_150, 28.9, 33.2), key(2.75, 475.0, 119_970, 29.0, 30.2),
            key(3.00, 493.3, 137_210, 29.0, 27.2), key(3.25, 506.5, 143_320, 29.0, 24.2), key(3.50, 519.7, 144_630, 29.0, 21.2),
            key(3.75, 532.9, 143_900, 29.0, 18.2), key(4.00, 546.1, 140_630, 29.0, 15.2), key(4.25, 559.3, 138_960, 29.0, 12.2),
            key(4.50, 572.6, 138_140, 29.0, 9.2), key(4.75, 585.8, 136_280, 29.0, 6.2), key(5.00, 599.2, 129_660, 29.0, 3.2),
            key(5.25, 613.0, 117_320, 29.0, 0.2), key(5.50, 626.8, 103_590, 29.0, -2.8), key(5.75, 640.6, 90_420, 29.0, -5.8),
            key(6.00, 651.9, 80_150, 29.0, -8.8), key(6.25, 656.3, 74_930, 29.0, -11.8), key(6.50, 656.4, 73_420, 29.0, -13.9),
            key(6.75, 656.4, 73_050, 29.0, -15.0), key(7.00, 656.4, 72_970, 29.0, -15.6), key(7.25, 656.4, 72_890, 29.0, -15.8),
            key(7.50, 656.4, 71_280, 28.8, -18.0), key(7.75, 656.4, 64_780, 28.1, -26.9), key(8.00, 656.4, 51_840, 26.5, -47.5),
            key(8.25, 656.4, 34_630, 23.5, -84.2), key(8.50, 656.4, 22_090, 20.1, -124.4), key(8.75, 656.4, 17_030, 18.2, -146.7),
            key(9.00, 656.4, 15_100, 17.3, -156.1), key(9.25, 656.4, 14_580, 17.0, -157.6), key(9.50, 656.4, 14_550, 17.0, -156.3),
            key(9.75, 656.4, 14_550, 17.0, -154.8), key(10.00, 656.4, 14_550, 17.0, -153.3), key(10.25, 656.4, 14_550, 17.0, -151.8),
            key(10.39, 656.4, 14_600, 17.0, -150.9),
        ],
        coveredFrom: 6.74, coveredUntil: 9.89)

    private static func waypoint(_ name: String, _ latitude: Double, _ longitude: Double, _ km: Double) -> CameraProbeFlight.Waypoint {
        CameraProbeFlight.Waypoint(name: name, coordinate: GeoCoordinate(latitude: latitude, longitude: longitude), routeKm: km)
    }

    private static func key(_ seconds: Double, _ km: Double, _ meters: Double, _ elevation: Double, _ heading: Double) -> CameraProbeFlight.Key {
        CameraProbeFlight.Key(seconds: seconds, routeKm: km, distanceMeters: meters, elevationDegrees: elevation, headingDegrees: heading)
    }
}
