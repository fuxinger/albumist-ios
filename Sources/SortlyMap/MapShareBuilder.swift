import Foundation
import SortlyCore

// The data of the four share motifs (concept §4.11). Privacy by construction (concept §8): the
// share types have no field for home, and home enters here only to keep things away from it.
// Nothing on a share image comes from within `MapShare.nearHomeMeters` of the home of its trip's
// time or of today's home: no point, no arc end, no route point, no photo and no place name. Arcs
// start in the middle of the home country (the same point for everyone living there), and not at
// all when that country is small or not known (`CountryGeometry.shareOrigin`).

extension MapShare {
    /// Nothing on a share image comes from closer to home than this (concept §8: "Reisen näher als
    /// 50 km am Zuhause bekommen auf der Postkarte keine Route"). Measured from the rounded home,
    /// the only one the summary keeps; it lies within half a grid cell of the real one, little
    /// against 50 km.
    public static let nearHomeMeters = 50_000.0

    /// Motif A, "Weltkarte". The numbers are the summary's (`numbers`), so the image says what the
    /// app says. Arcs: one per trip with a home of its time whose country has a share origin
    /// (known and not small) and whose destination may be shown, from the middle of that country
    /// to the destination; trips from one country to destinations within `MapArcs.mergeMeters`
    /// share one arc (grouped as `MapArcs.build` does), at most `MapSummary.maxArcs`, the strongest
    /// and newest. Destinations: every trip's destination that may be shown, one point for those
    /// within `MapArcs.mergeMeters` of each other (the one of the trip with the most photos).
    public static func world(_ summary: MapSummary, geometry: CountryGeometry) -> ShareWorld {
        let numbers = summary.numbers
        var points = MapArcs.Clusters(radiusMeters: MapArcs.mergeMeters)
        var ends = MapArcs.Clusters(radiusMeters: MapArcs.mergeMeters)
        var origins: [String: Int] = [:]
        // One per leader of `ends`, at the same index.
        var arcs: [ShareBuilding.ArcGroup] = []
        for trip in MapArcs.byLeadership(summary.trips) {
            let destination = trip.geometry.destination
            guard ShareBuilding.mayShow(destination, of: trip, today: summary.home) else { continue }
            _ = points.assign(destination)
            guard let code = trip.home?.countryCode?.uppercased(), let origin = geometry.shareOrigin(countryCode: code) else { continue }
            let space: Int
            if let known = origins[code] {
                space = known
            } else {
                space = origins.count
                origins[code] = space
            }
            let assignment = ends.assign(destination, space: space)
            if assignment.isNew {
                arcs.append(ShareBuilding.ArcGroup(arc: ShareArc(from: origin, to: destination, weight: 1), newest: trip.geometry.start,
                                                   leader: trip.id.rawValue))
            } else {
                arcs[assignment.leader].arc.weight += 1
                arcs[assignment.leader].newest = max(arcs[assignment.leader].newest, trip.geometry.start)
            }
        }
        // Stronger first, then the one with the more recent trip, then the smaller leading trip id
        // (as `MapArcs.build` keeps its arcs).
        let kept = arcs.sorted { a, b in
            if a.arc.weight != b.arc.weight { return a.arc.weight > b.arc.weight }
            if a.newest != b.newest { return a.newest > b.newest }
            return a.leader < b.leader
        }
        // Continents as the app counts them (`numbers.continents`, the six inhabited ones).
        let continents = Set(numbers.continents.filter { $0.visited > 0 && $0.continent != .antarctica }.map(\.continent)).count
        return ShareWorld(countries: ShareBuilding.byFirstVisit(summary.countries).map(\.code), states: numbers.states, tripCount: numbers.trips,
                          sinceYear: numbers.firstTripYear, kilometers: MapDistance.roundedKilometers(numbers.metersTraveled),
                          continents: continents, worldShare: numbers.worldShare, arcs: kept.prefix(MapSummary.maxArcs).map(\.arc),
                          destinations: points.leaders)
    }

    /// Motif B, "Reisepass": a stamp per country in first visit order, with the year of the first
    /// visit as the time travel and the numbers give it (`MapCountry.firstVisitYear`, in the
    /// device's calendar like the travel atlas). `newCountries` (ISO codes) are drawn as the
    /// newest stamps (moment "Neues Land").
    public static func passport(_ summary: MapSummary, newCountries: Set<String> = []) -> SharePassport {
        let fresh = Set(newCountries.map { $0.uppercased() })
        let stamps = ShareBuilding.byFirstVisit(summary.countries).map { country in
            SharePassport.Stamp(countryCode: country.code, year: country.firstVisitYear,
                                isNew: fresh.contains(country.code.uppercased()))
        }
        return SharePassport(stamps: stamps, sinceYear: summary.numbers.firstCountryYear, tripCount: summary.numbers.trips)
    }

    /// Motif C, "Mein Reisejahr", from the year's entry in `summary.years`; `nil` without a trip
    /// that year. Photos: each trip's best photo first (its destination's first candidate), the
    /// trips with the most photos first, then the others in turn, never from a place near home.
    public static func year(_ year: Int, of summary: MapSummary) -> ShareYear? {
        guard let entry = summary.years.first(where: { $0.year == year }), !entry.tripIDs.isEmpty else { return nil }
        let trips = ShareBuilding.tripsByID(summary.trips)
        let photos = ShareBuilding.photos(of: entry.tripIDs.compactMap { trips[$0.rawValue] }, today: summary.home)
        return ShareYear(year: year, newCountries: entry.newCountries, kilometers: MapDistance.roundedKilometers(entry.metersTraveled),
                         earth: EarthComparison(meters: entry.metersTraveled), tripCount: entry.tripIDs.count, daysAway: entry.daysAway,
                         photoCount: entry.photoCount, photos: photos)
    }

