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
    public var id: AlbumistID
    public var center: GeoCoordinate
    /// The place as Albumist knew it when the user chose it (town, region, country, as far as
    /// they were known: offline only country and region). Names the home in the settings and
    /// tells which countries, regions and towns are the home's (`keys`).
    public var components: PlaceComponents?

    public init(id: AlbumistID, center: GeoCoordinate, components: PlaceComponents?) {
        self.id = id
        self.center = center
        self.components = components
    }

    /// A place chosen at `center`. The same place always gets the same id.
    public init(center: GeoCoordinate, components: PlaceComponents?) {
        self.init(id: .stable("home", String(format: "%.3f,%.3f", center.latitude, center.longitude)), center: center, components: components)
    }

    /// The country, region, district and town this home was called when the user chose it (as
    /// place keys at their level). Only the fallback for `HomeContext`, which names a chosen
    /// home from the photos around it whenever suggestions are made: names stored at the
    /// choice can be missing (offline, "Ort ohne Namen") or only the region.
    public var keys: Set<PlaceKey> {
        guard let components else { return [] }
        return Set([PlaceLevel.country, .administrativeArea, .subAdministrativeArea, .locality].compactMap { components.key(at: $0) })
    }
}

/// A home the user had before, up to a date ("Bis 2019: Hamburg").
public struct FormerHome: Hashable, Sendable, Codable, Identifiable {
    public var id: AlbumistID
    public var place: HomePlace
    /// Since when; nil: from the first photo on (or from the end of the former home before).
    public var from: Date?
    /// Up to this instant (not included).
    public var until: Date

    public init(id: AlbumistID = AlbumistID(), place: HomePlace, from: Date? = nil, until: Date) {
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
    /// From when the current home holds; before it the detection keeps deciding (with both homes
    /// in the months of a move), so a confirmation never changes the past behind the user's back.
    /// "Stimmt" on the detected home: the moment of the confirmation (it only keeps later photos
    /// from moving the home). A place picked under "Ändern": the day the user says they live
    /// there since ("Seit wann wohnst du dort?", proposed by `HomeCandidates.stayStart`). nil
    /// (every date) only in values stored by earlier builds of this branch.
    public var confirmedFrom: Date?
    public var former: [FormerHome]
    /// When the user last changed something here.
    public var changedAt: Date?

    public init(mode: Mode = .automatic, confirmed: HomePlace? = nil, confirmedFrom: Date? = nil, former: [FormerHome] = [], changedAt: Date? = nil) {
        self.mode = mode
        self.confirmed = confirmed
        self.confirmedFrom = confirmedFrom
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
    ///   current home: "Kein Zuhause" from the beginning of time to the end, a chosen or confirmed
    ///   home from `confirmedFrom` on;
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
        case .confirmed:
            if let date, let confirmedFrom, date < confirmedFrom { return .detected }
            return confirmed.map(HomeAtDate.chosen) ?? .detected
        }
    }

    /// Every home the user chose (current and former), for place suggestions: none of them is
    /// an album of its own.
    public var chosenPlaces: [HomePlace] {
        (currentMode == .confirmed ? [confirmed].compactMap { $0 } : []) + former.map(\.place)
    }

    /// Some dates are left to the detection.
    public var usesDetection: Bool { currentMode == .automatic || (currentMode == .confirmed && confirmedFrom != nil) }

    // MARK: Codable (fields added later are read with their defaults)

    enum CodingKeys: String, CodingKey { case version, mode, confirmed, confirmedFrom, former, changedAt }

