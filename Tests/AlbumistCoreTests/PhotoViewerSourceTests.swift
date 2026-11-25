import Foundation
import Testing
import AlbumistTestSupport

/// The photo view's app code (design wave 2, DS-10), read from the source (the app does not
/// build on Linux): date and place as the title, sharing only what is on the iPhone, a tap hides
/// everything but never leaves VoiceOver or Switch Control without controls, Live Photos move
/// where motion is welcome, and everything the viewer did before stays.
@Suite("Photo view source (DS-10)")
struct PhotoViewerSourceTests {
    static let folder = "App/Albumist/Views/PhotoViewer"

    static func viewer() throws -> String { try PhotoViewerSource.read() }
    static func file(_ name: String) throws -> String { try AppSource.read("\(folder)/\(name)") }

    /// The code of `path` with comments and strings blanked.
    static func code(_ path: String) throws -> String { AppSource.code(try AppSource.read(path)) }

    /// The files that load photos for the photo view.
    static var loadingFiles: [String] {
        PhotoViewerSource.views + ThumbnailSource.paths + AppSource.swiftFiles(under: folder)
    }

    static func count(_ pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    // MARK: Never from iCloud

    /// Albumist never loads a photo from iCloud (the owner's promise): every request of the
    /// photo view, its Live Photo and its share says so, and none says otherwise.
    @Test func noRequestLoadsFromICloud() throws {
        #expect(AppSource.swiftFiles(under: Self.folder).count >= 3, "the photo view's own files are missing")
        var requests = 0
        for path in Self.loadingFiles {
            let code = try Self.code(path)
            let options = Self.count(#"\bPH\w*RequestOptions\(\)"#, in: code)
            let allowed = Self.count(#"\.isNetworkAccessAllowed\b"#, in: code)
            let off = Self.count(#"\.isNetworkAccessAllowed\s*=\s*false\b"#, in: code)
            #expect(allowed == off, "\(path): network access is set to something other than false")
            #expect(off >= options, "\(path): \(options) request options, only \(off) without network")
            for function in ["requestImage(", "requestImageDataAndOrientation(", "requestLivePhoto(", "requestData(", "writeData("] {
                for arguments in AppSource.calls(of: function, in: code) {
                    requests += 1
                    #expect(arguments.contains("options: options"), "\(path): \(function) without its options")
                }
            }
        }
        let live = try Self.code("\(Self.folder)/LivePhotoPlayer.swift")
        #expect(AppSource.calls(of: "requestLivePhoto(", in: live).count == 1)
        // The share asks for the first bytes of the photo's file and copies it file to file;
        // it no longer reads the whole photo into memory to learn where it is (review D, M3).
        let share = try Self.code("\(Self.folder)/PhotoShare.swift")
        #expect(AppSource.calls(of: "requestImageDataAndOrientation(", in: share).isEmpty)
        #expect(AppSource.calls(of: "requestData(", in: share).count == 1)
        #expect(AppSource.calls(of: "writeData(", in: share).count == 1)
        #expect(requests >= 4)
    }

    // MARK: Date and place as the title

    /// The title is the photo's place, day and time (`PhotoTitle`, in the app's language and on
    /// the iPhone's clock), no longer "3 von 176"; the position stays for VoiceOver.
    @Test func theTitleIsPlaceAndDay() throws {
        let viewer = AppSource.code(try Self.viewer(), keepStrings: true)
        #expect(!viewer.contains("navigationTitle(Text(\"\\((index + 1)"), "the title is still the position")
        #expect(viewer.contains("ToolbarItem(placement: .principal)"))
        #expect(!AppSource.calls(of: "PhotoTitleBar(", in: viewer).isEmpty)
        #expect(!AppSource.calls(of: "model.photoTitle(", in: viewer).isEmpty)
        #expect(viewer.contains(".accessibilityValue("), "the position is gone for VoiceOver too")
        #expect(viewer.contains(" von \\("), "the position is gone for VoiceOver too")
        let model = AppSource.code(try AppSource.read("App/Albumist/Model/AppModel+PhotoViewer.swift"))
        let title = try #require(AppSource.body(of: "func photoTitle(", in: model))
        #expect(title.contains("PhotoTitle(facts: factsByID[id], photoDate: photo?.date, photoLocated: photo?.isLocated ?? false, homeZone: homeZone,"))
        #expect(title.contains("words: proposalWords"))
        #expect(title.contains("currentZone: .current"))
        #expect(title.contains("clock: clock"))
        // Without facts, the date Photos keeps for the photo (review D, M7), on the clock its
        // facts will have: the home clock without a location (review D2, N10).
        let calls = AppSource.calls(of: "model.photoTitle(", in: viewer)
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0.contains("photo: basics[id], homeZone: homeZone, clock: clock") })
        let basics = AppSource.code(try Self.file("PhotoBasics.swift"))
        #expect(basics.contains("creationDate"))
        #expect(basics.contains("isLocated: asset.value.location != nil"))
        #expect(basics.contains("ThumbnailCache.shared.asset(for:"))
        // The home clock as the analysis keeps it, under the analysis' own key.
        let home = try #require(AppSource.body(of: "func homeTimeZone(", in: model))
        #expect(home.contains("store.value(String.self, forKey: Self.homeTimeZoneKey)"))
        let keys = AppSource.code(try AppSource.read("App/Albumist/Model/AppModel+PhotoViewer.swift"), keepStrings: true)
        let engine = AppSource.code(try AppSource.read("Sources/AlbumistEngine/AnalysisPipeline.swift"), keepStrings: true)
        #expect(engine.contains("static let homeTimeZone = \"user.homeTimeZone\""), "the analysis keeps the home clock elsewhere")
        #expect(keys.contains("nonisolated static let homeTimeZoneKey = \"user.homeTimeZone\""))
        // Asked once, before the first date is shown, so no title changes clock while it shows.
        let look = try #require(AppSource.body(of: "private func lookAtCurrent(", in: viewer))
        let asked = try #require(look.range(of: "homeZone = await model.homeTimeZone()"))
        let dated = try #require(look.range(of: "await PhotoBasics.of(id)"))
        #expect(asked.lowerBound < dated.lowerBound, "the date shows before the home clock is known")
        #expect(look.contains("if !homeZoneAsked {"))
        // 12 or 24 hours from the hour cycle, read again when the iPhone's settings change (L2).
        let clock = try #require(AppSource.body(of: "static func deviceClock(", in: model))
        #expect(clock.contains("PhotoTitle.Clock(hourCycle:"))
        #expect(!model.contains("dateFormat(fromTemplate"))
        #expect(viewer.contains("NSLocale.currentLocaleDidChangeNotification"))
        #expect(viewer.contains("clock = AppModel.deviceClock()"))
        let bar = AppSource.code(try Self.file("PhotoTitleBar.swift"))
        #expect(bar.contains(".accessibilityElement(children: .ignore)"))
        #expect(bar.contains("spoken(live:"))
        #expect(bar.contains(".accessibilityShowsLargeContentViewer"))
        #expect(bar.contains(".foregroundStyle(.noteText)"))
    }

    /// The short form where the long one does not fit, cut at its start if even that is too
    /// long, so the time is never what goes on a narrow iPhone (L1). Each line picks its own
    /// form (review D2, N6): a long place no longer turns "30. September 2024 · 14:32" into
    /// "30.09.2024" when the long date fits; the first line has a short form only when it is
    /// an older day (a place has none).
    @Test func eachLineOfTheTitlePicksItsOwnForm() throws {
        let bar = AppSource.code(try Self.file("PhotoTitleBar.swift"))
        #expect(Self.count(#"ViewThatFits\("#, in: bar) == 2)
        let body = try #require(AppSource.body(of: "var body: some View", in: bar))
        #expect(!body.contains("ViewThatFits("), "both lines pick their form together")
        let first = try #require(body.range(of: "titleLine"))
        let second = try #require(body.range(of: "subtitleLine"))
        #expect(first.upperBound < second.lowerBound)
        for (line, guarded, long, short) in [
            ("private var titleLine", "if title.shortTitle != title.title {", "heading(title.title)", "heading(title.shortTitle)"),
            ("private var subtitleLine", "if title.shortSubtitle != title.subtitle {", "line(title.subtitle)", "line(title.shortSubtitle)"),
        ] {
            let code = try #require(AppSource.body(of: line, in: bar), "\(line) is missing")
            let condition = try #require(code.range(of: guarded), "\(line) picks a form it does not have")
            let fits = try #require(code.range(of: "ViewThatFits(in: .horizontal) {", range: condition.upperBound..<code.endIndex))
            let longForm = try #require(code.range(of: long, range: fits.upperBound..<code.endIndex))
            let shortForm = try #require(code.range(of: short, range: longForm.upperBound..<code.endIndex))
            #expect(!code[fits.lowerBound..<shortForm.upperBound].contains(line == "private var titleLine" ? "subtitle" : "title.title"),
                    "\(line) picks with the other line")
        }
        #expect(try #require(AppSource.body(of: "private func line(", in: bar)).contains(".truncationMode(.head)"))
    }

    // MARK: A tap hides everything

    /// A tap hides the bars, the status bar and the home indicator (`ViewerChrome`), a double tap
    /// still zooms (the single tap waits for it), and with VoiceOver or Switch Control the bars
    /// stay and come back.
    @Test func aTapHidesEverythingButNeverForVoiceOver() throws {
        let viewer = AppSource.code(try Self.viewer())
        #expect(viewer.contains("ViewerChrome()"))
        #expect(viewer.contains(".statusBarHidden(!chrome.isShown)"))
        #expect(viewer.contains(".persistentSystemOverlays(chrome.isShown"))
        #expect(viewer.contains("\\.accessibilityVoiceOverEnabled"))
        #expect(viewer.contains("\\.accessibilitySwitchControlEnabled"))
        #expect(!AppSource.calls(of: "chrome.tap(", in: viewer).isEmpty)
        #expect(!AppSource.calls(of: "chrome.assistiveTechnology(", in: viewer).isEmpty)
        let bars = try #require(AppSource.body(of: "private var bars", in: viewer))
        #expect(bars.contains("if chrome.isShown"), "the bars do not hide")
        let toggle = try #require(AppSource.body(of: "private func toggleChrome(", in: viewer))
        #expect(toggle.contains("reduceMotion"), "no calm version with Reduce Motion")
        #expect(viewer.contains("TapGesture(count: 2)"))
        #expect(viewer.contains(".exclusively(before:"), "a double tap would hide the bars too")
        #expect(!viewer.contains("onTapGesture(count: 2)"))
        // Zooming in hides the bars, so no title stands on the zoomed photo (review D, L6).
        #expect(viewer.contains(".onChange(of: scale > 1)"))
        let zoom = try #require(AppSource.body(of: "private func zoomChrome(", in: viewer))
        #expect(zoom.contains("chrome.zoomed(assistive: assistive)"))
        #expect(zoom.contains("reduceMotion"))
        // "Widerrufen" stays for its time when a tap hides the bars; the iCloud note goes (L7).
        let notes = try #require(AppSource.body(of: "private var notes", in: viewer))
        #expect(notes.contains("IgnoreUndoBar()"))
        #expect(notes.contains("if chrome.isShown && shareState == .onlyInICloud"))
        #expect(!notes.contains("if chrome.isShown {"), "the undo bar goes with the bars")
    }

    /// The title never stands on the photo (design rule 1, strict; review D2, N8): while the bars
    /// show, the bar's area shows no photo, also zoomed, after a tap while zoomed and with
    /// VoiceOver or Switch Control (whose bars never go). The photo's own area stays where it is
    /// (`top`, kept while the bars are hidden), so nothing jumps; with the bars hidden a zoomed
    /// photo fills the screen, as in Photos, and the bar's area fades with the bars.
    @Test func theTitleNeverStandsOnThePhoto() throws {
        let viewer = AppSource.code(try Self.viewer())
        let pages = try #require(AppSource.body(of: "private var pages", in: viewer))
        let whole = try #require(pages.range(of: ".ignoresSafeArea()"))
        let masked = try #require(pages.range(of: ".mask { photosArea }"), "the photo passes under the title")
        #expect(whole.upperBound <= masked.lowerBound, "the mask is not the whole screen's")
        let area = try #require(AppSource.body(of: "private var photosArea", in: viewer))
        let band = try #require(area.range(of: "Color.black.opacity(chrome.isShown ? 0 : 1)"))
        let height = try #require(area.range(of: ".frame(height: top)", range: band.upperBound..<area.endIndex))
        _ = try #require(area.range(of: "Color.black", range: height.upperBound..<area.endIndex), "nothing of the photo shows")
        #expect(area.contains(".ignoresSafeArea()"))
        // The bar's height is measured only while the bars show, so the photo never moves.
        #expect(pages.contains("if chrome.isShown { top = measured }"))
        let content = try #require(AppSource.body(of: "private func content(in size: CGSize)", in: viewer))
        #expect(content.contains(".padding(.top, top)"))
    }

    // MARK: Live Photos

    /// A Live Photo moves in Photos' own view, which takes no touch of its own (the photo view's
    /// gestures decide): briefly when it comes into view where motion is welcome, whole on a
    /// long press and from VoiceOver's actions. Its sign stands in the bar, never on the photo.
    @Test func livePhotosMoveWhereMotionIsWelcome() throws {
        let player = AppSource.code(try Self.file("LivePhotoPlayer.swift"))
        #expect(player.contains("UIViewRepresentable"))
        #expect(player.contains("PHLivePhotoView()"))
        #expect(player.contains("isUserInteractionEnabled = false"))
        #expect(player.contains("playbackGestureRecognizer.isEnabled = false"))
        #expect(player.contains("startPlayback(with: .hint)"))
        #expect(player.contains("startPlayback(with: .full)"))
        #expect(player.contains("stopPlayback()"))
        #expect(player.contains("isOtherAudioPlaying"), "a Live Photo's sound would stop the user's music")
        try Self.theSoundMixesWithTheUsers(player)
        // PhotoKit does not promise the main thread for its delegate calls: a hop, not a trap (M4).
        let hop = try #require(AppSource.body(of: "nonisolated private func showOnMain(", in: player))
        #expect(hop.contains("if Thread.isMainThread"))
        #expect(hop.contains("Task { @MainActor in"))
        #expect(Self.count("assumeIsolated", in: player) == 1)
        // The motion at the screen's pixels: it shows only while it plays (L5).
        let loadLive = try #require(AppSource.body(of: "func loadLive(", in: AppSource.code(try Self.viewer())))
        #expect(loadLive.contains("LivePhotoLoader.load("))
        #expect(!loadLive.contains("* 2"))
        let viewer = AppSource.code(try Self.viewer(), keepStrings: true)
        let hint = try #require(viewer.range(of: "LiveMotion.playsHint("), "the short motion plays everywhere")
        let call = String(viewer[hint.lowerBound...].prefix(260))
        #expect(call.contains("reduceMotion"))
        #expect(call.contains("isLowPowerModeEnabled"))
        #expect(call.contains("isVideoAutoplayEnabled"))
        try Self.theLongPressIsUIKits(viewer)
        // The touch that was a press is neither a tap nor a pull down to close.
        for gesture in ["private var taps", "private var pullDown"] {
            let body = try #require(AppSource.body(of: gesture, in: viewer))
            #expect(body.contains("pressedLately"), "\(gesture) acts on a long press")
        }
        #expect(viewer.contains("Button(\"Live Photo abspielen\")"), "VoiceOver cannot play it")
        #expect(viewer.contains(".accessibilityHidden(true)"))
        for path in PhotoViewerSource.paths + ["\(Self.folder)/LivePhotoPlayer.swift"] {
            #expect(!(try AppSource.read(path)).contains("\"livephoto\""), "\(path): a Live Photo sign on the photo")
        }
        #expect(try Self.file("PhotoTitleBar.swift").contains("Image(systemName: \"livephoto\")"))
    }

    /// `livePhotosMoveWhereMotionIsWelcome`: the sound of a Live Photo, prepared when the photo
    /// view opens.
    static func theSoundMixesWithTheUsers(_ player: String) throws {
        // The app's sound mixes with the user's and follows the silent switch (review D, H2).
        // Set when the photo view opens, off the main thread and not where a Live Photo starts
        // to move; kept only once it worked, so a failure is tried again (review D2, N9).
        #expect(player.contains("setCategory(.ambient"))
        let follow = try #require(AppSource.body(of: "func follow(", in: player))
        #expect(!follow.contains("LiveAudio.prepare()"), "the audio server is called where the motion starts")
        let short = try #require(follow.range(of: "case .hint:"))
        let ready = try #require(follow.range(of: "guard LiveAudio.isReady else { return }", range: short.upperBound..<follow.endIndex),
                                 "the short motion may stop the user's music")
        #expect(follow.range(of: "case .full:", range: short.upperBound..<ready.lowerBound) == nil)
        let prepare = try #require(AppSource.body(of: "static func prepare(", in: player))
        let detached = try #require(prepare.range(of: "Task.detached("))
        let set = try #require(prepare.range(of: "setCategory(.ambient", range: detached.upperBound..<prepare.endIndex))
        _ = try #require(prepare.range(of: "await LiveAudio.finished(done)", range: set.upperBound..<prepare.endIndex))
        #expect(!prepare.contains("isReady = true"), "kept before it worked")
        #expect(try #require(AppSource.body(of: "private static func finished(", in: player)).contains("isReady = done"))
        #expect(try #require(AppSource.body(of: "private func opened(", in: AppSource.code(try Self.viewer()))).contains("LiveAudio.prepare()"))
    }

