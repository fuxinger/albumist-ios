import Foundation

/// The App target's sources, for tests that check how the App uses a rule tested here: the App
/// does not build on Linux, so these tests read its code (`AnalysisStartCauseTests`,
/// `TripWorkshopTests`).
public enum AppSource {
    /// The repository root.
    public static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// A file under the repository root, e.g. "App/Sortly/Model/AppModel.swift".
    public static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The body of the first declaration that starts with `declaration` (e.g. "func
    /// changeTrips("), from its first "{" to the matching "}"; nil when there is none. Braces in
    /// comments and strings count too, which the App's code keeps balanced.
    public static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration),
              let open = source[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The argument lists of every call of `function` in `text` ("startAnalysis(" gives "" for
    /// `startAnalysis()` and "cause: .tap" for `startAnalysis(cause: .tap)`).
    public static func calls(of function: String, in text: String) -> [String] {
        var found: [String] = []
        var rest = text[...]
        while let call = rest.range(of: function) {
            var depth = 1
            var index = call.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                if depth > 0 { index = rest.index(after: index) }
            }
            found.append(String(rest[call.upperBound..<index]))
            rest = rest[index...]
        }
        return found
    }
}
