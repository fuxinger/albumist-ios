import SwiftUI

/// Before Albumist deletes albums or folders in Photos, iOS asks once more ("delete 15 albums
/// and 9 folders"). Albumist's own confirmation before it says so, so the word "delete" in the
/// iOS question does not scare (review 18.11., P3-07). Only when the change really deletes one
/// (`AppModel.undoDeletesCollections`, `ChangePlan.deletesCollections`): an undo that only
/// takes photos out of albums says nothing about deleting. `DeleteQuestionNoteTests` finds
/// every confirmation by what its button calls.
enum DeleteQuestionNote {
    /// The sentence itself, the one place it is written.
    static var text: Text {
        Text("iOS fragt gleich noch einmal, ob Albumist die Alben löschen darf. Deine Fotos bleiben.")
    }

    /// A confirmation's message: `lead`, then the iOS question when `deletes`, otherwise that
    /// the photos stay (the note says that too, so it is never said twice).
    static func message(_ lead: Text, deletes: Bool) -> Text {
        let tail = deletes ? text : Text("Deine Fotos bleiben unverändert.")
        return Text("\(lead) \(tail)")
    }
}
