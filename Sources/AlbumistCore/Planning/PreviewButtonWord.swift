import Foundation

/// The word on the preview's button (design W1, Punkt 2): what a tap does, as one verb after
/// "Jetzt". It replaces "Alben jetzt anlegen", "Fotos jetzt einsortieren" and "Änderungen jetzt
/// ausführen" (three ways of naming one step).
public enum PreviewButtonWord: Hashable, Sendable {
    /// "Jetzt anlegen": new albums, with their photos (photos for albums of the user's may come
    /// along in the same plan; the new albums are what the button names).
    case create
    /// "Jetzt ergänzen": photos go into albums that are there already.
    case extend
    /// "Jetzt entfernen": a removal from Albumist's albums (albums deleted, or only Albumist's
    /// photos taken out of an album that stays).
    case remove
    /// "Jetzt ändern": anything else, such as renames or moves alone.
    case change

    public init(_ plan: ChangePlan) {
        self.init(plan.summary, kind: PlanReceipt.Kind(plan))
    }

    /// From what the preview has already worked out (`PlanReviewFacts.summary`): the summary
    /// walks every photo of the plan, the kind only its steps.
    public init(_ summary: PlanSummary, kind: PlanReceipt.Kind) {
        let removes = summary.removedMemberships > 0 || summary.deletedContainers > 0
        switch kind {
        case .removed:
            self = .remove
        case .undone:
            // An undo is asked in a dialog, never in the preview (and is never retried).
            self = .change
        case .created:
            if summary.newAlbums > 0 || summary.newFolders > 0 {
                self = .create
            } else if summary.totalAssignments > 0 {
                self = .extend
            } else {
                self = removes ? .remove : .change
            }
        }
    }
}
