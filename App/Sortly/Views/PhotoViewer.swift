import SwiftUI
import UIKit
import SortlyCore

/// The photos of a suggestion in full screen: swipe from one to the next, pinch or double-tap
/// to zoom. First device test 15.11.: "Hier müsste man die Bilder öffnen bzw. groß machen
/// können." The images come straight from Photos (only what is on the device, nothing is
/// downloaded or stored).
struct PhotoViewer: View {
    struct Start: Identifiable {
        var id: AssetID
    }

    var ids: [AssetID]
    @State var current: AssetID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let index = ids.firstIndex(of: current) ?? 0
        TabView(selection: $current) {
            ForEach(ids, id: \.self) { id in
                ZoomablePhoto(id: id)
                    .tag(id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .overlay(alignment: .top) {
            HStack {
                Text("\(index + 1) von \(ids.count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel(Text("Schließen"))
                .accessibilityIdentifier("viewer.close")
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
        }
        .statusBarHidden()
        .accessibilityAction(.escape) { dismiss() }
    }
}

/// One photo that fits the screen; pinch or double-tap to zoom, drag to look around.
private struct ZoomablePhoto: View {
    var id: AssetID
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityLabel(Text("Foto"))
                        .accessibilityHint(Text("Zweimal tippen zum Vergrößern"))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 5) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 { withAnimation(.snappy) { reset() } }
                    }
            )
            // Moving the zoomed photo wins over swiping to the next one; at normal size the
            // swipe goes to the next photo.
            .highPriorityGesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset },
                including: scale > 1 ? .all : .subviews
            )
            .task(id: id) {
                let pixels = CGSize(width: geo.size.width * displayScale * 2, height: geo.size.height * displayScale * 2)
                image = await ThumbnailCache.shared.largeImage(for: id, pixels: pixels)
            }
        }
        .onDisappear { reset() }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
