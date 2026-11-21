import Foundation
import AlbumistStore

/// A full disk is the one database error the user can fix, so it gets words instead of
/// "SQLiteError error 1" in the alert and on the plan (Fuchs, 15.11.: every device condition
/// is tested, with a clear message). SQLite reports it as SQLITE_FULL (13) for any write when
/// the device has no space left. Other database errors keep their technical description,
/// exactly as before, for the diagnostic report.
extension SQLiteError: @retroactive LocalizedError {
    public var errorDescription: String? {
        guard code == 13 else { return nil }
        return String(localized: "Der Speicher deines iPhone ist voll, darum konnte Albumist gerade nichts sichern. Gib etwas Speicher frei, dann geht es dort weiter, wo es aufgehört hat.")
    }
}
