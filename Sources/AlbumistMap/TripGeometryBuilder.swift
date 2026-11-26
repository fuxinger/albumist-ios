import Foundation
import AlbumistCore

extension TripGeometry {
    /// Where the photos of `trip` were, day by day (concept §4.3 and §5): its day places, its
    /// distinct places with their names, the route between them (at most `maxRoutePoints`), the
    /// legs "ohne Fotos", the place its arc points to, its countries and its photos per day.
    ///
    /// Only photos with a usable location and a date, on the ground (`FlightJudgement`), no
    /// screenshot and not at home (`AssetFacts.atHome`, concept §8: everyday photos at home never
    /// appear on the map, not even one the trip detection put in a trip) are drawn on the map: day
    /// places, places, route, destination, covers, countries and photos per day come from them
    /// alone, and so every record (concept §5: "Flugzeugfotos zählen nicht"). Their place
    /// is their GPS place (`AssetFacts.gpsPlace`), never one guessed from the content. Every photo
    /// counts in `photoCount` and every dated one in the trip's days (`start` to `end`, `firstDay`
    /// to `lastDay`), as its album shows them.
    ///
    /// - Parameters:
    ///   - facts: the trip's photos (those whose `tripID` is the trip's), in any order, maybe none.
    ///     The same facts in any order give the same geometry. A photo listed twice counts once
    ///     (`eachPhotoOnce`).
    ///   - airborne: photos taken in flight (`AirborneFilter.airborne`): left out of places,
    ///     route and countries, counted in `airborneCount`.
    ///   - maybeInFlight: photos maybe taken in flight (`FlightJudgement`): left out as well, not
    ///     counted in `airborneCount`.
    ///   - altitudes: metres above sea level by photo, where the iPhone stored one (`TripPlace.altitude`).
    ///   - timeZone: the device's time zone, for a trip none of whose photos has a known one.
    ///
    /// A photo's day is the day on the clock where it was taken, as the app's albums count it
    /// (`AssetFacts.timeZone`, review P1-15; decision 19.11.2026), else in its place's zone, else
    /// in the trip's zone (the most common zone of its photos on the map).
    public static func build(trip: Trip, facts: [AssetFacts], airborne: Set<AssetID>, maybeInFlight: Set<AssetID> = [],
                             altitudes: [AssetID: Double] = [:], timeZone: TimeZone) -> TripGeometry {
        TripGeometryBuilder.build(trip: trip, facts: facts, airborne: airborne, maybeInFlight: maybeInFlight, altitudes: altitudes,
                                  deviceTimeZone: timeZone)
    }
}

/// The steps of `TripGeometry.build`, in the order they depend on each other.
///
/// Each fact is read once, into plain values (only the few best covers of a place are read again,
/// for their `PreviewRank`): the steps after read a photo many times, and the trips of a library
/// hold tens of thousands of photos (concept §9: the whole map of 50,000 photos in 300 ms). Every
/// step is about linear in the photos, so one trip holding all of them costs what the trips of a
/// library do.
enum TripGeometryBuilder {
    /// A photo the geometry is drawn from: a usable location and a date, on the ground
    /// (`FlightJudgement`), no screenshot, not at home.
    struct Photo {
        /// Into the photos' `Source`s, which keep the order the facts came in.
        var source: Int
        var date: Date
        var coordinate: GeoCoordinate
        /// Its local day: on the clock where it was taken (`AssetFacts.timeZone`), else where its
        /// place is, else in the trip's zone.
        var day = LocalDay(year: 1970, month: 1, day: 1)
    }

    /// What the later steps need of a photo on the map besides its time and place.
    struct Source {
        var id: AssetID
        var names: Names
        /// Nil for anything but a still image (a video).
        var cover: Cover?
    }

    /// What a photo's GPS place says to name its trip place by (`tripPlace`); "" where it says
    /// nothing (an empty name is none).
    struct Names {
        var pointOfInterest = "", town = "", district = "", region = "", country = "", countryKey = ""

        init(_ place: PlaceComponents?) {
            guard let place else { return }
            pointOfInterest = place.areaOfInterest ?? ""
            town = place.locality ?? ""
            district = place.subAdministrativeArea ?? ""
            region = place.administrativeArea ?? ""
            country = place.country ?? ""
            countryKey = TripGeometryBuilder.countryKey(place) ?? ""
        }
    }

