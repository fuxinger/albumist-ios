import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
@testable import SortlyCore
@testable import SortlyStore
import SortlyTestSupport

/// Second review of the labels fix (17.11.): what follows the end of a run (`AnalysisRunEnd`),
/// decided against the settings the run really read (`Report.settingsUsed`). The owner's rules:
/// never a false "fertig", Pause is always respected, no run is lost, no number goes back.
@Suite("Run end: what follows a run")
struct AnalysisRunEndTests {
    typealias T = LabelsLaterTests

    static let off = T.settings(labels: false)
    static let on = T.settings(labels: true)

    /// A complete report of a run that read `used`.
    static func complete(_ used: OrganizationSettings) -> AnalysisPipeline.Report {
        var report = AnalysisPipeline.Report()
        report.completedStages = AnalysisPipeline.Stage.allCases
        report.settingsUsed = .init(used)
        return report
    }

    static func end(_ report: AnalysisPipeline.Report?, settings: OrganizationSettings = on, pauseTapped: Bool = false,
                    catchUp: Bool = false, mayStart: Bool = true, background: Bool = false) -> AnalysisRunEnd {
        AnalysisRunEnd(report: report, settings: settings, pauseTapped: pauseTapped, catchUpRequested: catchUp,
                       mayStart: mayStart, background: background)
    }

    // MARK: The decision

    @Test func aRunThatDidWhatTheSettingsAskIsFinished() {
        let done = Self.end(Self.complete(Self.on))
        #expect(done.isFinished && done.next == .nothing && !done.needsResume)
        #expect(done.report == Self.complete(Self.on))
        // Changes in Photos during it: one more pass after the usual gap, as before.
        let changed = Self.end(Self.complete(Self.on), catchUp: true)
        #expect(changed.isFinished && changed.next == .catchUp)
        // Settings changed in a way that needs no run ("Themen" off): finished.
        let offNow = Self.end(Self.complete(Self.on), settings: Self.off)
        #expect(offNow.isFinished && offNow.next == .nothing)
    }

    /// Finding 1: "Themen" turned on after the run decided on its labels. Not "fertig": one more
    /// run right away; it takes changes in Photos in too.
    @Test func aChangeTheRunMissedStartsOneMoreRightAway() {
        let missed = Self.end(Self.complete(Self.off))
        #expect(missed.next == .followUp)
        #expect(!missed.isFinished)
        // The report stays complete; the run goes on by itself, so the Lock Screen never reads "fertig".
        #expect(missed.report?.isComplete == true && missed.needsResume)
        #expect(Self.end(Self.complete(Self.off), catchUp: true).next == .followUp)
        // Each change `settingsChangeNeedsRun` names, the same way.
        var hidden = Self.on
        hidden.privacy.includeHiddenAssets = true
        var noHidden = Self.on
        noHidden.privacy.includeHiddenAssets = false
        #expect(Self.end(Self.complete(noHidden), settings: hidden).next == .followUp)
        var offline = Self.on
        offline.privacy.allowOnlineGeocoding = false
        #expect(Self.end(Self.complete(offline), settings: Self.on).next == .followUp)
    }

    /// No run may start now (a plan claimed or being written, a rebuild, no photo access): the
    /// one that ends that starts a run anyway. Still never "fertig".
    @Test func aMissedChangeWaitsForTheRunThatIsDueAnyway() {
        let held = Self.end(Self.complete(Self.off), mayStart: false)
        #expect(held.next == .nothing && !held.isFinished && held.needsResume)
        #expect(Self.end(Self.complete(Self.off), catchUp: true, mayStart: false).next == .catchUp)
    }

    /// Finding 2: Pause tapped during the last steps, which finish anyway. With work left the
    /// run reads as paused by the user ("Fortsetzen"), nothing starts by itself.
    @Test func aLatePauseKeepsTheWorkForFortsetzen() {
        let settingsLeft = Self.end(Self.complete(Self.off), pauseTapped: true)
        #expect(settingsLeft.report?.pausedBecause == .userPaused)
        #expect(settingsLeft.report?.isComplete == false)
        #expect(settingsLeft.next == .nothing && !settingsLeft.isFinished && !settingsLeft.needsResume)
        // Changes in Photos left: the same, Pause wins over the catch-up.
        let photosLeft = Self.end(Self.complete(Self.on), pauseTapped: true, catchUp: true)
        #expect(photosLeft.report?.pausedBecause == .userPaused && photosLeft.next == .nothing)
        // Nothing left: the Pause came too late for a run that was done; it is finished.
        let nothingLeft = Self.end(Self.complete(Self.on), pauseTapped: true)
        #expect(nothingLeft.isFinished && nothingLeft.report?.pausedBecause == nil)
    }

