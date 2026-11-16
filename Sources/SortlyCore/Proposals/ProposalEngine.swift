import Foundation

/// Input to proposal generation: everything the analysis produced.
public struct AnalysisSnapshot: Sendable {
    public var facts: [AssetFacts]
    public var trips: [Trip]
    public var frequentPlaces: [FrequentPlace]
    /// Person/pet groups (confirmed and unconfirmed).
    public var groups: [ObservationGroup]
    /// Places the user said they are often at (Trips/RecurringPlaces.swift).
    public var recurringPlaces: [RecurringPlace]
    /// What the user set in "Dein Zuhause": the home of each date for trip names and place albums.
    public var home: HomeSettings

    public init(facts: [AssetFacts], trips: [Trip] = [], frequentPlaces: [FrequentPlace] = [], groups: [ObservationGroup] = [],
                recurringPlaces: [RecurringPlace] = [], home: HomeSettings = HomeSettings()) {
        self.facts = facts
        self.trips = trips
        self.frequentPlaces = frequentPlaces
        self.groups = groups
        self.recurringPlaces = recurringPlaces
        self.home = home
    }
}

/// Generates album proposals for all enabled areas (prompt §4, §7 Schritt 4–6).
/// Pure and deterministic: the same analysis produces the same proposal ids, so user
/// decisions stay attached across re-analysis.
public struct ProposalEngine: Sendable {
    public var settings: OrganizationSettings
    public var calendar: Calendar

    public init(settings: OrganizationSettings, calendar: Calendar = .sortlyDefault) {
        self.settings = settings
        self.calendar = calendar
    }

    var labels: Labels { Labels(settings.titleLanguage) }

    public func proposals(for analysis: AnalysisSnapshot, overrides: OverrideSet = OverrideSet()) -> [AlbumProposal] {
        suggestions(for: analysis, overrides: overrides).open
    }

    /// The suggestions to show, the ones the user dismissed, and which album stands for the
    /// photos that get no album of their own (`Suggestions`).
    public func suggestions(for analysis: AnalysisSnapshot, overrides: OverrideSet = OverrideSet()) -> Suggestions {
        let usable = analysis.facts.filter { !overrides.isExcluded($0.id) && !overrides.isIgnored($0.id) }
        let profile = LibraryProfile(facts: usable, trips: analysis.trips)
        let home = HomeContext(settings: analysis.home, profile: profile)
        var result: [AlbumProposal] = []
        var standIns: [StandIn] = []
        let areas = settings.enabledAreas
        if areas.contains(.places) { result += placeProposals(usable, profile: profile) }
        if areas.contains(.trips) { result += tripProposals(analysis.trips, facts: usable, profile: profile, home: home, routineVisits: &standIns) }
        if areas.contains(.frequentPlaces) { result += frequentPlaceProposals(analysis.frequentPlaces, facts: analysis.facts) }
        // A place the user is often at gets one album instead of its trips, so it comes with
        // either area (Trips/RecurringPlaces.swift).
        if areas.contains(.frequentPlaces) || areas.contains(.trips) { result += recurringPlaceProposals(analysis.recurringPlaces, facts: usable) }
        if areas.contains(.chronology) { result += chronologyProposals(usable) }
        if areas.contains(.mediaTypes) { result += mediaTypeProposals(usable) }
        if areas.contains(.screenshots) { result += screenshotProposals(usable, profile: profile) }
        if areas.contains(.imageCategories) { result += imageCategoryProposals(usable, profile: profile) }
        if areas.contains(.documents) { result += documentProposals(usable, profile: profile) }
        if areas.contains(.messenger) { result += messengerProposals(usable) }
        if areas.contains(.peopleAndPets) { result += groupProposals(analysis.groups) }
        // Curated before rejections are taken out: a trip the user said no to still stands for
        // its country, which would otherwise come back as the same photos under another name.
        let kept = curated(result, home: home, standIns: &standIns)
        if areas.contains(.places) { standIns += placesOfTrips(kept, standIns: standIns) }
        let dismissed = { (p: AlbumProposal) in overrides.isRejected(p.id) || overrides.mustNotRecreate(p.id) }
        return Suggestions(open: kept.filter { !dismissed($0) }, dismissed: kept.filter(dismissed),
                           standIns: Self.resolved(standIns, kept: Set(kept.map(\.id))))
    }

    // MARK: Places (4.1)

