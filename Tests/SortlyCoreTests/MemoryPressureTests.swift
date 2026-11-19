import Foundation
import Testing
import SortlyCore
import SortlyTestSupport

/// Memory warnings (review 18.11., P4-06): on a library of 50,000 to 100,000 photos iOS ends an
/// app that keeps every copy it made while memory is short. On a warning the caches that can be
/// made again go; the facts, the states, the suggestions and the decisions stay.
@MainActor
@Suite("Memory warnings")
struct MemoryPressureTests {
    /// Stands for `AppModel`: state that must stay, and a cache made from it on first use.
    final class Owner {
        var facts = ["a", "b", "c"]
        var decisions = ["s1": "accepted"]
        private(set) var builds = 0
        private var indexCache: [String: Int]?
        var cacheIsEmpty: Bool { indexCache == nil }

        var index: [String: Int] {
            if let indexCache { return indexCache }
            builds += 1
            let made = Dictionary(uniqueKeysWithValues: facts.enumerated().map { ($1, $0) })
            indexCache = made
            return made
        }

        func dropCaches() { indexCache = nil }
    }

    @Test func aWarningEmptiesARegisteredCacheAndLeavesTheStateAlone() {
        let pressure = MemoryPressure()
        let owner = Owner()
        let before = owner.index
        pressure.register("facts by id", owner: owner) { $0.dropCaches() }

        let emptied = pressure.warning()

        #expect(emptied == ["facts by id"])
        #expect(owner.cacheIsEmpty, "the cache was kept through the memory warning")
        #expect(owner.facts == ["a", "b", "c"] && owner.decisions == ["s1": "accepted"], "state was touched")
        // Made again on its next use, from the state that stayed.
        #expect(owner.index == before)
        #expect(owner.builds == 2)
    }

    @Test func aCacheWhoseOwnerIsGoneIsForgotten() {
        let pressure = MemoryPressure()
        let kept = Owner()
        _ = kept.index
        do {
            let gone = Owner()
            pressure.register("gone", owner: gone) { $0.dropCaches() }
        }
        pressure.register("kept", owner: kept) { $0.dropCaches() }

        #expect(pressure.warning() == ["kept"])
        #expect(kept.cacheIsEmpty)
        #expect(pressure.warning() == ["kept"], "a cache whose owner is gone was asked again")
    }

    @Test func theDiagnosticLineHasCountsAndNamesOfCachesOnly() {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let line = MemoryPressure.line(at: date, analysisRunning: true, onScreen: false, availableMB: 212,
                                       emptied: ["thumbnails", "search index"])
        #expect(line == "2026-11-18T11:06:40Z, analysis running true, on screen false, available 212 MB, emptied thumbnails, search index")
        let unknown = MemoryPressure.line(at: date, analysisRunning: false, onScreen: true, availableMB: nil, emptied: [])
        #expect(unknown == "2026-11-18T11:06:40Z, analysis running false, on screen true, available ? MB, emptied nothing")
    }

    /// The App: an observer for iOS's warning empties the caches and notes the warning; the
    /// model's purge drops only caches that are made again on their next use, never state.
    @Test func theAppEmptiesItsCachesOnAWarningAndNeverItsState() throws {
        let app = try AppSource.read("App/Sortly/App/SortlyApp.swift")
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        let thumbnails = try AppSource.read("App/Sortly/Views/AssetThumbnail.swift")

        let appCode = AppSource.code(app)
        let observed = appCode.contains("UIApplication.didReceiveMemoryWarningNotification")
        #expect(observed, "no observer for iOS's memory warning")
        #expect(!AppSource.calls(of: "memoryWarning(", in: appCode).isEmpty, "the observer does not reach the model")

        let warning = AppSource.code(AppSource.body(of: "func memoryWarning(", in: model) ?? "")
        #expect(!AppSource.calls(of: "MemoryPressure.shared.warning(", in: warning).isEmpty, "the warning empties nothing")
        #expect(!AppSource.calls(of: "BackgroundRunLog.memoryWarning(", in: warning).isEmpty, "the warning is not in the diagnostic report")

        let modelRegisters = AppSource.code(model).contains("MemoryPressure.shared.register(")
        #expect(modelRegisters, "the model's caches are not registered")
        let thumbnailsRegister = AppSource.code(thumbnails).contains("MemoryPressure.shared.register(")
        #expect(thumbnailsRegister, "the thumbnails are not registered")

        let purge = AppSource.code(AppSource.body(of: "func dropCaches(", in: model) ?? "")
        for cache in ["searchIndexCache = nil", "factsIndex = nil", "datesCache = nil", "atlasCache = [:]", "countryCache = [:]"] {
            #expect(purge.contains(cache), "\(cache) is kept through a memory warning")
        }
        // State, and what a running search or analysis waits for, is never dropped.
        let state = ["facts", "states", "snapshot", "decisions", "userTitles", "inventory", "removedFromProposals",
                     "managedAlbums", "history", "statesIfNotIgnored", "ignoredIDs", "searchIndexTask", "libraryBucketsTask"]
        for name in state {
            let assigned = purge.range(of: "\\b\(name)\\s*(=(?!=)|\\[|\\.remove)", options: .regularExpression) != nil
            #expect(!assigned, "a memory warning changes \(name)")
        }
    }
}
