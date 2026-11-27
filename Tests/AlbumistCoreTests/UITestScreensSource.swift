import Foundation
import AlbumistTestSupport

/// The UI tests' screens (`UITestScreens`) for the source guards. `UITestScreens.swift` once
/// held all of them; for SwiftLint's file length (design wave 3) the tabs and the cards stayed
/// there and the search, the analysis with the trial year, the start page with the suggestions
/// and the purchase sheet, and the tabs "Unsortiert" and "Alben" went into files beside it. A
/// guard reads them as one text, so what it pins is found in whichever of these files it went
/// to, and what it rules out is ruled out in all of them.
///
/// The files come from the folder, not from a list by hand (review T9 of H14's round 2: a sixth
/// `UITestScreens+….swift` would have been read by no guard); `UITestTabsSourceTests` pins which
/// five they are today.
enum UITestScreensSource {
    static let folder = "App/AlbumistUITests"
    /// The main file first, the files beside it after, so a guard that pins text of both reads
    /// them in a fixed order.
    static let main = folder + "/UITestScreens.swift"

    /// Every `UITestScreens….swift` of the folder: `main`, then the rest in the folder's order.
    static var paths: [String] {
        let beside = AppSource.swiftFiles(under: folder).filter {
            $0 != main && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("UITestScreens")
        }
        return [main] + beside
    }

    /// The files' text, joined in the order of `paths`.
    static func read() throws -> String {
        try paths.map { try AppSource.read($0) }.joined(separator: "\n")
    }
}
