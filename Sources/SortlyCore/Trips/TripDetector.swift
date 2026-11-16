import Foundation

public enum TripKind: String, Sendable, Codable, CaseIterable {
    case dayTrip, weekendTrip, shortTrip, vacation, roadTrip
}

/// A detected trip (prompt §4.2). The date range is the span of the photos, not a proven
/// arrival/departure.
public struct Trip: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var start: Date
    public var end: Date
    /// Members with GPS evidence away from the habitual area.
    public var geotaggedAssetIDs: [AssetID]
    /// Members without GPS proposed only by time window. Always need confirmation.
    public var inferredAssetIDs: [AssetID]
    public var centroid: GeoCoordinate
    public var maxDistanceFromHomeMeters: Double
    /// Number of distinct overnight areas (~25 km cells with photos on ≥1 evening).
    public var distinctStops: Int
    public var kind: TripKind

    public var allAssetIDs: [AssetID] { geotaggedAssetIDs + inferredAssetIDs }
}

/// User corrections that survive re-analysis because they are expressed in time,
/// not in volatile ids (prompt §4.2: "Speichere solche Korrekturen dauerhaft").
public struct TripCorrections: Hashable, Sendable, Codable {
    /// Always split a trip at these instants.
    public var forcedBreaks: [Date] = []
    /// Never split inside these intervals (manual merge).
    public var forcedJoins: [DateInterval] = []
    /// Assets the user removed from trips.
    public var excludedAssets: Set<AssetID> = []

    public init(forcedBreaks: [Date] = [], forcedJoins: [DateInterval] = [], excludedAssets: Set<AssetID> = []) {
        self.forcedBreaks = forcedBreaks
        self.forcedJoins = forcedJoins
        self.excludedAssets = excludedAssets
    }
}

