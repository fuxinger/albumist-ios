import SwiftUI
import UIKit
import AlbumistCore

/// The small moment after "Anlegen" on a card (draft E6, design wave 2): as the banner
/// "„Name“ angelegt · Widerrufen" comes, a small copy of the card's cover flies into the tab
/// "Alben" and lands there as a small album, with one light tap (`QuickCreateMoment` decides
/// when, where and along which path).
///
/// - Over the tabs only (`MainTabs`), where the banner shows; never to be tapped, hidden from
///   VoiceOver (the banner is announced and says what happened).
/// - The photo is the very image the card shows: its sharp cover from the device, from the covers'
///   store (`ThumbnailCache.cachedCover`). Nothing is loaded for it; no card on screen, a
///   placeholder, a personal suggestion or "Vorschau ausgeblendet": nothing flies.
/// - Reduce Motion: nothing flies; the small album fades in on the tab and out again.
/// - One haptic per album, as before: the success tap with the banner, or the light tap as the
///   cover lands instead (`QuickCreateMoment.haptic`). The tab bar stays open while the small
///   album comes to it (`holdsTabBar`: it shrinks while scrolling).
struct QuickCreateMomentLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    /// The tab bar stays open while the small album comes to it.
    @Binding var holdsTabBar: Bool
    /// The tab bar shows "Alben" in its place: not while the search tab is chosen (the bar is then
    /// the search field beside one round button), so nothing flies there.
    var showsAlbumsTab: Bool
    @State private var moment: QuickCreateMomentRun?
    @State private var progress: CGFloat = 0
    @State private var fading = false
    /// The success tap with the banner, when nothing flies.
    @State private var successes = 0
    /// The light tap as the flying cover lands.
    @State private var landings = 0
    /// The layer on screen: it covers the screen (the cards are measured on screen).
    @State private var screen: CGRect = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let moment {
                MomentAlbum(moment: moment)
                    .modifier(MomentPlacement(progress: progress, flight: moment.flight, flies: moment.kind == .fly,
                                              origin: screen.origin))
                    .opacity(fading ? 0 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { screen = $0 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .sensoryFeedback(.success, trigger: successes)
        .sensoryFeedback(.impact(weight: .light), trigger: landings)
        .onChange(of: model.quickCreateBanner?.id) { old, new in begin(old: old, new: new) }
        .task(id: moment?.id) { await play() }
    }

    /// A new banner: what the moment does, and the haptic that goes with it.
    private func begin(old: AlbumistID?, new: AlbumistID?) {
        guard let new, new != old, let banner = model.quickCreateBanner, banner.id == new else { return }
        let sources = QuickCreateMomentSources.shared
        let tab = showsAlbumsTab ? sources.albumsTab(on: screen, rightToLeft: layoutDirection == .rightToLeft) : nil
        let photo = tab == nil ? nil : sources.photo(for: banner.proposalID, on: screen, model: model)
        let kind = QuickCreateMoment.kind(reduceMotion: reduceMotion, sourceOnScreen: photo != nil, hasSharpCover: photo?.image != nil)
        switch QuickCreateMoment.haptic(for: kind) {
        case .successWithBanner: successes += 1
        case .lightTapAtLanding: break
        }
        guard kind != .none, let tab, let photo, let image = photo.image else {
            finish()
            return
        }
        progress = 0
        fading = false
        moment = QuickCreateMomentRun(id: banner.id, kind: kind, flight: QuickCreateMoment.Flight(cover: photo.cover, to: tab),
                                      image: image, focus: photo.focus)
        // "Alben" must be in its place while the small album comes to it, flying or fading in.
        holdsTabBar = true
    }

    private func play() async {
        guard let moment else { return }
        switch moment.kind {
        case .fly:
            // The banner starts to come and the tab bar opens first.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.42, 0, 0.18, 1, duration: QuickCreateMoment.Flight.duration)) { progress = 1 }
            try? await Task.sleep(for: .seconds(QuickCreateMoment.Flight.duration))
            guard !Task.isCancelled else { return }
            landings += 1
            // On the tab for a moment, then gone.
            try? await Task.sleep(for: .milliseconds(450))
        case .fadeAtTab:
            withAnimation(.easeOut(duration: 0.25)) { progress = 1 }
            try? await Task.sleep(for: .milliseconds(850))
        case .none:
            break
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) { fading = true }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        finish()
    }

    private func finish() {
        moment = nil
        holdsTabBar = false
    }
}

/// One moment: the album that was made, the path and the photo.
struct QuickCreateMomentRun: Identifiable {
    let id: AlbumistID
    let kind: QuickCreateMoment.Kind
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
/// solid (draft E6); with Reduce Motion on the tab, fading in. Round corners in proportion, a white
/// edge (the card colour in dark mode) and a soft shadow.
private struct MomentPlacement: ViewModifier, Animatable {
    var progress: CGFloat
    let flight: QuickCreateMoment.Flight
    let flies: Bool
    let origin: CGPoint

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = Double(progress)
        let point = flies ? flight.point(at: t) : flight.end
        let side = CGFloat(flies ? flight.side(at: t) : QuickCreateMoment.Flight.endSide)
        let shape = RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
        return content
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.card, lineWidth: 2) }
            .shadow(color: .black.opacity(0.2), radius: 9, y: 8)
            .opacity(flies ? flight.opacity(at: t) : t)
            .position(x: CGFloat(point.x) - origin.x, y: CGFloat(point.y) - origin.y)
    }
}

