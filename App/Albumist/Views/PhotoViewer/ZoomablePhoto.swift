import SwiftUI
import UIKit
import AlbumistCore

/// One photo that fits the screen; pinch or double-tap to zoom, drag to look around, pull
/// down to close, tap to hide or show the bars, press and hold to play a Live Photo
/// (`LivePress`). A video plays over its still (`VideoSurface`), zoomed and pulled with it, also
/// before the still came and when none came sharp: the video is its own sharp picture.
///
/// While the photo comes, the thumbnail the grid showed stands in for it, from memory, as in
/// Photos; without one the page is black. No spinner (DS-18). The large picture shows only when
/// it is sharp at the screen's size (`ViewerPicture`); a photo of which only Photos' small
/// preview is on the iPhone (the photo itself in iCloud) gets the calm note instead of a big
/// blurry picture (design rule 6), a video only once the video is known not to play
/// (`ViewerPage`, review V1), a page of no known kind not before it was on screen (review X6).
struct ZoomablePhoto: View {
    var id: AssetID
    /// What VoiceOver says: place, day and time ("München, 12. Oktober 2024, 14:32").
    var label: String
    /// Where it is among the photos ("3 von 176").
    var position: Text
    /// The photo on screen (the pages beside it are built too): only it loads its Live Photo.
    var isCurrent: Bool
    /// What it is (`PageKind`): for a video also where its video is
    /// (`ViewerVideo.availability(for:)`), so the page waits while it may still play instead of
    /// saying it is not available (review V1); a page of no known kind waits too (review X6).
    var kind: PageKind
    /// The video's player while this video is on screen (`ViewerVideo`).
    var player: ViewerVideo.Player?
    /// The top of the photo's area (under the bar).
    var top: CGFloat
    @Binding var pull: CGFloat
    var onTap: () -> Void
    var onClose: () -> Void
    /// Its Live Photo's motion is on the iPhone and can play.
    var onLive: (AssetID) -> Void
    /// It was zoomed in (the bars go).
    var onZoom: () -> Void
    /// A long press on its Live Photo began (true) or ended (false): the pager holds still.
    var onPressing: (Bool) -> Void
    /// A sharp picture came (true), or none will and the page says so (false): the photo view
    /// then says nothing more of it.
    var onPicture: (AssetID, Bool) -> Void
    /// VoiceOver's two-finger double tap on a video's page: it plays or pauses.
    var onPlayPause: () -> Void
    @State var image: UIImage?
    /// No sharp picture came from Photos (only in iCloud, or gone): said instead of an endless
    /// wait or a big blurry picture.
    @State var unavailable = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State var live: LivePhotoLoader.Live?
    @State var command = LiveCommand()
    /// A long press plays the Live Photo (`LivePress`); when the last one ended.
    @State private var pressing = false
    @State private var pressEnded: ContinuousClock.Instant?
    @Environment(\.displayScale) var displayScale
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
                .task(id: id) { await load(in: area(of: geo.size)) }
                .task(id: id) { await giveUp() }
                .task(id: LiveRequest(id: id, isCurrent: isCurrent, shown: image != nil)) { await loadLive(in: area(of: geo.size)) }
        }
        .onDisappear {
            // Its press ends with it: the pager is never held for good.
            if pressing { press(false) }
            reset()
        }
        .onChange(of: scale > 1) { _, zoomed in
            if zoomed { onZoom() }
        }
    }

    /// When the Live Photo is wanted: for the photo on screen, once its still is shown.
    private struct LiveRequest: Equatable {
        var id: AssetID
        var isCurrent: Bool
        var shown: Bool
    }

    /// The photo's area: the screen under the bar.
    private func area(of size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(size.height - top, 1))
    }

    private func content(in size: CGSize) -> some View {
        shown(in: area(of: size))
            .padding(.top, top)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            // The long press first, innermost (review D2, N3): the gestures added after it give
            // way to it, so a resting finger begins it and a short touch fails it at once and is
            // a tap; added after the taps it would wait for a tap that never fails.
            .gesture(LivePress(isEnabled: live != nil) { began in press(began) })
            .gesture(taps)
            .gesture(magnify)
            // Moving the zoomed photo wins over swiping to the next one; at normal size the
            // swipe goes to the next photo.
            .highPriorityGesture(pan, including: scale > 1 ? .all : .subviews)
            // At normal size a mostly vertical pull down closes the viewer, as in Photos;
            // sideways still goes to the next photo.
            .simultaneousGesture(pullDown, including: scale > 1 ? .subviews : .all)
    }

    /// What the page shows (`ViewerPage`): the picture once its still is sharp, or its video plays
    /// over it, also while the still comes and when none came sharp (a small poster frame, review
    /// F, F6); the note once nothing will come, for a video only once the video is known not to
    /// play (review V1); until then it waits.
    @ViewBuilder
    private func shown(in size: CGSize) -> some View {
        switch page {
        case .picture: photo(image, in: size)
        case .unavailable: unavailableNote(in: size)
        case .waiting: waiting(in: size)
        }
    }

    /// The core's rule, told what the page is (for a video, `.unknown` while it is not on screen).
    private var page: ViewerPage {
        ViewerPage.shows(still: picture, playing: player != nil, kind: kind)
    }

    /// A video: its words while it loads and when it is not available; VoiceOver's magic tap
    /// plays and pauses it. A page of no known kind speaks as a photo while it waits.
    private var isVideo: Bool {
        kind.isVideo
    }

    /// What Photos' answer for the still was: sharp, none will come, or nil while it has not answered.
    private var picture: ViewerPicture? {
        if image != nil { return .sharp }
        return unavailable ? .unavailable : nil
    }

    /// Nothing sharp came, and for a video the video does not play: said calmly instead of an
    /// endless wait or a big blurry picture.
    private func unavailableNote(in size: CGSize) -> some View {
        ContentUnavailableView {
            if isVideo {
                Label("Dieses Video ist gerade nicht verfügbar.", systemImage: "icloud.slash")
            } else {
                Label("Dieses Foto ist gerade nicht verfügbar.", systemImage: "icloud.slash")
            }
        } description: {
            Text("Vielleicht liegt es nur in iCloud. In der Fotos-App lädt iOS es herunter.")
        }
        .frame(width: size.width, height: size.height)
        .accessibilityIdentifier("viewer.unavailable")
    }

    /// While the picture comes: the thumbnail the grid showed, from memory, fitted as the picture
    /// will be, as Photos does; else the black page. No spinner (DS-18); VoiceOver hears that it
    /// loads. A moment at most: the sharp picture replaces it, or the note when none comes.
    private func waiting(in size: CGSize) -> some View {
        Color.clear
            .overlay {
                if let preview = ThumbnailCache.shared.thumbnailInMemory(for: id) {
                    // Pulled down to close or pinched, it follows the finger as the photo will.
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale * (1 - min(pull / 2000, 0.15)))
                        .offset(x: offset.width, y: offset.height + pull)
                }
            }
            .frame(width: size.width, height: size.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isVideo ? Text("Video wird geladen") : Text("Foto wird geladen"))
    }

    /// The still, and over it the Live Photo's motion while it plays or the video's picture;
    /// zoomed and moved together. One element for VoiceOver, with the title's words, the position
    /// and the zoom.
    private func photo(_ image: UIImage?, in size: CGSize) -> some View {
        ZStack {
            still(image)
            if let live {
                LivePhotoPlayer(livePhoto: live.value, command: command)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let player {
                VideoSurface(player: player)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .scaleEffect(scale * (1 - min(pull / 2000, 0.15)))
        .offset(x: offset.width, y: offset.height + pull)
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(position)
        .accessibilityAddTraits(.isImage)
        // The photo on screen carries its position ("3 von 176") as its value under a fixed name:
        // the UI tests read which photo shows from it (viewer count and swipes, 26.11.2026).
        .accessibilityIdentifier(isCurrent ? "viewer.position" : "viewer.photo")
        // VoiceOver's own zoom gesture instead of "Zweimal tippen zum Vergrößern",
        // which clashed with VoiceOver's double tap (design review W11).
        .accessibilityZoomAction { action in zoom(action) }
        .accessibilityActions { liveActions }
        .modifier(PlayPauseOnMagicTap(isVideo: isVideo, action: onPlayPause))
    }

    /// The sharp still; under a video that plays without one, the grid's thumbnail from memory
    /// as while it waits, else the black page. The video's first frame covers it.
    @ViewBuilder
    private func still(_ image: UIImage?) -> some View {
        if let still = image ?? ThumbnailCache.shared.thumbnailInMemory(for: id) {
            Image(uiImage: still)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    /// A Live Photo plays from VoiceOver's actions too (swipe up or down), as the long press.
    @ViewBuilder
    private var liveActions: some View {
        if live != nil {
            Button("Live Photo abspielen") { play(.full) }
        }
    }
}

extension ZoomablePhoto {
    // MARK: Gestures

    /// A tap hides or shows the bars, a double tap zooms (the single tap waits for the second
    /// one). The touch that was a long press on a Live Photo (`LivePress`) is no tap.
    private var taps: some Gesture {
        TapGesture(count: 2)
            .onEnded { if !pressedLately { toggleZoom() } }
            .exclusively(before: TapGesture().onEnded { if !pressedLately { onTap() } })
    }

    /// The long press on a Live Photo began or is over: it plays whole while the press lasts,
    /// as in Photos, and the page holds still (the photo view stops paging, `magnify` and `pan`
    /// rest; review D2, N4). Only a press that began ends one (a touch too short for a press is
    /// a tap).
    private func press(_ began: Bool) {
        if began {
            pressing = true
            onPressing(true)
            play(.full)
        } else if pressing {
            pressing = false
            pressEnded = .now
            onPressing(false)
            play(.stop)
        }
    }

    /// A long press is on, or ended a moment ago: the tap or pull that ends with it was the
    /// press (a single tap is known only after the wait for a second one, about a third of a
    /// second).
    private var pressedLately: Bool {
        if pressing { return true }
        guard let pressEnded else { return false }
        return ContinuousClock.now - pressEnded < .milliseconds(600)
    }

    /// Pinch to zoom; not while a long press plays the Live Photo (a second finger then is no
    /// pinch, review D2, N4).
    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !pressing else { return }
                scale = min(max(lastScale * value.magnification, 1), 5)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { withAnimation(.snappy) { reset() } }
            }
    }

    /// Moving the zoomed photo; not while a long press plays its Live Photo (N4).
    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !pressing else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    /// A finger that drifts while a long press plays the Live Photo pulls nothing.
    private var pullDown: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let t = value.translation
                guard !pressedLately, t.height > 0, abs(t.height) > abs(t.width) else { return }
                pull = t.height
            }
            .onEnded { value in
                let t = value.translation
                if !pressedLately, t.height > 120, abs(t.height) > abs(t.width) {
                    onClose()
                } else {
                    withAnimation(.snappy) { pull = 0 }
                }
            }
    }

    // MARK: Zoom

    private func toggleZoom() {
        withAnimation(.snappy) {
            if scale > 1 {
                reset()
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func zoom(_ action: AccessibilityZoomGestureAction) {
        withAnimation(.snappy) {
            switch action.direction {
            case .zoomIn: scale = min(scale * 2, 5)
            case .zoomOut: scale = max(scale / 2, 1)
            }
            lastScale = scale
            if scale <= 1 { reset() }
        }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}

/// VoiceOver's two-finger double tap plays and pauses a video (DS-16), on its page as on its
/// controls (`VideoControls`). On a photo it stays the system's, which plays or pauses the
/// user's music: the page does not take it.
private struct PlayPauseOnMagicTap: ViewModifier {
    var isVideo: Bool
    var action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isVideo {
            content.accessibilityAction(.magicTap, action)
        } else {
            content
        }
    }
}
