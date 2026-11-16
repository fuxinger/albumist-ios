import Foundation

// "Bist du hier öfter?" – places the user goes to again and again (a holiday flat, a weekend
// place, family in another town, a second workplace). Albumist notices them by the trips that
// keep going to the same place and asks once per place. Only the user's answer turns a place
// into one where stays are no longer trips; Albumist never decides that by itself and never
// calls a place "home" or anything else. The place's album is named after the place.

/// The user's answer for one place, kept by position (like trip corrections are kept in
/// time): it holds for every later analysis and for photos added later.
public struct PlaceAnswer: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var center: GeoCoordinate
    /// True: "Ja, hier bin ich öfter" – stays here are not trips, the place gets one album.
    /// False: "Nein, das sind Reisen" – trips stay, the question is not asked again.
    public var oftenHere: Bool
    /// The place's name when the user answered (from the trip), shown in the settings only.
    public var name: String?
    public var answeredAt: Date

    public init(id: SortlyID, center: GeoCoordinate, oftenHere: Bool, name: String?, answeredAt: Date) {
        self.id = id
        self.center = center
        self.oftenHere = oftenHere
        self.name = name
        self.answeredAt = answeredAt
    }
}

/// All answers (store key `user.recurringPlaces`, part of the decisions copy in the backup).
public struct RecurringPlaceAnswers: Hashable, Sendable, Codable {
    public var places: [PlaceAnswer] = []

    public init(places: [PlaceAnswer] = []) {
        self.places = places
    }

    /// One answer covers everything within this distance of its center. Half the radius the
    /// trip detection uses for the habitual area: a town and its outskirts, not the next town.
    public static let matchRadiusMeters: Double = 15_000

    /// The places whose stays are not trips.
    public var oftenHere: [PlaceAnswer] { places.filter(\.oftenHere) }

    /// The answer for the place at `coordinate`, if the user gave one.
    public func answer(near coordinate: GeoCoordinate) -> PlaceAnswer? {
        places
            .filter { GeoMath.distance($0.center, coordinate) <= Self.matchRadiusMeters }
            .min { GeoMath.distance($0.center, coordinate) < GeoMath.distance($1.center, coordinate) }
    }

    /// Stores an answer for the place at `center`. An earlier answer for the same place is
    /// replaced but keeps its id and center, so the place's album keeps its suggestion id
    /// (and the user's decisions on it) when the user changes their mind back and forth.
    public func answering(_ oftenHere: Bool, at center: GeoCoordinate, name: String?, date: Date) -> RecurringPlaceAnswers {
        var copy = self
        if let existing = answer(near: center), let index = copy.places.firstIndex(where: { $0.id == existing.id }) {
            copy.places[index].oftenHere = oftenHere
            copy.places[index].answeredAt = date
            if let name, !name.isEmpty { copy.places[index].name = name }
        } else {
            let id = SortlyID.stable("place-answer", String(format: "%.4f,%.4f", center.latitude, center.longitude))
            copy.places.append(PlaceAnswer(id: id, center: center, oftenHere: oftenHere, name: name, answeredAt: date))
        }
        return copy
    }

    /// "Zurücknehmen" in the settings: the place's stays are trips again. It is remembered as
    /// "Nein", so the same question does not come back right after the user took it back.
    public func withdrawing(_ id: SortlyID, date: Date) -> RecurringPlaceAnswers {
        var copy = self
        if let index = copy.places.firstIndex(where: { $0.id == id }) {
            copy.places[index].oftenHere = false
            copy.places[index].answeredAt = date
        }
        return copy
    }
}

/// A place with several separate stays away and no answer yet: the app asks about it once,
/// on its trips.
public struct RecurringPlaceCandidate: Hashable, Sendable, Codable, Identifiable {
    public var id: SortlyID
    public var center: GeoCoordinate
    /// Separate stays there, also short ones too small for a trip album.
    public var stayCount: Int
    public var firstVisit: Date
    public var lastVisit: Date
    /// The trips to this place; the question is shown on them.
    public var tripIDs: [SortlyID]
}

/// A place the user said they are often at, with the photos taken there: one album
/// suggestion instead of a trip per stay.
public struct RecurringPlace: Hashable, Sendable, Codable, Identifiable {
    /// The answer's id.
    public var id: SortlyID
    public var center: GeoCoordinate
    public var name: String?
    public var assetIDs: [AssetID]
    public var distinctDays: Int
    public var firstDate: Date
    public var lastDate: Date
}

/// One separate time away (every stretch the trip detection found, also those too small for a
/// trip), with the place it mostly was at.
public struct AwayStay: Hashable, Sendable, Codable {
    public var start: Date
    public var end: Date
    /// Where most of the stay's days were (an excursion does not move it).
    public var mainPlace: GeoCoordinate
    public var photoCount: Int
    /// Index into `TripAnalysis.trips` when the stay became a trip.
    public var tripIndex: Int?
}

