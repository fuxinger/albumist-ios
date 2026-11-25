import SwiftUI
import UIKit
import AlbumistCore

/// Where the suggestions' cards are on screen and on which tab, for the small moment
/// (`quickCreateMomentSource`), where each tab's bar begins (`QuickCreateMomentBarProbe`), and
/// what the scroll of the screens with cards says of the tab bar (`quickCreateMomentScrollTrail`;
/// decided in the core, `QuickCreateMoment.TabWatch`). Written while cards move and lists scroll,
/// read once per banner: not observed, so a scrolling list draws nothing again.
@MainActor
final class QuickCreateMomentSources {
    static let shared = QuickCreateMomentSources()

    /// A card on screen.
    struct Source {
        /// Its suggestion as the card shows it: the moment never depends on the analysis still
        /// having it as the banner comes (it may make its suggestions anew while the album is
        /// made; a list keeps the made card meanwhile).
        var proposal: AlbumProposal
        /// The card's frame on screen (`.global`).
        var card: CGRect
        /// Its cover's aspect ratio as the card passes it to `PhotoCard`.
        var aspectRatio: CGFloat
        var accessibilitySize: Bool
        var displayScale: CGFloat
        /// The tab's screen it is on (`QuickCreateMomentBarProbe`); nil outside the tabs.
        var place: UUID?
    }

    /// A tab's screen: where the tab bar begins and where the safe area begins at the top
    /// (`QuickCreateMomentBarProbe`, measured over the whole screen with its safe area). The top
    /// is the status bar's edge: the probe is outside the navigation stack.
    struct Place: Equatable {
        var barTop: CGFloat
        var top: CGFloat

        init(frame: CGRect, safeArea: EdgeInsets) {
            barTop = frame.maxY - safeArea.bottom
            top = frame.minY + safeArea.top
        }
    }

    /// A cover to fly from: where it is, and its sharp photo at hand (nil: none).
    struct Photo {
        var cover: QuickCreateMoment.Rect
        var image: UIImage?
        var focus: UnitPoint
    }

    private var sources: [UUID: Source] = [:]
    /// The tabs, the screens with cards that scroll on them, and the tab bar's trail.
    private var watch = QuickCreateMoment.TabWatch()

    /// The app's clock for the watch, in seconds: a screen that shows within
    /// `TabWatch.arrivalTime` of its tab came with it, not back from a pop.
    private static var now: Double {
        ProcessInfo.processInfo.systemUptime
    }

    /// The screen of the tab that shows; nil before it was measured.
    var place: QuickCreateMoment.TabPlace? {
        watch.place
    }

    /// Whether the tab bar is open, as far as the scroll of the screens with cards tells (review
    /// E of design wave 2, finding 5; review E2, N1 and N2).
    var barOpen: Bool {
        watch.barOpen
    }

    func note(_ source: Source, as token: UUID) {
        sources[token] = source
    }

    func forget(_ token: UUID) {
        sources[token] = nil
    }

    func note(_ place: Place, as token: UUID) {
        watch.measured(QuickCreateMoment.TabPlace(barTop: Double(place.barTop), top: Double(place.top)), for: token)
    }

    /// A tab's screen shows (`shown`) or went (switched to another tab, or covered).
    func show(place token: UUID, _ shown: Bool) {
        watch.show(place: token, shown, now: Self.now)
    }

    /// The next tab is chosen in code (Siri, Spotlight, a route), not on the bar: it may be shrunk.
    func tabChosenInCode() {
        watch.tabChosenInCode()
    }

    /// A screen with cards shows on the tab `place` (`quickCreateMomentScrollTrail`).
    func appeared(_ screen: UUID, on place: UUID, at spot: QuickCreateMoment.ScrollSpot?, again: Bool) {
        watch.appeared(screen: screen, on: place, at: spot, again: again, now: Self.now)
    }

    func scrolled(_ screen: UUID, to spot: QuickCreateMoment.ScrollSpot, _ motion: QuickCreateMoment.ScrollMotion) {
        watch.scrolled(screen: screen, to: spot, motion)
    }

    func disappeared(_ screen: UUID) {
        watch.disappeared(screen: screen)
    }

    /// The middle of the symbol of the tab "Alben" on `screen` (`QuickCreateMoment.TabBar`); nil
    /// before the tabs were measured, or while a screen hides the tab bar.
    func albumsTab(on screen: CGRect, rightToLeft: Bool) -> QuickCreateMoment.Point? {
        guard let place else { return nil }
        return QuickCreateMoment.TabBar.albumsTab(screenWidth: Double(screen.width), barTop: place.barTop,
                                                  screenBottom: Double(screen.maxY), rightToLeft: rightToLeft)
    }

    /// The card of the suggestion `id` on the tab that shows whose cover is on screen, with the
    /// sharp photo it shows: the first of its cover's candidates kept at the very size the card
    /// asked for it. Never for personal content (its card shows no photo).
    func photo(for id: AlbumistID, on screen: CGRect, model: AppModel) -> Photo? {
        guard let place, let shown = watch.shownPlace else { return nil }
        for source in sources.values where source.proposal.id == id && source.place == shown {
            let proposal = source.proposal
            let card = QuickCreateMoment.Rect(x: Double(source.card.minX), y: Double(source.card.minY),
                                              width: Double(source.card.width), height: Double(source.card.height))
            let cover = QuickCreateMoment.coverFrame(card: card, aspectRatio: Double(source.aspectRatio),
                                                     accessibilitySize: source.accessibilitySize)
            guard QuickCreateMoment.isOnScreen(cover, top: place.top, bottom: place.barTop,
                                               width: Double(screen.maxX)) else { continue }
            let personal = proposal.isSensitive || model.previewHidden(for: proposal)
            let kept = personal ? nil : keptCover(of: proposal, source: source, model: model)
            let focus = kept.map { CoverLoader.focus(imageSize: $0.image.size, screenshot: $0.screenshot, target: CGSize(width: 1, height: 1)) }
            return Photo(cover: cover, image: kept?.image, focus: focus ?? .center)
        }
        return nil
    }

    /// The sharp cover the card keeps (`CoverPhoto`): its candidates (the ids it tries, in its
    /// order) at the card's drawn size.
    private func keptCover(of proposal: AlbumProposal, source: Source, model: AppModel) -> CachedCover? {
        let pixels = QuickCreateMoment.coverPixels(cardWidth: Double(source.card.width), aspectRatio: Double(source.aspectRatio),
                                                   accessibilitySize: source.accessibilitySize, scale: Double(source.displayScale))
        let size = CGSize(width: pixels.width, height: pixels.height)
        let candidates = model.proposalCoverIDs(for: proposal).filter { !$0.rawValue.isEmpty }.prefix(CoverLoader.attempts)
        for id in candidates {
            if let kept = ThumbnailCache.shared.cachedCover(for: id, pixels: size) { return kept }
        }
        return nil
    }
}
