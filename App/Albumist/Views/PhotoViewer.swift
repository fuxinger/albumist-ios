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
///
/// Design wave 2 (DS-10), as in Photos: the title is the photo's place, day and time
/// (`PhotoTitle`, before "1 von 176", which VoiceOver still says with the photo); "Teilen"
/// shares the photo from the iPhone (`PhotoShare`); a tap hides the bars, the status bar and
/// the home indicator and the next brings them back, but never while VoiceOver or Switch
/// Control runs (`ViewerChrome`); Live Photos move (`LivePhotoPlayer`).
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @State private var info: AssetFacts?
    @State private var addingToAlbum: [AssetID]?
    /// How far the photo was pulled down to close.
    @State private var pull: CGFloat = 0
    /// The pages built: a window around the photo shown, moved on while swiping (review
    /// P4-11: the library hands over 3,000 photos and more, and every one was a page).
    @State private var window: PageWindow
    /// The bars, the status bar and the home indicator: a tap on the photo hides and shows them.
    @State private var chrome = ViewerChrome()
    /// The top of the photos' area: under the bar while the bars show, kept while they are
    /// hidden, so the photo never moves (on an iPhone with a Home button the status bar's height
    /// goes with it) and the bar's title never stands on the photo (design rule 1).
    @State private var top: CGFloat = 0
    /// Whether each photo looked at can be shared (asked once per photo).
    @State private var sharing: [AssetID: ShareAvailability] = [:]
    @State private var preparingShare = false
    /// Making the file for the share sheet; stopped when the viewer closes meanwhile.
    @State private var shareTask: Task<Void, Never>?
    /// The photos whose Live Photo motion is on the iPhone: their title shows the symbol.
    @State private var livePhotos: Set<AssetID> = []

    init(ids: [AssetID], current: AssetID, showsInfo: Bool = false) {
        self.ids = ids
        _current = State(initialValue: current)
        self.showsInfo = showsInfo
        _window = State(initialValue: PageWindow(around: ids.firstIndex(of: current) ?? 0, count: ids.count))
    }

    var body: some View {
        NavigationRoot { pager }
            // Dark inside the viewer only; the sheets below keep the app's own appearance.
            .environment(\.colorScheme, .dark)
            .accessibilityAction(.escape) { dismiss() }
            .sheet(item: $info) { facts in details(facts) }
            .sheet(isPresented: addingBinding) { addSheet }
            // A share the app could not clean up after (it was ended while the sheet was open).
            .onAppear { PhotoShare.removeLeftovers() }
            .onDisappear {
                shareTask?.cancel()
                PhotoShare.removeLeftovers()
            }
    }

    // MARK: Pages

    /// The pages with what is around them: black behind, the bars, the notes at the bottom.
    private var pager: some View {
        pages
            .background(background)
            .navigationBarTitleDisplayMode(.inline)
            // Light controls and title on the black photo background.
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { bars }
            .statusBarHidden(!chrome.isShown)
            .persistentSystemOverlays(chrome.isShown ? .automatic : .hidden)
            .overlay(alignment: .bottom) { notes }
            .animation(.snappy, value: model.lastIgnored)
            .onChange(of: assistive, initial: true) { _, running in chrome.assistiveTechnology(running: running) }
            .task(id: current) { await checkSharing() }
    }

    private var pages: some View {
        TabView(selection: $current) {
            ForEach(window.range.clamped(to: ids.indices), id: \.self) { index in
                page(at: index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: current) {
            window = window.following(ids.firstIndex(of: current) ?? 0, count: ids.count)
        }
        // The photos lie on the whole screen, under a bar of fixed height (`top`).
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { measured in
            if chrome.isShown { top = measured }
        }
    }

    private func page(at index: Int) -> some View {
        let id = ids[index]
        let photo = ZoomablePhoto(id: id, label: label(of: id), position: position(of: index), isCurrent: id == current,
                                  top: top, pull: $pull, onTap: { toggleChrome() }, onClose: { dismiss() },
                                  onLive: { _ = livePhotos.insert($0) })
        return photo.ignoresSafeArea().tag(id)
    }

    /// Black, lighter while the photo is pulled down to close.
    private var background: some View {
        Color.black.opacity(1 - min(pull / 500, 0.7)).ignoresSafeArea()
    }

    /// What VoiceOver says for a photo: where and when it was taken, as its title says it.
    private func label(of id: AssetID) -> String {
        model.photoTitle(for: id).spoken(live: livePhotos.contains(id))
    }

    /// "3 von 176": where the photo is among those swiped through (before, the bar's title).
    private func position(of index: Int) -> Text {
        Text("\((index + 1).formatted()) von \(ids.count.formatted())")
    }

    // MARK: Bars

    /// Close on the left, the photo's title in the middle, share and info on the right; all go
    /// with a tap on the photo.
    @ToolbarContentBuilder
    private var bars: some ToolbarContent {
        if chrome.isShown {
            ToolbarItem(placement: .cancellationAction) { closeButton }
            ToolbarItem(placement: .principal) { titleBar }
                // A title, as the system's: no glass of its own.
                .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) {
                shareButton
                infoButton
            }
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
            .accessibilityIdentifier("viewer.close")
    }

    private var titleBar: some View {
        PhotoTitleBar(title: model.photoTitle(for: current), live: livePhotos.contains(current))
    }

    /// Shares the photo from the iPhone (`PhotoShare`); off, with the reason, where only a
    /// preview of it is here. Not for videos: they come with wave 3 (DS-16).
    @ViewBuilder
    private var shareButton: some View {
        if !isVideo {
            Button { share() } label: { Label("Teilen", systemImage: "square.and.arrow.up") }
                .disabled(!shareState.canShare || preparingShare)
                .accessibilityHint(shareHint)
                .accessibilityIdentifier("viewer.share")
        }
    }

    private var shareHint: Text {
        switch shareState {
        case .onlyInICloud: Text("Das ganze Foto liegt nur in iCloud. Teilen kannst du es in der Fotos-App.")
        case .unavailable: Text("Dieses Foto ist gerade nicht verfügbar.")
        case .unknown, .onDevice: Text(verbatim: "")
        }
    }

    @ViewBuilder
    private var infoButton: some View {
        if showsInfo, let facts = model.factsByID[current] {
            Button { info = facts } label: { Label("Info", systemImage: "info.circle") }
                .accessibilityIdentifier("viewer.info")
        }
    }

    /// Under the photo, on a solid ground: why it cannot be shared, and "Widerrufen" after
    /// ignoring it from its details (design review D4). They go with the bars.
    @ViewBuilder
    private var notes: some View {
        if chrome.isShown {
            VStack(spacing: 0) {
                if shareState == .onlyInICloud && !isVideo {
                    ShareInICloudNote()
                        .transition(.opacity)
                }
                IgnoreUndoBar()
            }
        }
    }

    // MARK: Sheets

    private func details(_ facts: AssetFacts) -> some View {
        AssetDetailView(facts: facts) { addingToAlbum = [facts.id] }
            .presentationDetents([.medium, .large])
            // A half-height sheet is see-through glass in iOS 26: over the black viewer
            // the light text lost its contrast ("Taken", UI run 43773339053). Solid.
            .presentationBackground(Theme.background)
    }

    private var addingBinding: Binding<Bool> {
        Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })
    }

    private var addSheet: some View {
        AddToAlbumSheet(assets: addingToAlbum ?? []) {}
            .presentationBackground(Theme.background)
    }

    // MARK: What the viewer does

    private var assistive: Bool { voiceOver || switchControl }
    private var shareState: ShareAvailability { sharing[current] ?? .unknown }
    private var isVideo: Bool { model.factsByID[current]?.asset.kind == .video }

    /// A tap on the photo: the bars, the status bar and the home indicator go or come back, a
    /// plain fade with Reduce Motion; with VoiceOver or Switch Control they stay.
    private func toggleChrome() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)) {
            chrome.tap(assistive: assistive)
        }
    }

    /// Whether the photo shown can be shared: asked once it has been on screen a moment (not for
    /// every photo swiped past), and once per photo.
    private func checkSharing() async {
        let id = current
        guard sharing[id] == nil, !isVideo else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let found = await PhotoShare.availability(of: id)
        guard found != .unknown else { return }
        withAnimation(.easeInOut(duration: 0.2)) { sharing[id] = found }
    }

    /// The share sheet with the photo shown, once its file is ready (a moment for a large one).
    /// A photo found only in iCloud turns the button off with its reason.
    private func share() {
        let id = current
        preparingShare = true
        shareTask = Task {
            let prepared = await PhotoShare.prepare(id, fallbackName: String(localized: "Foto"))
            preparingShare = false
            switch prepared {
            case .file(let file) where id == current && !Task.isCancelled:
                PhotoShare.present(file)
            case .file(let file):
                // Swiped on or closed meanwhile: not the photo on screen.
                PhotoShare.remove(file.deletingLastPathComponent())
            case .unavailable(let reason):
                withAnimation(.easeInOut(duration: 0.2)) { sharing[id] = reason }
            }
        }
    }
}

