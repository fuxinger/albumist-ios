import SwiftUI
import UIKit
import AlbumistCore

/// How a page gets its large picture and its Live Photo (`ZoomablePhoto`).
extension ZoomablePhoto {
    // MARK: Loading

    /// The large picture, at twice the screen's pixels for the zoom; shown when it is sharp at
    /// the screen's size, or the photo's whole self (a small photo); otherwise the note (DS-18).
    func load(in size: CGSize) async {
        unavailable = false
        let basics = await PhotoBasics.of(id)
        let pixels = CGSize(width: size.width * displayScale * 2, height: size.height * displayScale * 2)
        let loaded = await ThumbnailCache.shared.largeImage(for: id, pixels: pixels)
        // After a swipe to the next photo this task is cancelled; its late image must
        // not replace the new photo's.
        guard !Task.isCancelled else { return }
        let screen = PixelSize(width: Double(size.width * displayScale), height: Double(size.height * displayScale))
        switch ViewerPicture.choose(delivered: loaded.map(Self.pixelSize(of:)), original: basics?.pixels, screen: screen) {
        case .sharp:
            image = loaded
            onPicture(id, true)
        case .unavailable: becameUnavailable()
        }
    }

    private static func pixelSize(of image: UIImage) -> PixelSize {
        PixelSize(width: Double(image.size.width * image.scale), height: Double(image.size.height * image.scale))
    }

    /// Photos may never answer for a photo that is only in iCloud.
    func giveUp() async {
        try? await Task.sleep(for: .seconds(15))
        if image == nil && !Task.isCancelled { becameUnavailable() }
    }

    /// No sharp picture comes: the page says so, and the photo view knows.
    private func becameUnavailable() {
        unavailable = true
        onPicture(id, false)
    }

    /// The Live Photo of the photo on screen, once its still shows; the pages beside it let
    /// theirs go. It moves briefly when it comes into view, where motion is welcome.
    func loadLive(in size: CGSize) async {
        guard isCurrent, image != nil else {
            live = nil
            return
        }
        if live == nil {
            // The screen's pixels: the motion shows only while it plays (review D, L5: twice as
            // many held a still of up to 12 megapixels beside the three stills of the pager).
            let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
            guard let loaded = await LivePhotoLoader.load(id, pixels: pixels), !Task.isCancelled else { return }
            live = loaded
            onLive(id)
        }
        // A moment for its view to be in place and for the swipe to come to rest.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let welcome = LiveMotion.playsHint(reduceMotion: reduceMotion, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                           autoplayVideos: UIAccessibility.isVideoAutoplayEnabled)
        if welcome { play(.hint) }
    }

    func play(_ kind: LiveCommand.Kind) {
        guard live != nil else { return }
        command.next(kind)
    }
}
