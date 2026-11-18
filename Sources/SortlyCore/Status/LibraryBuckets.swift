import Foundation

/// The library tab's areas ("Nicht sortiert", "Vorschläge", "Unsicher", "Sortiert", "Ignoriert",
/// "Alle"), each newest first, made in one pass off the main thread (app-speed, 18.11.2026).
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

    private var members: [InboxBucket: [Item]] = [:]
    /// Each photo's place among all photos, newest first (`.all` in this order).
    private var rank: [AssetID: Int] = [:]

    public init() {}

    /// The photos of one area, newest first.
    public subscript(bucket: InboxBucket) -> [Item] { members[bucket] ?? [] }

    /// Every photo (`facts`) in the areas its state puts it in (`OrganizationStatusResolver.buckets`);
    /// a photo without a state yet is only in "Alle". Newest first; photos without a date last,
    /// photos with the same date in the order of `facts`. `shouldStop` is asked now and then:
    /// `true` ends the work early with `nil` (newer facts or states are on their way).
    public static func make(facts: [AssetFacts], states: [AssetID: AssetOrganizationState],
                            resolver: OrganizationStatusResolver,
                            shouldStop: () -> Bool = { false }) -> LibraryBuckets? {
        if shouldStop() { return nil }
        let dates = facts.map { $0.asset.creationDate ?? .distantPast }
        let order = facts.indices.sorted { a, b in dates[a] != dates[b] ? dates[a] > dates[b] : a < b }
        if shouldStop() { return nil }
        var result = LibraryBuckets()
        result.rank.reserveCapacity(facts.count)
        var members: [InboxBucket: [Item]] = [.all: []]
        members[.all]?.reserveCapacity(facts.count)
        for (position, index) in order.enumerated() {
            if position % 5_000 == 4_999, shouldStop() { return nil }
            let f = facts[index]
            // A photo listed twice keeps its first (newest) place.
            guard result.rank[f.id] == nil else { continue }
            result.rank[f.id] = members[.all, default: []].count
            let item = Item(id: f.id, date: f.asset.creationDate)
            for bucket in buckets(states[f.id], resolver) {
                members[bucket, default: []].append(item)
            }
        }
        result.members = members
        return result
    }

    /// The same areas after some photos changed their state (`old` to `new`), without making
    /// them anew: the photos leave the areas they are no longer in and join the others at their
    /// place in the order. Gives what `make` gives with the new states.
    public func updating(_ ids: some Sequence<AssetID>, from old: [AssetID: AssetOrganizationState],
                         to new: [AssetID: AssetOrganizationState], resolver: OrganizationStatusResolver) -> LibraryBuckets {
        var result = self
        let all = self[.all]
        var leaving: [InboxBucket: Set<AssetID>] = [:]
        var joining: [InboxBucket: [Item]] = [:]
        for id in Set(ids) {
            guard let position = rank[id], position < all.count else { continue }
            let was = Self.buckets(old[id], resolver), now = Self.buckets(new[id], resolver)
            guard was != now else { continue }
            for bucket in was.subtracting(now) { leaving[bucket, default: []].insert(id) }
            for bucket in now.subtracting(was) { joining[bucket, default: []].append(all[position]) }
        }
        for (bucket, ids) in leaving {
            result.members[bucket]?.removeAll { ids.contains($0.id) }
        }
        for (bucket, items) in joining {
            var list = result.members[bucket] ?? []
            for item in items.sorted(by: { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }) {
                let place = rank[item.id] ?? .max
                // First member that comes after the photo in the order of all photos.
                var low = 0, high = list.count
                while low < high {
                    let mid = (low + high) / 2
                    if (rank[list[mid].id] ?? .max) < place { low = mid + 1 } else { high = mid }
                }
                list.insert(item, at: low)
            }
            result.members[bucket] = list
        }
        return result
    }

    /// Same photos in the same areas in the same order (an area without photos is empty either way).
    public static func == (lhs: LibraryBuckets, rhs: LibraryBuckets) -> Bool {
        lhs.rank == rhs.rank && InboxBucket.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }

    static func buckets(_ state: AssetOrganizationState?, _ resolver: OrganizationStatusResolver) -> Set<InboxBucket> {
        guard let state else { return [.all] }
        return resolver.buckets(state)
    }
}
