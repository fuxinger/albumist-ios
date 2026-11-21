import Foundation
import Testing
import AlbumistTestSupport

/// "Analyse fertig" for VoiceOver as the App wires it (design wave 3, H14; the rule is
/// `FinishAnnouncement`, tested in `FinishAnnouncementTests`). The card used to say it when its
/// state changed to "fertig", but the card is made anew between the run's end and "Analyse
/// fertig" (the done line stands there meanwhile), so only the first full analysis was heard
/// (DS-08's "Analyse fertig: 100 %"). Now the model tells a store outside the card how each run
/// ended, and the finished card says it once, as its check mark plays. The App does not build on
/// Linux, so these tests read its code (`AppSource`).
@Suite("Analyse fertig for VoiceOver in the App")
struct FinishAnnouncementSourceTests {
    static let model = "App/Albumist/Model/AppModel.swift"
    static let card = "App/Albumist/Views/AnalysisProgressCard.swift"
    static let mark = "// Design W3 H14"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ path: [String], in file: String) throws -> String {
        try #require(AppSource.body(of: path, in: file), "\(path) is not there")
    }

    /// `text` without any white space, so a check does not depend on how a line is broken.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The end of a run tells the store, with `FinishMoment` and before the wait for the
    /// overview, whether Albumist was in the background then (the notification says it there).
    /// One marked line in `AppModel.swift`, nothing else of H14 there.
    @Test func theModelTellsHowARunEnded() throws {
        let raw = try AppSource.read(Self.model)
        let model = try Self.code(Self.model)
        let run = try Self.body(["func startAnalysisNow("], in: model)
        let owed = try #require(run.range(of: "finishMoment.runEnded(finished: end.isFinished, celebrates: celebrate)"))
        let told = try #require(run.range(of: "FinishAnnouncementStore.shared.runEnded(finished: end.isFinished, celebrates: celebrate, inBackground: UIApplication.shared.applicationState == .background)"),
                                "the end of a run does not tell how it ended")
        #expect(owed.upperBound < told.lowerBound)
        for later in ["endCard()", "await refreshDerived()", "finishMoment.afterWait("] {
            let at = try #require(run.range(of: later), "\(later)")
            #expect(told.upperBound < at.lowerBound, "told after \(later)")
        }
        #expect(model.components(separatedBy: "FinishAnnouncementStore").count - 1 == 1, "told from another place too")
        let line = try #require(raw.split(separator: "\n").first { $0.contains("FinishAnnouncementStore.shared.runEnded(") })
        #expect(line.contains(Self.mark), "unmarked: \(line)")
        #expect(raw.components(separatedBy: Self.mark).count - 1 == 1, "more of H14 in AppModel.swift")
    }

    /// The store lives outside the card (one per app), so the card made anew keeps what the end
    /// of the run said. It asks the rule with VoiceOver, whether Albumist is active, and whether
    /// the first 100 % says it ("Analyse fertig: 100 %", DS-08); then says "Analyse fertig"
    /// quietly, as the card's other announcements.
    @Test func theStoreAsksTheRuleAndSaysItQuietly() throws {
        let card = try Self.code(Self.card)
        let store = try Self.body(["final class FinishAnnouncementStore"], in: card)
        #expect(store.contains("static let shared = FinishAnnouncementStore()"), "\(store)")
        #expect(store.contains("private var rule = FinishAnnouncement()"), "\(store)")
        let ended = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "func runEnded("], in: card))
        #expect(ended == "{rule.runEnded(finished:finished,celebrates:celebrates,inBackground:inBackground)}", "\(ended)")
        let seen = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "func cardSeen("], in: card))
        let asks = try #require(seen.range(of: "guardrule.cardSeen(voiceOver:UIAccessibility.isVoiceOverRunning,active:active,saidByFirstMoment:FirstAnalysisMomentStore.shared.moment.shows(at:Date()))else{return}"),
                                "\(seen)")
        let words = try #require(seen.range(of: "varspoken=AttributedString(String(localized:\"Analysefertig\"))"), "\(seen)")
        let quiet = try #require(seen.range(of: "spoken.accessibilitySpeechAnnouncementPriority=.low"), "\(seen)")
        let said = try #require(seen.range(of: "AccessibilityNotification.Announcement(spoken).post()"), "\(seen)")
        #expect(asks.upperBound <= words.lowerBound && words.upperBound <= quiet.lowerBound && quiet.upperBound <= said.lowerBound, "\(seen)")
    }

    /// The finished card says it as its check mark is claimed, once per run (the claim is), also
    /// with Reduce Motion (only the bounce waits for motion). The card's own announcement of a
    /// changed state no longer says "fertig": it came only when the card was not made anew, and
    /// would say it a second time.
    @Test func theFinishedCardSaysItOnceAsItIsClaimed() throws {
        let card = try Self.code(Self.card)
        let play = Self.squeezed(try Self.body(["struct AnalysisFinishedView", "private func play()"], in: card))
        #expect(play == "{guardmodel.claimFinishMoment()else{return}FinishAnnouncementStore.shared.cardSeen(active:model.isOnScreen)guard!reduceMotionelse{return}bounce+=1}",
                "\(play)")
        let announcement = Self.squeezed(try Self.body(["struct AnalysisProgressCard", "private var announcement: String?"], in: card))
        #expect(announcement.contains("case.finished:nil"), "\(announcement)")
        #expect(card.components(separatedBy: "FinishAnnouncementStore.shared.cardSeen(").count - 1 == 1)
        #expect(card.components(separatedBy: "AccessibilityNotification.Announcement(").count - 1 == 2, "said from another place too")
        // Nowhere else in the App.
        for path in AppSource.swiftFiles(under: "App/Albumist") where path != Self.card && path != Self.model {
            #expect(!(try Self.code(path)).contains("FinishAnnouncement"), "\(path)")
        }
    }
}
