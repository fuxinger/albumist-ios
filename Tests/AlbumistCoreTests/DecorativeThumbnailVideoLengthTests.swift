import Foundation
import Testing
import AlbumistTestSupport

/// A thumbnail says a video's length in the grids (DS-16, `AssetThumbnail`); where a photo only
/// decorates, the length would be noise on it: the mosaic of the first analysis (`ScanShow`) and
/// the large photo a long press lifts when its cell's thumbnail is not in memory
/// (`PhotoPreview`). Covers and a card's mosaic leave it out already (`CoverThumbnail`,
/// `ThumbnailGrid`). The views run only on a Mac; the guards read their code.
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

    @Test func theLongPresssFallbackPreviewShowsNoVideoLength() throws {
        let source = AppSource.code(try AppSource.read("App/Albumist/Views/Menus/PhotoMenuItems.swift"))
        let body = try #require(AppSource.body(of: ["struct PhotoPreview", "var body: some View"], in: source), "no PhotoPreview.body")
        let squeezed = Self.squeezed(body)
        let fallback = try #require(squeezed.range(of: "}else{AssetThumbnail(id:id,side:side)"), "no fallback thumbnail: \(squeezed)")
        #expect(squeezed[fallback.upperBound...].hasPrefix(".environment(\\.thumbnailShowsVideoLength,false)"),
                "the lifted photo says a video's length: \(squeezed[fallback.upperBound...].prefix(120))")
    }
}
