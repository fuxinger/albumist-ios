import Foundation

/// The library's areas ("Unsortiert", "Vorschläge", "Unsicher", "Sortiert", "Ignoriert",
/// "Alle"), each newest first, made in one pass off the main thread (app-speed, 18.11.2026). The
/// tab "Unsortiert" shows three of them (`unsortedTabFilters`).
///
/// Stress run 44144011110 (50,000 photos): the first tap on "Mediathek" took 15.8 s, with a
/// main-thread stall of 7.7 s. `AppModel.bucketMembers` filtered and sorted the facts of every
/// photo on the main thread, in the view's body, for each area anew whenever facts or states
/// changed (every count during an analysis), copying the whole `AssetFacts` of each photo.
/// Here the photos are ordered once (by index, not by moving facts around), every photo is
/// put into its areas in one pass, and an area holds only what the grid needs (`Item`).
///
/// "Ignorieren" and "Nicht mehr ignorieren" move only the tapped photos (`updating`), so the
/// grid follows the tap at once instead of waiting for the areas to be made anew.
///
/// "Sortiert" and "Nicht sortiert" hold what the ring counts as sorted and as not yet sorted
/// (`OrganizationStatusResolver.ringPart`, decision Fuchs 18.11.), over the same part of the
/// library (`inScope`).
public struct LibraryBuckets: Sendable, Equatable {
    /// One photo in the grid: its id and the date its accessibility label says.
    public struct Item: Hashable, Sendable, Identifiable {
        public let id: AssetID
        public let date: Date?

        public init(id: AssetID, date: Date?) {
            self.id = id
            self.date = date
        }
    }

    /// The filters of the tab "Unsortiert" (design W1, tabs 6B), the first one shown when the tab
    /// opens. Suggestions have a tab of their own; "Sortiert" and "Alle" are no filters of it. A
    /// photo with an open suggestion the ring counts is in "Unsortiert" as well (`buckets`).
    public static let unsortedTabFilters: [InboxBucket] = [.unorganized, .uncertain, .ignored]

    private var members: [InboxBucket: [Item]] = [:]
    /// Each photo's place among all photos, newest first (`.all` in this order).
    private var rank: [AssetID: Int] = [:]
    /// Photos outside the part of the library the ring counts ("Nur 2026").
    private var outsideScope: Set<AssetID> = []

    public init() {}

    /// The photos of one area, newest first.
    public subscript(bucket: InboxBucket) -> [Item] { members[bucket] ?? [] }

    /// Every photo (`facts`) in the areas its state puts it in (`OrganizationStatusResolver.buckets`);
    /// a photo without a state yet is only in "Alle". Newest first; photos without a date last,
    /// photos with the same date in the order of `facts`. `inScope`: the photo is in the part of
    /// the library the ring counts; one outside it is in neither "Sortiert" nor "Nicht sortiert".
    /// `shouldStop` is asked now and then: `true` ends the work early with `nil` (newer facts or
    /// states are on their way).
    public static func make(facts: [AssetFacts], states: [AssetID: AssetOrganizationState],
                            resolver: OrganizationStatusResolver,
                            shouldStop: () -> Bool = { false },
                            inScope: (AssetFacts) -> Bool = { _ in true }) -> LibraryBuckets? {
        var photoReads = 0
        return make(facts: facts, states: states, resolver: resolver, shouldStop: shouldStop, inScope: inScope,
                    photoReads: &photoReads)
    }

    /// `make`, adding to `photoReads` one per comparison of two photos' dates while ordering them
    /// and one per photo put into its areas: about n log n for n photos, once (tests count it
    /// instead of timing it; review P5-14 b).
    static func make(facts: [AssetFacts], states: [AssetID: AssetOrganizationState],
                     resolver: OrganizationStatusResolver,
                     shouldStop: () -> Bool = { false },
                     inScope: (AssetFacts) -> Bool = { _ in true },
                     photoReads: inout Int) -> LibraryBuckets? {
        if shouldStop() { return nil }
        var reads = 0
        defer { photoReads += reads }
        let dates = facts.map { $0.asset.creationDate ?? .distantPast }
        let order = facts.indices.sorted { a, b in
            reads += 1
            return dates[a] != dates[b] ? dates[a] > dates[b] : a < b
        }
        if shouldStop() { return nil }
        var result = LibraryBuckets()
        result.rank.reserveCapacity(facts.count)
        var members: [InboxBucket: [Item]] = [.all: []]
        members[.all]?.reserveCapacity(facts.count)
        for (position, index) in order.enumerated() {
            if position % 5_000 == 4_999, shouldStop() { return nil }
            reads += 1
            let f = facts[index]
            // A photo listed twice keeps its first (newest) place.
            guard result.rank[f.id] == nil else { continue }
            result.rank[f.id] = members[.all, default: []].count
            let item = Item(id: f.id, date: f.asset.creationDate)
            let counted = inScope(f)
            if !counted { result.outsideScope.insert(f.id) }
            for bucket in buckets(states[f.id], resolver, inScope: counted) {
                members[bucket, default: []].append(item)
            }
        }
        result.members = members
        return result
    }

