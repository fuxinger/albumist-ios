import Foundation
import AlbumistTestSupport

/// The UI tests' screens (`UITestScreens`) for the source guards. `UITestScreens.swift` once
/// held all of them; for SwiftLint's file length (design wave 3) the tabs and the cards stayed
/// there and the search, the analysis with the trial year, the start page with the suggestions
/// and the purchase sheet, and the tabs "Unsortiert" and "Alben" went into files beside it. A
/// guard reads them as one text, so what it pins is found in whichever of these files it went
/// to, and what it rules out is ruled out in all of them.
enum UITestScreensSource {
    static let paths = [
        "App/AlbumistUITests/UITestScreens.swift",
        "App/AlbumistUITests/UITestScreens+Search.swift",
        "App/AlbumistUITests/UITestScreens+Analysis.swift",
        "App/AlbumistUITests/UITestScreens+StartPage.swift",
        "App/AlbumistUITests/UITestScreens+UnsortedAndAlbums.swift",
    ]

    /// The files' text, joined in the order of `paths`.
    static func read() throws -> String {
        try paths.map { try AppSource.read($0) }.joined(separator: "\n")
    }
}
