import Foundation

/// "Analyse fertig" for VoiceOver (design wave 3, H14): said once for each finish of the
/// analysis that no notification said, as the user first sees its "Analyse fertig" with
/// VoiceOver on; the check mark and the success tap of that card come at the same moment
/// (`FinishMoment.claim`).
///
/// Before, the card said it only when its state changed to "fertig", and the card is made anew
/// between the end of a run and "Analyse fertig" (the done line stands there meanwhile): only
/// the first full analysis was heard, through its own "Analyse fertig: 100 %" (DS-08,
/// `FirstAnalysisMoment`). So the finish is told here, outside the card, and the card asks when
/// it is first seen.
///
/// - Decided where the notification is decided (review S2 of H14): after the run's wait for the
///   overview, with what `FinishMoment.afterWait` showed. The notification went out: said there.
///   The card shows a finish no notification said: owed. Decided as the run ended, before the
///   wait, a run that ended as the user left was said twice (in front then, the notification
///   after the wait), and a finish overtaken in the background, then shown in front at the end
///   of the check after it, by nobody.
/// - Only a finish of a run that celebrates (`AnalysisCardState.celebratesFinish`: a wait of
///   30 s and more): never the check for new photos ("Sucht neue Fotos") alone. A short run that
///   slips in after a long one shows the long one's finish, as its card does.
/// - Once: the first sight of the card decides, also when VoiceOver is off then (turning
///   VoiceOver on later brings no old "fertig"). The card is seen only while Albumist is on
///   screen (`AppModel.claimFinishMoment`), so whether it is active is not asked (review S8).
/// - Not beside the first 100 %, which says "Analyse fertig: 100 %" itself.
/// - A notification says it only where iOS shows it (review T1 of H14's round 2): Albumist in
///   the background as the moment decides, not only inactive (in front of Control Centre, the
///   app switcher, Siri or a system alert iOS hands it to Albumist, whose `willPresent` shows
///   nothing), and its notifications allowed. Otherwise the card owes it.
/// - Whether they are allowed is asked of iOS once more as the notification goes out, and that
///   answer decides (`notificationsAnswered`, review Q2 of H14's round 3): the value the end of
///   the run decides with is the one iOS gave when Albumist was last active, and the setting can
///   change while Albumist is in the background.
public struct FinishAnnouncement: Sendable, Equatable {
    /// The card shows a finish no notification said, and was not seen yet.
    public private(set) var owed = false
    /// iOS showed the notification of the newest finish: its card stays silent.
    public private(set) var notified = false
    /// The notification of the newest finish went out with Albumist in the background, and iOS's
    /// answer whether it may show it is still to come (`notificationsAnswered`): whether the card
    /// shows that finish. `nil`: no answer awaited (none asked, the card seen since, or a new
    /// finish began).
    private var awaited: Bool?

    public init() {}

    /// The end of a run, before it waits for the overview (with `FinishMoment.runEnded`).
    /// `finished`: it finished the analysis; `celebrates`: "Analyse fertig" is due for it. Such a
    /// run brings a new finish, which no notification has said yet.
    public mutating func runEnded(finished: Bool, celebrates: Bool) {
        guard finished && celebrates else { return }
        notified = false
        awaited = nil
    }

    /// After the wait, with what `FinishMoment.afterWait` showed: `card`, the finish card (in
    /// the app, or for when the user comes back); `notification`, the notification "Analyse
    /// fertig" went out with it (once per finish, `FinishMoment`). iOS shows it only when
    /// `inBackground` (Albumist was in the background as the moment decided, not only inactive)
    /// and `notificationsAllowed` (as iOS last said); otherwise nobody heard it, and the card owes
    /// it. Sent in the background, iOS's answer to the question asked again decides
    /// (`notificationsAnswered`).
    public mutating func afterWait(card: Bool, notification: Bool, inBackground: Bool, notificationsAllowed: Bool) {
        let sentInBackground = notification && inBackground
        awaited = sentInBackground ? card : nil
        if sentInBackground && notificationsAllowed {
            notified = true
            owed = false
        } else if card && !notified {
            owed = true
        }
    }

    /// iOS answers whether Albumist's notifications are allowed (`allowed`), asked once more as
    /// the notification of the newest finish went out with Albumist in the background. The answer
    /// decides either way: not allowed, iOS showed nothing, and the card owes the finish again;
    /// allowed although `afterWait` was told no (iOS had not answered the first time yet, or they
    /// were turned on meanwhile), the notification said it, and the card stays silent, so it is
    /// not said twice. Nothing once the card was seen (its first sight decided), after a new
    /// finish began, or where no answer is awaited (in front, only inactive, answered already).
    public mutating func notificationsAnswered(allowed: Bool) {
        guard let card = awaited else { return }
        awaited = nil
        notified = allowed
        if allowed {
            owed = false
        } else if card {
            owed = true
        }
    }

    /// The card with "Analyse fertig" is seen for the first time for its finish. True: VoiceOver
    /// says "Analyse fertig" now. `voiceOver`: VoiceOver is on; `saidByFirstMoment`: the first
    /// 100 % shows on the card and says it itself.
    public mutating func cardSeen(voiceOver: Bool, saidByFirstMoment: Bool) -> Bool {
        defer {
            owed = false
            awaited = nil
        }
        return owed && voiceOver && !saidByFirstMoment
    }
}
