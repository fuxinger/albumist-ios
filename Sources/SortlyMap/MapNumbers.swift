import Foundation
import SortlyCore

// MARK: - One trip

extension TripStats {
    /// The numbers of one trip, all great-circle ("Luftlinie", concept §5 "Begriffe, überall
    /// gleich"), from `home`, the rounded home of the trip's time (`MapTrip.home`):
    /// - "vor Ort": the legs between its places in time order (`TripGeometry.metersOnSite`).
    /// - "unterwegs": on site plus the way from home to the first route point and from the last
    ///   one back. A trip without a route goes from home to its destination and back. Without a
    ///   home: on site only (concept §11, "Kein Zuhause bekannt: km nur vor Ort").
    /// - "von zu Hause": the place farthest from home, or the destination when the trip has no
    ///   place; `nil` without a home.
    public static func compute(_ geometry: TripGeometry, home: RoundedHome?) -> TripStats {
        let onSite = geometry.metersOnSite
        guard let home else { return TripStats(metersOnSite: onSite, metersTraveled: onSite, metersFromHome: nil) }
        let from = home.coordinate
        let fromHome = geometry.places.isEmpty
            ? greatCircleMeters(from, geometry.destination)
            : geometry.places.reduce(0) { max($0, greatCircleMeters(from, $1.coordinate)) }
        // A route point always names one of the trip's places; should one not, the trip counts
        // as having no route rather than reading past its places.
        let way: Double
        if let first = geometry.route.first.flatMap({ place(of: geometry, at: $0.placeIndex) }),
           let last = geometry.route.last.flatMap({ place(of: geometry, at: $0.placeIndex) }) {
            way = greatCircleMeters(from, first.coordinate) + greatCircleMeters(last.coordinate, from)
        } else {
            way = 2 * greatCircleMeters(from, geometry.destination)
        }
        return TripStats(metersOnSite: onSite, metersTraveled: onSite + way, metersFromHome: fromHome)
    }
}

// MARK: - Deine Welt in Zahlen

extension WorldNumbers {
    /// Every number of "Deine Welt in Zahlen" (concept §5) from the map's trips and countries.
    ///
    /// - Counts: `countries` all of them (territories too), `states` those of the 195, the world
    ///   share `states / 195`, per inhabited continent its states of the 195 ("Europa 12 von 46").
    /// - Years are Gregorian years of local days, as the app's albums count them: a trip's is the
    ///   year of its first local day (`TripGeometry.firstDay`), a country's that of its first
    ///   visit on the clock where the photo was taken (`MapCountry.firstVisitYear`). So a trip
    ///   that starts on New Year's Eve in New York is one of the old year, wherever the iPhone is
    ///   now, and stamp, time travel, arcs and postcard agree. `firstTripYear` is the earliest
    ///   trip's year, `firstCountryYear` the earliest first visit's; `year` is the year of `now`
    ///   in `timeZone` (the device's), with the countries first visited in it (`newThisYear`,
    ///   first visit order).
    /// - Distances: the trips' `stats` added up (in the trips' time order, so the same trips in any
    ///   order give the same last digit), and the Earth comparison of "unterwegs".
    /// - Records, the longest trip, the day with the most photos and the favourite country: see
    ///   `records(of:)`, `longestTrip(of:)`, `mostPhotosInADay(of:)` and `favoriteCountry(of:)`.
    ///
    /// The result is `isPreliminary` while the analysis runs; `holdingHighs(over:)` then keeps
    /// every number from going down.
    public static func compute(trips: [MapTrip], countries: [MapCountry], cities: Int, timeZone: TimeZone, now: Date,
                               analysisRunning: Bool) -> WorldNumbers {
        let trips = MapYears.chronological(trips)
        let countries = MapCountries.inFirstVisitOrder(countries)
        let states = countries.filter(\.isState)
        var numbers = WorldNumbers()
        numbers.countries = countries.count
        numbers.states = states.count
        numbers.worldShare = min(1, Double(states.count) / Double(WorldStates.codes.count))
        numbers.continents = inhabitedContinents.map { continent in
            ContinentTally(continent: continent, visited: states.count { $0.continent == continent }, total: WorldStates.count(on: continent))
        }
        numbers.cities = cities
        numbers.trips = trips.count
        // The smallest year rather than the first trip's: a trip that starts a little later can
        // still begin on an earlier local day, across the date line.
        numbers.firstTripYear = trips.map(\.geometry.firstDay.year).min()
        numbers.firstCountryYear = countries.min { ($0.firstVisit, $0.code) < ($1.firstVisit, $1.code) }?.firstVisitYear
        numbers.metersTraveled = trips.reduce(0) { $0 + TripStats.finiteMeters($1.stats.metersTraveled) }
        numbers.metersOnSite = trips.reduce(0) { $0 + TripStats.finiteMeters($1.stats.metersOnSite) }
        numbers.earth = EarthComparison(meters: numbers.metersTraveled)
        numbers.records = records(of: trips)
        if let longest = longestTrip(of: trips) {
            numbers.longestTripID = longest.id
            numbers.longestTripDays = longest.days
        }
        numbers.mostPhotosInADay = mostPhotosInADay(of: trips)
        numbers.favoriteCountry = favoriteCountry(of: trips)
        let year = LocalDay(now, timeZone: timeZone).year
        numbers.year = year
        numbers.newThisYear = countries.filter { $0.firstVisitYear == year }.map(\.code)
        numbers.isPreliminary = analysisRunning
        return numbers
    }

