import Foundation

/// Set-overlap metrics between a proposal P and an existing album A (prompt §5.2).
public struct OverlapMetrics: Hashable, Sendable, Codable {
    public var proposalCount: Int
    public var albumCount: Int
    public var intersection: Int

    public init(proposalCount: Int, albumCount: Int, intersection: Int) {
        self.proposalCount = proposalCount
        self.albumCount = albumCount
        self.intersection = intersection
    }

    /// Share of the proposal already contained in the album: |P∩A| / |P|.
    public var coverage: Double { proposalCount == 0 ? 0 : Double(intersection) / Double(proposalCount) }
    /// Share of the album that belongs to the proposal: |P∩A| / |A|.
    public var purity: Double { albumCount == 0 ? 0 : Double(intersection) / Double(albumCount) }
    /// |P∩A| / |P∪A|.
    public var jaccard: Double {
        let union = proposalCount + albumCount - intersection
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
    /// Proposal members missing in the album: |P \ A|.
    public var missing: Int { proposalCount - intersection }
    /// Album members outside the proposal: |A \ P|.
    public var extra: Int { albumCount - intersection }
}

/// How an existing album relates to a proposal.
public enum AlbumRelation: String, Sendable, Codable {
    case equivalent            // essentially the same set
    case partOfProposal        // album is a (mostly pure) subset → can be extended
    case broaderCollection     // album spans several sibling proposals (e.g. all Italy trips)
    case partialOverlap
}

/// Status of a proposal with respect to existing albums (prompt §5.3).
public enum MatchStatus: String, Sendable, Codable, CaseIterable {
    case alreadyComplete       // Bereits vollständig vorhanden
    case extendable            // Bestehendes Album ergänzbar
    case possibleMatch         // Bestehendes Album möglicherweise passend
    case multipleMatches       // Mehrere passende Alben gefunden
    case nameConflict          // Namenskonflikt ohne ausreichende Inhaltsübereinstimmung
    case newAlbumRequired      // Neues Album erforderlich
    case ambiguous             // Nicht eindeutig zuordenbar
    case notEditable           // Nicht bearbeitbar
}

/// Explanation building blocks; the app renders them as sentences such as
/// "Das bestehende Album enthält bereits 248 dieser Aufnahmen. 38 weitere Bilder passen."
public enum MatchReason: Hashable, Sendable, Codable {
    case albumContains(album: String, contained: Int, total: Int)
    case missingItems(count: Int)
    case albumHasOtherItems(album: String, count: Int)
    case albumIsBroaderCollection(album: String, siblingCount: Int)
    case sameNameDifferentContent(album: String, sharedItems: Int)
    case albumNotEditable(album: String)
    case severalAlbumsMatch(count: Int)
    case weakOverlapOnly(album: String, shared: Int)
    case noExistingAlbum
    /// Only a possible match (`possibleMatch`): Albumist makes an album of its own and leaves
    /// this one alone; the user can still choose it under "Anpassen" (review 16.11., A1–A4).
    case keptUnchangedUntilChosen(album: String)
}

public struct MatchCandidate: Hashable, Sendable, Codable {
    public var albumID: CollectionID
    public var albumTitle: String
    public var metrics: OverlapMetrics
    public var relation: AlbumRelation
    public var nameSimilarity: Double
    public var score: Double
    public var isEditable: Bool
}

public struct MatchResult: Hashable, Sendable, Codable {
    public var proposalID: SortlyID
    public var status: MatchStatus
    public var best: MatchCandidate?
    public var alternatives: [MatchCandidate]
    public var sameNameAlbums: [CollectionID]
    public var reasons: [MatchReason]
}

/// Content-based matching of proposals against the existing album inventory.
///
/// The decision never relies on album names alone (prompt §5.2). Names only break ties
/// and reveal name conflicts. All thresholds are explicit, documented in
/// `docs/ALBUM_MATCHING.md`, and covered by unit tests.
public struct AlbumMatcher: Sendable {
    public struct Thresholds: Hashable, Sendable, Codable {
        /// Minimum share for an album to be considered at all.
        public var candidatePurity = 0.5
        public var candidateCoverage = 0.5
        /// Complete: nothing missing and the album is almost purely this proposal.
        public var completePurity = 0.9
        public var completeCoverage = 0.98
        /// Extendable: album is mostly this proposal and already holds a relevant part.
        public var extendablePurity = 0.8
        public var extendableCoverage = 0.25
        /// A collection (not a trip or period) extends an album without a name that says so
        /// ("Bello" for Hunde, "Italien 2019" for the year 2019) only when the album already
        /// holds this much of it; below, it is only a possible match (review 16.11.).
        public var unnamedCollectionCoverage = 0.8
        /// A place album whose photos all lie in one trip is that trip, not the place, when the
        /// trip holds less than this share of the place (review 16.11., BEFUNDE #3). Not an
        /// album named only after the place ("Italien").
        public var oneTripShareOfPlace = 0.8
        /// Share of an album that lies in *other* sibling proposals before it is
        /// treated as a broader collection (Scenario C).
        public var broaderCollectionShare = 0.2
        /// Two candidates closer than this in score are reported as multiple matches.
        public var multipleMatchScoreGap = 0.15
        public var minimumSharedItems = 3