public struct TripDetector: Sendable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Photos closer than this to the habitual area count as "at home".
        public var homeRadiusMeters: Double = 30_000
        /// Split when there are no away-photos for longer than this.
        public var maxGap: TimeInterval = 3 * 86_400
        /// Longer allowed gap when both sides are far away and close to each other
        /// (long vacation with photo-less days).
        public var maxGapFarAway: TimeInterval = 7 * 86_400
        public var farAwayMeters: Double = 300_000
        /// A trip ends when the user is back home for longer than this.
        public var homeInterludeTolerance: TimeInterval = 10 * 3_600
        public var minPhotos: Int = 5
        /// Window around the trip in which non-GPS photos may be proposed.
        public var inferenceTolerance: TimeInterval = 2 * 3_600
        /// Window for the time-local habitual area (people move house).
        public var homeWindowDays: Int = 120

        public init() {}
    }

    public var configuration: Configuration
    public var calendar: Calendar

    public init(configuration: Configuration = .init(), calendar: Calendar = .sortlyDefault) {
        self.configuration = configuration
        self.calendar = calendar
    }

    /// - Parameters:
    ///   - assets: all assets (with and without GPS).
    ///   - corrections: persisted user corrections.
    ///   - places: the user's answers to "Bist du hier öfter?".
    ///   - home: what the user set in "Dein Zuhause" (`HomeSettings.home(at:)`).
    ///   - excludeFromInference: returns true for assets that must never be added to a trip
    ///     purely by time (screenshots, messenger media, downloads – prompt §4.2).
    public func detect(
        in assets: [AssetSnapshot],
        corrections: TripCorrections = .init(),
        places: RecurringPlaceAnswers = .init(),
        home homeSettings: HomeSettings = .init(),
        excludeFromInference: (AssetSnapshot) -> Bool = { _ in false }
    ) -> [Trip] {
        analyse(in: assets, corrections: corrections, places: places, home: homeSettings, excludeFromInference: excludeFromInference).trips
    }

    /// The trips, every stay away (also those too small for a trip, to notice places the user
    /// goes to again and again), and the photos at the places the user said they are often at.
    public func analyse(
        in assets: [AssetSnapshot],
        corrections: TripCorrections = .init(),
        places: RecurringPlaceAnswers = .init(),
        home homeSettings: HomeSettings = .init(),
        excludeFromInference: (AssetSnapshot) -> Bool = { _ in false }
    ) -> TripAnalysis {
        let geotagged = assets
            .filter { $0.usableLocation != nil && $0.creationDate != nil && !$0.isScreenshotLike && !corrections.excludedAssets.contains($0.id) }
            .sorted { ($0.creationDate!, $0.id) < ($1.creationDate!, $1.id) }
        guard !geotagged.isEmpty else { return TripAnalysis(trips: [], stays: [], places: []) }

        // A place the user is often at counts like the habitual area, at every time: its stays
        // are not trips, and an excursion from there starts there.
        let oftenHere = places.oftenHere
        let detection = HabitualArea(assets: geotagged, calendar: calendar, windowDays: configuration.homeWindowDays,
                                     homeRadius: configuration.homeRadiusMeters, extraHomes: oftenHere.map(\.center))
        // The home the user chose wins over the detection, date by date (`HomeSettings.home(at:)`).
        let home = HomeReference(detection: detection, settings: homeSettings, radius: configuration.homeRadiusMeters,
                                 extraHomes: oftenHere.map(\.center))

        struct Segment {
            var members: [AssetSnapshot] = []
            var lastAway: Date
            var lastCoordinate: GeoCoordinate
            var firstHomeAfterLastAway: Date?
        }

        var segments: [[AssetSnapshot]] = []
        /// Per segment: it starts where the user split a trip (Reise-Werkstatt).
        var splitBefore: [Bool] = []
        var current: Segment?
        var currentSplit = false

        func joinProtects(_ a: Date, _ b: Date) -> Bool {
            corrections.forcedJoins.contains { $0.contains(a) && $0.contains(b) }
        }
        func forcedBreakBetween(_ a: Date, _ b: Date) -> Bool {
            corrections.forcedBreaks.contains { $0 > a && $0 <= b }
        }
        /// The user moved on from one place they stayed at for weeks to the next one (digital
        /// nomad): a new trip starts, as if they had been back home in between.
        func movedOnBetween(_ a: Date, _ b: Date) -> Bool {
            home.movedOn.contains { $0 > a && $0 <= b }
        }

        for asset in geotagged {
            let date = asset.creationDate!
            let coordinate = asset.usableLocation!
            let distanceHome = home.distanceToHome(coordinate, at: date)
            let isAway = distanceHome > configuration.homeRadiusMeters

            if isAway {
                if var seg = current {
                    let gap = date.timeIntervalSince(seg.lastAway)
                    let bothFar = distanceHome > configuration.farAwayMeters
                        && home.distanceToHome(seg.lastCoordinate, at: seg.lastAway) > configuration.farAwayMeters
                        && GeoMath.distance(coordinate, seg.lastCoordinate) < configuration.farAwayMeters / 2
                    let allowedGap = bothFar ? configuration.maxGapFarAway : configuration.maxGap
                    let cameHome = seg.firstHomeAfterLastAway.map { date.timeIntervalSince($0) > configuration.homeInterludeTolerance } ?? false
                        || wentHomeUnseen(from: seg.lastCoordinate, at: seg.lastAway, to: coordinate, at: date, home: home)
                    let protected = joinProtects(seg.lastAway, date)
                    let mustBreak = forcedBreakBetween(seg.lastAway, date)
                    let naturalBreak = !protected && (gap > allowedGap || cameHome || movedOnBetween(seg.lastAway, date))
                    if mustBreak || naturalBreak {
                        segments.append(seg.members)
                        splitBefore.append(currentSplit)
                        current = Segment(members: [asset], lastAway: date, lastCoordinate: coordinate)
                        // Only the user's split made two parts here.
                        currentSplit = mustBreak && !naturalBreak
                    } else {
                        seg.members.append(asset)
                        seg.lastAway = date
                        seg.lastCoordinate = coordinate
                        seg.firstHomeAfterLastAway = nil
                        current = seg
                    }
                } else {
                    current = Segment(members: [asset], lastAway: date, lastCoordinate: coordinate)
                    currentSplit = false
                }
            } else if var seg = current {
                if seg.firstHomeAfterLastAway == nil {
                    seg.firstHomeAfterLastAway = date
                    current = seg
                }
            }
        }
        if let seg = current {
            segments.append(seg.members)
            splitBefore.append(currentSplit)
        }

        // A trip the user split stays split into all its parts, however small a part is, as
        // long as the whole trip was big enough to be found (audit 2, 2.1): the workshop
        // promised exactly these parts.
        var keep = segments.map { $0.count >= configuration.minPhotos }
        var groupStart = 0
        for index in segments.indices {
            let endsGroup = index + 1 == segments.count || !splitBefore[index + 1]
            guard endsGroup else { continue }
            let group = groupStart...index
            if group.count > 1, group.reduce(0, { $0 + segments[$1].count }) >= configuration.minPhotos {
                for member in group { keep[member] = true }
            }
            groupStart = index + 1
        }
        let nonGeo = assets
            .filter { $0.usableLocation == nil && $0.creationDate != nil && !$0.isScreenshotLike && ($0.kind == .image || $0.kind == .video) }
            .filter { !corrections.excludedAssets.contains($0.id) && !excludeFromInference($0) }
            .sorted { ($0.creationDate!, $0.id) < ($1.creationDate!, $1.id) }
        let breaks = corrections.forcedBreaks.sorted()

        var trips: [Trip] = []
        var stays: [AwayStay] = []
        for (index, members) in segments.enumerated() {
            let photos = members.map { (date: $0.creationDate!, coordinate: $0.usableLocation!) }
            var stay = AwayStay(start: photos.first!.date, end: photos.last!.date,
                                mainPlace: RecurringPlaces.mainPlace(of: photos, calendar: calendar) ?? photos[0].coordinate,
                                photoCount: members.count, tripIndex: nil)
            if keep[index] {
                stay.tripIndex = trips.count
                trips.append(makeTrip(members, home: home, nonGeo: nonGeo, breaks: breaks))
            }
            stays.append(stay)
        }
        // Where the user lives: never a place album of its own, so these photos do not count
        // for "Länder und Orte" (decision Fuchs 15.11.: the home town and its surroundings, not
        // the whole home country).
        let atHome = geotagged.filter { asset in home.isAtHome(asset.usableLocation!, at: asset.creationDate!) }
        return TripAnalysis(trips: trips, stays: stays, places: placesOftenVisited(oftenHere, photos: geotagged, home: home),
                            atHome: Set(atHome.map(\.id)),
                            detectedHome: detection.mainHome(at: geotagged.last!.creationDate!))
    }

    /// Within a day trip of the habitual area: a place the user can go to and come back from
    /// on one day.
    static let dayTripReachMeters: Double = 150_000
    /// A whole day without a single photo.
    static let silentDay: TimeInterval = 24 * 3_600

    /// Most people take no photo at home on the evening they come back. Two stays at different
    /// places with no photo in between are still two outings when the user most likely slept
    /// at home in between (simulated library: the parents' town on Saturday and the lake on
    /// Sunday became one weekend trip, a day in Innsbruck two days after Sardinia part of it):
    /// - a night lay between them and the way from one to the other passes the habitual area
    ///   anyway (at most `2 × homeRadius` longer than the direct way), or
    /// - a whole day passed without a photo and one of them is within a day trip of the
    ///   habitual area.
    /// Stops of one journey far from home (a road trip, a semester's weekends) are never split
    /// this way: home is not on their way and they are out of day-trip reach.
    private func wentHomeUnseen(from a: GeoCoordinate, at aDate: Date, to b: GeoCoordinate, at bDate: Date, home: HomeReference) -> Bool {
        let apart = GeoMath.distance(a, b)
        guard apart > configuration.homeRadiusMeters else { return false }
        let gap = bDate.timeIntervalSince(aDate)
        if gap > configuration.homeInterludeTolerance,
           home.wayViaHome(a, b, at: bDate) <= apart + 2 * configuration.homeRadiusMeters { return true }
        if gap >= Self.silentDay,
           min(home.distanceToHome(a, at: aDate), home.distanceToHome(b, at: bDate)) <= Self.dayTripReachMeters { return true }
        return false
    }

    /// The photos of each place the user is often at: the stays there that would otherwise be
    /// trips. Within the habitual radius of the place, closer to it than to the habitual area of
    /// that time (a place near the usual one does not take everyday photos away from it), and
    /// not from a time the place was part of the habitual area itself (the town the user
    /// lived in before moving away and now visits).
    private func placesOftenVisited(_ answers: [PlaceAnswer], photos: [AssetSnapshot], home: HomeReference) -> [RecurringPlace] {
        guard !answers.isEmpty else { return [] }
        var members = [[AssetSnapshot]](repeating: [], count: answers.count)
        for asset in photos {
            let coordinate = asset.usableLocation!, date = asset.creationDate!
            let distances = answers.map { GeoMath.distance($0.center, coordinate) }
            guard let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }),
                  distances[nearest] <= configuration.homeRadiusMeters,
                  distances[nearest] < home.distanceToUsualHome(coordinate, at: date),
                  home.distanceToUsualHome(answers[nearest].center, at: date) > configuration.homeRadiusMeters else { continue }
            members[nearest].append(asset)
        }
        return answers.indices.compactMap { index in
            let assets = members[index]
            guard let first = assets.first?.creationDate, let last = assets.last?.creationDate else { return nil }
            return RecurringPlace(
                id: answers[index].id,
                center: answers[index].center,
                name: answers[index].name,
                assetIDs: assets.map(\.id),
                distinctDays: Set(assets.map { calendar.startOfDay(for: $0.creationDate!) }).count,
                firstDate: first,
                lastDate: last
            )
        }
    }

    private func makeTrip(_ members: [AssetSnapshot], home: HomeReference, nonGeo: [AssetSnapshot], breaks: [Date]) -> Trip {
        let start = members.first!.creationDate!
        let end = members.last!.creationDate!
        let coordinates = members.map { $0.usableLocation! }
        let centroid = GeoMath.centroid(coordinates) ?? coordinates[0]
        // Without a known home (a small library, or GPS only on trips) the distance is
        // "far", not infinite: infinity cannot be stored as JSON and failed every run.
        let maxDistance = zip(members, coordinates).map { min(home.distanceToHome($1, at: $0.creationDate!), .greatestFiniteMagnitude) }.max() ?? 0

        // Inferred members: binary search the time window. A split by the user is a hard
        // edge: a photo without GPS belongs to the part on its side only (audit 2, 2.2).
        var lower = start.addingTimeInterval(-configuration.inferenceTolerance)
        var upper = end.addingTimeInterval(configuration.inferenceTolerance)
        var upperIsOpen = false
        if let edge = breaks.last(where: { $0 <= start }), edge > lower { lower = edge }
        if let edge = breaks.first(where: { $0 > end }), edge <= upper {
            upper = edge
            upperIsOpen = true
        }
        var lo = 0, hi = nonGeo.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if nonGeo[mid].creationDate! < lower { lo = mid + 1 } else { hi = mid }
        }
        var inferred: [AssetID] = []
        var i = lo
        while i < nonGeo.count, upperIsOpen ? nonGeo[i].creationDate! < upper : nonGeo[i].creationDate! <= upper {
            inferred.append(nonGeo[i].id)
            i += 1
        }

        let (kind, stops) = Self.classify(dates: members.map { $0.creationDate! }, coordinates: coordinates, calendar: calendar)

        return Trip(
            id: .stable("trip", members.first!.id.rawValue),
            start: start,
            end: end,
            geotaggedAssetIDs: members.map(\.id),
            inferredAssetIDs: inferred,
            centroid: centroid,
            maxDistanceFromHomeMeters: maxDistance,
            distinctStops: stops,
            kind: kind
        )
    }

    /// The hour a night out ends (see `classify`).
    static let nightEndsHour = 4

    /// Kind of a trip from its photos (sorted by date) and the number of distinct overnight
    /// stops. Days and evening hours are counted in `calendar`, which should use the
    /// destination's time zone when it is known: an evening flight home across midnight is
    /// still a day trip there.
    public static func classify(dates: [Date], coordinates: [GeoCoordinate], calendar: Calendar) -> (kind: TripKind, stops: Int) {
        guard let start = dates.first, let end = dates.last else { return (.dayTrip, 1) }
        // Distinct stops: ~25 km cells where photos were taken in the evening/night.
        var nights: [GeoCell: Set<Date>] = [:]
        for (date, c) in zip(dates, coordinates) {
            let hour = calendar.component(.hour, from: date)
            if hour >= 18 || hour < 6 { nights[GeoCell(c, sizeMeters: 25_000), default: []].insert(calendar.startOfDay(for: date)) }
        }
        let stopCells = Set(nights.keys)
        let allCells = Set(coordinates.map { GeoCell($0, sizeMeters: 25_000) })
        // A stay at one place with a few excursions (a semester with weekend trips, a holiday
        // flat with a night elsewhere) is not a road trip: one stop holds most evenings.
        let eveningCount = nights.values.reduce(0) { $0 + $1.count }
        let mainStopShare = eveningCount > 0 ? Double(nights.values.map(\.count).max() ?? 0) / Double(eveningCount) : 0

        let startDay = calendar.startOfDay(for: start)
        // An outing that runs past midnight (a concert, New Year's Eve) still ends on the day it
        // began: photos before 4 a.m. on the last day belong to the evening before.
        let lateNight = calendar.component(.hour, from: end) < Self.nightEndsHour
        let endDay = max(startDay, calendar.startOfDay(for: lateNight ? end.addingTimeInterval(-Double(Self.nightEndsHour) * 3_600) : end))
        let dayCount = (calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1
        let kind: TripKind
        if dayCount == 1 {
            kind = .dayTrip
        } else if stopCells.count >= 3 && allCells.count >= 4 && dayCount >= 3 && mainStopShare < 0.5 {
            kind = .roadTrip
        } else if dayCount <= 3 && (startDay...endDay).containsWeekend(calendar) {
            kind = .weekendTrip
        } else if dayCount <= 3 {
            kind = .shortTrip
        } else {
            kind = .vacation
        }
        return (kind, max(stopCells.count, 1))
    }

    /// The trips with kind and stops counted in their destination's time zone (the most
    /// common one among their photos' places), where that differs from `calendar`'s.
    public static func inDestinationTime(_ trips: [Trip], assets: [AssetID: AssetSnapshot], timeZones: [AssetID: String], calendar: Calendar) -> [Trip] {
        trips.map { trip in
            var counts: [String: Int] = [:]
            for id in trip.geotaggedAssetIDs { if let zone = timeZones[id] { counts[zone, default: 0] += 1 } }
            guard let identifier = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
                  let zone = TimeZone(identifier: identifier), zone.identifier != calendar.timeZone.identifier else { return trip }
            var local = calendar
            local.timeZone = zone
            let members = trip.geotaggedAssetIDs.compactMap { assets[$0] }
                .compactMap { a -> (Date, GeoCoordinate)? in
                    guard let date = a.creationDate, let c = a.usableLocation else { return nil }
                    return (date, c)
                }
                .sorted { $0.0 < $1.0 }
            guard !members.isEmpty else { return trip }
            var result = trip
            (result.kind, result.distinctStops) = classify(dates: members.map(\.0), coordinates: members.map(\.1), calendar: local)
            return result
        }
    }
}