    /// The six inhabited continents in `Continent` order: Antarctica has no state (concept §5).
    static let inhabitedContinents = Continent.allCases.filter { $0 != .antarctica }

    // MARK: Records

    /// "Weitester Ort", "Nördlichster Ort", ... (concept §5, "Regeln für Rekorde"). Only the
    /// trips' `places` qualify: each has at least `TripGeometry.minimumPhotosPerPlace` photos of
    /// one day and no photo taken in flight (the geometry's rule), so neither a single wrong
    /// photo, nor a trip's mere destination, nor an everyday photo at home makes a record.
    /// - farthest: the largest great-circle distance from the trip's home (trips with a home only).
    /// - northernmost and southernmost: the largest and the smallest latitude.
    /// - easternmost and westernmost: the largest and the smallest longitude. Plain longitude, as
    ///   the atlas shows it: across the antimeridian Fiji (178° E) is the easternmost and Samoa
    ///   (172° W) the westernmost, though Samoa lies just east of Fiji.
    /// - highest: the largest `TripPlace.altitude`, from places that have one.
    /// Ties go to the earlier trip start, then the smaller trip id, then the lower place index.
    /// A place without a plausible coordinate is skipped. One record per kind, in
    /// `MapRecord.Kind` order; a kind no place qualifies for is missing.
    static func records(of trips: [MapTrip]) -> [MapRecord] {
        var board = RecordBoard()
        for t in trips.indices {
            let home = trips[t].home?.coordinate
            let places = trips[t].geometry.places
            for p in places.indices {
                let c = places[p].coordinate
                guard c.isPlausible else { continue }
                if let home { RecordBoard.offer(&board.farthest, GeoMath.distance(home, c), .farthest, trip: t, place: p) }
                RecordBoard.offer(&board.northernmost, c.latitude, .northernmost, trip: t, place: p)
                RecordBoard.offer(&board.southernmost, c.latitude, .southernmost, trip: t, place: p)
                RecordBoard.offer(&board.easternmost, c.longitude, .easternmost, trip: t, place: p)
                RecordBoard.offer(&board.westernmost, c.longitude, .westernmost, trip: t, place: p)
                if let altitude = places[p].altitude { RecordBoard.offer(&board.highest, altitude, .highest, trip: t, place: p) }
            }
        }
        return MapRecord.Kind.allCases.compactMap { kind in
            board.best(kind).map { best in
                let trip = trips[best.trip]
                let place = trip.geometry.places[best.place]
                return MapRecord(kind: kind, tripID: trip.id, placeIndex: best.place, placeName: place.name, coordinate: place.coordinate,
                                 day: place.days.min() ?? trip.geometry.firstDay, value: best.value)
            }
        }
    }

