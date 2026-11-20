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
    static let gated = ["func undo(_ executed: ChangePlan)", "func undoInterruptedPlan()", "func resumeInterruptedPlan()",
                         // A plan run from the review: the review shows `FullAccessCard`, the model asks too
                         // (second look: the review goes by `access` as last seen).
                         "func execute(_ plan: ChangePlan)"]

    @Test func everyChangeWithoutAReviewAsksForFullAccessFirst() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        for signature in Self.gated {
            let body = try #require(AppSource.body(of: signature, in: model), "\(signature) not found")
            let code = AppSource.code(body)
            // A guard that ends the way out, not a call whose answer is dropped.
            let gate = try #require(code.range(of: #"guard\s+await\s+changesHaveFullAccess\(\)\s+else"#, options: .regularExpression),
                                    "\(signature) does not stop without full access")
            for later in ["claimExecution(", "reconcileManagedAlbums(", "UndoPlanner(", "run(", "ChangeExecutor(", "storeWaitingResults("] {
                if let use = code.range(of: later) {
                    #expect(gate.lowerBound < use.lowerBound, "\(signature) uses \(later) before it asks for full access")
                }
            }
        }
    }

    /// The buttons that ask before an undo ask for full access before their dialog, not after
    /// the user confirmed it (second look at S2).
    @Test func theUndoDialogsAskForFullAccessFirst() throws {
        for path in ["App/Sortly/Views/OverviewView.swift", "App/Sortly/Views/PlanReceiptView.swift",
                     "App/Sortly/Views/PlanReviewView.swift", "App/Sortly/Views/SettingsView.swift"] {
            let code = AppSource.code(try AppSource.read(path))
            var searchFrom = code.startIndex
            var asks = 0
            while let ask = code.range(of: "DeletesCollections(", range: searchFrom..<code.endIndex) {
                let from = code.index(ask.lowerBound, offsetBy: -400, limitedBy: code.startIndex) ?? code.startIndex
                let before = code[from..<ask.lowerBound]
                #expect(before.contains("changesHaveFullAccess()"), "\(path): the dialog opens before full access was asked for")
                asks += 1
                searchFrom = ask.upperBound
            }
            #expect(asks > 0, "\(path): no undo dialog found")
        }
    }
}
