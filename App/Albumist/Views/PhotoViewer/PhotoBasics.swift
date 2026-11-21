import Foundation
import Photos
import AlbumistCore

/// What Photos itself says of a photo, for the photo view (design wave 2, DS-10) while Albumist
/// has not analysed it yet, as right after an import: its date, which then makes the title
/// (review D, M7: such a photo was titled just "Foto"), whether it has a location, which tells
/// the clock of that title (review D2, N10: `PhotoTitle.zoneWithoutFacts`), and whether it is a
/// still image, the only kind that is shared (L4: a video without facts got a share button and
/// went out as a still).
struct PhotoBasics: Equatable, Sendable {
    var date: Date?
    var isLocated = false
    var isImage: Bool

    /// With the thumbnails' own lookup, so it costs no second read of the Photos database; nil
    /// while Photos does not answer or does not know the photo.
    @MainActor
    static func of(_ id: AssetID) async -> PhotoBasics? {
        guard let asset = await ThumbnailCache.shared.asset(for: id) else { return nil }
        return PhotoBasics(date: asset.value.creationDate, isLocated: asset.value.location != nil,
                           isImage: asset.value.mediaType == .image)
    }
}
