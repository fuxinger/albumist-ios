import Foundation
import SortlyCore

/// Photos did not answer in time (`PhotosDeadline`, app-speed 18.11.2026): words instead of
/// "PhotosNotResponding error 1" in an alert or on a plan. A change Photos did not answer is
/// neither done nor taken back: the plan stays open in the overview ("Fortsetzen"), and its
/// step is settled from what the library shows once Photos answers again (docs/DECISIONS.md).
extension PhotosNotResponding: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch lane {
        case .write where notSent:
            // An earlier change still has no answer: nothing new was sent. Restarting, not
            // "Fortsetzen", is the way out when it lasts (second review of the PhotoKit limits, 11).
            String(localized: "Fotos hat eine frühere Änderung noch nicht beantwortet, deshalb schickt Albumist nichts Neues. Hält das an, beende Albumist und öffne es neu, notfalls starte das iPhone neu.")
        case .write where asksUser:
            // A deletion: the question iOS asks before it may still be on screen (7).
            String(localized: "Die Rückfrage von iOS zum Löschen blieb ohne Antwort und ist vielleicht noch offen. Ob gelöscht wird, steht noch nicht fest. Sobald das geklärt ist, kannst du in der Übersicht fortsetzen.")
        case .write:
            String(localized: "Fotos antwortet gerade nicht. Was Albumist gerade ändern wollte, gilt weder als erledigt noch als zurückgenommen. Sobald Fotos wieder reagiert, kannst du in der Übersicht fortsetzen.")
        case .read, .image:
            String(localized: "Fotos antwortet gerade nicht. Albumist versucht es gleich noch einmal.")
        }
    }
}