private extension ClosedRange where Bound == Date {
    func containsWeekend(_ calendar: Calendar) -> Bool {
        var day = lowerBound
        while day <= upperBound {
            if calendar.isDateInWeekend(day) { return true }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return false
    }
}

/// The user's habitual area ("gewöhnlicher Aufenthaltsbereich"), computed time-locally
/// so that moving house does not turn the old or new home into a "trip".
/// Its place at the end of the library is shown in the settings as the detected home ("Dein
/// Zuhause"), where the user can confirm or correct it (`HomeSettings`); trips and the ring
/// ask it only for the dates the user left to the detection (`HomeReference`).
///
/// A place is habitual around a date when it holds a quarter of the photo days of the
/// surrounding months, spread over three weeks or more. Two things refine that:
/// - A long stay away that the user comes back from (semester, sabbatical, Work & Travel, a
///   month on a long journey) is time away, not a new home: its days do not make its place
///   habitual, and the place the user came from stays habitual meanwhile. Moving house is
///   told apart by the missing return; a stay longer than a year is a move even with one.
/// - Places the user said they are often at count at every time.
struct HabitualArea: Sendable {
    private struct Day { let day: Date; let coordinate: GeoCoordinate; var cluster: Int }
    /// The user lived at `cluster` from `start` to `end` (photo days) and came back to `home`.
    struct Sojourn: Sendable, Hashable { var cluster: Int; var start: Date; var end: Date; var home: Int }