    /// Lenient: a field this build cannot read (a later version's shape, or damage) is read as
    /// not set, so the value never stops an analysis. A mode a later version added is read as
    /// "automatic", and a confirmed home that cannot be read too: the detection is always safe.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        mode = raw.flatMap(Mode.init(rawValue:)) ?? .automatic
        confirmed = (try? c.decodeIfPresent(HomePlace.self, forKey: .confirmed)) ?? nil
        confirmedFrom = (try? c.decodeIfPresent(Date.self, forKey: .confirmedFrom)) ?? nil
        former = ((try? c.decodeIfPresent([Lenient<FormerHome>].self, forKey: .former)) ?? nil)?.compactMap(\.value) ?? []
        changedAt = (try? c.decodeIfPresent(Date.self, forKey: .changedAt)) ?? nil
        if mode == .confirmed && confirmed == nil { mode = .automatic }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .version)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(confirmed, forKey: .confirmed)
        try c.encodeIfPresent(confirmedFrom, forKey: .confirmedFrom)
        try c.encode(former, forKey: .former)
        try c.encodeIfPresent(changedAt, forKey: .changedAt)
    }

    // MARK: Changes from the settings screen

    /// "Stimmt" on the detected home: it holds from `date` on and changes nothing before
    /// (`confirmedFrom`).
    public func confirming(_ place: HomePlace, date: Date) -> HomeSettings {
        var copy = self
        copy.mode = .confirmed
        copy.confirmed = place
        copy.confirmedFrom = date
        copy.changedAt = date
        return copy
    }

    /// A place the user picked under "Ändern", their home `from` the day they moved there (the
    /// app always passes one; nil, every date, is for the tests of the period rules). Before it
    /// the detection decides as with "Stimmt"; former homes the user entered win for their periods.
    public func choosing(_ place: HomePlace, from: Date?, date: Date) -> HomeSettings {
        var copy = self
        copy.mode = .confirmed
        copy.confirmed = place
        copy.confirmedFrom = from
        copy.changedAt = date
        return copy
    }

    /// "Kein Zuhause festlegen".
    public func withoutHome(date: Date) -> HomeSettings {
        var copy = self
        copy.mode = .none
        copy.confirmed = nil
        copy.confirmedFrom = nil
        copy.changedAt = date
        return copy
    }

    /// "Automatisch erkennen": the current home is Albumist's detection again. Former homes stay.
    public func automatic(date: Date) -> HomeSettings {
        var copy = self
        copy.mode = .automatic
        copy.confirmed = nil
        copy.confirmedFrom = nil
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

    public func removingFormer(_ ids: Set<AlbumistID>, date: Date) -> HomeSettings {
        var copy = self
        copy.former.removeAll { ids.contains($0.id) }
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
///
/// A chosen home's places are taken from the photos around it each time suggestions are made
/// (`placeKeys(around:facts:)`), the way the ring and the trip detection judge it by distance,
/// not only from the names stored when the user chose it: those can be missing (offline,
/// "Ort ohne Namen") or only the region, and "Deutschland" or "München" would become an album
/// of all home photos once the towns are named.
public struct HomeContext: Sendable {
    public var settings: HomeSettings
    public var profile: LibraryProfile
    /// The places of each chosen home (by `HomePlace.id`), from the photos around it.
    public var chosenKeys: [AlbumistID: Set<PlaceKey>]
    /// How many places' keys were worked out (once per distinct place of the library, however
    /// many homes were chosen): for the test that keeps this linear.
    var placeKeyLookups = 0

    public init(settings: HomeSettings = HomeSettings(), profile: LibraryProfile = LibraryProfile(), facts: [AssetFacts] = [],
                radius: Double = TripDetector.Configuration().homeRadiusMeters) {
        self.settings = settings
        self.profile = profile
        var keys: [AlbumistID: Set<PlaceKey>] = [:]
        let chosen = settings.chosenPlaces
        if !chosen.isEmpty {
            // The places of every photo once; per home only the distance is measured.
            let table = PlaceKeyTable(facts: facts)
            placeKeyLookups = table.lookups
            for place in chosen where keys[place.id] == nil {
                keys[place.id] = place.keys.union(table.homeKeys(around: place.center, radius: radius))
            }
        }
        chosenKeys = keys
    }

    /// The places of `place` as a home.
    func keys(of place: HomePlace) -> Set<PlaceKey> { chosenKeys[place.id] ?? place.keys }

    /// Whether `key` is home at `date`: never a trip's name, never an album of its own.
    public func isHome(_ key: PlaceKey, at date: Date?) -> Bool {
        switch settings.home(at: date) {
        case .chosen(let place): keys(of: place).contains(key)
        case .none: false
        case .detected: profile.isEveryday(key)
        }
    }

    /// Whether `key` is home at any time: no place album of its own (curation rule 1).
    public func isHomeAtSomeTime(_ key: PlaceKey) -> Bool {
        if settings.chosenPlaces.contains(where: { keys(of: $0).contains(key) }) { return true }
        return settings.usesDetection && profile.isEveryday(key)
    }
}

/// The country, region, district and town keys of the photos' places, worked out once per
/// distinct place (`PlaceComponents.key(at:)` normalizes names and is slow on 50,000 photos),
/// with where each photo was taken.
struct PlaceKeyTable {
    static let levels: [PlaceLevel] = [.country, .administrativeArea, .subAdministrativeArea, .locality]
    /// Keys of each distinct place.
    private(set) var keys: [[PlaceKey]] = []
    /// Photos with a usable location: where, and the index of their place in `keys`.
    private(set) var located: [(coordinate: GeoCoordinate, place: Int)] = []
    /// Photos per key in the whole library.
    private(set) var everywhere: [PlaceKey: Int] = [:]
    var lookups: Int { keys.count }

    init(facts: [AssetFacts]) {
        var index: [PlaceComponents: Int] = [:]
        for f in facts {
            guard let place = f.gpsPlace else { continue }
            let i: Int
            if let known = index[place] {
                i = known
            } else {
                i = keys.count
                keys.append(Self.levels.compactMap { place.key(at: $0) })
                index[place] = i
            }
            for key in keys[i] { everywhere[key, default: 0] += 1 }
            if let c = f.asset.usableLocation { located.append((c, i)) }
        }
    }

    /// The countries, regions, districts and towns that are home around `center`: among the
    /// photos within `radius` (the home radius of the trip detection), a place holding at least
    /// a quarter of them (as for the everyday places, `LibraryProfile.everydayShare`), or one
    /// most of whose photos in the whole library lie there. So a town across the border inside
    /// the radius is home, and so is its country when the user's photos of it are mostly these
    /// everyday ones; a country visited on trips further away keeps its album.
    func homeKeys(around center: GeoCoordinate, radius: Double) -> Set<PlaceKey> {
        var nearPerPlace: [Int: Int] = [:]
        var nearPhotos = 0
        for photo in located where GeoMath.distance(photo.coordinate, center) <= radius {
            nearPhotos += 1
            nearPerPlace[photo.place, default: 0] += 1
        }
        var near: [PlaceKey: Int] = [:]
        for (place, count) in nearPerPlace {
            for key in keys[place] { near[key, default: 0] += count }
        }
        let needed = Double(nearPhotos) * LibraryProfile.everydayShare
        return Set(near.filter { key, count in
            Double(count) >= needed || 2 * count > everywhere[key, default: 0]
        }.keys)
    }
}

/// Decodes one element of a list on its own: an element this build cannot read (a later
/// version's shape, or damage) is left out instead of making the whole list unreadable.
public struct Lenient<T: Decodable & Sendable>: Decodable, Sendable {
    public let value: T?
    public init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
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
    /// `stop`: asked every 4,096 photos; once it says so, the pass gives up and says `nil`
    /// (`DerivedLibrary.namedHome` when its task is cancelled).
    public static func components(near center: GeoCoordinate, facts: [AssetFacts], radius: Double = RecurringPlaceAnswers.matchRadiusMeters,
                                  stoppingWhen stop: () -> Bool = { false }) -> PlaceComponents? {
        var towns: [PlaceKey: (PlaceComponents, Int)] = [:]
        var regions: [PlaceKey: (PlaceComponents, Int)] = [:]
        for (index, f) in facts.enumerated() {
            if index & 4095 == 0, stop() { return nil }
            guard let place = f.gpsPlace, let c = f.asset.usableLocation, GeoMath.distance(c, center) <= radius else { continue }
            if let key = place.key(at: .locality) { towns[key, default: (place, 0)].1 += 1 }
            if let key = place.key(at: .administrativeArea) ?? place.key(at: .country) { regions[key, default: (place, 0)].1 += 1 }
        }
        func best(_ counts: [PlaceKey: (PlaceComponents, Int)]) -> PlaceComponents? {
            counts.max { ($0.value.1, $1.key) < ($1.value.1, $0.key) }?.value.0
        }
        if let town = best(towns) {
            return PlaceComponents(isoCountryCode: town.isoCountryCode, country: town.country, administrativeArea: town.administrativeArea,
                                   subAdministrativeArea: town.subAdministrativeArea, locality: town.locality,
                                   administrativeAreaKey: town.administrativeAreaKey, disputedArea: town.disputedArea)
        }
        return best(regions).map { PlaceComponents(isoCountryCode: $0.isoCountryCode, country: $0.country, administrativeArea: $0.administrativeArea,
                                                   administrativeAreaKey: $0.administrativeAreaKey, disputedArea: $0.disputedArea) }
    }
}
