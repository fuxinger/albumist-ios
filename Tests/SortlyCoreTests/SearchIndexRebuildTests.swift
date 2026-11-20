import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Review finding G4-05 (19.11.2026): a search typed while the search index was being built
/// again used the old library state once. The library changed while an index was being built;
/// the search waiting for that build got the index of the old state, and nothing searched again
/// once the new index was there. `SearchIndexStore` is what `AppModel.searchIndex()` uses.
@MainActor
@Suite("Search while the index is built again (G4-05)")
struct SearchIndexRebuildTests {
    let now = Fixture.date("2026-11-19 12:00")

    /// Holds a build until the test lets it go.
    actor Gate {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            open = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// The library as the app holds it, and every build the store started (by photo count).
    @MainActor final class Library {
        let before: [AssetFacts]
        let after: [AssetFacts]
        let rome: Set<AssetID>
        var facts: [AssetFacts]
        var builds: [Int] = []
        var gates: [Int: Gate] = [:]

        init() {
            var lib = LibraryBuilder()
            let munich = lib.daily(from: "2026-01-01", to: "2026-03-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 3, hour: 19)
            let rome = lib.daily(from: "2026-05-12", to: "2026-05-14", at: Fixture.Places.rome, perDay: 3, hour: 11)
            let all = FixtureGeocoder.facts(for: lib.assets)
            after = all
            before = all.filter { Set(munich).contains($0.id) }
            self.rome = Set(rome)
            facts = before
        }

        /// Like `AppModel.searchIndex()`: takes the facts as they are now; the build waits for
        /// the gate of its photo count, if there is one.
        func prepare() -> @Sendable () async -> SearchIndex {
            let facts = facts, gate = gates[facts.count]
            builds.append(facts.count)
            return {
                await gate?.wait()
                return SearchIndex(facts: facts, calendar: Fixture.calendar)
            }
        }

        /// The analysis brought the photos from Rome: the app invalidates the index.
        func change(_ store: SearchIndexStore) {
            facts = after
            store.invalidate()
        }

        func waitForBuilds(_ count: Int) async {
            while builds.count < count { await Task.yield() }
        }
    }

    @Test func aSearchWaitingForAnOldBuildGetsTheIndexOfTheNewState() async {
        let lib = Library(), store = SearchIndexStore(), gate = Gate()
        lib.gates[lib.before.count] = gate
        let search = Task { await store.index { lib.prepare() }.search("Rom", now: now) }
        await lib.waitForBuilds(1)
        // The library changes while the index of the old state is being built.
        lib.change(store)
        await gate.release()
        let result = await search.value
        #expect(Set(result.ids) == lib.rome, "found \(result.ids.count) photos, \(lib.rome.count) from Rome expected")
        #expect(lib.builds == [lib.before.count, lib.after.count])
    }

    @Test func searchesDuringTheRebuildShareOneBuildOfTheNewState() async {
        let lib = Library(), store = SearchIndexStore(), old = Gate(), new = Gate()
        lib.gates = [lib.before.count: old, lib.after.count: new]
        let first = Task { await store.index { lib.prepare() }.search("Rom", now: now) }
        await lib.waitForBuilds(1)
        lib.change(store)
        let second = Task { await store.index { lib.prepare() }.search("Rom", now: now) }
        await lib.waitForBuilds(2)
        // The old build ends first, the new one after it.
        await old.release()
        for _ in 0..<50 { await Task.yield() }
        await new.release()
        let (a, b) = await (first.value, second.value)
        #expect(Set(a.ids) == lib.rome, "the first search found \(a.ids.count) photos")
        #expect(Set(b.ids) == lib.rome, "the second search found \(b.ids.count) photos")
        // No third build: the first search waits for the build the second one started.
        #expect(lib.builds == [lib.before.count, lib.after.count])
    }

    @Test func withoutAChangeTheIndexIsBuiltOnce() async {
        let lib = Library(), store = SearchIndexStore()
        let first = await store.index { lib.prepare() }.search("Rom", now: now)
        let second = await store.index { lib.prepare() }.search("Rom", now: now)
        #expect(first.ids.isEmpty && second.ids.isEmpty)
        #expect(lib.builds == [lib.before.count])
        lib.change(store)
        let third = await store.index { lib.prepare() }.search("Rom", now: now)
        #expect(Set(third.ids) == lib.rome)
        #expect(lib.builds == [lib.before.count, lib.after.count])
    }

    /// A memory warning lets go of a finished index and leaves one being built to finish
    /// (`AppModel.dropCaches`, P4-06): the waiting search still gets it, the next one builds again.
    @Test func aMemoryWarningLetsGoOfTheIndexButNotOfABuild() async {
        let lib = Library(), store = SearchIndexStore(), gate = Gate()
        lib.gates[lib.before.count] = gate
        let search = Task { await store.index { lib.prepare() }.count }
        await lib.waitForBuilds(1)
        #expect(store.dropCache() == nil)
        await gate.release()
        #expect(await search.value == lib.before.count)
        #expect(lib.builds == [lib.before.count])
        #expect(store.dropCache()?.count == lib.before.count)
        _ = await store.index { lib.prepare() }
        #expect(lib.builds == [lib.before.count, lib.before.count])
    }
}