    private var days: [Day] = []
    /// Per day: it counts toward its place being habitual (days of a sojourn do not).
    private var counts: [Bool] = []
    private var clusterCentroids: [GeoCoordinate] = []
    private let windowDays: Int
    private let calendar: Calendar
    private let homeRadius: Double
    private let extraHomes: [GeoCoordinate]
    private var homesByDay: [Date: [Int]] = [:]
    private var globalHome: Int?
    /// Counting photo days per cluster, ascending.
    private var clusterDays: [[Date]] = []
    private var requireSpread = false
    private(set) var sojourns: [Sojourn] = []
    /// Instants where a long time away is split: the user moved on from one place they stayed
    /// at for weeks to the next without coming back in between (digital nomad, a long
    /// journey with long stops). Each such stay is its own trip.
    private(set) var movedOn: [Date] = []

    /// A place only counts as home when its photo days inside the window lie at least this
    /// far apart. A burst of holiday days (one trip, even a long one) never makes a place
    /// "home", which matters for people who mostly take photos while travelling.
    static let minimumHomeSpread: TimeInterval = 21 * 86_400
    /// Photo days at one place at most this far apart belong to one stay there. Three weeks:
    /// a Christmas visit home does not end a semester abroad, a monthly visit is a new stay.
    static let stayGap: TimeInterval = 21 * 86_400
    /// A stay away that ends with a return counts as time away up to this length; a longer one
    /// is a move (two years abroad, then back).
    static let maximumSojourn: TimeInterval = 365 * 86_400
    /// How far before and after a stay the place the user came from and went back to is looked for.
    static let returnHorizon: TimeInterval = 365 * 86_400