    /// The same areas after some photos changed their state to `new`, without making them
    /// anew: each photo leaves the areas it is in now and joins the ones `new` puts it in, at its
    /// place in the order. Where a photo is now is looked up in the areas themselves, not taken
    /// from older states, so areas made from states a little older than the app's (a pass still
    /// on its way) never keep a photo in two areas (second review of the app-speed branch, 5).
    /// Gives what `make` gives with the new states for these photos.
    ///
    /// A few photos per area are moved by binary search; more are merged in one pass over the
    /// area, so a large selection costs about one pass per area, not one per photo.
    public func updating(_ ids: some Sequence<AssetID>, to new: [AssetID: AssetOrganizationState],
                         resolver: OrganizationStatusResolver) -> LibraryBuckets {
        var photoReads = 0
        return updating(ids, to: new, resolver: resolver, photoReads: &photoReads)
    }

    /// `updating`, adding to `photoReads` the members of the areas it looked at: one per step of
    /// a binary search (about log n per moved photo and area) and one per member of an area it
    /// merges. A tap or two never goes through a whole area (tests count it instead of timing
    /// it; review P5-14 b).
    func updating(_ ids: some Sequence<AssetID>, to new: [AssetID: AssetOrganizationState],
                  resolver: OrganizationStatusResolver, photoReads: inout Int) -> LibraryBuckets {
        let all = self[.all]
        var belongs: [AssetID: Set<InboxBucket>] = [:]
        for id in ids {
            guard let position = rank[id], position < all.count else { continue }
            belongs[id] = Self.buckets(new[id], resolver, inScope: !outsideScope.contains(id))
        }
        guard !belongs.isEmpty else { return self }
        let moved = belongs.keys.sorted { rank[$0]! < rank[$1]! }
        var result = self
        for bucket in InboxBucket.allCases where bucket != .all {
            let list = self[bucket]
            var leaving: Set<AssetID> = []
            var joining: [Item] = []
            for id in moved {
                let isIn = index(of: id, in: list, reads: &photoReads) != nil
                let goes = belongs[id]!.contains(bucket)
                if isIn && !goes { leaving.insert(id) }
                if !isIn && goes { joining.append(all[rank[id]!]) }
            }
            guard !leaving.isEmpty || !joining.isEmpty else { continue }
            result.members[bucket] = leaving.count + joining.count <= Self.fewMoves
                ? moving(leaving, joining, in: list, reads: &photoReads)
                : merging(leaving, joining, into: list, reads: &photoReads)
        }
        return result
    }

    /// Up to this many photos per area are moved one by one.
    static let fewMoves = 16

    /// Where the photo is in an area, by binary search on its place among all photos.
    private func index(of id: AssetID, in list: [Item], reads: inout Int) -> Int? {
        guard let place = rank[id] else { return nil }
        let i = firstIndex(atOrAfter: place, in: list, reads: &reads)
        return i < list.count && list[i].id == id ? i : nil
    }

    /// The first member at or after `place` in the order of all photos.
    private func firstIndex(atOrAfter place: Int, in list: [Item], reads: inout Int) -> Int {
        var low = 0, high = list.count
        while low < high {
            reads += 1
            let mid = (low + high) / 2
            if (rank[list[mid].id] ?? .max) < place { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func moving(_ leaving: Set<AssetID>, _ joining: [Item], in list: [Item], reads: inout Int) -> [Item] {
        var list = list
        for id in leaving { if let i = index(of: id, in: list, reads: &reads) { list.remove(at: i) } }
        for item in joining { list.insert(item, at: firstIndex(atOrAfter: rank[item.id] ?? .max, in: list, reads: &reads)) }
        return list
    }

    /// `joining` in the order of all photos.
    private func merging(_ leaving: Set<AssetID>, _ joining: [Item], into list: [Item], reads: inout Int) -> [Item] {
        var merged: [Item] = []
        merged.reserveCapacity(list.count + joining.count)
        var next = 0
        reads += list.count
        for item in list where !leaving.contains(item.id) {
            let place = rank[item.id] ?? .max
            while next < joining.count, (rank[joining[next].id] ?? .max) < place {
                merged.append(joining[next])
                next += 1
            }
            merged.append(item)
        }
        merged.append(contentsOf: joining[next...])
        return merged
    }

    /// Same photos in the same areas in the same order (an area without photos is empty either way).
    public static func == (lhs: LibraryBuckets, rhs: LibraryBuckets) -> Bool {
        lhs.rank == rhs.rank && lhs.outsideScope == rhs.outsideScope && InboxBucket.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }

    static func buckets(_ state: AssetOrganizationState?, _ resolver: OrganizationStatusResolver, inScope: Bool = true) -> Set<InboxBucket> {
        guard let state else { return [.all] }
        return resolver.buckets(state, inScope: inScope)
    }
}
