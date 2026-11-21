import Foundation
import Testing
import AlbumistCore
@testable import Albumist

/// The sentences the change receipt shows when Photos did not delete what an undo asked for
/// (first iPhone test 15.11.). Device UI test 05 walked the receipt once per failure, each time
/// the same screens with only another sentence; it now walks them once (the real iOS question),
/// and which sentence each failure gets is checked here. That the engine records the right
/// reason and that "Rest rückgängig machen" then takes back everything is
/// PlanningExecutionTests.undoThatPhotosDidNotCarryOutSaysWhyAndCanBeRepeated (both failures).
/// Compared with the catalog's own entry, so the test holds in every language of the simulator.
@Suite("Step problems in plain words")
struct StepProblemTextTests {
    static let unknown = String(localized: "Die Fotos-App hat einen Fehler gemeldet.")

    @Test func aDeclinedDeletionSaysTheUserDeclinedIt() {
        let text = StepProblemText.text(StepState.deletionDeclinedReason)
        #expect(text == String(localized: "Du hast das Löschen in der Frage von iOS nicht erlaubt. Die Alben sind noch da. Versuche es noch einmal und tippe dann auf „Löschen“."))
        #expect(text != Self.unknown)
    }

    @Test func aDeletionPhotosDidNotCarryOutSaysSo() {
        let text = StepProblemText.text(StepState.deletionNotAppliedReason)
        #expect(text == String(localized: "Die Fotos-App hat das Löschen nicht ausgeführt, die Alben sind noch da. Versuche es in ein paar Minuten noch einmal."))
        #expect(text != Self.unknown)
    }

    @Test func eachFailureHasItsOwnSentenceOnce() {
        let declined = StepProblemText.text(StepState.deletionDeclinedReason)
        let ignored = StepProblemText.text(StepState.deletionNotAppliedReason)
        #expect(declined != ignored)
        // One sentence per kind of problem, in plan order, however many steps share it.
        let reasons = [StepState.deletionDeclinedReason, StepState.deletionDeclinedReason, StepState.deletionNotAppliedReason]
        #expect(StepProblemText.texts(reasons) == [declined, ignored])
    }
}
