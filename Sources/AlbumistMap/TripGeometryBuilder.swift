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
        var dated: [(date: Date, zone: Int, photo: Int)] = []
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
                dated.append((date, zone, -1))
                continue
            }
            dated.append((date, zone, photos.count))
            photos.append(Photo(source: photos.count, date: date, coordinate: coordinate))
            let names = Names(place)
            countries.add(names.countryKey)
            sources.append(Source(id: fact.id, names: names, cover: Cover(fact, at: index)))
        }

        // The trip's zone: the most common one of the photos on the map (a window photo over
        // another zone is none of them), ties to the smaller identifier; one Foundation does not
        // know is none.
        let timeZones = zones.identifiers.map { TimeZone(identifier: $0) }
        var votes = [Int](repeating: 0, count: timeZones.count)
        for entry in dated where entry.photo >= 0 && entry.zone >= 0 { votes[entry.zone] += 1 }
        var tripZone: Int?
        for z in votes.indices where votes[z] > 0 && timeZones[z] != nil {
            if let best = tripZone, votes[z] < votes[best] || (votes[z] == votes[best] && zones.identifiers[z] > zones.identifiers[best]) {
                continue
            }
            tripZone = z
        }

        // Every dated photo's local day: on its clock, else in the zone of its place, else in the
        // trip's. The trip's first and last day are those of all of them (its album's), its
        // photos per day those on the map.
        var days = LocalDayFinder(zones: timeZones, fallback: tripZone.flatMap { timeZones[$0] } ?? deviceTimeZone)
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
        photos.sort { precedes($0, $1, sources: sources) }

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
        let places = (0..<placeCount).map { p in
            tripPlace(members: placeMembers[p], dayPlaces: placeGroups[p], photos: photos, sources: sources, facts: facts, altitudes: altitudes)
        }
        let dayPlaces = groups.enumerated().map { g, group in
            DayPlace(coordinate: group.coordinate, day: group.day, firstPhoto: photos[group.members[0]].date,
                     lastPhoto: photos[group.members[group.members.count - 1]].date, photoCount: group.members.count, placeIndex: groupPlace[g])
        }

        let coordinates = places.map { $0.coordinate }
        let (visits, legs) = route(placeOfPhoto: placeOfPhoto, photos: photos, coordinates: coordinates)
        let routePoints = visits.map {
            RoutePoint(placeIndex: $0.place, arrival: photos[$0.first].date, departure: photos[$0.last].date, day: photos[$0.first].day)
        }

        // The arc's end: the place with the most photos, ties to the earlier first day, then the
        // lower index. Without a place, the photo the trip's photos on the map gather around (as a
        // day's point). Without a photo on the map, the trip's centre, unless one of its photos is
        // at home: the centre the trip detection worked out from its photos may then be home
        // (concept §8), so the destination is no place on Earth (`nowhere`); the composer shows no
        // trip without a photo on the map anyway (`MapSummary.isDrawn`).
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

        // Per day, the place holding most of its photos on the map, ties to the lower index: a
        // day's photos in places are those of its day places.
        var placePhotosPerDay: [LocalDay: [Int: Int]] = [:]
        for (g, group) in groups.enumerated() {
            placePhotosPerDay[group.day, default: [:]][groupPlace[g], default: 0] += group.members.count
        }
        let dayCounts = photosPerDay.keys.sorted().map { day in
            TripDay(day: day, photoCount: photosPerDay[day] ?? 0,
                    placeIndex: placePhotosPerDay[day]?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key)
        }
        let countryPhotos = countries.counts

        return TripGeometry(
            id: trip.id, start: start, end: end, timeZoneIdentifier: tripZone.map { zones.identifiers[$0] },
            firstDay: firstDay ?? days.day(trip.start, zone: -1), lastDay: lastDay ?? days.day(trip.end, zone: -1),
            photoCount: facts.count, dayCounts: dayCounts, dayPlaces: dayPlaces, places: places, route: routePoints,
            legs: legs, destinationIndex: destinationIndex, destination: destination,
            countryPhotos: countryPhotos, mainCountryKey: countryPhotos.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key,
            airborneCount: airborneCount)
    }

    /// Time order, equal times by id: one order, whatever order the facts came in (`build` holds
    /// each id once).
    static func precedes(_ a: Photo, _ b: Photo, sources: [Source]) -> Bool {
        if a.date != b.date { return a.date < b.date }
        return sources[a.source].id < sources[b.source].id
    }

    // MARK: A photo listed twice

    /// `facts` with each photo (asset id) once, in the order they came: a library may list one
    /// twice, maybe in two states of the analysis, and it must count once in every number (concept
    /// §5: a single photo makes no place, no record and no country). Of two facts of one photo the
    /// one `isKept(_:over:)` prefers stays, so the choice never depends on their order. Facts
    /// with no id twice, as a library mostly gives them, come back as they are.
    static func eachPhotoOnce(_ facts: [AssetFacts]) -> [AssetFacts] {
        var seen = Set<AssetID>(minimumCapacity: facts.count)
        guard !facts.allSatisfy({ seen.insert($0.id).inserted }) else { return facts }
        var position: [AssetID: Int] = [:]
        var result: [AssetFacts] = []
        for fact in facts {
            if let p = position[fact.id] {
                if isKept(fact, over: result[p]) { result[p] = fact }
            } else {
                position[fact.id] = result.count
                result.append(fact)
            }
        }
        return result
    }

    /// Whether `build` keeps `a` rather than `b`, two facts of one photo: the one at home when only
    /// one is (privacy first: a photo either calls at home is never drawn), else the one whose
    /// `duplicateKey` comes first. Two facts with equal keys are alike to every step of `build`,
    /// so either gives the same geometry.
    static func isKept(_ a: AssetFacts, over b: AssetFacts) -> Bool {
        if a.atHome != b.atHome { return a.atHome }
        return duplicateKey(a).lexicographicallyPrecedes(duplicateKey(b))
    }

    /// Everything `build` reads of a fact besides its id and whether it is at home, as text in a
    /// fixed order (any fixed order will do): its date, location, whether it is a screenshot, its
    /// clock, its GPS place's names and zone, what makes it a cover and its preview rank.
    static func duplicateKey(_ fact: AssetFacts) -> [String] {
        let asset = fact.asset, place = fact.gpsPlace
        return [asset.creationDate.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "",
                asset.usableLocation.map { "\($0.latitude) \($0.longitude)" } ?? "",
                asset.isScreenshotLike ? "screenshot" : "", fact.timeZone?.identifier ?? "",
                place?.isoCountryCode ?? "", place?.disputedArea ?? "", place?.country ?? "", place?.administrativeArea ?? "",
                place?.subAdministrativeArea ?? "", place?.locality ?? "", place?.areaOfInterest ?? "", place?.timeZoneIdentifier ?? "",
                "\(asset.kind.rawValue) \(asset.isFavorite) \(asset.pixelWidth) \(asset.pixelHeight)", "\(PreviewRank(fact).rawValue)"]
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

    // MARK: Places

    /// Two points at most `TripGeometry.placeRadiusMeters` apart along the Earth (as
    /// `GeoMath.distance` measures, on the same sphere) are at most this apart in a straight line
    /// through it, squared (`UnitVector.chordSquared`): a test with no trigonometry, exact for
    /// short distances, right across the antimeridian and at the poles.
    static let placeChordSquared: Double = {
        let chord = 2 * sin(TripGeometry.placeRadiusMeters / GeoMath.earthRadiusMeters / 2)
        return chord * chord
    }()

    /// The day places, oldest first (by their first photo): per local day, the day's photos in
    /// time order, each joining the nearest group of that day whose running centre is within
    /// `TripGeometry.placeRadiusMeters`, else starting one; the groups with at least
    /// `TripGeometry.minimumPhotosPerPlace` photos. The running centre is the spherical mean of
    /// the group's photos so far, so a town walked across from one end to the other stays one
    /// place, and a group across the antimeridian or near a pole is no different.
    /// A day place's point is `GeoMath.dayPoint` of its photos in time order: a real photo
    /// location where most of them were, at a bounded cost.
    ///
    /// A photo is compared with every group of its day: the groups of a day lie 3 km apart, so a
    /// day on the ground has a few dozen of them, a few hundred on a long drive.
    static func dayGroups(_ photos: [Photo]) -> [DayGroup] {
        // The photos day by day, each day in time order (and time order is mostly day order).
        let keys = photos.map { dayKey($0.day) }
        let byDay = photos.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
        var groups: [DayGroup] = []
        var first = 0
        while first < byDay.count {
            var end = first + 1
            while end < byDay.count && keys[byDay[end]] == keys[byDay[first]] { end += 1 }
            var members: [[Int]] = [], sums: [UnitVector] = [], centres: [UnitVector] = []
            for i in byDay[first..<end] {
                let point = UnitVector(photos[i].coordinate)
                var nearest = -1, nearestChord = Double.infinity
                for k in centres.indices {
                    let chord = point.chordSquared(to: centres[k])
                    if chord <= placeChordSquared && chord < nearestChord { (nearest, nearestChord) = (k, chord) }
                }
                if nearest >= 0 {
                    members[nearest].append(i)
                    sums[nearest] = sums[nearest] + point
                    centres[nearest] = sums[nearest].normalized ?? centres[nearest]
                } else {
                    members.append([i])
                    sums.append(point)
                    centres.append(point)
                }
            }
            for group in members where group.count >= TripGeometry.minimumPhotosPerPlace {
                let points = group.map { photos[$0].coordinate }
                groups.append(DayGroup(day: photos[group[0]].day, members: group, coordinate: GeoMath.dayPoint(points) ?? points[0]))
            }
            first = end
        }
        return groups.sorted { $0.members[0] < $1.members[0] }
    }

    /// The trip place of each day place, and how many there are: in time order, each day place
    /// joins the nearest place whose first day place lies within `TripGeometry.placeRadiusMeters`
    /// of its point, else it starts a new one (so places are numbered by first appearance). The
    /// hotel town of several days becomes one place. Measured from the place's first day place,
    /// which never moves, so places along a coast road do not chain into one. Day places of the
    /// same day merge too: two groups of one day whose running centres drifted within the
    /// radius are one place, not a zig-zag of the route inside one town.
    ///
    /// A day place is compared only with the places near it (`PlaceGrid`), not with every place
    /// before it: a trip has a few dozen places, but one the trip detection made of years of
    /// photos has thousands. The nearest by the same measure, ties to the lower index, so the
    /// places are those of comparing each.
    static func mergedPlaces(_ groups: [DayGroup]) -> (placeOfGroup: [Int], count: Int) {
        var grid = PlaceGrid()
        var placeOfGroup: [Int] = []
        placeOfGroup.reserveCapacity(groups.count)
        for group in groups {
            let point = UnitVector(group.coordinate)
            if let place = grid.nearest(to: point) {
                placeOfGroup.append(place)
            } else {
                placeOfGroup.append(grid.add(point))
            }
        }
        return (placeOfGroup, grid.count)
    }

    /// The first day places of a trip's places (their founders, `mergedPlaces`), on a grid of
    /// cubes over the space the unit sphere lies in, each as wide as the place radius in a
    /// straight line (`placeChordSquared`). Two points within the radius differ by less than
    /// that along each axis, so they lie in the same cube or in neighbouring ones: a point is
    /// compared with the founders of 27 cubes, whatever lies elsewhere. In space, not in latitude
    /// and longitude, so the antimeridian and the poles are no different.
    struct PlaceGrid {
        /// A cube's edge: a little longer than the radius as a straight line, so that rounding
        /// never puts two points within the radius more than one cube apart.
        static let edge = placeChordSquared.squareRoot() * (1 + 1e-6)
        /// Cubes on either side of the centre along an axis (the sphere reaches 1 from it), with
        /// room for the neighbours of the outermost: a cube's number is `(x, y, z)` in one `Int`.
        static let reach = Int((1 / edge).rounded(.up)) + 2

        /// The founders' points, by place.
        private(set) var founders: [UnitVector] = []
        /// The places whose founder lies in a cube, lowest first, by the cube's number.
        private var cubes: [Int: [Int]] = [:]

        var count: Int { founders.count }

        /// The nearest place whose founder lies within the radius of `point`, ties to the lower
        /// index; nil without one.
        func nearest(to point: UnitVector) -> Int? {
            let x = Self.cube(point.x), y = Self.cube(point.y), z = Self.cube(point.z)
            var nearest = -1, nearestChord = Double.infinity
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        guard let places = cubes[Self.number(x + dx, y + dy, z + dz)] else { continue }
                        for p in places {
                            let chord = point.chordSquared(to: founders[p])
                            if chord <= placeChordSquared && (chord < nearestChord || (chord == nearestChord && p < nearest)) {
                                (nearest, nearestChord) = (p, chord)
                            }
                        }
                    }
                }
            }
            return nearest >= 0 ? nearest : nil
        }

        /// A new place founded at `point`; its index.
        mutating func add(_ point: UnitVector) -> Int {
            founders.append(point)
            cubes[Self.number(Self.cube(point.x), Self.cube(point.y), Self.cube(point.z)), default: []].append(founders.count - 1)
            return founders.count - 1
        }

        /// The cube along one axis that `value` (-1 to 1) lies in. A point that is none on the
        /// sphere (no usable location gives one) lies in a cube of the grid too: it is within the
        /// radius of nothing and founds a place, as comparing each would have it.
        static func cube(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return Int((min(1, max(-1, value)) / edge).rounded(.down))
        }

        static func number(_ x: Int, _ y: Int, _ z: Int) -> Int {
            let span = 2 * reach + 1
            return ((x + reach) * span + (y + reach)) * span + (z + reach)
        }
    }

    /// One distinct place of the trip from its photos (indices into `photos`, time order) and its
    /// day places (time order).
    static func tripPlace(members: [Int], dayPlaces: [DayGroup], photos: [Photo], sources: [Source], facts: [AssetFacts],
                          altitudes: [AssetID: Double]) -> TripPlace {
        var pointsOfInterest = NameCounter(), towns = NameCounter(), districts = NameCounter()
        var regions = NameCounter(), countries = NameCounter(), countryKeys = NameCounter()
        var covers = CoverPicker(limit: TripGeometry.coverCandidateLimit)
        for m in members {
            let source = sources[photos[m].source]
            pointsOfInterest.add(source.names.pointOfInterest)
            towns.add(source.names.town)
            districts.add(source.names.district)
            regions.add(source.names.region)
            countries.add(source.names.country)
            countryKeys.add(source.names.countryKey)
            if let cover = source.cover { covers.add(cover) }
        }
        // Pin and stack photos: the best of its ordinary analysed photos. `PreviewRank` reads much
        // of a fact, so it is asked of the best few pictures only; when one of them is no ordinary
        // photo, of all of them.
        if !covers.kept.allSatisfy({ PreviewRank(facts[$0.fact]) == .photo }) {
            covers = CoverPicker(limit: TripGeometry.coverCandidateLimit)
            for m in members {
                if let cover = sources[photos[m].source].cover, PreviewRank(facts[cover.fact]) == .photo { covers.add(cover) }
            }
        }
        // The point of interest when one names at least half of its photos ("Skógafoss"), else
        // the most common town, then district, region, country.
        var name: String?
        if let poi = pointsOfInterest.top, poi.count * 2 >= members.count {
            name = poi.name
        } else {
            name = [towns, districts, regions, countries].lazy.compactMap { $0.top?.name }.first
        }

        // Where most of its photos were over the whole trip, a real photo location:
        // `GeoMath.dayPoint` over all its photos in time order, whose sample spreads over its days
        // by their photos (for a place of one day place, that day place's point: the same photos).
        let coordinate = dayPlaces.count == 1 ? dayPlaces[0].coordinate
            : GeoMath.dayPoint(members.map { photos[$0].coordinate }) ?? photos[members[0]].coordinate
        var days: [LocalDay] = []
        for day in dayPlaces.map({ $0.day }).sorted() where days.last != day { days.append(day) }

        return TripPlace(coordinate: coordinate, name: name, countryKey: countryKeys.top?.name, photoCount: members.count, days: days,
                         coverCandidates: covers.ids,
                         altitude: altitudes.isEmpty ? nil : altitude(of: members.map { sources[photos[$0].source].id }, altitudes: altitudes))
    }

    /// The place's height (`TripPlace.altitude`): the mean of its highest photos that agree, those
    /// within `TripGeometry.altitudeSpreadMeters` below the highest one that has at least
    /// `TripGeometry.minimumPhotosPerPlace - 1` others that close ("nur, wenn die Höhen der Fotos
    /// zusammenpassen"); else none, and no "Höchstes Foto" from it. A summit is one place with
    /// the way up to it (3 km), so the photos on the way up must not take its height away, and a
    /// single photo with a wrong altitude makes none. Altitudes above
    /// `AirborneFilter.maximumAltitude` are from planes (concept §5) and count as none. Added up
    /// from the lowest, so the mean does not depend on the input order.
    static func altitude(of ids: [AssetID], altitudes: [AssetID: Double]) -> Double? {
        guard !altitudes.isEmpty else { return nil }
        let values = ids.compactMap { altitudes[$0] }.filter { $0.isFinite && $0 <= AirborneFilter.maximumAltitude }.sorted()
        let minimum = TripGeometry.minimumPhotosPerPlace
        guard values.count >= minimum else { return nil }
        // From the highest down: the values from `low` to `high` lie within the spread, and as
        // `high` comes down, `low` can only come down too.
        var low = values.count - 1
        for high in stride(from: values.count - 1, through: minimum - 1, by: -1) {
            low = min(low, high)
            while low > 0 && values[high] - values[low - 1] <= TripGeometry.altitudeSpreadMeters { low -= 1 }
            if high - low + 1 >= minimum { return values[low...high].reduce(0, +) / Double(high - low + 1) }
        }
        return nil
    }

    // MARK: Route

    /// The route (`RoutePoint`) and its legs.
    ///
    /// The visits: the photos on the map in time order, each at the trip place of its day place
    /// (photos in no place are skipped), consecutive photos at one place one visit. A → B → A in
    /// one day are three visits.
    ///
    /// Some legs from one visit to the next nobody went (`travelledLegs`): the two visits were
    /// taken at the same time in two places, by a second camera in the library (an iCloud Shared
    /// Library) or with a wrong location. The order of a run of visits joined by such legs is no
    /// way anyone went, so the route passes each of the run's places once, at its first visit in
    /// the run: photos taken in turn in two places add no point and no kilometre, whichever of
    /// them came last. A leg someone went starts a new run, from the route's last point; a visit
    /// to that point's own place adds no point but lengthens it to the visit's last photo.
    ///
    /// The legs are those between all the visits (`legs`). More than `TripGeometry.maxRoutePoints`
    /// visits are then cut (`simplified`), each leg of the cut route carrying the legs it stands
    /// for (`cutLegs`): "vor Ort" counts every leg, the cut changes only what is drawn.
    static func route(placeOfPhoto: [Int], photos: [Photo], coordinates: [GeoCoordinate]) -> (visits: [Visit], legs: [RouteLeg]) {
        var all: [Visit] = []
        for (i, place) in placeOfPhoto.enumerated() where place >= 0 {
            if let last = all.last, last.place == place {
                all[all.count - 1].last = i
            } else {
                all.append(Visit(place: place, first: i, last: i))
            }
        }
        let travelled = travelledLegs(all, photos: photos)
        // The visits kept; the runs of visits joined by legs nobody went, numbered, and per place
        // the last run it was kept in.
        var visits: [Visit] = []
        var run = 0
        var keptInRun = [Int](repeating: -1, count: coordinates.count)
        for (k, visit) in all.enumerated() {
            if k == 0 {
                visits.append(visit)
            } else if travelled[k - 1] {
                // A new run, from the route's last point when it is here already.
                run += 1
                if visits[visits.count - 1].place == visit.place {
                    visits[visits.count - 1].last = visit.last
                } else {
                    visits.append(visit)
                }
            } else if keptInRun[visit.place] != run {
                // In the run of the visit before: its place once.
                visits.append(visit)
            }
            keptInRun[visit.place] = run
        }

        let legs = legs(visits, photos: photos, coordinates: coordinates)
        guard visits.count > TripGeometry.maxRoutePoints else { return (visits, legs) }
        let cut = simplified(visits, coordinates: coordinates, limit: TripGeometry.maxRoutePoints)
        return (cut.visits, cutLegs(legs, startingAt: cut.starts))
    }

    /// Faster than this, as the crow flies from the last photo at one place to the first at the
    /// next, nobody goes door to door on the ground between the places of a trip, except by
    /// high-speed train between stations a hundred kilometres and more apart (Beijing to Tianjin,
    /// 108 km in half an hour): a car averages well under it even on a motorway, the Shanghai
    /// airport maglev comes to some 180 km/h (24 km in eight minutes). Planes reach it in the air
    /// and, gate to gate, from some 150 km on (Honolulu to Maui in 40 minutes). 200 km/h, in
    /// metres per second.
    static let turnBackSpeed = 200.0 / 3.6
    /// At most this long at a place (from its first photo there to its last), between legs faster
    /// than `turnBackSpeed` from one place and back to it, is turning back right away: an hour.
    /// Whoever gets somewhere that fast mostly stays for hours (a day out by high-speed train, an
    /// island by plane); two cameras taking photos in turn mostly stay minutes at each turn.
    static let turnBackStay: TimeInterval = 3_600

    /// For each leg from one visit to the next (`visits[k]` to `visits[k + 1]`, from the last
    /// photo of the one to the first of the other), whether someone went it, as far as the photos
    /// tell. Nobody went it
    /// - when nothing could have gone it in the time, not even a plane (`isNoTravel`); or
    /// - when it leads to or from a visit the route **turns back** from right away, with another
    ///   such visit next to it or one visit away (A → B → A → B, or A → B → A → C → A, the visit
    ///   between them as long as it may be). The route turns back from a visit right away when
    ///   the visits before and after it are at one place, both its legs are faster than
    ///   `turnBackSpeed` (`isFast`) and it lasts at most `turnBackStay`. Once is a way people go:
    ///   a scenic flight circling a glacier and back to the airfield, a high-speed train out and
    ///   straight back. Twice in a row is not: the photos were taken in two places at the same
    ///   time, by two cameras or with a location jumping to and fro (review: Reykjavík and
    ///   Þingvellir, 41 km apart, in turn every ten minutes made 18 route points and 700 km
    ///   "vor Ort").
    ///
    /// So photos taken in turn in two places still zig-zag when their legs are slower than
    /// `turnBackSpeed` (two cameras 41 km apart, in turn every quarter of an hour), when the route
    /// turns back right away from one visit with no other such visit next to it or one visit away
    /// (A → B → A, then on to C), and when the visits last longer than `turnBackStay`. Real ways
    /// back and forth this fast with no more than `turnBackStay` at two turns in a row (shuttle
    /// flights with a crew's short turnarounds, photos at two spots of a race track lap after
    /// lap) count as no way anyone went.
    static func travelledLegs(_ visits: [Visit], photos: [Photo]) -> [Bool] {
        guard visits.count > 1 else { return [] }
        var travelled: [Bool] = [], fast: [Bool] = []
        travelled.reserveCapacity(visits.count - 1)
        fast.reserveCapacity(visits.count - 1)
        for (from, to) in zip(visits, visits.dropFirst()) {
            travelled.append(!isNoTravel(from: photos[from.last], to: photos[to.first]))
            fast.append(isFast(from: photos[from.last], to: photos[to.first]))
        }
        // The visits the route turns back from right away (never the first or the last).
        var turnsBack = [Bool](repeating: false, count: visits.count)
        for k in 1..<(visits.count - 1) where visits[k - 1].place == visits[k + 1].place && fast[k - 1] && fast[k] {
            turnsBack[k] = photos[visits[k].last].date.timeIntervalSince(photos[visits[k].first].date) <= turnBackStay
        }
        // Two of them in a row: the legs to and from both.
        for k in turnsBack.indices where turnsBack[k] {
            for other in [k + 1, k + 2] where other < turnsBack.count && turnsBack[other] {
                for leg in [k - 1, k, other - 1, other] { travelled[leg] = false }
            }
        }
        return travelled
    }

    /// Whether nothing could have gone from where `a` was taken to where `b` was in the time
    /// between them (`b` not before `a`), not even a plane (`AirborneFilter.maximumFlightSpeed`,
    /// as the crow flies): they were taken at the same time in two places.
    static func isNoTravel(from a: Photo, to b: Photo) -> Bool {
        GeoMath.distance(a.coordinate, b.coordinate) > AirborneFilter.maximumFlightSpeed * b.date.timeIntervalSince(a.date)
    }

    /// Whether going from where `a` was taken to where `b` was in the time between them (`b` not
    /// before `a`) is faster than `turnBackSpeed`, as the crow flies.
    static func isFast(from a: Photo, to b: Photo) -> Bool {
        GeoMath.distance(a.coordinate, b.coordinate) > turnBackSpeed * b.date.timeIntervalSince(a.date)
    }

    /// At most `limit` visits of `visits` (concept §9), the first and last always among them,
    /// and where each of them starts in `visits` (`cutLegs`).
    ///
    /// Douglas–Peucker on the sphere: the visits that stand out most from the line through their
    /// neighbours stay. Unlike dropping the visits that change the outline least (Visvalingam),
    /// it keeps an excursion there and back (hotel → far waterfall → hotel), which has no area.
    /// Measured on the sphere (`angleToArc`), so the antimeridian and the poles need no
    /// projection. The tolerance is raised just as far as needed in one step: each visit carries
    /// the largest tolerance at which DP would keep it (`significance`), and the `limit - 2`
    /// inner visits that keep up longest stay (a tie at the cut drops all tied, so never more).
    /// Visits of one place that come next to each other then become one visit, from the first's
    /// arrival to the last's departure.
    static func simplified(_ visits: [Visit], coordinates: [GeoCoordinate], limit: Int) -> (visits: [Visit], starts: [Int]) {
        guard visits.count > limit, limit >= 2 else { return (visits, Array(visits.indices)) }
        let points = visits.map { UnitVector(coordinates[$0.place]) }
        let keep = significance(points, depthLimit: limit - 1)
        let cut = keep[1..<(visits.count - 1)].sorted(by: >)[limit - 2]
        var result: [Visit] = []
        var starts: [Int] = []
        for (i, visit) in visits.enumerated() where i == 0 || i == visits.count - 1 || keep[i] > cut {
            if let last = result.last, last.place == visit.place {
                result[result.count - 1].last = visit.last
            } else {
                result.append(visit)
                starts.append(i)
            }
        }
        return (result, starts)
    }

    /// The legs of a cut route from the legs between all its visits (`legs[i]` from visit `i` to
    /// `i + 1`) and the visit each point of the cut route starts at (`simplified`).
    ///
    /// A point's leg stands for the legs from its first visit up to the next point's: the way
    /// over the visits the cut left out, and an excursion from the point back to it (a hotel
    /// left for the day). The last point's own excursions go with the last leg. So the cut route
    /// keeps the metres of every leg ("vor Ort"), each in the leg drawn in its place. A leg is
    /// "ohne Fotos" when more than half of its metres were.
    static func cutLegs(_ legs: [RouteLeg], startingAt starts: [Int]) -> [RouteLeg] {
        guard starts.count >= 2 else { return [] }
        return (0..<(starts.count - 1)).map { j in
            let upTo = j + 2 < starts.count ? starts[j + 1] : legs.count
            var meters = 0.0, withoutPhotos = 0.0
            for leg in legs[starts[j]..<upTo] {
                meters += leg.meters
                if leg.withoutPhotos { withoutPhotos += leg.meters }
            }
            return RouteLeg(meters: meters, withoutPhotos: withoutPhotos > meters / 2)
        }
    }

    /// A deviation smaller than this (radians, 1 m on the Earth) keeps no visit: it is no turn
    /// worth a route point, and a run of visits back and forth between two places (all on the
    /// line between them) costs no recursion.
    static let minimumDeviation = 1 / GeoMath.earthRadiusMeters

    /// For each point, the largest tolerance (an angle) at which Douglas–Peucker keeps it: its
    /// distance from the arc it split, capped by that of every split above it (DP stops at a
    /// segment whose farthest point is within the tolerance, whatever lies below). 0: never kept;
    /// first and last are kept anyway. The farthest point of a segment, ties to the first.
    ///
    /// Splits deeper than `depthLimit` are not worked out: a point there has at least
    /// `depthLimit` splits above it keeping up as long as it does, so it is never among the
    /// `depthLimit - 1` inner points kept. That bounds the cost at `depthLimit` passes over the
    /// points, however unevenly they split.
    static func significance(_ points: [UnitVector], depthLimit: Int) -> [Double] {
        var result = [Double](repeating: 0, count: points.count)
        guard points.count > 2 else { return result }
        var segments: [(first: Int, last: Int, ceiling: Double, depth: Int)] = [(0, points.count - 1, .infinity, 1)]
        while let segment = segments.popLast() {
            guard segment.last - segment.first > 1, segment.depth <= depthLimit else { continue }
            var farthest = segment.first + 1
            var deviation = -1.0
            for k in (segment.first + 1)..<segment.last {
                let d = angleToArc(points[k], points[segment.first], points[segment.last])
                if d > deviation { (farthest, deviation) = (k, d) }
            }
            guard deviation >= minimumDeviation else { continue }
            let kept = min(deviation, segment.ceiling)
            result[farthest] = kept
            segments.append((segment.first, farthest, kept, segment.depth + 1))
            segments.append((farthest, segment.last, kept, segment.depth + 1))
        }
        return result
    }

    /// The angle from `p` to the shorter great-circle arc from `a` to `b`: to the arc itself where
    /// `p`'s foot on the great circle lies between them, else to the nearer end.
    static func angleToArc(_ p: UnitVector, _ a: UnitVector, _ b: UnitVector) -> Double {
        let toEnds = min(p.angle(to: a), p.angle(to: b))
        let normal = a.cross(b)
        let length = normal.length
        guard length > 1e-15 else { return toEnds }
        let n = normal.scaled(1 / length)
        let sine = p.dot(n)
        let foot = p + n.scaled(-sine)
        guard a.cross(foot).dot(n) >= 0, foot.cross(b).dot(n) >= 0 else { return toEnds }
        return min(asin(min(1, abs(sine))), toEnds)
    }

    /// One leg per pair of route points, as the crow flies (`GeoMath.distance`, right across the
    /// antimeridian). "ohne Fotos" (concept §4.3): longer than `TripGeometry.gapMeters` and no
    /// photo on the map for longer than `TripGeometry.gapDuration` between the departure from
    /// the one and the arrival at the other; a single photo on the way, in no place, counts.
    static func legs(_ visits: [Visit], photos: [Photo], coordinates: [GeoCoordinate]) -> [RouteLeg] {
        zip(visits, visits.dropFirst()).map { from, to in
            let meters = GeoMath.distance(coordinates[from.place], coordinates[to.place])
            var longest: TimeInterval = 0
            if meters > TripGeometry.gapMeters {
                for k in from.last..<to.first { longest = max(longest, photos[k + 1].date.timeIntervalSince(photos[k].date)) }
            }
            return RouteLeg(meters: meters, withoutPhotos: meters > TripGeometry.gapMeters && longest > TripGeometry.gapDuration)
        }
    }

    // MARK: Counting many photos

    /// Numbers the distinct zone identifiers of many photos, which mostly come in runs (the
    /// photos of one place): one dictionary lookup per run, not per photo.
    struct ZoneNumbers {
        private(set) var identifiers: [String] = []
        private var numbers: [String: Int] = [:]
        private var last = (identifier: "", number: -1)

        mutating func number(_ identifier: String) -> Int {
            if identifier == last.identifier { return last.number }
            let number = numbers[identifier] ?? identifiers.count
            if number == identifiers.count {
                identifiers.append(identifier)
                numbers[identifier] = number
            }
            last = (identifier, number)
            return number
        }
    }

    /// Counts the names of many photos (a town, a country), which mostly come in runs: the
    /// photos of a place in time order mostly name one town, so a run costs one dictionary
    /// update, not one per photo. An empty name is none.
    struct NameCounter {
        private var settled: [String: Int] = [:]
        private var name = ""
        private var run = 0

        mutating func add(_ name: String) {
            if name == self.name {
                run += 1
                return
            }
            if run > 0 && !self.name.isEmpty { settled[self.name, default: 0] += run }
            self.name = name
            run = 1
        }

        /// Each name with how often it came.
        var counts: [String: Int] {
            var counts = settled
            if run > 0 && !name.isEmpty { counts[name, default: 0] += run }
            return counts
        }

        /// The most common name and how often it came, ties to the alphabetically first (so the
        /// dictionary's order never decides); nil without any.
        var top: (name: String, count: Int)? {
            counts.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { ($0.key, $0.value) }
        }
    }

    /// The best `limit` covers of many (`Cover.ranks(before:)`) in one pass, an id that comes
    /// twice taken once at its better rank: what sorting them all and taking the first `limit`
    /// ids gives, at a comparison or two per photo.
    struct CoverPicker {
        let limit: Int
        /// The best so far, best first.
        private(set) var kept: [Cover] = []

        init(limit: Int) {
            self.limit = limit
        }

        mutating func add(_ cover: Cover) {
            guard limit > 0 else { return }
            // Not before the last of a full list: it never gets in.
            if kept.count == limit, let last = kept.last, !cover.ranks(before: last) { return }
            if let same = kept.firstIndex(where: { $0.id == cover.id }) {
                guard cover.ranks(before: kept[same]) else { return }
                kept.remove(at: same)
            } else if kept.count == limit {
                kept.removeLast()
            }
            kept.insert(cover, at: kept.firstIndex { cover.ranks(before: $0) } ?? kept.count)
        }

        var ids: [AssetID] { kept.map { $0.id } }
    }

    // MARK: Local days

    /// The local day of many photos (`LocalDay(_:place:fallback:)`, decision 19.11.2026: the day
    /// where the photo was taken) without a calendar per photo.
    ///
    /// A zone keeps one offset from GMT between two of its transitions (Foundation names them: of
    /// summer time, or any other change of the offset). So the offset looked up for one photo
    /// serves every photo from the zone's transition before it (looked for up to a year back) to
    /// the one after it: a trip asks Foundation a few times per zone, in whatever order its
    /// photos come. The day then follows from the offset and the Gregorian calendar in plain
    /// arithmetic. Outside 1900 to 2200 (dates no camera stored, or broken ones) it asks
    /// `LocalDay` itself, so it always gives what `LocalDay` gives.
    struct LocalDayFinder {
        /// A stretch of time in which a zone keeps one offset: from `from` up to `until` (not
        /// included), in seconds since the reference date (as `Date` compares).
        struct Stretch {
            var from: TimeInterval
            var until: TimeInterval
            var offset: TimeInterval
        }

        /// How far back a stretch is looked for its start: a year holds a zone's summer and
        /// winter time.
        static let reach: TimeInterval = 366 * 86_400

        struct Zone {
            let zone: TimeZone
            var stretches: [Stretch] = []

            /// The zone's offset from GMT at `date`, in seconds.
            mutating func offset(at date: Date) -> TimeInterval {
                let time = date.timeIntervalSinceReferenceDate
                for stretch in stretches where stretch.from <= time && time < stretch.until { return stretch.offset }
                // The last transition at or before `date` within `reach`, else `reach` back (no
                // transition in between); and the first one after it.
                var from = date.addingTimeInterval(-LocalDayFinder.reach)
                var next = zone.nextDaylightSavingTimeTransition(after: from)
                while let transition = next, transition <= date, transition > from {
                    from = transition
                    next = zone.nextDaylightSavingTimeTransition(after: transition)
                }
                let offset = TimeInterval(zone.secondsFromGMT(for: date))
                let until = next?.timeIntervalSinceReferenceDate ?? .infinity
                // Kept only when it holds `date` (transitions out of order would be no stretch).
                if time < until { stretches.append(Stretch(from: from.timeIntervalSinceReferenceDate, until: until, offset: offset)) }
                return offset
            }
        }

        /// By number (`ZoneNumbers`), the fallback last.
        private var zones: [Zone]

        /// 1900-01-01 to 2200-01-01 UTC, in seconds since 1970: the proleptic Gregorian arithmetic
        /// and Foundation's calendar agree there (the Julian calendar ends in 1582).
        static let arithmeticRange: Range<TimeInterval> = -2_208_988_800 ..< 7_258_118_400

        /// - Parameters:
        ///   - zones: the zones of the photos' places by number (`ZoneNumbers`); nil for an
        ///     identifier Foundation does not know, which counts as none.
        ///   - fallback: the trip's zone, for photos whose place has none.
        init(zones: [TimeZone?], fallback: TimeZone) {
            self.zones = zones.map { Zone(zone: $0 ?? fallback) } + [Zone(zone: fallback)]
        }

        /// The local day of `date` in the zone numbered `zone`, or in the fallback for -1.
        mutating func day(_ date: Date, zone: Int) -> LocalDay {
            let index = zone >= 0 ? zone : zones.count - 1
            let seconds = date.timeIntervalSince1970
            guard seconds >= Self.arithmeticRange.lowerBound && seconds < Self.arithmeticRange.upperBound else {
                return LocalDay(date, timeZone: zones[index].zone)
            }
            return Self.civilDay(Int(((seconds + zones[index].offset(at: date)) / 86_400).rounded(.down)))
        }

        /// The Gregorian date `days` after 1970-01-01 (H. Hinnant's `civil_from_days`).
        static func civilDay(_ days: Int) -> LocalDay {
            let z = days + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let dayOfEra = z - era * 146_097
            let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
            let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
            let monthIndex = (5 * dayOfYear + 2) / 153
            let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
            let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
            return LocalDay(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
        }
    }

    // MARK: Points on the sphere

    /// A point on the unit sphere: the running centre of a day's group of photos (a spherical
    /// mean, right across the antimeridian and near the poles), the test whether two points lie
    /// within a place's radius, and the route's simplification.
    struct UnitVector: Sendable {
        var x: Double
        var y: Double
        var z: Double

        init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }

        init(_ c: GeoCoordinate) {
            let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
            self.init(x: cos(lat) * cos(lon), y: cos(lat) * sin(lon), z: sin(lat))
        }

        /// The coordinate it points to (any length); `nil` for the null vector.
        var coordinate: GeoCoordinate? {
            let horizontal = (x * x + y * y).squareRoot()
            guard horizontal > 1e-12 || abs(z) > 1e-12 else { return nil }
            return GeoCoordinate(latitude: atan2(z, horizontal) * 180 / .pi, longitude: atan2(y, x) * 180 / .pi)
        }

        var length: Double { (x * x + y * y + z * z).squareRoot() }

        /// Of length 1; `nil` for (almost) the null vector, which points nowhere.
        var normalized: UnitVector? {
            let length = length
            return length > 1e-12 ? scaled(1 / length) : nil
        }

        static func + (a: UnitVector, b: UnitVector) -> UnitVector { UnitVector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
        func scaled(_ factor: Double) -> UnitVector { UnitVector(x: x * factor, y: y * factor, z: z * factor) }
        func dot(_ o: UnitVector) -> Double { x * o.x + y * o.y + z * o.z }
        func cross(_ o: UnitVector) -> UnitVector { UnitVector(x: y * o.z - z * o.y, y: z * o.x - x * o.z, z: x * o.y - y * o.x) }
        /// The angle between two unit vectors, exact for small and large angles alike.
        func angle(to o: UnitVector) -> Double { atan2(cross(o).length, dot(o)) }
        /// The square of the straight line to `o`: for two unit vectors, it grows with the angle
        /// between them (`2 sin(angle / 2)`, squared) and stays exact for short distances.
        func chordSquared(to o: UnitVector) -> Double {
            let dx = x - o.x, dy = y - o.y, dz = z - o.z
            return dx * dx + dy * dy + dz * dz
        }
    }
}
