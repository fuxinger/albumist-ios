import SwiftUI
import UIKit
import AlbumistCore

/// Loads covers for `CoverPhoto`: the first of the candidates that is sharp at the drawn size.
@MainActor
enum CoverLoader {
    /// How many ids a cover tries at most: each one is a request to Photos, and a suggestion whose
    /// first photos are all only in iCloud has little chance with its next ones.
    static let attempts = 4

    /// The waits before a cover asks again when Photos did not answer: three more tries, the
    /// first after a second (each try waits for Photos up to its own limit,
    /// `PhotoKitLibrary.imageFetchLimit`). Then the cover keeps its calm surface until it is
    /// shown again.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(2)]

    struct Request: Equatable, Sendable {
        var ids: [AssetID]
        /// The drawn size in pixels.
        var pixels: CGSize
    }

    struct Loaded {
        var ids: [AssetID]
        var shown: Shown
        /// What the diagnostic report counts (`CoverStats`); nil while Photos did not answer
        /// for a photo: nothing is known then, and the cover asks again.
        var counted: CoverStats.Outcome?

        /// What the card is told; nil while nothing is known.
        var outcome: CoverOutcome? {
            switch counted {
            case .sharp?, .sharpLater?: .sharp
            case .onlyBlurry?, .nothing?: .noSharpPhoto
            case nil: nil
            }
        }
    }

    enum Shown {
        /// A sharp photo and where its crop is centred.
        case photo(UIImage, focus: UnitPoint)
        /// No sharp photo (yet): the placeholder, in the four colours of the first small preview
        /// there was (the cover's own, when it had one).
        case placeholder([Color])
    }

    static func load(_ request: Request, from source: any CoverSource = ThumbnailCache.shared) async -> Loaded {
        var blurry: UIImage?
        var unanswered = false
        candidates: for (index, id) in request.ids.enumerated() {
            guard !Task.isCancelled else { break }
            // The first one was not sharp (or not there): the others are looked up together,
            // one wait for Photos instead of one for each.
            if index == 1, request.ids.count > 2 { await source.lookUp(Array(request.ids.dropFirst())) }
            switch await source.cover(for: id, pixels: request.pixels) {
            case .image(let image, let screenshot):
                if Task.isCancelled { break candidates }
                if ThumbnailRequest.isSharp(image, for: request.pixels) {
                    let crop = Self.focus(imageSize: image.size, screenshot: screenshot, target: request.pixels)
                    return Loaded(ids: request.ids, shown: .photo(image, focus: crop), counted: index == 0 ? .sharp : .sharpLater)
                }
                if blurry == nil { blurry = image }
            case .missing:
                continue candidates
            case .noAnswer:
                // Photos is busy: the next ones would only wait for it too.
                unanswered = true
                break candidates
            }
        }
        return await placeholder(for: request, blurry: blurry, unanswered: unanswered)
    }

    /// No candidate was sharp: the placeholder in the colours of the first blurry preview, if
    /// there was one, counted unless Photos did not answer (nothing is known then, and the cover
    /// asks again).
    private static func placeholder(for request: Request, blurry: UIImage?, unanswered: Bool) async -> Loaded {
        var colors: [Color] = []
        if let blurry, !Task.isCancelled { colors = await palette(of: blurry) }
        guard !unanswered, !Task.isCancelled else { return Loaded(ids: request.ids, shown: .placeholder(colors), counted: nil) }
        return Loaded(ids: request.ids, shown: .placeholder(colors), counted: blurry == nil ? .nothing : .onlyBlurry)
    }

    /// Where the crop of a cover is centred, as a share of the image ("Bildausschnitt"; faces and
    /// the subject must not be cut):
    /// - a screenshot keeps its top, where its title is (as `ThumbnailGrid` shows them);
    /// - a photo in portrait format cut at top and bottom keeps its upper part: the crop is
    ///   centred a third down, as far as the image reaches, where faces and heads are in most
    ///   portraits (a portrait in a wide card loses its legs and the ground, not the heads);
    /// - a photo in landscape format cut at top and bottom loses a little more at the bottom than
    ///   at the top (centred 40 % down): heads of people and the tops of buildings and mountains
    ///   stay, the foreground gives way (a 4:3 photo in a 2:1 card keeps 7 % to 73 % of its height);
    /// - cut at the sides (a landscape photo in a square tile): around its middle.
    /// Cheap on purpose: no image analysis per cover (the analysis runs Vision on the same chips
    /// at the same time), only the formats of the image and the cover.
    nonisolated static func focus(imageSize: CGSize, screenshot: Bool, target: CGSize) -> UnitPoint {
        if screenshot { return UnitPoint(x: 0.5, y: 0) }
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else { return .center }
        let cutAtTopAndBottom = imageSize.width / imageSize.height < target.width / target.height
        guard cutAtTopAndBottom else { return .center }
        return UnitPoint(x: 0.5, y: imageSize.height > imageSize.width ? 1.0 / 3.0 : 0.4)
    }

