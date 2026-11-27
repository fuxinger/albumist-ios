import Foundation
import AlbumistTestSupport

/// The photo view's code for the source guards. `PhotoViewer.swift` once held all of it; for
/// SwiftLint's file length (design wave 3) the view's state, body and sheets stayed there, its
/// pages, bars and actions went into `PhotoViewer+Pages.swift`, and the page of one photo
/// (`ZoomablePhoto`, private before, internal now that it is in a file of its own) into the
/// photo view's folder. A guard reads them as one text, so what it pins is found in whichever
/// of these files it went to, and what it rules out is ruled out in all of them.
enum PhotoViewerSource {
    /// The photo view itself.
    static let views = [
        "App/Albumist/Views/PhotoViewer.swift",
        "App/Albumist/Views/PhotoViewer+Pages.swift",
    ]
    /// The page of one photo, with its gestures and its loading.
    static let zoomable = [
        "App/Albumist/Views/PhotoViewer/ZoomablePhoto.swift",
        "App/Albumist/Views/PhotoViewer/ZoomablePhoto+Loading.swift",
    ]
    static let paths = views + zoomable

    /// The files' text, joined in the order of `paths`.
    static func read() throws -> String {
        try paths.map { try AppSource.read($0) }.joined(separator: "\n")
    }

    /// The page of one photo's text: `ZoomablePhoto`, its extensions and its magic tap, nothing
    /// else of the photo view.
    static func readZoomable() throws -> String {
        try zoomable.map { try AppSource.read($0) }.joined(separator: "\n")
    }
}
