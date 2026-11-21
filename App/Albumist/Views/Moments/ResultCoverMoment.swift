import SwiftUI
import UIKit
import AlbumistCore

/// The top of the result after a run (draft E3, the big moment): the covers of the new albums
/// fanned above the count, lying down one after another, the main cover last and on top; without
/// a stack the symbol as before (undo, removal, failed steps, or no cover sharp on the device).
///
/// - Which albums and photos: `ResultCoverStack` (core), worked out once per plan as the result
///   shows and kept (`make`; review E of design wave 2, finding 7). The covers come from the
///   covers' store only (`ResultMomentLoader.kept`): what the preview loaded through `CoverLoader`
///   while the plan ran, sharp and from the device (never iCloud, never blurry). The result never
///   waits for Photos (finding 1): an album without a kept cover is left out, and with none the
///   symbol shows at once, with no room held for covers that might come (finding 9).
/// - The screen's success tap comes as the main cover lies down (`onSettled`, within
///   `ResultCoverFan.settleTime`; the screen lets it go after `successDeadline` anyway). No
///   haptic of its own.
/// - Reduce Motion: the covers only fade in where they lie; so in the UI tests, whose picture of
///   the result is taken a second after it shows.
/// - Decorative for VoiceOver: the count below ("10 neue Alben") is the heading that is read.
/// - Room: at most five covers, three at the accessibility text sizes; the fan shrinks to the
///   width and to the room `room` leaves (everything below it stays on screen), down to
///   `ResultCoverFan.minimumScale`; below that the screen scrolls.
/// - Once per result: coming back to the tab shows the covers where they lie.
struct ResultCoverMoment: View {
    let plan: ChangePlan
    /// What the stack knows of the suggestions the plan came from, taken as it started (nil:
    /// taken now, `AppModel.resultCoverStack`).
    let sources: ResultCoverSources?
    /// The symbol without a stack, and its colour.
    let symbol: String
    let tint: Color
    /// The height the screen has left for the stack; nil until measured.
    let room: CGFloat?
    /// The moment is there: the main cover lay down, or the symbol shows.
    let onSettled: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    /// The covers of `madeFor`, in the order of the stack: kept on the device as the result showed.
    @State private var covers: [ResultMomentCover] = []
    @State private var madeFor: AlbumistID?
    /// How many covers lie down, in laying order.
    @State private var laid = 0
    @State private var settledFor: AlbumistID?
    @State private var width: CGFloat = 360
    /// Changes as a moment starts: the symbol bounces once.
    @State private var bounce = false

    /// The covers only fade in where they lie: Reduce Motion, and the UI tests.
    private var calm: Bool {
        reduceMotion || UITestSupport.isRunning
    }

    private var limit: Int {
        typeSize.isAccessibilitySize ? ResultCoverStack.limitAtLargestText : ResultCoverStack.limit
    }

    /// The covers on the stack now (three of five at the accessibility sizes).
    private var shown: [ResultMomentCover] {
        guard madeFor == plan.id else { return [] }
        return Array(covers.prefix(ResultCoverFan.count(min(covers.count, limit))))
    }

    var body: some View {
        Group {
            if madeFor != plan.id {
                // Worked out as it appears (`make`), before its first frame.
                Color.clear.frame(height: 0)
            } else if shown.isEmpty {
                symbolView
            } else {
                fanArea
            }
        }
        .onChange(of: plan.id, initial: true) { make() }
        .task(id: plan.id) { await play() }
        // Left before the main cover lay down: the moment is over, and coming back shows the
        // covers where they lie.
        .onDisappear { settle(laidDown: true) }
    }

    // MARK: Parts

    private var symbolView: some View {
        Image(systemName: symbol)
            .font(.system(size: 56))
            .foregroundStyle(tint)
            .symbolEffect(.bounce, value: bounce)
            .accessibilityHidden(true)
    }

    /// The fan across the width, as high as it is drawn.
    private var fanArea: some View {
        let count = shown.count
        let scale = fanScale(count)
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(ResultCoverFan.size(count).height) * scale)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay { fan(scale: scale) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func fan(scale: CGFloat) -> some View {
        let count = shown.count
        let box = ResultCoverFan.bounds(count)
        let size = ResultCoverFan.size(count)
        let slots = ResultCoverFan.slots(count)
        let order = ResultCoverFan.layingOrder(count)
        return ZStack {
            ForEach(Array(order.enumerated()), id: \.element) { position, index in
                FannedCover(cover: shown[index], slot: slots[index], down: position < laid, calm: calm)
                    .position(x: CGFloat(slots[index].x - box.minX), y: CGFloat(slots[index].y - box.minY))
            }
        }
        .frame(width: CGFloat(size.width), height: CGFloat(size.height))
        .scaleEffect(scale)
    }

    /// The scale that fits `count` covers into the width and into the room left above the rest.
    private func fanScale(_ count: Int) -> CGFloat {
        let height = room.map { Double($0) } ?? .infinity
        return CGFloat(ResultCoverFan.scale(count: count, width: Double(width), height: height))
    }

    // MARK: Choreography

    /// Works the stack out for this plan, once: which albums and photos, and which covers are
    /// kept sharp on the device now. Nothing is loaded here.
    private func make() {
        guard madeFor != plan.id else { return }
        let stack = model.resultCoverStack(for: plan, taken: sources)
        covers = ResultMomentLoader.kept(stack, scale: displayScale)
        if settledFor != plan.id { laid = 0 }
        madeFor = plan.id
    }

    private func play() async {
        make()
        // Back on the tab: the covers lie where they lay.
        guard settledFor != plan.id else { return }
        let count = shown.count
        guard count > 0 else {
            bounce.toggle()
            settle(laidDown: true)
            return
        }
        if calm {
            withAnimation(.easeOut(duration: ResultCoverFan.fadeIn)) { laid = count }
            try? await Task.sleep(for: .seconds(ResultCoverFan.fadeIn))
        } else {
            for step in 1...count {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { laid = step }
                try? await Task.sleep(for: .seconds(step == count ? ResultCoverFan.lastFall : ResultCoverFan.layingStep))
                guard !Task.isCancelled else { return }
            }
        }
        guard !Task.isCancelled else { return }
        settle(laidDown: false)
    }

    /// The moment is there; `laidDown`: every cover lies where it belongs at once.
    private func settle(laidDown: Bool) {
        guard settledFor != plan.id else { return }
        settledFor = plan.id
        if laidDown { laid = ResultCoverStack.limit }
        onSettled()
    }
}

/// One cover of the stack and the card it stands for.
struct ResultMomentCover: Identifiable {
    let card: String
    let image: UIImage
    let focus: UnitPoint