/// Everything the trip detection found: the trips, every stay away, and the photos at the
/// places the user is often at.
public struct TripAnalysis: Sendable {
    public var trips: [Trip]
    public var stays: [AwayStay]
    public var places: [RecurringPlace]
    /// Photos taken where the user lives: the home town and its surroundings (within the home
    /// radius of the habitual area of their time). Places the user is often at are not home.
    public var atHome: Set<AssetID> = []
}

/// What the app needs to ask about recurring places and to offer "Keine Reise, hier bin ich
/// öfter" (store key `analysis.recurringPlaces`, rebuilt by every analysis).
public struct RecurringPlaceReport: Hashable, Sendable, Codable {
    public var candidates: [RecurringPlaceCandidate] = []
    /// Where each trip mostly was: the place the button on a trip suggestion marks.
    public var tripPlaces: [SortlyID: GeoCoordinate] = [:]
    /// The places the user is often at, with their photos.
    public var places: [RecurringPlace] = []

    public init(candidates: [RecurringPlaceCandidate] = [], tripPlaces: [SortlyID: GeoCoordinate] = [:], places: [RecurringPlace] = []) {
        self.candidates = candidates
        self.tripPlaces = tripPlaces
        self.places = places
    }

    /// The report for an analysis. `trips` are the analysis' trips with their remembered ids
    /// (`TripIdentity.carryOver` keeps their order).
    public init(_ analysis: TripAnalysis, trips: [Trip], answers: RecurringPlaceAnswers) {
        precondition(trips.count == analysis.trips.count, "trips must be the analysis' trips")
        var tripPlaces: [SortlyID: GeoCoordinate] = [:]
        for stay in analysis.stays {
            if let index = stay.tripIndex { tripPlaces[trips[index].id] = stay.mainPlace }
        }
        self.init(
            candidates: RecurringPlaces.candidates(stays: analysis.stays, tripIDs: trips.map(\.id), answers: answers),
            tripPlaces: tripPlaces,
            places: analysis.places
        )
    }

    /// The open question to show on a trip, if its place is visited again and again.
    public func question(forTrip id: SortlyID) -> RecurringPlaceCandidate? {
        candidates.first { $0.tripIDs.contains(id) }
    }

    /// The open question to show on a suggestion: a trip, or the album that gathers the trips
    /// to one place (the suggestions fold routine visits into one album), whose photos are
    /// mostly on trips to a place visited again and again. `tripOf` gives a photo's trip.
    public func question(for proposal: AlbumProposal, tripOf: (AssetID) -> SortlyID?) -> RecurringPlaceCandidate? {
        if proposal.kind == .trip { return question(forTrip: proposal.id) }
        guard !candidates.isEmpty, !proposal.assetIDs.isEmpty else { return nil }
        var perTrip: [SortlyID: Int] = [:]
        for id in proposal.assetIDs { if let trip = tripOf(id) { perTrip[trip, default: 0] += 1 } }
        return candidates
            .map { candidate in (candidate, candidate.tripIDs.reduce(0) { $0 + (perTrip[$1] ?? 0) }) }
            .filter { $0.1 * 2 > proposal.assetIDs.count }
            .max { $0.1 < $1.1 }?.0
    }

    /// The place "Keine Reise, hier bin ich öfter" marks for a suggestion: where its trip
    /// mostly was, or for an album of several trips, where the trip with most of its photos was.
    public func place(for proposal: AlbumProposal, tripOf: (AssetID) -> SortlyID?) -> GeoCoordinate? {
        if proposal.kind == .trip { return tripPlaces[proposal.id] }
        var perTrip: [SortlyID: Int] = [:]
        for id in proposal.assetIDs { if let trip = tripOf(id), tripPlaces[trip] != nil { perTrip[trip, default: 0] += 1 } }
        return perTrip.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }.flatMap { tripPlaces[$0.key] }
    }
}

public enum RecurringPlaces {
    /// The suggestion id of the album of the place the user answered `answer` for: the same for
    /// as long as the answer exists, so decisions on the album stay attached.
    public static func proposalID(for answer: SortlyID) -> SortlyID {
        .stable("recurring-place", answer.rawValue)
    }

    /// A place is asked about from this many separate stays within `window` on.
    public static let minimumStays = 4
    public static let window: TimeInterval = 365 * 86_400
    /// …spread over at least four weeks: four returns within a few days are one busy week.
    public static let minimumSpan: TimeInterval = 28 * 86_400

