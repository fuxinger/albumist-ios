import SwiftUI
import UIKit
import AlbumistCore

/// The small moment after "Anlegen" on a card (draft E6, design wave 2): as the banner
/// "„Name“ angelegt · Widerrufen" comes, a small copy of the card's cover flies towards the tab
/// "Alben" and fades into the tab bar as it reaches it (`QuickCreateMoment` decides when, where
/// and along which path).
///
/// - Over the tabs only (`MainTabs`), where the banner shows; never to be tapped, hidden from
///   VoiceOver (the banner is announced and says what happened).
/// - The photo is the very image the card shows: its sharp cover from the device, from the covers'
///   store (`ThumbnailCache.cachedCover`). Nothing is loaded for it; no card on screen, a
///   placeholder, a personal suggestion or "Vorschau ausgeblendet": nothing flies.
/// - Only into a tab bar that is open, as far as the scroll of the screens with cards tells
///   (`quickCreateMomentScrollTrail`, decided in `QuickCreateMoment.TabWatch`; review E2 of design
///   wave 2, N1 and N2); the bar is never held open for it (review E, finding 5).
/// - No landing: the cover is gone as it reaches the bar (`QuickCreateMoment.Flight.opacity`), so a
///   few points of the worked-out tab do not show (finding 4).
/// - Reduce Motion: nothing flies.
/// - No haptic of its own: the tabs give the success tap with every banner, as before the moment,
///   whether or not the cover flies (finding 6).
struct QuickCreateMomentLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    /// The tab bar shows "Alben" in its place: not while the search tab is chosen (the bar is then
    /// the search field beside one round button), so nothing flies there.
    var showsAlbumsTab: Bool
    /// The banner whose card is looked at (`begin`).
    @State private var pending: AlbumistID?
    @State private var moment: QuickCreateMomentRun?
    @State private var progress: CGFloat = 0
    /// The layer on screen: it covers the whole screen (the cards are measured on screen).
    @State private var screen: CGRect = .zero

    /// How long after the banner came the card is looked at: a list that lost the made suggestion
    /// while the album was made (the analysis made its suggestions anew) puts its card back as the
    /// banner comes, and has done so by then.
    private static let lookDelay: Duration = .milliseconds(80)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let moment {
                MomentAlbum(moment: moment)
                    .modifier(MomentPlacement(progress: progress, flight: moment.flight, origin: screen.origin))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Measured inside the area it ignores, where this frame covers the whole screen: what
        // `ignoresSafeArea()` itself reports is the safe frame (review E of design wave 2, finding 2).
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { screen = $0 }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: model.quickCreateBanner?.id) { old, new in
            if let new, new != old { pending = new }
        }
        .task(id: pending) { await begin() }
        .task(id: moment?.id) { await play() }
    }

    /// A new banner: whether its card's cover flies. A banner without a flight leaves a cover still
    /// flying for the one before.
    private func begin() async {
        guard let pending else { return }
        try? await Task.sleep(for: Self.lookDelay)
        guard !Task.isCancelled, let banner = model.quickCreateBanner, banner.id == pending else { return }
        let sources = QuickCreateMomentSources.shared
        let tab = showsAlbumsTab ? sources.albumsTab(on: screen, rightToLeft: layoutDirection == .rightToLeft) : nil
        let photo = tab == nil ? nil : sources.photo(for: banner.proposalID, on: screen, model: model)
        let kind = QuickCreateMoment.kind(reduceMotion: reduceMotion, sourceOnScreen: photo != nil,
                                          hasSharpCover: photo?.image != nil, barOpen: sources.barOpen)
        guard kind == .fly, let tab, let photo, let image = photo.image else { return }
        progress = 0
        moment = QuickCreateMomentRun(id: banner.id, flight: QuickCreateMoment.Flight(cover: photo.cover, to: tab),
                                      image: image, focus: photo.focus)
    }

    /// The flight; the cover is gone as it reaches the bar.
    private func play() async {
        guard let flying = moment else { return }
        withAnimation(.timingCurve(0.42, 0, 0.18, 1, duration: QuickCreateMoment.Flight.duration)) { progress = 1 }
        try? await Task.sleep(for: .seconds(QuickCreateMoment.Flight.duration))
        guard !Task.isCancelled, moment?.id == flying.id else { return }
        moment = nil
    }
}