    @Test func pausedOrStoppedRunsGoOnAsBefore() {
        var paused = Self.complete(Self.off)
        paused.pausedBecause = .userPaused
        // "Fortsetzen" reads the library and the settings: nothing follows, the catch-up is taken.
        for catchUp in [false, true] {
            let end = Self.end(paused, pauseTapped: true, catchUp: catchUp)
            #expect(end.next == .nothing && !end.isFinished && !end.needsResume)
        }
        var hot = Self.complete(Self.off)
        hot.pausedBecause = .thermal
        #expect(Self.end(hot).next == .retry)
        #expect(Self.end(hot).needsResume)
        #expect(Self.end(hot, catchUp: true).next == .catchUp)
        // Threw or stopped on purpose.
        #expect(Self.end(nil).next == .retry && Self.end(nil).needsResume)
        #expect(Self.end(nil, catchUp: true).next == .catchUp)
    }

    /// Finding 3: the overnight refinement ends through the same rules. It takes a catch-up
    /// asked for meanwhile, starts a run for a change it missed, and leaves retries to its
    /// next window.
    @Test func theRefinementEndsTheSameWay() {
        #expect(Self.end(Self.complete(Self.on), catchUp: true, background: true).next == .catchUp)
        #expect(Self.end(Self.complete(Self.off), background: true).next == .followUp)
        #expect(Self.end(Self.complete(Self.on), background: true).isFinished)
        var cut = Self.complete(Self.on)
        cut.pausedBecause = .timeBudget
        #expect(Self.end(cut, background: true).next == .nothing)
        #expect(Self.end(nil, background: true).next == .nothing)
        #expect(Self.end(nil, catchUp: true, background: true).next == .catchUp)
    }

    /// Third review, finding 1: the refinement decides its end as soon as its run returns, with
    /// the Pause tapped until then. Paused by the user, the analysis stays paused (before, an
    /// unfinished one went on by itself); the other ends set `needsResume` as before.
    @Test func aPauseDuringTheRefinementStays() {
        let late = Self.end(Self.complete(Self.off), pauseTapped: true, background: true)
        #expect(late.report?.pausedBecause == .userPaused && late.next == .nothing && !late.isFinished)
        var paused = Self.complete(Self.off)
        paused.pausedBecause = .userPaused
        for before in [false, true] {
            #expect(!late.needsResume(afterRefinement: before))
            #expect(!Self.end(paused, pauseTapped: true, background: true).needsResume(afterRefinement: before))
            // Finished: nothing to go on with. A change it missed: not done.
            #expect(!Self.end(Self.complete(Self.on), background: true).needsResume(afterRefinement: before))
            #expect(Self.end(Self.complete(Self.off), background: true).needsResume(afterRefinement: before))
            // Cut off by iOS or stopped by the device: as it was.
            var hot = Self.complete(Self.on)
            hot.pausedBecause = .thermal
            #expect(Self.end(hot, background: true).needsResume(afterRefinement: before) == before)
            #expect(Self.end(nil, background: true).needsResume(afterRefinement: before) == before)
        }
    }

