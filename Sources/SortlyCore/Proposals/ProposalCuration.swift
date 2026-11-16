import Foundation

/// Photos that get no album of their own in an area because another suggestion's album stands
/// for them there. The sorted count takes that album for them (device test 15.11.: the
/// country of a trip went with the trip, and its photos counted as unsorted for "Länder und
/// Orte" although the user's own trip album held them).
public struct StandIn: Hashable, Sendable, Codable {
    public enum Reason: String, Hashable, Sendable, Codable {
        /// A place or theme seen on one trip only: the trip's album is its album.
        case partOfTrip
        /// Screenshots inside a document album.
        case partOfDocuments
        /// The same photos as a more telling suggestion.
        case samePhotos
        /// A photo on a trip whose place has no album of its own (the home country, a country
        /// with too few photos): the trip's album is its place album.
        case placeOfTrip
        /// A routine visit is not a trip: the album of the place visited is its album.
        case routineVisit
    }

    /// The area in which the photos have no album of their own.
    public var area: OrganizationArea
    /// The suggestion whose album stands for them.
    public var suggestion: SortlyID
    /// The suggestion (or trip) that was left out, if there was one.
    public var dropped: SortlyID?
    public var assetIDs: Set<AssetID>
    public var reason: Reason

    public init(area: OrganizationArea, suggestion: SortlyID, dropped: SortlyID?, assetIDs: Set<AssetID>, reason: Reason) {
        self.area = area
        self.suggestion = suggestion
        self.dropped = dropped
        self.assetIDs = assetIDs
        self.reason = reason
    }
}

/// What suggesting produced: the suggestions to show, the ones the user dismissed ("Nicht
/// jetzt", or the album deleted in Photos) and which album stands for photos without an album
/// of their own. Dismissed suggestions are not shown, but an own album that fits one still
/// counts as sorted.
public struct Suggestions: Sendable {
    public var open: [AlbumProposal]
    public var dismissed: [AlbumProposal]
    public var standIns: [StandIn]

    public init(open: [AlbumProposal], dismissed: [AlbumProposal] = [], standIns: [StandIn] = []) {
        self.open = open
        self.dismissed = dismissed
        self.standIns = standIns
    }
}

/// The last step of suggesting: one album for one set of photos.
///
/// On the first iPhone (15.11., 5,683 photos) about 250 suggestions came out, many of them the
/// same photos under several names: the trip "Marokko", the country "Marokko" and its towns;
/// "Tickets" among the screenshots and among the documents; "Deutschland" with most of the
/// library. A suggestion list is read top to bottom, so every duplicate costs attention and
/// hides a good suggestion further down. The rules, in order:
/// 1. Where the user lives is not an album (see `HomeContext`, `LibraryProfile`).
/// 2. A country, region, town or theme seen on one trip only is that trip's album. It comes
///    back by itself after a second trip there. Likewise a screenshot album inside a document
///    album.
/// 3. Of two suggestions with (nearly) the same photos, the more telling one stays: a named
///    place, then a trip, then a place album (the more specific level first: the user chose
///    towns), then the album of a repeatedly visited place, then documents, screenshots,
///    themes, and last a place still waiting for a name.
/// Years, months, media types, messengers and people are left as they are: they are opt-in,
/// and the user asked for exactly that view.
extension ProposalEngine {
    /// A share of photos this high inside one trip makes a place or theme part of that trip.
    static let nestedShare = 0.9
    /// Two suggestions are the same album when each holds at least this share of the other.
    static let sameAlbumShare = 0.9

    func curated(_ proposals: [AlbumProposal], profile: LibraryProfile) -> [AlbumProposal] {
        var standIns: [StandIn] = []
        return curated(proposals, home: HomeContext(profile: profile), standIns: &standIns)
    }