    /// `livePhotosMoveWhereMotionIsWelcome`: the long press that plays a Live Photo, with its rules.
    static func theLongPressIsUIKits(_ viewer: String) throws {
        // The long press is UIKit's, beside the pager's swipe: SwiftUI's long press followed by
        // a drag kept the swipe from the pager on exactly the Live Photo pages (review D, H1).
        #expect(!viewer.contains("LongPressGesture("))
        #expect(!viewer.contains(".sequenced(before:"))
        #expect(AppSource.calls(of: "LivePress(", in: viewer).count == 1)
        let press = AppSource.code(try Self.file("LivePress.swift"))
        #expect(press.contains("struct LivePress: UIGestureRecognizerRepresentable"))
        #expect(press.contains("final class LivePressRecognizer: UILongPressGestureRecognizer, UIGestureRecognizerDelegate"))
        // Each rule in its own place (review D2, N11): made with them, the recognizer its own
        // delegate, one finger to begin, beside every other gesture, and it says both ends.
        let make = try #require(AppSource.body(of: "func makeUIGestureRecognizer(", in: press))
        for rule in ["recognizer.minimumPressDuration = 0.3", "recognizer.numberOfTouchesRequired = 1", "recognizer.delegate = recognizer"] {
            #expect(make.contains(rule), "\(rule) is not where the recognizer is made")
        }
        let begins = try #require(AppSource.body(of: "func gestureRecognizerShouldBegin(", in: press))
        #expect(begins.contains("gestureRecognizer.numberOfTouches == 1"), "two fingers resting for a pinch would play it")
        let beside = try #require(AppSource.body(of: "shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool", in: press))
        #expect(beside.filter { !$0.isWhitespace } == "{true}", "the press would hold the swipe back")
        let handled = try #require(AppSource.body(of: "func handleUIGestureRecognizerAction(", in: press))
        #expect(handled.contains("case .began: onPress(true)"))
        #expect(handled.contains("case .ended, .cancelled, .failed: onPress(false)"))
    }

