import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// X9 as the App wires it (verification review X9, the lead's decision): a first analysis that ran
/// in legs (paused, cut off by iOS, closed and gone on later) is one wait for "Analyse fertig" and
/// its 100 %. The rule is `FirstAnalysisLegs` (tested in `FirstAnalysisLegsTests`); the model tells
/// where a run starts, works and ends, and the moment's store keeps the legs beside the moment
/// (`FirstAnalysisMomentStore`). The App does not build on Linux, so these tests read its code
/// (`AppSource`, with the paths and helpers of `FirstAnalysisMomentSourceTests`). A first analysis
/// in legs on the iPhone, closed and killed in between, is a device check.
@Suite("First analysis in legs in the App (X9)")
struct FirstAnalysisLegsSourceTests {
    typealias Source = FirstAnalysisMomentSourceTests

    /// The legs of the first analysis count together for its first completion (verification review
    /// X9, `FirstAnalysisLegs`): the model tells where a run starts (with its clock, after the
    /// resume position was read), while it works (with each report, as the resume position is
    /// written) and as it ends, before "Analyse fertig" is decided, which is decided on what the
    /// legs counted, for every follower of `celebrate` alike.
    @Test func theModelCountsTheLegsOfTheFirstAnalysis() throws {
        let model = try Source.code(Source.model)
        let run = try Source.body(["func startAnalysisNow("], in: model)
        let resume = try #require(run.range(of: "analysis.resumeFrom = AnalysisMarker.unfinished"), "\(run)")
        let begin = try #require(run.range(of: "beginCard()"), "\(run)")
        #expect(resume.upperBound < begin.lowerBound, "the leg starts before the resume position is read")
        let card = try Source.body(["private func beginCardNow()"], in: model)
        let clock = try #require(card.range(of: "runClockStart = .now"), "\(card)")
        let started = try #require(card.range(of: "firstAnalysisLegStarted()"), "no leg starts with the run: \(card)")
        #expect(clock.upperBound < started.lowerBound, "\(card)")
        let receive = try Source.body(["private func receive("], in: model)
        let marker = try #require(receive.range(of: "AnalysisMarker.unfinished = .init("), "\(receive)")
        let runs = try #require(receive.range(of: "firstAnalysisLegRuns(since: runClockStart, showedBar: runShowedBar)"),
                                "the legs are not kept with the resume position: \(receive)")
        #expect(marker.upperBound < runs.lowerBound, "\(receive)")
        let leg = try #require(run.range(of: "let leg = firstAnalysisLeg(ended: end.isFinished, since: runClockStart, showedBar: runShowedBar)"),
                               "the end is decided without the legs: \(run)")
        let decided = try #require(run.range(of: "let celebrate = AnalysisCardState.celebratesFinish(isComplete: end.isFinished,"), "\(run)")
        #expect(leg.upperBound < decided.lowerBound, "\(run)")
        let rule = run[decided.upperBound...].prefix(260)
        #expect(rule.contains("wasQuickCheck: !leg.showedBar,") && rule.contains("ranFor: .seconds(leg.seconds))"), "\(rule)")
        #expect(!run.contains("wasQuickCheck: !runShowedBar"), "the run is decided alone: \(run)")
        // "Analyse fertig", its notification, VoiceOver's word and the 100 % all follow `celebrate`.
        for follower in ["finishMoment.runEnded(finished: end.isFinished, celebrates: celebrate)",
                         "firstAnalysisRunEnded(finished: end.isFinished, celebrates: celebrate)",
                         "FinishAnnouncementStore.shared.runEnded(finished: end.isFinished, celebrates: celebrate,"] {
            let told = try #require(run.range(of: follower), "\(follower)")
            #expect(decided.upperBound < told.lowerBound, "\(follower)")
        }
        // A leg of the first analysis while no analysis was completed, going on from the resume position.
        let store = try Source.code(Source.store)
        let begun = try Source.body(["extension AppModel", "func firstAnalysisLegStarted()"], in: store)
        #expect(begun.contains("legStarted(firstAnalysis: !AnalysisMarker.completedOnce, goesOn: analysis.resumeFrom != nil)"), "\(begun)")
        let start = try Source.body(["final class FirstAnalysisMomentStore", "func legStarted(firstAnalysis: Bool, goesOn: Bool)"], in: store)
        #expect(start.contains("legs.started(firstCompletion: firstAnalysis && moment.firstCompletionAhead, goesOn: goesOn)"), "\(start)")
    }

    /// The legs live in `UserDefaults` beside the moment, under keys of their own: read at launch
    /// (none for a test that starts the moment afresh), written exactly as a run starts and ends
    /// and at most once a second while it works, gone once the first completion came, also
    /// overnight (`completedAway`). Not observed: the ring card reads only the moment.
    @Test func theLegsAreKeptBesideTheMoment() throws {
        let store = try Source.code(Source.store)
        let type = try Source.body(["final class FirstAnalysisMomentStore"], in: store)
        #expect(type.contains("private static let legSecondsKey = \"analysis.firstFinishMoment.legSeconds\""), "\(type)")
        #expect(type.contains("private static let legBarKey = \"analysis.firstFinishMoment.legBar\""), "\(type)")
        #expect(type.contains("@ObservationIgnored private var legs = FirstAnalysisLegs()"), "\(type)")
        let initializer = try Source.body(["final class FirstAnalysisMomentStore", "private init()"], in: store)
        #expect(initializer.contains("let legSeconds = fresh ? 0 : UserDefaults.standard.double(forKey: Self.legSecondsKey)"), "\(initializer)")
        #expect(initializer.contains("let legBar = !fresh && UserDefaults.standard.bool(forKey: Self.legBarKey)"), "\(initializer)")
        let read = try #require(initializer.range(of: "legs = FirstAnalysisLegs(kept: FirstAnalysisLegs.Leg(seconds: legSeconds, showedBar: legBar),"),
                                "\(initializer)")
        let lapse = try #require(initializer.range(of: "moment.lapse(at: Date())"), "\(initializer)")
        let kept = try #require(initializer.range(of: "keep()"), "\(initializer)")
        #expect(lapse.upperBound < read.lowerBound && read.upperBound < kept.lowerBound, "\(initializer)")
        #expect(initializer.contains("firstCompletionAhead: moment.firstCompletionAhead)"), "\(initializer)")
        let works = try Source.body(["final class FirstAnalysisMomentStore", "func legRuns(_ leg: FirstAnalysisLegs.Leg)"], in: store)
        #expect(works.contains("guard legs.counting else { return }") && works.contains("keepLegs(exactly: false)"), "\(works)")
        let ended = try Source.body(["final class FirstAnalysisMomentStore", "func legEnded(_ leg: FirstAnalysisLegs.Leg, finished: Bool)"], in: store)
        #expect(ended.contains("legs.ended(leg, finished: finished)") && ended.contains("keepLegs(exactly: true)"), "\(ended)")
        let written = try Source.body(["final class FirstAnalysisMomentStore", "private func keepLegs(exactly: Bool)"], in: store)
        #expect(written.contains("exactly ? seconds != stored : abs(seconds - stored) >= 1"), "\(written)")
        #expect(written.contains("UserDefaults.standard.removeObject(forKey: Self.legSecondsKey)"), "\(written)")
        let keep = try Source.body(["final class FirstAnalysisMomentStore", "private func keep()"], in: store)
        #expect(keep.contains("keepLegs(exactly: true)"), "\(keep)")
        let away = try Source.body(["final class FirstAnalysisMomentStore", "func completedAway(first: Bool)"], in: store)
        let dropped = try #require(away.range(of: "legs.drop()"), "the legs outlive an overnight completion: \(away)")
        let keptAway = try #require(away.range(of: "keep()"), "\(away)")
        #expect(dropped.upperBound < keptAway.lowerBound, "\(away)")
    }
}
