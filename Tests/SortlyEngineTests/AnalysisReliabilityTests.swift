import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Reliability of the analysis on real devices (review after the first iPhone test, 15.11.):
/// runs that overlap or lose their Pause, photos given up after a few quick catch-up runs,
/// Vision failing in the background, and a throttled geocoder holding step 3 for hours.
@Suite("Analysis reliability")
struct AnalysisReliabilityTests {
    static let map: OfflineWorldMap = PipelineTests.map

    struct Failure: Error {}

    /// Analyzer whose behaviour the test scripts per photo; it suspends on every call, so two
    /// runs on the same pipeline would interleave if nothing kept them apart.
    final class ScriptedAnalyzer: ContentAnalyzing, @unchecked Sendable {
        enum Answer { case labels, unreadable, analyzerError }
        let contentAnswer = Mutex<@Sendable (AssetSnapshot) -> Answer>({ _ in .labels })
        let textAnswer = Mutex<@Sendable (AssetSnapshot) -> Answer>({ _ in .labels })
        let contentCalls = Mutex<[AssetID]>([])
        let textCalls = Mutex<[AssetID]>([])

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            contentCalls.withLock { $0.append(asset.id) }
            await Task.yield()
            switch contentAnswer.withLock({ $0 })(asset) {
            case .labels: return ContentAnalysis(labels: [LabelScore("food", 0.7)], source: .localPreview)
            case .unreadable: throw AnalysisError.unreadable
            case .analyzerError: throw Failure()
            }
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            textCalls.withLock { $0.append(asset.id) }
            await Task.yield()
            switch textAnswer.withLock({ $0 })(asset) {
            case .labels: return TextAnalysis(text: "Ihre Bestellung Lieferung", source: .original)
            case .unreadable: throw AnalysisError.unreadable
            case .analyzerError: throw Failure()
            }
        }
    }

    final class Clock: @unchecked Sendable {
        let value = Mutex(Fixture.date("2026-07-01 12:00"))
        func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
    }

    struct Setup {
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var analyzer: ScriptedAnalyzer
        var clock: Clock
        var time: ManualTime
        var pipeline: AnalysisPipeline
        var photos: [AssetID]
        var screenshots: [AssetID]
    }

    func setup(photos: Int = 12, screenshots: Int = 0, geocoder: (any ReverseGeocoding)? = FakeGeocoder(),
               foregroundOnlineBudget: Int? = nil, batchSize: Int = 5) throws -> Setup {
        var lib = LibraryBuilder()
        var ids: [AssetID] = []
        for day in 0..<photos {
            ids.append(lib.photo(at: Fixture.date("2026-06-01 12:00").addingTimeInterval(Double(day) * 86_400), Fixture.Places.munichHome))
        }
        var shots: [AssetID] = []
        for day in 0..<screenshots {
            shots.append(lib.photo(at: Fixture.date("2026-05-01 20:00").addingTimeInterval(Double(day) * 86_400), nil, subtypes: .screenshot))
        }
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let analyzer = ScriptedAnalyzer()
        let clock = Clock()
        let time = ManualTime()
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: Self.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: time.source,
            batchSize: batchSize, foregroundOnlineBudget: foregroundOnlineBudget, now: { clock.value.withLock { $0 } }
        )
        return Setup(store: store, reader: reader, analyzer: analyzer, clock: clock, time: time, pipeline: pipeline, photos: ids, screenshots: shots)
    }

    // MARK: One run at a time, and Pause reaches the right one

    @Test func twoRunsCalledTogetherDoNotAnalyseAPhotoTwice() async throws {
        let s = try setup(photos: 30)
        async let first = s.pipeline.run()
        async let second = s.pipeline.run()
        let reports = try await [first, second]
        #expect(reports.allSatisfy { $0.isComplete })
        let calls = s.analyzer.contentCalls.withLock { $0 }
        #expect(calls.count == s.photos.count)
        #expect(Set(calls).count == calls.count)
        #expect(reports.map(\.contentAnalyzed).reduce(0, +) == s.photos.count)
    }

    @Test func pauseBeforeTheRunBeginsIsNotLost() async throws {
        let s = try setup()
        let control = AnalysisRunControl()
        // Tapped while the app was still handing the run over (it used to be cleared at the start).
        control.pause()
        let report = try await s.pipeline.run(control: control)
        #expect(report.pausedBecause == .userPaused)
        #expect(s.analyzer.contentCalls.withLock { $0 }.isEmpty)
    }

    @Test func pauseAfterARunEndedDoesNotStopTheNext() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        // A Pause that arrives late (the run had just finished) must not end "Neu prüfen".
        await s.pipeline.pause()
        await s.reader.set(assets: (await s.reader.assets) + [newPhoto(id: "late")])
        let next = try await s.pipeline.run()
        #expect(next.isComplete)
        #expect(next.contentAnalyzed == 1)
    }

    @Test func controlPausesTheRunInProgress() async throws {
        let s = try setup(photos: 30)
        let control = AnalysisRunControl()
        s.analyzer.contentAnswer.withLock { answer in
            answer = { asset in
                // The user taps Pause while the fifth photo is looked at.
                if asset.id == AssetID("asset-000026") { control.pause() }
                return .labels
            }
        }
        let report = try await s.pipeline.run(control: control)
        #expect(report.pausedBecause == .userPaused)
        #expect(report.contentAnalyzed == 5)
        // The next run goes on and leaves no photo out.
        let rest = try await s.pipeline.run()
        #expect(rest.isComplete)
        #expect(rest.contentAnalyzed == 25)
    }

    // MARK: Photos that cannot be read

    @Test func quickCatchUpRunsDoNotGiveUpAPhoto() async throws {
        let s = try setup()
        let broken = s.photos[4]
        s.analyzer.contentAnswer.withLock { answer in answer = { $0.id == broken ? .unreadable : .labels } }
        // While iCloud syncs, every change in Photos starts a run a few seconds later.
        for _ in 0..<5 {
            _ = try await s.pipeline.run()
            s.clock.advance(10)
        }
        let record = try #require(try await s.store.result(ContentAnalysis.self, kind: "content", asset: broken))
        #expect(record.failedAttempts == 1)
        #expect(s.analyzer.contentCalls.withLock { $0 }.filter { $0 == broken }.count == 1)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 1)

        // An hour later its preview has arrived: read like any other photo.
        s.analyzer.contentAnswer.withLock { answer in answer = { _ in .labels } }
        s.clock.advance(ContentAnalysis.retrySpacing)
        let later = try await s.pipeline.run()
        #expect(later.contentAnalyzed == 1)
        #expect(try await s.store.result(ContentAnalysis.self, kind: "content", asset: broken)?.failedAttempts == nil)
    }

    @Test func failingAnalyzerEndsTheRunWithoutMarkingPhotos() async throws {
        let s = try setup(photos: 20)
        // Vision fails for every photo (e.g. no graphics hardware in the background).
        s.analyzer.contentAnswer.withLock { answer in answer = { _ in .analyzerError } }
        let report = try await s.pipeline.run()
        #expect(report.pausedBecause == .timeBudget)
        #expect(report.analyzerUnavailable)
        #expect(!report.isComplete)
        // Photos already in other lanes finish, nothing more starts.
        #expect(s.analyzer.contentCalls.withLock { $0 }.count < AnalysisPipeline.analyzerFailureLimit + 4)
        // Nothing was counted against the photos.
        #expect(try await s.store.results(ContentAnalysis.self, kind: "content").isEmpty)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == s.photos.count)

        // Back in the app, Vision works again: every photo is read, none is "unreadable".
        s.analyzer.contentAnswer.withLock { answer in answer = { _ in .labels } }
        let next = try await s.pipeline.run()
        #expect(next.isComplete)
        #expect(next.contentAnalyzed == s.photos.count)
        let records = try await s.store.results(ContentAnalysis.self, kind: "content")
        #expect(records.values.allSatisfy { $0.failedAttempts == nil })
    }

    @Test func analyzerErrorOnOnePhotoCountsAgainstThatPhoto() async throws {
        let s = try setup()
        let odd = s.photos[6]
        s.analyzer.contentAnswer.withLock { answer in answer = { $0.id == odd ? .analyzerError : .labels } }
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(!report.analyzerUnavailable)
        #expect(report.contentAnalyzed == s.photos.count - 1)
        // The photos after it worked, so it was this photo: one try counted, spaced out.
        let record = try #require(try await s.store.result(ContentAnalysis.self, kind: "content", asset: odd))
        #expect(record.failedAttempts == 1)
        #expect(record.lastAttempt == s.clock.value.withLock { $0 })
    }

    @Test func storedLabelsAreNotReadAgain() async throws {
        let s = try setup()
        // The app was ended after the first photo's labels were saved, before it was marked.
        _ = try await s.store.upsertAssets(await s.reader.assets)
        try await s.store.saveResult(ContentAnalysis(labels: [LabelScore("dog", 0.9)]), kind: "content",
                                     asset: s.photos[0], version: AnalysisPipeline.contentVersion)
        let first = try await s.pipeline.run()
        #expect(first.isComplete)
        #expect(!s.analyzer.contentCalls.withLock { $0 }.contains(s.photos[0]))
        #expect(s.analyzer.contentCalls.withLock { $0 }.count == s.photos.count - 1)
        #expect(try await s.store.result(ContentAnalysis.self, kind: "content", asset: s.photos[0])?.labels.first?.identifier == "dog")

        // Only the place of one photo changed (no edit of the image): its labels stay valid.
        var assets = await s.reader.assets
        assets[3].location = Fixture.Places.tegernsee
        await s.reader.set(assets: assets)
        let reads = s.analyzer.contentCalls.withLock { $0 }.count
        let second = try await s.pipeline.run()
        #expect(second.isComplete)
        #expect(second.newOrChanged == 1)
        #expect(s.analyzer.contentCalls.withLock { $0 }.count == reads)
        #expect(try await s.store.countNeedingAnalysis(version: AnalysisPipeline.contentVersion) == 0)
    }

    // MARK: Text

    @Test func failingTextRecognitionKeepsItsRetries() async throws {
        let s = try setup(photos: 0, screenshots: 12)
        s.analyzer.textAnswer.withLock { answer in answer = { _ in .analyzerError } }
        let report = try await s.pipeline.run()
        #expect(report.analyzerUnavailable)
        #expect(report.pausedBecause == .timeBudget)
        #expect(s.analyzer.textCalls.withLock { $0 }.count < AnalysisPipeline.analyzerFailureLimit + 2)
        // No try was used up: the texts are read at the next run, not an hour later.
        #expect(try await s.store.results(TextResult.self, kind: "text").isEmpty)
        s.analyzer.textAnswer.withLock { answer in answer = { _ in .labels } }
        let next = try await s.pipeline.run()
        #expect(next.isComplete)
        #expect(next.textRecognized == s.screenshots.count)
    }

    // MARK: A throttled geocoder does not hold the run

    final class RefusingGeocoder: ReverseGeocoding, @unchecked Sendable {
        let calls = Mutex(0)
        let retryAfter: Double?
        init(retryAfter: Double? = nil) { self.retryAfter = retryAfter }
        func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
            calls.withLock { $0 += 1 }
            throw GeocodingError.rateLimited(retryAfter: retryAfter)
        }
    }

    func requests(_ places: [GeoCoordinate]) -> [PlaceResolutionService.Request] {
        places.enumerated().map { PlaceResolutionService.Request(assetID: AssetID("p\($0.offset)"), coordinate: $0.element) }
    }

    static let fivePlaces = [Fixture.Places.munichHome, Fixture.Places.rome, Fixture.Places.florence, Fixture.Places.naples, Fixture.Places.gardaLake]

    @Test func appRunWaitsForTheGeocoderOnlyBriefly() async throws {
        let time = ManualTime()
        let geocoder = RefusingGeocoder()
        let service = PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german), time: time.source
        )
        let outcome = try await service.resolve(requests(Self.fivePlaces), maxRateLimitWait: .seconds(30)) { _ in }
        // Asked once, waited once, asked again; then the rest waits for a later run.
        #expect(geocoder.calls.withLock { $0 } == 2)
        #expect(time.now.withLock { $0 } <= .seconds(31))
        #expect(outcome.stoppedBecauseThrottled)
        #expect(outcome.pendingOnline.count == Self.fivePlaces.count)
    }

    @Test func refusedLookupsStopAfterOneCellAlsoWithoutALimit() async throws {
        let time = ManualTime()
        let geocoder = RefusingGeocoder()
        let service = PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german), time: time.source
        )
        let outcome = try await service.resolve(requests(Self.fivePlaces), refining: true) { _ in }
        // Four tries for the first cell (the overnight run may wait), not four for every cell,
        // and no wait after the last one.
        #expect(geocoder.calls.withLock { $0 } == 4)
        #expect(time.now.withLock { $0 } == .seconds(30 + 60 + 120))
        #expect(outcome.stoppedBecauseThrottled)
    }

    @Test func pauseInterruptsAWaitForTheGeocoder() async throws {
        let time = ManualTime()
        let geocoder = RefusingGeocoder(retryAfter: 600)
        let service = PlaceResolutionService(
            map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
            policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german), time: time.source
        )
        let checks = Mutex(0)
        // The user taps Pause a few seconds into a ten-minute wait.
        let outcome = try await service.resolve(requests(Self.fivePlaces), shouldStop: {
            checks.withLock { $0 += 1; return $0 > 3 }
        }) { _ in }
        #expect(geocoder.calls.withLock { $0 } == 1)
        #expect(time.now.withLock { $0 } < .seconds(10))
        #expect(outcome.pendingOnline.count == Self.fivePlaces.count)
    }

    @Test func runInTheAppGoesOnWhenTheGeocoderRefuses() async throws {
        let geocoder = RefusingGeocoder()
        let s = try setup(photos: 12, geocoder: geocoder, foregroundOnlineBudget: 60)
        let report = try await s.pipeline.run()
        #expect(report.isComplete)
        #expect(report.placesThrottled)
        #expect(report.contentAnalyzed == s.photos.count)
        #expect(s.time.now.withLock { $0 } <= AnalysisPipeline.foregroundRateLimitWait + .seconds(1))
        #expect(report.placesPendingOnline > 0)
    }

    func newPhoto(id: String) -> AssetSnapshot {
        AssetSnapshot(id: AssetID(id), kind: .image, creationDate: Fixture.date("2026-08-01 10:00"),
                      location: Fixture.Places.munichHome, pixelWidth: 4032, pixelHeight: 3024)
    }
}
