import Foundation
import Testing
@testable import AlbumistCore

/// Calm placeholders while pictures load (design wave 3, DS-18: "ruhige Platzhalter beim Laden
/// statt grauer Flächen und Kreisel"): in the photo view the thumbnail the grid showed while the
/// photo comes, never a spinner and never a big blurry picture left standing (design rule 6); in
/// the grids a soft tinted ground instead of a grey slab, the photo fading in once it is there
/// (at once when it was in memory), and a video's length only where it leaves the photo free.
@Suite("Calm placeholders while loading (DS-18)")
struct LoadingPlaceholderTests {
    /// An iPhone 15's screen in pixels.
    let screen = PixelSize(width: 1179, height: 2556)

    private func picture(delivered: PixelSize?, original: PixelSize? = nil, answered: Bool = true,
                         preview: Bool = false) -> ViewerPicture {
        ViewerPicture.choose(preview: preview, delivered: delivered, answered: answered, original: original, screen: screen)
    }

    // MARK: Photo view

    /// While the photo comes, the thumbnail the grid showed, from memory, as Photos does; without
    /// one the black page. Never a spinner.
    @Test func whileThePhotoComesThePreviewFromMemoryShows() {
        #expect(picture(delivered: nil, answered: false, preview: true) == .waiting(preview: true))
        #expect(picture(delivered: nil, answered: false, preview: false) == .waiting(preview: false))
        // A picture that came replaces the preview.
        #expect(picture(delivered: PixelSize(width: 2358, height: 1768), answered: true, preview: true) == .sharp)
    }

    /// A picture sharp at the screen's size shows: it brings at least 70 % of the pixels it
    /// fills, as the grids' thumbnails and the covers count it (`ThumbnailRequest.sharpShare`).
    @Test func aSharpPictureShows() {
        let photo = PixelSize(width: 4032, height: 3024)
        #expect(picture(delivered: PixelSize(width: 2358, height: 1768), original: photo) == .sharp)
        #expect(picture(delivered: PixelSize(width: 1179, height: 884), original: photo) == .sharp)
        // Stretched 1.4 times it is still sharp, 1.5 times it is not.
        #expect(picture(delivered: PixelSize(width: 842, height: 632), original: photo) == .sharp)
        #expect(picture(delivered: PixelSize(width: 786, height: 590), original: photo) == .unavailable)
        // A panorama is fitted by its width, a tall screenshot by its height.
        #expect(picture(delivered: PixelSize(width: 4000, height: 800), original: PixelSize(width: 16000, height: 3200)) == .sharp)
        #expect(picture(delivered: PixelSize(width: 1000, height: 2200), original: PixelSize(width: 1179, height: 2556)) == .sharp)
    }

    /// Only the small preview Photos keeps of a photo whose original is in iCloud: the calm note
    /// says why, no big blurry picture stands (design rule 6). Nothing at all: the note too.
    @Test func aBlurryPreviewNeverStandsBig() {
        let photo = PixelSize(width: 4032, height: 3024)
        #expect(picture(delivered: PixelSize(width: 360, height: 270), original: photo) == .unavailable)
        #expect(picture(delivered: PixelSize(width: 360, height: 270)) == .unavailable)
        #expect(picture(delivered: nil, original: photo) == .unavailable)
        #expect(picture(delivered: PixelSize(width: 0, height: 0), original: photo) == .unavailable)
    }

    /// A photo that is small itself (an old 640 × 480 photo, a picture from a message) shows as
    /// large as it is, as Photos shows it: it is the whole photo, not a preview of it.
    @Test func aSmallPhotoShowsAsLargeAsItIs() {
        let small = PixelSize(width: 640, height: 480)
        #expect(picture(delivered: small, original: small) == .sharp)
        #expect(picture(delivered: PixelSize(width: 600, height: 450), original: small) == .sharp)
        // Its own small preview is not the photo.
        #expect(picture(delivered: PixelSize(width: 160, height: 120), original: small) == .unavailable)
    }

    /// Before the page has a size nothing is called blurry.
    @Test func withoutAScreenNothingIsCalledBlurry() {
        let none = ViewerPicture.choose(preview: false, delivered: PixelSize(width: 160, height: 120), answered: true,
                                        original: nil, screen: PixelSize(width: 0, height: 0))
        #expect(none == .sharp)
    }

    // MARK: Thumbnails

    /// A thumbnail that was in memory, or came at once, is simply there: a cell rebuilt or
    /// scrolled back never flickers. One that took a moment fades in, a fade with Reduce Motion
    /// too (it does not move), as the covers do.
    @Test func aThumbnailFadesInOnlyAfterAWait() {
        #expect(ThumbnailAppearance.fade(seeded: true, waited: 1) == nil)
        #expect(ThumbnailAppearance.fade(seeded: false, waited: 0) == nil)
        #expect(ThumbnailAppearance.fade(seeded: false, waited: 0.05) == nil)
        #expect(ThumbnailAppearance.fade(seeded: false, waited: 0.06) == 0.2)
        #expect(ThumbnailAppearance.fade(seeded: false, waited: 3) == 0.2)
        #expect(ThumbnailAppearance.fade(seeded: false, waited: .nan) == nil)
    }

    /// The ground while a thumbnail comes: a soft wash of the accent over the card, the covers'
    /// family, never a flat grey; a little stronger in dark mode and with Increase Contrast, where
    /// a faint wash would vanish, and never strong enough to be a coloured block.
    @Test func theGroundIsASoftTintNeverAGreySlab() {
        let all = [false, true].flatMap { dark in [false, true].map { ThumbnailGroundTint(dark: dark, increasedContrast: $0) } }
        for tint in all {
            #expect(tint.top > 0 && tint.bottom > 0, "\(tint): a grey slab")
            #expect(tint.top > tint.bottom, "\(tint): flat")
            #expect(tint.top <= 0.25, "\(tint): a coloured block")
        }
        let light = ThumbnailGroundTint(dark: false, increasedContrast: false)
        let dark = ThumbnailGroundTint(dark: true, increasedContrast: false)
        #expect(dark.top > light.top)
        #expect(ThumbnailGroundTint(dark: false, increasedContrast: true).top > light.top)
        #expect(ThumbnailGroundTint(dark: true, increasedContrast: true).top > dark.top)
    }

    /// A video's length stands on its thumbnail only where it leaves most of the photo free: in a
    /// dense grid, or with a large text size, it gives way (VoiceOver still says it).
    @Test func theLengthShowsOnlyWhereItLeavesThePhotoFree() {
        #expect(VideoBadge.fits(badgeWidth: 42, tileWidth: 110))
        #expect(VideoBadge.fits(badgeWidth: 42, tileWidth: 78))
        #expect(!VideoBadge.fits(badgeWidth: 58, tileWidth: 78))
        #expect(!VideoBadge.fits(badgeWidth: 42, tileWidth: 50))
        #expect(!VideoBadge.fits(badgeWidth: 0, tileWidth: 0))
    }
}
