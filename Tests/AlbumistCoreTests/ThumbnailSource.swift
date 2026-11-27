import Foundation
import AlbumistTestSupport

/// The thumbnails' code for the source guards. `AssetThumbnail.swift` once held all of it; for
/// SwiftLint's file length (design wave 3) the views stayed there and the cache with its covers
/// and assets, the PhotoKit request and the length revision went into files beside it. A guard
/// reads them as one text, so what it pins is found in whichever of these files it went to, and
/// what it rules out is ruled out in all of them.
enum ThumbnailSource {
    static let paths = [
        "App/Albumist/Views/ThumbnailCache.swift",
        "App/Albumist/Views/ThumbnailCache+Covers.swift",
        "App/Albumist/Views/ThumbnailCache+Assets.swift",
        "App/Albumist/Views/VideoLengthRevision.swift",
        "App/Albumist/Views/ThumbnailRequest.swift",
        "App/Albumist/Views/AssetThumbnail.swift",
    ]

    /// The files' text, joined in the order of `paths`.
    static func read() throws -> String {
        try paths.map { try AppSource.read($0) }.joined(separator: "\n")
    }
}
