import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore
@testable import SortlyStore
import SortlyTestSupport

/// The open points of the labels fix (app-speed, 18.11.2026): the ring holds only a fall the
/// labels cause (B) and says once why it came back lower (A); a Pause holds the overnight
/// refinement too (C); the end of a plan keeps the wait before a retry (D).
@Suite("Labels hold: follow-ups")
struct LabelsHoldFollowUpTests {
    /// Photos sorted by their trip, then "Themen" made a main area. Five photos leave their trip
    /// album in Photos before any label came: that fall is shown at once, not held. Then the labels
    /// come in: held at the count on screen (25), and when the new count is lower, the overview
    /// says so once.
    @Test func onlyAFallFromTheLabelsIsHeldAndALowerEndIsSaid() async throws {
        let s = try LabelsLaterTests.setup(photos: 30, screenshots: 0, labels: false, delay: .milliseconds(2))
        _ = try await s.pipeline.run()
        var on = LabelsLaterTests.settings(labels: true)
        on.primaryAreas = [.trips, .imageCategories]
        await s.pipeline.update(settings: on)
        let resolver = OrganizationStatusResolver(primaryAreas: on.primaryAreas)
        func status(inAlbum: Set<AssetID>) async throws -> DerivedLibraryStatus {
            let labels = try await AnalysisPipeline.photosWaitingForLabels(in: s.store, settings: on)
            let contents = try await s.store.results(ContentAnalysis.self, kind: "content")
            let facts = try await s.pipeline.currentFacts().map { f -> AssetFacts in
                var f = f
                f.tripID = SortlyID("trip")
                return f
            }
            var status = DerivedLibraryStatus.derive(facts: facts, snapshot: nil, settings: on, overrides: OverrideSet(),
                                                     contents: contents, labelsMissing: labels.missing, labelsRetrying: labels.retrying,
                                                     managed: [], inventory: CollectionInventory(), scope: .all)
            let analysed = Set(contents.filter { $0.value.failedAttempts == nil }.keys)
            let states = LibraryStatus.compute(facts: facts, snapshot: nil, settings: on, contentAnalyzed: analysed,
                                               organizedBySortly: [.trips: inAlbum])
            status.progress = resolver.progress(states.values)
            return status
        }
        // As `AppModel.assignDerived` does it.
        var hold: RecountState?
        var note: RecountState.LowerNote?
        var shown = OrganizationStatusResolver.Progress()
        var shownLabels: RecountState.LabelsWaiting?
        var seen: [Int] = []
        func assign(_ status: DerivedLibraryStatus, ended: AnalysisPipeline.Report?) {
            let next = RecountState.next(hold, shown: shown, shownLabels: shownLabels, derived: status, settings: on,
                                         newSuggestions: true, ended: ended)
            note = RecountState.LowerNote.next(note, before: hold, after: next, progress: status.progress, settings: on)
            hold = next
            shown = status.progress
            shownLabels = RecountState.LabelsWaiting(status)
            seen.append(hold?.fully ?? status.progress.fully)
        }

        let all = Set(s.photos)
        assign(try await status(inAlbum: all), ended: nil)
        #expect(seen == [30])
        // Five photos taken out of their album in Photos, no label yet: the fall is shown.
        let kept = Set(s.photos.dropFirst(5))
        let left = try await status(inAlbum: kept)
        #expect(left.labelsUntried == 30 && left.progress.fully == 25)
        assign(left, ended: nil)
        #expect(hold == nil && note == nil)
        #expect(seen == [30, 25])

        // The labels come in, a Pause part way: the count would fall, it is held at 25.
        let control = AnalysisRunControl()
        let paused = try await s.pipeline.run(control: control, onProgress: { p in
            if p.stage == .content, p.completed >= 12 { control.pause() }
        })
        #expect(paused.pausedBecause == .userPaused)
        let halfway = try await status(inAlbum: kept)
        #expect(halfway.progress.fully < 25)
        assign(halfway, ended: paused)
        #expect(hold == RecountState(fully: 25, total: 30, labels: true))
        #expect(note == nil)

        // The rest: the hold ends lower, and that is said once, with the count it held.
        let rest = try await s.pipeline.run()
        #expect(rest.isComplete)
        let after = try await status(inAlbum: kept)
        #expect(after.progress.fully < 25)
        assign(after, ended: rest)
        #expect(hold == nil)
        #expect(note == RecountState.LowerNote(held: 25))
        #expect(seen == [30, 25, 25, after.progress.fully])
        // Stays on the next refresh; gone once the count is back at 25 (theme albums made).
        assign(after, ended: rest)
        #expect(note == RecountState.LowerNote(held: 25))
        var sortedAgain = after
        sortedAgain.progress.fully = 25
        assign(sortedAgain, ended: rest)
        #expect(note == nil)
    }

