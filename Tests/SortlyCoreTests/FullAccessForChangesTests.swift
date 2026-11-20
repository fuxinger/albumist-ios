import Foundation
import Testing
import SortlyTestSupport

/// Second review of P1-07 (S2): with "Ausgewählte Fotos" the album list shows only the shared
/// photos of each album. An album the user also filled with photos that are not shared then
/// looks like Albumist's alone (`ManagedAlbumTracker.removalPlan`: delete when its photos are a
/// subset of what Albumist added), and an undo would delete it. The plan review shows
/// `FullAccessCard` instead of its button; the ways that change Photos without a review (undo,
/// "Rest rückgängig machen", taking back or finishing an interrupted plan) ask for full access
/// first, before anything is read or planned.
@Suite("Changes without a review need full access")
struct FullAccessForChangesTests {
    static let gated = ["func undo(_ executed: ChangePlan)", "func undoInterruptedPlan()", "func resumeInterruptedPlan()"]

    @Test func everyChangeWithoutAReviewAsksForFullAccessFirst() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        for signature in Self.gated {
            let body = try #require(AppSource.body(of: signature, in: model), "\(signature) not found")
            let code = AppSource.code(body)
            let gate = try #require(code.range(of: "changesHaveFullAccess("), "\(signature) does not ask for full access")
            for later in ["claimExecution(", "reconcileManagedAlbums(", "UndoPlanner(", "run("] {
                if let use = code.range(of: later) {
                    #expect(gate.lowerBound < use.lowerBound, "\(signature) uses \(later) before it asks for full access")
                }
            }
        }
    }
}
