import Foundation
import AlbumistCore

/// What the covers of the history and the receipt are worked out from (design wave 3, DS-15): the
/// changes, and the facts the photos' dates and ranks are made from, by their revision
/// (`AppModel.factsVersion`). A screen works its covers out again when one of them changes
/// (`.task(id:)`), so a photo the analysis finds to be a sensitive document leaves its cover at
/// once. Cheap to keep and compare (review G7): the dictionaries of all dates and ranks as the
/// task's id were held by SwiftUI while the screen was open, so a memory warning freed nothing
/// there, and compared entry by entry once the model made them anew.
struct ChangeCoverInputs: Equatable {
    var plans: [AlbumistID]
    var facts: Int
}

/// The covers of the changes Albumist made and is about to make (DS-15, `PlanCovers`): which
/// photos each one tries, worked out off the main thread (a starter pack holds thousands of
/// photos).
extension AppModel {
    /// What the covers of `plans`, and of the plan cut off on its way, are worked out from.
    func changeCoverInputs(_ plans: [ChangePlan], interrupted: ChangePlan? = nil) -> ChangeCoverInputs {
        ChangeCoverInputs(plans: plans.map(\.id) + (interrupted.map { [$0.id] } ?? []), facts: factsVersion)
    }

    /// The cover of each change in the history (`PlanCovers.mosaic`): the albums of the run, with
    /// the photos the library confirmed; for the plan cut off on its way, with what it sets out to
    /// add, so it is recognised before it is complete. None before the first facts of a launch
    /// (`ChangeCoverInputs` changes when they come).
    func historyCovers(_ plans: [ChangePlan], interrupted: ChangePlan?) async -> [AlbumistID: PlanCovers.Mosaic] {
        // Without facts every photo would count as an ordinary one (`PreviewRank`): no cover until
        // they say which are sensitive documents.
        guard !facts.isEmpty else { return [:] }
        let dates = creationDates, ranks = previewRanks
        return await Task.detached(priority: .userInitiated) {
            var covers: [AlbumistID: PlanCovers.Mosaic] = [:]
            for plan in plans {
                covers[plan.id] = PlanCovers.mosaic(of: plan, dates: dates, ranks: ranks)
            }
            if let interrupted {
                covers[interrupted.id] = PlanCovers.mosaic(of: interrupted, applied: false, dates: dates, ranks: ranks)
            }
            return covers
        }.value
    }

    /// The cover of each album on the receipt of `plan` (`PlanCovers.albums`), named as the receipt
    /// names its albums: the photos the plan added to it, as the tab "Alben" shows the album. Nil
    /// before the first facts of a launch, as the history's.
    func receiptCovers(for plan: ChangePlan) async -> [String: PlanCovers.Cover]? {
        guard !facts.isEmpty else { return nil }
        let dates = creationDates, ranks = previewRanks
        return await Task.detached(priority: .userInitiated) {
            PlanCovers.albums(of: plan, dates: dates, ranks: ranks)
        }.value
    }

    /// The cover of each album the preview of `plan` lists (DS-15 part 2), before the run: the
    /// photos the plan sets out to add (`applied: false`), as its receipt will show them, named as
    /// the receipt names its albums (`PlanCovers.key`). Nil before the first facts of a launch, as
    /// the receipt's.
    func previewCovers(for plan: ChangePlan) async -> [String: PlanCovers.Cover]? {
        guard !facts.isEmpty else { return nil }
        await makeDatesAndRanksOffMain() // Design W3 H13: the preview never makes the two tables on the main actor
        let dates = creationDates, ranks = previewRanks
        return await Task.detached(priority: .userInitiated) {
            PlanCovers.albums(of: plan, applied: false, dates: dates, ranks: ranks)
        }.value
    }
}
