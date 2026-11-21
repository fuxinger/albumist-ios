import CoreGraphics
import SwiftUI
import Testing
import UIKit
import AlbumistCore
@testable import Albumist

/// Design wave 1: the parts of the photo cards that are worked out rather than drawn. When a
/// cover counts as sharp (design rule 7: never a big blurry picture), where a cover is cropped
/// ("Bildausschnitt": screenshots keep their top, portraits their upper third), how wide the
/// shelf makes its cards (draft E1, fewer and wider with larger text), how high the compact
/// cards' texts are (all equally high), when a large card's action goes below its texts, how a
/// cover that Photos does not answer for asks again without telling or counting anything, that
/// a card is told its cover's outcome once, that covers are kept apart from the grids'
/// thumbnails and only when sharp, and how the covers are counted for the diagnostic report.
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

    @Test func withLargerTextTheShelfShowsFewerWiderCards() {
        let minimum = CardShelfMetrics.minimumCardWidth
        // The standard size: two cards on the 393 pt and on the small 375 pt iPhone.
        #expect(CardShelfMetrics.cardWidth(container: 361, count: 2, spacing: 12, minimum: minimum) == 172)
        #expect(CardShelfMetrics.cardWidth(container: 343, count: 2, spacing: 12, minimum: minimum) == 163)
        // One size larger (the headline grows from 17 to 19 pt): one card of 356 pt on the 393 pt
        // iPhone, still two on the 430 pt one.
        let larger = minimum * 19 / 17
        #expect(CardShelfMetrics.cardWidth(container: 361, count: 2, spacing: 12, minimum: larger) == 356)
        #expect(CardShelfMetrics.cardWidth(container: 398, count: 2, spacing: 12, minimum: larger) == 190)
        // The largest standard size (23 pt): one card everywhere on an iPhone.
        let largest = minimum * 23 / 17
        #expect(CardShelfMetrics.cardWidth(container: 398, count: 2, spacing: 12, minimum: largest) == 393)
        // Wherever two cards are shown, each is at least as wide as asked.
        for container in stride(from: 300.0, through: 700.0, by: 7.0) {
            for wanted in [minimum, larger, largest] {
                let width = CardShelfMetrics.cardWidth(container: container, count: 2, spacing: 12, minimum: wanted)
                #expect(width >= wanted || width == CardShelfMetrics.cardWidth(container: container, count: 1, spacing: 12))
            }
        }
    }

    @Test func aShelfCardIsNeverWithoutWidth() {
        #expect(CardShelfMetrics.cardWidth(container: 0, count: 0, spacing: 12) == 1)
        #expect(CardShelfMetrics.cardWidth(container: 361, count: -3, spacing: 12) == 356)
        #expect(CardShelfMetrics.cardWidth(container: 20, count: 5, spacing: 12) == 1)
        #expect(CardShelfMetrics.cardWidth(container: 361, count: 2, spacing: 0, minimum: 0) == 178)
        #expect(CardShelfMetrics.cardWidth(container: .infinity, count: 2, spacing: 12, minimum: 162) >= 1)
    }

    // MARK: Card texts

    /// Heights of one and two lines as SF Pro gives them at the standard size: the compact
    /// card's headline title and footnote subtitle.
    let compactLines = CardTextMetrics.Lines(titleOne: 22, titleTwo: 44, subtitleOne: 18, subtitleTwo: 36)

    @Test func compactCardsKeepTheHeightOfThreeLinesWhateverTheirTexts() {
        let spacing: CGFloat = 2
        let kept = CardTextMetrics.reservedHeight(lines: compactLines, spacing: spacing)
        #expect(kept == 64)
        // Every text a compact card can show fits in what it keeps: a title of one or two
        // lines, no subtitle or the lines the title leaves of three.
        let shown: [(title: CGFloat, subtitle: CGFloat?)] = [
            (22, nil), (44, nil), (22, 18), (22, 36), (44, 18),
        ]
        for text in shown {
            let height = text.title + (text.subtitle.map { spacing + $0 } ?? 0)
            #expect(height <= kept)
        }
        // At a larger size the lines grow and what is kept grows with them.
        let larger = CardTextMetrics.Lines(titleOne: 25, titleTwo: 50, subtitleOne: 20, subtitleTwo: 40)
        #expect(CardTextMetrics.reservedHeight(lines: larger, spacing: spacing) == 72)
    }

    @Test func theSubtitleGetsTheLinesTheTitleLeaves() {
        // A one-line title: the subtitle keeps its own two lines.
        #expect(CardTextMetrics.subtitleRoom(titleHeight: 22, lines: compactLines) == nil)
        // A two-line title: room for one line of the subtitle, never for a second.
        let room = CardTextMetrics.subtitleRoom(titleHeight: 44, lines: compactLines)
        #expect(room.map { $0 >= compactLines.subtitleOne && $0 < compactLines.subtitleTwo } == true)
        #expect(CardTextMetrics.titleTakesTwoLines(43, compactLines))
        #expect(!CardTextMetrics.titleTakesTwoLines(23, compactLines))
    }

    @Test func aLargeCardsActionGoesBelowWhenTheTextsWouldBeTooNarrow() {
        let minimum = CardTextMetrics.minimumTextBesideAction
        // The 393 pt iPhone (333 pt inside the card): "Anlegen" and "Benennen …" beside the texts.
        #expect(CardTextMetrics.actionBesideText(width: 333, actionWidth: 104, spacing: 12, minimumTextWidth: minimum))
        #expect(CardTextMetrics.actionBesideText(width: 333, actionWidth: 140, spacing: 12, minimumTextWidth: minimum))
        // The small iPhone (315 pt): "Benennen …" goes below, "Anlegen" stays beside.
        #expect(!CardTextMetrics.actionBesideText(width: 315, actionWidth: 140, spacing: 12, minimumTextWidth: minimum))
        #expect(CardTextMetrics.actionBesideText(width: 315, actionWidth: 104, spacing: 12, minimumTextWidth: minimum))
        // One size larger, the texts ask more room (the title grows from 20 to 22 pt).
        #expect(!CardTextMetrics.actionBesideText(width: 333, actionWidth: 152, spacing: 12, minimumTextWidth: minimum * 22 / 20))
    }

    // MARK: Loading a cover

    /// Photos as the tests want it: an answer per id, and what was asked.
    @MainActor
    final class FakeCovers: CoverSource {
        var answers: [AssetID: CoverFetch] = [:]
        private(set) var asked: [AssetID] = []
        private(set) var lookedUp: [[AssetID]] = []

        func cover(for id: AssetID, pixels: CGSize) async -> CoverFetch {
            asked.append(id)
            return answers[id] ?? .missing
        }

        func lookUp(_ ids: [AssetID]) async {
            lookedUp.append(ids)
        }
    }

    let request = CoverLoader.Request(ids: ["a", "b", "c", "d"], pixels: CGSize(width: 516, height: 387))

    @Test func whenPhotosDoesNotAnswerNothingIsToldOrCountedAndTheCoverAsksAgain() async {
        let photos = FakeCovers()
        photos.answers = ["a": .noAnswer]
        let loaded = await CoverLoader.load(request, from: photos)
        #expect(loaded.counted == nil)
        #expect(loaded.outcome == nil)
        // The next photos would only wait for Photos too: not asked.
        #expect(photos.asked == ["a"])
        // A few more tries, a second or two apart, then the cover waits until it is shown again.
        #expect(!CoverLoader.retryDelays.isEmpty && CoverLoader.retryDelays.count <= 3)
        #expect(CoverLoader.retryDelays.allSatisfy { $0 >= .seconds(1) && $0 <= .seconds(2) })
    }

    @Test func aBlurryPreviewThenNoAnswerIsNotYetNoPhoto() async {
        let photos = FakeCovers()
        photos.answers = ["a": .image(image(120, 90), screenshot: false), "b": .noAnswer]
        let loaded = await CoverLoader.load(request, from: photos)
        #expect(loaded.counted == nil && loaded.outcome == nil)
        #expect(photos.asked == ["a", "b"])
        // The calm surface in the preview's colours while it waits.
        guard case .placeholder(let colors) = loaded.shown else {
            Issue.record("expected the placeholder")
            return
        }
        #expect(colors.count == 4)
    }

    @Test func photosThatAreNotOnTheDeviceAreCountedAndTold() async {
        let photos = FakeCovers()
        let none = await CoverLoader.load(request, from: photos)
        #expect(none.counted == .nothing)
        #expect(none.outcome == .noSharpPhoto)
        #expect(photos.asked == ["a", "b", "c", "d"])
        // The others were looked up together once the first one had nothing.
        #expect(photos.lookedUp == [["b", "c", "d"]])
        photos.answers = ["c": .image(image(120, 90), screenshot: false)]
        let blurry = await CoverLoader.load(request, from: photos)
        #expect(blurry.counted == .onlyBlurry)
        #expect(blurry.outcome == .noSharpPhoto)
    }

    @Test func aSharpPhotoLaterInTheListIsShownAndCountedAsSuch() async {
        let photos = FakeCovers()
        photos.answers = ["a": .image(image(120, 90), screenshot: false), "b": .image(image(516, 387), screenshot: false)]
        let loaded = await CoverLoader.load(request, from: photos)
        #expect(loaded.counted == .sharpLater)
        #expect(loaded.outcome == .sharp)
        #expect(photos.asked == ["a", "b"])
        guard case .photo = loaded.shown else {
            Issue.record("expected the sharp photo")
            return
        }
    }

    @Test func aCardIsToldOnceForItsPhotos() {
        var latch = CoverOutcomeLatch()
        let ids: [AssetID] = ["a", "b"]
        #expect(latch.take(.noSharpPhoto, for: ids) == .noSharpPhoto)
        // The card turned smaller and its cover, at the smaller size, found the photo sharp
        // after all: the card is not told again (it would grow and shrink in turn).
        #expect(latch.take(.sharp, for: ids) == nil)
        #expect(latch.take(.noSharpPhoto, for: ids) == nil)
        // Another suggestion's photos in the same view: told for them.
        #expect(latch.take(.sharp, for: ["c"]) == .sharp)
        // Nothing to try is an outcome too, told once.
        var empty = CoverOutcomeLatch()
        #expect(empty.take(.noSharpPhoto, for: []) == .noSharpPhoto)
        #expect(empty.take(.noSharpPhoto, for: []) == nil)
    }

    // MARK: Kept covers

    @Test func onlySharpCoversAreKept() {
        let cache = ThumbnailCache()
        let pixels = CGSize(width: 516, height: 387)
        // The small preview of a photo in iCloud: shown as colours, never kept, so the photo is
        // asked for again and shows once it is on the device.
        #expect(!cache.keepCover(image(120, 90), screenshot: false, for: "blurry", pixels: pixels))
        #expect(cache.cachedCover(for: "blurry", pixels: pixels) == nil)
        #expect(cache.keepCover(image(516, 387), screenshot: true, for: "sharp", pixels: pixels))
        #expect(cache.cachedCover(for: "sharp", pixels: pixels)?.screenshot == true)
        // Kept for its size only.
        #expect(cache.cachedCover(for: "sharp", pixels: CGSize(width: 1029, height: 772)) == nil)
    }

    @Test func coversDoNotPushOutTheGridsThumbnails() {
        let cache = ThumbnailCache()
        #expect(ThumbnailCache.coverCostLimit < ThumbnailCache.thumbnailCostLimit)
        cache.keepThumbnail(image(240, 240), for: "grid", side: 80)
        // Forty covers across the page at 3x, five times what the covers' store holds.
        let wide = image(1029, 772), pixels = CGSize(width: 1029, height: 772)
        for index in 0..<40 {
            cache.keepCover(wide, screenshot: false, for: AssetID("cover-\(index)"), pixels: pixels)
        }
        #expect(cache.cachedThumbnail(for: "grid", side: 80) != nil)
        // A cover never lands among the thumbnails.
        #expect(cache.cachedThumbnail(for: "cover-39", side: 80) == nil)
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
