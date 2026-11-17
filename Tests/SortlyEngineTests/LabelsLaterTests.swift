import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
@testable import SortlyCore
@testable import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// "Themen" or "Dokumente" turned on after the photos were analysed: image labels are asked
/// for only while one of them is on, and photos used to be marked analysed either way. So the
/// photos analysed before never got labels: search ("Hund", "Rechnung") and both areas missed
/// them until "Analyse neu aufbauen". Now the store records which photos have labels
/// (`labels_version`), and the next run gives exactly the photos without them their labels:
/// a look that asks for nothing else, merged into the earlier result, no text read again.
@Suite("Labels turned on later")
struct LabelsLaterTests {
    static let map: OfflineWorldMap = PipelineTests.map

    /// Labels from the id: every third photo a receipt, the others a dog. Records each request.
    final class Analyzer: ContentAnalyzing, @unchecked Sendable {
        let requests = Mutex<[(AssetID, ContentAnalysisRequest)]>([])
        let textCalls = Mutex<[AssetID]>([])
        let unreadable = Mutex<Set<AssetID>>([])
        let delay: Duration
        init(delay: Duration = .zero) { self.delay = delay }

        static func isReceipt(_ id: AssetID) -> Bool { (Int(id.rawValue.suffix(2)) ?? 0) % 3 == 0 }

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            requests.withLock { $0.append((asset.id, request)) }
            if delay > .zero { try await Task.sleep(for: delay) } else { await Task.yield() }
            if unreadable.withLock({ $0.contains(asset.id) }) { throw AnalysisError.unreadable }
            let labels = !request.classify ? []
                : Self.isReceipt(asset.id) ? [LabelScore("receipt", 0.9, isPrecise: true)] : [LabelScore("dog", 0.9, isPrecise: true)]
            // Only a full look has a feature print (the labels-only look asks for none).
            return ContentAnalysis(labels: labels, featurePrint: request.featurePrint ? Embedding([0.5, 0.5]) : nil,
                                   source: .localPreview, aestheticsScore: 0.25, isUtility: asset.isScreenshotLike)
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            textCalls.withLock { $0.append(asset.id) }
            return TextAnalysis(text: "Rechnung Nr. 4711 Gesamtbetrag 12,50 EUR", source: .original)
        }

