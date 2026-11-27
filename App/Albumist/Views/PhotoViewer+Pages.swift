import SwiftUI
import UIKit
import AlbumistCore

/// The photo view's pages, its bars and notes, and what it does as the user looks, swipes, taps
/// and shares (`PhotoViewer`).
extension PhotoViewer {
    // MARK: Pages

    /// The pages with what is around them: black behind, the bars, the notes at the bottom.
    var pager: some View {
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
            // A video pauses when the app goes to the background, as in Photos; told by the
            // app too, as a full-screen cover has not always been told its scene's phase.
            .onChange(of: scenePhase) { _, phase in if phase == .background { video.pause() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in video.pause() }
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
                                  kind: kind(of: id), player: video.surface(for: id),
                                  top: top, pull: $pull, onTap: { toggleChrome() }, onClose: { closeNow() },
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
        Button { closeNow() } label: { Label("Schließen", systemImage: "xmark") }
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

    /// A video, as Photos or else Albumist's facts say (DS-16); not while neither says.
    private func isVideo(_ id: AssetID) -> Bool {
        knownVideo(id) ?? false
    }

    /// Whether `id` is a video, as Photos says once it is known, before that as Albumist's facts
    /// say; nil while neither says (a video not analysed yet beside the page on screen).
    private func knownVideo(_ id: AssetID) -> Bool? {
        if let known = basics[id] { return known.isVideo }
        return model.factsByID[id].map { $0.asset.kind == .video }
    }

    /// What the photo view knows of the kind of `id`'s page (`PageKind`): without Photos' word or
    /// facts it is not known until it was the page on screen and Photos was asked, and it waits
    /// meanwhile instead of taking a video's small still for a photo that is not available
    /// (review X6).
    private func kind(of id: AssetID) -> PageKind {
        PageKind(isVideo: knownVideo(id), asked: kindsAsked.contains(id), video: video.availability(for: id))
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
    /// clock before (review D2, N10). Once Photos was asked, its kind counts as known, also when
    /// Photos could not tell it (review X6). A look that a swipe on cancelled goes no further:
    /// opening its video would stop the next page's.
    private func lookAtCurrent() async {
        let id = current
        if !homeZoneAsked {
            homeZone = await model.homeTimeZone()
            homeZoneAsked = true
        }
        if basics[id] == nil, let found = await PhotoBasics.of(id), !Task.isCancelled {
            basics[id] = found
        }
        guard !Task.isCancelled else { return }
        if !kindsAsked.contains(id) { kindsAsked.insert(id) }
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
    func leaveShare() {
        preparation.leave()
        shareTask?.cancel()
        shareTask = nil
    }
}
