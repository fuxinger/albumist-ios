import Foundation
import SortlyCore

/// Photos did not answer in time (`PhotosDeadline`, app-speed 18.11.2026): words instead of
/// "PhotosNotResponding error 1" in an alert or on a plan. A change Photos did not answer is
/// neither done nor taken back: the plan stays open in the overview ("Fortsetzen"), and its
/// step is settled from what the library shows once Photos answers again (docs/DECISIONS.md).
extension PhotosNotResponding: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch lane {
        case .write where neverBegan:
            // Given up before it got a thread (Albumist's own work kept them all busy): this
            // change was never sent, so it did not happen, and nothing hangs. Trying again is
            // safe; no restart needed (second review of 6c45378, P1; wording: review of 045f297,
            // S3). Only this change: a library call reports nothing as never begun once it sent
            // one (`PhotosNotResponding.afterAChangeWasSent`).
            String(localized: "Albumist war gerade ausgelastet und hat diese Änderung nicht an Fotos geschickt – sie ist nicht passiert. Versuche es gleich noch einmal; bei einem Plan mit „Fortsetzen“ in der Übersicht.")
        case .write where notSent:
            // An earlier change still has no answer: nothing new was sent. Restarting, not
            // "Fortsetzen", is the way out when it lasts (second review of the PhotoKit limits, 11).
            String(localized: "Fotos hat eine frühere Änderung noch nicht beantwortet, deshalb schickt Albumist nichts Neues. Hält das an, beende Albumist und öffne es neu, notfalls starte das iPhone neu.")
        case .write where asksUser:
            // A deletion: the question iOS asks before it may still be on screen (7).
            String(localized: "Die Rückfrage von iOS zum Löschen blieb ohne Antwort und ist vielleicht noch offen. Ob gelöscht wird, steht noch nicht fest. Sobald das geklärt ist, kannst du in der Übersicht fortsetzen.")
        case .write:
            String(localized: "Fotos antwortet gerade nicht. Was Albumist gerade ändern wollte, gilt weder als erledigt noch als zurückgenommen. Sobald Fotos wieder reagiert, kannst du in der Übersicht fortsetzen.")
        case .read where neverBegan, .image where neverBegan, .thumbnail where neverBegan:
            // Given up before it got a thread: Photos was never asked, it is not Photos that is
            // slow (review of 045f297, S1).
            String(localized: "Albumist war gerade ausgelastet und hat Fotos noch nicht gefragt. Versuche es gleich noch einmal.")
        case .read, .image, .thumbnail:
            String(localized: "Fotos antwortet gerade nicht. Albumist versucht es gleich noch einmal.")
        }
    }
}

/// A new album Albumist asked for before (its request got no answer, and the app was closed
/// since) is not in Photos yet and may still land: going on or taking the plan back waits a
/// few minutes, so it is never made twice (`ChangeExecutor.lateCreateWait`, third review N2).
/// Says from when, in the local time format; the app goes on by itself then while it is open
/// (`AppModel.retryAfterLateCreateWait`, round-3 review L1). "So lassen" does not wait.
extension ChangeExecutor.ExecutionError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .earlierCreateMayLand(let until):
            let time = until.formatted(date: .omitted, time: .shortened)
            return String(localized: "Ein Album, das Albumist vorhin anlegen wollte, ist in Fotos noch nicht angekommen und kann noch kommen. Damit es nicht doppelt entsteht, geht es ab \(time) weiter, von selbst, solange Albumist offen ist.")
        case .notConfirmed, .blocked:
            return nil
        }
    }
}
