import Testing
@testable import AlbumistCore

/// "Analyse fertig" for VoiceOver (design wave 3, H14): said once for each finish of the analysis
/// no notification said, when its card is first seen with VoiceOver on; never for the check for
/// new photos alone, never twice for one finish, and not beside the first 100 %, which says
/// "Analyse fertig: 100 %" itself (DS-08). Decided where the notification is decided (review S2
/// of H14): after the run's wait, with what `FinishMoment.afterWait` showed, here written out as
/// `FinishMomentTests` shows it (`shownInFront`, `notified`, `overtaken`). A notification counts
/// only where iOS shows it: Albumist in the background, not only inactive, and its notifications
/// allowed (review T1 of H14's round 2).
@Suite("Analyse fertig for VoiceOver")
struct FinishAnnouncementTests {
    /// The end of a long run that finished the analysis (`celebratesFinish`), before its wait.
    private static func longRunEnded(_ rule: inout FinishAnnouncement) {
        rule.runEnded(finished: true, celebrates: true)
    }

    /// The end of the check for new photos ("Sucht neue Fotos"), which never celebrates.
    private static func checkEnded(_ rule: inout FinishAnnouncement) {
        rule.runEnded(finished: true, celebrates: false)
    }

    /// After the wait, Albumist in front: the finish card, no notification.
    private static func shownInFront(_ rule: inout FinishAnnouncement) {
        rule.afterWait(card: true, notification: false, inBackground: false, notificationsAllowed: true)
    }

    /// After the wait, Albumist in the background with its notifications allowed: the card for
    /// later, and the notification, which iOS shows.
    private static func notified(_ rule: inout FinishAnnouncement) {
        rule.afterWait(card: true, notification: true, inBackground: true, notificationsAllowed: true)
    }

    /// After the wait, Albumist inactive (Control Centre or Notification Centre pulled down, the
    /// app switcher, Siri, a system alert, the moment of leaving): the notification goes out, but
    /// iOS hands it to Albumist, whose `willPresent` shows nothing.
    private static func notifiedWhileInactive(_ rule: inout FinishAnnouncement) {
        rule.afterWait(card: true, notification: true, inBackground: false, notificationsAllowed: true)
    }

    /// After the wait, Albumist in the background, its notifications turned off: the notification
    /// goes out, and iOS shows nothing.
    private static func notifiedWithNotificationsOff(_ rule: inout FinishAnnouncement) {
        rule.afterWait(card: true, notification: true, inBackground: true, notificationsAllowed: false)
    }

    /// After the wait, a newer run started meanwhile, or nothing was owed: nothing shows.
    private static func overtaken(_ rule: inout FinishAnnouncement) {
        rule.afterWait(card: false, notification: false, inBackground: false, notificationsAllowed: true)
    }

    /// The first sight of the card, with VoiceOver on. Always while Albumist is on screen (the
    /// card's claim, `AppModel.claimFinishMoment`), so the rule does not ask (review S8 of H14).
    private static func seen(_ rule: inout FinishAnnouncement, voiceOver: Bool = true,
                             saidByFirstMoment: Bool = false) -> Bool {
        rule.cardSeen(voiceOver: voiceOver, saidByFirstMoment: saidByFirstMoment)
    }

    @Test func aRunWatchedToItsEndIsSaidOnce() {
        var rule = FinishAnnouncement()
        #expect(!rule.owed)
        Self.longRunEnded(&rule)
        // Not before its wait: only what the wait showed decides.
        #expect(!rule.owed)
        Self.shownInFront(&rule)
        #expect(rule.owed)
        #expect(Self.seen(&rule))
        // The card made anew, another return to the overview: never twice for one finish.
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
    }

