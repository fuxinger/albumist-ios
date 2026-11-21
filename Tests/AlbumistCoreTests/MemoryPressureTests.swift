import Foundation
import Testing
import AlbumistCore
import AlbumistTestSupport

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

    /// The App's facts by id (review P4-09): an index per photo into the facts, made off the main
    /// thread with them and handed over by the refresh, never made on the main thread at a lookup
    /// (before: a dictionary of all facts at the first lookup after every refresh and after every
    /// warning, 97 ms at 50,000 photos). It is no second copy of the facts any more (review
    /// P4-06), so a warning keeps it: dropped, the next lookup would have to make it on the main
    /// thread again or find nothing. Its lookups (first photo of an id wins) are tested with the
    /// engine (`DerivedRefreshTests.factsByIDKeepsTheFirstPhotoOfAnID`).
    @Test func theAppKeepsTheFactsIndexHandedOverWithTheFacts() throws {
        let model = AppSource.code(try AppSource.read("App/Albumist/Model/AppModel.swift"))
        let lookup = AppSource.body(of: "var factsByID: FactsByID", in: model) ?? ""
        #expect(!lookup.isEmpty, "no facts by id")
        let handedOver = lookup.contains("return factsIndex ?? FactsByID()")
        #expect(handedOver, "the lookup does not use the index handed over with the facts")
        let madeHere = lookup.contains("Dictionary(") || lookup.contains("FactsByID(facts")
        #expect(!madeHere, "the lookup makes the index on the main thread")
        let purge = AppSource.body(of: "func dropCaches(", in: model) ?? ""
        let dropped = purge.contains("factsIndex = nil")
        #expect(!dropped, "a memory warning drops the facts index: the next lookup finds nothing")
        let refresh = AppSource.body(of: "func refreshDerived(", in: model) ?? ""
        #expect(refresh.contains("factsIndex = derived.factsByID"), "the refresh does not hand over the facts index")
        let searches = model.contains("factsIndexDropped") || model.contains("facts.first(where:")
        #expect(!searches, "lookups are a search through all photos")
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
        let app = try AppSource.read("App/Albumist/App/AlbumistApp.swift")
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        let thumbnails = try AppSource.read("App/Albumist/Views/AssetThumbnail.swift")

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
        for cache in ["searchIndexStore.dropCache()", "datesCache = nil", "countryCache = [:]"] {
            #expect(purge.contains(cache), "\(cache) is kept through a memory warning")
        }
        // Released off the main thread (second review, 4).
        #expect(!AppSource.calls(of: "Task.detached(", in: purge).isEmpty, "the dropped caches are freed on the main thread")
        // State, and what a running search or analysis waits for, is never dropped. Neither are
        // the library's areas (a few MB; the grid would lose its place under the photo view) nor
        // the atlas (a few KB, 100 to 250 ms to make again on the main thread): second review, 1-2.
        // Nor the facts by id: an index per photo now, made only with the facts (review P4-09).
        let state = ["facts", "states", "snapshot", "decisions", "userTitles", "inventory", "removedFromProposals",
                     "managedAlbums", "history", "statesIfNotIgnored", "ignoredIDs", "libraryBucketsTask",
                     "libraryBuckets", "libraryBucketsMadeFor", "atlasCache", "factsIndex"]
        for name in state {
            let assigned = purge.range(of: "\\b\(name)\\s*(=(?!=)|\\[|\\.remove)", options: .regularExpression) != nil
            #expect(!assigned, "a memory warning changes \(name)")
        }
        // A search index still being built is left to finish (`SearchIndexStore.dropCache`).
        #expect(AppSource.calls(of: "searchIndexStore.invalidate(", in: purge).isEmpty, "a memory warning stops the index being built")
    }

    /// Second review, 6 and 7: the previews loaded ahead for the analysis and the thumbnails'
    /// image manager let go of their images; the report says this launch's warnings.
    @Test func theAppLetsGoOfLoadedImagesAndSaysThisLaunchsWarnings() throws {
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        let thumbnails = AppSource.code(try AppSource.read("App/Albumist/Views/AssetThumbnail.swift"))
        let analyzer = try AppSource.read("App/Albumist/Platform/VisionAnalyzer.swift")
        let log = try AppSource.read("App/Albumist/Platform/BackgroundRunLog.swift")

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