    init(assets: [AssetSnapshot], calendar: Calendar, windowDays: Int, homeRadius: Double = 30_000, extraHomes: [GeoCoordinate] = []) {
        self.calendar = calendar
        self.windowDays = windowDays
        self.homeRadius = homeRadius
        self.extraHomes = extraHomes
        var perDay: [Date: [GeoCoordinate]] = [:]
        for asset in assets {
            guard let c = asset.usableLocation, let d = asset.creationDate else { continue }
            perDay[calendar.startOfDay(for: d), default: []].append(c)
        }
        // One representative point per day: the coordinate minimizing total distance (medoid
        // of a small sample) – robust against a single far-away photo that day.
        let dayPoints = perDay.map { day, coordinates -> (Date, GeoCoordinate) in
            let sample = Array(coordinates.prefix(15))
            let medoid = sample.min { a, b in
                sample.reduce(0) { $0 + GeoMath.distance($1, a) } < sample.reduce(0) { $0 + GeoMath.distance($1, b) }
            } ?? coordinates[0]
            return (day, medoid)
        }.sorted { $0.0 < $1.0 }

        let clusterer = GeoClusterer(epsilonMeters: 15_000, minPoints: 3)
        let result = clusterer.cluster(dayPoints.map(\.1))
        var labels = [Int](repeating: -1, count: dayPoints.count)
        for (ci, cluster) in result.clusters.enumerated() {
            for m in cluster.memberIndices { labels[m] = ci }
        }
        clusterCentroids = result.clusters.map(\.centroid)
        days = dayPoints.enumerated().map { Day(day: $1.0, coordinate: $1.1, cluster: labels[$0]) }
        var allClusterDays = [[Date]](repeating: [], count: result.clusters.count)
        for d in days where d.cluster >= 0 { allClusterDays[d.cluster].append(d.day) }
        // Spread is only demanded once some place shows it; a library of a few weeks keeps
        // the plain majority rule (otherwise its home would turn into one long trip).
        requireSpread = allClusterDays.contains { ($0.last ?? .distantPast).timeIntervalSince($0.first ?? .distantPast) >= Self.minimumHomeSpread }

        sojourns = findSojourns(allClusterDays)
        counts = days.map { d in !sojourns.contains { $0.cluster == d.cluster && $0.start <= d.day && d.day <= $0.end } }
        clusterDays = Array(repeating: [], count: result.clusters.count)
        for (i, d) in days.enumerated() where d.cluster >= 0 && counts[i] { clusterDays[d.cluster].append(d.day) }

        var global: [Int: Int] = [:]
        for (i, d) in days.enumerated() where d.cluster >= 0 && counts[i] && isSpread(d.cluster, from: .distantPast, to: .distantFuture) {
            global[d.cluster, default: 0] += 1
        }
        if let best = global.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), best.value >= 5 { globalHome = best.key }

