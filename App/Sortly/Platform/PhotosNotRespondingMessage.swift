import Foundation
import SortlyCore

/// Photos did not answer in time (`PhotosDeadline`, app-speed 18.11.2026): words instead of
/// "PhotosNotResponding error 1" in an alert or on a plan. A change Photos did not answer is
/// neither done nor taken back: the plan stays open in the overview ("Fortsetzen"), and its
/// step is settled from what the library shows once Photos answers again (docs/DECISIONS.md).
extension PhotosNotResponding: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch lane {
        case .write:
            String(localized: "Fotos antwortet gerade nicht. Was Albumist gerade ändern wollte, gilt weder als erledigt noch als zurückgenommen. Sobald Fotos wieder reagiert, kannst du in der Übersicht fortsetzen.")
        case .read:
            String(localized: "Fotos antwortet gerade nicht. Albumist versucht es gleich noch einmal.")
        }
    }
}
