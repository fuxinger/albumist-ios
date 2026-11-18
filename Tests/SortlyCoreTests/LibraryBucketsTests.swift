import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// App-speed (18.11.2026): the library tab's areas are made off the main thread in one pass
/// (`LibraryBuckets`). Stress run 44144011110: the first tap on "Mediathek" with 50,000 photos
/// took 15.8 s, 7.7 s of it a stalled main thread filtering and sorting in the view's body.
@Suite("Library areas")
struct LibraryBucketsTests {
    static let resolver = OrganizationStatusResolver(primaryAreas: [.places, .trips])
    static let statuses: [AreaStatus] = [.organized, .preExisting, .proposed, .unorganized, .notApplicable, .analysisPending]

    /// A state for most photos (a few have none yet), of every kind the areas tell apart.
    static func states(for facts: [AssetFacts], seed: UInt64 = 7) -> [AssetID: AssetOrganizationState] {
        var generator = SplitMix(seed: seed)
        var states: [AssetID: AssetOrganizationState] = [:]
        for f in facts {
            let roll = generator.next() % 100
            guard roll >= 3 else { continue }
            var areas: [OrganizationArea: AreaStatus] = [
                .places: statuses[Int(generator.next() % UInt64(statuses.count))],
                .trips: statuses[Int(generator.next() % UInt64(statuses.count))],
            ]
            if roll < 8 { areas = areas.mapValues { _ in .ignored } }
            if roll == 8 { areas = areas.mapValues { _ in .excluded } }
            states[f.id] = AssetOrganizationState(assetID: f.id, areas: areas, isUncertain: roll % 11 == 0)
        }
        return states
    }

