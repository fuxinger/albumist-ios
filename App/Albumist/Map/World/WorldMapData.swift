import Foundation
import MapKit
import AlbumistCore
import AlbumistMap

/// What the map for laypeople (`WorldMapView`) shows in its sheet: nothing chosen (the user's
/// trips), a country, a trip or one place of a trip.
enum WorldMapSelection: Hashable {
    case home
    case country(String)
    case trip(AlbumistID)
    case place(trip: AlbumistID, placeIndex: Int)
}

/// The map's data: the summary of the user's trips and each trip's photos, made once when the
/// map opens (off the main thread), and each trip's film worked out on first use.
@MainActor @Observable
final class WorldMapData {
    private(set) var summary: MapSummary?
    private(set) var loaded = false
    @ObservationIgnored private var factsByTrip: [AlbumistID: [AssetFacts]] = [:]
    @ObservationIgnored private var films: [AlbumistID: TripFilm] = [:]
    @ObservationIgnored private var photos: [AlbumistID: TripPhotos] = [:]
    @ObservationIgnored private(set) var pinsByID: [String: MapPin] = [:]

    func load(_ model: AppModel) async {
        guard !loaded else { return }
        let facts = model.facts
        async let grouped = Task.detached(priority: .userInitiated) {
            Dictionary(grouping: facts.filter { $0.tripID != nil }) { $0.tripID! }
        }.value
        let made = await model.mapPrototypeSummary()
        factsByTrip = await grouped
        summary = made?.summary
        pinsByID = Dictionary((made?.summary.pins ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loaded = true
    }

    /// The trips, newest first.
    var trips: [MapTrip] {
        (summary?.trips ?? []).sorted { $0.geometry.start > $1.geometry.start }
    }

    func trip(_ id: AlbumistID) -> MapTrip? { summary?.trip(id) }

    func film(_ trip: MapTrip) -> TripFilm {
        if let film = films[trip.id] { return film }
        let film = TripFilm(geometry: trip.geometry)
        films[trip.id] = film
        return film
    }

    func photos(_ trip: MapTrip) -> TripPhotos {
        if let made = photos[trip.id] { return made }
        let made = TripPhotos.collect(geometry: trip.geometry, ownFacts: factsByTrip[trip.id] ?? [])
        photos[trip.id] = made
        return made
    }

    /// The trips with photos in a country, newest first.
    func trips(inCountry key: String) -> [MapTrip] {
        trips.filter { ($0.geometry.countryPhotos[key] ?? 0) > 0 || $0.geometry.mainCountryKey == key }
    }

    /// Where the map's pins of a country or world region stand (to zoom in on them).
    func coordinates(ofCountry key: String) -> [GeoCoordinate] {
        trips(inCountry: key).flatMap { trip in
            trip.geometry.places.filter { $0.countryKey == key || $0.countryKey == nil && trip.geometry.mainCountryKey == key }.map(\.coordinate)
        }
    }

    func coordinates(ofRegion region: WorldRegion) -> [GeoCoordinate] {
        (summary?.pins ?? []).filter { $0.level == .country && $0.region == region }.map(\.coordinate)
    }
}

/// Names and dates as the map says them.
enum WorldMapText {
    static func countryName(_ key: String) -> String {
        guard key.count == 2 else { return GlobePinLabel.countryName(key) }
        return Locale.current.localizedString(forRegionCode: key) ?? key
    }

    /// "August 2025"; a trip over two months "Juli – August 2025".
    static func when(_ geometry: TripGeometry) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = geometry.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        let style = Date.FormatStyle(date: .omitted, time: .omitted, calendar: calendar, timeZone: calendar.timeZone)
        let end = style.month(.wide).year().format(geometry.end.addingTimeInterval(-1))
        let start = style.month(.wide).year().format(geometry.start)
        guard start != end else { return start }
        let sameYear = calendar.component(.year, from: geometry.start) == calendar.component(.year, from: geometry.end.addingTimeInterval(-1))
        return "\(sameYear ? style.month(.wide).format(geometry.start) : start) – \(end)"
    }

    static func placeName(_ trip: MapTrip, _ index: Int) -> String {
        guard trip.geometry.places.indices.contains(index), let name = trip.geometry.places[index].name, !name.isEmpty else { return trip.title }
        return name
    }
}

/// Map regions for a centre and a width on the ground.
enum WorldMapCamera {
    /// The share of the screen the sheet or the film's card covers at the bottom: what the map
    /// shows is moved up by half of it.
    static let coveredShare = 0.4

    /// A region `widthMeters` wide around `center` for a view of `size`, moved so that `center`
    /// sits in the middle of the part above the sheet.
    static func region(center: GeoCoordinate, widthMeters: Double, size: CGSize, covered: Double = coveredShare) -> MKCoordinateRegion {
        let aspect = size.width > 0 ? max(size.height / size.width, 0.5) : 2
        let width = min(max(widthMeters, 1_000), 20_000_000)
        let height = width * aspect / max(1 - covered, 0.3)
        let shiftDegrees = height * covered / 2 / GeoMath.metersPerDegreeLatitude
        let latitude = min(max(center.latitude - shiftDegrees, -80), 80)
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: center.longitude),
                                  latitudinalMeters: height, longitudinalMeters: width)
    }

    static func region(focus: MapFocus, size: CGSize, covered: Double = coveredShare) -> MKCoordinateRegion {
        region(center: focus.center, widthMeters: focus.radiusMeters * 2.4, size: size, covered: covered)
    }

    /// The width on the ground a region shows, in metres (for the pins' level).
    static func widthMeters(of region: MKCoordinateRegion) -> Double {
        let meters = region.span.longitudeDelta * GeoMath.metersPerDegreeLatitude * cos(region.center.latitude * .pi / 180)
        return meters.isFinite ? max(meters, 1) : .nan
    }

    static func focus(on coordinates: [GeoCoordinate], minimumRadiusMeters: Double) -> MapFocus? {
        let points = coordinates.filter(\.isPlausible)
        guard let center = GeoMath.centroid(points) ?? points.first else { return nil }
        let farthest = points.reduce(0) { max($0, GeoMath.distance(center, $1)) }
        return MapFocus(center: center, radiusMeters: max(farthest * 1.2, minimumRadiusMeters))
    }
}

extension GeoCoordinate {
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
