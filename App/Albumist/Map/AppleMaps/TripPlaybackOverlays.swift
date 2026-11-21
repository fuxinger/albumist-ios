import SwiftUI
import AlbumistCore
import AlbumistMap

// What lies over the playback's map and under it: the title plate, the camera switch, the photos
// beside the dot, the cards that cover the map (waiting for it, a slideshow day, a pause), the end
// card, and the bottom bar. Names and numbers only ever on solid dark plates, never directly on
// the imagery (prototype brief).

/// The title, the camera switch and the photos over the playing map.
struct TripPlaybackChrome: View {
    let model: TripPlaybackModel

    var body: some View {
        VStack(spacing: 8) {
            if showsTitle {
                TripPlaybackTitlePlate(title: model.title, date: model.dateText)
                TripPlaybackCameraSwitch(model: model)
            }
            Spacer(minLength: 0)
            if showsStack {
                TripPlaybackPhotoStack(ids: model.stack, showsPhotos: model.showsPhotos, more: model.moreText, side: 76)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.stackPlaceIndex)
    }

    private var showsTitle: Bool { !model.showsCover && model.state != .finished }
    private var showsStack: Bool { model.stackPlaceIndex != nil && !model.showsCover && model.state != .finished }
}

/// "Tag 3 von 9 · Skógafoss" and the local date, on a solid dark plate.
struct TripPlaybackTitlePlate: View {
    let title: String
    let date: String

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: title)
                .font(.headline)
                .foregroundStyle(Color.white)
            Text(verbatim: date)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppleMapsStyle.plate))
        .accessibilityElement(children: .combine)
    }
}

/// The prototype's switch between a camera per frame and MapKit's own animated steps.
struct TripPlaybackCameraSwitch: View {
    let model: TripPlaybackModel

    var body: some View {
        Button {
            model.toggleCameraMode()
        } label: {
            Text(verbatim: "Kamera: \(model.cameraMode.label)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(AppleMapsStyle.plate))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Wechselt, wie die Kamera der Route folgt"))
    }
}

/// Three photos fanned out with white rims, and "+46" for the day's other photos.
struct TripPlaybackPhotoStack: View {
    let ids: [AssetID?]
    let showsPhotos: Bool
    let more: String?
    let side: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            fan
            if let more {
                Text(verbatim: more)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppleMapsStyle.plate))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var fan: some View {
        ZStack {
            ForEach(Array(ids.enumerated()), id: \.offset) { item in
                TripPlaybackPhotoTile(id: item.element, showsPhotos: showsPhotos, index: item.offset, side: side)
                    .rotationEffect(.degrees(spread(item.offset) * 7))
                    .offset(x: CGFloat(spread(item.offset)) * side * 0.32)
            }
        }
        .frame(width: side * 1.8, height: side * 1.25)
    }

    /// -1, 0, 1 for three photos: left, middle, right.
    private func spread(_ index: Int) -> Double {
        Double(index) - Double(ids.count - 1) / 2
    }

    private var accessibilityText: String {
        let photos = showsPhotos ? "Fotos dieses Orts" : "Platzhalter statt Fotos"
        guard let more else { return photos }
        return "\(photos), \(more) weitere"
    }
}

/// One photo of the stack: the photo from the iPhone (`AssetThumbnail`, never from iCloud), or
/// for the demo trip a quiet tile.
struct TripPlaybackPhotoTile: View {
    let id: AssetID?
    let showsPhotos: Bool
    let index: Int
    let side: CGFloat

    var body: some View {
        face
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white, lineWidth: 3) }
            .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder private var face: some View {
        if showsPhotos, let id {
            AssetThumbnail(id: id, side: side)
        } else {
            TripPlaybackPlaceholder(index: index)
        }
    }
}

/// A quiet tile in place of a photo: soft colours of sea, moss and sand.
struct TripPlaybackPlaceholder: View {
    let index: Int

    var body: some View {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var colors: [Color] {
        switch index % 3 {
        case 0: [Color(red: 0.55, green: 0.66, blue: 0.72), Color(red: 0.33, green: 0.44, blue: 0.52)]
        case 1: [Color(red: 0.60, green: 0.68, blue: 0.55), Color(red: 0.38, green: 0.47, blue: 0.36)]
        default: [Color(red: 0.80, green: 0.72, blue: 0.58), Color(red: 0.58, green: 0.50, blue: 0.40)]
        }
    }
}

/// The card over the map while a day waits for it (after `PlaybackPlayer.coverDelay`), runs as a
/// slideshow, or is paused before its map was ready.
struct TripPlaybackCoverLayer: View {
    let model: TripPlaybackModel

    var body: some View {
        if model.showsCover && model.state != .finished {
            TripPlaybackCoverCard(model: model)
                .transition(.opacity)
        }
    }
}

/// A calm full-screen card: the day, its date, and its photos (or the map loading).
struct TripPlaybackCoverCard: View {
    let model: TripPlaybackModel