    /// What `AppModel.bucketMembers` did before, on the main thread.
    static func before(_ bucket: InboxBucket, facts: [AssetFacts], states: [AssetID: AssetOrganizationState]) -> [AssetID] {
        facts.filter { f in
            guard let state = states[f.id] else { return bucket == .all }
            return resolver.buckets(state).contains(bucket)
        }
        .sorted { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
        .map(\.id)
    }

    @Test func sameAreasAsBefore() throws {
        let facts = SearchPerformanceTests.library(count: 3_000)
        let states = Self.states(for: facts)
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: states, resolver: Self.resolver))
        for bucket in InboxBucket.allCases {
            #expect(buckets[bucket].map(\.id) == Self.before(bucket, facts: facts, states: states), "\(bucket)")
        }
        #expect(buckets[.all].count == facts.count)
        #expect(!buckets[.ignored].isEmpty && !buckets[.unorganized].isEmpty && !buckets[.organized].isEmpty)
        #expect(buckets[.all].first?.date == facts.compactMap(\.asset.creationDate).max())
    }

    /// Ignoring and bringing back photos moves only those photos, to the same places a new
    /// pass gives them.
    @Test func updatingGivesWhatANewPassGives() throws {
        let facts = SearchPerformanceTests.library(count: 2_000)
        let old = Self.states(for: facts)
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: old, resolver: Self.resolver))
        var new = old
        var changed: [AssetID] = []
        var generator = SplitMix(seed: 99)
        for f in facts where generator.next() % 20 == 0 {
            changed.append(f.id)
            guard var state = new[f.id] else {
                new[f.id] = AssetOrganizationState(assetID: f.id, areas: [.places: .ignored])
                continue
            }
            let ignored = state.areas.values.contains(.ignored)
            state.areas = state.areas.mapValues { _ in ignored ? .organized : .ignored }
            new[f.id] = state
        }
        // Ids that do not change, or are no photo at all, change nothing.
        changed += [facts[0].id, "no-such-photo"]
        let updated = buckets.updating(changed, to: new, resolver: Self.resolver)
        #expect(updated == LibraryBuckets.make(facts: facts, states: new, resolver: Self.resolver))
        #expect(updated != buckets)
        #expect(buckets.updating([], to: new, resolver: Self.resolver) == buckets)
    }

    /// A tap or two move by binary search (the many-photo test above merges): the same result.
    @Test func aFewPhotosMovedOneByOneGiveWhatANewPassGives() throws {
        let facts = SearchPerformanceTests.library(count: 1_000)
        let old = Self.states(for: facts)
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: old, resolver: Self.resolver))
        var new = old
        let tapped = [facts[10].id, facts[500].id, facts[999].id]
        for id in tapped {
            let ignored = new[id]?.areas.values.contains(.ignored) ?? false
            new[id] = AssetOrganizationState(assetID: id, areas: [.places: ignored ? .organized : .ignored, .trips: ignored ? .proposed : .ignored])
        }
        #expect(buckets.updating(tapped, to: new, resolver: Self.resolver) == LibraryBuckets.make(facts: facts, states: new, resolver: Self.resolver))
    }

    /// Areas made from states older than the app's (a pass still on its way when the photo was
    /// tapped): the photo leaves the area it is really in, never stays in two (second review 5).
    @Test func areasFromOlderStatesNeverKeepAPhotoTwice() throws {
        let facts = SearchPerformanceTests.library(count: 500)
        let id = facts[42].id
        var made = Self.states(for: facts)
        made[id] = AssetOrganizationState(assetID: id, areas: [.places: .organized, .trips: .organized])
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: made, resolver: Self.resolver))
        // Meanwhile the count put the photo among the unsorted ones; the areas do not know yet.
        var newer = made
        newer[id] = AssetOrganizationState(assetID: id, areas: [.places: .unorganized, .trips: .unorganized])
        // Then it is ignored.
        var tapped = newer
        tapped[id] = AssetOrganizationState(assetID: id, areas: [.places: .ignored, .trips: .ignored])
        let updated = buckets.updating([id], to: tapped, resolver: Self.resolver)
        let expected = Self.resolver.buckets(tapped[id]!)
        for bucket in InboxBucket.allCases {
            #expect(updated[bucket].contains { $0.id == id } == expected.contains(bucket), "\(bucket)")
        }
    }

    @Test func stopsEarlyWhenNewerInputIsOnItsWay() {
        let facts = SearchPerformanceTests.library(count: 12_000)
        var asked = 0
        let result = LibraryBuckets.make(facts: facts, states: [:], resolver: Self.resolver) {
            asked += 1
            return asked > 2
        }
        #expect(result == nil)
    }

    /// 50,000 photos: one pass off the main thread, and one tap moves its photos in a moment.
    /// Linux debug build here; the app's release build is faster. Before, the same work ran in
    /// the view's body on the main thread (1.6 s measured there, the stall 7.7 s).
    @Test func fiftyThousandPhotos() throws {
        let facts = SearchPerformanceTests.library(count: 50_000)
        let states = Self.states(for: facts)
        let clock = ContinuousClock()
        var buckets: LibraryBuckets?
        let make = clock.measure { buckets = LibraryBuckets.make(facts: facts, states: states, resolver: Self.resolver) }
        let made = try #require(buckets)
        let tapped = Array(made[.unorganized].prefix(2).map(\.id))
        var new = states
        for id in tapped { new[id]?.areas = states[id]!.areas.mapValues { _ in .ignored } }
        var updated = made
        let tap = clock.measure { updated = made.updating(tapped, to: new, resolver: Self.resolver) }
        // The former code on the main thread, for one area (it ran for each area shown).
        let former = clock.measure { _ = Self.before(.unorganized, facts: facts, states: states) }
        print("LIBRARY_BUCKETS 50000 make \(make) (all areas, off the main thread), ignore tap \(tap); before: \(former) for one area on the main thread")
        #expect(updated[.ignored].count == made[.ignored].count + 2)
        #expect(make < .seconds(5))
        #expect(tap < .milliseconds(500))
    }
}
