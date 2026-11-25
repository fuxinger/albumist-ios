import Foundation
import AlbumistCore

// "Deine Welt" (map concept 2.0, approved by Fuchs on 20.11.2026): the data the globe, the trip
// view, the numbers and the share images are drawn from. Worked out once per analysis state
// (`MapSummary.build`), stored, and shown at once when the map opens: a few hundred map elements
// instead of 50,000 photos.
//
// Privacy by construction (concept §8):
// - Home is only ever kept rounded to `MapHome.gridMeters` (`RoundedHome`).
// - Everyday photos at home never become a pin, a place or a record: every pin, place, route
//   point and record comes from the photos of a trip, and of those none taken at home
//   (`AssetFacts.atHome`, the home of their date) or within `MapHome.maximumRoundingMeters` of
//   today's home (`MapSummary.isDrawn`).
// - The share data (`ShareWorld`, `SharePassport`, `ShareYear`, `SharePostcard`) has no field for
//   home at all; arcs there start in the middle of the home country, never at home.
// - The diagnostics (`MapDiagnostics`) hold counts only, no coordinates.
//
// Honest numbers (concept §5): distances are great-circle ("Luftlinie") between photo places, shown
// rounded with "ca."; a record needs at least 3 photos at one place; photos taken in flight count
// for nothing (`AirborneFilter`).
//
// Here the days, the trip geometry and the rounded home; the world and the numbers are in
// `MapModel+World.swift`, the pins, arcs and summary in `MapModel+Pins.swift`, the share data in
// `MapModel+Share.swift`.

// MARK: - Days

