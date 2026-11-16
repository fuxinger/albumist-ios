import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// The App Store rating question (decision Fuchs, 16.11.2026): only after the user left the
/// result of a plan that made new albums without a problem, never at app start. One test per
/// rule of `ReviewPromptPolicy`, the moment itself (`Session`), and the stored state.
@Suite("Rating question")
struct ReviewPromptTests {
    typealias Policy = ReviewPromptPolicy

    let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
    let day: TimeInterval = 24 * 60 * 60
    /// When results are left, unless a test says otherwise (`ContinuousClock`).
    let start = ContinuousClock.now

    // MARK: Plans

    /// Two photos for "Rom", one for "Sommer", which exists already.
    func library() -> InMemoryPhotoLibrary {
        InMemoryPhotoLibrary(assets: ["a", "b", "c", "s1"], collections: [CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ["s1"])])
    }

    /// A plan run on `library`: "Rom" made new with two photos; `extend` puts a photo into the
    /// existing album "Sommer" instead (no new album); `missing` plans a photo that is no longer
    /// there; `failAfterWrites` lets the library fail its writes after that many.
    func applied(extend: Bool = false, missing: Bool = false, failAfterWrites: Int? = nil,
                 in library: InMemoryPhotoLibrary? = nil) async throws -> ChangePlan {
        let photos = library ?? self.library()
        let proposal = extend
            ? AlbumProposal(id: SortlyID("sommer"), kind: .trip, title: "Sommer", assetIDs: ["c"])
            : AlbumProposal(id: SortlyID("rom"), kind: .trip, title: "Rom", assetIDs: missing ? ["a", "b", "gone"] : ["a", "b"])
        let decision: ProposalDecision = extend ? .extendExisting("sommer") : .createNew(title: nil, folderPath: nil)
        var plan = OrganizationPlanner(rootFolderTitle: "")
            .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: try await photos.currentInventory())
        plan.confirmedAt = now
        plan.status = .confirmed
        if let failAfterWrites { await photos.setFailAfterWrites(failAfterWrites) }
        return try await ChangeExecutor(library: photos, store: InMemoryPlanStore()).execute(plan)
    }

    /// The undo of `plan`, run on the library `plan` ran on.
    func undo(of plan: ChangePlan, in library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        var reverting = UndoPlanner().undoPlan(for: plan, current: try await library.currentInventory())
        reverting.confirmedAt = now
        reverting.status = .confirmed
        return try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(reverting)
    }

    /// The user saw the result of `plan` and left it.
    func seenAndLeft(_ plan: ChangePlan) -> Policy.Session {
        var session = Policy.Session()
        session.screenAppeared()
        session.resultSeen(plan)
        leave(&session, moment: true)
        return session
    }

    /// A result or receipt leaves the screen (at `time`, else `start`); `moment`: whether that is
    /// the moment to ask. (The session changes, so this is not done inside `#expect`.)
    func leave(_ session: inout Policy.Session, moment: Bool, at time: ContinuousClock.Instant? = nil,
               sourceLocation: SourceLocation = #_sourceLocation) {
        let isMoment = session.screenDisappeared(at: time ?? start)
        #expect(isMoment == moment, sourceLocation: sourceLocation)
    }

    /// Takes the plan to ask about now and expects `plan` (nil: none).
    func expectTaken(_ session: inout Policy.Session, _ plan: ChangePlan?, sourceLocation: SourceLocation = #_sourceLocation) {
        let taken = session.takeWaiting()
        #expect(taken?.plan.id == plan?.id, sourceLocation: sourceLocation)
    }

    func refusal(_ plan: ChangePlan, session: Policy.Session? = nil, situation: Policy.Situation = Policy.Situation(),
                 state: Policy.State = Policy.State(), version: String = "1.0.0", at time: Date? = nil) -> Policy.Refusal? {
        Policy.refusal(after: plan, session: session ?? seenAndLeft(plan), situation: situation, state: state,
                       version: version, now: time ?? now)
    }

    // MARK: When it asks

    /// A plan that made new albums without a problem, its result seen and left a moment ago,
    /// nothing busy, not asked in this version or the last 120 days: it asks. Any such plan, not
    /// only the first one (for most people the first one makes their first albums); also on the
    /// day of the first launch (decided 16.11.: no day is left out, see the type's comment).
    @Test func asksAfterAPlanWithNewAlbumsEvenOnTheFirstDay() async throws {
        let plan = try await applied()
        #expect(plan.status == .completed)
        #expect(refusal(plan) == nil)
    }

    @Test func askingIsWrittenDownWithVersionAndDate() async throws {
        let plan = try await applied()
        let state = Policy.State.asked(version: "1.0.0", at: now)
        #expect(state == Policy.State(lastAskedVersion: "1.0.0", lastAskedAt: now))
        #expect(refusal(plan, state: state) == .askedInThisVersion)
    }

    // MARK: Never at app start

    /// At launch the session is new. A plan that finished before the app was closed (its results
    /// are stored at launch) or the newest one of the history was not seen in this run, and the
    /// receipt of an old plan opened from "Verlauf" and left again is no moment either.
    @Test func appStartNeverAsks() async throws {
        let plan = try await applied()
        var session = Policy.Session()
        #expect(refusal(plan, session: session) == .resultNotSeen)
        session.screenAppeared()
        leave(&session, moment: false)
        expectTaken(&session, nil)
        #expect(refusal(plan, session: session) == .resultNotSeen)
    }

    /// A plan that was cut off and is found at launch is trouble for the whole run: continuing or
    /// keeping it, and even a clean plan afterwards, does not ask.
    @Test func interruptedPlanFoundAtLaunchMeansNoQuestionInThisRun() async throws {
        let plan = try await applied()
        var session = Policy.Session()
        session.interruptedPlanFound()
        session.screenAppeared()
        session.resultSeen(plan)
        leave(&session, moment: true)
        #expect(refusal(plan, session: session) == .troubleInThisSession)
    }

    // MARK: The moment: seen, then left

    @Test func leavingTheResultIsTheMomentAndItIsTakenOnce() async throws {
        let plan = try await applied()
        var session = Policy.Session()
        session.screenAppeared()
        // Not seen yet (flashed by, e.g. a sheet that closes as soon as the plan is done).
        leave(&session, moment: false)
        session.screenAppeared()
        session.resultSeen(plan)
        leave(&session, moment: true)
        expectTaken(&session, plan)
        expectTaken(&session, nil)
        // Seen again (back on the result): it may wait again.
        session.screenAppeared()
        session.resultSeen(plan)
        leave(&session, moment: true)
        expectTaken(&session, plan)
    }

    /// "Alle Änderungen ansehen" covers the result with its receipt: never asked over it, in
    /// whichever order the two screens report.
    @Test func receiptOpenedFromTheResultHoldsTheQuestionBack() async throws {
        let plan = try await applied()
        var session = Policy.Session()
        session.screenAppeared()
        session.resultSeen(plan)
        // The receipt comes on screen first, then the result leaves.
        session.screenAppeared()
        leave(&session, moment: false)
        expectTaken(&session, nil)
        // Back from the receipt to the result, then away from both.
        session.screenAppeared()
        leave(&session, moment: false)
        leave(&session, moment: true)
        expectTaken(&session, plan)

        // The result leaves first, the receipt arrives before the question: it waits.
        var other = Policy.Session()
        other.screenAppeared()
        other.resultSeen(plan)
        leave(&other, moment: true)
        other.screenAppeared()
        expectTaken(&other, nil)
        leave(&other, moment: true)
        expectTaken(&other, plan)
    }

    // MARK: Only right after the result was left, in Albumist

    /// The user leaves the result, then Albumist (Home Screen, another app, a call) while the
    /// question waits: it is dropped, also when they come back and open and leave a receipt.
    @Test func leavingAlbumistWhileTheQuestionWaitsDropsIt() async throws {
        let plan = try await applied()
        var session = seenAndLeft(plan)
        session.sceneLeft()
        expectTaken(&session, nil)
        // Back in Albumist: a receipt from "Verlauf" opened and left is no moment for it.
        session.screenAppeared()
        leave(&session, moment: false)
        expectTaken(&session, nil)
    }

    /// "In Fotos ansehen" on the result leaves Albumist while the result stays on screen: back
    /// from Photos, leaving the result is still the moment.
    @Test func leavingAlbumistWithTheResultOnScreenKeepsIt() async throws {
        let plan = try await applied()
        var session = Policy.Session()
        session.screenAppeared()
        session.resultSeen(plan)
        session.sceneLeft()
        leave(&session, moment: true)
        expectTaken(&session, plan)
        #expect(refusal(plan, session: session) == nil)
    }

    /// The wait for the question counts the time in the background (`ContinuousClock`): asked
    /// later than `momentLasts` after the result was left, nothing is asked, also when the app
    /// did not hear that it left the screen (or the tabs came back with an old moment).
    @Test func questionLongAfterLeavingTheResultIsNotAsked() async throws {
        #expect(Policy.momentLasts == Policy.delay + Policy.analysisWait + .seconds(2))
        let plan = try await applied()
        var session = Policy.Session()
        session.screenAppeared()
        session.resultSeen(plan)
        leave(&session, moment: true, at: start)
        let waiting = session.takeWaiting()
        let taken = try #require(waiting)
        #expect(taken.plan.id == plan.id)
        #expect(taken.left == start)
        // As the app measures it: the clock at the question minus the moment the result was left.
        func asked(at time: ContinuousClock.Instant) -> Policy.Refusal? {
            refusal(plan, session: session, situation: Policy.Situation(sinceLeft: time - taken.left))
        }
        #expect(asked(at: start + Policy.delay) == nil)
        #expect(asked(at: start + Policy.momentLasts) == nil)
        #expect(asked(at: start + Policy.momentLasts + .milliseconds(1)) == .momentPassed)
        // Hours in the background, the sleep of the wait already over when the user is back.
        #expect(asked(at: start + .seconds(3 * 60 * 60)) == .momentPassed)
    }

    /// Back on the result while the question waits: that moment is over, leaving it again is
    /// the next one (with its own time).
    @Test func backOnTheResultStartsTheMomentAgain() async throws {
        let plan = try await applied()
        var session = seenAndLeft(plan)
        session.screenAppeared()
        #expect(session.left == nil)
        // Albumist leaves the screen with the result on it: the plan stays.
        session.sceneLeft()
        leave(&session, moment: true, at: start + .seconds(60))
        let waiting = session.takeWaiting()
        #expect(waiting?.plan.id == plan.id)
        #expect(waiting?.left == start + .seconds(60))
    }

    // MARK: Taken back

    @Test func undoOnTheResultMeansNoQuestion() async throws {
        let plan = try await applied()
        var session = Policy.Session()
        session.screenAppeared()
        session.resultSeen(plan)
        session.undoStarted(plan.id)
        leave(&session, moment: false)
        expectTaken(&session, nil)
        #expect(refusal(plan, session: session) == .undone)
    }

    /// Also an undo that only took back part ("Nicht erlauben"), and one started from the receipt
    /// after the result was left.
    @Test func undoAfterLeavingTheResultMeansNoQuestion() async throws {
        let plan = try await applied()
        var session = seenAndLeft(plan)
        session.undoStarted(plan.id)
        expectTaken(&session, nil)
        #expect(refusal(plan, session: session) == .undone)
    }

    /// The result of the undo itself shows "Rückgängig gemacht": no question either.
    @Test func undoPlanNeverAsks() async throws {
        let photos = library()
        let reverted = try await undo(of: try await applied(in: photos), in: photos)
        #expect(reverted.reverts != nil)
        #expect(reverted.status == .completed)
        #expect(refusal(reverted) == .undoPlan)
    }

    // MARK: Only after a plan that made new albums, completely

    @Test func planWithoutANewAlbumDoesNotAsk() async throws {
        let plan = try await applied(extend: true)
        #expect(plan.status == .completed)
        #expect(refusal(plan) == .noNewAlbum)
    }

    @Test func failedStepMeansNoQuestion() async throws {
        // The album is made, adding the photos fails.
        let plan = try await applied(failAfterWrites: 1)
        #expect(plan.status == .completedWithErrors)
        #expect(refusal(plan) == .incomplete)
    }

    @Test func photosNoLongerInTheLibraryMeanNoQuestion() async throws {
        let plan = try await applied(missing: true)
        #expect(PlanReceipt(plan: plan, inventory: CollectionInventory()).unavailablePhotos == 1)
        #expect(refusal(plan) == .incomplete)
    }

    @Test func planThatDidNotFinishDoesNotAsk() async throws {
        var plan = try await applied()
        plan.status = .running
        #expect(refusal(plan) == .incomplete)
        plan.status = .cancelled
        #expect(refusal(plan) == .incomplete)
    }

    @Test func unconfirmedStepMeansNoQuestion() async throws {
        var plan = try await applied()
        let step = try #require(plan.steps.first { if case .addAssets = $0.operation { true } else { false } })
        plan.record?.unverified.insert(step.id)
        #expect(refusal(plan) == .incomplete)
    }

    /// "Fehlendes erneut versuchen" follows a plan that went wrong.
    @Test func retryPlanNeverAsks() async throws {
        var plan = try await applied()
        plan.retries = SortlyID("earlier")
        #expect(refusal(plan) == .retryPlan)
    }

    // MARK: Never after a plan that went wrong in this run

    @Test func earlierFailedPlanInThisRunMeansNoQuestion() async throws {
        let failed = try await applied(failAfterWrites: 1)
        let plan = try await applied()
        var session = Policy.Session()
        session.planEnded(failed, resultsStored: true)
        #expect(session.hadTrouble)
        session.screenAppeared()
        session.resultSeen(plan)
        leave(&session, moment: true)
        #expect(refusal(plan, session: session) == .troubleInThisSession)
    }

    @Test func whatCountsAsTrouble() async throws {
        let photos = library()
        let plan = try await applied(in: photos)
        let undone = try await undo(of: plan, in: photos)
        let failedStep = try await applied(failAfterWrites: 1)
        let photosMissing = try await applied(missing: true)
        func trouble(_ result: ChangePlan?, stored: Bool = true) -> Bool {
            var session = Policy.Session()
            session.planEnded(result, resultsStored: stored)
            return session.hadTrouble
        }
        #expect(!trouble(plan))
        // A clean undo of another plan is no trouble.
        #expect(!trouble(undone))
        // The plan stopped with an error, before or after it started.
        #expect(trouble(nil))
        // Its results (albums, decisions, free albums) could not be stored, e.g. a full disk.
        #expect(trouble(plan, stored: false))
        #expect(trouble(failedStep))
        #expect(trouble(photosMissing))
        var stopped = plan
        stopped.status = .running
        #expect(trouble(stopped))
    }

    // MARK: Never while something is busy

    @Test func neverWhileAPlanRuns() async throws {
        #expect(refusal(try await applied(), situation: Policy.Situation(planRunning: true)) == .planRunning)
    }

    /// Also the check for new photos that follows every plan (the app waits for it a little) and
    /// the first analysis.
    @Test func neverWhileAnAnalysisRuns() async throws {
        #expect(refusal(try await applied(), situation: Policy.Situation(analysisRunning: true)) == .analysisRunning)
    }

    @Test func neverWhileAChangeInDeinZuhauseRuns() async throws {
        #expect(refusal(try await applied(), situation: Policy.Situation(homeChangeRunning: true)) == .homeChangeRunning)
    }

    @Test func neverWhileAPlanThatWasCutOffWaits() async throws {
        #expect(refusal(try await applied(), situation: Policy.Situation(planInterrupted: true)) == .planInterrupted)
    }

    @Test func neverInTheBackgroundOrOverAMessage() async throws {
        let plan = try await applied()
        #expect(refusal(plan, situation: Policy.Situation(onScreen: false)) == .notOnScreen)
        #expect(refusal(plan, situation: Policy.Situation(messageShown: true)) == .messageShown)
    }

    // MARK: Never in UI tests or with the sample photos

    @Test func neverInAUITest() async throws {
        #expect(refusal(try await applied(), situation: Policy.Situation(uiTest: true)) == .uiTest)
    }

    /// An App Review device trying "Mit Beispielfotos ausprobieren": as long as Albumist's sample
    /// photos are in the library (`SampleLibrary.Record.hasSamples`, also while they are added).
    @Test func neverWithTheSamplePhotosInTheLibrary() async throws {
        #expect(refusal(try await applied(), situation: Policy.Situation(samplePhotos: true)) == .samplePhotos)
        var record = SampleLibrary.Record()
        record.begin()
        #expect(record.hasSamples)
    }

    // MARK: Once per version, 120 days apart

    @Test func neverTwiceInTheSameVersion() async throws {
        let plan = try await applied()
        let state = Policy.State.asked(version: "1.0.0", at: now.addingTimeInterval(-400 * day))
        #expect(refusal(plan, state: state, version: "1.0.0") == .askedInThisVersion)
        #expect(refusal(plan, state: state, version: "1.1.0") == nil)
    }

    @Test func neverWithin120DaysOfTheLastQuestion() async throws {
        let plan = try await applied()
        #expect(Policy.daysBetweenQuestions == 120)
        let state = Policy.State.asked(version: "1.0.0", at: now)
        #expect(refusal(plan, state: state, version: "1.1.0", at: now.addingTimeInterval(1 * day)) == .askedRecently)
        #expect(refusal(plan, state: state, version: "1.1.0", at: now.addingTimeInterval(120 * day - 60)) == .askedRecently)
        #expect(refusal(plan, state: state, version: "1.1.0", at: now.addingTimeInterval(120 * day)) == nil)
    }

    /// A last question "in the future" (the clock was set back since): counts as recent. More
    /// than a day ahead it counts as asked today (`clockChecked`, stored by the app), so the 120
    /// days run from today instead of from a date that may lie years ahead.
    @Test func clockSetBackCountsAsRecent() async throws {
        let plan = try await applied()
        let state = Policy.State.asked(version: "1.0.0", at: now.addingTimeInterval(30 * day))
        #expect(refusal(plan, state: state, version: "1.1.0") == .askedRecently)
        let checked = state.clockChecked(now: now)
        #expect(checked == Policy.State.asked(version: "1.0.0", at: now))
        #expect(refusal(plan, state: checked, version: "1.1.0") == .askedRecently)
        #expect(refusal(plan, state: checked, version: "1.1.0", at: now.addingTimeInterval(120 * day)) == nil)
        // Unchecked, the date 30 days ahead would still hold it back then.
        #expect(refusal(plan, state: state, version: "1.1.0", at: now.addingTimeInterval(120 * day)) == .askedRecently)
        // Up to a day ahead stays as it is (time zones, a clock the network set right).
        let soon = Policy.State.asked(version: "1.0.0", at: now.addingTimeInterval(day - 60))
        #expect(soon.clockChecked(now: now) == soon)
        #expect(refusal(plan, state: soon, version: "1.1.0") == .askedRecently)
        // Never asked, or asked in the past: nothing to change.
        #expect(Policy.State().clockChecked(now: now) == Policy.State())
        let past = Policy.State.asked(version: "1.0.0", at: now.addingTimeInterval(-3 * day))
        #expect(past.clockChecked(now: now) == past)
    }

    // MARK: Stored state

    @Test func storedStateIsReadBack() throws {
        let state = Policy.State.asked(version: "1.2.0", at: now)
        #expect(Policy.State(stored: state.stored) == state)
        // Nothing stored, damage: never asked.
        #expect(Policy.State(stored: nil) == Policy.State())
        #expect(Policy.State(stored: Data("not json".utf8)) == Policy.State())
        // A value with only some fields (an older or newer version) keeps what it has.
        let partial = try JSONSerialization.data(withJSONObject: ["lastAskedVersion": "0.9.0", "future": true])
        #expect(Policy.State(stored: partial) == Policy.State(lastAskedVersion: "0.9.0"))
    }
}
