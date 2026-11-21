import SwiftUI
import UIKit
import AlbumistCore

/// "Fotos fliegen in Alben": while a plan runs, photos lift off a loose pile and fly in one
/// calm arc into their album, one album after another, while a counter runs up.
///
/// The show follows the real work and never runs ahead of it: an album only fills once its
/// step has really finished. With fast work it lasts about 2 s for one album and about 5–7 s
/// for many; when the work is slower, it waits on the next album and photos fly for nearly
/// every one. A backlog of finished albums is riffled through. "Animation überspringen" ends the show
/// at once and stays on screen at every text size: the scene gives way to it (`sceneScale`).
/// With Reduce Motion only the current album is shown and cross-fades; nothing flies.
///
/// Design wave 3 (DS-17, "Show und Handschrift"): the photos are bigger (in the scene 101 pt on
/// the 4.7" iPhone, up to 125 pt; before 76) and the album is its real cover, grey while it waits
/// and in its colours once filled, no longer a pale box (`SortingShowLayout`, `ShowAlbumCover`).
/// On a low screen the pile gives way first and the rest of the scene is scaled (`sceneScale`):
/// on the 4.7" iPhone the photos show at about 82 pt (before about 66). Only photos that are
/// sharp on the device fly or lie on the pile (`ShowPhotos`), never a sensitive document, never
/// a personal suggestion's photo; a personal album shows "Vorschau ausgeblendet"
/// (`SortingShowAlbum`). The count is in Apple's wide figures in the accent, as the result's count
/// that follows it. In Low Power Mode the albums fill as before, with their tap, but no photo
/// flies; the pile shows its photos in every mode.
struct SortingShow: View {
    struct Album: Identifiable, Equatable {
        /// Index of the album's last "add photos" step in the plan.
        let id: Int
        let title: String
        /// Every photo the plan adds: what the counter counts.
        let assets: [AssetID]
        /// What flies and lies on the pile: ordinary photos first, never a sensitive document,
        /// never a personal suggestion's photo (`SortingShowAlbum.flying`). Can be shorter than
        /// `assets`, or empty.
        let shown: [AssetID]
        /// What its cover tries, best first (`SortingShowAlbum.cover`); empty for a personal album.
        let cover: [AssetID]
        /// A personal album: "Vorschau ausgeblendet" on its cover, nothing of it flies.
        let hidesPreview: Bool
    }

    let albums: [Album]
    /// The padding the screen puts around the show (above and below it); kept free when the
    /// show fits itself to the screen (`sceneScale`).
    let screenPadding: CGFloat
    var onFinish: () -> Void
    /// Distinct photos of all albums, counted once here: the pile asked for it in every
    /// redraw, and the show redraws many times a second (a set over every photo of the plan).
    private let totalPhotos: Int