/// One moment: the album that was made, the path and the photo.
struct QuickCreateMomentRun: Identifiable {
    let id: AlbumistID
    let flight: QuickCreateMoment.Flight
    let image: UIImage
    let focus: UnitPoint
}

/// The small album: the card's photo, cropped square.
private struct MomentAlbum: View {
    let moment: QuickCreateMomentRun

    var body: some View {
        Color.clear
            .overlay {
                GeometryReader { proxy in
                    let drawn = CoverLoader.placement(imageSize: moment.image.size, focus: moment.focus, filling: proxy.size)
                    Image(uiImage: moment.image)
                        .resizable()
                        .frame(width: drawn.width, height: drawn.height)
                        .offset(x: drawn.minX, y: drawn.minY)
                }
            }
    }
}

/// Where the small album is at `progress`: along the path, ever smaller, a faint copy that gets
/// solid and fades into the bar at the end (draft E6). Round corners in proportion, a white edge
/// (the card colour in dark mode) and a soft shadow.
private struct MomentPlacement: ViewModifier, Animatable {
    var progress: CGFloat
    let flight: QuickCreateMoment.Flight
    let origin: CGPoint

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = Double(progress)
        let point = flight.point(at: t)
        let side = CGFloat(flight.side(at: t))
        let shape = RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
        return content
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.card, lineWidth: 2) }
            .shadow(color: .black.opacity(0.2), radius: 9, y: 8)
            .opacity(flight.opacity(at: t))
            .position(x: CGFloat(point.x) - origin.x, y: CGFloat(point.y) - origin.y)
    }
}

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

/// Measures a tab's screen for the small moment (`showsQuickCreateBanner`): where its tab bar
/// begins, over the whole screen with its safe area, while the tab shows; and tells the cards on
/// its screens which tab they are on. Draws nothing.
struct QuickCreateMomentBarProbe: ViewModifier {
    @State private var token = UUID()
    /// The last measure, noted again when the tab shows again (it may have been pruned).
    @State private var measured: QuickCreateMomentSources.Place?

    func body(content: Content) -> some View {
        content
            .environment(\.quickCreateMomentPlace, token)
            .background { probe }
            .onAppear {
                if let measured { QuickCreateMomentSources.shared.note(measured, as: token) }
                QuickCreateMomentSources.shared.show(place: token, true)
            }
            .onDisappear { QuickCreateMomentSources.shared.show(place: token, false) }
    }

