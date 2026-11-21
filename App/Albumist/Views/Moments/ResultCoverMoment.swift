import SwiftUI
import UIKit
import AlbumistCore

/// The top of the result after a run (draft E3, the big moment): the covers of the new albums
/// fanned above the count, lying down one after another, the main cover last and on top; without
/// a stack the symbol as before (undo, removal, failed steps, or no cover sharp on the device).
///
/// - Which albums and photos: `ResultCoverStack` (core). The covers load through `CoverLoader`
///   at the card's full size, only from the device (never iCloud, never blurry): an album without
///   a sharp cover is left out, and with none at all the symbol shows. The preview loads them
///   ahead while the plan runs (`ResultMomentLoader.prefetch`), so they are there with the result.
/// - The screen's success tap comes as the main cover lies down (`onSettled`; `ExecutionHaptics`
///   waits for it): no haptic of its own.
/// - Reduce Motion: the covers only fade in where they lie; so in the UI tests, whose picture of
///   the result is taken a second after it shows.
/// - Decorative for VoiceOver: the count below ("10 neue Alben") is the heading that is read.
/// - Room: at most five covers, three at the accessibility text sizes; the fan shrinks to the
///   width and to the room `room` leaves (the count and "Fotos-App öffnen" stay on screen), down
///   to `ResultCoverFan.minimumScale`. Its height is held while the covers load.
/// - Once per result: coming back to the tab shows the covers where they lie.
struct ResultCoverMoment: View {
    let plan: ChangePlan
    let stack: ResultCoverStack
    /// The symbol without a stack, and its colour.
    let symbol: String
    let tint: Color
    /// The height the screen has left for the stack; nil until measured.
    let room: CGFloat?
    /// The moment is there: the main cover lay down, or the symbol shows.
    let onSettled: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    /// The covers of `loadedFor`, in the order of the stack.
    @State private var covers: [ResultMomentCover] = []
    @State private var loadedFor: AlbumistID?
    /// How many covers lie down, in laying order.
    @State private var laid = 0
    @State private var settledFor: AlbumistID?
    @State private var width: CGFloat = 360
    @State private var appeared = false

    /// The covers only fade in where they lie: Reduce Motion, and the UI tests.
    private var calm: Bool {
        reduceMotion || UITestSupport.isRunning
    }

    private var limit: Int {
        typeSize.isAccessibilitySize ? ResultCoverStack.limitAtLargestText : ResultCoverStack.limit
    }

    /// The covers on the stack now (three of five at the accessibility sizes).
    private var shown: [ResultMomentCover] {
        guard loadedFor == plan.id else { return [] }
        return Array(covers.prefix(ResultCoverFan.count(min(covers.count, limit))))
    }

    /// While the covers load: as many as the stack may show.
    private var expected: Int {
        ResultCoverFan.count(min(stack.cards.count, limit))
    }

    private var showsSymbol: Bool {
        stack.isEmpty || (loadedFor == plan.id && covers.isEmpty)
    }

    var body: some View {
        Group {
            if showsSymbol {
                symbolView
            } else {
                fanArea
            }
        }
        .task(id: plan.id) { await play() }
        .onAppear { appeared = true }
        // Left before the main cover lay down: the moment is over, and coming back shows the
        // covers where they lie.
        .onDisappear { settle(laidDown: true) }
    }

    // MARK: Parts

    private var symbolView: some View {
        Image(systemName: symbol)
            .font(.system(size: 56))
            .foregroundStyle(tint)
            .symbolEffect(.bounce, value: appeared)
            .accessibilityHidden(true)
    }

    /// The fan across the width, as high as it is drawn (held while the covers load).
    private var fanArea: some View {
        let scale = fanScale
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: heldHeight * scale)
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

    /// The tallest fan the stack may become while it loads, so nothing below it moves.
    private var heldHeight: CGFloat {
        let most = loadedFor == plan.id ? max(1, shown.count) : max(1, expected)
        let tallest = (1...most).map { ResultCoverFan.size($0).height }.max() ?? ResultCoverFan.cardHeight
        return CGFloat(tallest)
    }