    init(albums: [Album], screenPadding: CGFloat, onFinish: @escaping () -> Void) {
        self.albums = albums
        self.screenPadding = screenPadding
        self.onFinish = onFinish
        totalPhotos = Set(albums.flatMap(\.assets)).count
    }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// Compact on an iPhone turned sideways: the counts stand beside the scene and the button.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// From xxLarge on, the album's name gets more room under its cover (`SortingShowLayout`).
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    /// The photos' number is grouped as the screen's language writes it ("1.234", "1,234").
    @Environment(\.locale) private var locale
    @State private var current = 0
    @State private var landed: Set<Int> = []
    /// Distinct photos sorted so far (a photo in two albums counts once, like the result card).
    @State private var sorted: Set<AssetID> = []
    @State private var flights: [ShowFlight] = []
    @State private var pop = false
    @State private var landings = 0
    /// The width the scene has on screen.
    @State private var available: CGFloat = 360
    /// The height the screen shows of the scroll view the show stands in: between the
    /// navigation bar and the tab bar (`containerRelativeFrame`). Nil until measured.
    @State private var room: CGFloat?
    @State private var headerHeight: CGFloat = 0
    @State private var skipHeight: CGFloat = 0
    /// The photos that are sharp on the device at the size they are drawn: only these lie on
    /// the pile and fly (`ShowPhotos`). Held while they are drawn: an album's go once it landed.
    @State private var photos = ShowPhotos()
    /// Low Power Mode as the show starts: the albums fill one after the other as before, with
    /// their tap, but no photo flies (the calm version; with Reduce Motion or VoiceOver the
    /// albums are riffled through quietly, as before).
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// The scene's sizes for the width on screen (DS-17): photos, cover, pile and strip; on a low
    /// screen with its pile giving way first (`sceneRoom`).
    private var stage: SortingShowLayout {
        SortingShowLayout(width: Double(available), largeText: typeSize >= .xxLarge, room: sceneRoom.map { Double($0) })
    }
    /// The scene's own height, from its sizes: 431 pt on the 4.7" iPhone with room enough (360 pt
    /// before DS-17), 387 pt with its pile given way.
    private var sceneHeight: CGFloat { CGFloat(stage.height) }
    /// The show's own padding above its counts.
    private static let topPadding = Theme.Spacing.m
    private var sideBySide: Bool { verticalSizeClass == .compact }
    /// What the screen leaves for the scene: its visible height without the padding, the counts
    /// and the button, which keep their text size, so "Animation überspringen" stays on screen at
    /// every size (review P3-18: at the largest text it lay below the tab bar on the small
    /// iPhone, and there even at the default size). Nil until measured.
    private var sceneRoom: CGFloat? {
        guard let room else { return nil }
        var free = room - 2 * screenPadding - Self.topPadding - skipHeight - Theme.Spacing.l
        if !sideBySide { free -= headerHeight + Theme.Spacing.l }
        return free
    }
    /// The scene's own size, 1 where the screen has room for it. Where it has not, the pile gave
    /// way first (`stage`), and the rest is scaled: drawn at its full size and scaled, so the
    /// flights keep their paths. On the 4.7" iPhone about 0.81 (313 pt for 387), 0.73 before the
    /// pile gave way (second review, K6).
    private var sceneScale: CGFloat {
        guard let free = sceneRoom else { return 1 }
        return min(1, max(0.1, free / sceneHeight))
    }
    /// The scene's width before scaling: scaled, it fills the width on screen.
    private var width: CGFloat { available / sceneScale }
    private var pileCenter: CGPoint { CGPoint(x: width / 2, y: CGFloat(stage.pileCenterY)) }
    private var coverCenter: CGPoint { CGPoint(x: width / 2, y: CGFloat(stage.coverCenterY)) }
    private var spacing: CGFloat { CGFloat(stage.spacing) }
    /// A photo's size in pixels: what a photo on the pile or in flight must bring to be sharp.
    private var photoPixels: CGSize {
        let side = CGFloat(stage.photo) * displayScale
        return CGSize(width: side, height: side)
    }
    private var counted: Int { sorted.count }

