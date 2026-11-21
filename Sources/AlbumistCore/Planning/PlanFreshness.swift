/// Whether a preview's plan still fits Photos and the user's choices (`PlanReviewView`). A run
/// that ended after the plan was made may have done part of it already, and running the plan
/// then makes an album a second time (second review of design wave 1, 20.11.: a preview of
/// picks left open on "Vorschläge" still offered an album that "Album anlegen" had made on
/// "Start" meanwhile). A choice made elsewhere meanwhile changes what the plan should hold, too
/// (review B of wave 1, finding 2: a suggestion set aside on another tab was made anyway).
///
/// The model counts both (`AppModel.runsEnded`, `AppModel.choicesMade`); the preview adds them
/// up to one count of changes. It notes the count when its plan is made, and the plan is stale
/// once the count moved on. Its own run does not make it stale: the result takes its place.
public struct PlanFreshness: Hashable, Sendable {
    /// The changes counted when the plan was made; nil while no plan was made.
    private var madeAfter: Int?
    /// The plan was handed to its run ("Jetzt anlegen").
    private var handedOver = false

    public init() {}

    /// A plan was made (also one with nothing in it, or none at all because nothing could be
    /// planned). A preview that opened while another run was on made none yet and makes it once
    /// that run ended (review B of wave 1, finding 3: it stayed on "Nichts zu tun").
    public var wasMade: Bool { madeAfter != nil }

    /// The plan was made, after `changes` changes: the count read before it was made, so a
    /// change while it is made counts as later.
    public mutating func made(after changes: Int) {
        madeAfter = changes
        handedOver = false
    }

    /// "Jetzt anlegen": the plan goes to its run, and changes now do not make it stale.
    public mutating func handOver() {
        handedOver = true
    }

    /// The run did not take the plan (refused, or another plan had the turn): it is as before,
    /// and a change meanwhile makes it stale.
    public mutating func notTaken() {
        handedOver = false
    }

    /// The plan may plan what a run did already, or what the user decided otherwise since.
    public func isStale(changes: Int) -> Bool {
        guard let madeAfter, !handedOver else { return false }
        return changes != madeAfter
    }
}
