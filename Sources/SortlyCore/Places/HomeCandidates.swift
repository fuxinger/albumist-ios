import Foundation

/// A place from the user's own photos that can be chosen as home in "Dein Zuhause": a town
/// (offline, where no town is known, a region), with where it is and how often the user was there.
public struct HomeCandidate: Hashable, Sendable, Identifiable {
    /// The place key it stands for.
    public var id: String
    public var center: GeoCoordinate
    public var components: PlaceComponents
    public var photoCount: Int
    public var photoDays: Int
    public var firstDate: Date?
    public var lastDate: Date?

    public init(id: String, center: GeoCoordinate, components: PlaceComponents, photoCount: Int, photoDays: Int,
                firstDate: Date? = nil, lastDate: Date? = nil) {
        self.id = id
        self.center = center
        self.components = components
        self.photoCount = photoCount
        self.photoDays = photoDays
        self.firstDate = firstDate
        self.lastDate = lastDate
    }

    public var name: HomeName { HomeName(components) }
    public var homePlace: HomePlace { HomePlace(center: center, components: components) }
}

/// The places the user can choose a home (or another place of theirs) from: every town of the
/// library with photos on a few days, from the analysis on the device. Works offline: without
/// online place names the regions are the candidates.
public enum HomeCandidates {
    /// A place needs photos on this many days to be offered.
    public static let minimumDays = 2

    /// Towns (or regions where no town is known) by photo days, most first.
    public static func make(facts: [AssetFacts], calendar: Calendar = .sortlyDefault) -> [HomeCandidate] {
        struct Group {
            var components: PlaceComponents
            var coordinates: [GeoCoordinate] = []
            var days = Set<Date>()
            var first: Date?
            var last: Date?
        }
        var groups: [PlaceKey: Group] = [:]
        for f in facts {
            guard let place = f.gpsPlace, let c = f.asset.usableLocation, !f.asset.isScreenshotLike,
                  let key = place.key(at: .locality) ?? place.key(at: .administrativeArea) ?? place.key(at: .country) else { continue }
            var group = groups[key] ?? Group(components: PlaceComponents(
                isoCountryCode: place.isoCountryCode, country: place.country, administrativeArea: place.administrativeArea,
                subAdministrativeArea: key.level == .locality ? place.subAdministrativeArea : nil,
                locality: key.level == .locality ? place.locality : nil))
            group.coordinates.append(c)
            if let date = f.asset.creationDate {
                group.days.insert(calendar.startOfDay(for: date))
                group.first = min(group.first ?? date, date)
                group.last = max(group.last ?? date, date)
            }
            groups[key] = group
        }
        return groups.compactMap { key, group -> HomeCandidate? in
            guard group.days.count >= minimumDays, let center = center(of: group.coordinates) else { return nil }
            return HomeCandidate(id: key.description, center: center, components: group.components,
                                 photoCount: group.coordinates.count, photoDays: group.days.count, firstDate: group.first, lastDate: group.last)
        }
        .sorted { ($0.photoDays, $0.photoCount, $1.id) > ($1.photoDays, $1.photoCount, $0.id) }
    }

    /// A stretch away from a place at least this long ends a stay there: a move, not a trip.
    public static let moveGap: TimeInterval = 28 * 86_400

    /// When the user's current stay at `center` began, for "Seit wann wohnst du dort?" under
    /// "Ändern": the first day of the latest run of photo days near it (within `radius`). Only
    /// a stretch of at least `moveGap` with photos elsewhere and none near it ends the run, so
    /// trips do not; days without photos say nothing. Too late a date does no harm (before it
    /// the detection decides), too early would make the years in the old town a trip.
    public static func stayStart(near center: GeoCoordinate, assets: some Sequence<AssetSnapshot>,
                                 radius: Double = TripDetector.Configuration().homeRadiusMeters,
                                 calendar: Calendar = .sortlyDefault) -> Date? {
        var near = Set<Date>(), away = Set<Date>()
        for asset in assets {
            guard let c = asset.usableLocation, let date = asset.creationDate, !asset.isScreenshotLike else { continue }
            let day = calendar.startOfDay(for: date)
            if GeoMath.distance(c, center) <= radius { near.insert(day) } else { away.insert(day) }
        }
        guard var start = near.max() else { return nil }
        // Newest first: near days extend the stay, a long enough stretch of days only elsewhere ends it.
        var awayLatest: Date?
        for day in near.union(away).sorted(by: >) where day < start {
            if near.contains(day) {
                awayLatest = nil
                start = day
            } else {
                let latest = awayLatest ?? day
                awayLatest = latest
                if latest.timeIntervalSince(day) + 86_400 >= moveGap { break }
            }
        }
        return start
    }

    /// Where the photos of a place are densest: the median of the photos within
    /// `RecurringPlaceAnswers.matchRadiusMeters` of the busiest cell of about 11 km. Not the
    /// median of all of them: offline a candidate is a whole region ("Bayern"), and the median of
    /// everyday photos in Munich and trips to Nuremberg and Würzburg lies near Nuremberg, more
    /// than the home radius away from where the user lives. For a town it is its busy part.
    static func center(of coordinates: [GeoCoordinate]) -> GeoCoordinate? {
        guard !coordinates.isEmpty else { return nil }
        struct Cell: Hashable { var lat: Int; var lon: Int }
        var cells: [Cell: [GeoCoordinate]] = [:]
        for c in coordinates {
            cells[Cell(lat: Int((c.latitude * 10).rounded(.down)), lon: Int((c.longitude * 10).rounded(.down))), default: []].append(c)
        }
        let busiest = cells.max { a, b in (a.value.count, b.key.lat, b.key.lon) < (b.value.count, a.key.lat, a.key.lon) }!.value
        let anchor = GeoCoordinate(latitude: busiest.map(\.latitude).sorted()[busiest.count / 2],
                                   longitude: busiest.map(\.longitude).sorted()[busiest.count / 2])
        let near = coordinates.filter { GeoMath.distance($0, anchor) <= RecurringPlaceAnswers.matchRadiusMeters }
        // The median, not the mean: a few photos at the edge of a large town do not move it.
        return GeoCoordinate(latitude: near.map(\.latitude).sorted()[near.count / 2],
                             longitude: near.map(\.longitude).sorted()[near.count / 2])
    }

    /// The candidates whose town, region or country contains `query` (case, accents and "ß"
    /// do not matter). An empty query keeps all.
    public static func filter(_ candidates: [HomeCandidate], query: String) -> [HomeCandidate] {
        let needle = PlaceKey.normalize(query)
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { candidate in
            [candidate.components.locality, candidate.components.subAdministrativeArea, candidate.components.administrativeArea, candidate.components.country]
                .compactMap { $0 }
                .contains { PlaceKey.normalize($0).contains(needle) }
        }
    }
}