    /// The note's own rules: only after a hold for the labels, only when lower, gone when a hold
    /// begins again or the count is back.
    @Test func theLowerNotesRules() {
        func progress(_ fully: Int) -> OrganizationStatusResolver.Progress {
            var p = OrganizationStatusResolver.Progress()
            p.total = 100
            p.fully = fully
            return p
        }
        var themen = LabelsLaterTests.settings(labels: true)
        themen.primaryAreas = [.trips, .imageCategories]
        func next(_ note: RecountState.LowerNote?, before: RecountState?, after: RecountState?, _ fully: Int,
                  settings: OrganizationSettings = themen) -> RecountState.LowerNote? {
            RecountState.LowerNote.next(note, before: before, after: after, progress: progress(fully), settings: settings)
        }
        let labels = RecountState(fully: 80, total: 100, labels: true)
        let rebuild = RecountState(fully: 80, total: 100)
        let note = RecountState.LowerNote(held: 80)
        #expect(next(nil, before: labels, after: nil, 70) == note)
        #expect(next(nil, before: labels, after: nil, 80) == nil)
        #expect(next(nil, before: labels, after: labels, 70) == nil)
        // The rebuild's hold has its own words ("kommt mit den ersten Vorschlägen").
        #expect(next(nil, before: rebuild, after: nil, 70) == nil)
        #expect(next(note, before: nil, after: nil, 75) == note)
        #expect(next(note, before: nil, after: nil, 81) == nil)
        #expect(next(note, before: nil, after: rebuild, 70) == nil)
        // "Themen" no longer a main area (or turned off): that ended the hold, the user's own
        // change; no note that would name themes (second review 4).
        var tripsOnly = themen
        tripsOnly.primaryAreas = [.trips]
        #expect(next(nil, before: labels, after: nil, 70, settings: tripsOnly) == nil)
        #expect(next(nil, before: labels, after: nil, 70, settings: LabelsLaterTests.settings(labels: false)) == nil)
    }

    /// C: a run paused by the user, also when Pause came too late to stop it with work left,
    /// leaves the analysis paused for the overnight refinement; any other end does not.
    @Test func aPauseIsKeptForTheRefinement() {
        let settings = LabelsLaterTests.settings(labels: true)
        var paused = AnalysisPipeline.Report()
        paused.completedStages = [.inventory]
        paused.pausedBecause = .userPaused
        #expect(AnalysisRunEnd(report: paused, settings: settings, pauseTapped: true, catchUpRequested: false, mayStart: true).keepsPause)
        #expect(AnalysisRunEnd(report: paused, settings: settings, pauseTapped: true, catchUpRequested: false, mayStart: true,
                               background: true).keepsPause)
        // Through, but a change of the settings it missed is left and Pause was tapped: paused.
        var through = AnalysisPipeline.Report()
        through.completedStages = AnalysisPipeline.Stage.allCases
        through.settingsUsed.labels = false
        #expect(AnalysisRunEnd(report: through, settings: settings, pauseTapped: true, catchUpRequested: false, mayStart: true).keepsPause)
        // Finished, cut off by iOS, or ended by the device: no Pause.
        through.settingsUsed.labels = true
        #expect(!AnalysisRunEnd(report: through, settings: settings, pauseTapped: true, catchUpRequested: false, mayStart: true).keepsPause)
        #expect(!AnalysisRunEnd(report: nil, settings: settings, pauseTapped: false, catchUpRequested: false, mayStart: true).keepsPause)
        var hot = paused
        hot.pausedBecause = .thermal
        #expect(!AnalysisRunEnd(report: hot, settings: settings, pauseTapped: false, catchUpRequested: false, mayStart: true,
                                background: true).keepsPause)
    }

    /// D: the end of a plan starts the analysis only once its try is due; a try that came due
    /// during the plan goes on when the plan ends.
    @Test func theEndOfAPlanKeepsTheWaitBeforeARetry() {
        let start = ContinuousClock.now
        var retry = UnattendedRetry()
        #expect(retry.startsOnRelease(now: start))
        // Vision failed: 30 s, then 60 s, then no more.
        #expect(retry.schedule(photos: false, now: start) == .seconds(30))
        #expect(!retry.startsOnRelease(now: start + .seconds(5)))
        #expect(retry.startsOnRelease(now: start + .seconds(30)))
        retry.runStarted()
        #expect(retry.startsOnRelease(now: start + .seconds(31)))
        #expect(retry.schedule(photos: false, now: start + .seconds(40)) == .seconds(60))
        #expect(!retry.startsOnRelease(now: start + .seconds(90)))
        retry.runStarted()
        #expect(retry.schedule(photos: false, now: start + .seconds(200)) == nil)
        #expect(retry.startsOnRelease(now: start + .seconds(201)))
        // Photos did not answer: every minute, without a cap.
        for minute in 0..<5 {
            let now = start + .seconds(300 + 60 * minute)
            #expect(retry.schedule(photos: true, now: now) == UnattendedRetry.photosDelay)
            #expect(!retry.startsOnRelease(now: now + .seconds(59)))
            #expect(retry.startsOnRelease(now: now + .seconds(60)))
            retry.runStarted()
        }
        // A tap, the app on screen, or a finished analysis: the tries count anew.
        retry.reset()
        #expect(retry.tries == 0)
        #expect(retry.schedule(photos: false, now: start) == .seconds(30))
    }
}