    /// A picture that may show its place on a pin or in a stack (`TripPlace.coverCandidates`) if
    /// it is an ordinary analysed photo (`PreviewRank.photo`, asked only of the best few: see
    /// `tripPlace`). Favourites first, then the largest, then by id.
    struct Cover {
        var favorite: Bool
        var area: Double
        var id: AssetID
        /// Into the facts given.
        var fact: Int

        /// Nil for anything but a still image (a video).
        init?(_ fact: AssetFacts, at index: Int) {
            guard fact.asset.kind == .image else { return nil }
            favorite = fact.asset.isFavorite
            // In Double, so no product of two dimensions overflows; a broken negative one is 0.
            area = Double(max(0, fact.asset.pixelWidth)) * Double(max(0, fact.asset.pixelHeight))
            id = fact.id
            self.fact = index
        }

        func ranks(before other: Cover) -> Bool {
            if favorite != other.favorite { return favorite }
            if area != other.area { return area > other.area }
            return id < other.id
        }
    }

    /// The photos of one day of one place (`DayPlace`), by their indices into the time-ordered
    /// photos, oldest first.
    struct DayGroup {
        var day: LocalDay
        var members: [Int]
        var coordinate: GeoCoordinate
    }

    /// One visit of the route: photos one after another at one trip place, by the indices of its
    /// first and last photo.
    struct Visit: Hashable {
        var place: Int
        var first: Int
        var last: Int
    }

    /// No place on Earth (`GeoCoordinate.isPlausible` is false for it): the destination of a trip
    /// with no photo on the map whose centre may be home (`build`).
    static let nowhere = GeoCoordinate(latitude: 0, longitude: 0)

    static func build(trip: Trip, facts: [AssetFacts], airborne: Set<AssetID>, maybeInFlight: Set<AssetID> = [], altitudes: [AssetID: Double],
                      deviceTimeZone: TimeZone) -> TripGeometry {
        let facts = eachPhotoOnce(facts)
        // Every dated photo with the zone of its clock, for its day; the photos on the map with
        // what the later steps need of them.
        var read = Reading(facts, trip: trip, airborne: airborne, maybeInFlight: maybeInFlight)
        let dated = read.dated, sources = read.sources, identifiers = read.zones.identifiers
        let timeZones = identifiers.map { TimeZone(identifier: $0) }
        let tripZone = tripZone(of: dated, identifiers: identifiers, timeZones: timeZones)
        var days = LocalDayFinder(zones: timeZones, fallback: tripZone.flatMap { timeZones[$0] } ?? deviceTimeZone)
        let span = localDays(of: dated, photos: &read.photos, days: &days)
        read.photos.sort { precedes($0, $1, sources: sources) }
        let photos = read.photos

        let groups = dayGroups(photos)
        let (groupPlace, placeCount) = mergedPlaces(groups)
        var placeGroups = [[DayGroup]](repeating: [], count: placeCount)
        var placeOfPhoto = [Int](repeating: -1, count: photos.count)
        for (g, group) in groups.enumerated() {
            placeGroups[groupPlace[g]].append(group)
            for m in group.members { placeOfPhoto[m] = groupPlace[g] }
        }
        var placeMembers = [[Int]](repeating: [], count: placeCount)
        for (i, place) in placeOfPhoto.enumerated() where place >= 0 { placeMembers[place].append(i) }
        let tripPhotos = TripPhotos(photos: photos, sources: sources, facts: facts, altitudes: altitudes)
        let places = (0..<placeCount).map { p in tripPlace(members: placeMembers[p], dayPlaces: placeGroups[p], in: tripPhotos) }
        let dayPlaces = groups.enumerated().map { g, group in
            DayPlace(coordinate: group.coordinate, day: group.day, firstPhoto: photos[group.members[0]].date,
                     lastPhoto: photos[group.members[group.members.count - 1]].date, photoCount: group.members.count, placeIndex: groupPlace[g])
        }

        let coordinates = places.map { $0.coordinate }
        let (visits, legs) = route(placeOfPhoto: placeOfPhoto, photos: photos, coordinates: coordinates)
        let routePoints = visits.map {
            RoutePoint(placeIndex: $0.place, arrival: photos[$0.first].date, departure: photos[$0.last].date, day: photos[$0.first].day)
        }
        let destination = destination(of: places, photos: photos, trip: trip, someAtHome: read.someAtHome)
        let dayCounts = dayCounts(span.photosPerDay, groups: groups, placeOfGroup: groupPlace)
        let countryPhotos = read.countries.counts

        return TripGeometry(
            id: trip.id, start: read.start, end: read.end, timeZoneIdentifier: tripZone.map { identifiers[$0] },
            firstDay: span.first ?? days.day(trip.start, zone: -1), lastDay: span.last ?? days.day(trip.end, zone: -1),
            photoCount: facts.count, dayCounts: dayCounts, dayPlaces: dayPlaces, places: places, route: routePoints,
            legs: legs, destinationIndex: destination.index, destination: destination.coordinate,
            countryPhotos: countryPhotos, mainCountryKey: countryPhotos.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key,
            airborneCount: read.airborneCount)
    }

