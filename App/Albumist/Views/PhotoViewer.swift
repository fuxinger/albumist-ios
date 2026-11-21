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
///
/// Design wave 3: videos play as in Photos (DS-16, `ViewerVideo`): by themselves and looping
/// where motion is welcome, without sound until the user turns it on, only from the iPhone, with
/// their controls under them on a solid ground, going with the bars. While a photo comes, the
/// thumbnail the grid showed stands in for it, never a spinner, and a picture that would only be
/// big and blurry never stands: the calm note says why (DS-18, `ViewerPicture`).
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
    /// The share being prepared for the photo on screen, and whether it failed
    /// (`SharePreparation`; review D2, N1 and N7).
    @State private var preparation = SharePreparation()
    /// Making the file for the share sheet; stopped when the user leaves the share.
    @State private var shareTask: Task<Void, Never>?
    /// The photos whose Live Photo motion is on the iPhone: their title shows the symbol.
    @State private var livePhotos: Set<AssetID> = []
    /// The photo whose Live Photo plays under a long press: the pager holds still meanwhile
    /// (review D2, N4), as in Photos.
    @State private var pressing: AssetID?
    /// What Photos says of each photo looked at: its date, for the title while Albumist has no
    /// facts of it, and its kind (`PhotoBasics`).
    @State private var basics: [AssetID: PhotoBasics] = [:]
    /// 12 or 24 hours as the iPhone is set; read again when its settings change.
    @State private var clock = AppModel.deviceClock()
    /// The clock the analysis tells photos without a place on, asked once before the first date
    /// shows: a photo not analysed yet is told on it (review D2, N10).
    @State private var homeZone: TimeZone?
    @State private var homeZoneAsked = false
    /// The video on screen: one player at most (DS-16).
    @State private var video = ViewerVideo()
    /// The pages whose picture did not come sharp: they say so themselves, the video's note under
    /// them would say it twice.
    @State private var unavailablePictures: Set<AssetID> = []
    @Environment(\.scenePhase) private var scenePhase

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
            // Said here, over the photo: the app's own alert cannot show over this full-screen
            // view and came up after it had closed (review D2, N1).
            .alert("Das hat nicht geklappt", isPresented: shareFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Das Foto konnte nicht zum Teilen vorbereitet werden. Versuch es gleich noch einmal.")
            }
            .onAppear { opened() }
            .onDisappear { closed() }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in clock = AppModel.deviceClock() }
    }

    /// A share the app could not clean up after (it was ended while the sheet was open) goes;
    /// the app's sound is set to mix with the user's before any Live Photo plays (review D2, N9).
    private func opened() {
        PhotoShare.removeLeftovers()
        LiveAudio.prepare()
    }

    /// The video stops, and the app's sound mixes with the user's again (DS-16).
    private func closed() {
        leaveShare()
        PhotoShare.removeLeftovers()
        video.close()
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
            .animation(.easeInOut(duration: 0.2), value: video.availability)
            .onChange(of: assistive, initial: true) { _, running in chrome.assistiveTechnology(running: running) }
            .task(id: current) { await lookAtCurrent() }
            // A video pauses when the app goes to the background, as in Photos.
            .onChange(of: scenePhase) { _, phase in if phase == .background { video.pause() } }
    }

    private var pages: some View {
        TabView(selection: $current) {
            ForEach(window.range.clamped(to: ids.indices), id: \.self) { index in
                page(at: index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // A thumb that drifts while a Live Photo plays under it does not page (review D2, N4).
        .scrollDisabled(pressing != nil)
        .onChange(of: current) {
            window = window.following(ids.firstIndex(of: current) ?? 0, count: ids.count)
            // A share prepared for the photo left behind is not this one's (review D2, N7).
            leaveShare()
            // A video left behind stops at once, as in Photos (DS-16).
            video.keepOnly(current)
        }
        // The photos lie on the whole screen, under a bar of fixed height (`top`).
        .ignoresSafeArea()
        // No photo under the title (design rule 1), also zoomed, after a tap while zoomed and
        // with VoiceOver (review D2, N8).
        .mask { photosArea }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { measured in
            if chrome.isShown { top = measured }
        }
    }

    /// Where the photos show: the whole screen but the bar's area while the bars show. With the
    /// bars hidden a zoomed photo fills the screen, as in Photos; the area fades with the bars
    /// (a fade with Reduce Motion too), and nothing moves.
    private var photosArea: some View {
        VStack(spacing: 0) {
            Color.black.opacity(chrome.isShown ? 0 : 1)
                .frame(height: top)
            Color.black
        }
        .ignoresSafeArea()
    }

    private func page(at index: Int) -> some View {
        let id = ids[index]
        let photo = ZoomablePhoto(id: id, label: label(of: id), position: position(of: index), isCurrent: id == current,
                                  isVideo: isVideo(id), player: video.surface(for: id),
                                  top: top, pull: $pull, onTap: { toggleChrome() }, onClose: { dismiss() },
                                  onLive: { _ = livePhotos.insert($0) }, onZoom: { zoomChrome() },
                                  onPressing: { livePress(id, $0) }, onPicture: { pictureCame($0, sharp: $1) },
                                  onPlayPause: { if video.id == id { video.togglePlay() } })
        return photo.ignoresSafeArea().tag(id)
    }

    /// A long press on the Live Photo of `id` began or ended: the pager holds still meanwhile.
    /// Only the press of that photo ends it.
    private func livePress(_ id: AssetID, _ pressed: Bool) {
        if pressed {
            pressing = id
        } else if pressing == id {
            pressing = nil
        }
    }

    /// Black, lighter while the photo is pulled down to close.
    private var background: some View {
        Color.black.opacity(1 - min(pull / 500, 0.7)).ignoresSafeArea()
    }

    /// The title of a photo: what Albumist knows of it, else the date Photos keeps for it, on
    /// the clock its facts will have (`PhotoTitle.zoneWithoutFacts`).
    private func title(of id: AssetID) -> PhotoTitle {
        model.photoTitle(for: id, photo: basics[id], homeZone: homeZone, clock: clock)
    }

    /// What VoiceOver says for a photo: where and when it was taken, as its title says it; for a
    /// video then what it is and how long ("Video, 15 Sekunden", DS-16).
    private func label(of id: AssetID) -> String {
        let spoken = title(of: id).spoken(live: livePhotos.contains(id))
        guard let length = videoLength(of: id) else { return spoken }
        return spoken + ", " + length.spoken(model.proposalWords)
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
        PhotoTitleBar(title: title(of: current), live: livePhotos.contains(current))
    }

    /// Shares the photo from the iPhone (`PhotoShare`); off, with the reason, where only a
    /// preview of it is here. Only for still images (DS-10); a video plays (DS-16).
    @ViewBuilder
    private var shareButton: some View {
        if isImage {
            Button { share() } label: { Label("Teilen", systemImage: "square.and.arrow.up") }
                .disabled(!shareState.canShare || preparation.isPreparing)
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
            Button {
                // The details cover the photo: a share still being prepared would come up over
                // them, or fail where it cannot be said (review D2, N1).
                leaveShare()
                info = facts
            } label: { Label("Info", systemImage: "info.circle") }
                .accessibilityIdentifier("viewer.info")
        }
    }

    /// Under the photo, on a solid ground: why it cannot be shared, which goes with the bars, a
    /// video's controls or why it does not play, which go with the bars too (DS-16), and
    /// "Widerrufen" after ignoring the photo from its details (design review D4), which stays for
    /// its time even when a tap hides the bars (review D, L7).
    private var notes: some View {
        VStack(spacing: 0) {
            if chrome.isShown && shareState == .onlyInICloud && isImage {
                ShareInICloudNote()
                    .transition(.opacity)
            }
            if chrome.isShown && video.id == current {
                videoPanel
                    .transition(.opacity)
            }
            IgnoreUndoBar()
        }
    }

    /// A video that plays has its controls; one that does not says why, unless its page says it
    /// already (no sharp still of it on the iPhone either).
    @ViewBuilder
    private var videoPanel: some View {
        if video.availability.plays {
            VideoControls(video: video, words: model.proposalWords)
        } else if let note = video.availability.note, !unavailablePictures.contains(current) {
            VideoNoteView(note: note)
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

    /// The share of the photo on screen failed: said until the user taps OK.
    private var shareFailed: Binding<Bool> {
        Binding(get: { preparation.failed }, set: { if !$0 { preparation.failureSeen() } })
    }

    private var addSheet: some View {
        AddToAlbumSheet(assets: addingToAlbum ?? []) {}
            .presentationBackground(Theme.background)
    }

    // MARK: What the viewer does

    private var assistive: Bool { voiceOver || switchControl }
    private var shareState: ShareAvailability { sharing[current] ?? .unknown }

    /// A still image, the only kind that is shared: as Photos says once it is known (`basics`),
    /// before that as Albumist's facts say (review D, L4: a video without facts was offered).
    private var isImage: Bool {
        if let known = basics[current] { return known.isImage }
        return model.factsByID[current].map { $0.asset.kind == .image } ?? true
    }

    /// A page said whether its sharp picture came (DS-18): under one that says it is not
    /// available now, a video's note would say it twice; one that came later has it again.
    private func pictureCame(_ id: AssetID, sharp: Bool) {
        if sharp {
            if unavailablePictures.contains(id) { unavailablePictures.remove(id) }
        } else {
            unavailablePictures.insert(id)
        }
    }

    /// A video, as Photos says once it is known, before that as Albumist's facts say (DS-16).
    private func isVideo(_ id: AssetID) -> Bool {
        if let known = basics[id] { return known.isVideo }
        return model.factsByID[id]?.asset.kind == .video
    }

    /// How long a video is, as Photos or else Albumist's facts say; nil for a photo.
    private func videoLength(of id: AssetID) -> VideoDuration? {
        if let known = basics[id] { return known.length }
        guard let facts = model.factsByID[id], facts.asset.kind == .video else { return nil }
        return VideoDuration(seconds: facts.asset.duration)
    }

    /// A tap on the photo: the bars, the status bar and the home indicator go or come back, a
    /// plain fade with Reduce Motion; with VoiceOver or Switch Control they stay.
    private func toggleChrome() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)) {
            chrome.tap(assistive: assistive)
        }
    }

    /// The photo was zoomed in: the bars go, as in Photos, so no title stands on the zoomed
    /// photo (design rule 1; review D, L6); never with VoiceOver or Switch Control.
    private func zoomChrome() {
        guard chrome.isShown else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)) {
            chrome.zoomed(assistive: assistive)
        }
    }

    /// The photo on screen: what Photos says of it (its date and kind, once per photo), then
    /// whether it can be shared. The home clock first, once, so a date never shows on another
    /// clock before (review D2, N10).
    private func lookAtCurrent() async {
        let id = current
        if !homeZoneAsked {
            homeZone = await model.homeTimeZone()
            homeZoneAsked = true
        }
        if basics[id] == nil, let found = await PhotoBasics.of(id), !Task.isCancelled {
            basics[id] = found
        }
        if isVideo(id) { await playVideo(id) }
        await checkSharing(id)
    }

    /// The video on screen (DS-16): asked for from the iPhone only, played by itself where
    /// motion is welcome (`VideoStart`), once in Low Power Mode; it stops when the user swipes on
    /// (`keepOnly`).
    private func playVideo(_ id: AssetID) async {
        let start = VideoStart(reduceMotion: reduceMotion, autoplayVideos: UIAccessibility.isVideoAutoplayEnabled,
                               lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        await video.open(id, length: videoLength(of: id), start: start)
    }

    /// Whether the photo shown can be shared: asked once it has been on screen a moment (not for
    /// every photo swiped past), and once per photo. Only an answer is kept: when Photos did not
    /// answer, the next look asks again (review D, M6).
    private func checkSharing(_ id: AssetID) async {
        guard sharing[id] == nil, isImage else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let found = await PhotoShare.availability(of: id)
        guard found != .unknown, !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) { sharing[id] = found }
    }

    /// The share sheet with the photo shown, once its file is ready (a moment for a large one).
    /// A photo found only in iCloud turns the button off with its reason; when Photos did not
    /// answer or the file could not be written, the photo view says so and the button stays on
    /// for another try (review D, M6). Only for the photo still on screen (`SharePreparation`,
    /// review D2, N7): a share the user left is neither shown nor said, its file goes.
    private func share() {
        guard let ticket = preparation.begin(current) else { return }
        shareTask = Task {
            let prepared = await PhotoShare.prepare(ticket.photo, fallbackName: String(localized: "Foto"))
            switch preparation.end(ticket, with: prepared.result, onScreen: current) {
            case .present:
                if case .file(let file) = prepared { PhotoShare.present(file) }
            case .discard:
                if case .file(let file) = prepared { PhotoShare.remove(file.deletingLastPathComponent()) }
            case .remember(let reason):
                withAnimation(.easeInOut(duration: 0.2)) { sharing[ticket.photo] = reason }
            case .sayFailed:
                // The alert on the root shows while `preparation.failed`.
                break
            }
        }
    }

    /// The user left the share being prepared (a swipe, the details, closing the view): its
    /// button is free again, and its end is neither shown nor said.
    private func leaveShare() {
        preparation.leave()
        shareTask?.cancel()
        shareTask = nil
    }
}

