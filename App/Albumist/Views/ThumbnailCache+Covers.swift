import UIKit
import AlbumistCore

/// The covers of the photo cards (`CoverPhoto`), kept apart from the thumbnails (`covers`).
extension ThumbnailCache {
    /// Keeps a cover for its id and size, in the covers' own store, only when it is sharp there:
    /// a blurry preview is asked for again the next time (the photo may be on the device by
    /// then, and the cover then shows it). Returns whether it was kept.
    @discardableResult
    func keepCover(_ image: UIImage, screenshot: Bool, for id: AssetID, pixels: CGSize) -> Bool {
        guard ThumbnailRequest.isSharp(image, for: pixels) else { return false }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        covers.setObject(CachedCover(image: image, screenshot: screenshot), forKey: Self.coverKey(id, pixels), cost: cost)
        return true
    }

    /// The kept cover of `id` at `pixels`, if there is one.
    func cachedCover(for id: AssetID, pixels: CGSize) -> CachedCover? {
        covers.object(forKey: Self.coverKey(id, pixels))
    }

    private static func coverKey(_ id: AssetID, _ pixels: CGSize) -> NSString {
        "\(id.rawValue)#\(Int(pixels.width))x\(Int(pixels.height))" as NSString
    }
}

/// What `ThumbnailCache.cover` found for one photo of a photo card.
enum CoverFetch {
    /// The photo at the asked size, or only the small preview Photos keeps of it
    /// (`ThumbnailRequest.isSharp` tells them apart).
    case image(UIImage, screenshot: Bool)
    /// Photos answered: it does not know the photo (deleted), or has nothing of it on the device.
    case missing
    /// Photos did not answer in time (it is busy), or the request was cancelled: nothing is known.
    case noAnswer
}

/// A kept cover (`ThumbnailCache.keepCover`) and whether it is a screenshot (its crop keeps the top).
final class CachedCover {
    let image: UIImage
    let screenshot: Bool

    init(image: UIImage, screenshot: Bool) {
        self.image = image
        self.screenshot = screenshot
    }
}