    /// Where an image of `imageSize` is drawn so it fills `size` (aspect fill) with `focus` (a
    /// share of the image) as near the middle as the image reaches: never an empty edge. The
    /// origin is relative to the cover's top left corner, so it is zero or negative.
    nonisolated static func placement(imageSize: CGSize, focus: UnitPoint, filling size: CGSize) -> CGRect {
        let imageWidth = max(imageSize.width, 1), imageHeight = max(imageSize.height, 1)
        let scale = max(size.width / imageWidth, size.height / imageHeight)
        let drawn = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let x = min(0, max(size.width - drawn.width, size.width / 2 - focus.x * drawn.width))
        let y = min(0, max(size.height - drawn.height, size.height / 2 - focus.y * drawn.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: drawn)
    }

    /// Four calm colours of a preview, worked out off the main thread (`PhotoPalette.sample`).
    private static func palette(of image: UIImage) async -> [Color] {
        let preview = Preview(image: image)
        return await Task.detached(priority: .utility) { () -> [Color] in
            guard let cgImage = preview.image.cgImage else { return [] }
            return PhotoPalette.sample(cgImage)
        }.value
    }

    /// A preview handed to the task that samples it; it is only read there.
    private struct Preview: @unchecked Sendable { let image: UIImage }
}

/// Where `CoverLoader` gets its photos: `ThumbnailCache` (Photos, on the device only); the tests
/// give their own.
@MainActor
protocol CoverSource {
    func cover(for id: AssetID, pixels: CGSize) async -> CoverFetch
    /// Looks the ids up in one batch before they are asked for one by one.
    func lookUp(_ ids: [AssetID]) async
}

extension ThumbnailCache: CoverSource {}

/// How the covers of this launch came out, for the diagnostic report (design report, wave 1:
/// "Zähler für unscharfe Titelbilder"): how many found a sharp photo on the device at once, how
/// many only after a blurry one, and how many found none (only a small blurry preview, or
/// nothing at all) and showed the calm placeholder. Each cover counts once per size it is drawn
/// at (its first id and width), however often it is scrolled into view. Thread-safe and cheap: a
/// lock around a few counts.
enum CoverStats {
    enum Outcome: Sendable {
        /// The first candidate was sharp.
        case sharp
        /// A later candidate was sharp after an earlier one was only blurry or missing.
        case sharpLater
        /// No candidate was sharp; at least one had a small blurry preview on the device.
        case onlyBlurry
        /// No candidate had anything on the device (or Photos did not know them).
        case nothing
    }

    /// The counts: each cover once per size it is drawn at.
    struct Tally: Sendable {
        private var outcomes: [Outcome: Int] = [:]
        private var seen: Set<String> = []
        /// Covers remembered so they count once; beyond this many each new one still counts.
        static let seenLimit = 5000

        /// Counts `outcome` unless the cover `key` (`CoverStats.key`) was counted before.
        mutating func note(_ outcome: Outcome, key: String) {
            if seen.contains(key) { return }
            if seen.count < Self.seenLimit { seen.insert(key) }
            outcomes[outcome, default: 0] += 1
        }

        /// One line, counts only (no photo ids).
        var lines: [String] {
            let sharp = outcomes[.sharp] ?? 0, later = outcomes[.sharpLater] ?? 0
            let blurry = outcomes[.onlyBlurry] ?? 0, nothing = outcomes[.nothing] ?? 0
            let total = sharp + later + blurry + nothing
            guard total > 0 else { return ["covers none shown yet"] }
            return ["covers \(total): sharp \(sharp), sharp after another \(later), "
                    + "no sharp photo on the device \(blurry + nothing) (only a blurry preview \(blurry), nothing \(nothing))"]
        }
    }

    private static let tally = LockedBox(Tally())

    /// A cover as it is counted: its first id at its width in pixels.
    static func key(for request: CoverLoader.Request) -> String {
        "\(request.ids.first?.rawValue ?? "")#\(Int(request.pixels.width))"
    }

    static func note(_ outcome: Outcome, for request: CoverLoader.Request) {
        let cover = Self.key(for: request)
        tally.update { $0.note(outcome, key: cover) }
    }

    /// The lines for the diagnostic report (`AppModel.diagnosticReport`: `lines += CoverStats.reportLines()`).
    static func reportLines() -> [String] {
        tally.value.lines
    }
}
