import Foundation

// "Dein Zuhause" (settings): where the user lives, as they say it. Albumist finds a home by
// itself (`HabitualArea`: the town and its surroundings where most everyday photos are taken).
// The user can confirm it, choose another place from their own photos, say there is none, and
// name the homes they had before ("Bis 2019: Hamburg"). Whatever the user said wins over the
// detection; where they said nothing, the detection decides as before.
//
// Zuhause is the home town and its surroundings (the trip detection's home radius), never the
// whole country (decision Fuchs 15.11.).

/// A home the user chose: a place from their own photos.
public struct HomePlace: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var center: GeoCoordinate
    /// The place as Albumist knew it when the user chose it (town, region, country, as far as
    /// they were known: offline only country and region). Names the home in the settings and
    /// tells which countries, regions and towns are the home's (`keys`).
    public var components: PlaceComponents?

    public init(id: SortlyID, center: GeoCoordinate, components: PlaceComponents?) {
        self.id = id
        self.center = center
        self.components = components
    }

    /// A place chosen at `center`. The same place always gets the same id.
    public init(center: GeoCoordinate, components: PlaceComponents?) {
        self.init(id: .stable("home", String(format: "%.3f,%.3f", center.latitude, center.longitude)), center: center, components: components)
    }

    /// The country, region, district and town of this home (as place keys at their level):
    /// the places that are "at home" for trip names and are no album of their own.
    public var keys: Set<PlaceKey> {
        guard let components else { return [] }
        return Set([PlaceLevel.country, .administrativeArea, .subAdministrativeArea, .locality].compactMap { components.key(at: $0) })
    }
}

/// A home the user had before, up to a date ("Bis 2019: Hamburg").
public struct FormerHome: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var place: HomePlace
    /// Since when; nil: from the first photo on (or from the end of the former home before).
    public var from: Date?
    /// Up to this instant (not included).
    public var until: Date

    public init(id: SortlyID = SortlyID(), place: HomePlace, from: Date? = nil, until: Date) {
        self.id = id
        self.place = place
        self.from = from
        self.until = until
    }
}

/// The home at one date, from the user's settings (`HomeSettings.home(at:)`).
public enum HomeAtDate: Hashable, Sendable {
    /// The user chose this home for the date (the current one or a former one).
    case chosen(HomePlace)
    /// The user said they have no home: no photo of that time is "at home".
    case none
    /// The user said nothing for this date: Albumist's own detection decides, as before.
    case detected
}

/// What the user set in "Dein Zuhause" (store key `user.home`, part of the decisions copy in the
/// backup, kept by "Analyse neu aufbauen"). The places the user is often at ("Eltern",
/// "Zweitwohnung", "Arbeit") are `RecurringPlaceAnswers` with a name, next to it.
public struct HomeSettings: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable {
        /// Albumist's detection, as before (nothing set).
        case automatic
        /// The user confirmed the detected home or chose another one (`confirmed`).
        case confirmed
        /// "Kein Zuhause festlegen": the user has no home.
        case none
    }

    /// Stored with the value: a later version can tell what it reads.
    public static let formatVersion = 1

    public var mode: Mode
    /// The current home, when `mode` is `.confirmed`.
    public var confirmed: HomePlace?
    public var former: [FormerHome]
    /// When the user last changed something here.
    public var changedAt: Date?

    public init(mode: Mode = .automatic, confirmed: HomePlace? = nil, former: [FormerHome] = [], changedAt: Date? = nil) {
        self.mode = mode
        self.confirmed = confirmed
        self.former = former
        self.changedAt = changedAt
    }

    /// Nothing set: everything works exactly as without this setting.
    public var isAutomatic: Bool { currentMode == .automatic && former.isEmpty }

    /// The mode in effect: "confirmed" without a place is automatic.
    public var currentMode: Mode { mode == .confirmed && confirmed == nil ? .automatic : mode }

    /// The single source of truth for "where was home at `date`" (trip detection, trip names,
    /// place suggestions and the sorted ring all ask this, through `HomeReference` and
    /// `HomeContext`):
    /// - the user's periods are the former homes (`from` … `until`, `from` nil = open) and the
    ///   current home (confirmed or none) from the beginning of time to the end;
    /// - of the periods that contain `date`, the one that ends first wins. So "Bis 2015: Köln",
    ///   "Bis 2019: Hamburg" and "München" read as a chain: Köln, then Hamburg, then München,
    ///   and an overlap is decided for the more specific (shorter-lived) period;
    /// - a date no period contains (current home automatic) is `.detected`.
    /// A photo without a date is judged by the current home.
    public func home(at date: Date?) -> HomeAtDate {
        if let date {
            let containing = former.filter { ($0.from.map { $0 <= date } ?? true) && date < $0.until }
            if let first = containing.min(by: { a, b in
                (a.until, -(a.from ?? .distantPast).timeIntervalSince1970, a.id.rawValue)
                    < (b.until, -(b.from ?? .distantPast).timeIntervalSince1970, b.id.rawValue)
            }) {
                return .chosen(first.place)
            }
        }
        switch currentMode {
        case .automatic: return .detected
        case .none: return .none
        case .confirmed: return confirmed.map(HomeAtDate.chosen) ?? .detected
        }
    }

    /// Every home the user chose (current and former), for place suggestions: none of them is
    /// an album of its own.
    public var chosenPlaces: [HomePlace] {
        (currentMode == .confirmed ? [confirmed].compactMap { $0 } : []) + former.map(\.place)
    }

    /// Some dates are left to the detection.
    public var usesDetection: Bool { currentMode == .automatic }

    // MARK: Codable (fields added later are read with their defaults)

    enum CodingKeys: String, CodingKey { case version, mode, confirmed, former, changedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(String.self, forKey: .mode) ?? Mode.automatic.rawValue
        // A mode a later version added is read as "automatic": the detection is always safe.
        mode = Mode(rawValue: raw) ?? .automatic
        confirmed = try c.decodeIfPresent(HomePlace.self, forKey: .confirmed)
        former = try c.decodeIfPresent([FormerHome].self, forKey: .former) ?? []
        changedAt = try c.decodeIfPresent(Date.self, forKey: .changedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(confirmed, forKey: .confirmed)
        try c.encode(former, forKey: .former)
        try c.encodeIfPresent(changedAt, forKey: .changedAt)
    }

    // MARK: Changes from the settings screen

    /// "Stimmt" on the detected home, or a place the user chose under "Ändern".
    public func confirming(_ place: HomePlace, date: Date) -> HomeSettings {
        var copy = self
        copy.mode = .confirmed
        copy.confirmed = place
        copy.changedAt = date
        return copy
    }

    /// "Kein Zuhause festlegen".
    public func withoutHome(date: Date) -> HomeSettings {
        var copy = self
        copy.mode = .none
        copy.confirmed = nil
        copy.changedAt = date
        return copy
    }

    /// "Automatisch erkennen": the current home is Albumist's detection again. Former homes stay.
    public func automatic(date: Date) -> HomeSettings {
        var copy = self
        copy.mode = .automatic
        copy.confirmed = nil
        copy.changedAt = date
        return copy
    }

    public func addingFormer(_ home: FormerHome, date: Date) -> HomeSettings {
        var copy = self
        copy.former.append(home)
        copy.former.sort { ($0.until, $0.id.rawValue) < ($1.until, $1.id.rawValue) }
        copy.changedAt = date
        return copy
    }

    public func removingFormer(_ id: SortlyID, date: Date) -> HomeSettings {
        var copy = self
        copy.former.removeAll { $0.id == id }
        copy.changedAt = date
        return copy
    }
}

