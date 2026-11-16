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
            var latitudes: [Double] = []
            var longitudes: [Double] = []
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
            group.latitudes.append(c.latitude)
            group.longitudes.append(c.longitude)
            if let date = f.asset.creationDate {
                group.days.insert(calendar.startOfDay(for: date))
                group.first = min(group.first ?? date, date)
                group.last = max(group.last ?? date, date)
            }
            groups[key] = group
        }
        return groups.compactMap { key, group -> HomeCandidate? in
            guard group.days.count >= minimumDays else { return nil }
            // The median, not the mean: a few photos at the edge of a large town do not move it.
            let lat = group.latitudes.sorted()[group.latitudes.count / 2]
            let lon = group.longitudes.sorted()[group.longitudes.count / 2]
            return HomeCandidate(id: key.description, center: GeoCoordinate(latitude: lat, longitude: lon), components: group.components,
                                 photoCount: group.latitudes.count, photoDays: group.days.count, firstDate: group.first, lastDate: group.last)
        }
        .sorted { ($0.photoDays, $0.photoCount, $1.id) > ($1.photoDays, $1.photoCount, $0.id) }
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
