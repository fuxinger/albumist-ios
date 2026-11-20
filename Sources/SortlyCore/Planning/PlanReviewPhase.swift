/// What the plan preview ("Vorschau") is showing, so its title fits (review P3-15: the title
/// said "Vorschau" during the sorting show and over the result too). The App gives each phase
/// its words (`PlanReviewView`).
public enum PlanReviewPhase: Hashable, Sendable {
    /// Nothing runs and no result is shown: what would change ("Vorschau").
    case preview
    /// The previewed plan runs, with or without the sorting show ("Alben werden angelegt").
    case creating
    /// Another plan runs here: the undo of the result shown, or an interrupted plan continued
    /// from the overview. It may remove albums, so it says "Alben werden geändert".
    case changing
    /// A run ended and its result is shown ("Ergebnis"; the card says how it went).
    case result

    /// `runningPlan`: the plan of the current or last run (`ExecutionState.planID`).
    /// `previewedPlan`: the plan the preview shows (its own, `PlanReviewView`).
    /// `hasResult`: a finished run's result is there (`ExecutionState.finished`).
    public init(running: Bool, runningPlan: SortlyID?, previewedPlan: SortlyID?, hasResult: Bool) {
        if running {
            self = runningPlan != nil && runningPlan == previewedPlan ? .creating : .changing
        } else if hasResult {
            self = .result
        } else {
            self = .preview
        }
    }
}