    func placeProposals(_ facts: [AssetFacts], profile: LibraryProfile = LibraryProfile()) -> [AlbumProposal] {
        let levels = settings.places.levels.sorted()
        guard !levels.isEmpty else { return [] }
        var groups: [PlaceKey: (components: PlaceComponents, assets: Set<AssetID>)] = [:]
        for f in facts {
            guard let place = f.gpsPlace else { continue }
            var deepest: PlaceKey?
            for level in levels {
                guard let key = place.key(at: level) else { continue }
                deepest = key
                if settings.allowMultipleAssignments {
                    groups[key, default: (place, [])].assets.insert(f.id)
                }
            }
            if !settings.allowMultipleAssignments, let deepest {
                groups[deepest, default: (place, [])].assets.insert(f.id)
            }
        }
        // One suggestion per country or region name: photos whose country came without its
        // code (or with another spelling of it) formed a second "Deutschland" next to the
        // first (first device test 15.11.). The larger group keeps its id, so decisions stay.
        // Towns are not merged: two towns of the same name are different places.
        var keysOf: [PlaceKey: [PlaceKey]] = [:]
        var keptByName: [String: PlaceKey] = [:]
        let bySize = groups.keys.sorted { a, b in
            let ca = groups[a]?.assets.count ?? 0, cb = groups[b]?.assets.count ?? 0
            return ca != cb ? ca > cb : a < b
        }
        for key in bySize {
            guard let value = groups[key] else { continue }
            keysOf[key] = [key]
            guard key.level <= .administrativeArea else { continue }
            // The continent is left out: it is only known together with the country code.
            let names = PlaceLevel.allCases.filter { $0 <= key.level && ($0 != .continent || key.level == .continent) }
                .compactMap { displayName(value.components, level: $0) }
            let identity = "\(key.level):" + names.map(PlaceKey.normalize).joined(separator: "/")
            if let kept = keptByName[identity] {
                groups[kept]?.assets.formUnion(value.assets)
                keysOf[kept, default: [kept]].append(key)
                groups[key] = nil
                keysOf[key] = nil
            } else {
                keptByName[identity] = key
            }
        }
        let base = labels.folder(for: .places)
        return groups.compactMap { key, value -> AlbumProposal? in
            guard profile.shots(in: value.assets) >= settings.places.minPhotos, let name = displayName(value.components, level: key.level) else { return nil }
            var path = [base]
            if settings.places.hierarchical {
                for parent in levels where parent < key.level {
                    if let n = displayName(value.components, level: parent) { path.append(n) }
                }
            }
            return AlbumProposal(
                id: .stable("place", key.description),
                kind: .placeCollection(key.level),
                title: name,
                folderPath: path,
                assetIDs: value.assets,
                reliability: .certain,
                reasons: [.photosInPlace(count: value.assets.count, place: name)],
                placeKeys: keysOf[key] ?? [key]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func displayName(_ c: PlaceComponents, level: PlaceLevel) -> String? {
        if level == .continent, let continent = c.continent {
            return DateRangeFormatter(language: settings.titleLanguage).continentName(continent)
        }
        return c.name(at: level)
    }

    // MARK: Trips (4.2)

    /// The template trips are named with. The stored default up to 15.11.2026 follows the new
    /// default: no screen ever let anyone choose a template, so it was nobody's choice.
    var tripTemplate: NamingTemplate {
        settings.trips.template == .tripDateRange ? .tripDefault : settings.trips.template
    }

    func tripProposals(_ trips: [Trip], facts: [AssetFacts], profile: LibraryProfile = LibraryProfile()) -> [AlbumProposal] {
        var routineVisits: [StandIn] = []
        return tripProposals(trips, facts: facts, profile: profile, home: HomeContext(profile: profile), routineVisits: &routineVisits)
    }

    /// - Parameters:
    ///   - home: whether a region or country is home at the trip's date (no trip is named after it).
    ///   - routineVisits: gets, per routine visit, the album of the place visited that stands
    ///     for it (a routine visit is not a trip of its own).
    func tripProposals(_ trips: [Trip], facts: [AssetFacts], profile: LibraryProfile, home: HomeContext,
                       routineVisits: inout [StandIn]) -> [AlbumProposal] {
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let collections = settings.trips.placeCollectionForRepeatedTrips
        let regular = collections ? regularDestinations(trips, facts: byID) : RegularDestinations()

        struct Draft {
            var trip: Trip
            var name: String
            var key: PlaceKey?
            var country: String?
            var places: [PlaceComponents]
            var formatter: DateRangeFormatter
            var path: [String]
            var title: String
        }
        var drafts: [Draft] = []
        for trip in trips where profile.shots(in: trip.geotaggedAssetIDs) >= settings.trips.minPhotos {
            if trip.kind == .dayTrip && !settings.trips.includeDayTrips { continue }
            // A routine visit (the parents' town, the lake every summer Sunday) is not a trip of
            // its own: its photos go to the one album of that destination below.
            if regular.outings.contains(trip.id) { continue }
            let places = trip.geotaggedAssetIDs.compactMap { byID[$0]?.gpsPlace }
            let (name, key, country) = Self.primaryPlaceName(places, kind: trip.kind, labels: labels,
                                                             isHome: { home.isHome($0, at: trip.start) })
            // The first day where the first photo was taken, the last day where the last one was
            // (the photos are in time order): Munich – New York – Tokyo ends on Tokyo's date.
            let zones = places.compactMap(\.timeZoneIdentifier)
            let timeZone = zones.first.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
            let formatter = DateRangeFormatter(language: settings.titleLanguage, timeZone: timeZone,
                                               endTimeZone: zones.last.flatMap(TimeZone.init(identifier:)))
            var path = [labels.folder(for: .trips)]
            if settings.trips.folderPerYear {
                var cal = calendar
                cal.timeZone = timeZone
                path.append(String(cal.component(.year, from: trip.start)))
            }
            let placeLabel = name ?? labels.unknownPlace
            drafts.append(Draft(trip: trip, name: placeLabel, key: key, country: country, places: places, formatter: formatter, path: path,
                                title: renderTripTitle(placeLabel, country: country, places: places, trip: trip, formatter: formatter, precise: false)))
        }
        // Two trips with the same title in the same folder ("Tegernsee, Juli 2025" twice) name
        // their days; the planner would refuse two new albums of the same name anyway.
        let clashes = Dictionary(grouping: drafts.indices) { drafts[$0].path + [drafts[$0].title] }.values.filter { $0.count > 1 }
        for group in clashes {
            for i in group {
                let d = drafts[i]
                drafts[i].title = renderTripTitle(d.name, country: d.country, places: d.places, trip: d.trip, formatter: d.formatter, precise: true)
            }
        }

        var result: [AlbumProposal] = drafts.map { d in
            let visited = Self.visitedTowns(d.places, labels: labels) ?? d.name
            return AlbumProposal(
                id: d.trip.id,
                kind: .trip,
                title: d.title,
                folderPath: d.path,
                assetIDs: Set(d.trip.geotaggedAssetIDs),
                optionalAssetIDs: Set(d.trip.inferredAssetIDs),
                reliability: d.name == labels.unknownPlace ? .plausible : .likely,
                reasons: [.photosInPlaceDuringPeriod(count: d.trip.geotaggedAssetIDs.count, place: visited, start: d.trip.start, end: d.trip.end)]
                    + (d.trip.inferredAssetIDs.isEmpty ? [] : [.inferredWithoutLocation(count: d.trip.inferredAssetIDs.count)]),
                dateRange: DateInterval(start: d.trip.start, end: d.trip.end),
                placeKeys: d.key.map { [$0] } ?? []
            )
        }
        guard collections else { return result.sorted(by: Self.byStart) }

        // One album per place the user goes to again and again (Scenario B): every routine
        // visit there, and the longer trips there too.
        var made = Set<SortlyID>()
        let tripsByID = Dictionary(trips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for destination in regular.destinations {
            let places = destination.members.compactMap { byID[$0]?.gpsPlace }
            let firstVisit = destination.members.compactMap { byID[$0]?.asset.creationDate }.min()
            let (name, key, _) = Self.primaryPlaceName(places, kind: .shortTrip, labels: labels,
                                                       isHome: { home.isHome($0, at: firstVisit) })
            guard profile.shots(in: destination.members) >= settings.trips.minPhotos, let name else { continue }
            let id = SortlyID.stable("trip-place", key?.description ?? destination.anchor)
            guard made.insert(id).inserted else { continue }
            result.append(collection(id: id, name: name, key: key, members: destination.members, facts: byID))
            // The routine visits there have no trip album: this album is theirs.
            let members = Set(destination.members)
            for tripID in destination.trips where regular.outings.contains(tripID) {
                guard let trip = tripsByID[tripID] else { continue }
                let visit = members.intersection(trip.geotaggedAssetIDs)
                if !visit.isEmpty {
                    routineVisits.append(StandIn(area: .trips, suggestion: id, dropped: tripID, assetIDs: visit, reason: .routineVisit))
                }
            }
        }
        // Repeated trips to the same place get that place's album next to the trips. Day trips
        // do not count: two afternoons in Innsbruck made three albums of the same 40 photos.
        var tripsPerPlace: [PlaceKey: [Draft]] = [:]
        for d in drafts where d.trip.kind != .dayTrip { if let key = d.key { tripsPerPlace[key, default: []].append(d) } }
        for (key, repeated) in tripsPerPlace where repeated.count >= 2 {
            let id = SortlyID.stable("trip-place", key.description)
            guard made.insert(id).inserted else { continue }
            let members = repeated.flatMap(\.trip.geotaggedAssetIDs)
            result.append(collection(id: id, name: repeated[0].name, key: key, members: members, facts: byID))
        }
        return result.sorted(by: Self.byStart)
    }

    private static func byStart(_ a: AlbumProposal, _ b: AlbumProposal) -> Bool {
        (a.dateRange?.start ?? .distantPast, a.id.rawValue) < (b.dateRange?.start ?? .distantPast, b.id.rawValue)
    }

    private func renderTripTitle(_ place: String, country: String?, places: [PlaceComponents], trip: Trip, formatter: DateRangeFormatter, precise: Bool) -> String {
        tripTemplate.render(
            .init(place: place, country: country, region: places.first?.administrativeArea, city: places.first?.locality,
                  start: trip.start, end: trip.end, preciseDates: precise),
            formatter: formatter
        )
    }

    /// The album of a place visited on several trips: "Tegernsee", with when and how often.
    private func collection(id: SortlyID, name: String, key: PlaceKey?, members: [AssetID], facts: [AssetID: AssetFacts]) -> AlbumProposal {
        let assets = Set(members)
        let dates = members.compactMap { facts[$0]?.asset.creationDate }
        let days = Set(dates.map { calendar.startOfDay(for: $0) }).count
        var reasons: [ProposalReason] = []
        if let first = dates.min(), let last = dates.max() {
            reasons.append(.photosInPlaceDuringPeriod(count: assets.count, place: name, start: first, end: last))
        } else {
            reasons.append(.photosInPlace(count: assets.count, place: name))
        }
        if days > 1 { reasons.append(.recurringPlace(count: assets.count, days: days)) }
        return AlbumProposal(
            id: id,
            kind: .placeCollection(key?.level ?? .locality),
            title: name,
            folderPath: [labels.folder(for: .trips)],
            assetIDs: assets,
            reliability: .likely,
            reasons: reasons,
            placeKeys: key.map { [$0] } ?? []
        )
    }

    /// Short trips to places the user goes to again and again, found by where they went, not
    /// by name: a town name alone would join two different lakes of one district.
    struct RegularDestinations {
        struct Destination {
            /// Every photo taken there from the first visit to the last.
            var members: [AssetID]
            /// Fallback identity when the place has no name yet.
            var anchor: String
            /// The short trips with days there (routine visits among them).
            var trips: [SortlyID] = []
        }
        var destinations: [Destination] = []
        /// Short trips spent mostly at such places.
        var outings: Set<SortlyID> = []
    }

    /// Short trips (one to three days) to the same spot at least this often make it a regular
    /// destination: once is a trip, twice may be a coincidence, three times is a habit.
    static let regularVisits = 3
    /// Days whose photos lie within this distance of each other count as the same spot.
    static let destinationRadius: Double = 5_000
    /// A short trip is a routine visit when this share of its photos is at regular destinations.
    static let routineShare = 0.6

    func regularDestinations(_ trips: [Trip], facts: [AssetID: AssetFacts]) -> RegularDestinations {
        struct DayPoint { var trip: Int; var short: Bool; var members: [AssetID]; var point: GeoCoordinate }
        var points: [DayPoint] = []
        for (index, trip) in trips.enumerated() {
            let short = trip.kind == .dayTrip || trip.kind == .weekendTrip || trip.kind == .shortTrip
            var byDay: [Date: [(AssetID, GeoCoordinate)]] = [:]
            for id in trip.geotaggedAssetIDs {
                guard let asset = facts[id]?.asset, let c = asset.usableLocation, let date = asset.creationDate else { continue }
                byDay[calendar.startOfDay(for: date), default: []].append((id, c))
            }
            for day in byDay.keys.sorted() {
                let items = byDay[day] ?? []
                // The median, not the mean: the drive there does not move the spot.
                let lat = items.map(\.1.latitude).sorted()[items.count / 2]
                let lon = items.map(\.1.longitude).sorted()[items.count / 2]
                points.append(DayPoint(trip: index, short: short, members: items.map(\.0), point: GeoCoordinate(latitude: lat, longitude: lon)))
            }
        }
        guard !points.isEmpty else { return RegularDestinations() }
        let clusters = GeoClusterer(epsilonMeters: Self.destinationRadius, minPoints: 1).cluster(points.map(\.point)).clusters
        var result = RegularDestinations()
        var routineMembers: [Int: Int] = [:]
        let located = facts.values.compactMap { f -> (id: AssetID, at: GeoCoordinate, date: Date)? in
            guard let c = f.asset.usableLocation, let date = f.asset.creationDate else { return nil }
            return (f.id, c, date)
        }
        for cluster in clusters {
            let shortTrips = Set(cluster.memberIndices.filter { points[$0].short }.map { points[$0].trip })
            guard shortTrips.count >= Self.regularVisits else { continue }
            // Every photo taken there from the first visit to the last, also on visits too short
            // to count as a trip: the album of the parents' town holds every visit. Nothing from
            // before or after: somebody who lived in Hamburg until last year and now visits it
            // gets the visits, not the years of everyday life there.
            let visits = Set(cluster.memberIndices.map { points[$0].trip }).map { trips[$0] }
            guard let first = visits.map(\.start).min(), let last = visits.map(\.end).max() else { continue }
            let from = calendar.startOfDay(for: first)
            let until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) ?? last
            let spots = GeoSpatialIndex(cellSize: Self.destinationRadius, points: cluster.memberIndices.map { (points[$0].point, $0) })
            let reach = (cluster.memberIndices.map { GeoMath.distance(points[$0].point, cluster.centroid) }.max() ?? 0) + Self.destinationRadius
            let members = located.filter { photo in
                photo.date >= from && photo.date < until && GeoMath.distance(photo.at, cluster.centroid) <= reach
                    && !spots.query(near: photo.at, radius: Self.destinationRadius).isEmpty
            }.map(\.id).sorted()
            let anchor = String(format: "%.2f,%.2f", cluster.centroid.latitude, cluster.centroid.longitude)
            result.destinations.append(.init(members: members, anchor: anchor, trips: shortTrips.sorted().map { trips[$0].id }))
            for i in cluster.memberIndices where points[i].short { routineMembers[points[i].trip, default: 0] += points[i].members.count }
        }
        for (index, count) in routineMembers {
            let trip = trips[index]
            let located = trip.geotaggedAssetIDs.filter { facts[$0]?.asset.usableLocation != nil }.count
            if located > 0, Double(count) >= Double(located) * Self.routineShare { result.outings.insert(trip.id) }
        }
        return result
    }

    /// A trip with this share of its photos in one country is a trip to that country; a day
    /// across the border does not change its name.
    static let oneCountryShare = 0.8

    /// Most fitting name for a set of places (prompt §4.2), in this order:
    /// 1. a lake holding 60 % of the photos ("Gardasee"),
    /// 2. a town holding 60 % of the photos ("Rom"),
    /// 3. a region – at home always, abroad only a plain one ("Sardinien", "Toskana"): composite
    ///    administrative names like "Marrakesch-Safi" or "Split-Dalmatien" read like a form, the
    ///    country is what people call such a trip; never the home region ("Bayern" for a
    ///    weekend near Munich says nothing),
    /// 4. the country, unless it is the home country ("Kroatien"; road trips "Kroatien-Roadtrip"),
    /// 5. the two or three towns that hold most photos ("Salzburg & Berchtesgaden"),
    /// 6. the countries in the order they were visited ("Portugal & Spanien").
    /// Regions and countries (3, 4) only name a trip that stayed (almost) in one country.
    static func primaryPlaceName(_ places: [PlaceComponents], kind: TripKind, labels: Labels,
                                 profile: LibraryProfile = LibraryProfile()) -> (String?, PlaceKey?, String?) {
        primaryPlaceName(places, kind: kind, labels: labels, isHome: profile.isEveryday)
    }

    /// - Parameter isHome: whether a country or region is home at the trip's time
    ///   (`HomeContext.isHome(_:at:)`).
    static func primaryPlaceName(_ places: [PlaceComponents], kind: TripKind, labels: Labels,
                                 isHome: (PlaceKey) -> Bool) -> (String?, PlaceKey?, String?) {
        guard !places.isEmpty else { return (nil, nil, nil) }
        func dominant(_ level: PlaceLevel) -> (String, PlaceKey)? {
            var counts: [PlaceKey: (String, Int)] = [:]
            for p in places {
                guard let key = p.key(at: level), let name = p.name(at: level) else { continue }
                counts[key, default: (name, 0)].1 += 1
            }
            guard let best = counts.max(by: { ($0.value.1, $1.key) < ($1.value.1, $0.key) }) else { return nil }
            return Double(best.value.1) / Double(places.count) >= 0.6 ? (best.value.0, best.key) : nil
        }
        let country = dominant(.country)
        let atHome = country.map { isHome($0.1) } ?? false
        // Photos on the lake itself name the trip after the lake: "Gardasee", not "Malcesine".
        if let area = places.compactMap(\.inlandWater).first, kind != .roadTrip,
           Double(places.filter { $0.inlandWater == area }.count) / Double(places.count) >= 0.6 {
            return (area, places.first { $0.inlandWater == area }?.key(at: .pointOfInterest), country?.0)
        }
        if kind != .roadTrip, let city = dominant(.locality) { return (city.0, city.1, country?.0) }
        // A region or a country names a trip that stayed there: a tour from Lisbon to Granada is
        // neither an "Andalusien-Roadtrip" nor a "Spanien-Roadtrip" because most photos were
        // taken in Spain.
        let oneCountry = country.map { c in
            Double(places.filter { $0.key(at: .country) == c.1 }.count) >= Double(places.count) * Self.oneCountryShare
        } ?? true
        if oneCountry, let region = dominant(.administrativeArea), !isHome(region.1),
           country == nil || atHome || !region.0.contains("-") {
            return (kind == .roadTrip ? "\(region.0)-\(labels.roadTripSuffix)" : region.0, region.1, country?.0)
        }
        if let country, oneCountry, !atHome {
            return (kind == .roadTrip ? "\(country.0)-\(labels.roadTripSuffix)" : country.0, country.1, country.0)
        }
        // Two or three towns that hold most of the photos.
        let towns = rankedTowns(places)
        let top = towns.prefix(3)
        if !top.isEmpty, Double(top.reduce(0) { $0 + $1.count }) >= Double(places.count) * 0.8 {
            let names = top.map(\.name)
            let title = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
            return (title, top.count == 1 ? top.first?.key : nil, country?.0)
        }
        if let country, oneCountry {
            // A long trip through the home country.
            return (kind == .roadTrip ? "\(country.0)-\(labels.roadTripSuffix)" : country.0, country.1, country.0)
        }
        var seen = Set<String>()
        let names = places.compactMap(\.country).filter { seen.insert($0).inserted }.prefix(3)
        return (names.isEmpty ? nil : names.joined(separator: " & "), nil, nil)
    }

    /// Towns by number of photos (ties: first visited first).
    private static func rankedTowns(_ places: [PlaceComponents]) -> [(name: String, key: PlaceKey, count: Int, first: Int)] {
        var towns: [PlaceKey: (name: String, count: Int, first: Int)] = [:]
        for (i, p) in places.enumerated() {
            guard let key = p.key(at: .locality), let name = p.locality else { continue }
            towns[key, default: (name, 0, i)].count += 1
        }
        return towns.map { (name: $0.value.name, key: $0.key, count: $0.value.count, first: $0.value.first) }
            .sorted { ($0.count, -$0.first) > ($1.count, -$1.first) }
    }

    /// The towns a trip went to, for its reason: "Split, Hvar und Dubrovnik". Up to four, in the
    /// order they were visited; nil when the towns are not known yet.
    static func visitedTowns(_ places: [PlaceComponents], labels: Labels) -> String? {
        let towns = rankedTowns(places)
        guard !towns.isEmpty else { return nil }
        // Towns with only a photo or two (a stop on the motorway) are left out.
        let minimum = max(1, places.count / 20)
        let shown = towns.filter { $0.count >= minimum }.prefix(4).sorted { $0.first < $1.first }.map(\.name)
        return shown.isEmpty ? nil : labels.list(shown)
    }

    // MARK: Frequent places (4.3)

    /// At most this many places without a name are offered, the most visited ones. A long tail
    /// of "Häufiger Ort 12 … 44" asks for names nobody can give (first device test 15.11.).
    static let maxUnnamedFrequentPlaces = 5

    func frequentPlaceProposals(_ places: [FrequentPlace], facts: [AssetFacts] = []) -> [AlbumProposal] {
        let placeOf = Dictionary(facts.compactMap { f in f.place.map { (f.id, $0) } }, uniquingKeysWith: { first, _ in first })
        var unnamed = 0
        var perCity: [String: Int] = [:]
        var result: [AlbumProposal] = []
        // Most visited first (the detector's order), so the cap keeps the places that matter.
        for place in places {
            let name = settings.frequentPlaces.names[place.id] ?? place.userName
            var title = name ?? ""
            if name == nil {
                unnamed += 1
                if unnamed > Self.maxUnnamedFrequentPlaces { continue }
                // "Häufiger Ort in München" says which place is meant; a number alone does not.
                if let city = Self.dominantCity(of: place.assetIDs, in: placeOf) {
                    perCity[city, default: 0] += 1
                    let n = perCity[city] ?? 1
                    title = n == 1 ? labels.frequentPlacePlaceholder(in: city) : "\(labels.frequentPlacePlaceholder(in: city)) \(n)"
                } else {
                    title = labels.frequentPlacePlaceholder(number: unnamed)
                }
            }
            result.append(AlbumProposal(
                id: place.id,
                kind: .frequentPlace,
                title: title,
                folderPath: [labels.folder(for: .frequentPlaces)],
                assetIDs: Set(place.assetIDs),
                reliability: .likely,
                reasons: [.recurringPlace(count: place.photoCount, days: place.distinctDays)],
                dateRange: DateInterval(start: place.firstDate, end: place.lastDate),
                isSensitive: true,
                requiresUserName: name == nil
            ))
        }
        return result
    }

    /// The town most of the place's photos were taken in (nil while towns are not known yet).
    static func dominantCity(of ids: [AssetID], in placeOf: [AssetID: PlaceComponents]) -> String? {
        var counts: [String: Int] = [:]
        for id in ids {
            guard let city = placeOf[id]?.locality ?? placeOf[id]?.subAdministrativeArea, !city.isEmpty else { continue }
            counts[city, default: 0] += 1
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: Chronology (4.9)

    func chronologyProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        let levels = settings.chronology.levels.sorted()
        guard let leaf = levels.last else { return [] }
        let grouper = ChronologyGrouper(calendar: calendar)
        let formatter = DateRangeFormatter(language: settings.titleLanguage, timeZone: calendar.timeZone)
        let (buckets, _) = grouper.group(facts.map(\.asset), levels: levels)
        var result: [AlbumProposal] = buckets.compactMap { path, assets in
            guard assets.count >= settings.chronology.minPhotos, let key = path.last else { return nil }
            let folders = [labels.folder(for: .chronology)] + path.dropLast().map(formatter.label(for:))
            return AlbumProposal(
                id: .stable("chrono", path.map(\.description).joined(separator: "/")),
                kind: .chronology(leaf),
                title: formatter.label(for: key),
                folderPath: folders,
                assetIDs: Set(assets),
                reliability: .certain,
                reasons: [.mediaType(count: assets.count, label: formatter.label(for: key))]
            )
        }
        for period in settings.chronology.customPeriods {
            let assets = Set(facts.filter { period.contains($0.asset.creationDate) }.map(\.id))
            guard !assets.isEmpty else { continue }
            result.append(AlbumProposal(
                id: period.id, kind: .customPeriod, title: period.title, folderPath: [labels.folder(for: .chronology)],
                assetIDs: assets, reliability: .certain,
                reasons: [.photosInPeriod(count: assets.count, start: period.start, end: period.end)],
                dateRange: DateInterval(start: period.start, end: period.end)
            ))
        }
        return result.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Media types (4.10)

    func mediaTypeProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        let classifier = MediaTypeClassifier()
        var groups: [MediaTypeCategory: Set<AssetID>] = [:]
        for f in facts {
            for c in classifier.categories(for: f.asset) where settings.mediaTypes.categories.contains(c) {
                groups[c, default: []].insert(f.id)
            }
        }
        return groups.compactMap { category, assets in
            guard assets.count >= settings.mediaTypes.minItems else { return nil }
            return AlbumProposal(
                id: .stable("mediatype", category.rawValue), kind: .mediaType(category.rawValue), title: labels.name(category),
                folderPath: [labels.folder(for: .mediaTypes)], assetIDs: assets, reliability: .certain,
                reasons: [.mediaType(count: assets.count, label: labels.name(category))]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Screenshots (4.6)

    /// Screenshot kinds that are real things to keep or find again (chats, recipes, orders,
    /// tickets, wish lists). Settings pages, error messages, sales, news, notes, how-tos and
    /// route screenshots are only useful in the moment: as albums they buried the useful ones
    /// (first device test 15.11.: 19 screenshot albums). Search still finds all of them.
    static let lastingScreenshotCategories: Set<ScreenshotCategory> = [
        .chat, .order, .invoice, .ticket, .flight, .hotel, .recipe, .product, .coupon, .socialMedia, .realEstate, .job, .qrCode,
    ]

    func screenshotProposals(_ facts: [AssetFacts], profile: LibraryProfile = LibraryProfile()) -> [AlbumProposal] {
        var groups: [ScreenshotCategory: Set<AssetID>] = [:]
        for f in facts where f.asset.subtypes.contains(.screenshot) {
            for raw in f.textCategories {
                if let c = ScreenshotCategory(rawValue: raw), Self.lastingScreenshotCategories.contains(c) { groups[c, default: []].insert(f.id) }
            }
        }
        // Five at least, and 1 % of the screenshots: three chats among 900 screenshots are noise.
        let minimum = LibraryProfile.scaled(max(settings.screenshots.minItems, 5), perMille: 10, of: profile.screenshotCount)
        return groups.compactMap { category, assets in
            guard assets.count >= minimum else { return nil }
            return AlbumProposal(
                id: .stable("screenshot", category.rawValue), kind: .screenshotCategory(category.rawValue), title: labels.name(category),
                folderPath: [labels.folder(for: .screenshots)], assetIDs: assets, reliability: .likely,
                reasons: [.recognizedText(count: assets.count, label: labels.name(category))]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Image categories (4.7)

    /// Categories the classifier finds in the background of ordinary photos rather than as
    /// their subject: every photo of people shows clothing, every room furniture, every street
    /// a building ("Immobilien"), every table a drink or a phone. As albums they were the
    /// biggest themes and the least useful ones (first device test 15.11.). Search still finds
    /// them ("Möbel"), and a search result can become an album.
    static let incidentalThemes: Set<String> = [
        "misc.clothing", "home.furniture", "home.interior", "home.realEstate", "home.garden", "misc.technology",
        "misc.shopping", "misc.collection", "work.tools", "work.documentation", "nature.landscape", "food.drink",
    ]
    /// A theme is something that comes back: photos of it on at least this many days. One
    /// afternoon at a horse farm is an event, not "Pferde".
    static let minimumThemeDays = 5
    /// At most this many themes, the biggest. Themes come after trips and places in the list,
    /// and a dozen of them pushed everything else out of sight; any other theme is one search
    /// away ("Kunst"), and a search result can be saved as an album.
    static let maximumThemes = 8

    func imageCategoryProposals(_ facts: [AssetFacts], profile: LibraryProfile = LibraryProfile()) -> [AlbumProposal] {
        var groups: [String: Set<AssetID>] = [:]
        var days: [String: Set<Date>] = [:]
        for f in facts where !f.asset.isScreenshotLike {
            for (id, reliability) in f.categories where reliability >= settings.imageCategories.minimumReliability {
                groups[id, default: []].insert(f.id)
                if let date = f.asset.creationDate { days[id, default: []].insert(calendar.startOfDay(for: date)) }
            }
        }
        // 15 photos at least, and 2.5 per thousand photos: 125 in a library of 50,000.
        let minimum = LibraryProfile.scaled(settings.imageCategories.minPhotos, perMille: 2.5, of: profile.photoCount)
        let themes = groups.compactMap { id, assets -> (category: ImageCategory, assets: Set<AssetID>)? in
            guard let category = ImageTaxonomy.byID[id], !settings.imageCategories.disabledCategories.contains(id),
                  !Self.incidentalThemes.contains(id), profile.shots(in: assets) >= minimum,
                  (days[id]?.count ?? 0) >= Self.minimumThemeDays else { return nil }
            if settings.imageCategories.leafCategoriesOnly && category.parentID == nil { return nil }
            return (category, assets)
        }
        .sorted { ($0.assets.count, $1.category.id) > ($1.assets.count, $0.category.id) }
        .prefix(Self.maximumThemes)
        // All in one folder "Themen": with a handful of themes, parent folders ("Natur",
        // "Weitere Bereiche") only put each album one tap further away.
        return themes.map { theme in
            let category = theme.category
            return AlbumProposal(
                id: .stable("category", category.id), kind: .imageCategory(category.id), title: labels.name(category),
                folderPath: [labels.folder(for: .imageCategories)],
                assetIDs: theme.assets, reliability: settings.imageCategories.minimumReliability,
                reasons: [.recognizedContent(count: theme.assets.count, label: labels.name(category))]
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Documents (4.8)

    func documentProposals(_ facts: [AssetFacts], profile: LibraryProfile = LibraryProfile()) -> [AlbumProposal] {
        var groups: [DocumentType: (assets: Set<AssetID>, sensitive: Bool)] = [:]
        for f in facts {
            guard let doc = f.document, doc.typeReliability >= .plausible else { continue }
            let sensitive = doc.sensitivity != .normal
            if sensitive && !settings.documents.includeSensitive { continue }
            groups[doc.type, default: ([], false)].assets.insert(f.id)
            if sensitive { groups[doc.type]?.sensitive = true }
        }
        // One receipt is not an album: four at least (a few warranty cards are worth keeping
        // together), more in big libraries. "Sonstige Dokumente" says nothing about its content.
        let minimum = LibraryProfile.scaled(max(settings.documents.minItems, 4), perMille: 0.5, of: profile.photoCount + profile.screenshotCount)
        return groups.compactMap { type, value in
            guard value.assets.count >= minimum, type != .other else { return nil }
            return AlbumProposal(
                id: .stable("document", type.rawValue), kind: .documentCategory(type.rawValue), title: labels.name(type),
                folderPath: [labels.folder(for: .documents)], assetIDs: value.assets, reliability: .plausible,
                reasons: [.recognizedText(count: value.assets.count, label: labels.name(type))],
                isSensitive: true
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: Messenger (4.5)

    func messengerProposals(_ facts: [AssetFacts]) -> [AlbumProposal] {
        var groups: [String: (app: MessengerApp, evidence: MessengerEvidence, assets: Set<AssetID>)] = [:]
        for f in facts {
            guard let m = f.messenger, m.evidence > .unknownOrigin else { continue }
            if m.evidence == .plausibleHint && !settings.messenger.includeHints { continue }
            let key = "\(m.app.rawValue).\(m.evidence.rawValue)"
            groups[key, default: (m.app, m.evidence, [])].assets.insert(f.id)
        }
        return groups.compactMap { key, value in
            guard value.assets.count >= settings.messenger.minItems else { return nil }
            let title = labels.name(value.app, evidence: value.evidence)
            return AlbumProposal(
                id: .stable("messenger", key), kind: .messenger(key), title: title,
                folderPath: [labels.folder(for: .messenger)], assetIDs: value.assets,
                reliability: value.evidence >= .existingAlbum ? .likely : .uncertain,
                reasons: [.recognizedContent(count: value.assets.count, label: title)],
                isSensitive: value.evidence < .existingAlbum
            )
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    // MARK: People and pets (4.4)

    func groupProposals(_ groups: [ObservationGroup]) -> [AlbumProposal] {
        var counters: [GroupKind: Int] = [:]
        return groups.compactMap { group in
            if group.kind == .person && !settings.people.faceGroupingEnabled { return nil }
            if group.kind != .person && !settings.people.petGroupingEnabled { return nil }
            counters[group.kind, default: 0] += 1
            let name = group.confirmedName ?? labels.groupPlaceholder(group.kind, number: counters[group.kind]!)
            return AlbumProposal(
                id: group.id, kind: .personOrPet, title: name, folderPath: [labels.folder(for: .peopleAndPets)],
                assetIDs: group.assetIDs, reliability: group.isConfirmed ? .certain : .uncertain,
                reasons: [.confirmedGroup(count: group.assetIDs.count, name: name)],
                isSensitive: true,
                requiresUserName: group.confirmedName == nil
            )
        }
    }
}

/// Figures for the result overview (prompt §7, Schritt 4).
public struct AreaOverview: Hashable, Sendable, Identifiable {
    public var area: OrganizationArea
    public var proposalCount: Int
    public var distinctAssets: Int
    public var existingMatches: Int
    public var newAlbumsNeeded: Int
    public var extendable: Int
    public var uncertain: Int
    public var id: OrganizationArea { area }

    public static func make(proposals: [AlbumProposal], matches: [SortlyID: MatchResult]) -> [AreaOverview] {
        var byArea: [OrganizationArea: [AlbumProposal]] = [:]
        for p in proposals { byArea[p.kind.area, default: []].append(p) }
        let matcher = AlbumMatcher()
        return OrganizationArea.allCases.compactMap { area in
            guard let ps = byArea[area] else { return nil }
            var assets = Set<AssetID>()
            var existing = 0, new = 0, extendable = 0, uncertain = 0
            for p in ps {
                assets.formUnion(p.assetIDs)
                let status = matches[p.id]?.status
                // "In deinen Alben" only where the photos count as sorted (`sortingAlbums`).
                let sorted = !matcher.sortingAlbums(matches[p.id], kind: p.kind, title: p.title).isEmpty
                switch status {
                case .alreadyComplete: existing += 1
                case .multipleMatches: if sorted { existing += 1 }
                case .extendable: existing += 1; extendable += 1
                // A possible match gets an album of its own (review 16.11.).
                case .possibleMatch, .newAlbumRequired, .nameConflict, .notEditable, .none: new += 1
                case .ambiguous: break
                }
                // One count per suggestion, whatever makes it uncertain.
                if status == .ambiguous || p.reliability < .likely || p.requiresUserName { uncertain += 1 }
            }
            return AreaOverview(area: area, proposalCount: ps.count, distinctAssets: assets.count, existingMatches: existing,
                                newAlbumsNeeded: new, extendable: extendable, uncertain: uncertain)
        }
    }
}
