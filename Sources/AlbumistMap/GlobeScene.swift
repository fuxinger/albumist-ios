import Foundation
import AlbumistCore

/// What a globe shows (concept §4.2, §7): the arcs, the pins of every level, the visited countries
/// for the tint, the trips (their routes after the handover to Apple's map, and "Reise
/// abspielen"), the rounded home and where to look first. Plain values made from the map summary
/// (`init(summary:)`) or, for the prototype page, from demo data (`demo()`): our own globe, Apple's
/// globe and the map after the handover all draw the same scene, so they can be compared.
public struct GlobeScene: Hashable, Sendable {
    public var arcs: [MapArc]
    /// Every level (`MapPins.build`); a view shows those `MapPins.visible` picks for its camera.
    public var pins: [MapPin]
    public var countries: [MapCountry]
    public var trips: [MapTrip]
    /// Rounded, never the exact home (concept §8); the house shows only at
    /// `MapHome.showsHouse(atWidth:)`.
    public var home: RoundedHome?
    public var focus: MapFocus?

    public init(arcs: [MapArc], pins: [MapPin], countries: [MapCountry], trips: [MapTrip], home: RoundedHome?, focus: MapFocus?) {
        self.arcs = arcs
        self.pins = pins
        self.countries = countries
        self.trips = trips
        self.home = home
        self.focus = focus
    }

    public init(summary: MapSummary) {
        self.init(arcs: summary.arcs, pins: summary.pins, countries: summary.countries, trips: summary.trips,
                  home: summary.home, focus: summary.focus)
    }

    /// The visited countries' codes, for the tint (disputed areas are no country, concept §5).
    public var visitedCountryCodes: Set<String> { Set(countries.map(\.code)) }

    /// The first camera: the focus filling most of the view's width, the whole Earth without one.
    public var firstCamera: GlobeCamera { GlobeCamera.showing(focus) }
}

/// Where a globe or a map looks: the point at the view's centre, and how much of the Earth spans
/// the view's width, as great-circle metres across it through its centre (the measure of
/// `MapViewport.widthMeters`, which picks and groups the pins). A view zoomed out beyond the
/// whole Earth (the globe's disc narrower than the view) counts on linearly:
/// `wholeEarthWidthMeters` is the disc exactly as wide as the view, twice that is a disc half as
/// wide. Renderers convert this to their own camera (distance, field of view, `MKMapCamera`);
/// the handover to Apple's map happens below `handoverWidthMeters` (concept §7).
public struct GlobeCamera: Hashable, Sendable {
    public var center: GeoCoordinate
    public var widthMeters: Double

    public init(center: GeoCoordinate, widthMeters: Double) {
        self.center = center
        self.widthMeters = widthMeters
    }

    /// Half the Earth's circumference: from one edge of the disc to the other through its centre.
    public static let wholeEarthWidthMeters = Double.pi * GeoMath.earthRadiusMeters
    /// Under about 3,000 km across, Apple's map takes over from our globe (concept §7); the same
    /// width as the house's upper limit (`MapHome.houseMaximumWidthMeters`).
    public static let handoverWidthMeters = 3_000_000.0
    /// The farthest a view zooms out: the disc a third of the view's width.
    public static let maximumWidthMeters = 3 * wholeEarthWidthMeters
    /// The closest our globe zooms in before the handover; Apple's map goes on from there.
    public static let minimumWidthMeters = 1_000.0

    /// The first view without a focus: the whole Earth with some room around the disc.
    public static let wholeEarth = GlobeCamera(center: GeoCoordinate(latitude: 30, longitude: 10), widthMeters: wholeEarthWidthMeters * 1.15)

    /// The camera that shows `focus`: its cap across 80 % of the view's width (concept §4.10,
    /// "Kleiner Anfang": a few trips bring the globe closer), never closer than the handover and
    /// never farther than `wholeEarth`. The whole Earth without a focus.
    public static func showing(_ focus: MapFocus?) -> GlobeCamera {
        guard let focus, focus.center.isPlausible, focus.radiusMeters.isFinite, focus.radiusMeters > 0 else { return wholeEarth }
        let width = min(max(2 * focus.radiusMeters / 0.8, handoverWidthMeters), wholeEarth.widthMeters)
        return GlobeCamera(center: focus.center, widthMeters: width)
    }

    /// The same camera with its values in range: latitude within ±90°, longitude within ±180°,
    /// the width between `minimumWidthMeters` and `maximumWidthMeters` (a broken value: the whole
    /// Earth).
    public var clamped: GlobeCamera {
        let latitude = center.latitude.isFinite ? min(max(center.latitude, -90), 90) : 0
        let longitude = center.longitude.isFinite ? MapHome.normalizedLongitude(center.longitude) : 0
        let width = widthMeters.isFinite ? min(max(widthMeters, Self.minimumWidthMeters), Self.maximumWidthMeters) : Self.wholeEarth.widthMeters
        return GlobeCamera(center: GeoCoordinate(latitude: latitude, longitude: longitude), widthMeters: width)
    }

    /// Whether Apple's map shows this view rather than our globe.
    public var isHandedOver: Bool { widthMeters < Self.handoverWidthMeters }

    /// The viewport for picking and grouping pins (`MapPins.visible`) in a view of this size.
    public func viewport(widthPoints: Double, heightPoints: Double) -> MapViewport {
        MapViewport(center: center, widthMeters: widthMeters, widthPoints: widthPoints, heightPoints: heightPoints)
    }
}
