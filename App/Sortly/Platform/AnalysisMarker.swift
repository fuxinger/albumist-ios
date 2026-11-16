import Foundation
import SortlyEngine

/// Where the analysis got to, kept across launches: a run that iOS ended (or the app was
/// closed) shows the real state when it goes on, instead of starting at "Schritt 1" again
/// (first device test 15.11.: "Schritt 3 kommt wieder, die Zahlen werden kleiner").
enum AnalysisMarker {
    struct Point: Codable, Equatable {
        /// Stage number (1…7) and the bar's value when the run was last seen.
        var stage: Int
        var overall: Double
        /// The bar's widths of this analysis (progress display S6): a run that goes on after a
        /// restart keeps them, so the bar does not jump. `nil` in markers of older versions and
        /// before the workload is known (the standard widths).
        var widths: StepWidths? = nil
        /// How much that stage had to do (photos, places, screenshots): a run that goes on
        /// continues the bar from `overall` only when there is more now (`ResumedRun.back`).
        /// `nil` in markers of older versions.
        var total: Int? = nil
    }

    private static let unfinishedKey = "analysis.unfinished"
    private static let completedKey = "analysis.completedOnce"

    static var unfinished: Point? {
        get {
            UserDefaults.standard.data(forKey: unfinishedKey).flatMap { try? JSONDecoder().decode(Point.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: unfinishedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: unfinishedKey)
            }
        }
    }

    /// Everything was analysed once: later runs only check for new photos.
    static var completedOnce: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    static func finished() {
        unfinished = nil
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    /// Another part of the library or a rebuilt analysis: the next run is a full one again.
    static func reset() {
        unfinished = nil
        UserDefaults.standard.removeObject(forKey: completedKey)
    }
}