    /// Third review, finding 3: "Themen" turned on while the overnight refinement runs, after it
    /// decided on labels. Its end asks for one more run, which the app makes a second pass of the
    /// refinement in the same window (`AppModel.refine`): that pass gives the labels and is finished.
    @Test func theRefinementDoesAChangeItMissedInASecondPass() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        _ = try await s.pipeline.run()
        let pipeline = s.pipeline
        final class Change: Sendable { let task = Mutex<Task<OrganizationSettings, Never>?>(nil) }
        let change = Change()
        let first = try await pipeline.run(mode: .refinement, onProgress: { p in
            guard p.stage == .content else { return }
            change.task.withLock { task in
                if task == nil { task = Task { await pipeline.update(settings: Self.on) } }
            }
        })
        _ = await change.task.withLock { $0 }?.value
        let end = Self.end(first, background: true)
        #expect(end.next == .followUp && !end.isFinished && end.needsResume(afterRefinement: false))
        let second = try await pipeline.run(mode: .refinement)
        #expect(second.labelsAdded == 12)
        let done = Self.end(second, background: true)
        #expect(done.isFinished && done.next == .nothing && !done.needsResume(afterRefinement: true))
    }

    /// Finding 4: another run started while this one's end waited for the overview (a change
    /// of the settings, "Neu prüfen"): no finish moment and nothing scheduled from the older run.
    @Test func anEndThatWaitedLeavesTheNewerRunAlone() {
        let done = Self.end(Self.complete(Self.on), catchUp: true)
        #expect(done.afterWait(isNewest: true) == (finishMoment: true, next: .catchUp))
        #expect(done.afterWait(isNewest: false) == (finishMoment: false, next: .nothing))
        var hot = Self.complete(Self.on)
        hot.pausedBecause = .thermal
        #expect(Self.end(hot).afterWait(isNewest: true) == (finishMoment: false, next: .retry))
        #expect(Self.end(hot).afterWait(isNewest: false) == (finishMoment: false, next: .nothing))
        // The follow-up started before the wait: nothing more after it.
        #expect(Self.end(Self.complete(Self.off)).afterWait(isNewest: false) == (finishMoment: false, next: .nothing))
        #expect(Self.end(Self.complete(Self.off)).afterWait(isNewest: true) == (finishMoment: false, next: .nothing))
    }

    /// What a run read, step by step: a run that did not get to a setting decides nothing about
    /// it; one that read everything decides as `settingsChangeNeedsRun`.
    @Test func whatARunReadDecidesLikeTheChangeItself() {
        let nothing = AnalysisPipeline.SettingsUsed()
        #expect(!nothing.needsRun(for: Self.on))
        let pairs: [(OrganizationSettings, OrganizationSettings)] = [(Self.off, Self.on), (Self.on, Self.off), (Self.off, Self.off),
                                                                     (Self.on, T.settings(labels: false, documents: true))]
        for (old, new) in pairs {
            #expect(AnalysisPipeline.SettingsUsed(old).needsRun(for: new) == AnalysisPipeline.settingsChangeNeedsRun(from: old, to: new))
        }
        var labelsOnly = AnalysisPipeline.SettingsUsed()
        labelsOnly.labels = false
        #expect(labelsOnly.needsRun(for: Self.on))
        #expect(!labelsOnly.needsRun(for: Self.off))
    }

    // MARK: Through the pipeline

    /// Conditions that let a test act once, at the run's first check: right after the library
    /// was read, before the run decides on labels (the change lands there for certain, not when
    /// a task happens to run).
    final class FirstCheck: AnalysisConditions, Sendable {
        let action = Mutex<(@Sendable () async -> Void)?>(nil)
        func pauseReason() async -> PauseReason? { nil }
        func pace() async -> AnalysisPace {
            let act = action.withLock { a in
                defer { a = nil }
                return a
            }
            await act?()
            return .normal
        }
        func isOnWiFi() async -> Bool { true }
    }

    /// "Themen" turned on after the library was read: the run decides on labels after the trips
    /// step and gives them itself. Its end needs nothing more (finding 5: the extra run).
    @Test func aChangeBeforeTheLabelsAreDecidedIsTakenInByTheRun() async throws {
        let check = FirstCheck()
        let s = try T.setup(photos: 12, screenshots: 0, labels: false, conditions: check)
        let pipeline = s.pipeline
        check.action.withLock { $0 = { _ = await pipeline.update(settings: Self.on) } }
        let report = try await pipeline.run()
        #expect(report.isComplete)
        #expect(report.settingsUsed.labels == true)
        #expect(report.labelsAdded + report.contentAnalyzed == 12)
        #expect(try await s.store.labelsVersions().values.allSatisfy { $0 == AnalysisPipeline.labelsVersion })
        let end = Self.end(report)
        #expect(end.isFinished && end.next == .nothing)
    }

    /// "Themen" turned on in the image step, after the run decided against labels: its end
    /// starts one more run right away, not "fertig"; that run gives the labels and is finished.
    @Test func aChangeAfterTheLabelsAreDecidedStartsTheFollowUp() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        let pipeline = s.pipeline
        final class Change: Sendable { let task = Mutex<Task<OrganizationSettings, Never>?>(nil) }
        let change = Change()
        let first = try await pipeline.run(onProgress: { p in
            guard p.stage == .content else { return }
            change.task.withLock { task in
                if task == nil { task = Task { await pipeline.update(settings: Self.on) } }
            }
        })
        _ = await change.task.withLock { $0 }?.value
        #expect(first.isComplete && first.settingsUsed.labels == false && first.labelsAdded == 0)
        let end = Self.end(first)
        #expect(end.next == .followUp && !end.isFinished)
        let followUp = try await pipeline.run()
        #expect(followUp.labelsAdded == 12)
        #expect(Self.end(followUp).isFinished)
    }

    /// The reviewer's probe: Pause tapped while the suggestions are made does not stop the run.
    /// With "Themen" turned on during it, the run reads as paused ("Fortsetzen"), and
    /// "Fortsetzen" gives the labels.
    @Test func pauseDuringTheSuggestionsKeepsTheChangeForFortsetzen() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        let pipeline = s.pipeline
        final class Change: Sendable { let task = Mutex<Task<OrganizationSettings, Never>?>(nil) }
        let change = Change()
        let control = AnalysisRunControl()
        let report = try await pipeline.run(control: control, onProgress: { p in
            if p.stage == .content {
                change.task.withLock { task in
                    if task == nil { task = Task { await pipeline.update(settings: Self.on) } }
                }
            }
            if p.stage == .proposals, p.completed == 0 { control.pause() }
        })
        _ = await change.task.withLock { $0 }?.value
        #expect(report.isComplete)
        let end = Self.end(report, pauseTapped: control.isPaused)
        #expect(end.report?.pausedBecause == .userPaused)
        #expect(end.next == .nothing && !end.isFinished && !end.needsResume)
        let resumed = try await pipeline.run()
        #expect(resumed.labelsAdded == 12)
        #expect(Self.end(resumed).isFinished)
    }

    /// A run paused in the library read never got to the labels: nothing of its own decides;
    /// "Fortsetzen" reads the settings.
    @Test func aRunPausedEarlyReadOnlyWhatItGotTo() async throws {
        let s = try T.setup(photos: 12, screenshots: 0, labels: false)
        let control = AnalysisRunControl()
        let report = try await s.pipeline.run(control: control, onProgress: { p in
            if p.stage == .inventory { control.pause() }
        })
        #expect(report.pausedBecause == .userPaused)
        #expect(report.settingsUsed.labels == nil && report.settingsUsed.text == nil && report.settingsUsed.places == nil)
        #expect(report.settingsUsed.hidden != nil)
    }

    // MARK: Words and the marker

    @Test func aCheckIsNamedForTheNewAreasWhenItIsMostlyLabels() {
        func w(content: Int, text: Int = 0, labels: Int) -> AnalysisWorkload {
            AnalysisWorkload(photos: 5_683, located: 4_000, screenshots: 300, contentLeft: content, textLeft: text, labelsLeft: labels)
        }
        #expect(w(content: 5_683, labels: 5_683).isMostlyLabels)
        #expect(w(content: 5_683, text: 40, labels: 5_600).isMostlyLabels)
        #expect(!w(content: 300, labels: 0).isMostlyLabels)
        #expect(!w(content: 3_000, labels: 1_000).isMostlyLabels)
        #expect(w(content: 2_000, labels: 1_000).isMostlyLabels)
    }

    /// Finding 9: the label "für die neuen Bereiche" is kept in the marker as one an older build
    /// knows ("Neue Fotos") plus a flag it ignores, and read back from the two. The marker itself
    /// (`AnalysisMarker.Point`) is the app's: its round trip and an older build reading it are in
    /// the app's tests (`AnalysisMarkerLabelTests`, third review, 7: not a copy of it here).
    @Test func theMarkerKeepsTheNewLabelInWordsOlderBuildsKnow() {
        let all: [ResumedRun.NewWork] = [.newAreas, .newPhotos, .moreNewPhotos, .afterUpdate, .afterUpdateAgain]
        for label in all {
            #expect(label.markerValue != .newAreas)
            #expect(ResumedRun.NewWork.fromMarker(label.markerValue, flag: label.markerFlag) == label)
            #expect((label.markerFlag != nil) == (label == .newAreas))
        }
        #expect(ResumedRun.NewWork.newAreas.markerValue == .newPhotos)
        // A marker without the flag (an older build wrote it) reads as it is.
        for label in all where label != .newAreas {
            #expect(ResumedRun.NewWork.fromMarker(label, flag: nil) == label)
        }
        #expect(ResumedRun.NewWork.fromMarker(nil, flag: nil) == nil)
    }

    // MARK: Store

    /// Finding 11: the overview reads only the analysed photos still without labels: none once
    /// they are caught up, none never analysed, none given up.
    @Test func theStoreReadsOnlyThePhotosWaitingForLabels() async throws {
        let store = try SortlyStore(url: nil)
        var lib = LibraryBuilder()
        let a = lib.photo(at: Fixture.date("2026-03-01 10:00"), Fixture.Places.munichHome)
        let b = lib.photo(at: Fixture.date("2026-03-02 10:00"), Fixture.Places.munichHome)
        let c = lib.photo(at: Fixture.date("2026-03-03 10:00"), Fixture.Places.munichHome)
        _ = lib.photo(at: Fixture.date("2026-03-04 10:00"), Fixture.Places.munichHome)
        _ = try await store.upsertAssets(lib.assets)
        try await store.saveResults([(a, ContentAnalysis()), (b, ContentAnalysis())], kind: "content", version: 1, markingAnalyzed: [a, b])
        try await store.saveResults([(c, ContentAnalysis(labels: [LabelScore("dog", 0.9)]))], kind: "content", version: 1,
                                    markingAnalyzed: [c], labelsVersion: 1)
        #expect(try await store.unlabelledAssets(version: 1, labelsVersion: 1) == [a, b])
        try await store.saveResults([(AssetID, ContentAnalysis)](), kind: "content", version: 1, markingAnalyzed: [a, b], labelsVersion: 1)
        #expect(try await store.unlabelledAssets(version: 1, labelsVersion: 1).isEmpty)
    }
}