/// One photo that fits the screen; pinch or double-tap to zoom, drag to look around, pull
/// down to close, tap to hide or show the bars, press and hold to play a Live Photo
/// (`LivePress`). A video plays over its still (`VideoSurface`), zoomed and pulled with it, also
/// before the still came and when none came sharp: the video is its own sharp picture.
///
/// While the photo comes, the thumbnail the grid showed stands in for it, from memory, as in
/// Photos; without one the page is black. No spinner (DS-18). The large picture shows only when
/// it is sharp at the screen's size (`ViewerPicture`); a photo of which only Photos' small
/// preview is on the iPhone (the photo itself in iCloud) gets the calm note instead of a big
/// blurry picture (design rule 6).
private struct ZoomablePhoto: View {
    var id: AssetID
    /// What VoiceOver says: place, day and time ("München, 12. Oktober 2024, 14:32").
    var label: String
    /// Where it is among the photos ("3 von 176").
    var position: Text
    /// The photo on screen (the pages beside it are built too): only it loads its Live Photo.
    var isCurrent: Bool
    /// A video: its words while it loads and when it is not available; VoiceOver's magic tap
    /// plays and pauses it.
    var isVideo: Bool
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
    @State private var image: UIImage?
    /// No sharp picture came from Photos (only in iCloud, or gone): said instead of an endless
    /// wait or a big blurry picture.
    @State private var unavailable = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var live: LivePhotoLoader.Live?
    @State private var command = LiveCommand()
    /// A long press plays the Live Photo (`LivePress`); when the last one ended.
    @State private var pressing = false
    @State private var pressEnded: ContinuousClock.Instant?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// A video that plays is its own sharp picture: it shows while its still comes and when none
    /// came sharp (a small poster frame), never under the note (review F, F6).
    @ViewBuilder
    private func shown(in size: CGSize) -> some View {
        if image != nil || player != nil {
            photo(image, in: size)
        } else if unavailable {
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
        } else {
            waiting(in: size)
        }
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

    // MARK: Loading

    /// The large picture, at twice the screen's pixels for the zoom; shown when it is sharp at
    /// the screen's size, or the photo's whole self (a small photo); otherwise the note (DS-18).
    private func load(in size: CGSize) async {
        unavailable = false
        let basics = await PhotoBasics.of(id)
        let pixels = CGSize(width: size.width * displayScale * 2, height: size.height * displayScale * 2)
        let loaded = await ThumbnailCache.shared.largeImage(for: id, pixels: pixels)
        // After a swipe to the next photo this task is cancelled; its late image must
        // not replace the new photo's.
        guard !Task.isCancelled else { return }
        let screen = PixelSize(width: Double(size.width * displayScale), height: Double(size.height * displayScale))
        switch ViewerPicture.choose(preview: false, delivered: loaded.map(Self.pixelSize(of:)), answered: true,
                                    original: basics?.pixels, screen: screen) {
        case .sharp:
            image = loaded
            onPicture(id, true)
        case .unavailable: becameUnavailable()
        case .waiting: break
        }
    }

    private static func pixelSize(of image: UIImage) -> PixelSize {
        PixelSize(width: Double(image.size.width * image.scale), height: Double(image.size.height * image.scale))
    }

    /// Photos may never answer for a photo that is only in iCloud.
    private func giveUp() async {
        try? await Task.sleep(for: .seconds(15))
        if image == nil && !Task.isCancelled { becameUnavailable() }
    }

    /// No sharp picture comes: the page says so, and the photo view knows.
    private func becameUnavailable() {
        unavailable = true
        onPicture(id, false)
    }

    /// The Live Photo of the photo on screen, once its still shows; the pages beside it let
    /// theirs go. It moves briefly when it comes into view, where motion is welcome.
    private func loadLive(in size: CGSize) async {
        guard isCurrent, image != nil else {
            live = nil
            return
        }
        if live == nil {
            // The screen's pixels: the motion shows only while it plays (review D, L5: twice as
            // many held a still of up to 12 megapixels beside the three stills of the pager).
            let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
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
