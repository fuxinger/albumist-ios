import SwiftUI
import UIKit
import AlbumistCore

/// Photos in full screen, like the Photos app: swipe from one to the next, pinch or double-tap
/// to zoom, swipe down to close. First device test 15.11.: "Hier müsste man die Bilder öffnen
/// bzw. groß machen können." The images come straight from Photos (only what is on the device,
/// nothing is downloaded or stored).
///
/// Design review 15.11. (W11, W12): the controls are the system's toolbar (Liquid Glass, not
/// home-made black circles); a tap on a photo opens this viewer everywhere, and its details
/// are behind the "i" button, as in Photos.
struct PhotoViewer: View {
    struct Start: Identifiable {
        var id: AssetID
        /// The photos to swipe through, fixed when the viewer opens (a photo ignored from its
        /// details must not reshuffle the pages under the user's finger).
        var ids: [AssetID] = []
    }

    var ids: [AssetID]
    @State var current: AssetID
    /// Shows the "i" button with the photo's details, album and ignore actions.
    var showsInfo: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var info: AssetFacts?
    @State private var addingToAlbum: [AssetID]?
    /// How far the photo was pulled down to close.
    @State private var pull: CGFloat = 0
    /// The pages built: a window around the photo shown, moved on while swiping (review
    /// P4-11: the library hands over 3,000 photos and more, and every one was a page).
    @State private var window: PageWindow

    init(ids: [AssetID], current: AssetID, showsInfo: Bool = false) {
        self.ids = ids
        _current = State(initialValue: current)
        self.showsInfo = showsInfo
        _window = State(initialValue: PageWindow(around: ids.firstIndex(of: current) ?? 0, count: ids.count))
    }

    var body: some View {
        let index = ids.firstIndex(of: current) ?? 0
        NavigationRoot {
            TabView(selection: $current) {
                ForEach(ids[window.range.clamped(to: ids.indices)], id: \.self) { id in
                    ZoomablePhoto(id: id, label: label(for: id), pull: $pull) { dismiss() }
                        .tag(id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: current) {
                window = window.following(ids.firstIndex(of: current) ?? 0, count: ids.count)
            }
            .background(Color.black.opacity(1 - min(pull / 500, 0.7)).ignoresSafeArea())
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(Text("\(index + 1) von \(ids.count)"))
            .navigationBarTitleDisplayMode(.inline)
            // Light controls and title on the black photo background.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // The title as its own element with a fixed name, so the UI tests read which
                // photo shows without searching visible text ("11 von 3.000", 26.11.).
                ToolbarItem(placement: .principal) {
                    Text("\(index + 1) von \(ids.count)")
                        .font(.headline)
                        .monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("viewer.position")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
                        .accessibilityIdentifier("viewer.close")
                }
                if showsInfo, let facts = model.factsByID[current] {
                    ToolbarItem(placement: .primaryAction) {
                        Button { info = facts } label: { Label("Info", systemImage: "info.circle") }
                            .accessibilityIdentifier("viewer.info")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                // "Widerrufen" after ignoring the photo from its details (design review D4).
                IgnoreUndoBar()
            }
            .animation(.snappy, value: model.lastIgnored)
        }
        // Dark inside the viewer only; the sheets below keep the app's own appearance.
        .environment(\.colorScheme, .dark)
        .accessibilityAction(.escape) { dismiss() }
        .sheet(item: $info) { facts in
            AssetDetailView(facts: facts) { addingToAlbum = [facts.id] }
                .presentationDetents([.medium, .large])
                // A half-height sheet is see-through glass in iOS 26: over the black viewer
                // the light text lost its contrast ("Taken", UI run 43773339053). Solid.
                .presentationBackground(Theme.background)
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {}
                .presentationBackground(Theme.background)
        }
    }

    /// What VoiceOver says for a photo: when and where it was taken, not just "Foto".
    private func label(for id: AssetID) -> Text {
        let facts = model.factsByID[id]
        var parts: [String] = []
        if let date = facts?.asset.creationDate { parts.append(date.formatted(date: .long, time: .shortened)) }
        if let place = facts?.place {
            let names = [place.locality, place.country].compactMap { $0 }
            if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        }
        return parts.isEmpty ? Text("Foto") : Text(verbatim: parts.joined(separator: ", "))
    }
}

/// One photo that fits the screen; pinch or double-tap to zoom, drag to look around, pull
/// down to close.
private struct ZoomablePhoto: View {
    var id: AssetID
    var label: Text
    @Binding var pull: CGFloat
    var onClose: () -> Void
    @State private var image: UIImage?
    /// Nothing came from Photos (only in iCloud, or gone): said instead of an endless spinner.
    @State private var unavailable = false
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
                        .scaleEffect(scale * (1 - min(pull / 2000, 0.15)))
                        .offset(x: offset.width, y: offset.height + pull)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityLabel(label)
                        .accessibilityAddTraits(.isImage)
                        // VoiceOver's own zoom gesture instead of "Zweimal tippen zum Vergrößern",
                        // which clashed with VoiceOver's double tap (design review W11).
                        .accessibilityZoomAction { action in
                            withAnimation(.snappy) {
                                switch action.direction {
                                case .zoomIn: scale = min(scale * 2, 5)
                                case .zoomOut: scale = max(scale / 2, 1)
                                }
                                lastScale = scale
                                if scale <= 1 { reset() }
                            }
                        }
                } else if unavailable {
                    ContentUnavailableView {
                        Label("Dieses Foto ist gerade nicht verfügbar.", systemImage: "icloud.slash")
                    } description: {
                        Text("Vielleicht liegt es nur in iCloud. In der Fotos-App lädt iOS es herunter.")
                    }
                    .accessibilityIdentifier("viewer.unavailable")
                } else {
                    ProgressView().tint(.white)
                        .accessibilityLabel(Text("Foto wird geladen"))
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
            // At normal size a mostly vertical pull down closes the viewer, as in Photos;
            // sideways still goes to the next photo.
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        let t = value.translation
                        guard t.height > 0, abs(t.height) > abs(t.width) else { return }
                        pull = t.height
                    }
                    .onEnded { value in
                        let t = value.translation
                        if t.height > 120, abs(t.height) > abs(t.width) {
                            onClose()
                        } else {
                            withAnimation(.snappy) { pull = 0 }
                        }
                    },
                including: scale > 1 ? .subviews : .all
            )
            .task(id: id) {
                unavailable = false
                let pixels = CGSize(width: geo.size.width * displayScale * 2, height: geo.size.height * displayScale * 2)
                let loaded = await ThumbnailCache.shared.largeImage(for: id, pixels: pixels)
                // After a swipe to the next photo this task is cancelled; its late image must
                // not replace the new photo's.
                guard !Task.isCancelled else { return }
                image = loaded
                if loaded == nil { unavailable = true }
            }
            .task(id: id) {
                // Photos may never answer for a photo that is only in iCloud.
                try? await Task.sleep(for: .seconds(15))
                if image == nil && !Task.isCancelled { unavailable = true }
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