        // Sliding window over the sorted days: O(days) instead of O(days²). Every photo day
        // counts in the total, only counting days count for their place.
        let window = Double(windowDays) * 86_400
        var lo = 0, hi = 0
        var perCluster: [Int: Int] = [:]
        for d in days {
            while hi < days.count && days[hi].day <= d.day.addingTimeInterval(window) {
                if days[hi].cluster >= 0 && counts[hi] { perCluster[days[hi].cluster, default: 0] += 1 }
                hi += 1
            }
            while lo < hi && days[lo].day < d.day.addingTimeInterval(-window) {
                if days[lo].cluster >= 0 && counts[lo] { perCluster[days[lo].cluster, default: 0] -= 1 }
                lo += 1
            }
            let lower = d.day.addingTimeInterval(-window), upper = d.day.addingTimeInterval(window)
            let candidates = perCluster.filter { $0.value > 0 && isSpread($0.key, from: lower, to: upper) }
            homesByDay[d.day] = Self.select(counts: candidates, total: hi - lo, returnedTo: returnHomes(at: d.day), fallback: globalHome)
        }
        makeLongStaysWhole(allClusterDays)
        movedOn = findMovedOn(allClusterDays)
    }

    /// A long stay is either where the user lived or time away, never half of each. The window
    /// is cut off at the ends of the library, so the last weeks of the nomad's last city looked
    /// habitual while the weeks before did not. The majority of the stay's days decides.
    private mutating func makeLongStaysWhole(_ allClusterDays: [[Date]]) {
        for (cluster, list) in allClusterDays.enumerated() {
            for stay in longStays(of: cluster, in: list) {
                let stayDays = stay.days.map { days[$0].day }
                let habitual = stayDays.filter { homesByDay[$0]?.contains(cluster) == true }.count
                guard habitual > 0, habitual < stayDays.count else { continue }
                let keep = habitual * 2 >= stayDays.count
                for day in stayDays {
                    var homes = homesByDay[day] ?? []
                    if keep, !homes.contains(cluster) { homes.append(cluster) }
                    if !keep { homes.removeAll { $0 == cluster } }
                    if homes.isEmpty, let globalHome { homes = [globalHome] }
                    homesByDay[day] = homes.sorted()
                }
            }
        }
    }

    /// Home clusters around `date`: clusters holding ≥ 25 % of the photo days in the window.
    private func homeClusters(at date: Date) -> [Int] {
        let center = calendar.startOfDay(for: date)
        if let cached = homesByDay[center] { return cached }
        return computeHomeClusters(center: center)
    }

    private func computeHomeClusters(center: Date) -> [Int] {
        guard !days.isEmpty else { return [] }
        let lower = center.addingTimeInterval(-Double(windowDays) * 86_400)
        let upper = center.addingTimeInterval(Double(windowDays) * 86_400)
        var perCluster: [Int: Int] = [:]
        var total = 0
        for (i, d) in days.enumerated() where d.day >= lower && d.day <= upper {
            total += 1
            if d.cluster >= 0 && counts[i] { perCluster[d.cluster, default: 0] += 1 }
        }
        return Self.select(counts: perCluster.filter { isSpread($0.key, from: lower, to: upper) }, total: total,
                           returnedTo: returnHomes(at: center), fallback: globalHome)
    }

    /// The places the user came from and went back to, during their sojourns at `day`.
    private func returnHomes(at day: Date) -> [Int] {
        sojourns.filter { $0.start <= day && day <= $0.end }.map(\.home)
    }

    /// True if the cluster's photo days between `lower` and `upper` span at least `minimumHomeSpread`.
    private func isSpread(_ cluster: Int, from lower: Date, to upper: Date) -> Bool {
        guard requireSpread else { return true }
        let list = clusterDays[cluster]
        var lo = 0, hi = list.count
        while lo < hi { let mid = (lo + hi) / 2; if list[mid] < lower { lo = mid + 1 } else { hi = mid } }
        let first = lo
        lo = first; hi = list.count
        while lo < hi { let mid = (lo + hi) / 2; if list[mid] <= upper { lo = mid + 1 } else { hi = mid } }
        let last = lo - 1
        guard first < list.count, last >= first else { return false }
        return list[last].timeIntervalSince(list[first]) >= Self.minimumHomeSpread
    }