    /// Time order, equal times by id: one order, whatever order the facts came in (`build` holds
    /// each id once).
    static func precedes(_ a: Photo, _ b: Photo, sources: [Source]) -> Bool {
        if a.date != b.date { return a.date < b.date }
        return sources[a.source].id < sources[b.source].id
    }

    /// `day` as one number in the same order, cheaper to compare than its three parts.
    static func dayKey(_ day: LocalDay) -> Int {
        (day.year * 13 + day.month) * 32 + day.day
    }

    /// A place's country (as `TravelAtlas.countryKey`): its ISO code, or "disputed-<id>" in a
    /// disputed area.
    static func countryKey(_ place: PlaceComponents) -> String? {
        place.isoCountryCode ?? place.disputedArea.map { "disputed-" + $0 }
    }
}

extension TripGeometryBuilder {
    // MARK: The steps of build

    /// A dated photo, for its local day (`localDays`): its date, the zone of its clock by number
    /// (`ZoneNumbers`, -1 for none) and where it is among the photos on the map (-1 for a photo
    /// not on the map).
    private struct DatedPhoto {
        var date: Date
        var zone: Int
        var photo: Int
    }

    /// What `build` reads of the facts, each in one pass: every dated photo with the zone of its
    /// clock, for its day; the photos on the map with what the later steps need of them; and the
    /// trip's start, end, countries and photos in flight.
    private struct Reading {
        let dated: [DatedPhoto]
        var photos: [Photo]
        let sources: [Source]
        let zones: ZoneNumbers
        /// The countries of the photos on the map (`TripGeometry.countryPhotos`).
        let countries: NameCounter
        /// The first and last photo's dates, the trip's own without a dated photo.
        let start: Date, end: Date
        let airborneCount: Int
        /// Whether one of the trip's photos is at home, dated or not (`destination`).
        let someAtHome: Bool

        init(_ facts: [AssetFacts], trip: Trip, airborne: Set<AssetID>, maybeInFlight: Set<AssetID>) {
            var dated: [DatedPhoto] = []
            var photos: [Photo] = []
            var sources: [Source] = []
            dated.reserveCapacity(facts.count)
            photos.reserveCapacity(facts.count)
            sources.reserveCapacity(facts.count)
            var zones = ZoneNumbers()
            var countries = NameCounter()
            var start = trip.start, end = trip.end
            var airborneCount = 0
            var someAtHome = false
            for (index, fact) in facts.enumerated() {
                let inFlight = !airborne.isEmpty && airborne.contains(fact.id)
                if inFlight { airborneCount += 1 }
                let notOnTheGround = inFlight || (!maybeInFlight.isEmpty && maybeInFlight.contains(fact.id))
                if fact.atHome { someAtHome = true }
                guard let date = fact.asset.creationDate else { continue }
                if dated.isEmpty || date < start { start = date }
                if dated.isEmpty || date > end { end = date }
                let place = fact.gpsPlace
                var zone = -1
                // The clock where it was taken, as the app counts its days and months
                // (`AssetFacts.timeZone`, review P1-15), else its place's zone.
                if let identifier = fact.timeZone?.identifier ?? place?.timeZoneIdentifier { zone = zones.number(identifier) }
                guard !notOnTheGround, !fact.atHome, !fact.asset.isScreenshotLike, let coordinate = fact.asset.usableLocation else {
                    dated.append(DatedPhoto(date: date, zone: zone, photo: -1))
                    continue
                }
                dated.append(DatedPhoto(date: date, zone: zone, photo: photos.count))
                photos.append(Photo(source: photos.count, date: date, coordinate: coordinate))
                let names = Names(place)
                countries.add(names.countryKey)
                sources.append(Source(id: fact.id, names: names, cover: Cover(fact, at: index)))
            }
            self.dated = dated
            self.photos = photos
            self.sources = sources
            self.zones = zones
            self.countries = countries
            self.start = start
            self.end = end
            self.airborneCount = airborneCount
            self.someAtHome = someAtHome
        }
    }