    private var fanScale: CGFloat {
        let count = loadedFor == plan.id ? max(1, shown.count) : max(1, expected)
        let height = room.map { Double($0) } ?? .infinity
        return CGFloat(ResultCoverFan.scale(count: count, width: Double(width), height: height))
    }

    // MARK: Choreography

    private func play() async {
        guard !stack.isEmpty else {
            settle(laidDown: true)
            return
        }
        if loadedFor != plan.id {
            if settledFor != plan.id { laid = 0 }
            let loaded = await ResultMomentLoader.load(stack, scale: displayScale)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) {
                covers = loaded
                loadedFor = plan.id
            }
        }
        // Back on the tab: the covers lie where they lay.
        guard settledFor != plan.id else { return }
        let count = shown.count
        guard count > 0 else {
            settle(laidDown: true)
            return
        }
        if calm {
            withAnimation(.easeOut(duration: 0.35)) { laid = count }
            try? await Task.sleep(for: .milliseconds(350))
        } else {
            for step in 1...count {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { laid = step }
                try? await Task.sleep(for: .milliseconds(step == count ? 300 : 110))
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

/// Loads the covers of the result's stack through `CoverLoader` (the cards' own loader: only
/// from the device, the first candidate that is sharp, kept in the covers' store), at the card's
/// full size whatever the fan is scaled to, so what was loaded ahead is what is shown.
@MainActor
enum ResultMomentLoader {
    /// How long the result waits for covers at most: what has not come by then stays off the stack.
    static let patience: Duration = .milliseconds(1500)
    /// How long the covers may load while the plan runs and the show plays.
    static let prefetchPatience: Duration = .seconds(20)
    /// Photos did not answer (busy with the run): the cover asks once more after this.
    static let retryDelay: Duration = .milliseconds(800)

    /// The size in pixels each cover is asked for.
    static func pixels(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(ResultCoverFan.cardWidth) * scale, height: CGFloat(ResultCoverFan.cardHeight) * scale)
    }

    /// The covers that lie on the stack (`ResultCoverStack.shown`), card by card in order; each
    /// card tries its own photos, an album with none sharp on the device is left out.
    static func load(_ stack: ResultCoverStack, scale: CGFloat,
                     patience: Duration = ResultMomentLoader.patience) async -> [ResultMomentCover] {
        let pixels = pixels(scale: scale)
        let started = ContinuousClock.now
        var sharp: [String: AssetID] = [:]
        var found: [AssetID: ResultMomentCover] = [:]
        for card in stack.cards {
            guard sharp.count < ResultCoverStack.limit, !Task.isCancelled,
                  ContinuousClock.now - started < patience else { break }
            let request = CoverLoader.Request(ids: card.candidates, pixels: pixels)
            var loaded = await CoverLoader.load(request)
            // Photos did not answer: asked once more while there is time.
            if loaded.counted == nil, !Task.isCancelled, ContinuousClock.now - started + retryDelay < patience {
                try? await Task.sleep(for: retryDelay)
                loaded = await CoverLoader.load(request)
            }
            guard case .photo(let image, let focus) = loaded.shown else { continue }
            // The photo it showed: the first candidate whose sharp cover is now kept.
            let photo = card.candidates.first { ThumbnailCache.shared.cachedCover(for: $0, pixels: pixels) != nil }
                ?? card.candidates[0]
            sharp[card.id] = photo
            found[photo] = ResultMomentCover(card: card.id, image: image, focus: focus)
        }
        return stack.shown(sharp: sharp, limit: ResultCoverStack.limit).compactMap { found[$0.photo] }
    }

    /// Loads the covers while the plan runs, so they are at hand when the result comes (sharp ones
    /// are kept in the covers' store; nothing is shown).
    static func prefetch(_ stack: ResultCoverStack, scale: CGFloat) async {
        guard !stack.isEmpty else { return }
        _ = await load(stack, scale: scale, patience: prefetchPatience)
    }
}
