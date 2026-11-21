import Foundation
import Testing
import AlbumistTestSupport

/// A thumbnail says a video's length in the grids (DS-16, `AssetThumbnail`); where a photo only
/// decorates, the length would be noise on it: the mosaic of the first analysis (`ScanShow`), the
/// photos "Gerade angesehen" on the analysis card and the large photo a long press lifts when its
/// cell's thumbnail is not in memory (`PhotoPreview`). Covers and a card's mosaic leave it out
/// already (`CoverThumbnail`, `ThumbnailGrid`). The views run only on a Mac; the guards read their
/// code, and every caller of `AssetThumbnail` is either a grid of photos or turns the length off.
@Suite("Thumbnails: no video length where a photo only decorates")
struct DecorativeThumbnailVideoLengthTests {
    private static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    @Test func theScanShowsMosaicShowsNoVideoLength() throws {
        let source = Self.squeezed(AppSource.code(try AppSource.read("App/Albumist/Views/ScanShow.swift")))
        let thumbnails = source.components(separatedBy: "AssetThumbnail(").dropFirst()
        #expect(!thumbnails.isEmpty, "the mosaic has no thumbnails")
        for thumbnail in thumbnails {
            #expect(thumbnail.prefix(120).contains(".environment(\\.thumbnailShowsVideoLength,false)"),
                    "a thumbnail of the mosaic says a video's length: \(thumbnail.prefix(120))")
        }
    }

    /// Every place that draws a thumbnail decides whether a video's length belongs there (review F4
    /// of design wave 3): a grid of photos to look through shows it, as Photos does; anything else
    /// turns it off right after the thumbnail. A new caller fails here until it is listed as a
    /// grid or turns the length off.
    @Test func everyThumbnailShowsALengthOnlyInAGridOfPhotos() throws {
        let grids: Set<String> = [
            "App/Albumist/Views/LibraryView.swift",                // "Unsortiert"
            "App/Albumist/Views/AlbumsView.swift",                 // an album's photos
            "App/Albumist/Views/ProposalViews.swift",              // a suggestion's photos
            "App/Albumist/Views/SearchView.swift",                 // the search's hits
            "App/Albumist/Views/CountryPhotosView.swift",          // a country's photos
            "App/Albumist/Views/Trips/TripTimelineViews.swift",    // a day's photos on a trip's timeline
        ]
        var callers = Set<String>()
        for path in AppSource.swiftFiles(under: "App/Albumist") where path != "App/Albumist/Views/AssetThumbnail.swift" {
            let thumbnails = Self.squeezed(AppSource.code(try AppSource.read(path))).components(separatedBy: "AssetThumbnail(").dropFirst()
            guard !thumbnails.isEmpty else { continue }
            callers.insert(path)
            guard !grids.contains(path) else { continue }
            for thumbnail in thumbnails {
                #expect(thumbnail.prefix(160).contains(".environment(\\.thumbnailShowsVideoLength,false)"),
                        "\(path): a thumbnail outside a grid of photos says a video's length: \(thumbnail.prefix(120))")
            }
        }
        #expect(callers.count > 6, "no thumbnails found: \(callers.sorted())")
        #expect(grids.isSubset(of: callers), "a listed grid has no thumbnail any more: \(grids.subtracting(callers).sorted())")
    }

    @Test func theLongPresssFallbackPreviewShowsNoVideoLength() throws {
        let source = AppSource.code(try AppSource.read("App/Albumist/Views/Menus/PhotoMenuItems.swift"))
        let body = try #require(AppSource.body(of: ["struct PhotoPreview", "var body: some View"], in: source), "no PhotoPreview.body")
        let squeezed = Self.squeezed(body)
        let fallback = try #require(squeezed.range(of: "}else{AssetThumbnail(id:id,side:side)"), "no fallback thumbnail: \(squeezed)")
        #expect(squeezed[fallback.upperBound...].hasPrefix(".environment(\\.thumbnailShowsVideoLength,false)"),
                "the lifted photo says a video's length: \(squeezed[fallback.upperBound...].prefix(120))")
    }
}