        public init() {}
    }

    public var thresholds: Thresholds

    public init(thresholds: Thresholds = .init()) {
        self.thresholds = thresholds
    }

    /// The album recorded for a suggestion (`assignments`) is still its album: it shares
    /// photos with it (`shared`), it is empty (a plan stopped before adding the photos), or the
    /// user took the suggestion's photos out by hand. Otherwise it was made for other photos
    /// under the same ID (second review of the place IDs, 18.11.2026).
    public static func isStillAlbum(_ album: CollectionID, of proposal: AlbumProposal, shared: Int,
                                    inventory: CollectionInventory, overrides: OverrideSet) -> Bool {
        shared > 0 || inventory[album]?.assetIDs.isEmpty == true || proposal.assetIDs.contains { overrides.tookOut($0, of: album) }
    }

    /// Version of the matching rules. Stored with the results; results of an older version
    /// are matched again at launch, so a changed rule never waits for the next analysis.
    /// 2: review 16.11. (possible matches never change or count, parts, one album per run).
    /// 3: "Gleicher Name gewinnt" (Fuchs 16.11.): an accepted trip "ergänzen Italien" is reopened.
    /// 4: the album recorded for a suggestion stays its album only while it shares photos with it
    ///    (`isStillAlbum`, second review of the place IDs 18.11.): saved matches that still offer
    ///    "ergänzen" into an album made for other photos are matched again.
    /// 5: "Gleicher Name gewinnt" also below the shares for extending by content (review P1-02):
    ///    saved matches that offer a second "Italien" next to the user's are matched again.
    public static let version = 5

    /// Matches all proposals in one pass using an inverted membership index.
    /// - Parameters:
    ///   - overrides: albums the user marked as "passt nicht" for a suggestion are never offered
    ///     for it again (neither as best match nor as alternative); photos the user took out
    ///     of an album do not count as missing.
    ///   - assignments: the album a suggestion was already applied to (from the managed-album
    ///     records). That album stays the suggestion's album even if it holds many other photos
    ///     or another album has the same content, so an applied suggestion never comes back.
    ///     It is also *only* that suggestion's album: another suggestion never extends it
    ///     (the country Italien must not grow the trip album "Rom · 2024").
    ///   - reserved: albums that already are the complete album of a suggestion outside this
    ///     run (a dismissed one). No suggestion of this run extends them.
    ///   - trips: the photos of every detected trip. A place album that holds photos of one
    ///     trip only is a part of the place (`isPart`), whatever its name.
    ///
    /// Within one run an album of the user is changed for one suggestion at most (review 16.11.,
    /// A5 and A10):
    /// - an album named exactly like a suggestion (normalised: "Italien" for the country
    ///   Italien) belongs to that suggestion when it would extend it, even if a trip of the run
    ///   wants it or already is complete in it (decision Fuchs 16.11.). That trip gets an album
    ///   of its own and sees this one only under "Anpassen". The suggestion extends the user's
    ///   only album of its name whenever that album is mostly its photos, however little of it
    ///   the album holds yet (review P1-02);
    /// - otherwise an album that already holds all of one suggestion ("schon vollständig",
    ///   whether or not the user tapped "Album so lassen") is that suggestion's album, and no
    ///   other suggestion extends it;
    /// - when several suggestions would extend the same album, the one it fits best (Jaccard,
    ///   then score) gets it; the others get an album of their own and see it only under
    ///   "Anpassen".
    public func match(_ proposals: [AlbumProposal], against inventory: CollectionInventory,
                      overrides: OverrideSet = OverrideSet(),
                      assignments: [SortlyID: CollectionID] = [:],
                      reserved: Set<CollectionID> = [],
                      trips: [Set<AssetID>] = []) -> [SortlyID: MatchResult] {
        var stats = Stats()
        return match(proposals, against: inventory, overrides: overrides, assignments: assignments,
                     reserved: reserved, trips: trips, stats: &stats)
    }

    /// Work counted during one run, for tests that must not depend on the clock.
    struct Stats {
        /// How often the photos of each album were read to find its trip (`isOneTripOfPlace`):
        /// at most once per album and run.
        var albumTripScans: [CollectionID: Int] = [:]
        /// Album memberships read to count each suggestion's overlap with the albums: one per
        /// photo of the suggestion and album that photo is in, per time the suggestion is matched.
        var membershipReads = 0
        /// Photos of albums read in full (the sibling count of a family, the trip rule). Each
        /// album at most once per family and run, so a big "Alle" album is not read per suggestion.
        var albumPhotoReads = 0
        /// Times a suggestion was matched (once, plus once per round it lost an album).
        var proposalRuns = 0
    }

