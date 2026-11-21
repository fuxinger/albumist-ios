import Testing
@testable import AlbumistCore

/// "Analyse fertig" for VoiceOver (design wave 3, H14): said once per run that finished the
/// analysis while Albumist was in front, when its card is first seen with VoiceOver on; never
/// for the check for new photos, never twice for one run, never for a run that ended in the
/// background (the notification says it there), and not beside the first 100 %, which says
/// "Analyse fertig: 100 %" itself (DS-08).
@Suite("Analyse fertig for VoiceOver")
struct FinishAnnouncementTests {
    /// A run that ended and the first sight of its card, with VoiceOver on and Albumist active.
    private static func seen(_ rule: inout FinishAnnouncement, voiceOver: Bool = true, active: Bool = true,
                             saidByFirstMoment: Bool = false) -> Bool {
        rule.cardSeen(voiceOver: voiceOver, active: active, saidByFirstMoment: saidByFirstMoment)
    }

    @Test func aRunWatchedToItsEndIsSaidOnce() {
        var rule = FinishAnnouncement()
        #expect(!rule.owed)
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        #expect(rule.owed)
        #expect(Self.seen(&rule))
        // The card made anew, another return to the overview: never twice for one run.
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
    }

    @Test func eachFinishedRunIsSaidOnce() {
        var rule = FinishAnnouncement()
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        #expect(Self.seen(&rule))
        // The next full analysis, later ("Analyse neu aufbauen", another part of the library).
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        #expect(Self.seen(&rule))
    }

    /// "Sucht neue Fotos" and any run too short to celebrate (`celebratesFinish`) say nothing;
    /// one that slips in after a long run leaves the long run's due.
    @Test func neverForTheCheckForNewPhotos() {
        var rule = FinishAnnouncement()
        rule.runEnded(finished: true, celebrates: false, inBackground: false)
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        rule.runEnded(finished: true, celebrates: false, inBackground: false)
        #expect(Self.seen(&rule))
    }

    /// Paused, stopped or with work left: nothing is owed, and a long run's due stays until a
    /// run finishes the analysis and its card shows (`FinishMoment`).
    @Test func onlyARunThatFinishedTheAnalysis() {
        var rule = FinishAnnouncement()
        rule.runEnded(finished: false, celebrates: true, inBackground: false)
        #expect(!rule.owed)
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        rule.runEnded(finished: false, celebrates: false, inBackground: false)
        #expect(rule.owed)
    }

    /// Ended in the background: the notification says it; the card the user comes back to stays
    /// silent. A run that ends in the background after one still owed is the one the card is
    /// for: silent too.
    @Test func neverForARunThatEndedInTheBackground() {
        var rule = FinishAnnouncement()
        rule.runEnded(finished: true, celebrates: true, inBackground: true)
        #expect(!rule.owed)
        #expect(!Self.seen(&rule))
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        rule.runEnded(finished: true, celebrates: true, inBackground: true)
        #expect(!Self.seen(&rule))
    }

    /// VoiceOver off or Albumist not active as the card is first seen: not said, and not later
    /// either (turning VoiceOver on does not bring an old "fertig").
    @Test func onlyWithVoiceOverWhileActiveAndNotLater() {
        var rule = FinishAnnouncement()
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        #expect(!Self.seen(&rule, voiceOver: false))
        #expect(!Self.seen(&rule))
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        #expect(!Self.seen(&rule, active: false))
        #expect(!Self.seen(&rule))
    }

    /// The first 100 % says "Analyse fertig: 100 %" itself (DS-08): not twice.
    @Test func notBesideTheFirstHundredPercent() {
        var rule = FinishAnnouncement()
        rule.runEnded(finished: true, celebrates: true, inBackground: false)
        #expect(!Self.seen(&rule, saidByFirstMoment: true))
        #expect(!Self.seen(&rule))
    }
}