    var body: some View {
        // Turned sideways the screen is too low for counts, scene and button one below the
        // other: the counts stand beside the scene and its button. One layout that changes its
        // direction, so turning the iPhone mid-show keeps the scene and its flying photos.
        let layout = sideBySide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.l))
            : AnyLayout(VStackLayout(spacing: Theme.Spacing.l))
        layout {
            header
            VStack(spacing: Theme.Spacing.l) {
                scene
                skip
            }
        }
        // iPad: a focused column instead of a small cluster in a wide band.
        .frame(maxWidth: sideBySide ? .infinity : 520)
        .frame(maxWidth: .infinity)
        .padding(.top, Self.topPadding)
        // How high the screen is: the scroll view's visible height, without its bars.
        .background {
            Color.clear
                .containerRelativeFrame(.vertical)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: landings)
        .task {
            if voiceOver {
                AccessibilityNotification.Announcement(String(localized: "Fotos werden einsortiert")).post()
            }
            await run()
        }
        // The pile's photos, sharp at the size they are drawn, in every mode (only the flights
        // wait for `flies`; second review, K1); again when the size changes, and after a memory
        // warning took them (`ShowPhotos.letGo`).
        .task(id: PileLoad(side: stage.photo, generation: photos.generation)) {
            await photos.load(pilePhotos, side: CGFloat(stage.photo), scale: displayScale)
        }
    }

    /// When the pile's photos are loaded: for their size, and again after a memory warning.
    private struct PileLoad: Equatable {
        var side: Double
        var generation: Int
    }

    /// Photos fly: not with Reduce Motion or VoiceOver (the albums are riffled through quietly),
    /// not in Low Power Mode (the albums fill with their tap, nothing flies). The pile shows its
    /// photos either way.
    private var flies: Bool { !reduceMotion && !voiceOver && !lowPower }

    // MARK: Parts

    /// Pile, albums and flying photos, drawn at the scene's own height (`SortingShowLayout`) and
    /// scaled to what the screen has left (`sceneScale`); in the layout it takes only its scaled
    /// height.
    private var scene: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: sceneHeight * sceneScale)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            .overlay(alignment: .top) {
                ZStack {
                    pile
                    carousel
                    ForEach(flights) {
                        ShowFlyingPhoto(flight: $0, side: CGFloat(stage.photo), radius: CGFloat(stage.photoRadius))
                    }
                }
                .frame(width: width, height: sceneHeight)
                .scaleEffect(sceneScale, anchor: .top)
            }
            // Nothing to tap: the scene drawn at full size reaches below its scaled frame.
            .allowsHitTesting(false)
            // Decorative and hidden from VoiceOver: the labels must not grow out of the scene.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .accessibilityHidden(true)
    }

    /// Ends only the animation; the albums keep being created in the background. A plain
    /// secondary button: glass belongs to the bars above the content (Theme.swift, design
    /// review N3). Its text stops growing at AX2, where "überspringen" still fits one line on
    /// the small iPhone (at AX5 the word broke in the middle); the scene makes room for it.
    private var skip: some View {
        Button("Animation überspringen", action: onFinish)
            .buttonStyle(SecondaryButtonStyle())
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityIdentifier("show.skip")
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { skipHeight = $0 }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // Albums count up steadily; the photo count would stand still while photos that
            // are already sorted get a second album (a country holds its trips). In Apple's wide
            // figures and the accent (DS-17), as the result's count that follows the show.
            Text(landed.count, format: .number)
                .font(.wideNumber(size: 56))
                .foregroundStyle(Theme.accent)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(landed.count)))
            Text("von \(albums.count) Alben fertig")
                .font(.headline)
                .foregroundStyle(.secondary)
            ZStack {
                // The widest the line gets, kept hidden: the header keeps its height while the
                // count runs up (a line that wrapped mid-show would shrink the scene at once).
                Text("\(totalPhotos) \(SortingShowWords.number(totalPhotos, locale: locale)) Fotos einsortiert")
                    .hidden()
                    .accessibilityHidden(true)
                Text("\(counted) \(SortingShowWords.number(counted, locale: locale)) Fotos einsortiert")
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(counted)))
            }
            .font(.subheadline)
            .foregroundStyle(.noteText)
            .monospacedDigit()
        }
        // Wrapped lines stay centred under the count. The show lasts a few seconds and its
        // progress is spoken in full below, so the captions stop growing at AX1: beyond that
        // they outgrow the 56 pt count and push the albums off a small screen.
        .multilineTextAlignment(.center)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Fotos werden einsortiert"))
        .accessibilityValue(Text("\(landed.count) von \(albums.count) Alben fertig, \(counted) \(SortingShowWords.number(counted, locale: locale)) Fotos einsortiert"))
        .accessibilityAddTraits(.updatesFrequently)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }

    /// The pile thins out as photos find their albums. Only photos that are sharp on the device
    /// lie on it; each one fades in once it is loaded.
    private var pile: some View {
        let stage = self.stage
        let pixels = photoPixels
        let shown = pilePhotos.filter { photos.image($0, sharpAt: pixels) != nil }
        let remaining = 1 - Double(counted) / Double(max(1, totalPhotos))
        let visible = max(0, min(shown.count, Int((remaining * Double(shown.count)).rounded(.up))))
        return ZStack {
            ForEach(Array(shown.prefix(visible).enumerated()), id: \.element) { index, id in
                if let image = photos.image(id, sharpAt: pixels) {
                    let loose = stage.loose(index)
                    ShowPhotoChip(image: image, side: CGFloat(stage.photo), radius: CGFloat(stage.photoRadius))
                        .rotationEffect(.degrees(loose.angle))
                        .offset(x: CGFloat(loose.x), y: CGFloat(loose.y))
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.scale(scale: 0.5).combined(with: .opacity))
                }
            }
        }
        .position(pileCenter)
        .animation(.smooth(duration: 0.35), value: visible)
    }

    /// The albums move as one strip; with Reduce Motion only the current one, cross-fading.
    private var carousel: some View {
        let stage = self.stage
        return ZStack {
            ForEach(albums.indices.filter { reduceMotion ? $0 == current : abs($0 - current) <= 1 }, id: \.self) { index in
                let offset = CGFloat(index - current)
                ShowAlbumCover(album: albums[index], filled: landed.contains(index), focused: index == current, layout: stage)
                    // Fade the album as one picture, its layers and cover together.
                    .compositingGroup()
                    .scaleEffect(index == current ? (pop && !reduceMotion ? 1.04 : 1) : SortingShowLayout.neighbourScale)
                    .opacity(index == current ? 1 : (index < current ? 0.5 : 0.35))
                    .position(x: coverCenter.x + offset * spacing, y: coverCenter.y)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.asymmetric(
                        insertion: AnyTransition.offset(x: spacing).combined(with: .opacity),
                        removal: AnyTransition.offset(x: -spacing).combined(with: .opacity)))
            }
        }
    }

    /// Up to six photos from the first albums, so the pile shows the user's own pictures.
    private var pilePhotos: [AssetID] {
        var result: [AssetID] = []
        var round = 0
        while result.count < 6 && round < 6 {
            for album in albums where round < album.shown.count && result.count < 6 {
                let id = album.shown[round]
                if !result.contains(id) { result.append(id) }
            }
            round += 1
        }
        return result
    }

    /// How many photos fly into one album.
    private var flightCount: Int { albums.count == 1 ? 5 : 3 }

    // MARK: Choreography

    private func run() async {
        let started = Date()
        // When the strip may move again: a move never starts while the last one is still
        // running, otherwise a fast riffle shows two strips sliding over each other.
        var moveEnds = Date.distantPast
        // `.task` restarts when the tab comes back: continue there, never land an album twice.
        for index in albums.indices where !landed.contains(index) {
            if Task.isCancelled { return }
            let essential = index < 3 || index == albums.count - 1
            let calm = !reduceMotion && !voiceOver
            if calm && (essential || albumsDone() - index <= 1) {
                await prefetch(index)
            }
            await waitUntilDone(index, started: started)
            let execution = model.execution
            if Task.isCancelled || execution.failure != nil { break }
            if !execution.isRunning && execution.finished == nil { break } // never started: no celebration
            // A step that failed or was skipped gets no checkmark.
            if model.executionProgress.unsuccessfulSteps.contains(albums[index].id) { continue }
            // Photos fly while the show keeps up; a backlog of finished albums is riffled through.
            let quick = !calm || (!essential && albumsDone() - index > 1)
            let mustMove = current != index && (!quick || index == albums.count - 1)
            if mustMove, moveEnds.timeIntervalSinceNow > 0 {
                try? await Task.sleep(for: .seconds(moveEnds.timeIntervalSinceNow))
            }
            if current != index && (mustMove || moveEnds.timeIntervalSinceNow <= 0) {
                let duration = reduceMotion || quick ? 0.3 : 0.5
                withAnimation(reduceMotion ? .easeInOut(duration: duration) : .smooth(duration: duration)) {
                    current = index
                }
                moveEnds = Date().addingTimeInterval(duration + 0.04)
            }
            if quick {
                await land(index, quietly: true)
                let step = reduceMotion ? max(0.08, min(0.5, 2.0 / Double(albums.count))) : 0.06
                try? await Task.sleep(for: .seconds(step))
            } else {
                // In Low Power Mode nothing flies: the album fills after the same short wait.
                let arrival = launch(index, duration: albums.count == 1 ? 0.7 : 0.58, lead: 0.15)
                try? await Task.sleep(for: .seconds(arrival))
                await land(index, quietly: false)
                try? await Task.sleep(for: .seconds(0.15))
                // The next album already moves to the centre and waits there while its step runs.
                if index + 1 < albums.count && albumsDone() <= index + 1 {
                    withAnimation(.smooth(duration: 0.5)) { current = index + 1 }
                    moveEnds = Date().addingTimeInterval(0.54)
                }
            }
        }
        await waitForEnd(started: started)
        guard !Task.isCancelled else { return }
        // The counter ends on what really arrived, counted as the receipt and the result count
        // ("mit 342 Fotos"): photos no longer in the library, or in a step whose outcome is
        // unclear, are not counted. Skipped or watched to its end, the show hands over to the
        // same result (`onFinish`).
        if let finished = model.execution.finished {
            let applied = finished.confirmedAddedMedia
            if applied != sorted { withAnimation(.snappy(duration: 0.3)) { sorted = applied } }
        }
        // A UI test may hold the end to read it (`-AlbumistUITestShowHold`, verification review V8).
        try? await Task.sleep(for: .seconds(UITestSupport.holdsShowEnd ? 15 : 0.5))
        guard !Task.isCancelled else { return }
        onFinish()
    }

    /// Sends the first sharp photos of an album on their way (none in Low Power Mode); returns
    /// when the last one arrives, or after the same time when none flies.
    @discardableResult
    private func launch(_ index: Int, duration: Double, lead: Double = 0) -> Double {
        let album = albums[index]
        let stage = self.stage
        let pixels = photoPixels
        var ready: [(AssetID, UIImage)] = []
        if flies {
            for id in album.shown where ready.count < flightCount {
                if let image = photos.image(id, sharpAt: pixels) { ready.append((id, image)) }
            }
        }
        let count = ready.count
        let flight = max(0.5, duration)
        let stagger = 0.08
        let photo = CGFloat(stage.photo)
        // Into the cover's upper middle, where the photos sink into the album.
        let target = CGPoint(x: coverCenter.x, y: coverCenter.y - CGFloat(stage.cover) * 0.12)
        // One calm gesture per album: all photos bow to the same side, alternating per album.
        let bow: CGFloat = (index.isMultiple(of: 2) ? 1 : -1) * min(photo * 0.84, width * 0.16)
        var launched: [ShowFlight] = []
        for (k, item) in ready.enumerated() {
            let loose = stage.loose(k)
            // Dealt from the top of the pile; the flight fades them in while they lift.
            let from = CGPoint(x: pileCenter.x + CGFloat(loose.x) * 0.25, y: pileCenter.y + CGFloat(loose.y) * 0.25 - 6)
            let to = CGPoint(x: target.x + CGFloat(k % 3 - 1) * 5, y: target.y + CGFloat(k % 2) * 3)
            let control = CGPoint(x: (from.x + to.x) / 2 + bow * (1 + 0.2 * CGFloat(k)), y: from.y - photo * 0.55)
            launched.append(ShowFlight(asset: item.0, image: item.1, from: from, control: control, to: to,
                                       angle: loose.angle, delay: lead + Double(k) * stagger, duration: flight))
        }
        flights.append(contentsOf: launched)
        let arrival = lead + Double(max(0, count - 1)) * stagger + flight
        let ids = Set(launched.map(\.id))
        if !ids.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(arrival + 0.3))
                flights.removeAll { ids.contains($0.id) }
            }
        }
        return arrival
    }

    private func land(_ index: Int, quietly: Bool) async {
        guard !landed.contains(index) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.32, dampingFraction: 0.62)) {
            _ = landed.insert(index)
        }
        withAnimation(.snappy(duration: quietly ? 0.15 : 0.35)) { sorted.formUnion(albums[index].assets) }
        // Its photos are drawn no more (the flights hold theirs until they end): the show keeps
        // only what it shows (second review, K2), the pile's photos.
        photos.release(albums[index].shown, keeping: Set(pilePhotos))
        if quietly { return }
        if index < 3 || index == albums.count - 1 { landings += 1 } // a few soft taps, not one per album
        withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { pop = true }
        try? await Task.sleep(for: .seconds(0.14))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { pop = false }
    }

    /// Never ahead of the real work: wait until the album's step has finished.
    private func waitUntilDone(_ index: Int, started: Date) async {
        while !Task.isCancelled {
            let execution = model.execution
            // completedSteps only counts for this run while it runs (a previous run leaves its value).
            if execution.isRunning && model.executionProgress.completedSteps > albums[index].id { return }
            if execution.finished != nil || execution.failure != nil { return }
            if !execution.isRunning && Date().timeIntervalSince(started) > 3 { return }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    /// The result card needs isRunning == false; `finished` is set earlier, before the new
    /// albums are recorded.
    private func waitForEnd(started: Date) async {
        while !Task.isCancelled {
            let execution = model.execution
            if !execution.isRunning && (execution.finished != nil || execution.failure != nil) { return }
            if !execution.isRunning && Date().timeIntervalSince(started) > 3 { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func albumsDone() -> Int {
        let execution = model.execution
        if execution.finished != nil { return albums.count }
        guard execution.isRunning else { return 0 }
        let completed = model.executionProgress.completedSteps
        return albums.filter { completed > $0.id }.count
    }

    /// Loads what the album shows next, not mid-flight: the photos about to fly (sharp only, not
    /// when nothing flies) and its cover at the size it is drawn, which `CoverLoader` keeps for
    /// the album's `CoverPhoto` (the same pixels: whole points times the screen's scale).
    private func prefetch(_ index: Int) async {
        let album = albums[index]
        let stage = self.stage
        if flies {
            await photos.load(album.shown.prefix(flightCount), side: CGFloat(stage.photo), scale: displayScale)
        }
        guard !album.hidesPreview, !album.cover.isEmpty, !Task.isCancelled else { return }
        let side = CGFloat(stage.cover) * displayScale
        _ = await CoverLoader.load(CoverLoader.Request(ids: Array(album.cover.prefix(CoverLoader.attempts)),
                                                       pixels: CGSize(width: side, height: side)))
    }

    // MARK: Plan → albums

    /// The albums of the show, in plan order (`SortingShowAlbum.cast`, `AppModel.sortingShowAlbums`).
    static func albums(from cast: [SortingShowAlbum]) -> [Album] {
        cast.map {
            Album(id: $0.lastStep, title: $0.title ?? String(localized: "Album"), assets: $0.assets,
                  shown: $0.flying, cover: $0.cover, hidesPreview: $0.hidesPreview)
        }
    }
}