    /// The trip with the most days (`TripGeometry.days`); a tie goes to the more recent start
    /// (as the atlas, `TravelAtlas.longestTrip`), then to the smaller id.
    static func longestTrip(of trips: [MapTrip]) -> (id: SortlyID, days: Int)? {
        // Keys taken once per trip, not per comparison.
        let keys = trips.map { (days: $0.geometry.days, start: $0.geometry.start, id: $0.id) }
        let longest = keys.max { a, b in
            if a.days != b.days { return a.days < b.days }
            if a.start != b.start { return a.start < b.start }
            return a.id.rawValue > b.id.rawValue
        }
        return longest.map { ($0.id, $0.days) }
    }

    /// "Meiste Fotos an einem Tag": the trip day (local time, decision 19.11.2026) with the most
    /// photos; a tie goes to the earlier day, then to the smaller trip id. Named after the place
    /// of most of that day's photos, if it has a name. `nil` when no trip has a day with photos.
    static func mostPhotosInADay(of trips: [MapTrip]) -> DayRecord? {
        var best: (photos: Int, day: LocalDay, tripID: String, trip: Int, index: Int)?
        for t in trips.indices {
            let tripID = trips[t].id.rawValue
            let dayCounts = trips[t].geometry.dayCounts
            for d in dayCounts.indices {
                let photos = dayCounts[d].photoCount, day = dayCounts[d].day
                guard photos > 0 else { continue }
                if let current = best, photos < current.photos || (photos == current.photos && (day, tripID) >= (current.day, current.tripID)) {
                    continue
                }
                best = (photos, day, tripID, t, d)
            }
        }
        return best.map { best in
            let trip = trips[best.trip]
            let day = trip.geometry.dayCounts[best.index]
            return DayRecord(tripID: trip.id, day: day.day, photoCount: day.photoCount,
                             placeName: day.placeIndex.flatMap { TripStats.place(of: trip.geometry, at: $0) }?.name)
        }
    }

    /// "Lieblingsland" (concept §5): the country with the most trips abroad, a trip counting for
    /// each country (ISO code, never a disputed area) it has at least
    /// `TripGeometry.minimumPhotosPerPlace` photos in (`TripGeometry.countryPhotos`), except the
    /// country of the home of its time, which would almost always win. "Abroad" follows the home
    /// of each trip's time: after a move from Germany to Austria a trip to Germany is abroad, and
    /// trips to Austria from before the move still count. A trip whose home country is unknown
    /// takes the most common known home country of
    /// all trips (a tie: the smaller code). When no trip has a known home country there is no
    /// favourite: without a home there is no "abroad". A tie goes to more photos there (summed
    /// over those trips), then to the smaller code.
    static func favoriteCountry(of trips: [MapTrip]) -> FavoriteCountry? {
        var homes: [String: Int] = [:]
        for trip in trips {
            if let code = MapCountries.isoCode(trip.home?.countryCode) { homes[code, default: 0] += 1 }
        }
        guard let usualHome = homes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        var tally: [String: (trips: Int, photos: Int)] = [:]
        for trip in trips {
            let home = MapCountries.isoCode(trip.home?.countryCode) ?? usualHome
            // Per code first: a key in another case is the same country, and the trip counts once.
            var photos: [String: Int] = [:]
            for (key, count) in trip.geometry.countryPhotos {
                if let code = MapCountries.isoCode(key), code != home { photos[code, default: 0] += count }
            }
            for (code, count) in photos where count >= TripGeometry.minimumPhotosPerPlace {
                tally[code, default: (0, 0)].trips += 1
                tally[code, default: (0, 0)].photos += count
            }
        }
        return tally
            .max { ($0.value.trips, $0.value.photos, $1.key) < ($1.value.trips, $1.value.photos, $0.key) }
            .map { FavoriteCountry(code: $0.key, tripCount: $0.value.trips, photoCount: $0.value.photos) }
    }

