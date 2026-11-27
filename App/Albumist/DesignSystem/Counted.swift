import Foundation
import AlbumistCore

/// Sentences with several counts ("1 Land · 5 Städte · 2 Reisen") are built from parts that
/// are each a plural string in the catalog, so German gets "1 Reise" and not "1 Reisen".
/// (One catalog entry with three numbers cannot pick a singular per number.)
enum Counted {
    static func join(_ parts: [String], separator: String = " · ") -> String {
        parts.joined(separator: separator)
    }

    /// History row in Settings: what the change did, as the core decides it (`HistoryLine`), each
    /// part a string of the catalog: "25 neu, 1 umbenannt, 236 Fotos"; "2 entfernt, 12 Fotos
    /// herausgenommen" for a removal; "Nichts geändert" or "Nichts entfernt" for a change of nothing.
    static func historyLine(_ plan: ChangePlan) -> String {
        join(HistoryLine.parts(of: plan).map { part in
            switch part {
            case .created(let count): String(localized: "\(count) neu")
            case .extended(let count): String(localized: "\(count) ergänzt")
            case .renamed(let count): String(localized: "\(count) \(count.formatted()) umbenannt")
            case .moved(let count): String(localized: "\(count) \(count.formatted()) verschoben")
            case .photos(let count): String(localized: "\(count) \(count.formatted()) Fotos")
            case .removed(let count): String(localized: "\(count) \(count.formatted()) entfernt")
            case .takenOut(let count): String(localized: "\(count) \(count.formatted()) Fotos herausgenommen")
            case .nothingChanged: String(localized: "Nichts geändert")
            case .nothingRemoved: String(localized: "Nichts entfernt")
            }
        }, separator: ", ")
    }
}