    /// - Parameters:
    ///   - home: which countries, regions and towns are home at some time (rule 1).
    ///   - standIns: gets, for every suggestion left out under rule 2 or 3, the suggestion that
    ///     stands for its photos. Rule 1 has none: home is no album at all.
    func curated(_ proposals: [AlbumProposal], home: HomeContext, standIns: inout [StandIn]) -> [AlbumProposal] {
        let tripFolder = labels.folder(for: .trips)
        func isPlaceAlbum(_ p: AlbumProposal) -> Bool {
            if case .placeCollection = p.kind { return p.folderPath.first != tripFolder }
            return false
        }
        func isTheme(_ p: AlbumProposal) -> Bool {
            if case .imageCategory = p.kind { return true }
            return false
        }

        // 1. Everyday places: the home of any time (the one the user chose, or the detected one).
        var list = proposals.filter { p in !(isPlaceAlbum(p) && p.placeKeys.contains(where: home.isHomeAtSomeTime)) }

        // 2. Places and themes inside a single trip.
        var tripOf: [AssetID: Int] = [:]
        let trips = list.filter { $0.kind == .trip }
        for (index, trip) in trips.enumerated() { for id in trip.assetIDs { tripOf[id] = index } }
        if !trips.isEmpty {
            list.removeAll { p in
                guard isPlaceAlbum(p) || isTheme(p), !p.assetIDs.isEmpty else { return false }
                var perTrip: [Int: Int] = [:]
                for id in p.assetIDs { if let t = tripOf[id] { perTrip[t, default: 0] += 1 } }
                guard let most = perTrip.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                      Double(most.value) >= Double(p.assetIDs.count) * Self.nestedShare else { return false }
                let trip = trips[most.key]
                standIns.append(StandIn(area: p.kind.area, suggestion: trip.id, dropped: p.id,
                                        assetIDs: p.assetIDs.intersection(trip.assetIDs), reason: .partOfTrip))
                return true
            }
        }

        // A screenshot album inside a document album: the documents already hold those
        // screenshots ("Flugbuchungen" inside "Tickets").
        var documentOf: [AssetID: [Int]] = [:]
        let documents = list.filter { if case .documentCategory = $0.kind { return true } else { return false } }
        for (index, document) in documents.enumerated() { for id in document.assetIDs { documentOf[id, default: []].append(index) } }
        if !documents.isEmpty {
            list.removeAll { p in
                guard case .screenshotCategory = p.kind, !p.assetIDs.isEmpty else { return false }
                var perDocument: [Int: Int] = [:]
                for id in p.assetIDs { for d in documentOf[id] ?? [] { perDocument[d, default: 0] += 1 } }
                guard let most = perDocument.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                      Double(most.value) >= Double(p.assetIDs.count) * Self.nestedShare else { return false }
                let document = documents[most.key]
                standIns.append(StandIn(area: p.kind.area, suggestion: document.id, dropped: p.id,
                                        assetIDs: p.assetIDs.intersection(document.assetIDs), reason: .partOfDocuments))
                return true
            }
        }

        // 3. The same photos under two names.
        func preference(_ p: AlbumProposal) -> Int? {
            switch p.kind {
            case .frequentPlace: return p.requiresUserName ? 90 : 0
            case .trip: return 10
            case .placeCollection(let level):
                // Deeper levels first: a town before its country.
                return isPlaceAlbum(p) ? 20 + (PlaceLevel.pointOfInterest.rawValue - level.rawValue) : 40
            case .documentCategory: return 50
            case .screenshotCategory: return 60
            case .imageCategory: return 70
            default: return nil
            }
        }
        let ranked = list.enumerated().compactMap { offset, p in preference(p).map { (offset, $0) } }
            .sorted { a, b in
                let (pa, pb) = (list[a.0], list[b.0])
                if a.1 != b.1 { return a.1 < b.1 }
                if pa.assetIDs.count != pb.assetIDs.count { return pa.assetIDs.count > pb.assetIDs.count }
                return pa.id.rawValue < pb.id.rawValue
            }
        var keptOf: [AssetID: [Int]] = [:]
        var dropped = Set<Int>()
        for (offset, _) in ranked {
            let p = list[offset]
            var shared: [Int: Int] = [:]
            for id in p.assetIDs { for k in keptOf[id] ?? [] { shared[k, default: 0] += 1 } }
            let duplicate = shared.filter { kept, count in
                let larger = max(p.assetIDs.count, list[kept].assetIDs.count)
                return Double(count) >= Double(larger) * Self.sameAlbumShare
            }.max { ($0.value, $1.key) < ($1.value, $0.key) }
            if let duplicate {
                dropped.insert(offset)
                let kept = list[duplicate.key]
                standIns.append(StandIn(area: p.kind.area, suggestion: kept.id, dropped: p.id,
                                        assetIDs: p.assetIDs.intersection(kept.assetIDs), reason: .samePhotos))
            } else {
                for id in p.assetIDs { keptOf[id, default: []].append(offset) }
            }
        }
        return list.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// Photos on a trip that no place suggestion holds (their country is the home country or
    /// has too few photos, or went with the trip): the trip's album is their place album, as
    /// curation rule 2 says for a country seen on one trip only.
    func placesOfTrips(_ kept: [AlbumProposal], standIns: [StandIn]) -> [StandIn] {
        var placed = Set<AssetID>()
        for p in kept where p.kind.area == .places { placed.formUnion(p.assetIDs) }
        for s in standIns where s.area == .places { placed.formUnion(s.assetIDs) }
        return kept.compactMap { trip in
            guard trip.kind == .trip else { return nil }
            let open = trip.assetIDs.subtracting(placed)
            return open.isEmpty ? nil : StandIn(area: .places, suggestion: trip.id, dropped: nil, assetIDs: open, reason: .placeOfTrip)
        }
    }

    /// Stand-ins point at a suggestion that is kept: one that was itself left out (a routine
    /// visit's place album with the same photos as a town) hands its photos on to the one kept
    /// for it. Stand-ins that lead nowhere are dropped.
    static func resolved(_ standIns: [StandIn], kept: Set<SortlyID>) -> [StandIn] {
        var next: [SortlyID: SortlyID] = [:]
        for s in standIns { if let dropped = s.dropped, next[dropped] == nil { next[dropped] = s.suggestion } }
        return standIns.compactMap { s in
            var s = s
            var hops = 0
            while !kept.contains(s.suggestion), let further = next[s.suggestion], hops < 8 {
                s.suggestion = further
                hops += 1
            }
            return kept.contains(s.suggestion) ? s : nil
        }
    }
}
