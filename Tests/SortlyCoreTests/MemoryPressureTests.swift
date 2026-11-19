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

    /// Second review: a cache registered while the caches are emptied was lost (`caches = alive`).
    @Test func aCacheRegisteredWhileTheCachesAreEmptiedIsKept() {
        let pressure = MemoryPressure()
        let first = Owner(), late = Owner()
        _ = late.index
        pressure.register("first", owner: first) { _ in
            pressure.register("late", owner: late) { $0.dropCaches() }
        }
        #expect(pressure.warning() == ["first"])
        let second = pressure.warning()
        #expect(second.contains("late"), "a cache registered during a warning was lost")
        #expect(late.cacheIsEmpty)
    }

    /// Second review: the report counted every warning since the app was installed.
    @Test func theCountIsThisLaunchsWarnings() {
        let pressure = MemoryPressure()
        #expect(pressure.warnings == 0)
        pressure.warning()
        pressure.warning()
        #expect(pressure.warnings == 2)
    }

    /// Second review: after a warning, a swipe in the photo view looked up one photo and made the
    /// index for all photos again. Without the index each lookup searches for its one photo.
    @Test func aLookupWithoutTheIndexFindsTheOnePhotoLikeTheIndex() {
        func facts(_ id: String, trip: String) -> AssetFacts {
            AssetFacts(asset: AssetSnapshot(id: AssetID(id), creationDate: Fixture.date("2024-05-01")), tripID: SortlyID(trip))
        }
        let all = [facts("p1", trip: "t1"), facts("p2", trip: "t2"), facts("p1", trip: "t3")]
        let index = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let indexed = FactsLookup(index: index), searched = FactsLookup(facts: all)
        for id in [AssetID("p1"), AssetID("p2"), AssetID("p9")] {
            #expect(searched[id] == indexed[id], "\(id.rawValue) differs without the index")
        }
        #expect(searched[AssetID("p1")]?.tripID == SortlyID("t1"))
        #expect(indexed[AssetID("p2")]?.tripID == SortlyID("t2"))
        #expect(searched[AssetID("p9")] == nil)
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
        for cache in ["searchIndexCache = nil", "factsIndex = nil", "datesCache = nil", "countryCache = [:]"] {
            #expect(purge.contains(cache), "\(cache) is kept through a memory warning")
        }
        // Released off the main thread (second review, 4).
        #expect(!AppSource.calls(of: "Task.detached(", in: purge).isEmpty, "the dropped caches are freed on the main thread")
        // State, and what a running search or analysis waits for, is never dropped. Neither are
        // the library's areas (a few MB; the grid would lose its place under the photo view) nor
        // the atlas (a few KB, 100 to 250 ms to make again on the main thread): second review, 1-2.
        let state = ["facts", "states", "snapshot", "decisions", "userTitles", "inventory", "removedFromProposals",
                     "managedAlbums", "history", "statesIfNotIgnored", "ignoredIDs", "searchIndexTask", "libraryBucketsTask",
                     "libraryBuckets", "libraryBucketsMadeFor", "atlasCache"]
        for name in state {
            let assigned = purge.range(of: "\\b\(name)\\s*(=(?!=)|\\[|\\.remove)", options: .regularExpression) != nil
            #expect(!assigned, "a memory warning changes \(name)")
        }
    }

    /// Second review, 3, 6 and 7: the photo view's lookups never make the whole index again
    /// while it is dropped; the previews loaded ahead for the analysis and the thumbnails'
    /// image manager let go of their images; the report says this launch's warnings.
    @Test func theAppLooksUpSinglePhotosAndLetsGoOfLoadedImages() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        let thumbnails = AppSource.code(try AppSource.read("App/Sortly/Views/AssetThumbnail.swift"))
        let analyzer = try AppSource.read("App/Sortly/Platform/VisionAnalyzer.swift")
        let log = try AppSource.read("App/Sortly/Platform/BackgroundRunLog.swift")

        let lookup = AppSource.code(AppSource.body(of: "var factsByID: FactsLookup", in: model) ?? "")
        let searchesWhileDropped = lookup.contains("factsIndexDropped") && lookup.contains("FactsLookup(facts:")
        #expect(searchesWhileDropped, "a lookup after a warning makes the index for all photos again")
        let purge = AppSource.code(AppSource.body(of: "func dropCaches(", in: model) ?? "")
        let marksDropped = purge.contains("factsIndexDropped = true")
        #expect(marksDropped, "the lookups do not know the index was dropped")

        let register = AppSource.code(AppSource.body(of: "func registerForMemoryWarnings(", in: analyzer) ?? "")
        let previews = register.contains("MemoryPressure.shared.register(") && register.contains("stopCachingImagesForAllAssets()")
            && !AppSource.calls(of: "PreviewCache.registerForMemoryWarnings(", in: AppSource.code(model)).isEmpty
        #expect(previews, "the previews loaded ahead for the analysis are kept through a warning")
        let thumbnailManager = thumbnails.contains("manager.value.stopCachingImagesForAllAssets()")
        #expect(thumbnailManager, "the thumbnails' image manager keeps its images")

        let perLaunch = AppSource.code(log, keepStrings: true).contains("memory warnings this launch")
        #expect(perLaunch, "the report does not say this launch's count")
        let sinceInstall = AppSource.code(log).contains("memoryWarnings")
        #expect(!sinceInstall, "the report keeps a count since the app was installed")
    }
}