    private static func select(counts: [Int: Int], total: Int, returnedTo: [Int], fallback: Int?) -> [Int] {
        let threshold = max(3, Int(Double(total) * 0.25))
        let homes = Set(counts.filter { $0.value >= threshold }.map(\.key)).union(returnedTo).sorted()
        if homes.isEmpty, let fallback { return [fallback] }
        return homes
    }

    /// Distance to the habitual area or to a place the user is often at, whichever is closer.
    func distanceToHome(_ coordinate: GeoCoordinate, at date: Date) -> Double {
        let usual = distanceToUsualHome(coordinate, at: date)
        return extraHomes.reduce(usual) { min($0, GeoMath.distance($1, coordinate)) }
    }

    /// The shortest way from `a` to `b` through the habitual area of `date` (or a place the
    /// user is often at).
    func wayViaHome(_ a: GeoCoordinate, _ b: GeoCoordinate, at date: Date) -> Double {
        let points = homeClusters(at: date).map { clusterCentroids[$0] } + extraHomes
        return points.map { GeoMath.distance(a, $0) + GeoMath.distance($0, b) }.min() ?? .infinity
    }

    /// The centres of the habitual area at `date` (several near a border or during a long stay away).
    func centers(at date: Date) -> [GeoCoordinate] {
        homeClusters(at: date).map { clusterCentroids[$0] }
    }

    /// The home at `date` as the settings show it: the habitual place with the most photo days,
    /// and since when it has been habitual without a break (the move there).
    func mainHome(at date: Date) -> DetectedHome? {
        let homes = homeClusters(at: date)
        guard let best = homes.max(by: { (clusterDays[$0].count, -$0) < (clusterDays[$1].count, -$1) }) else { return nil }
        let end = calendar.startOfDay(for: date)
        var since: Date?
        var always = true
        for d in days.reversed() where d.day <= end {
            guard homesByDay[d.day]?.contains(best) == true else { always = false; break }
            since = d.day
        }
        return DetectedHome(center: clusterCentroids[best], since: always ? nil : since, photoDays: clusterDays[best].count)
    }

    /// Distance to the habitual area alone, without the places the user is often at.
    func distanceToUsualHome(_ coordinate: GeoCoordinate, at date: Date) -> Double {
        let homes = homeClusters(at: date)
        guard !homes.isEmpty else { return .infinity }
        return homes.map { GeoMath.distance(clusterCentroids[$0], coordinate) }.min() ?? .infinity
    }

    // MARK: Long stays

    /// Indices of the days from `lower` to `upper` (both included).
    private func dayIndices(from lower: Date, to upper: Date) -> Range<Int> {
        var lo = 0, hi = days.count
        while lo < hi { let mid = (lo + hi) / 2; if days[mid].day < lower { lo = mid + 1 } else { hi = mid } }
        let first = lo
        hi = days.count
        while lo < hi { let mid = (lo + hi) / 2; if days[mid].day <= upper { lo = mid + 1 } else { hi = mid } }
        return first..<lo
    }

    /// The stays at one place: its photo days split where they lie more than `stayGap` apart.
    /// Only stays of three weeks or more in which the place holds at least half the photo days
    /// (the user lived there then, not next to another home).
    private func longStays(of cluster: Int, in list: [Date]) -> [(start: Date, end: Date, days: Range<Int>)] {
        var result: [(start: Date, end: Date, days: Range<Int>)] = []
        var first = 0
        for i in list.indices where i + 1 == list.count || list[i + 1].timeIntervalSince(list[i]) > Self.stayGap {
            let start = list[first], end = list[i]
            first = i + 1
            guard end.timeIntervalSince(start) >= Self.minimumHomeSpread else { continue }
            let inside = dayIndices(from: start, to: end)
            let here = inside.filter { days[$0].cluster == cluster }.count
            if here * 2 >= inside.count { result.append((start, end, inside)) }
        }
        return result
    }

    /// The place the user was at in the most different months between `lower` and `upper`,
    /// apart from `excluded`. Months, not photo days: a week of holiday photos must not
    /// outweigh a few photos every month at home (people who mostly photograph on trips).
    private func mostPresent(from lower: Date, to upper: Date, excluding excluded: Int) -> Int? {
        var months: [Int: Set<Int>] = [:]
        for i in dayIndices(from: lower, to: upper) where days[i].cluster >= 0 && days[i].cluster != excluded {
            let c = calendar.dateComponents([.year, .month], from: days[i].day)
            months[days[i].cluster, default: []].insert((c.year ?? 0) * 12 + (c.month ?? 0))
        }
        return months.max { ($0.value.count, -$0.key) < ($1.value.count, -$1.key) }?.key
    }

