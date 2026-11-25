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
/// - Once: the first sight of the card decides, also when VoiceOver is off then or Albumist not
///   active (turning VoiceOver on later brings no old "fertig").
/// - Not beside the first 100 %, which says "Analyse fertig: 100 %" itself.
public struct FinishAnnouncement: Sendable, Equatable {
    /// The card shows a finish no notification said, and was not seen yet.
    public private(set) var owed = false
    /// The notification said the newest finish: its card stays silent.
    public private(set) var notified = false

    public init() {}

    /// The end of a run, before it waits for the overview (with `FinishMoment.runEnded`).
    /// `finished`: it finished the analysis; `celebrates`: "Analyse fertig" is due for it. Such a
    /// run brings a new finish, which no notification has said yet.
    public mutating func runEnded(finished: Bool, celebrates: Bool) {
        guard finished && celebrates else { return }
        notified = false
    }

    /// After the wait, with what `FinishMoment.afterWait` showed: `card`, the finish card (in
    /// the app, or for when the user comes back); `notification`, the notification "Analyse
    /// fertig" went out with it.
    public mutating func afterWait(card: Bool, notification: Bool) {
        if notification {
            notified = true
            owed = false
        } else if card && !notified {
            owed = true
        }
    }

    /// The card with "Analyse fertig" is seen for the first time for its finish. True: VoiceOver
    /// says "Analyse fertig" now. `voiceOver`: VoiceOver is on; `active`: Albumist is active;
    /// `saidByFirstMoment`: the first 100 % shows on the card and says it itself.
    public mutating func cardSeen(voiceOver: Bool, active: Bool, saidByFirstMoment: Bool) -> Bool {
        defer { owed = false }
        return owed && voiceOver && active && !saidByFirstMoment
    }
}