    // MARK: Holding highs

    /// While the analysis runs (`isPreliminary`, "bisher" in the app), no number is shown smaller
    /// than in `previous`, the numbers shown before (concept §5: "Zahlen springen nicht zurück,
    /// solange die Analyse läuft"):
    /// - counts and sums keep the larger value: countries, states, world share, each continent's
    ///   visited states, cities, trips, both distances (the Earth comparison follows "unterwegs");
    /// - a record kind missing now keeps the previous record; farthest and highest keep the larger
    ///   value, northernmost and easternmost the larger, southernmost and westernmost the smaller;
    /// - "seit 2011" keeps the earlier year (`firstTripYear`, `firstCountryYear`).
    /// On equal values the current one stands. What is no number stays current: `year`,
    /// `newThisYear` (a country can rightly stop being new when an older visit turns up) and the
    /// totals per continent.
    ///
    /// What is kept must still be true of what it leads to. With `trips` (the summary's trips
    /// now), a previous record is kept only while its trip still has a place where the record's
    /// place was (`relocated`), and then leads to that place: the running analysis numbers a
    /// trip's places anew as photos arrive, and splits and merges trips, so its old index may name
    /// another place. The longest trip, the day with the most photos (with `trips`) and the
    /// favourite country (with `countries`) are then always the current ones: a kept one would
    /// name a trip, a day or a country that no longer has its number ("14 Tage" opening a trip of
    /// 6 days), and they only drop when the analysis splits a trip or moves its photos. Without
    /// them (the lists are not known), those are held like the counts. Lists (trips, countries,
    /// years, pins) are always the current ones, and share images take their numbers from those
    /// lists (`MapShare`), so an image never says "3 Länder" over two flags.
    ///
    /// Not preliminary (the analysis is complete), or without `previous`: `self`, unchanged.
    /// After deleting photos, correcting a trip or changing home, numbers may go down, and that
    /// is honest (concept §5).
    public func holdingHighs(over previous: WorldNumbers?, trips shownTrips: [MapTrip]? = nil,
                             countries shownCountries: [MapCountry]? = nil) -> WorldNumbers {
        guard isPreliminary, let previous else { return self }
        var held = self
        held.countries = max(countries, previous.countries)
        held.states = max(states, previous.states)
        held.worldShare = Self.larger(worldShare, previous.worldShare)
        held.continents = continents.map { tally in
            var tally = tally
            if let before = previous.continents.first(where: { $0.continent == tally.continent }) {
                tally.visited = max(tally.visited, before.visited)
            }
            return tally
        }
        held.cities = max(cities, previous.cities)
        held.trips = max(trips, previous.trips)
        held.firstTripYear = Self.earlier(firstTripYear, previous.firstTripYear)
        held.firstCountryYear = Self.earlier(firstCountryYear, previous.firstCountryYear)
        held.metersTraveled = Self.larger(metersTraveled, previous.metersTraveled)
        held.metersOnSite = Self.larger(metersOnSite, previous.metersOnSite)
        held.earth = EarthComparison(meters: held.metersTraveled)
        held.records = MapRecord.Kind.allCases.compactMap { kind in
            var before = previous.record(kind)
            if let shownTrips, let record = before { before = Self.relocated(record, in: shownTrips) }
            switch (record(kind), before) {
            case let (now?, before?): return RecordBoard.beats(before.value, now.value, kind: kind) ? before : now
            case let (now, before): return now ?? before
            }
        }
        if shownTrips == nil {
            if let days = previous.longestTripDays, days > (longestTripDays ?? .min) {
                held.longestTripID = previous.longestTripID
                held.longestTripDays = days
            }
            if let before = previous.mostPhotosInADay, before.photoCount > (mostPhotosInADay?.photoCount ?? .min) {
                held.mostPhotosInADay = before
            }
        }
        if shownCountries == nil, let before = previous.favoriteCountry,
           favoriteCountry.map({ (before.tripCount, before.photoCount) > ($0.tripCount, $0.photoCount) }) ?? true {
            held.favoriteCountry = before
        }
        return held
    }

