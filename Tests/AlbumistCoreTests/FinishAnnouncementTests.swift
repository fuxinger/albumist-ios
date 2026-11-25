import Testing
@testable import AlbumistCore

/// "Analyse fertig" for VoiceOver (design wave 3, H14): said once for each finish of the analysis
/// no notification said, when its card is first seen with VoiceOver on; never for the check for
/// new photos alone, never twice for one finish, and not beside the first 100 %, which says
/// "Analyse fertig: 100 %" itself (DS-08). Decided where the notification is decided (review S2
/// of H14): after the run's wait, with what `FinishMoment.afterWait` showed, here written out as
/// `FinishMomentTests` shows it (`shownInFront`, `notified`, `overtaken`).
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
        rule.afterWait(card: true, notification: false)
    }

    /// After the wait, Albumist not in front: the card for later, and the notification.
    private static func notified(_ rule: inout FinishAnnouncement) {
        rule.afterWait(card: true, notification: true)
    }

    /// After the wait, a newer run started meanwhile, or nothing was owed: nothing shows.
    private static func overtaken(_ rule: inout FinishAnnouncement) {
        rule.afterWait(card: false, notification: false)
    }

    /// The first sight of the card, with VoiceOver on and Albumist active.
    private static func seen(_ rule: inout FinishAnnouncement, voiceOver: Bool = true, active: Bool = true,
                             saidByFirstMoment: Bool = false) -> Bool {
        rule.cardSeen(voiceOver: voiceOver, active: active, saidByFirstMoment: saidByFirstMoment)
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

    /// VoiceOver off or Albumist not active as the card is first seen: not said, and not later
    /// either (turning VoiceOver on does not bring an old "fertig").
    @Test func onlyWithVoiceOverWhileActiveAndNotLater() {
        var rule = FinishAnnouncement()
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        #expect(!Self.seen(&rule, voiceOver: false))
        #expect(!Self.seen(&rule))
        Self.longRunEnded(&rule)
        Self.shownInFront(&rule)
        #expect(!Self.seen(&rule, active: false))
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
}