    @Test func eachFinishedRunIsSaidOnce() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        #expect(Self.seen(&rule))
        // The next full analysis, later ("Analyse neu aufbauen", another part of the library).
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        #expect(Self.seen(&rule))
    }

    /// "Sucht neue Fotos" alone shows nothing and says nothing; one that slips in after a long
    /// run shows the long run's finish, which is owed as long as no notification said it.
    @Test func neverForTheCheckForNewPhotos() {
        var rule = FinishAnnouncement()
        Self.checkEnded(&rule)
        Self.overtaken(&rule)
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        Self.checkEnded(&rule)
        Self.shownInFront(&rule)
        #expect(Self.seen(&rule))
    }

    /// Ended in the background: the notification says it, and the card the user comes back to
    /// stays silent, also when a check ends in front before it is seen.
    @Test func notWhereTheNotificationSaidIt() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.notified(&rule)
        #expect(!rule.owed)
        Self.checkEnded(&rule)
        Self.shownInFront(&rule)
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
        // A card shown in front, then the notification for a newer finish before it was seen:
        // said once, by the notification.
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        Self.longRunEnded(&rule)
        Self.notified(&rule)
        #expect(!Self.seen(&rule))
    }

    /// The review's case (a): a long analysis ends just as the user leaves. Before, Albumist was
    /// still in front as the run ended (owed), in the background after the wait (the
    /// notification): said twice. Now only what the wait showed counts: said once.
    @Test func aRunThatEndsAsTheUserLeavesIsSaidOnce() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.notified(&rule)
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
    }

    /// The review's case (b): a long run ends in front, a newer run overtakes its wait, the user
    /// leaves, and that check ends in the background and sends the notification for the finish.
    /// Before, the check left the long run's "owed" as it was: said twice. Now silent.
    @Test func aFinishOvertakenInFrontAndToldOutsideIsSaidOnce() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.overtaken(&rule)
        Self.checkEnded(&rule)
        Self.notified(&rule)
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
    }

    /// The review's case (c): a long run ends in the background and is overtaken the same way,
    /// and the check after it ends in front and shows the card, with no notification. Before,
    /// nobody said it. Now the card does.
    @Test func aFinishOvertakenInTheBackgroundAndShownInFrontIsSaid() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.overtaken(&rule)
        Self.checkEnded(&rule)
        Self.shownInFront(&rule)
        #expect(rule.owed)
        #expect(Self.seen(&rule))
    }

    /// A finish the notification said, then a newer one shown in front: the newer one is owed
    /// (a new finish clears what the notification said).
    @Test func aNewFinishIsOwedAfterOneTheNotificationSaid() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.notified(&rule)
        Self.longRunEnded(&rule)
        Self.overtaken(&rule)
        Self.checkEnded(&rule)
        Self.shownInFront(&rule)
        #expect(Self.seen(&rule))
    }

    /// Paused, stopped or with work left: nothing new is owed, and a finish shown before stays
    /// owed until its card is seen.
    @Test func onlyARunThatFinishedTheAnalysis() {
        var rule = FinishAnnouncement()
        rule.runEnded(finished: false, celebrates: true)
        Self.overtaken(&rule)
        #expect(!rule.owed)
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        rule.runEnded(finished: false, celebrates: false)
        Self.overtaken(&rule)
        #expect(rule.owed)
    }

    /// VoiceOver off as the card is first seen: not said, and not later either (turning
    /// VoiceOver on does not bring an old "fertig").
    @Test func onlyWithVoiceOverAndNotLater() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        #expect(!Self.seen(&rule, voiceOver: false))
        #expect(!Self.seen(&rule))
    }

    /// The first 100 % says "Analyse fertig: 100 %" itself (DS-08): not twice.
    @Test func notBesideTheFirstHundredPercent() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        #expect(!Self.seen(&rule, saidByFirstMoment: true))
        #expect(!Self.seen(&rule))
    }

    /// Review T1 of H14's round 2: a long run ends while Albumist is inactive (Control Centre
    /// pulled down, the app switcher, Siri, or the moment of leaving in S2's case (a)). Its
    /// notification went out, but iOS showed nothing: the card owes it and says it once
    /// Albumist is active again. Before, the notification counted as said, and nobody said it.
    /// A check that ends after it in the background shows the card again without a second
    /// notification (`FinishMoment` sends one per finish): still owed, said once.
    @Test func aNotificationSentWhileInactiveLeavesTheCardOwing() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.notifiedWhileInactive(&rule)
        #expect(rule.owed)
        #expect(Self.seen(&rule))
        #expect(!Self.seen(&rule))
        Self.longRunEnded(&rule)
        Self.notifiedWhileInactive(&rule)
        Self.checkEnded(&rule)
        rule.afterWait(card: true, notification: false, inBackground: true, notificationsAllowed: true)
        #expect(rule.owed)
        #expect(Self.seen(&rule))
        #expect(!Self.seen(&rule))
    }

    /// With Albumist's notifications turned off the notification goes out and iOS shows nothing:
    /// the card owes the finish (before H14 nobody said it then either). Allowed again (back from
    /// the Settings app), the next finish is the notification's.
    @Test func withNotificationsOffTheCardOwesIt() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.notifiedWithNotificationsOff(&rule)
        #expect(rule.owed)
        #expect(Self.seen(&rule))
        #expect(!Self.seen(&rule))
        Self.longRunEnded(&rule)
        Self.notified(&rule)
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
    }
}
