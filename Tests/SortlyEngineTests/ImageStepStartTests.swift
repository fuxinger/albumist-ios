import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// Stress run 44116350940 (50,000 photos): "Bildinhalte werden erkannt 0 von 50.246 Fotos"
/// stood still for 13 s when the image step began, over the owner's limit of 10 s. Between the
/// report that starts the step and the first counted photo the run made the early suggestions
/// over the whole library (2.8 s on Linux over 50,000 photos, 0.25 s over 5,000: it grows with
/// the library), and the overview's refresh after them assembled the facts of every photo on the
/// pipeline's actor. The early suggestions are now made beside the first photos, and what grows
/// with the library runs off the actor: the count moves after the first photos at any size.
@Suite("Image step: the count moves at once")
struct ImageStepStartTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Setup {
        let store: SortlyStore
        let pipeline: AnalysisPipeline
        let photos: Int
    }

    /// A home, a week in Rome, screenshots: trips and places for the early suggestions.
    func setup() throws -> Setup {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1, skipping: [("2026-05-12", "2026-05-19")])
        lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        for day in 1...5 { _ = lib.photo(at: Fixture.date("2026-06-0\(day) 20:00"), nil, subtypes: .screenshot) }
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let pipeline = AnalysisPipeline(
            store: store, reader: InMemoryLibraryReader(assets: lib.assets), analyzer: FakeContentAnalyzer(),
            geocoder: FakeGeocoder(), map: Self.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source, batchSize: 10
        )
        return Setup(store: store, pipeline: pipeline, photos: lib.assets.count)
    }

    struct Seen {
        var events: [AnalysisPipeline.Progress] = []
        /// The image step's newest count.
        var counted = 0
        var inContent = false
        /// The early suggestions' work was held (`offActorProbe`), and the count when it let go.
        var held = false
        var countedWhileHeld: Int?
    }

    /// The early suggestions' work that grows with the library is held until the image step
    /// has counted 30 photos. Made before the photos, or on the pipeline's actor, it would hold
    /// the count instead: the probe then lets go after 30 s with the count where it was (a
    /// deadline only for that case; a busy test machine still counts 30 photos in well under it).
    @Test func photosAreCountedWhileTheEarlySuggestionsAreMade() async throws {
        let s = try setup()
        let seen = Mutex(Seen())
        await s.pipeline.setOffActorProbe {
            let first = seen.withLock { state -> Bool in
                guard state.inContent, !state.held else { return false }
                state.held = true
                return true
            }
            guard first else { return }
            let deadline = Date().addingTimeInterval(30)
            while seen.withLock({ $0.counted }) < 30, Date() < deadline { usleep(1_000) }
            seen.withLock { $0.countedWhileHeld = $0.counted }
        }
        let report = try await s.pipeline.run { progress in
            seen.withLock { state in
                state.events.append(progress)
                if progress.stage == .content {
                    state.inContent = true
                    state.counted = max(state.counted, progress.completed)
                }
            }
        }
        #expect(report.isComplete)
        #expect(report.earlyProposals)
        let state = seen.withLock { $0 }
        #expect(state.held, "the early suggestions did no work off the actor")
        #expect((state.countedWhileHeld ?? 0) >= 30, "counted \(state.countedWhileHeld ?? -1) photos while the early suggestions were made")
        let content = state.events.filter { $0.stage == .content }
        // The count never goes back, and the early suggestions are said once, after photos were
        // counted, with the newest count.
        #expect(zip(content, content.dropFirst()).allSatisfy { $0.completed <= $1.completed })
        let early = content.indices.filter { content[$0].earlyProposals }
        #expect(early.count == 1)
        if let i = early.first {
            #expect(content[i].completed >= 30)
            #expect(i > 0 && content[i].completed == content[i - 1].completed)
        }
        // The early set was replaced by the full one at the end of the run.
        #expect(try await s.pipeline.latestProposals()?.isEarly == false)
    }

    /// Pause right when the image step begins, before any photo: the run waits for the early
    /// suggestions before it ends, so a paused first run still offers trips and places, and
    /// says so with the count it stopped at.
    @Test func pauseBeforeTheFirstPhotoStillOffersTheEarlySuggestions() async throws {
        let s = try setup()
        let control = AnalysisRunControl()
        let seen = Mutex<[AnalysisPipeline.Progress]>([])
        let report = try await s.pipeline.run(control: control) { progress in
            seen.withLock { $0.append(progress) }
            if progress.stage == .content { control.pause() }
        }
        #expect(report.pausedBecause == .userPaused)
        #expect(report.contentAnalyzed == 0)
        #expect(report.earlyProposals)
        let early = try #require(try await s.pipeline.latestProposals())
        #expect(early.isEarly)
        #expect(early.proposals.contains { $0.title.hasPrefix("Rom") })
        let content = seen.withLock { $0 }.filter { $0.stage == .content }
        #expect(content.filter(\.earlyProposals).count == 1)
        #expect(content.allSatisfy { $0.completed == 0 })
        // The run that goes on makes the full set and says no early ones again.
        let rest = Mutex(false)
        let second = try await s.pipeline.run { progress in if progress.earlyProposals { rest.withLock { $0 = true } } }
        #expect(second.isComplete)
        #expect(!second.earlyProposals && !rest.withLock { $0 })
        #expect(second.contentAnalyzed == s.photos)
        #expect(try await s.pipeline.latestProposals()?.isEarly == false)
    }

    /// The overview's facts (`refreshDerived` after the early suggestions, and every 10 s per
    /// 5,000 photos while it has none) are assembled off the pipeline's actor too.
    @Test func factsAreAssembledOffTheActor() async throws {
        let s = try setup()
        _ = try await s.pipeline.run()
        let probed = Mutex(0)
        await s.pipeline.setOffActorProbe { probed.withLock { $0 += 1 } }
        let facts = try await s.pipeline.currentFacts()
        #expect(facts.count == s.photos)
        #expect(probed.withLock { $0 } == 1)
    }
}