    var body: some View {
        ZStack {
            TripPlaybackCoverBackground()
            VStack(spacing: 18) {
                Text(verbatim: heading)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.8))
                TripPlaybackCoverTitle(title: model.title, date: model.dateText)
                middle
                if let note {
                    Text(verbatim: note)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder private var middle: some View {
        if model.state == .waitingForTiles {
            ProgressView()
                .accessibilityLabel(Text(verbatim: "Karte lädt"))
                .tint(Color.white)
                .controlSize(.large)
        } else {
            TripPlaybackPhotoStack(ids: model.stackIDs(for: model.titlePlaceIndex), showsPhotos: model.showsPhotos,
                                   more: model.moreText, side: 104)
        }
    }

    private var heading: String {
        switch model.state {
        case .waitingForTiles: return "Karte lädt"
        case .slideshowDay: return "Bilderfolge"
        case .paused, .playing, .finished: return "Pausiert"
        }
    }

    /// Why the day runs as a slideshow (the prototype shows it, so the owner sees what happened).
    private var note: String? {
        guard model.state == .slideshowDay || model.state == .paused, let reason = model.slideshowReason else { return nil }
        switch reason {
        case .timedOut: return "Die Karte war nicht rechtzeitig fertig."
        case .failed: return "Die Karte ließ sich nicht laden."
        case .saving: return "Wärme oder Stromsparmodus: ohne 3D-Karte."
        }
    }
}

/// The day's title and date on the cover card.
struct TripPlaybackCoverTitle: View {
    let title: String
    let date: String

    var body: some View {
        VStack(spacing: 4) {
            Text(verbatim: title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.white)
            Text(verbatim: date)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.85))
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

/// The cover card's background: a deep night blue, darker at the bottom.
struct TripPlaybackCoverBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.11, blue: 0.16), Color(red: 0.03, green: 0.04, blue: 0.06)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top)
    }
}

/// After the last day: "Willkommen zurück" with the trip's days, photos and kilometres, and
/// "Nochmal".
struct TripPlaybackEndLayer: View {
    let model: TripPlaybackModel

    var body: some View {
        if model.state == .finished {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea(edges: .top)
                TripPlaybackEndCard(summary: model.summary) {
                    model.togglePlay()
                }
            }
            .transition(.opacity)
        }
    }
}

struct TripPlaybackEndCard: View {
    let summary: String
    let again: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(verbatim: "Willkommen zurück")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.white)
            Text(verbatim: summary)
                .font(.body)
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.center)
            Button(action: again) {
                Text(verbatim: "Nochmal")
                    .font(.headline)
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 28)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(AppleMapsStyle.plate))
        .padding(.horizontal, 24)
    }
}

/// "Pause" / "Weiter" and the bar with a tick per day, on a strong dark background under the map.
struct TripPlaybackBottomBar: View {
    let model: TripPlaybackModel

    var body: some View {
        HStack(spacing: 12) {
            TripPlaybackPlayButton(model: model)
            TripPlaybackProgressBar(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea(edges: .bottom))
    }
}

struct TripPlaybackPlayButton: View {
    let model: TripPlaybackModel

    var body: some View {
        Button {
            model.togglePlay()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(verbatim: word)
            }
            .font(.headline)
            .foregroundStyle(Color.white)
            .frame(minWidth: 92, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        if model.isRunning { return "pause.fill" }
        return model.state == .finished ? "arrow.counterclockwise" : "play.fill"
    }

    private var word: String {
        if model.isRunning { return "Pause" }
        return model.state == .finished ? "Nochmal" : "Weiter"
    }
}

/// The bar: the whole height (44 pt) takes taps and drags; the day under the finger shows in the
/// title while dragging, and letting go jumps there.
struct TripPlaybackProgressBar: View {
    let model: TripPlaybackModel

    var body: some View {
        GeometryReader { proxy in
            TripPlaybackTrack(progress: model.progress, ticks: model.dayFractions, width: proxy.size.width)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(drag(width: proxy.size.width))
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Tag wählen"))
        .accessibilityValue(Text(verbatim: model.title))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.jump(to: model.dayIndex + 1)
            case .decrement: model.jump(to: model.dayIndex - 1)
            @unknown default: break
            }
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in model.preview(atFraction: Self.fraction(value.location.x, of: width)) }
            .onEnded { value in model.jump(atFraction: Self.fraction(value.location.x, of: width)) }
    }

    private static func fraction(_ x: CGFloat, of width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }
}

/// The bar's picture: the track, how far the playback is, and a tick where each day starts.
struct TripPlaybackTrack: View {
    let progress: Double
    let ticks: [Double]
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(height: 6)
            Capsule()
                .fill(Color.white)
                .frame(width: filled, height: 6)
            ForEach(Array(ticks.enumerated()), id: \.offset) { item in
                Rectangle()
                    .fill(Color.white.opacity(0.8))
                    .frame(width: 2, height: 14)
                    .offset(x: width * CGFloat(item.element) - 1)
            }
        }
    }

    private var filled: CGFloat {
        max(6, width * CGFloat(min(max(progress, 0), 1)))
    }
}
