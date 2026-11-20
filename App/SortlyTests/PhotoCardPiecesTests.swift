import CoreGraphics
import SwiftUI
import Testing
import UIKit
import SortlyCore
@testable import Sortly

/// Design wave 1: the parts of the photo cards that are worked out rather than drawn. When a
/// cover counts as sharp (design rule 7: never a big blurry picture), where a cover is cropped
/// ("Bildausschnitt": screenshots keep their top, portraits their upper third), how wide the
/// shelf makes its cards (draft E1) and how the covers are counted for the diagnostic report.
/// Which photos a cover tries is `CoverCandidatesTests` (core, Linux); how the cards look is for
/// the screens' UI tests and screenshots.
@Suite("Photo cards: sharp covers, crop, shelf, counts")
@MainActor
struct PhotoCardPiecesTests {
    /// An image of `width` × `height` pixels.
    func image(_ width: CGFloat, _ height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in }
    }

    // MARK: Sharp enough

    @Test func aThumbnailMadeAtTheSizeIsSharpASmallPreviewIsNot() {
        // A card of 172 pt at 3x, 4:3: 516 × 387 px.
        let target = CGSize(width: 516, height: 387)
        #expect(ThumbnailRequest.isSharp(image(516, 387), for: target))
        // Photos' own thumbnail can be a little smaller: sharp down to 70 % per side.
        #expect(ThumbnailRequest.isSharp(image(362, 272), for: target))
        #expect(!ThumbnailRequest.isSharp(image(360, 270), for: target))
        // The small preview Photos keeps of a photo whose original is in iCloud: stretched more
        // than three times, never a cover.
        #expect(!ThumbnailRequest.isSharp(image(160, 120), for: target))
    }

    @Test func aWideCoverDoesNotTakeATallPreviewSharpOnlyOnItsShortSide() {
        // A card across the page, 361 × 180 pt at 3x.
        let wide = CGSize(width: 1083, height: 540)
        // A portrait preview of 480 × 640 px: its short side is 89 % of the cover's height, but
        // filled across the cover it is stretched 2.3 times.
        #expect(!ThumbnailRequest.isSharp(image(480, 640), for: wide))
        #expect(ThumbnailRequest.isSharp(image(1083, 1444), for: wide))
    }

    @Test func nothingToDrawIsNeverSharp() {
        #expect(!ThumbnailRequest.isSharp(image(500, 500), for: .zero))
        #expect(!ThumbnailRequest.isSharp(UIImage(), for: CGSize(width: 100, height: 100)))
    }

    // MARK: Crop

    @Test func screenshotsKeepTheirTop() {
        let screenshot = CGSize(width: 1179, height: 2556), card = CGSize(width: 343, height: 257)
        let focus = CoverLoader.focus(imageSize: screenshot, screenshot: true, target: card)
        #expect(focus == UnitPoint(x: 0.5, y: 0))
        let drawn = CoverLoader.placement(imageSize: screenshot, focus: focus, filling: card)
        #expect(drawn.minY == 0)
        #expect(abs(drawn.width - card.width) < 0.001)
    }

    @Test func aLandscapePhotoInAWideCardKeepsItsUpperPart() {
        // A 4:3 photo in a 2:1 card keeps 7 % to 73 % of its height: heads and the tops of
        // buildings stay, the foreground gives way.
        let photo = CGSize(width: 4032, height: 3024), card = CGSize(width: 360, height: 180)
        let focus = CoverLoader.focus(imageSize: photo, screenshot: false, target: card)
        #expect(focus == UnitPoint(x: 0.5, y: 0.4))
        let drawn = CoverLoader.placement(imageSize: photo, focus: focus, filling: card)
        #expect(abs(drawn.width - 360) < 0.001 && abs(drawn.height - 270) < 0.001)
        let top = -drawn.minY / drawn.height, bottom = (card.height - drawn.minY) / drawn.height
        #expect(abs(top - 0.0667) < 0.001)
        #expect(abs(bottom - 0.7333) < 0.001)
    }

    @Test func aPortraitIsCroppedAroundItsUpperThird() {
        let portrait = CGSize(width: 3024, height: 4032), card = CGSize(width: 344, height: 258)
        let focus = CoverLoader.focus(imageSize: portrait, screenshot: false, target: card)
        #expect(focus.x == 0.5 && abs(focus.y - 1.0 / 3.0) < 0.0001)
        let drawn = CoverLoader.placement(imageSize: portrait, focus: focus, filling: card)
        // The middle of the cover shows the point a third down the photo.
        let middle = (card.height / 2 - drawn.minY) / drawn.height
        #expect(abs(middle - 1.0 / 3.0) < 0.001)
    }

    @Test func cutAtTheSidesOrNotCutTheMiddleStays() {
        // A landscape photo in a square tile is cut at the sides: around its middle.
        #expect(CoverLoader.focus(imageSize: CGSize(width: 4032, height: 3024), screenshot: false,
                                  target: CGSize(width: 300, height: 300)) == .center)
        // The card's own format: nothing is cut.
        #expect(CoverLoader.focus(imageSize: CGSize(width: 400, height: 300), screenshot: false,
                                  target: CGSize(width: 800, height: 600)) == .center)
        // Sizes not known: the middle.
        #expect(CoverLoader.focus(imageSize: .zero, screenshot: false, target: CGSize(width: 800, height: 600)) == .center)
        #expect(CoverLoader.focus(imageSize: CGSize(width: 400, height: 300), screenshot: false, target: .zero) == .center)
    }

    @Test func theCropNeverLeavesAnEdgeEmpty() {
        let photo = CGSize(width: 3000, height: 4000), card = CGSize(width: 400, height: 200)
        for share in [0.0, 0.1, 1.0 / 3.0, 0.5, 0.9, 1.0] {
            let drawn = CoverLoader.placement(imageSize: photo, focus: UnitPoint(x: share, y: share), filling: card)
            #expect(drawn.minX <= 0 && drawn.maxX >= card.width - 0.001)
            #expect(drawn.minY <= 0 && drawn.maxY >= card.height - 0.001)
        }
        // An image without a size still fills the cover.
        let empty = CoverLoader.placement(imageSize: .zero, focus: .center, filling: card)
        #expect(empty.width >= card.width && empty.height >= card.height)
    }

    // MARK: Shelf

    @Test func twoCardsAsInTheDraftAndTheThirdPeeksIn() {
        // Draft E1: a 393 pt iPhone, 16 pt margins: 361 pt for two cards and the 12 pt between.
        let width = CardShelfMetrics.cardWidth(container: 361, count: 2, spacing: 12)
        #expect(width == 172)
        // After the margin, two cards and their gaps, the screen goes on: the third one shows.
        #expect(16 + 2 * (width + 12) < 393)
        // The small iPhone, 375 pt.
        #expect(CardShelfMetrics.cardWidth(container: 343, count: 2, spacing: 12) == 163)
        // One card a row: the width less the peek.
        #expect(CardShelfMetrics.cardWidth(container: 361, count: 1, spacing: 12) == 356)
    }

    @Test func aShelfCardIsNeverWithoutWidth() {
        #expect(CardShelfMetrics.cardWidth(container: 0, count: 0, spacing: 12) == 1)
        #expect(CardShelfMetrics.cardWidth(container: 361, count: -3, spacing: 12) == 356)
        #expect(CardShelfMetrics.cardWidth(container: 20, count: 5, spacing: 12) == 1)
    }

    // MARK: Counts for the diagnostic report

    @Test func eachCoverCountsOncePerSize() {
        var tally = CoverStats.Tally()
        #expect(tally.lines == ["covers none shown yet"])
        tally.note(.sharp, key: "a#1029")
        // The same cover scrolled into view again.
        tally.note(.sharp, key: "a#1029")
        tally.note(.sharpLater, key: "b#1029")
        tally.note(.onlyBlurry, key: "c#1029")
        tally.note(.nothing, key: "d#516")
        // The same cover at another size (another card, the other orientation).
        tally.note(.sharp, key: "a#516")
        #expect(tally.lines == ["covers 5: sharp 2, sharp after another 1, no sharp photo on the device 2 (only a blurry preview 1, nothing 1)"])
    }

    @Test func aCoverIsKnownByItsFirstPhotoAndWidthAndTheReportHasNoIDs() {
        let request = CoverLoader.Request(ids: ["photo-1", "photo-2"], pixels: CGSize(width: 1029.4, height: 772))
        #expect(CoverStats.key(for: request) == "photo-1#1029")
        var tally = CoverStats.Tally()
        tally.note(.sharp, key: CoverStats.key(for: request))
        #expect(tally.lines.allSatisfy { !$0.contains("photo-1") })
    }

    @Test func pastTheLimitNewCoversStillCount() {
        let limit = CoverStats.Tally.seenLimit
        var tally = CoverStats.Tally()
        for index in 0..<limit { tally.note(.sharp, key: "k\(index)") }
        // Not remembered any more: counted each time.
        tally.note(.nothing, key: "late")
        tally.note(.nothing, key: "late")
        // Remembered: counted once.
        tally.note(.sharp, key: "k0")
        #expect(tally.lines == ["covers \(limit + 2): sharp \(limit), sharp after another 0, no sharp photo on the device 2 (only a blurry preview 0, nothing 2)"])
    }
}