    func match(_ proposals: [AlbumProposal], against inventory: CollectionInventory,
               overrides: OverrideSet, assignments: [SortlyID: CollectionID],
               reserved: Set<CollectionID>, trips: [Set<AssetID>], stats: inout Stats) -> [SortlyID: MatchResult] {
        let membership = inventory.albumMembershipIndex()
        // Detected trips (also those too small for a suggestion), for parts of a place.
        var tripOf: [AssetID: Int] = [:]
        if proposals.contains(where: { if case .placeCollection = $0.kind { true } else { false } }) {
            for (index, members) in trips.enumerated() { for a in members { tripOf[a] = index } }
        }

        // Sibling map per proposal family, to detect albums that span several siblings.
        var siblingOf: [String: [AssetID: SortlyID]] = [:]
        for p in proposals {
            var map = siblingOf[p.kind.familyKey, default: [:]]
            for a in p.assetIDs where map[a] == nil { map[a] = p.id }
            siblingOf[p.kind.familyKey] = map
        }

        var titleIndex: [String: [CollectionID]] = [:]
        for album in inventory.albums {
            titleIndex[AlbumTitle.normalized(album.title), default: []].append(album.id)
        }

        // Albums that belong to a current suggestion (Albumist made or extended them for it).
        let current = Set(proposals.map(\.id))
        var owners: [CollectionID: Set<SortlyID>] = [:]
        for (proposalID, albumID) in assignments where current.contains(proposalID) {
            owners[albumID, default: []].insert(proposalID)
        }

        var results: [SortlyID: MatchResult] = [:]
        // Per family and album: how many of the album's photos each sibling suggestion has.
        // Counted once per album instead of once per suggestion, so a big album shared by
        // many suggestions (all favourites, a camera roll export) is read only once.
        var siblingCounts: [String: [CollectionID: [SortlyID: Int]]] = [:]
        // Per album, once per run: the one trip all its photos lie in (inner nil: none).
        var albumTrips: [CollectionID: Int?] = [:]
        var taken: [SortlyID: Set<CollectionID>] = [:]
        // Albums a suggestion gave up to the suggestion named exactly like the album: never its
        // album in this run, not even as complete (offered under "Anpassen" only).
        var ceded: [SortlyID: Set<CollectionID>] = [:]
        func run(_ proposal: AlbumProposal) {
            let claimed = Set(owners.compactMap { albumID, ids in ids.contains(proposal.id) ? nil : albumID })
            let family = proposal.kind.familyKey
            var counts = siblingCounts[family, default: [:]]
            results[proposal.id] = match(
                proposal,
                inventory: inventory,
                overrides: overrides,
                assigned: assignments[proposal.id],
                claimedByOthers: claimed,
                taken: taken[proposal.id] ?? [],
                ceded: ceded[proposal.id] ?? [],
                tripOf: tripOf,
                trips: trips,
                albumTrips: &albumTrips,
                stats: &stats,
                membership: membership,
                siblings: siblingOf[family] ?? [:],
                siblingCounts: &counts,
                titleIndex: titleIndex
            )
            siblingCounts[family] = counts
        }
        for proposal in proposals { run(proposal) }
        let byID = Dictionary(proposals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // One album, one suggestion per run. Every round takes at least one album away from
        // one suggestion for good, so this ends; in practice after one or two rounds.
        while true {
            var keeping: [CollectionID: [AlbumProposal]] = [:]
            var extending: [CollectionID: [AlbumProposal]] = [:]
            for p in proposals {
                guard let r = results[p.id], let best = r.best, best.isEditable else { continue }
                switch r.status {
                case .alreadyComplete: keeping[best.albumID, default: []].append(p)
                case .extendable: extending[best.albumID, default: []].append(p)
                default: break
                }
            }
            func rank(_ p: AlbumProposal) -> (Double, Double, String) {
                let best = results[p.id]?.best
                return (best?.metrics.jaccard ?? 0, best?.score ?? 0, p.id.rawValue)
            }
            var losers: [(AlbumProposal, CollectionID)] = []
            var cedes: [(AlbumProposal, CollectionID)] = []
            for (albumID, ps) in extending {
                // The suggestion the album was applied to keeps it (`assignments`).
                let contenders = ps.filter { assignments[$0.id] != albumID }
                if contenders.count < ps.count {
                    losers += contenders.map { ($0, albumID) }
                    continue
                }
                let keepers = keeping[albumID] ?? []
                // Same name wins (decision Fuchs 16.11., ENTWURF-BEDIENUNG Q8): the user's
                // "Italien" belongs to the suggestion "Italien", also when a trip in this run
                // wants it or already is complete in it. That trip gets an album of its own.
                // Not when a suggestion complete in the album has that name itself.
                let name = AlbumTitle.normalized(inventory[albumID]?.title ?? "")
                func named(_ p: AlbumProposal) -> Bool { !name.isEmpty && AlbumTitle.normalized(p.title) == name }
                let namedContenders = contenders.filter(named)
                if !namedContenders.isEmpty && !keepers.contains(where: named) {
                    let winner = namedContenders.max { rank($0) < rank($1) }
                    losers += contenders.filter { $0.id != winner?.id }.map { ($0, albumID) }
                    cedes += keepers.map { ($0, albumID) }
                    continue
                }
                // Otherwise a suggestion it is already complete for keeps it (also one outside
                // this run, `reserved`), and among several the most similar one gets it.
                if !keepers.isEmpty || reserved.contains(albumID) {
                    losers += contenders.map { ($0, albumID) }
                    continue
                }
                guard contenders.count > 1 else { continue }
                let winner = contenders.max { rank($0) < rank($1) }
                losers += contenders.filter { $0.id != winner?.id }.map { ($0, albumID) }
            }
            if losers.isEmpty && cedes.isEmpty { break }
            for (p, albumID) in losers { taken[p.id, default: []].insert(albumID) }
            for (p, albumID) in cedes { ceded[p.id, default: []].insert(albumID) }
            for id in Set((losers + cedes).map(\.0.id)).sorted(by: { $0.rawValue < $1.rawValue }) {
                if let p = byID[id] { run(p) }
            }
        }
        return results
    }

    private func match(
        _ proposal: AlbumProposal,
        inventory: CollectionInventory,
        overrides: OverrideSet,
        assigned: CollectionID?,
        claimedByOthers: Set<CollectionID>,
        taken: Set<CollectionID>,
        ceded: Set<CollectionID>,
        tripOf: [AssetID: Int],
        trips: [Set<AssetID>],
        albumTrips: inout [CollectionID: Int?],
        stats: inout Stats,
        membership: [AssetID: [CollectionID]],
        siblings: [AssetID: SortlyID],
        siblingCounts: inout [CollectionID: [SortlyID: Int]],
        titleIndex: [String: [CollectionID]]
    ) -> MatchResult {
        var intersections: [CollectionID: Int] = [:]
        stats.proposalRuns += 1
        for asset in proposal.assetIDs {
            let albums = membership[asset] ?? []
            stats.membershipReads += albums.count
            for album in albums { intersections[album, default: 0] += 1 }
        }
        // The album this suggestion was applied to is its album only while it is about the same
        // photos: it holds some of them, or the user took them out by hand. One that shares no
        // photo was made for other photos under this ID (a place that had it before, second
        // review of the place IDs, 18.11.2026): it is not extended with these. An empty album
        // stays its album: a plan stopped after creating it and before adding the photos, the
        // next plan fills it (instead of a second album of the same name).
        let assigned = assigned.flatMap { album -> CollectionID? in
            Self.isStillAlbum(album, of: proposal, shared: intersections[album] ?? 0, inventory: inventory, overrides: overrides) ? album : nil
        }
        let tracksTrips: Bool
        if case .placeCollection = proposal.kind { tracksTrips = !tripOf.isEmpty } else { tracksTrips = false }
        var tripCounts: [Int: Int] = [:]
        /// All the album's photos lie in one trip, and the place is much more than that trip.
        /// The trip of an album is found once per run (`albumTrips`), only for albums asked about.
        func isOneTripOfPlace(_ album: CollectionSnapshot) -> Bool {
            guard tracksTrips else { return false }
            let trip: Int?
            if let known = albumTrips[album.id] {
                trip = known
            } else {
                var found: Int?
                for asset in album.assetIDs {
                    guard let t = tripOf[asset], found == nil || found == t else { found = nil; break }
                    found = t
                }
                albumTrips[album.id] = .some(found)
                stats.albumTripScans[album.id, default: 0] += 1
                stats.albumPhotoReads += album.assetIDs.count
                trip = found
            }
            guard let trip else { return false }
            let count: Int
            if let known = tripCounts[trip] {
                count = known
            } else {
                count = trips[trip].reduce(0) { $0 + (proposal.assetIDs.contains($1) ? 1 : 0) }
                tripCounts[trip] = count
            }
            return Double(count) < thresholds.oneTripShareOfPlace * Double(proposal.assetIDs.count)
        }

        let proposalTokens = AlbumTitle.tokens(proposal.title)
        var candidates: [MatchCandidate] = []
        var weak: [MatchCandidate] = []
        // Smaller albums inside a place collection ("Rom 2024" inside Italien): the user may
        // still pick one under "Anpassen", but Albumist never recommends growing them.
        var parts: [MatchCandidate] = []

        for (albumID, shared) in intersections {
            guard let album = inventory[albumID], shared >= min(thresholds.minimumSharedItems, proposal.assetIDs.count),
                  !overrides.isRejectedMatch(albumID, for: proposal.id) else { continue }
            let metrics = OverlapMetrics(proposalCount: proposal.assetIDs.count, albumCount: album.assetIDs.count, intersection: shared)

            // Broader collection: a substantial part of the album belongs to other siblings
            // (only asked for event-like suggestions).
            var broader = false
            if proposal.kind.isEventLike, !album.assetIDs.isEmpty {
                let counts: [SortlyID: Int]
                if let cached = siblingCounts[albumID] {
                    counts = cached
                } else {
                    var fresh: [SortlyID: Int] = [:]
                    for asset in album.assetIDs { if let s = siblings[asset] { fresh[s, default: 0] += 1 } }
                    stats.albumPhotoReads += album.assetIDs.count
                    siblingCounts[albumID] = fresh
                    counts = fresh
                }
                let otherSiblingItems = counts.reduce(0) { $0 + ($1.key == proposal.id ? 0 : $1.value) }
                let otherShare = Double(otherSiblingItems) / Double(album.assetIDs.count)
                broader = otherSiblingItems > 0 && otherShare >= thresholds.broaderCollectionShare
            }

            let relation: AlbumRelation
            if broader {
                relation = .broaderCollection
            } else if metrics.purity >= thresholds.completePurity && metrics.coverage >= thresholds.completeCoverage {
                relation = .equivalent
            } else if metrics.purity >= thresholds.extendablePurity {
                relation = .partOfProposal
            } else {
                relation = .partialOverlap
            }

            // Another suggestion's album only counts if it already is exactly this set
            // (a country visited on one trip; an equivalent album is complete, see `status`);
            // it is never extended with this suggestion's photos.
            if claimedByOthers.contains(albumID) && relation != .equivalent { continue }
            // Taken in this run by another suggestion: the same, but still offered under "Anpassen".
            let isTaken = taken.contains(albumID)
            let holdsAll = isTaken && (relation == .equivalent || (relation == .partOfProposal && !proposal.assetIDs.contains {
                !album.assetIDs.contains($0) && overrides.mayAdd($0, toAlbum: albumID) && overrides.mayAdd($0, toSource: proposal.id)
            }))

            let nameSimilarity = Self.tokenSimilarity(proposalTokens, AlbumTitle.tokens(album.title))
            let weights = Self.weights(for: proposal.kind)
            let score = weights.purity * metrics.purity + weights.coverage * metrics.coverage + weights.name * nameSimilarity

            let candidate = MatchCandidate(
                albumID: albumID,
                albumTitle: album.title,
                metrics: metrics,
                relation: relation,
                nameSimilarity: nameSimilarity,
                score: score,
                isEditable: album.isEditableAlbum
            )
            // In this run the album is another suggestion's: offered under "Anpassen" only.
            // An album named only after the place ("Italien" made after the first trip) stays the
            // place's album, as without trips (re-check 16.11.).
            let oneTrip = relation != .equivalent && metrics.coverage < thresholds.completeCoverage
                && tracksTrips && isOneTripOfPlace(album) && !Self.nameAddsNothing(album: album.title, proposal: proposal.title)
            if ceded.contains(albumID) || isTaken && !holdsAll || oneTrip || isPart(candidate, of: proposal) {
                parts.append(candidate)
                continue
            }
            // An album that holds this suggestion among many other photos ("iPhone-Export" with a
            // whole trip, "Familie" with the dog photos, "Italien" with the city Rom) is not its
            // album: it is never recommended and never makes the photos count as sorted, but
            // the user may still pick it under "Anpassen" (review 16.11., A1 and A3).
            if relation != .broaderCollection, metrics.purity < thresholds.candidatePurity,
               metrics.coverage >= thresholds.candidateCoverage {
                parts.append(candidate)
                continue
            }
            let qualifies = relation != .broaderCollection && metrics.purity >= thresholds.candidatePurity
            if qualifies { candidates.append(candidate) } else { weak.append(candidate) }
        }

        // The album this suggestion was applied to stays its album (first in line).
        if let assigned, let album = inventory[assigned], album.isEditableAlbum, !overrides.isRejectedMatch(assigned, for: proposal.id) {
            candidates.removeAll { $0.albumID == assigned }
            weak.removeAll { $0.albumID == assigned }
            let metrics = OverlapMetrics(proposalCount: proposal.assetIDs.count, albumCount: album.assetIDs.count,
                                         intersection: intersections[assigned] ?? 0)
            candidates.append(MatchCandidate(albumID: assigned, albumTitle: album.title, metrics: metrics, relation: .partOfProposal,
                                             nameSimilarity: Self.tokenSimilarity(proposalTokens, AlbumTitle.tokens(album.title)),
                                             score: 2, isEditable: true))
        }

        candidates.sort { ($0.score, $0.albumID.rawValue) > ($1.score, $1.albumID.rawValue) }
        weak.sort { ($0.score, $0.albumID.rawValue) > ($1.score, $1.albumID.rawValue) }
        parts.removeAll { $0.albumID == assigned }
        parts.sort { ($0.score, $0.albumID.rawValue) > ($1.score, $1.albumID.rawValue) }

        let sameName = (titleIndex[AlbumTitle.normalized(proposal.title)] ?? []).sorted()
        // The one album of the user named exactly like this suggestion (`isNamedLike`).
        let sameNamed = sameName.filter { inventory[$0]?.isEditableAlbum == true }
        let namedAlbum = sameNamed.count == 1 ? sameNamed.first : nil
        var reasons: [MatchReason] = []

        // Prefer editable albums; a read-only smart album must not block a real album.
        let editable = candidates.filter(\.isEditable)
        guard let best = editable.first ?? candidates.first else {
            for broader in weak where broader.relation == .broaderCollection {
                reasons.append(.albumIsBroaderCollection(album: broader.albumTitle, siblingCount: 2))
            }
            if let conflict = sameName.first, let album = inventory[conflict] {
                let shared = intersections[conflict] ?? 0
                reasons.append(.sameNameDifferentContent(album: album.title, sharedItems: shared))
                return MatchResult(proposalID: proposal.id, status: .nameConflict, best: nil, alternatives: weak + parts, sameNameAlbums: sameName, reasons: reasons)
            }
            if let w = weak.first(where: { $0.relation != .broaderCollection }) {
                reasons.append(.weakOverlapOnly(album: w.albumTitle, shared: w.metrics.intersection))
                return MatchResult(proposalID: proposal.id, status: .ambiguous, best: nil, alternatives: weak + parts, sameNameAlbums: sameName, reasons: reasons)
            }
            reasons.append(.noExistingAlbum)
            return MatchResult(proposalID: proposal.id, status: .newAlbumRequired, best: nil, alternatives: weak + parts, sameNameAlbums: sameName, reasons: reasons)
        }

        let alternatives = (candidates.filter { $0.albumID != best.albumID }) + weak + parts
        // Missing photos Albumist may still add: photos the user took out of the album by hand stay out.
        let bestMembers = inventory[best.albumID]?.assetIDs ?? []
        let addable = best.metrics.missing == 0 ? 0 : proposal.assetIDs.filter {
            !bestMembers.contains($0) && overrides.mayAdd($0, toAlbum: best.albumID) && overrides.mayAdd($0, toSource: proposal.id)
        }.count
        // The album already holds everything: there is nothing to choose, even if other
        // albums hold the same photos (a country with one city, a trip that is the whole visit).
        let bestIsComplete = best.isEditable && addable == 0
            && (best.relation == .equivalent || best.relation == .partOfProposal)
        if !best.isEditable {
            reasons.append(.albumContains(album: best.albumTitle, contained: best.metrics.intersection, total: best.metrics.proposalCount))
            reasons.append(.albumNotEditable(album: best.albumTitle))
            return MatchResult(proposalID: proposal.id, status: .notEditable, best: best, alternatives: alternatives, sameNameAlbums: sameName, reasons: reasons)
        }

        let strongRivals = bestIsComplete ? [] : editable.dropFirst().filter {
            $0.metrics.purity >= thresholds.extendablePurity && best.score - $0.score < thresholds.multipleMatchScoreGap
        }
        if !strongRivals.isEmpty {
            // No "will be added" here: nothing happens until the user picks an album.
            for c in [best] + strongRivals {
                reasons.append(.albumContains(album: c.albumTitle, contained: c.metrics.intersection, total: c.metrics.proposalCount))
            }
            reasons.append(.severalAlbumsMatch(count: strongRivals.count + 1))
            return MatchResult(proposalID: proposal.id, status: .multipleMatches, best: best, alternatives: alternatives, sameNameAlbums: sameName, reasons: reasons)
        }

        let status: MatchStatus
        switch best.relation {
        case _ where bestIsComplete:
            status = .alreadyComplete
        case _ where best.albumID == assigned:
            // The album Albumist made or extended for this suggestion stays its album, however
            // much the suggestion grew ("2026" made in January): never a second one.
            status = .extendable
        case .equivalent:
            status = .alreadyComplete
        case .partOfProposal where addable == 0:
            status = .alreadyComplete
        case .partOfProposal where best.metrics.coverage >= thresholds.extendableCoverage && isCertain(best, for: proposal):
            status = .extendable
        case _ where best.albumID == namedAlbum:
            // Gleicher Name gewinnt (decision Fuchs 16.11., review P1-02): the user's only album
            // named like the suggestion is its album, also when it holds little of it ("Italien"
            // made after the first of five trips) or other photos too (the way there through
            // Austria), as long as it is mostly this suggestion's (`candidatePurity`). Otherwise
            // a second "Italien" was offered next to it.
            status = addable == 0 ? .alreadyComplete : .extendable
        default:
            status = .possibleMatch
        }
        reasons.append(.albumContains(album: best.albumTitle, contained: best.metrics.intersection, total: best.metrics.proposalCount))
        // "werden ergänzt" only where Albumist really adds them by default.
        if addable > 0 && status == .extendable { reasons.append(.missingItems(count: addable)) }
        if best.metrics.extra > 0 { reasons.append(.albumHasOtherItems(album: best.albumTitle, count: best.metrics.extra)) }
        if status == .possibleMatch { reasons.append(.keptUnchangedUntilChosen(album: best.albumTitle)) }
        return MatchResult(proposalID: proposal.id, status: status, best: best, alternatives: alternatives, sameNameAlbums: sameName, reasons: reasons)
    }

    /// A smaller album about something else inside a collection: "Rom · 2024" holds only
    /// Italy photos, but it is Rom, not Italien, and must not grow into a country album.
    /// The content alone cannot tell a part from an incomplete album, so the name decides:
    /// - a place collection only extends an album that shares a word with the place
    ///   ("Urlaub in Italien");
    /// - no collection (place, category, year …) extends an album whose name holds a year the
    ///   suggestion's name does not: "Italien 2019" or Albumist's own "Italien · Mai 2024" is
    ///   one trip, not the country, and never gets the photos of other years (review 16.11.,
    ///   A2 and A9). Events (trips, periods) are bounded themselves and not affected.
    /// An album that already holds the whole suggestion still counts as complete.
    func isPart(_ candidate: MatchCandidate, of proposal: AlbumProposal) -> Bool {
        isPart(candidate, kind: proposal.kind, title: proposal.title)
    }

    /// `title` nil: the suggestion's name is unknown, only the content and the shared words count.
    func isPart(_ candidate: MatchCandidate, kind: ProposalKind, title: String?) -> Bool {
        guard !kind.isEventLike, candidate.relation != .equivalent,
              candidate.metrics.coverage < thresholds.completeCoverage else { return false }
        if let title, Self.namesOtherYear(album: candidate.albumTitle, proposal: title) { return true }
        guard case .placeCollection = kind else { return false }
        return candidate.nameSimilarity == 0
    }

    /// The album's name holds a year that the suggestion's name does not.
    static func namesOtherYear(album: String, proposal: String) -> Bool {
        let years = years(in: album)
        guard !years.isEmpty else { return false }
        return !years.isSubset(of: Self.years(in: proposal))
    }

    /// The years a title names: "2019", "Urlaub2019", "Italien '19", "Winter 2025/26" and
    /// "Winter 2025/2026" (both 2025 and 2026), "2019–2021" (both ends).
    static func years(in title: String) -> Set<Int> {
        let chars = Array(title)
        func digits(at i: Int, count: Int) -> Int? {
            guard i >= 0, i + count <= chars.count else { return nil }
            let run = chars[i..<(i + count)]
            guard run.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            // Not part of a longer number.
            if i > 0, chars[i - 1].isASCII && chars[i - 1].isNumber { return nil }
            if i + count < chars.count, chars[i + count].isASCII && chars[i + count].isNumber { return nil }
            return Int(String(run))
        }
        var result = Set<Int>()
        var i = 0
        while i < chars.count {
            if let year = digits(at: i, count: 4), (1900...2099).contains(year) {
                result.insert(year)
                // "2025/26": the short second year belongs to the same century.
                var j = i + 4
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, "/–-".contains(chars[j]) {
                    var k = j + 1
                    while k < chars.count, chars[k] == " " { k += 1 }
                    if let short = digits(at: k, count: 2) { result.insert(year / 100 * 100 + short) }
                }
                i += 4
                continue
            }
            // "'19", "’19": a year in short form.
            if "'’‘´`".contains(chars[i]), let short = digits(at: i + 1, count: 2) {
                result.insert(short <= 69 ? 2000 + short : 1900 + short)
                i += 3
                continue
            }
            i += 1
        }
        return result
    }

    /// Words of dates: numbers, months and seasons (German and English). A shared date word
    /// does not make an album a collection's album ("Italien, Mai 2024" is not "Mai 2024").
    static func isDateWord(_ token: String) -> Bool {
        if token.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        return dateWords.contains(token)
    }

    private static let dateWords: Set<String> = [
        "januar", "jan", "februar", "feb", "marz", "maerz", "mar", "april", "apr", "mai", "juni", "jun", "juli", "jul",
        "august", "aug", "september", "sep", "sept", "oktober", "okt", "november", "nov", "dezember", "dez",
        "january", "february", "march", "may", "june", "july", "october", "oct", "december", "dec",
        "jahr", "year", "monat", "month",
        "fruhling", "fruehling", "sommer", "herbst", "winter", "spring", "summer", "autumn", "fall",
    ]

    /// Whether extending `candidate` for a collection is certain enough to be the default.
    /// Trips and periods: the content decides (`extendableCoverage`). Collections: the album's
    /// name must say it is this collection (all its words are in the suggestion's name, or it
    /// shares a word that is not a date: "Italien", "Urlaub in Italien" for Italien), or the
    /// album already holds most of it. "Bello" for Hunde, "Italien 2019" for the year 2019 or
    /// "Italien, Mai 2024" for the month Mai 2024 stay possible matches (review 16.11.).
    func isCertain(_ candidate: MatchCandidate, for proposal: AlbumProposal) -> Bool {
        if proposal.kind.isEventLike || candidate.metrics.coverage >= thresholds.unnamedCollectionCoverage { return true }
        return Self.nameSaysCollection(album: candidate.albumTitle, proposal: proposal.title)
    }

    static func nameSaysCollection(album: String, proposal: String) -> Bool {
        if nameAddsNothing(album: album, proposal: proposal) { return true }
        return AlbumTitle.tokens(album).intersection(AlbumTitle.tokens(proposal)).contains { !isDateWord($0) }
    }

    /// Nothing in the album's name beyond the suggestion's: "Italien" for Italien, "2019" for
    /// 2019, "Winter 2025/2026" for "Winter 2025/26". An empty name says nothing.
    static func nameAddsNothing(album: String, proposal: String) -> Bool {
        func words(_ title: String) -> Set<String> { AlbumTitle.tokens(title).filter { !$0.allSatisfy { $0.isASCII && $0.isNumber } } }
        let a = words(album)
        let albumYears = years(in: album)
        guard !a.isEmpty || !albumYears.isEmpty else { return false }
        return a.isSubset(of: words(proposal)) && albumYears.isSubset(of: years(in: proposal))
    }

    /// The other albums that fit a suggestion exactly as well as its best album when several
    /// match (`multipleMatches`): editable, the same score, mostly this suggestion's photos,
    /// and no part (`isPart`; pass the suggestion's `title` for the year rule). Until the user
    /// picks one, each of them sorts its photos.
    public func tiedWithBest(_ result: MatchResult, kind: ProposalKind, title: String? = nil) -> [MatchCandidate] {
        guard result.status == .multipleMatches, let best = result.best else { return [] }
        return result.alternatives.filter {
            $0.isEditable && $0.score == best.score && $0.relation != .broaderCollection
                && $0.metrics.purity >= thresholds.extendablePurity && !isPart($0, kind: kind, title: title)
        }
    }

    /// The albums that make a suggestion's photos count as sorted (the ring, "davon in deinen
    /// Alben", the area overview): the best album of a certain match (complete, or extended by
    /// default). With several matching albums only those that are mostly this suggestion
    /// (purity ≥ `extendablePurity`): the best one and the ones tied with it. A possible match
    /// and a read-only album never count (review 16.11.).
    public func sortingAlbums(_ result: MatchResult?, kind: ProposalKind, title: String? = nil) -> Set<CollectionID> {
        guard let result, let best = result.best, best.isEditable else { return [] }
        switch result.status {
        case .alreadyComplete, .extendable:
            return [best.albumID]
        case .multipleMatches:
            var albums = Set(tiedWithBest(result, kind: kind, title: title).map(\.albumID))
            if best.metrics.purity >= thresholds.extendablePurity { albums.insert(best.albumID) }
            return albums
        default:
            return []
        }
    }

    struct Weights { var purity: Double; var coverage: Double; var name: Double }

    /// Event albums must be pure; collections may be partial but should be on-topic.
    static func weights(for kind: ProposalKind) -> Weights {
        switch kind {
        case .trip, .customPeriod: Weights(purity: 0.5, coverage: 0.4, name: 0.1)
        case .placeCollection, .frequentPlace, .chronology: Weights(purity: 0.55, coverage: 0.35, name: 0.1)
        default: Weights(purity: 0.6, coverage: 0.3, name: 0.1)
        }
    }

    static func tokenSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b)
        guard !union.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(union.count)
    }
}