/// Where the suggestions' cards are on screen, for the small moment (`quickCreateMomentSource`),
/// and where the tab bar begins (`showsQuickCreateBanner`). Written while cards move and read once
/// per banner: not observed, so a scrolling list draws nothing again.
@MainActor
final class QuickCreateMomentSources {
    static let shared = QuickCreateMomentSources()

    /// A card on screen.
    struct Source {
        var proposal: AlbumistID
        /// The card's frame on screen (`.global`).
        var card: CGRect
        /// Its cover's aspect ratio as the card passes it to `PhotoCard`.
        var aspectRatio: CGFloat
        var accessibilitySize: Bool
        var displayScale: CGFloat
    }

    /// A tab's screen: where the tab bar begins and where the safe area begins at the top
    /// (`QuickCreateMomentBarProbe`, measured over the whole screen with its safe area).
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
    /// Each tab's screen, and the tabs that show, the one shown last at the end.
    private var places: [UUID: Place] = [:]
    private var shownPlaces: [UUID] = []

    /// The screen of the tab that shows; nil before it was measured.
    var place: Place? {
        shownPlaces.last.flatMap { places[$0] }
    }

    func note(_ source: Source, as token: UUID) {
        sources[token] = source
    }

    func forget(_ token: UUID) {
        sources[token] = nil
    }

    func note(_ place: Place, as token: UUID) {
        places[token] = place
    }

    /// A tab's screen shows (`shown`) or went (switched to another tab).
    func show(place token: UUID, _ shown: Bool) {
        shownPlaces.removeAll { $0 == token }
        if shown { shownPlaces.append(token) }
    }

    /// The middle of the symbol of the tab "Alben" on `screen` (`QuickCreateMoment.TabBar`); nil
    /// before the tabs were measured.
    func albumsTab(on screen: CGRect, rightToLeft: Bool) -> QuickCreateMoment.Point? {
        guard let place, screen.width > 0, place.barTop < screen.maxY else { return nil }
        return QuickCreateMoment.TabBar.albumsTab(screenWidth: Double(screen.width), barTop: Double(place.barTop),
                                                  screenBottom: Double(screen.maxY), rightToLeft: rightToLeft)
    }

    /// The card of the suggestion `id` whose cover is on screen, with the sharp photo it shows:
    /// the first of its cover's candidates kept at the very size the card asked for it. Never for
    /// personal content (its card shows no photo).
    func photo(for id: AlbumistID, on screen: CGRect, model: AppModel) -> Photo? {
        guard let place, let proposal = model.proposals.first(where: { $0.id == id }) else { return nil }
        let personal = proposal.isSensitive || model.previewHidden(for: proposal)
        for source in sources.values where source.proposal == id {
            let card = QuickCreateMoment.Rect(x: Double(source.card.minX), y: Double(source.card.minY),
                                              width: Double(source.card.width), height: Double(source.card.height))
            let cover = QuickCreateMoment.coverFrame(card: card, aspectRatio: Double(source.aspectRatio),
                                                     accessibilitySize: source.accessibilitySize)
            guard QuickCreateMoment.isOnScreen(cover, top: Double(place.top), bottom: Double(place.barTop),
                                               width: Double(screen.maxX)) else { continue }
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
/// begins, over the whole screen with its safe area, while the tab shows. Draws nothing.
struct QuickCreateMomentBarProbe: ViewModifier {
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .background { probe }
            .onAppear { QuickCreateMomentSources.shared.show(place: token, true) }
            .onDisappear { QuickCreateMomentSources.shared.show(place: token, false) }
    }

    private var probe: some View {
        Color.clear
            .ignoresSafeArea()
            .onGeometryChange(for: QuickCreateMomentSources.Place.self) { proxy in
                QuickCreateMomentSources.Place(frame: proxy.frame(in: .global), safeArea: proxy.safeAreaInsets)
            } action: { place in
                QuickCreateMomentSources.shared.note(place, as: token)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Where the small moment after "Anlegen" starts (draft E6): the card of `proposal`, whose
    /// cover `PhotoCard` draws at `aspectRatio` across its top. Marks the card while it is on
    /// screen; nothing about it changes.
    func quickCreateMomentSource(_ proposal: AlbumistID, aspectRatio: CGFloat) -> some View {
        modifier(QuickCreateMomentSource(proposal: proposal, aspectRatio: aspectRatio))
    }
}

private struct QuickCreateMomentSource: ViewModifier {
    let proposal: AlbumistID
    let aspectRatio: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
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
            .onDisappear { QuickCreateMomentSources.shared.forget(token) }
    }

    private func note(_ card: CGRect) {
        let source = QuickCreateMomentSources.Source(proposal: proposal, card: card, aspectRatio: aspectRatio,
                                                     accessibilitySize: typeSize.isAccessibilitySize, displayScale: displayScale)
        QuickCreateMomentSources.shared.note(source, as: token)
    }
}