    /// The long press is the innermost gesture of the photo (review D2, N3): a gesture added
    /// with `.gesture` gives way to those of the view it is added to, so attached after the
    /// taps it would wait for a tap that never fails while a finger rests, and never begin. A
    /// short touch makes it fail and the tap goes on. While it plays a Live Photo, the page
    /// stays still: no paging, no pinch, no moving the zoomed photo (N4), as in Photos.
    @Test func theLongPressComesFirstAndHoldsThePage() throws {
        let source = AppSource.code(try Self.viewer(), keepStrings: true)
        let content = try #require(AppSource.body(of: "private func content(in size: CGSize)", in: source))
        var last = content.startIndex
        for step in [".contentShape(Rectangle())", ".gesture(LivePress(isEnabled: live != nil) { began in press(began) })",
                     ".gesture(taps)", ".gesture(magnify)", ".highPriorityGesture(pan,", ".simultaneousGesture(pullDown,"] {
            let found = try #require(content.range(of: step, range: last..<content.endIndex), "\(step) is not in its place")
            last = found.upperBound
        }
        #expect(Self.count(#"\.gesture\(LivePress\("#, in: source) == 1)
        // A pinch that waits for the press is not kept waiting: a second finger fails it at once.
        let recognizer = AppSource.code(try Self.file("LivePress.swift"))
        #expect(recognizer.contains("import UIKit.UIGestureRecognizerSubclass"))
        let touches = try #require(AppSource.body(of: "override func touchesBegan(", in: recognizer), "a pinch waits for the press")
        let begun = try #require(touches.range(of: "super.touchesBegan(touches, with: event)"))
        let fails = try #require(touches.range(of: "if numberOfTouches > 1, state == .possible { state = .failed }"))
        #expect(begun.upperBound < fails.lowerBound)
        // The press is told to the photo view, which holds the pager still meanwhile.
        let press = try #require(AppSource.body(of: "private func press(", in: source))
        let began = try #require(press.range(of: "onPressing(true)"))
        let ended = try #require(press.range(of: "onPressing(false)"))
        #expect(began.lowerBound < ended.lowerBound)
        let pages = try #require(AppSource.body(of: "private var pages", in: source))
        let tabs = try #require(pages.range(of: "TabView(selection: $current)"))
        let still = try #require(pages.range(of: ".scrollDisabled(pressing != nil)"), "the page slides away under a press")
        #expect(tabs.upperBound < still.lowerBound)
        let held = try #require(AppSource.body(of: "private func livePress(", in: source))
        #expect(held.contains("pressing = id"))
        #expect(held.contains("pressing == id"), "another page's end frees the pager")
        #expect(AppSource.calls(of: "ZoomablePhoto(", in: source).allSatisfy { $0.contains("onPressing: { livePress(id, $0) }") })
        // A page that goes while pressed ends its press, so the pager is never held for good.
        let photo = try #require(AppSource.body(of: "struct ZoomablePhoto", in: source))
        let gone = try #require(AppSource.body(of: ".onDisappear", in: photo))
        #expect(gone.contains("if pressing { press(false) }"))
        // No pinch and no moving the zoomed photo while the press plays.
        for gesture in ["private var magnify", "private var pan"] {
            let body = try #require(AppSource.body(of: gesture, in: source))
            let changed = try #require(body.range(of: ".onChanged { value in"), "\(gesture)")
            #expect(String(body[changed.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("guard !pressing else { return }"), "\(gesture) moves the photo under a press")
        }
    }
}
