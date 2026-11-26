import SwiftUI
import AlbumistCore
import AlbumistMap

// The playback's bottom bar under the map: "Pause" / "Weiter" and the progress bar with a tick
// per day, which jumps to a day on a tap or a drag (the layers over the map are in
// TripPlaybackOverlays.swift).

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