    /// Motif D, "Reise-Postkarte"; `nil` for a trip the summary does not have. The country is the
    /// trip's main one, none in a disputed area ("nicht sicher" is no flag). The route keeps only
    /// the points that may be shown, and none when fewer than two are left ("Reisen näher als
    /// 50 km am Zuhause bekommen keine Route"). The title is the trip's own name, which the user
    /// chose to share.
    public static func postcard(for tripID: SortlyID, in summary: MapSummary) -> SharePostcard? {
        guard let trip = summary.trips.filter({ $0.id == tripID }).min(by: MapArcs.leads) else { return nil }
        let geometry = trip.geometry
        var route: [GeoCoordinate] = []
        for point in geometry.route where geometry.places.indices.contains(point.placeIndex) {
            let coordinate = geometry.places[point.placeIndex].coordinate
            // Without the points near home, a place left on both sides of them is not drawn twice
            // in a row.
            guard ShareBuilding.mayShow(coordinate, of: trip, today: summary.home), route.last != coordinate else { continue }
            route.append(coordinate)
        }
        let countryCode = geometry.mainCountryKey.flatMap { $0.hasPrefix(ShareBuilding.disputedPrefix) ? nil : $0 }
        return SharePostcard(title: trip.title, countryCode: countryCode, year: geometry.firstDay.year, month: geometry.firstDay.month,
                             days: geometry.days, photoCount: geometry.photoCount, placeCount: geometry.places.count,
                             kilometers: MapDistance.roundedKilometers(trip.stats.metersOnSite), route: route.count >= 2 ? route : [],
                             photos: ShareBuilding.tripPhotos(trip, today: summary.home))
    }
}

private enum ShareBuilding {
    /// How a disputed area's key begins (`TripPlace.countryKey`, as the atlas keys it).
    static let disputedPrefix = "disputed-"

    /// Whether a share image may show `coordinate` of `trip`: a real place at least
    /// `MapShare.nearHomeMeters` from the home of the trip's time and from today's home. Today's
    /// home counts for every trip: a trip from an earlier home, or one without a known home, may
    /// have gone to where the user lives now.
    static func mayShow(_ coordinate: GeoCoordinate, of trip: MapTrip, today: RoundedHome?) -> Bool {
        guard coordinate.isPlausible else { return false }
        for home in [trip.home, today] {
            guard let home else { continue }
            // A home that is no place on Earth cannot be measured from (`GeoMath.distance` takes a
            // coordinate that is no number for the far side of the Earth), so it keeps everything
            // off the image: without data, privacy wins.
            guard home.coordinate.isPlausible, GeoMath.distance(coordinate, home.coordinate) >= MapShare.nearHomeMeters else { return false }
        }
        return true
    }

    /// An arc while its trips are grouped: the arc, its most recent trip, the trip it ends at.
    struct ArcGroup: Sendable {
        var arc: ShareArc
        var newest: Date
        var leader: String
    }

    /// Countries in first visit order (a tie: the smaller code), a repeated code (the summary never
    /// has one) kept once: its earliest first visit. Never a disputed area, which is no country
    /// (decision 18.11.2026), even if one came in: it would get a stamp.
    static func byFirstVisit(_ countries: [MapCountry]) -> [MapCountry] {
        let ordered = countries
            .filter { !$0.code.hasPrefix(disputedPrefix) }
            .sorted { ($0.firstVisit, $0.code) < ($1.firstVisit, $1.code) }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.code).inserted }
    }

    /// The trips by id, a repeated id kept once (as `MapArcs.byLeadership` keeps it), in one pass.
    static func tripsByID(_ trips: [MapTrip]) -> [String: MapTrip] {
        var byID: [String: MapTrip] = [:]
        for trip in trips {
            if let kept = byID[trip.id.rawValue], !MapArcs.leads(trip, before: kept) { continue }
            byID[trip.id.rawValue] = trip
        }
        return byID
    }

    /// The photos of `trips` for a share image, best first: each trip's best photo, the trips with
    /// the most photos first (then the earlier, then the smaller id), then each trip's second
    /// best, and so on.
    static func photos(of trips: [MapTrip], today: RoundedHome?) -> [SharePhoto] {
        inTurn(MapArcs.byLeadership(trips).map { tripPhotos($0, today: today) })
    }

    /// The photos of one trip, best first: its destination's first candidate, then the first
    /// candidate of each other place (most photos first, a tie: the lower index), then the second
    /// of each, and so on: one photo of each place before a second of any. Never from a place
    /// a share image may not show.
    static func tripPhotos(_ trip: MapTrip, today: RoundedHome?) -> [SharePhoto] {
        let places = trip.geometry.places
        let destination = trip.geometry.destinationIndex
        let shown = places.indices
            .filter { mayShow(places[$0].coordinate, of: trip, today: today) }
            .sorted { a, b in
                if (a == destination) != (b == destination) { return a == destination }
                if places[a].photoCount != places[b].photoCount { return places[a].photoCount > places[b].photoCount }
                return a < b
            }
        return inTurn(shown.map { index in places[index].coverCandidates.map { SharePhoto(asset: $0, placeName: places[index].name) } })
    }

    /// The first of each list, then the second of each, and so on; a photo already taken is left
    /// out.
    static func inTurn(_ lists: [[SharePhoto]]) -> [SharePhoto] {
        var result: [SharePhoto] = []
        var taken = Set<AssetID>()
        for round in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where round < list.count {
                if taken.insert(list[round].asset).inserted { result.append(list[round]) }
            }
        }
        return result
    }
}
