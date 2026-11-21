import Foundation

/// "Analyse fertig" for VoiceOver (design wave 3, H14): said once for each run that finished the
/// analysis while Albumist was in front, as the user first sees its "Analyse fertig" with
/// VoiceOver on; the check mark and the success tap of that card come at the same moment
/// (`FinishMoment.claim`).
///
/// Before, the card said it only when its state changed to "fertig", and the card is made anew
/// between the end of a run and "Analyse fertig" (the done line stands there meanwhile): only
/// the first full analysis was heard, through its own "Analyse fertig: 100 %" (DS-08,
/// `FirstAnalysisMoment`). So the end of the run is told here, outside the card, and the card
/// asks when it is first seen.
///
/// - Only a run that finished the analysis and celebrates (`AnalysisCardState.celebratesFinish`:
///   a wait of 30 s and more): never the check for new photos ("Sucht neue Fotos"). A short run
///   that slips in after a long one leaves the long one's due, as its card does.
/// - Never a run that ended in the background: the notification says it there.
/// - Once: the first sight of the card decides, also when VoiceOver is off then or Albumist not
///   active (turning VoiceOver on later brings no old "fertig").
/// - Not beside the first 100 %, which says "Analyse fertig: 100 %" itself.
public struct FinishAnnouncement: Sendable, Equatable {
    /// A run finished the analysis in front and celebrates; its card was not seen yet.
    public private(set) var owed = false

    public init() {}

    /// The end of a run, decided before it waits for the overview (with `FinishMoment.runEnded`).
    /// `finished`: it finished the analysis; `celebrates`: "Analyse fertig" is owed for it;
    /// `inBackground`: Albumist was in the background as it ended.
    public mutating func runEnded(finished: Bool, celebrates: Bool, inBackground: Bool) {
        guard finished && celebrates else { return }
        owed = !inBackground
    }

    /// The card with "Analyse fertig" is seen for the first time for its run. True: VoiceOver says
    /// "Analyse fertig" now. `voiceOver`: VoiceOver is on; `active`: Albumist is active;
    /// `saidByFirstMoment`: the first 100 % shows on the card and says it itself.
    public mutating func cardSeen(voiceOver: Bool, active: Bool, saidByFirstMoment: Bool) -> Bool {
        defer { owed = false }
        return owed && voiceOver && active && !saidByFirstMoment
    }
}
