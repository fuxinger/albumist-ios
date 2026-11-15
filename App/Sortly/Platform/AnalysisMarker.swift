import Foundation

/// Where the analysis got to, kept across launches: a run that iOS ended (or the app was
/// closed) shows the real state when it goes on, instead of starting at "Schritt 1" again
/// (first device test 15.11.: "Schritt 3 kommt wieder, die Zahlen werden kleiner").
enum AnalysisMarker {
    struct Point: Codable, Equatable {
        /// Stage number (1…7) and the bar's value when the run was last seen.
        var stage: Int
        var overall: Double
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
