/// Whether a preview's plan still fits Photos (`PlanReviewView`). A run that ended after the
/// plan was made may have done part of it already, and running the plan then makes an album a
/// second time (second review of design wave 1, 20.11.: a preview of picks left open on
/// "Vorschläge" still offered an album that "Album anlegen" had made on "Start" meanwhile).
///
/// The model counts the runs that ended (`AppModel.runsEnded`). The preview notes the count
/// when its plan is made, and the plan is stale once another run ended. Its own run does not
/// make it stale: the result takes its place.
public struct PlanFreshness: Hashable, Sendable {
    /// The runs that had ended when the plan was made; nil while no plan was made.
    private var madeAfter: Int?
    /// The plan was handed to its run ("Jetzt anlegen").
    private var handedOver = false

    public init() {}

    /// The plan was made, after `runsEnded` runs had ended: the count read before it was made,
    /// so a run that ends while it is made counts as later.
    public mutating func made(after runsEnded: Int) {
        madeAfter = runsEnded
        handedOver = false
    }

    /// "Jetzt anlegen": the plan goes to its run, and runs that end now do not make it stale.
    public mutating func handOver() {
        handedOver = true
    }

    /// The run did not take the plan (refused, or another plan had the turn): it is as before,
    /// and a run that ended meanwhile makes it stale.
    public mutating func notTaken() {
        handedOver = false
    }

    /// The plan may plan what a run that ended after it was made did already.
    public func isStale(runsEnded: Int) -> Bool {
        guard let madeAfter, !handedOver else { return false }
        return runsEnded != madeAfter
    }
}