/// The home Albumist found by itself at the end of the library (shown as "erkannt").
public struct DetectedHome: Hashable, Sendable, Codable {
    public var center: GeoCoordinate
    /// Since when it has been the home (the user moved there then); nil: as long as the photos go back.
    public var since: Date?
    /// Days with photos there.
    public var photoDays: Int

    public init(center: GeoCoordinate, since: Date?, photoDays: Int) {
        self.center = center
        self.since = since
        self.photoDays = photoDays
    }
}

/// What the suggestions ask about home: "is this country, region or town the user's home at
/// this date?". Goes through `HomeSettings.home(at:)`; where the user set nothing, the
/// everyday places of the library decide as before (`LibraryProfile`).
public struct HomeContext: Sendable {
    public var settings: HomeSettings
    public var profile: LibraryProfile

    public init(settings: HomeSettings = HomeSettings(), profile: LibraryProfile = LibraryProfile()) {
        self.settings = settings
        self.profile = profile
    }

    /// Whether `key` is home at `date`: never a trip's name, never an album of its own.
    public func isHome(_ key: PlaceKey, at date: Date?) -> Bool {
        switch settings.home(at: date) {
        case .chosen(let place): place.keys.contains(key)
        case .none: false
        case .detected: profile.isEveryday(key)
        }
    }

    /// Whether `key` is home at any time: no place album of its own (curation rule 1).
    public func isHomeAtSomeTime(_ key: PlaceKey) -> Bool {
        if settings.chosenPlaces.contains(where: { $0.keys.contains(key) }) { return true }
        return settings.usesDetection && profile.isEveryday(key)
    }
}

/// How a home is called in the settings: the town ("München und Umgebung"), or where only
/// country and region are known (offline), the region.
public struct HomeName: Hashable, Sendable {
    public var town: String?
    public var region: String?
    public var country: String?

    public init(town: String? = nil, region: String? = nil, country: String? = nil) {
        self.town = town
        self.region = region
        self.country = country
    }

    public init(_ components: PlaceComponents?) {
        self.init(town: components?.locality, region: components?.administrativeArea, country: components?.country)
    }

    public var isEmpty: Bool { town == nil && region == nil && country == nil }

    /// The components most photos within `radius` of `center` have (towns first): what the
    /// detected home is called, from the user's own photos.
    public static func components(near center: GeoCoordinate, facts: [AssetFacts], radius: Double = RecurringPlaceAnswers.matchRadiusMeters) -> PlaceComponents? {
        var towns: [PlaceKey: (PlaceComponents, Int)] = [:]
        var regions: [PlaceKey: (PlaceComponents, Int)] = [:]
        for f in facts {
            guard let place = f.gpsPlace, let c = f.asset.usableLocation, GeoMath.distance(c, center) <= radius else { continue }
            if let key = place.key(at: .locality) { towns[key, default: (place, 0)].1 += 1 }
            if let key = place.key(at: .administrativeArea) ?? place.key(at: .country) { regions[key, default: (place, 0)].1 += 1 }
        }
        func best(_ counts: [PlaceKey: (PlaceComponents, Int)]) -> PlaceComponents? {
            counts.max { ($0.value.1, $1.key) < ($1.value.1, $0.key) }?.value.0
        }
        if let town = best(towns) {
            return PlaceComponents(isoCountryCode: town.isoCountryCode, country: town.country, administrativeArea: town.administrativeArea,
                                   subAdministrativeArea: town.subAdministrativeArea, locality: town.locality)
        }
        return best(regions).map { PlaceComponents(isoCountryCode: $0.isoCountryCode, country: $0.country, administrativeArea: $0.administrativeArea) }
    }
}
