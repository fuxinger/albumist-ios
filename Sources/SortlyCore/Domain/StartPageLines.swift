import Foundation

/// "Bescheid sagen, wenn fertig" on the analysis card (decision 3B, 16.11.): Albumist no longer
/// asks for notifications at the start of the analysis, two iOS questions in a row are easily
/// declined (and a "no" can only be undone in the iOS settings). It asks on the card, once the
/// analysis takes a while, so the user sees what the notification is for; iOS asks after the tap.
public enum FinishNotice: Equatable, Sendable {
    /// "Bescheid sagen, wenn fertig".
    case offer
    /// Allowed on the card in this visit: "Albumist sagt Bescheid, wenn die Analyse fertig ist."
    case promised

    /// What iOS knows about Albumist's notifications.
    public enum Permission: Equatable, Sendable {
        case notAsked
        case allowed
        case denied
    }

    /// The analysis takes at least this long still before the card offers it.
    public static let minimumWait: TimeInterval = 120

    /// - Parameters:
    ///   - runGoesOn: the analysis runs or waits for the device and goes on by itself (not
    ///     paused, not a quick check for new photos, not the overnight refinement).
    ///   - finish: the expected end (`FinishEstimate`); nil while there is none.
    ///   - firstAnalysis: the first analysis, which takes long anyway: offered before its first
    ///     estimate.
    ///   - allowedHere: the user allowed it on this card in this visit.
    public static func make(runGoesOn: Bool, finish: Date?, now: Date, firstAnalysis: Bool,
                            permission: Permission, allowedHere: Bool) -> FinishNotice? {
        guard runGoesOn else { return nil }
        switch permission {
        case .denied:
            return nil
        case .allowed:
            return allowedHere ? .promised : nil
        case .notAsked:
            if let finish { return finish.timeIntervalSince(now) >= minimumWait ? .offer : nil }
            return firstAnalysis ? .offer : nil
        }
    }
}

/// The analysis line of the ring card when no analysis runs (overview draft B, 19.11.): one
/// line with a check mark, the details in the sheet "Analyse".
public enum AnalysisDoneLine: Equatable, Sendable {
    /// No photo to analyse: "Analyse aktuell".
    case upToDate
    /// "Alle 14.381 Fotos analysiert".
    case all(photos: Int)
    /// "Analyse fertig" / "Den Rest holt Albumist später nach": a photo that could not be read
    /// yet, places without a city name, documents only in iCloud, photos still without the
    /// labels of a new area, or photos not analysed yet. Each with its count in the sheet.
    case restLater

    public static func make(photos: Int, analyzed: Int, later: Int) -> AnalysisDoneLine {
        if photos == 0 { return .upToDate }
        if analyzed >= photos && later == 0 { return .all(photos: photos) }
        return .restLater
    }
}