    /// Long stays away that the user came back from: three weeks to a year at one place,
    /// where the place they mostly were at in the year before is the same as in the year
    /// after, they were hardly there during the stay (at most one photo day in five), and it is
    /// their place for longer (more months with photos) than the stay's place.
    private func findSojourns(_ allClusterDays: [[Date]]) -> [Sojourn] {
        guard allClusterDays.count > 1 else { return [] }
        let months = allClusterDays.map { list in
            Set(list.map { day -> Int in
                let c = calendar.dateComponents([.year, .month], from: day)
                return (c.year ?? 0) * 12 + (c.month ?? 0)
            }).count
        }
        var result: [Sojourn] = []
        for (cluster, list) in allClusterDays.enumerated() {
            for stay in longStays(of: cluster, in: list) where stay.end.timeIntervalSince(stay.start) <= Self.maximumSojourn {
                guard let before = mostPresent(from: stay.start.addingTimeInterval(-Self.returnHorizon), to: stay.start.addingTimeInterval(-1), excluding: cluster),
                      let after = mostPresent(from: stay.end.addingTimeInterval(1), to: stay.end.addingTimeInterval(Self.returnHorizon), excluding: cluster),
                      before == after,
                      GeoMath.distance(clusterCentroids[before], clusterCentroids[cluster]) > homeRadius,
                      months[before] > months[cluster] else { continue }
                let atHome = stay.days.filter { days[$0].cluster == before }.count
                guard atHome * 5 <= stay.days.count else { continue }
                result.append(Sojourn(cluster: cluster, start: stay.start, end: stay.end, home: before))
            }
        }
        return result
    }

    /// The day after each long stay away that is followed by another long stay elsewhere,
    /// with no day at the habitual area in between.
    private func findMovedOn(_ allClusterDays: [[Date]]) -> [Date] {
        var settled: [(cluster: Int, start: Date, end: Date)] = []
        for (cluster, list) in allClusterDays.enumerated() {
            for stay in longStays(of: cluster, in: list) where distanceToHome(clusterCentroids[cluster], at: stay.start) > homeRadius {
                settled.append((cluster, stay.start, stay.end))
            }
        }
        settled.sort { ($0.start, $0.cluster) < ($1.start, $1.cluster) }
        var result: [Date] = []
        for (a, b) in zip(settled, settled.dropFirst()) where a.end < b.start && a.cluster != b.cluster {
            let between = dayIndices(from: a.end.addingTimeInterval(1), to: b.start.addingTimeInterval(-1))
            guard !between.contains(where: { distanceToHome(days[$0].coordinate, at: days[$0].day) <= homeRadius }),
                  let next = calendar.date(byAdding: .day, value: 1, to: a.end) else { continue }
            result.append(next)
        }
        return result
    }
}

/// What trips and the ring are judged against, date by date: the home the user chose for the
/// date (`HomeSettings.home(at:)`), otherwise the habitual area. "Kein Zuhause" means no photo
/// is at home; trips are still told from everyday life by where the user usually is at the
/// time, or every everyday photo would be on one long trip.
struct HomeReference: Sendable {
    let detection: HabitualArea
    let settings: HomeSettings
    let radius: Double
    /// Places the user is often at: stays there are not trips.
    let extraHomes: [GeoCoordinate]

    var movedOn: [Date] { detection.movedOn }

    /// Where trips start from at `date`.
    func referenceCenters(at date: Date) -> [GeoCoordinate] {
        if case .chosen(let place) = settings.home(at: date) { return [place.center] }
        return detection.centers(at: date)
    }

    /// Distance to the home of `date` alone, without the places the user is often at.
    func distanceToUsualHome(_ coordinate: GeoCoordinate, at date: Date) -> Double {
        referenceCenters(at: date).map { GeoMath.distance($0, coordinate) }.min() ?? .infinity
    }

    /// Distance to the home of `date` or a place the user is often at, whichever is closer.
    func distanceToHome(_ coordinate: GeoCoordinate, at date: Date) -> Double {
        extraHomes.reduce(distanceToUsualHome(coordinate, at: date)) { min($0, GeoMath.distance($1, coordinate)) }
    }

    /// The shortest way from `a` to `b` through the home of `date` (or a place the user is often at).
    func wayViaHome(_ a: GeoCoordinate, _ b: GeoCoordinate, at date: Date) -> Double {
        (referenceCenters(at: date) + extraHomes).map { GeoMath.distance(a, $0) + GeoMath.distance($0, b) }.min() ?? .infinity
    }

    /// Taken at home: within the home radius of the home of its date. Places the user is often
    /// at are not home; with "Kein Zuhause" nothing is.
    func isAtHome(_ coordinate: GeoCoordinate, at date: Date) -> Bool {
        switch settings.home(at: date) {
        case .chosen(let place): GeoMath.distance(place.center, coordinate) <= radius
        case .none: false
        case .detected: detection.distanceToUsualHome(coordinate, at: date) <= radius
        }
    }
}