        var full: Int { requests.withLock { $0.filter { $0.1.featurePrint }.count } }
        var labelsOnly: Int { requests.withLock { $0.filter { $0.1 == .labelsOnly }.count } }
        var classifyingRequests: Int { requests.withLock { $0.filter { $0.1.classify }.count } }
    }

    static func settings(labels: Bool, documents: Bool? = nil) -> OrganizationSettings {
        var s = OrganizationSettings()
        s.titleLanguage = .german
        s.enabledAreas.remove(.imageCategories)
        s.enabledAreas.remove(.documents)
        if labels { s.enabledAreas.insert(.imageCategories) }
        if documents ?? false { s.enabledAreas.insert(.documents) }
        return s
    }

    struct Setup {
        let store: SortlyStore
        let analyzer: Analyzer
        let pipeline: AnalysisPipeline
        let photos: [AssetID]
        let screenshots: [AssetID]
    }

    static func setup(photos count: Int = 30, screenshots shots: Int = 3, labels: Bool, store: SortlyStore? = nil,
                      delay: Duration = .zero, conditions: FakeConditions = FakeConditions()) throws -> Setup {
        var lib = LibraryBuilder()
        var photos: [AssetID] = []
        for i in 0..<count {
            photos.append(lib.photo(at: Fixture.date("2026-03-01 10:00").addingTimeInterval(Double(i) * 7_200), Fixture.Places.munichHome))
        }
        var screenshots: [AssetID] = []
        for i in 0..<shots {
            screenshots.append(lib.photo(at: Fixture.date("2026-02-01 20:00").addingTimeInterval(Double(i) * 3_600), nil, subtypes: .screenshot))
        }
        let store = try store ?? SortlyStore(url: nil)
        let analyzer = Analyzer(delay: delay)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer, geocoder: FakeGeocoder(), map: map,
            conditions: conditions, settings: settings(labels: labels), calendar: Fixture.calendar, time: ManualTime().source, batchSize: 7
        )
        return Setup(store: store, analyzer: analyzer, pipeline: pipeline, photos: photos, screenshots: screenshots)
    }

    /// The content step's reports of one run, in order.
    final class Recorder: @unchecked Sendable {
        let content = Mutex<[(completed: Int, total: Int)]>([])
        let overall = Mutex<[Double]>([])
        var onProgress: @Sendable (AnalysisPipeline.Progress) -> Void {
            { p in
                if p.stage == .content { self.content.withLock { $0.append((p.completed, p.total)) } }
                self.overall.withLock { $0.append(AnalysisPipeline.Progress.overall(stage: p.stage, completed: p.completed, total: p.total)) }
            }
        }
        func expectMonotonic(_ comment: Comment? = nil) {
            let content = content.withLock { $0 }
            for (a, b) in zip(content, content.dropFirst()) {
                #expect(b.completed >= a.completed, comment)
                #expect(b.total >= a.total, comment)
            }
            for c in content { #expect(c.completed <= c.total, comment) }
            let overall = overall.withLock { $0 }
            for (a, b) in zip(overall, overall.dropFirst()) { #expect(b >= a - 1e-9, comment) }
        }
    }

    static func dogSearch(_ pipeline: AnalysisPipeline) async throws -> Set<AssetID> {
        Set(SearchIndex(facts: try await pipeline.currentFacts()).search("Hund").ids)
    }

    @Test func turnedOnLaterTheOlderPhotosGetLabelsOnlyOnce() async throws {
        let s = try Self.setup(labels: false)
        let first = try await s.pipeline.run()
        #expect(first.isComplete)
        let all = s.photos.count + s.screenshots.count
        #expect(s.analyzer.full == all)
        #expect(s.analyzer.classifyingRequests == 0)
        #expect(try await Self.dogSearch(s.pipeline).isEmpty)
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == 0 })
        let textBefore = s.analyzer.textCalls.withLock { $0 }
        #expect(Set(textBefore) == Set(s.screenshots))
        let before = try await s.store.results(ContentAnalysis.self, kind: "content")

        // "Themen" on.
        let on = Self.settings(labels: true)
        #expect(AnalysisPipeline.settingsChangeNeedsRun(from: Self.settings(labels: false), to: on))
        await s.pipeline.update(settings: on)
        let recorder = Recorder()
        let second = try await s.pipeline.run(onProgress: recorder.onProgress)
        #expect(second.isComplete)
        // Each photo once, labels only: no second full look.
        #expect(s.analyzer.full == all)
        #expect(s.analyzer.labelsOnly == all)
        #expect(second.labelsAdded == all)
        #expect(second.contentAnalyzed == all)
        // No text read again: only the photos the labels show to be documents are read, once.
        let textAfter = s.analyzer.textCalls.withLock { $0 }
        let newlyRead = Array(textAfter.dropFirst(textBefore.count))
        #expect(Array(textAfter.prefix(textBefore.count)) == textBefore)
        #expect(Set(newlyRead) == Set(s.photos.filter(Analyzer.isReceipt)))
        #expect(newlyRead.count == Set(newlyRead).count)
        // The labels are added, everything else of the earlier result stays.
        let after = try await s.store.results(ContentAnalysis.self, kind: "content")
        for id in s.photos {
            let old = try #require(before[id]), new = try #require(after[id])
            #expect(!new.labels.isEmpty)
            #expect(new.featurePrint == old.featurePrint && new.featurePrint != nil)
            #expect(new.aestheticsScore == old.aestheticsScore)
            #expect(new.failedAttempts == nil)
        }
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
        let dogs = Set((s.photos + s.screenshots).filter { !Analyzer.isReceipt($0) })
        let foundDogs = try await Self.dogSearch(s.pipeline)
        #expect(foundDogs == dogs, "\(foundDogs.subtracting(dogs).sorted()) \(dogs.subtracting(foundDogs).sorted())")
        // The count: one photo each, never back, ends at its total.
        recorder.expectMonotonic()
        let content = recorder.content.withLock { $0 }
        #expect(content.first?.completed == 0)
        #expect(content.first?.total == all)
        #expect(content.last.map { $0.completed == $0.total } == true)

        // Once only: the next run looks at nothing.
        let third = try await s.pipeline.run()
        #expect(third.isComplete)
        #expect(s.analyzer.requests.withLock { $0.count } == 2 * all)
    }

    @Test func offAndOnAgainKeepsTheLabelsAndDoesNothing() async throws {
        let s = try Self.setup(labels: true)
        _ = try await s.pipeline.run()
        let all = s.photos.count + s.screenshots.count
        #expect(s.analyzer.full == all)
        #expect(s.analyzer.classifyingRequests == all)
        #expect(s.analyzer.labelsOnly == 0)
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
        let labelled = try await s.store.results(ContentAnalysis.self, kind: "content")

        // Off: the labels stay (search still finds what they say, and turning the area on again
        // costs nothing); the step has nothing to do.
        #expect(!AnalysisPipeline.settingsChangeNeedsRun(from: Self.settings(labels: true), to: Self.settings(labels: false)))
        await s.pipeline.update(settings: Self.settings(labels: false))
        let off = Recorder()
        _ = try await s.pipeline.run(onProgress: off.onProgress)
        #expect(s.analyzer.requests.withLock { $0.count } == all)
        #expect(try await s.store.results(ContentAnalysis.self, kind: "content") == labelled)
        #expect(off.content.withLock { $0.allSatisfy { $0.completed == $0.total } })

        // On again: nothing to do either.
        await s.pipeline.update(settings: Self.settings(labels: true))
        let on = Recorder()
        _ = try await s.pipeline.run(onProgress: on.onProgress)
        #expect(s.analyzer.requests.withLock { $0.count } == all)
        #expect(on.content.withLock { $0.allSatisfy { $0.completed == $0.total } })
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })

        // Off, on, off, on without a run between: still nothing.
        for labels in [false, true, false, true] { await s.pipeline.update(settings: Self.settings(labels: labels)) }
        _ = try await s.pipeline.run()
        #expect(s.analyzer.requests.withLock { $0.count } == all)
    }

    /// "Dokumente" on later: the photos get their labels, and the ones that turn out to be
    /// documents are read for the first time ("Rechnung"); screenshots read before are not.
    @Test func documentsOnLaterReadsOnlyTheNewDocuments() async throws {
        let s = try Self.setup(labels: false)
        _ = try await s.pipeline.run()
        let textBefore = s.analyzer.textCalls.withLock { $0 }
        #expect(Set(textBefore) == Set(s.screenshots))

        await s.pipeline.update(settings: Self.settings(labels: false, documents: true))
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(s.analyzer.labelsOnly == s.photos.count + s.screenshots.count)
        let textAfter = s.analyzer.textCalls.withLock { $0 }
        let newlyRead = Array(textAfter.dropFirst(textBefore.count))
        let receipts = s.photos.filter(Analyzer.isReceipt)
        #expect(!receipts.isEmpty)
        #expect(Set(newlyRead) == Set(receipts))
        #expect(newlyRead.count == receipts.count)
        let found = Set(SearchIndex(facts: try await s.pipeline.currentFacts()).search("Rechnung").ids)
        #expect(found.isSuperset(of: receipts))
    }

    /// Pause in the middle of giving labels: stops within a photo per lane, the count goes on
    /// from where it was (never back), and the rest follows in the next run.
    @Test func pausedWhileAddingLabelsGoesOnWhereItStopped() async throws {
        let s = try Self.setup(photos: 40, screenshots: 0, labels: false, delay: .milliseconds(5))
        _ = try await s.pipeline.run()
        await s.pipeline.update(settings: Self.settings(labels: true))

        let control = AnalysisRunControl()
        let first = Recorder()
        let stopAt = 12
        let progress: @Sendable (AnalysisPipeline.Progress) -> Void = { p in
            first.onProgress(p)
            if p.stage == .content, p.completed >= stopAt { control.pause() }
        }
        let clock = ContinuousClock()
        let paused = try await s.pipeline.run(control: control, onProgress: progress)
        #expect(paused.pausedBecause == .userPaused)
        first.expectMonotonic()
        let reached = try #require(first.content.withLock { $0.last })
        #expect(reached.completed >= stopAt && reached.completed < reached.total)
        #expect(try await s.store.labelsVersions().values.filter { $0 == AnalysisPipeline.labelsVersion }.count == reached.completed)

        let second = Recorder()
        let start = clock.now
        let rest = try await s.pipeline.run(onProgress: second.onProgress)
        #expect(rest.isComplete)
        #expect(clock.now - start < .seconds(10))
        second.expectMonotonic()
        let resumed = try #require(second.content.withLock { $0.first })
        #expect(resumed.completed == reached.completed)
        #expect(resumed.total == reached.total)
        // Every photo got its labels once.
        #expect(s.analyzer.labelsOnly == 40)
        #expect(s.analyzer.full == 40)
    }

    /// A photo given up as unreadable has no result to add labels to: one more full look,
    /// given up again when it still cannot be read, and not tried every run after that.
    @Test func unreadablePhotosAreNotTriedEveryRun() async throws {
        let s = try Self.setup(photos: 6, screenshots: 0, labels: false)
        let broken = s.photos[2]
        s.analyzer.unreadable.withLock { $0 = [broken] }
        // Given up after its attempts (spaced out: the stored attempt is made old each time).
        for _ in 0..<ContentAnalysis.maxFailedAttempts {
            _ = try await s.pipeline.run()
            if var failed = try await s.store.result(ContentAnalysis.self, kind: "content", asset: broken), failed.failedAttempts != nil {
                failed.lastAttempt = .distantPast
                try await s.store.saveResult(failed, kind: "content", asset: broken, version: AnalysisPipeline.contentVersion)
            }
        }
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
        await s.pipeline.update(settings: Self.settings(labels: true))
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(report.labelsAdded == 5)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion, labelsVersion: AnalysisPipeline.labelsVersion) == 0)
        let calls = s.analyzer.requests.withLock { $0.count }
        _ = try await s.pipeline.run()
        #expect(s.analyzer.requests.withLock { $0.count } == calls)
    }

    // MARK: Store

    /// An edited image loses its labels with its result; a photo whose place or date changed
    /// keeps them.
    @Test func anEditedImageNeedsItsLabelsAgain() async throws {
        let store = try SortlyStore(url: nil)
        var lib = LibraryBuilder()
        let a = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let b = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        _ = try await store.upsertAssets(lib.assets)
        try await store.saveResults([(a, ContentAnalysis(labels: [LabelScore("dog", 0.9)])), (b, ContentAnalysis(labels: [LabelScore("dog", 0.9)]))],
                                    kind: "content", version: 1, markingAnalyzed: [a, b], labelsVersion: 1)
        #expect(try await store.countNeedingAnalysis(version: 1, labelsVersion: 1) == 0)
        var edited = lib.assets
        edited[0].pixelWidth = 2000
        edited[1].location = Fixture.Places.rome
        _ = try await store.upsertAssets(edited)
        let versions = try await store.labelsVersions()
        #expect(versions[a] == 0)
        #expect(versions[b] == 1)
        #expect(try await store.assetsNeedingAnalysis(version: 1, labelsVersion: 1, limit: 10).map(\.id).sorted() == [a, b])
        // Labels not wanted: only the analysis marks count.
        #expect(try await store.countNeedingAnalysis(version: 1) == 2)
        try await store.resetAnalysis()
        #expect(try await store.labelsVersions().values.allSatisfy { $0 == 0 })
    }

    /// A database of an earlier version: a photo counts as having labels only if its stored
    /// result has some. One without (analysed while topics were off, or with nothing found)
    /// is classified once more; the migration cannot tell the two apart.
    @Test func migrationMarksOnlyPhotosWithLabels() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("albumist-labels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sortly.sqlite")

        // As the previous app version left it: analysed with topics on (labels), with topics
        // off (none), analysed without a result, a photo given up as unreadable, a new photo.
        var lib = LibraryBuilder()
        let withLabels = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let without = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        let noResult = lib.photo(at: Fixture.date("2026-03-03 10:00"), Fixture.Places.munichHome)
        let givenUp = lib.photo(at: Fixture.date("2026-03-04 10:00"), Fixture.Places.munichHome)
        let fresh = lib.photo(at: Fixture.date("2026-03-05 10:00"), Fixture.Places.munichHome)
        do {
            let store = try SortlyStore(url: url)
            _ = try await store.upsertAssets(lib.assets)
            var failed = ContentAnalysis()
            failed.failedAttempts = ContentAnalysis.maxFailedAttempts
            try await store.saveResults([
                (withLabels, ContentAnalysis(labels: [LabelScore("dog", 0.9, isPrecise: true), LabelScore("grass", 0.3)], featurePrint: Embedding([1, 0]))),
                (without, ContentAnalysis(labels: [], featurePrint: Embedding([0, 1]), aestheticsScore: 0.5)),
                (givenUp, failed),
            ], kind: "content", version: AnalysisPipeline.contentVersion, markingAnalyzed: [withLabels, without, noResult, givenUp])
        }
        do {
            // Back to schema 4.
            let old = try SQLiteDatabase(path: url.path)
            try old.execute("DROP INDEX idx_assets_labels")
            try old.execute("ALTER TABLE assets DROP COLUMN labels_version")
            try old.setUserVersion(4)
        }
        let store = try SortlyStore(url: url)
        #expect(await store.schemaVersion == 5)
        let versions = try await store.labelsVersions()
        #expect(versions == [withLabels: 1, without: 0, noResult: 0, givenUp: 0, fresh: 0])
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 1)
        #expect(try await store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion, labelsVersion: AnalysisPipeline.labelsVersion) == 4)
        // Reopening migrates nothing again.
        let reopened = try SortlyStore(url: url)
        #expect(try await reopened.labelsVersions() == versions)

        // The next run with topics on: labels for the one without (its result kept), a full
        // look for the new photo, the one without a result and the one given up; nothing for
        // the one with labels.
        let analyzer = Analyzer()
        let pipeline = AnalysisPipeline(
            store: reopened, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer, geocoder: FakeGeocoder(), map: Self.map,
            conditions: FakeConditions(), settings: Self.settings(labels: true), calendar: Fixture.calendar, time: ManualTime().source
        )
        let report = try await pipeline.run()
        #expect(report.isComplete)
        let requests = analyzer.requests.withLock { Dictionary($0.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a }) }
        #expect(requests[withLabels] == nil)
        #expect(requests[without] == .labelsOnly)
        #expect(requests[noResult]?.featurePrint == true && requests[noResult]?.classify == true)
        #expect(requests[givenUp]?.featurePrint == true && requests[givenUp]?.classify == true)
        #expect(requests[fresh]?.featurePrint == true && requests[fresh]?.classify == true)
        let kept = try #require(try await reopened.result(ContentAnalysis.self, kind: "content", asset: without))
        #expect(kept.featurePrint == Embedding([0, 1]) && kept.aestheticsScore == 0.5 && !kept.labels.isEmpty)
        #expect(try await reopened.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
    }
}