    var id: String { card }
}

/// One cover in the fan: the photo cropped like a card's cover, a white edge (the card colour in
/// dark mode), a soft shadow (draft E3). Before it lies down it hangs a little higher, larger and
/// more turned, unseen; with Reduce Motion it only fades in where it lies.
private struct FannedCover: View {
    let cover: ResultMomentCover
    let slot: ResultCoverFan.Slot
    let down: Bool
    /// Reduce Motion: it only fades in where it lies.
    let calm: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // How far it still has to fall: none once it lies, none with Reduce Motion.
        let rise: CGFloat = down || calm ? 0 : 1
        return photo
            .frame(width: CGFloat(ResultCoverFan.cardWidth), height: CGFloat(ResultCoverFan.cardHeight))
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.card, lineWidth: 3) }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(down ? 0.22 : 0), radius: 15, y: 14)
            .scaleEffect(1 + 0.06 * rise)
            .rotationEffect(.degrees(slot.angle * Double(1 + 0.6 * rise)))
            .offset(y: -36 * rise)
            .opacity(down ? 1 : 0)
    }

    private var photo: some View {
        Color.clear
            .overlay {
                GeometryReader { proxy in
                    let drawn = CoverLoader.placement(imageSize: cover.image.size, focus: cover.focus, filling: proxy.size)
                    Image(uiImage: cover.image)
                        .resizable()
                        .frame(width: drawn.width, height: drawn.height)
                        .offset(x: drawn.minX, y: drawn.minY)
                }
            }
    }
}

/// The covers of the result's stack: loaded through `CoverLoader` (the cards' own loader: only
/// from the device, the first candidate that is sharp, kept in the covers' store) while the plan
/// runs (`prefetch`), and taken from that store as the result shows (`kept`), at the card's full
/// size whatever the fan is scaled to. The result never asks Photos itself.
@MainActor
enum ResultMomentLoader {
    /// How long the covers may load while the plan runs and the show plays; the screen cancels
    /// the loading as the result shows, or when the run ends without one.
    static let prefetchPatience: Duration = .seconds(20)
    /// Photos did not answer (busy with the run): the cover asks once more after this.
    static let retryDelay: Duration = .milliseconds(800)

    /// The size in pixels each cover is asked for and kept at.
    static func pixels(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(ResultCoverFan.cardWidth) * scale, height: CGFloat(ResultCoverFan.cardHeight) * scale)
    }

    /// Loads the covers of the stack ahead, card by card in order, while the plan runs: each card
    /// tries its own photos, and the sharp ones are kept in the covers' store. Nothing is shown.
    static func prefetch(_ stack: ResultCoverStack, scale: CGFloat) async {
        let pixels = pixels(scale: scale)
        let started = ContinuousClock.now
        var sharp = 0
        for card in stack.cards {
            guard sharp < ResultCoverStack.limit, !Task.isCancelled,
                  ContinuousClock.now - started < prefetchPatience else { return }
            let request = CoverLoader.Request(ids: card.candidates, pixels: pixels)
            var loaded = await CoverLoader.load(request)
            // Photos did not answer: asked once more while there is time.
            if loaded.counted == nil, !Task.isCancelled, ContinuousClock.now - started + retryDelay < prefetchPatience {
                try? await Task.sleep(for: retryDelay)
                loaded = await CoverLoader.load(request)
            }
            if case .photo = loaded.shown { sharp += 1 }
        }
    }

    /// The covers that lie on the stack (`ResultCoverStack.shown`), card by card in order, from
    /// the covers' store only: each card's first photo whose sharp cover is kept at the card's
    /// size. Asks Photos nothing, so the result never waits; an album without one is left out.
    static func kept(_ stack: ResultCoverStack, scale: CGFloat) -> [ResultMomentCover] {
        let pixels = pixels(scale: scale)
        var sharp: [String: AssetID] = [:]
        var found: [AssetID: ResultMomentCover] = [:]
        for card in stack.cards {
            for photo in card.candidates {
                guard let cover = ThumbnailCache.shared.cachedCover(for: photo, pixels: pixels) else { continue }
                let focus = CoverLoader.focus(imageSize: cover.image.size, screenshot: cover.screenshot, target: pixels)
                sharp[card.id] = photo
                found[photo] = ResultMomentCover(card: card.id, image: cover.image, focus: focus)
                break
            }
        }
        return stack.shown(sharp: sharp, limit: ResultCoverStack.limit).compactMap { found[$0.photo] }
    }
}