    /// `record` leading to the place of its trip in `trips` where its place was: the nearest place
    /// within `TripGeometry.placeRadiusMeters` of the record's point, ties to the lower index, with
    /// that place's index, name, point and day (the record's day if the place still has photos on
    /// it, else its first); its value stays. Nil when its trip is gone or has no place there.
    static func relocated(_ record: MapRecord, in trips: [MapTrip]) -> MapRecord? {
        guard let trip = trips.first(where: { $0.id == record.tripID }) else { return nil }
        var nearest: (index: Int, meters: Double)?
        for (index, place) in trip.geometry.places.enumerated() {
            let meters = GeoMath.distance(place.coordinate, record.coordinate)
            if meters <= TripGeometry.placeRadiusMeters && meters < (nearest?.meters ?? .infinity) { nearest = (index, meters) }
        }
        guard let nearest else { return nil }
        let place = trip.geometry.places[nearest.index]
        var relocated = record
        relocated.placeIndex = nearest.index
        relocated.placeName = place.name
        relocated.coordinate = place.coordinate
        relocated.day = place.days.contains(record.day) ? record.day : (place.days.min() ?? record.day)
        return relocated
    }

    /// The larger of two values, a broken one (NaN) never winning.
    private static func larger(_ a: Double, _ b: Double) -> Double {
        a.isNaN ? b : (b.isNaN ? a : max(a, b))
    }

    private static func earlier(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case let (a?, b?): min(a, b)
        case let (a, b): a ?? b
        }
    }
}

// MARK: - Helpers
//
// Kept inside the types this file extends: a file-private name at the top level would clash
// with the same name declared anywhere else in the module.

extension WorldNumbers {
    /// The best place per record kind while the places are walked.
    fileprivate struct RecordBoard {
        struct Best {
            var value: Double
            /// Index into the trips, which are in chronological order (start, then id).
            var trip: Int
            var place: Int
        }

        var farthest, northernmost, southernmost, easternmost, westernmost, highest: Best?

        func best(_ kind: MapRecord.Kind) -> Best? {
            switch kind {
            case .farthest: farthest
            case .northernmost: northernmost
            case .southernmost: southernmost
            case .easternmost: easternmost
            case .westernmost: westernmost
            case .highest: highest
            }
        }

        /// Whether `value` makes a better record of `kind` than `other`: farther, more northern,
        /// more eastern, higher; or more southern, more western.
        static func beats(_ value: Double, _ other: Double, kind: MapRecord.Kind) -> Bool {
            switch kind {
            case .farthest, .northernmost, .easternmost, .highest: value > other
            case .southernmost, .westernmost: value < other
            }
        }

        /// Takes `value` as the record of `kind` when it beats `best`, or equals it from an earlier
        /// trip or a lower place index (the tie rule of `WorldNumbers.records(of:)`).
        static func offer(_ best: inout Best?, _ value: Double, _ kind: MapRecord.Kind, trip: Int, place: Int) {
            guard value.isFinite else { return }
            if let current = best {
                let tie = value == current.value && (trip, place) < (current.trip, current.place)
                guard beats(value, current.value, kind: kind) || tie else { return }
            }
            best = Best(value: value, trip: trip, place: place)
        }
    }
}

extension TripStats {
    /// Great-circle metres, 0 when a coordinate is broken, so no sum and no record turns NaN.
    fileprivate static func greatCircleMeters(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        finiteMeters(GeoMath.distance(a, b))
    }

    /// A distance that can be added up: a broken (NaN, infinite) or negative one counts as 0.
    static func finiteMeters(_ meters: Double) -> Double {
        meters.isFinite && meters > 0 ? meters : 0
    }

    /// The place at `index` of `geometry`, or `nil` for an index that names none.
    fileprivate static func place(of geometry: TripGeometry, at index: Int) -> TripPlace? {
        geometry.places.indices.contains(index) ? geometry.places[index] : nil
    }
}
