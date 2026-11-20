import Foundation
import SortlyCore

/// The years of the time travel and of the first look's waves (concept §3, moments 1 and 5;
/// §4.6 and §4.7), the moment "Neues Land" (moment 7, §4.9) and "Überrasch mich" (moment 8).
public enum MapYears {
    /// Every year from the first trip's to `year` (the year of `MapSummary.computedAt`), years
    /// without a trip included, oldest first; no trips: none.
    ///
    /// A trip belongs to the year of its start in `calendar`, the device's calendar (as
    /// `MapYear.year` says), not to the local day where it started: so the time travel, the
    /// numbers' "seit 2011" and the arcs' years all count it in the same year. A trip starting on
    /// 31 December at 23:30 in Lisbon (UTC) is a trip of the new year for a device in Germany and of
    /// the old one in New York. It counts in that year with all its days, photos and kilometres,
    /// even when it lasts into January.
    ///
    /// - `newCountries`: first visited in the year (`MapCountry.firstVisitYear`), first
    ///   visit order.
    /// - `countriesSoFar`: first visited up to the end of the year, including countries visited
    ///   before the first trip (the home country from everyday photos).
    /// - `tripsSoFar`: trips started up to the end of the year.
    /// - `daysAway`, `photoCount`, `metersTraveled`: the year's trips added up (`TripGeometry.days`,
    ///   `TripGeometry.photoCount`, `TripStats.metersTraveled`).
    /// Trips and countries dated after `year` (a camera clock set wrong) are in no year; when even
    /// the first trip is, there are no years.
    public static func compute(trips: [MapTrip], countries: [MapCountry], calendar: Calendar, through year: Int) -> [MapYear] {
        let trips = chronological(trips)
        let tripYears = trips.map { calendar.component(.year, from: $0.geometry.start) }
        guard let first = tripYears.min(), first <= year else { return [] }
        // Indices into `trips` per year, oldest first.
        var tripsOfYear: [Int: [Int]] = [:]
        for (index, tripYear) in tripYears.enumerated() where tripYear <= year { tripsOfYear[tripYear, default: []].append(index) }
        var newOfYear: [Int: [String]] = [:]
        var countriesSoFar = 0
        for country in MapCountries.inFirstVisitOrder(countries) {
            let visitYear = country.firstVisitYear
            if visitYear < first { countriesSoFar += 1 } else { newOfYear[visitYear, default: []].append(country.code) }
        }
        var years: [MapYear] = []
        years.reserveCapacity(year - first + 1)
        var tripsSoFar = 0
        for y in first...year {
            var entry = MapYear(year: y, tripIDs: [], newCountries: newOfYear[y] ?? [], countriesSoFar: 0, tripsSoFar: 0, daysAway: 0,
                                photoCount: 0, metersTraveled: 0)
            for index in tripsOfYear[y] ?? [] {
                let trip = trips[index]
                entry.tripIDs.append(trip.id)
                entry.daysAway += trip.geometry.days
                entry.photoCount += trip.geometry.photoCount
                entry.metersTraveled += TripStats.finiteMeters(trip.stats.metersTraveled)
            }
            tripsSoFar += entry.tripIDs.count
            countriesSoFar += entry.newCountries.count
            entry.tripsSoFar = tripsSoFar
            entry.countriesSoFar = countriesSoFar
            years.append(entry)
        }
        return years
    }

    /// The moment "Neues Land" ("Großbritannien ist dein 14. Land"): the countries the user has
    /// not seen on the map yet, first visit order. `seen` holds the codes the map showed when it
    /// was last open; `nil` when it was never opened: the first look shows everything, so there
    /// is no moment then. An empty `seen` (opened before any country) makes every country new.
    /// `ordinal` is the country's place in the first visit order of all countries, from 1;
    /// `tripID` the first of its trips.
    public static func newCountries(since seen: Set<String>?, countries: [MapCountry]) -> [NewCountryEvent] {
        guard let seen else { return [] }
        let seenCodes = Set(seen.map { $0.uppercased() })
        return MapCountries.inFirstVisitOrder(countries).enumerated().compactMap { index, country in
            seenCodes.contains(country.code.uppercased()) ? nil
                : NewCountryEvent(code: country.code, ordinal: index + 1, firstVisit: country.firstVisit, tripID: country.tripIDs.first)
        }
    }

    /// A trip looked at within this time before `now` is no surprise (a week).
    static let recentViewInterval: TimeInterval = 7 * 86_400
    /// "Überrasch mich" picks among at least this many of the trips not looked at for longest ...
    static let surprisePoolMinimum = 3
    /// ... or this share of all its trips, if more (20 %, rounded up).
    static let surprisePoolPercent = 20

    /// "Überrasch mich" (moment 8): a trip the user has not looked at for a long time.
    ///
    /// Among the trips with at least one place (something to fly to), ordered by how long they
    /// were not looked at (never first, then the oldest look in `lastViewed`, then the older trip,
    /// then the smaller id), it takes the first max(3, 20 %) and picks one of them with `seed`
    /// (SplitMix64), so the same seed gives the same trip and the app varies the seed per tap.
    /// A trip looked at within `recentViewInterval` before `now` (or, with a clock set back,
    /// after it) is never picked while any other trip is older: it leaves the pool. When every
    /// trip was looked at that recently, the one looked at longest ago is taken, so tapping again
    /// and again goes round all trips. `nil` without a trip with a place.
    public static func surpriseTrip(trips: [MapTrip], lastViewed: [SortlyID: Date], now: Date, seed: UInt64) -> SortlyID? {
        let candidates = trips.filter { !$0.geometry.places.isEmpty }
        guard !candidates.isEmpty else { return nil }
        let keys = candidates.map { staleness($0, lastViewed) }
        let ordered = candidates.indices.sorted { keys[$0] < keys[$1] }.map { candidates[$0] }
        let recentSince = now.addingTimeInterval(-recentViewInterval)
        // Never looked at, then looked at before `recentSince`: a prefix of `ordered`.
        let stale = ordered.prefix { lastViewed[$0.id].map { $0 < recentSince } ?? true }
        guard !stale.isEmpty else { return ordered[0].id }
        let share = (candidates.count * surprisePoolPercent + 99) / 100
        let pool = stale.prefix(max(surprisePoolMinimum, share))
        let pick = Int(splitMix64(seed) % UInt64(pool.count))
        return pool[pool.startIndex + pick].id
    }

    // MARK: Helpers

    /// `trips` by start, then id: a total order, whatever order they come in, so sums of their
    /// kilometres come out the same to the last digit and ties are broken the same way.
    static func chronological(_ trips: [MapTrip]) -> [MapTrip] {
        // Sorted by index on keys taken once, so the comparisons do not copy whole trips.
        let keys = trips.map { ($0.geometry.start, $0.id.rawValue) }
        return trips.indices.sorted { keys[$0] < keys[$1] }.map { trips[$0] }
    }

    /// How long `trip` was not looked at, as a sort key: never first (by the trip's start), then
    /// the oldest look, then the older trip, then the smaller id.
    private static func staleness(_ trip: MapTrip, _ lastViewed: [SortlyID: Date]) -> (Int, Date, Date, String) {
        if let viewed = lastViewed[trip.id] { return (1, viewed, trip.geometry.start, trip.id.rawValue) }
        return (0, .distantPast, trip.geometry.start, trip.id.rawValue)
    }

    /// SplitMix64 (Steele, Lea, Flood 2014): one well-mixed number per seed, the same on every
    /// platform (unlike `Hasher`, which is seeded per process).
    static func splitMix64(_ seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
