import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Review P4-07: "Pause in unter 1 Sekunde" held for the card, not for the work. The card said
/// "Wird angehalten" at once, but the run asked for the Pause only before each photo and between
/// steps: the photos in work were finished first (an iCloud original up to 180 s), and the
/// trips step and the suggestions (3.5 to 7.8 s over 50,000 to 100,000 photos) were never
/// interrupted. Counted here is the work done after the Pause, not the time it takes.
@Suite("Pause stops the work, not only the card")
struct PauseStopsWorkTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    /// Analyses that wait at a gate until the test opens it (or until they are cancelled, like
    /// the app's image requests). Every analysis that ends normally is counted.
    final class GatedAnalyzer: ContentAnalyzing, @unchecked Sendable {
        let gateContent: Bool
        let gateText: Bool
        let open = Mutex(false)
        /// Analyses begun and analyses that ran to their end.
        let counts = Mutex<(started: Int, finished: Int)>((0, 0))

        init(gateContent: Bool = false, gateText: Bool = false) {
            self.gateContent = gateContent
            self.gateText = gateText
        }

        private func pass(_ gated: Bool) async throws {
            guard gated else { return }
            counts.withLock { $0.started += 1 }
            while !open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
            counts.withLock { $0.finished += 1 }
        }

        func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
            try await pass(gateContent)
            return ContentAnalysis(labels: [], source: .localPreview)
        }

        func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
            try await pass(gateText)
            return TextAnalysis(text: "Ihre Bestellung Bestellnummer 302-1234567", source: .original)
        }
    }

    /// A home, a week in Rome and a few screenshots (trips, places, image and text steps).
    func pipeline(analyzer: any ContentAnalyzing = FakeContentAnalyzer()) throws -> (SortlyStore, AnalysisPipeline) {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for day in 1...5 { lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot) }
        let store = try SortlyStore(url: nil)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: analyzer,
            geocoder: FakeGeocoder(), map: Self.map, conditions: FakeConditions(), settings: OrganizationSettings(),
            calendar: Fixture.calendar, time: ManualTime().source, batchSize: 10, earlyGraceOnStop: .seconds(60)
        )
        return (store, pipeline)
    }

    /// Pause while the trips are detected: no later step begins (before, the places step ran
    /// and the run asked for the Pause only after it).
    @Test func pauseInTheTripsStepBeginsNoLaterStep() async throws {
        let (_, pipeline) = try pipeline()
        let control = AnalysisRunControl()
        let afterPause = Mutex<[AnalysisPipeline.Stage]>([])
        let report = try await pipeline.run(control: control) { progress in
            if control.isPaused {
                afterPause.withLock { $0.append(progress.stage) }
            } else if progress.stage == .patterns, progress.total > 0 {
                control.pause()
            }
        }
        #expect(control.isPaused, "the trips step said no count")
        #expect(report.pausedBecause == .userPaused)
        #expect(report.completedStages == [.inventory])
        let later = afterPause.withLock { $0 }.filter { $0 != .patterns }
        #expect(later.isEmpty, "steps begun after the Pause: \(later)")
    }

    /// Pause while the suggestions are made (the facts of every photo, then the suggestions,
    /// then the matching, each off the actor): none of that work begins after the Pause, and
    /// nothing is saved.
    @Test func pauseWhileTheSuggestionsAreMadeBeginsNoMoreOfTheirWork() async throws {
        let (_, pipeline) = try pipeline()
        let control = AnalysisRunControl()
        let inProposals = Mutex(false)
        let begunAfterPause = Mutex(0)
        await pipeline.setOffActorProbe {
            guard inProposals.withLock({ $0 }) else { return }
            if control.isPaused { begunAfterPause.withLock { $0 += 1 } } else { control.pause() }
        }
        let report = try await pipeline.run(control: control) { progress in
            if progress.stage == .proposals { inProposals.withLock { $0 = true } }
        }
        #expect(control.isPaused, "the suggestions did no work off the actor")
        #expect(begunAfterPause.withLock { $0 } == 0, "work of the suggestions begun after the Pause")
        #expect(report.pausedBecause == .userPaused)
        #expect(!report.completedStages.contains(.proposals))
        #expect(try await pipeline.latestProposals()?.isEarly != false, "the full set was saved after the Pause")
    }

    /// Runs `pipeline` with `control`, pauses once the analyzer has begun its first gated
    /// analysis, waits up to `grace` for the run to end, then opens the gate. `grace` is only a
    /// fallback for the old behaviour (the run waited for the gate); a run that cancels its
    /// photos ends long before it, also on a busy test machine.
    func runAndPauseInWork(_ pipeline: AnalysisPipeline, _ analyzer: GatedAnalyzer,
                           grace: Duration = .seconds(10)) async throws -> AnalysisPipeline.Report {
        let control = AnalysisRunControl()
        let ended = Mutex(false)
        let run = Task {
            defer { ended.withLock { $0 = true } }
            return try await pipeline.run(control: control)
        }
        let clock = ContinuousClock()
        // No deadline: a run that never reaches the gate ends by itself.
        while analyzer.counts.withLock({ $0.started }) == 0, !ended.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(analyzer.counts.withLock { $0.started } > 0, "no analysis began")
        control.pause()
        // Only a fallback: the run that waits for the photos in work ends when the gate opens.
        let deadline = clock.now + grace
        while !ended.withLock({ $0 }), clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        analyzer.open.withLock { $0 = true }
        return try await run.value
    }

    /// Pause while photos are in the image step: they are cancelled, not finished first.
    @Test func pauseCancelsThePhotosInWork() async throws {
        let analyzer = GatedAnalyzer(gateContent: true)
        let (_, pipeline) = try pipeline(analyzer: analyzer)
        let report = try await runAndPauseInWork(pipeline, analyzer)
        #expect(report.pausedBecause == .userPaused)
        #expect(analyzer.counts.withLock { $0.finished } == 0, "photos finished after the Pause")
        #expect(report.contentAnalyzed == 0)
    }

    /// Pause while a text is read (an iCloud original can take minutes): the read is cancelled.
    @Test func pauseCancelsTheTextReadsInWork() async throws {
        let analyzer = GatedAnalyzer(gateText: true)
        let (_, pipeline) = try pipeline(analyzer: analyzer)
        let report = try await runAndPauseInWork(pipeline, analyzer)
        #expect(report.pausedBecause == .userPaused)
        #expect(analyzer.counts.withLock { $0.finished } == 0, "texts finished after the Pause")
        #expect(report.textRecognized == 0)
    }
}