    /// The trip's zone, by its number: the most common one of the photos on the map (a window
    /// photo over another zone is none of them), ties to the smaller identifier; one Foundation
    /// does not know is none.
    private static func tripZone(of dated: [DatedPhoto], identifiers: [String], timeZones: [TimeZone?]) -> Int? {
        var votes = [Int](repeating: 0, count: timeZones.count)
        for entry in dated where entry.photo >= 0 && entry.zone >= 0 { votes[entry.zone] += 1 }
        var tripZone: Int?
        for z in votes.indices where votes[z] > 0 && timeZones[z] != nil {
            if let best = tripZone, votes[z] < votes[best] || (votes[z] == votes[best] && identifiers[z] > identifiers[best]) {
                continue
            }
            tripZone = z
        }
        return tripZone
    }

    /// The trip's first and last local day (nil without a dated photo) and its photos on the map
    /// per day (`localDays`).
    private struct DaySpan {
        var first: LocalDay?
        var last: LocalDay?
        var photosPerDay: [LocalDay: Int]
    }

    /// Every dated photo's local day: on its clock, else in the zone of its place, else in the
    /// trip's. The trip's first and last day are those of all of them (its album's), its
    /// photos per day those on the map. Each photo on the map gets its day (`Photo.day`).
    private static func localDays(of dated: [DatedPhoto], photos: inout [Photo], days: inout LocalDayFinder) -> DaySpan {
        var photosPerDay: [LocalDay: Int] = [:]
        var firstDay: LocalDay?, lastDay: LocalDay?
        var previous = LocalDay(year: 0, month: 0, day: 0)
        var run = (day: previous, count: 0)
        for entry in dated {
            let day = days.day(entry.date, zone: entry.zone)
            if day != previous {
                previous = day
                if firstDay.map({ day < $0 }) ?? true { firstDay = day }
                if lastDay.map({ day > $0 }) ?? true { lastDay = day }
            }
            guard entry.photo >= 0 else { continue }
            photos[entry.photo].day = day
            // The photos of one day mostly come one after another: one count per run of them.
            if day == run.day {
                run.count += 1
            } else {
                if run.count > 0 { photosPerDay[run.day, default: 0] += run.count }
                run = (day, 1)
            }
        }
        if run.count > 0 { photosPerDay[run.day, default: 0] += run.count }
        return DaySpan(first: firstDay, last: lastDay, photosPerDay: photosPerDay)
    }

    /// The arc's end: the place with the most photos, ties to the earlier first day, then the
    /// lower index. Without a place, the photo the trip's photos on the map gather around (as a
    /// day's point). Without a photo on the map, the trip's centre, unless one of its photos is
    /// at home: the centre the trip detection worked out from its photos may then be home
    /// (concept §8), so the destination is no place on Earth (`nowhere`); the composer shows no
    /// trip without a photo on the map anyway (`MapSummary.isDrawn`).
    private static func destination(of places: [TripPlace], photos: [Photo], trip: Trip, someAtHome: Bool) -> (index: Int?, coordinate: GeoCoordinate) {
        func isBetterDestination(_ a: TripPlace, than b: TripPlace) -> Bool {
            if a.photoCount != b.photoCount { return a.photoCount > b.photoCount }
            guard let dayA = a.days.first, let dayB = b.days.first else { return false }
            return dayA < dayB
        }
        var destinationIndex: Int?
        for p in places.indices where destinationIndex.map({ isBetterDestination(places[p], than: places[$0]) }) ?? true {
            destinationIndex = p
        }
        let destination = destinationIndex.map { places[$0].coordinate } ?? GeoMath.dayPoint(photos.map { $0.coordinate })
            ?? (someAtHome ? nowhere : trip.centroid)
        return (destinationIndex, destination)
    }

    /// The trip's days with photos on the map (`TripGeometry.dayCounts`), and per day the place
    /// holding most of its photos on the map, ties to the lower index: a day's photos in places
    /// are those of its day places.
    private static func dayCounts(_ photosPerDay: [LocalDay: Int], groups: [DayGroup], placeOfGroup: [Int]) -> [TripDay] {
        var placePhotosPerDay: [LocalDay: [Int: Int]] = [:]
        for (g, group) in groups.enumerated() {
            placePhotosPerDay[group.day, default: [:]][placeOfGroup[g], default: 0] += group.members.count
        }
        return photosPerDay.keys.sorted().map { day in
            TripDay(day: day, photoCount: photosPerDay[day] ?? 0,
                    placeIndex: placePhotosPerDay[day]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key)
        }
    }
}