    /// Measured inside the area it ignores: this clear view covers the whole screen and reports the
    /// safe area's insets, while what `ignoresSafeArea()` itself reports is the safe frame (review
    /// E of design wave 2, finding 2).
    private var probe: some View {
        Color.clear
            .onGeometryChange(for: QuickCreateMomentSources.Place.self) { proxy in
                QuickCreateMomentSources.Place(frame: proxy.frame(in: .global), safeArea: proxy.safeAreaInsets)
            } action: { place in
                measured = place
                QuickCreateMomentSources.shared.note(place, as: token)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct QuickCreateMomentPlaceKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The tab's screen these views are on, for the small moment (`QuickCreateMomentBarProbe`);
    /// nil outside the tabs.
    var quickCreateMomentPlace: UUID? {
        get { self[QuickCreateMomentPlaceKey.self] }
        set { self[QuickCreateMomentPlaceKey.self] = newValue }
    }
}

extension View {
    /// Where the small moment after "Anlegen" starts (draft E6): the card of `proposal`, whose
    /// cover `PhotoCard` draws at `aspectRatio` across its top. Marks the card while it is on
    /// screen; nothing about it changes.
    func quickCreateMomentSource(_ proposal: AlbumProposal, aspectRatio: CGFloat) -> some View {
        modifier(QuickCreateMomentSource(proposal: proposal, aspectRatio: aspectRatio))
    }
}

private struct QuickCreateMomentSource: ViewModifier {
    let proposal: AlbumProposal
    let aspectRatio: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    /// The tab's screen the card is on.
    @Environment(\.quickCreateMomentPlace) private var place
    @State private var token = UUID()
    /// The card's last frame, noted again when it shows again (back from another tab or screen,
    /// where nothing moved). Only the actions read it: the card is not drawn again for it.
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { card in
                frame = card
                note(card)
            }
            .onAppear {
                if let frame { note(frame) }
            }
            // A suggestion the analysis updates in place while its card rests (a new cover, now
            // personal): noted as the card shows it now, so the flying photo is never an older
            // cover (review E2 of design wave 2, N5).
            .onChange(of: proposal) {
                if let frame { note(frame) }
            }
            .onDisappear { QuickCreateMomentSources.shared.forget(token) }
    }

    private func note(_ card: CGRect) {
        let source = QuickCreateMomentSources.Source(proposal: proposal, card: card, aspectRatio: aspectRatio,
                                                     accessibilitySize: typeSize.isAccessibilitySize, displayScale: displayScale,
                                                     place: place)
        QuickCreateMomentSources.shared.note(source, as: token)
    }
}

extension View {
    /// The scroll of a screen whose cards offer "Anlegen" (the start page and the suggestion
    /// list), for the small moment after it (draft E6): whether the tab bar is open as the banner
    /// comes is read from the scroll itself, not from where the cards are (review E2 of design
    /// wave 2, N1 and N2). On the screen's scroll view; it reads the offset and the phase and
    /// changes nothing about the screen.
    func quickCreateMomentScrollTrail() -> some View {
        modifier(QuickCreateMomentScrollTrail())
    }
}

/// Hands a screen's scroll to `QuickCreateMomentSources` (decided in `QuickCreateMoment.TabWatch`):
/// each reading of the offset with whether the user moves it, and when the screen shows and goes.
/// Only on a tab's own stack (`quickCreateAtOnce`): a sheet over the tabs has its own stack and its
/// own scroll. Written in actions only, never read in a body: the screen is not drawn again for it.
private struct QuickCreateMomentScrollTrail: ViewModifier {
    /// The tab's screen it is on (`QuickCreateMomentBarProbe`), and whether this is a tab's stack.
    @Environment(\.quickCreateMomentPlace) private var place
    @Environment(\.quickCreateAtOnce) private var onTab
    @State private var token = UUID()
    /// The last reading, handed over as the screen shows again, and whether it showed before.
    @State private var spot: QuickCreateMoment.ScrollSpot?
    @State private var shownBefore = false
    /// Who moves the content now (`onScrollPhaseChange`).
    @State private var motion = QuickCreateMoment.ScrollMotion.other

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                motion = Self.motion(phase)
            }
            .onScrollGeometryChange(for: QuickCreateMoment.ScrollSpot.self) { geometry in
                QuickCreateMoment.ScrollSpot(
                    offset: Double(geometry.contentOffset.y), top: -Double(geometry.contentInsets.top),
                    end: Double(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height))
            } action: { _, now in
                spot = now
                guard onTab, place != nil else { return }
                QuickCreateMomentSources.shared.scrolled(token, to: now, motion)
            }
            .onAppear {
                guard onTab, let place else { return }
                QuickCreateMomentSources.shared.appeared(token, on: place, at: spot, again: shownBefore)
                shownBefore = true
            }
            .onDisappear { QuickCreateMomentSources.shared.disappeared(token) }
    }

    /// The user's scroll: a finger on the list, or the list slowing down after it. At rest
    /// (`idle`: something above the cards changed height, a card came or went) or animated by the
    /// system (`animating`: the end of a refresh, a tap on the status bar) is none, nor is a phase
    /// a later iOS adds.
    private static func motion(_ phase: ScrollPhase) -> QuickCreateMoment.ScrollMotion {
        switch phase {
        case .tracking, .interacting, .decelerating: .user
        default: .other
        }
    }
}
