import UIKit
import AlbumistCore

/// The PhotoKit assets the thumbnails' lookup (`photoAsset`) finds, for whoever else needs them.
extension ThumbnailCache {
    /// What a lookup found: the asset, no such photo (Photos answered), or no answer in time
    /// (Photos is busy; nothing is remembered, the next lookup asks again).
    enum AssetLookup: Sendable {
        case found(ThumbnailRequest.Asset)
        case unknown
        case noAnswer
    }

    /// Looks the ids up in one batch (`photoAsset`), so a cover whose first photo was not sharp
    /// waits for Photos once for all its other candidates, not once for each of them.
    func lookUp(_ ids: [AssetID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { _ = await self.photoAsset(for: id) }
            }
        }
    }

    /// A large version for the full-screen viewer: not kept in the cache (a few of them would
    /// push out hundreds of thumbnails), and only what is on the device (no download).
    func largeImage(for id: AssetID, pixels: CGSize) async -> UIImage? {
        guard let asset = await photoAsset(for: id) else { return nil }
        return await ThumbnailRequest.load(asset, size: pixels, manager: manager, contentMode: .aspectFit)
    }

    /// The PhotoKit asset of `id` for the photo view's Live Photo and its sharing (DS-10,
    /// `LivePhotoLoader`, `PhotoShare`): the thumbnails' own lookup, so it costs no second read
    /// of the Photos database. Nil when Photos does not know the photo or did not answer in time.
    func asset(for id: AssetID) async -> ThumbnailRequest.Asset? {
        await photoAsset(for: id)
    }
}