    /// Places with at least `minimumStays` separate stays within a year and at least one trip,
    /// that the user has not answered for yet. Most visited first.
    public static func candidates(stays: [AwayStay], tripIDs: [SortlyID], answers: RecurringPlaceAnswers) -> [RecurringPlaceCandidate] {
        struct Group { var center: GeoCoordinate; var members: [AwayStay] }
        var groups: [Group] = []
        // Oldest first and a running center: the same stays always make the same groups.
        for stay in stays.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let index = groups.indices.min(by: { GeoMath.distance(groups[$0].center, stay.mainPlace) < GeoMath.distance(groups[$1].center, stay.mainPlace) }),
               GeoMath.distance(groups[index].center, stay.mainPlace) <= RecurringPlaceAnswers.matchRadiusMeters {
                groups[index].members.append(stay)
                groups[index].center = GeoMath.centroid(groups[index].members.map(\.mainPlace)) ?? groups[index].center
            } else {
                groups.append(Group(center: stay.mainPlace, members: [stay]))
            }
        }
        let result = groups.compactMap { group -> RecurringPlaceCandidate? in
            let trips = group.members.compactMap(\.tripIndex).map { tripIDs[$0] }
            guard !trips.isEmpty, answers.answer(near: group.center) == nil, isRecurring(group.members.map(\.start)) else { return nil }
            return RecurringPlaceCandidate(
                id: .stable("recurring-place", String(format: "%.3f,%.3f", group.center.latitude, group.center.longitude)),
                center: group.center,
                stayCount: group.members.count,
                firstVisit: group.members.map(\.start).min()!,
                lastVisit: group.members.map(\.end).max()!,
                tripIDs: trips
            )
        }
        return result.sorted { ($0.stayCount, $1.firstVisit) > ($1.stayCount, $0.firstVisit) }
    }

    /// At least `minimumStays` starts within one `window`, spread over `minimumSpan`.
    static func isRecurring(_ starts: [Date]) -> Bool {
        let sorted = starts.sorted()
        guard sorted.count >= minimumStays else { return false }
        var lo = 0
        for hi in sorted.indices {
            while sorted[hi].timeIntervalSince(sorted[lo]) > window { lo += 1 }
            if hi - lo + 1 >= minimumStays, sorted[hi].timeIntervalSince(sorted[lo]) >= minimumSpan { return true }
        }
        return false
    }

    /// Where a stay mostly was: one point per day (the day's most central photo), then the
    /// centre of the day points that have the most other days within `radius`. A day trip from
    /// the holiday flat does not move the place; a road trip gets its longest stop.
    public static func mainPlace(of photos: [(date: Date, coordinate: GeoCoordinate)], calendar: Calendar,
                                 radius: Double = RecurringPlaceAnswers.matchRadiusMeters) -> GeoCoordinate? {
        guard !photos.isEmpty else { return nil }
        var perDay: [Date: [GeoCoordinate]] = [:]
        for photo in photos { perDay[calendar.startOfDay(for: photo.date), default: []].append(photo.coordinate) }
        let points = perDay.keys.sorted().map { day -> GeoCoordinate in
            let sample = Array(perDay[day]!.prefix(15))
            return sample.min { a, b in
                sample.reduce(0) { $0 + GeoMath.distance($1, a) } < sample.reduce(0) { $0 + GeoMath.distance($1, b) }
            } ?? sample[0]
        }
        // Long journeys have a few hundred days at most: the square is cheap.
        var best: [GeoCoordinate] = []
        for point in points {
            let near = points.filter { GeoMath.distance($0, point) <= radius }
            if near.count > best.count { best = near }
        }
        return GeoMath.centroid(best) ?? points[0]
    }
}

extension ProposalEngine {
    /// One album per place the user is often at, instead of a trip per stay. Named after the
    /// place (the town most photos were taken in), never after what the place is to the user.
    /// Personal like a frequent place: never chosen automatically.
    func recurringPlaceProposals(_ places: [RecurringPlace], facts: [AssetFacts]) -> [AlbumProposal] {
        let labels = Labels(settings.titleLanguage)
        let byID = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return places.compactMap { place -> AlbumProposal? in
            // `facts` are the usable ones: photos the user excluded or ignored stay out.
            let members = place.assetIDs.filter { byID[$0] != nil }
            guard members.count >= settings.trips.minPhotos else { return nil }
            let gps = members.compactMap { byID[$0]?.gpsPlace }
            let (geoName, key, _) = Self.primaryPlaceName(gps, kind: .vacation, labels: labels)
            let title = geoName ?? place.name ?? labels.unknownPlace
            let dates = members.compactMap { byID[$0]?.asset.creationDate }
            let days = Set(dates.map { calendar.startOfDay(for: $0) }).count
            return AlbumProposal(
                id: RecurringPlaces.proposalID(for: place.id),
                kind: .frequentPlace,
                title: title,
                folderPath: [labels.folder(for: .frequentPlaces)],
                assetIDs: Set(members),
                reliability: .certain,
                reasons: [.recurringPlace(count: members.count, days: days)],
                dateRange: dates.min().flatMap { start in dates.max().map { DateInterval(start: start, end: $0) } },
                placeKeys: key.map { [$0] } ?? [],
                isSensitive: true
            )
        }
    }
}