/// Finds groups of existing albums with overlapping content (prompt §5.5).
/// The result only proposes *album structure* merges – never deletion of originals.
public struct AlbumOverlapAnalyzer: Sendable {
    public struct MergeSuggestion: Hashable, Sendable, Codable {
        public var albumIDs: [CollectionID]
        /// Number of distinct media in the union of all albums.
        public var distinctAssetCount: Int
        /// Sum of all album memberships (shows how much overlap there is).
        public var totalMemberships: Int
    }

    public var minJaccard = 0.3
    public var minContainment = 0.7
    public var minAlbumSize = 5

    public init() {}

    /// `excluding`: albums Albumist created or manages. They overlap on purpose (a country
    /// album holds its trips), so they are never offered for merging.
    public func suggestions(in inventory: CollectionInventory, excluding excluded: Set<CollectionID> = []) -> [MergeSuggestion] {
        let albums = inventory.albums.filter { $0.kind == .userAlbum && $0.assetIDs.count >= minAlbumSize && !excluded.contains($0.id) }
        let index = Dictionary(uniqueKeysWithValues: albums.enumerated().map { ($1.id, $0) })
        var parent = Array(albums.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }

        // Pairwise intersections through the inverted index (sparse in practice).
        var pairCounts: [Int: [Int: Int]] = [:]
        for (_, albumIDs) in inventory.albumMembershipIndex() {
            let ids = albumIDs.compactMap { index[$0] }.sorted()
            guard ids.count > 1 else { continue }
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    pairCounts[ids[i], default: [:]][ids[j], default: 0] += 1
                }
            }
        }
        for (i, row) in pairCounts {
            for (j, shared) in row {
                let a = albums[i].assetIDs.count, b = albums[j].assetIDs.count
                let jaccard = Double(shared) / Double(a + b - shared)
                let containment = Double(shared) / Double(min(a, b))
                if jaccard >= minJaccard || containment >= minContainment {
                    parent[find(i)] = find(j)
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in albums.indices { groups[find(i), default: []].append(i) }
        return groups.values
            .filter { $0.count > 1 }
            .compactMap { members in
                var union = Set<AssetID>()
                var total = 0
                var largest = 0
                for m in members {
                    union.formUnion(albums[m].assetIDs)
                    total += albums[m].assetIDs.count
                    largest = max(largest, Set(albums[m].assetIDs).count)
                }
                // The largest album already holds every photo (e.g. "Rom" inside "Italien"):
                // a part of a bigger album, nothing to merge.
                guard union.count > largest else { return nil }
                return MergeSuggestion(albumIDs: members.map { albums[$0].id }.sorted(), distinctAssetCount: union.count, totalMemberships: total)
            }
            .sorted { $0.distinctAssetCount > $1.distinctAssetCount }
    }
}