/// One photo that fits the screen; pinch or double-tap to zoom, drag to look around, pull
/// down to close, tap to hide or show the bars, press and hold to play a Live Photo.
private struct ZoomablePhoto: View {
    var id: AssetID
    /// What VoiceOver says: place, day and time ("München, 12. Oktober 2024, 14:32").
    var label: String
    /// Where it is among the photos ("3 von 176").
    var position: Text
    /// The photo on screen (the pages beside it are built too): only it loads its Live Photo.
    var isCurrent: Bool
    /// The top of the photo's area (under the bar).
    var top: CGFloat
    @Binding var pull: CGFloat
    var onTap: () -> Void
    var onClose: () -> Void
    /// Its Live Photo's motion is on the iPhone and can play.
    var onLive: (AssetID) -> Void
    @State private var image: UIImage?
    /// Nothing came from Photos (only in iCloud, or gone): said instead of an endless spinner.
    @State private var unavailable = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var live: LivePhotoLoader.Live?
    @State private var command = LiveCommand()
    @GestureState private var holding = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
                .task(id: id) { await load(in: area(of: geo.size)) }
                .task(id: id) { await giveUp() }
                .task(id: LiveRequest(id: id, isCurrent: isCurrent, shown: image != nil)) { await loadLive(in: area(of: geo.size)) }
        }
        .onDisappear { reset() }
        .onChange(of: holding) { _, held in play(held ? .full : .stop) }
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
            .gesture(touches)
            .gesture(magnify)
            // Moving the zoomed photo wins over swiping to the next one; at normal size the
            // swipe goes to the next photo.
            .highPriorityGesture(pan, including: scale > 1 ? .all : .subviews)
            // At normal size a mostly vertical pull down closes the viewer, as in Photos;
            // sideways still goes to the next photo.
            .simultaneousGesture(pullDown, including: scale > 1 ? .subviews : .all)
    }

    @ViewBuilder
    private func shown(in size: CGSize) -> some View {
        if let image {
            photo(image, in: size)
        } else if unavailable {
            ContentUnavailableView {
                Label("Dieses Foto ist gerade nicht verfügbar.", systemImage: "icloud.slash")
            } description: {
                Text("Vielleicht liegt es nur in iCloud. In der Fotos-App lädt iOS es herunter.")
            }
            .frame(width: size.width, height: size.height)
            .accessibilityIdentifier("viewer.unavailable")
        } else {
            ProgressView().tint(.white)
                .accessibilityLabel(Text("Foto wird geladen"))
                .frame(width: size.width, height: size.height)
        }
    }

    /// The still, and over it the Live Photo's motion while it plays; zoomed and moved together.
    /// One element for VoiceOver, with the title's words, the position and the zoom.
    private func photo(_ image: UIImage, in size: CGSize) -> some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
            if let live {
                LivePhotoPlayer(livePhoto: live.value, command: command)
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
        // VoiceOver's own zoom gesture instead of "Zweimal tippen zum Vergrößern",
        // which clashed with VoiceOver's double tap (design review W11).
        .accessibilityZoomAction { action in zoom(action) }
        .accessibilityActions { liveActions }
    }

    /// A Live Photo plays from VoiceOver's actions too (swipe up or down), as the long press.
    @ViewBuilder
    private var liveActions: some View {
        if live != nil {
            Button("Live Photo abspielen") { play(.full) }
        }
    }

    // MARK: Gestures

    /// A long press plays a Live Photo whole, as in Photos; a tap hides or shows the bars, a
    /// double tap zooms. The single tap waits for the second one; a press is no tap.
    private var touches: some Gesture {
        hold.exclusively(before: taps)
    }

    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
    }

    private var taps: some Gesture {
        TapGesture(count: 2)
            .onEnded { toggleZoom() }
            .exclusively(before: TapGesture().onEnded { onTap() })
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 5) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { withAnimation(.snappy) { reset() } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private var pullDown: some Gesture {
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

    // MARK: Loading

    private func load(in size: CGSize) async {
        unavailable = false
        let pixels = CGSize(width: size.width * displayScale * 2, height: size.height * displayScale * 2)
        let loaded = await ThumbnailCache.shared.largeImage(for: id, pixels: pixels)
        // After a swipe to the next photo this task is cancelled; its late image must
        // not replace the new photo's.
        guard !Task.isCancelled else { return }
        image = loaded
        if loaded == nil { unavailable = true }
    }

    /// Photos may never answer for a photo that is only in iCloud.
    private func giveUp() async {
        try? await Task.sleep(for: .seconds(15))
        if image == nil && !Task.isCancelled { unavailable = true }
    }

    /// The Live Photo of the photo on screen, once its still shows; the pages beside it let
    /// theirs go. It moves briefly when it comes into view, where motion is welcome.
    private func loadLive(in size: CGSize) async {
        guard isCurrent, image != nil else {
            live = nil
            return
        }
        if live == nil {
            let pixels = CGSize(width: size.width * displayScale * 2, height: size.height * displayScale * 2)
            guard let loaded = await LivePhotoLoader.load(id, pixels: pixels), !Task.isCancelled else { return }
            live = loaded
            onLive(id)
        }
        // A moment for its view to be in place and for the swipe to come to rest.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let welcome = LiveMotion.playsHint(reduceMotion: reduceMotion, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                           autoplayVideos: UIAccessibility.isVideoAutoplayEnabled)
        if welcome { play(.hint) }
    }

    private func play(_ kind: LiveCommand.Kind) {
        guard live != nil else { return }
        command.next(kind)
    }
}