/// A calendar day as the photo's place saw it: in the local time where it was taken (decision
/// Fuchs 19.11.2026, as Apple Photos), Gregorian.
public struct LocalDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day of `date` in `timeZone`.
    ///
    /// Plain day arithmetic on the zone's offset at that moment, no `Calendar`: the map works out
    /// the day of every photo, and making a calendar for each costs more than all the rest of a
    /// photo's work (`MapSummaryLoadTests`). Gives the Gregorian calendar's day
    /// (`localDayIsTheGregorianCalendarsDay` compares the two).
    public init(_ date: Date, timeZone: TimeZone) {
        let seconds = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        // A date no calendar can show (not a number, or millions of years away) is 1 January 1970.
        guard seconds.isFinite, abs(seconds) < 1e15 else {
            self.init(year: 1970, month: 1, day: 1)
            return
        }
        self.init(dayNumber: Int((seconds / 86_400).rounded(.down)))
    }

    /// The day of `date` where `place` is, or in `fallback` when the place has no known time zone.
    public init(_ date: Date, place: PlaceComponents?, fallback: TimeZone) {
        let zone = place?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? fallback
        self.init(date, timeZone: zone)
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    /// Days from `self` to `other` (`other` later: positive), counted as whole calendar days.
    public func days(to other: LocalDay) -> Int { other.dayNumber - dayNumber }

    /// Days since 1 January 1970 in the (proleptic) Gregorian calendar. A month or day out of
    /// range carries over as a calendar would: month 13 is January of the next year, day 0 the
    /// last day of the month before. After H. Hinnant's `days_from_civil`.
    var dayNumber: Int {
        let months = month - 1
        let carry = months >= 0 ? months / 12 : (months - 11) / 12
        let m = months - carry * 12 + 1
        let y = year + carry - (m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((m + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The day `dayNumber` days after 1 January 1970 (H. Hinnant's `civil_from_days`).
    init(dayNumber: Int) {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let month = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: dayOfYear - (153 * mp + 2) / 5 + 1)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

// MARK: - Trip geometry (where the photos of one trip were, day by day)

/// How many photos of a trip on the map were taken on one local day ("Meiste Fotos an einem Tag").
public struct TripDay: Hashable, Sendable, Codable {
    public var day: LocalDay
    /// The trip's photos of that day on the map (`TripGeometry.build`): with a location, not taken
    /// in flight, no screenshot, not at home. A photo the map does not draw counts in no record.
    public var photoCount: Int
    /// The place of most of that day's photos, if one has `TripGeometry.minimumPhotosPerPlace`.
    public var placeIndex: Int?

    public init(day: LocalDay, photoCount: Int, placeIndex: Int?) {
        self.day = day
        self.photoCount = photoCount
        self.placeIndex = placeIndex
    }
}

/// Where photos of one local day of a trip were taken: at least `TripGeometry.minimumPhotosPerPlace`
/// photos of that day within `TripGeometry.placeRadiusMeters`.
public struct DayPlace: Hashable, Sendable, Codable {
    /// A real photo location (the medoid of the photos), never a computed point that could lie in
    /// the sea.
    public var coordinate: GeoCoordinate
    public var day: LocalDay
    public var firstPhoto: Date
    public var lastPhoto: Date
    public var photoCount: Int
    /// The distinct place of the trip it belongs to (`TripGeometry.places`).
    public var placeIndex: Int

    public init(coordinate: GeoCoordinate, day: LocalDay, firstPhoto: Date, lastPhoto: Date, photoCount: Int, placeIndex: Int) {
        self.coordinate = coordinate
        self.day = day
        self.firstPhoto = firstPhoto
        self.lastPhoto = lastPhoto
        self.photoCount = photoCount
        self.placeIndex = placeIndex
    }
}

/// A distinct place of a trip: its day places within `TripGeometry.placeRadiusMeters` of each
/// other merged across days ("17 Orte").
public struct TripPlace: Hashable, Sendable, Codable {
    /// A real photo location (the medoid of the place's photos).
    public var coordinate: GeoCoordinate
    /// What the place is called, from the place names the analysis already stored: the point of
    /// interest when one names at least half of its photos ("Skógafoss"), otherwise the most
    /// common town, then district, region, country. `nil` when no name is known.
    public var name: String?
    /// ISO country code of most of its photos, or "disputed-<id>" in a disputed area.
    public var countryKey: String?
    public var photoCount: Int
    /// The local days it has photos on, oldest first.
    public var days: [LocalDay]
    /// Photos for its pin and for the stack when the trip is played: ordinary photos the image
    /// analysis has looked at (`PreviewRank.photo`), favourites first, then the largest, at most
    /// `TripGeometry.coverCandidateLimit`. The app shows only those it has sharp on the iPhone
    /// and never loads one from iCloud.
    public var coverCandidates: [AssetID]
    /// Metres above sea level: the mean of its highest photos that agree, those within
    /// `TripGeometry.altitudeSpreadMeters` below the highest one that has at least
    /// `TripGeometry.minimumPhotosPerPlace - 1` others that close. A summit with photos on the way
    /// up is as high as the photos at its top; altitudes above `AirborneFilter.maximumAltitude`
    /// (from planes) count as none. `nil` without such photos (no "Höchstes Foto" from it).
    public var altitude: Double?

    public init(coordinate: GeoCoordinate, name: String?, countryKey: String?, photoCount: Int, days: [LocalDay], coverCandidates: [AssetID],
                altitude: Double? = nil) {
        self.coordinate = coordinate
        self.name = name
        self.countryKey = countryKey
        self.photoCount = photoCount
        self.days = days
        self.coverCandidates = coverCandidates
        self.altitude = altitude
    }
}

/// One stop of the route: a visit to a place of the trip, in time order. A place visited twice
/// (back to the hotel) appears twice, never twice in a row. Photos taken in turn in two places
/// are no way anyone went (two cameras in one library) when nothing could travel between them in
/// the time (`AirborneFilter.maximumFlightSpeed`), or when the route would turn back right away
/// twice in a row (A → B → A → B), each way faster than 200 km/h as the crow flies and at most an
/// hour at each turn: the route passes each place of such a run once, at its first visit in the
/// run.
public struct RoutePoint: Hashable, Sendable, Codable {
    public var placeIndex: Int
    /// First and last photo of this visit.
    public var arrival: Date
    public var departure: Date
    /// The local day of `arrival`.
    public var day: LocalDay

    public init(placeIndex: Int, arrival: Date, departure: Date, day: LocalDay) {
        self.placeIndex = placeIndex
        self.arrival = arrival
        self.departure = departure
        self.day = day
    }
}

/// The straight line from one route point to the next: we know where photos were taken, not
/// which roads were driven (concept §4.3, "Ehrliche Linien").
public struct RouteLeg: Hashable, Sendable, Codable {
    /// Great-circle length. On a route cut to `TripGeometry.maxRoutePoints`: the lengths of all
    /// the legs between the visits it stands for added up (the visits the cut left out, an
    /// excursion from its first point and back), so `TripGeometry.metersOnSite` counts every leg.
    public var meters: Double
    /// Longer than `TripGeometry.gapMeters` with no photo for over `TripGeometry.gapDuration`:
    /// drawn grey and dotted with the label "ohne Fotos", so it does not read as a part of the trip.
    /// On a cut route: when more than half of its metres were.
    public var withoutPhotos: Bool

    public init(meters: Double, withoutPhotos: Bool) {
        self.meters = meters
        self.withoutPhotos = withoutPhotos
    }
}

/// Where one trip went: its day places, its distinct places, the route between them and the
/// place its arc points to. Built from the trip's own photos only (`TripGeometry.build`).
public struct TripGeometry: Hashable, Sendable, Codable, Identifiable {
    /// A place needs this many photos of one day (concept §5: also the rule for records, so a
    /// single wrong or received photo makes no place, no record and no country).
    public static let minimumPhotosPerPlace = 3
    /// Photos of one day this close count as one place; places of different days this close are
    /// one place of the trip.
    public static let placeRadiusMeters = 3_000.0
    /// A leg is "ohne Fotos" when it is longer than this ...
    public static let gapMeters = 100_000.0
    /// ... and no photo was taken for longer than this along it.
    public static let gapDuration: TimeInterval = 3 * 3_600
    /// At most this many route points per trip (concept §9).
    public static let maxRoutePoints = 200
    /// At most this many photos per place for its pin and stack.
    public static let coverCandidateLimit = 6
    /// A place's photos must agree on their altitude within this to give it one (`TripPlace.altitude`).
    public static let altitudeSpreadMeters = 150.0

    public var id: AlbumistID
    /// First and last dated photo of the trip, as its album shows them (those not on the map too).
    public var start: Date
    public var end: Date
    /// The time zone most of the trip's photos on the map were taken in (from their clocks and
    /// places), if known.
    public var timeZoneIdentifier: String?
    /// First and last local day of its dated photos, as its album shows them: each on the clock
    /// where it was taken, else in its place's zone, else in `timeZoneIdentifier` (else the
    /// device's time zone).
    public var firstDay: LocalDay
    public var lastDay: LocalDay
    /// Every photo of the trip once (an asset id listed twice counts once), as its album shows
    /// them: on the map, and without a location or date, screenshots, taken in flight or at home.
    public var photoCount: Int
    /// Every local day with photos on the map (`TripDay`), oldest first, each photo on its day as
    /// for `firstDay`. A day with photos only off the map (at home, without a location) has none.
    public var dayCounts: [TripDay]
    /// Oldest first.
    public var dayPlaces: [DayPlace]
    public var places: [TripPlace]
    /// At most `maxRoutePoints`, in time order.
    public var route: [RoutePoint]
    /// `route.count - 1` legs (none for fewer than two points).
    public var legs: [RouteLeg]
    /// The place with the most photos: where the trip's arc ends and its pin stands. `nil` when no
    /// place has `minimumPhotosPerPlace` photos of one day; `destination` is then the medoid of
    /// the trip's photos on the map (a real photo location, but no place: no record comes from
    /// it). Without a photo on the map, the trip's centre (`Trip.centroid`), unless one of its
    /// photos is at home: that centre may be home, so it is then 0, 0 (not `isPlausible`).
    public var destinationIndex: Int?
    public var destination: GeoCoordinate
    /// Photos on the map per country key (ISO code or "disputed-<id>"): none in flight or maybe in
    /// flight, at home or without a location.
    public var countryPhotos: [String: Int]
    /// The country key with the most photos (ties: the smaller key).
    public var mainCountryKey: String?
    /// Photos of the trip left out as taken in flight (`AirborneFilter`). Those maybe taken in
    /// flight (`FlightJudgement`) are left out as well, without being counted here.
    public var airborneCount: Int

    public init(id: AlbumistID, start: Date, end: Date, timeZoneIdentifier: String?, firstDay: LocalDay, lastDay: LocalDay, photoCount: Int,
                dayCounts: [TripDay] = [], dayPlaces: [DayPlace], places: [TripPlace], route: [RoutePoint], legs: [RouteLeg], destinationIndex: Int?,
                destination: GeoCoordinate, countryPhotos: [String: Int], mainCountryKey: String?, airborneCount: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.photoCount = photoCount
        self.dayCounts = dayCounts
        self.dayPlaces = dayPlaces
        self.places = places
        self.route = route
        self.legs = legs
        self.destinationIndex = destinationIndex
        self.destination = destination
        self.countryPhotos = countryPhotos
        self.mainCountryKey = mainCountryKey
        self.airborneCount = airborneCount
    }

    /// Calendar days from the first to the last local day, both included.
    public var days: Int { firstDay.days(to: lastDay) + 1 }

    /// "vor Ort": the legs between the places, in time order (not between all photo points, or
    /// GPS jitter would make the number grow), those a cut to `maxRoutePoints` left out too
    /// (`RouteLeg.meters`).
    public var metersOnSite: Double { legs.reduce(0) { $0 + $1.meters } }

    /// The route's coordinates, in time order.
    public var routeCoordinates: [GeoCoordinate] { route.map { places[$0.placeIndex].coordinate } }

    /// The name of the destination place, if it has one.
    public var destinationName: String? { destinationIndex.flatMap { places[$0].name } }
}

// MARK: - Home (rounded, never exact)

/// Where the user lived at a time, rounded to `MapHome.gridMeters`. The only form in which the map
/// keeps home. Shown in the app only (the house at 300 to 3,000 km view width, arcs starting
/// there), never on a share image.
public struct RoundedHome: Hashable, Sendable, Codable {
    /// The centre of the `MapHome.gridMeters` grid cell home lies in.
    public var coordinate: GeoCoordinate
    /// The ISO code of the country home lies in, if known.
    public var countryCode: String?

    public init(coordinate: GeoCoordinate, countryCode: String?) {
        self.coordinate = coordinate
        self.countryCode = countryCode
    }
}
