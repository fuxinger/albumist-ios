import Foundation
import Testing
import AlbumistTestSupport

/// "Analyse fertig" for VoiceOver as the App wires it (design wave 3, H14; the rule is
/// `FinishAnnouncement`, tested in `FinishAnnouncementTests`). The card used to say it when its
/// state changed to "fertig", but the card is made anew between the run's end and "Analyse
/// fertig" (the done line stands there meanwhile), so only the first full analysis was heard
/// (DS-08's "Analyse fertig: 100 %"). Now the model tells a store outside the card whether the
/// notification said a finish or its card owes it, where the notification is decided, and the
/// finished card says it once, as its check mark plays. The App does not build on Linux, so
/// these tests read its code (`AppSource`).
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

    /// Said or owed is decided where the notification is decided (review S2 of H14): right after
    /// `FinishMoment.afterWait`, with what it showed, in the block that sends the notification
    /// and before the card is set. Decided at the end of the run instead, before the wait, a run
    /// that ended as the user left was said twice (owed in front, then the notification), and a
    /// check that ended in front after a finish overtaken in the background said nothing. Before
    /// the wait, next to `FinishMoment.runEnded`, the end of a run only tells that a new finish
    /// began, which no notification has said yet. Three marked lines in `AppModel.swift` for it
    /// (the third makes the store at launch, `iOSIsAskedAtLaunchAndOnceMoreAsTheNotificationGoesOut`),
    /// and five of the search's revision (review Q1 of round 3, pinned in `SearchTabSourceTests`):
    /// nothing else of H14 there.
    @Test func theModelDecidesWhereTheNotificationIsDecided() throws {
        let raw = try AppSource.read(Self.model)
        let model = try Self.code(Self.model)
        let run = try Self.body(["func startAnalysisNow("], in: model)
        // A new finish, before the wait, with `FinishMoment.runEnded`.
        #expect(AppSource.calls(of: "FinishAnnouncementStore.shared.runEnded(", in: run) == ["finished: end.isFinished, celebrates: celebrate"],
                "\(AppSource.calls(of: "FinishAnnouncementStore.shared.runEnded(", in: run))")
        let owed = try #require(run.range(of: "finishMoment.runEnded(finished: end.isFinished, celebrates: celebrate)"))
        let began = try #require(run.range(of: "FinishAnnouncementStore.shared.runEnded("), "the end of a run does not tell that a finish began")
        #expect(owed.upperBound < began.lowerBound)
        for later in ["endCard()", "await refreshDerived()", "finishMoment.afterWait("] {
            let at = try #require(run.range(of: later), "\(later)")
            #expect(began.upperBound < at.lowerBound, "told after \(later)")
        }
        // Said or owed: right after the wait, with what it showed, before the card and the
        // notification it decides with.
        let shown = try #require(run.range(of: "let shown = finishMoment.afterWait("))
        let decided = try #require(run.range(of: "FinishAnnouncementStore.shared.afterWait(shown)"), "not decided with the notification")
        let between = Self.squeezed(String(run[shown.upperBound..<decided.lowerBound]))
        #expect(between == "settled:settled.finishMoment,appActive:UIApplication.shared.applicationState==.active)", "\(between)")
        for later in ["if shown.card {", "if shown.notification { ContinuedAnalysis.notifyFinished("] {
            let at = try #require(run.range(of: later), "\(later)")
            #expect(decided.upperBound < at.lowerBound, "decided after \(later)")
        }
        #expect(!run.contains("inBackground"), "decided before the wait as well")
        #expect(model.components(separatedBy: "FinishAnnouncementStore").count - 1 == 3, "told from another place too")
        for call in ["FinishAnnouncementStore.shared.runEnded(", "FinishAnnouncementStore.shared.afterWait(", "_ = FinishAnnouncementStore.shared "] {
            let line = try #require(raw.split(separator: "\n").first { $0.contains(call) }, "\(call)")
            #expect(line.contains(Self.mark), "unmarked: \(line)")
        }
        #expect(raw.components(separatedBy: Self.mark).count - 1 == 3 + 5, "more of H14 in AppModel.swift")
    }

    /// The store lives outside the card (one per app), so the card made anew keeps what the end
    /// of the run said. It asks the rule with VoiceOver and whether the first 100 % says it
    /// ("Analyse fertig: 100 %", DS-08); then says "Analyse fertig" quietly, as the card's other
    /// announcements. Not whether Albumist is active: the card's claim needs it on screen
    /// (`AppModel.claimFinishMoment`), so the question was always answered yes (review S8 of H14).
    @Test func theStoreAsksTheRuleAndSaysItQuietly() throws {
        let card = try Self.code(Self.card)
        let store = try Self.body(["final class FinishAnnouncementStore"], in: card)
        #expect(store.contains("static let shared = FinishAnnouncementStore()"), "\(store)")
        #expect(store.contains("private var rule = FinishAnnouncement()"), "\(store)")
        let ended = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "func runEnded("], in: card))
        #expect(ended == "{rule.runEnded(finished:finished,celebrates:celebrates)}", "\(ended)")
        let shown = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "func afterWait(_ shown: FinishMoment.Shown)"], in: card))
        #expect(shown.hasPrefix("{rule.afterWait(card:shown.card,notification:shown.notification,"
                + "inBackground:UIApplication.shared.applicationState==.background,notificationsAllowed:notificationsAllowed)"), "\(shown)")
        let seen = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "func cardSeen()"], in: card))
        let question = "guardrule.cardSeen(voiceOver:UIAccessibility.isVoiceOverRunning,"
            + "saidByFirstMoment:FirstAnalysisMomentStore.shared.moment.shows(at:Date()))else{return}"
        let asks = try #require(seen.range(of: question), "\(seen)")
        let words = try #require(seen.range(of: "varspoken=AttributedString(String(localized:\"Analysefertig\"))"), "\(seen)")
        let quiet = try #require(seen.range(of: "spoken.accessibilitySpeechAnnouncementPriority=.low"), "\(seen)")
        let said = try #require(seen.range(of: "AccessibilityNotification.Announcement(spoken).post()"), "\(seen)")
        #expect(asks.upperBound <= words.lowerBound && words.upperBound <= quiet.lowerBound && quiet.upperBound <= said.lowerBound, "\(seen)")
    }

    /// A notification counts as said only where iOS shows it (review T1 of H14's round 2): with
    /// Albumist in the background as the moment decides, read in the same step as the model's
    /// `appActive` (inactive is not enough: in front of Control Centre, the app switcher, Siri or
    /// a system alert iOS hands the notification to Albumist, whose `willPresent` shows nothing),
    /// and with its notifications allowed. That is cached, read from iOS as the store is made (at
    /// launch) and each time Albumist becomes active (back from the Settings app, after iOS's
    /// question), so the decision after the wait does not wait for iOS; iOS's answer to the
    /// question asked once more right then decides (review Q2 of round 3,
    /// `iOSIsAskedAtLaunchAndOnceMoreAsTheNotificationGoesOut`). Only `.authorized` shows the
    /// notification at once: Albumist asks for alerts and sound, never for quiet (provisional)
    /// notifications.
    @Test func aNotificationCountsOnlyWhereIOSShowsIt() throws {
        let raw = try AppSource.read(Self.card)
        #expect(raw.contains("\nimport UserNotifications\n"), "the card's file does not import UserNotifications")
        let card = try Self.code(Self.card)
        let store = try Self.body(["final class FinishAnnouncementStore"], in: card)
        #expect(store.contains("private var notificationsAllowed = false"), "\(store)")
        #expect(store.contains("private var observers: [any NSObjectProtocol] = []"), "\(store)")
        let made = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "private init()"], in: card))
        #expect(made == "{readNotificationSettings()observers=[NotificationCenter.default.addObserver("
                + "forName:UIApplication.didBecomeActiveNotification,object:nil,queue:.main){[weakself]_in"
                + "MainActor.assumeIsolated{self?.readNotificationSettings()}},]}", "\(made)")
        let read = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "private func readNotificationSettings()"], in: card))
        #expect(read == "{Task{notificationsAllowed=awaitSelf.notificationsAllowedNow()}}", "\(read)")
        let now = Self.squeezed(try Self.body(["final class FinishAnnouncementStore",
                                               "nonisolated private static func notificationsAllowedNow() async -> Bool"], in: card))
        #expect(now == "{awaitUNUserNotificationCenter.current().notificationSettings().authorizationStatus==.authorized}", "\(now)")
        // What the rule rests on: in front, Albumist's notifications show nothing.
        let platform = try Self.code("App/Albumist/Platform/ContinuedAnalysis.swift")
        let present = Self.squeezed(try Self.body(["final class NotificationRouter", "willPresent notification: UNNotification"], in: platform))
        #expect(present == "{[]}", "notifications show in front of Albumist: \(present)")
    }

    /// Review Q2 of H14's round 3: the cached value is the one iOS gave when Albumist was last
    /// active. Turned off in Settings while Albumist was in the background, the notification
    /// counted as said, and nobody said the finish; and the store, made at the first run's end,
    /// could decide before iOS had answered the first time, so the finish was said twice. Now the
    /// store is made at launch, right after the first 100 %'s store and before anything else of
    /// the load (no run starts before it), so its first answer is long there; and where `afterWait`
    /// decides, iOS is asked once more and its answer decides either way
    /// (`FinishAnnouncement.notificationsAnswered`). It comes within milliseconds; the card is seen
    /// only while Albumist is active (`AppModel.claimFinishMoment`).
    @Test func iOSIsAskedAtLaunchAndOnceMoreAsTheNotificationGoesOut() throws {
        let raw = try AppSource.read(Self.model)
        let load = try Self.body(["private func load() async"], in: try Self.code(Self.model))
        let first = try #require(load.range(of: "FirstAnalysisMomentStore.shared.launched()"), "\(load)")
        let made = try #require(load.range(of: "_ = FinishAnnouncementStore.shared"), "the store is not made at launch: \(load)")
        #expect(load[first.upperBound..<made.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "something runs before the store is made: \(load)")
        let rest = load[made.upperBound...].prefix { $0 != "\n" }
        #expect(rest.trimmingCharacters(in: .whitespaces).isEmpty, "the store is not only made there: \(rest)")
        let line = try #require(raw.split(separator: "\n").first { $0.contains("_ = FinishAnnouncementStore.shared ") }, "\(raw.count)")
        #expect(line.hasPrefix("        _ = FinishAnnouncementStore.shared \(Self.mark)"), "\(line)")
        // Asked again where the notification is decided, and the answer told to the rule there only.
        let card = try Self.code(Self.card)
        let shown = Self.squeezed(try Self.body(["final class FinishAnnouncementStore", "func afterWait(_ shown: FinishMoment.Shown)"], in: card))
        #expect(shown == "{rule.afterWait(card:shown.card,notification:shown.notification,"
                + "inBackground:UIApplication.shared.applicationState==.background,notificationsAllowed:notificationsAllowed)"
                + "Task{notificationsAllowed=awaitSelf.notificationsAllowedNow()rule.notificationsAnswered(allowed:notificationsAllowed)}}",
                "\(shown)")
        #expect(card.components(separatedBy: "notificationsAnswered(").count - 1 == 1, "told from another place too")
        #expect(card.components(separatedBy: "Self.notificationsAllowedNow()").count - 1 == 2, "asked from another place too")
    }

    /// The finished card says it as its check mark is claimed, once per run (the claim is), also
    /// with Reduce Motion (only the bounce waits for motion). The card's own announcement of a
    /// changed state no longer says "fertig": it came only when the card was not made anew, and
    /// would say it a second time.
    @Test func theFinishedCardSaysItOnceAsItIsClaimed() throws {
        let card = try Self.code(Self.card)
        let play = Self.squeezed(try Self.body(["struct AnalysisFinishedView", "private func play()"], in: card))
        #expect(play == "{guardmodel.claimFinishMoment()else{return}FinishAnnouncementStore.shared.cardSeen()guard!reduceMotionelse{return}bounce+=1}",
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
