import Foundation
import Testing
import AlbumistTestSupport

/// The photo view's app code (design wave 2, DS-10), read from the source (the app does not
/// build on Linux): date and place as the title, sharing only what is on the iPhone, a tap hides
/// everything but never leaves VoiceOver or Switch Control without controls, Live Photos move
/// where motion is welcome, and everything the viewer did before stays.
@Suite("Photo view source (DS-10)")
struct PhotoViewerSourceTests {
    static let viewerPath = "App/Albumist/Views/PhotoViewer.swift"
    static let folder = "App/Albumist/Views/PhotoViewer"

    static func viewer() throws -> String { try AppSource.read(viewerPath) }
    static func file(_ name: String) throws -> String { try AppSource.read("\(folder)/\(name)") }

    /// The code of `path` with comments and strings blanked.
    static func code(_ path: String) throws -> String { AppSource.code(try AppSource.read(path)) }

    /// The files that load photos for the photo view.
    static var loadingFiles: [String] {
        [viewerPath, "App/Albumist/Views/AssetThumbnail.swift"] + AppSource.swiftFiles(under: folder)
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
        for (line, guarded, long, short) in [("private var titleLine", "if title.shortTitle != title.title {", "heading(title.title)", "heading(title.shortTitle)"),
                                             ("private var subtitleLine", "if title.shortSubtitle != title.subtitle {", "line(title.subtitle)", "line(title.shortSubtitle)")] {
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
        // PhotoKit does not promise the main thread for its delegate calls: a hop, not a trap (M4).
        let hop = try #require(AppSource.body(of: "nonisolated private func showOnMain(", in: player))
        #expect(hop.contains("if Thread.isMainThread"))
        #expect(hop.contains("Task { @MainActor in"))
        #expect(Self.count("assumeIsolated", in: player) == 1)
        // The motion at the screen's pixels: it shows only while it plays (L5).
        let loadLive = try #require(AppSource.body(of: "private func loadLive(", in: AppSource.code(try Self.viewer())))
        #expect(loadLive.contains("LivePhotoLoader.load("))
        #expect(!loadLive.contains("* 2"))
        let viewer = AppSource.code(try Self.viewer(), keepStrings: true)
        let hint = try #require(viewer.range(of: "LiveMotion.playsHint("), "the short motion plays everywhere")
        let call = String(viewer[hint.lowerBound...].prefix(260))
        #expect(call.contains("reduceMotion"))
        #expect(call.contains("isLowPowerModeEnabled"))
        #expect(call.contains("isVideoAutoplayEnabled"))
        // The long press is UIKit's, beside the pager's swipe: SwiftUI's long press followed by
        // a drag kept the swipe from the pager on exactly the Live Photo pages (review D, H1).
        #expect(!viewer.contains("LongPressGesture("))
        #expect(!viewer.contains(".sequenced(before:"))
        #expect(AppSource.calls(of: "LivePress(", in: viewer).count == 1)
        let press = AppSource.code(try Self.file("LivePress.swift"))
        #expect(press.contains("UIGestureRecognizerRepresentable"))
        #expect(press.contains("UILongPressGestureRecognizer"))
        #expect(press.contains("minimumPressDuration = 0.3"))
        #expect(press.contains("numberOfTouches == 1"), "two fingers resting for a pinch would play it")
        #expect(press.contains("shouldRecognizeSimultaneouslyWith"), "the press would hold the swipe back")
        #expect(press.contains("case .began"))
        #expect(press.contains("case .ended, .cancelled, .failed"))
        // The touch that was a press is neither a tap nor a pull down to close.
        for gesture in ["private var taps", "private var pullDown"] {
            let body = try #require(AppSource.body(of: gesture, in: viewer))
            #expect(body.contains("pressedLately"), "\(gesture) acts on a long press")
        }
        #expect(viewer.contains("Button(\"Live Photo abspielen\")"), "VoiceOver cannot play it")
        #expect(viewer.contains(".accessibilityHidden(true)"))
        for path in [Self.viewerPath, "\(Self.folder)/LivePhotoPlayer.swift"] {
            #expect(!(try AppSource.read(path)).contains("\"livephoto\""), "\(path): a Live Photo sign on the photo")
        }
        #expect(try Self.file("PhotoTitleBar.swift").contains("Image(systemName: \"livephoto\")"))
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
        let photo = try #require(AppSource.body(of: "private struct ZoomablePhoto", in: source))
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

    // MARK: Sharing

    /// The share button shares the photo's file as Photos hands it out (the edited one, else the
    /// original), from a temporary file with the photo's own name that goes when the share sheet
    /// closes; "Bild sichern" and "Zu geteiltem Album hinzufügen" would copy the photo into the
    /// library or into iCloud and are not offered. Off with a reason where only a preview is on
    /// the iPhone; no answer from Photos is no verdict (review D: M3, M5, M6, L4, L8, L9).
    @Test func sharingUsesOnlyWhatIsOnTheIPhone() throws {
        let share = AppSource.code(try Self.file("PhotoShare.swift"))
        #expect(share.contains("UIActivityViewController("))
        #expect(share.contains("excludedActivityTypes = [.saveToCameraRoll, UIActivity.ActivityType(rawValue:"))
        #expect(AppSource.code(try Self.file("PhotoShare.swift"), keepStrings: true)
            .contains("\"com.apple.mobileslideshow.StreamShareService\""))
        let done = try #require(share.range(of: "completionWithItemsHandler"))
        #expect(share[done.lowerBound...].prefix(120).contains("remove("), "the shared file stays behind")
        #expect(share.contains("temporaryDirectory"))
        #expect(share.contains("SharedPhotoFile.name("))
        // The file Photos would hand out, and only for a still image.
        #expect(share.contains("$0.type == .fullSizePhoto"))
        #expect(share.contains("$0.type == .photo"))
        #expect(share.contains("mediaType == .image"))
        // Its first bytes say whether it is on the iPhone, and the reading stops there.
        let check = try #require(AppSource.body(of: "private static func firstBytes(", in: share))
        #expect(check.contains("requestData("))
        #expect(check.contains("finish(.onDevice, stop: true)"))
        // Only Photos' "network access required" says "only in iCloud"; any other error is
        // unknown (review D2, N5), by the core's rule, with the errors under the error too.
        let ended = try #require(check.range(of: "} completionHandler: { error in"))
        #expect(String(check[ended.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("answer.finish(ShareAvailability.afterReading(errors: errorChain(of: error)))"))
        #expect(!check.contains(".onlyInICloud"), "an error read as only in iCloud by itself")
        let chain = try #require(AppSource.body(of: "static func errorChain(", in: share))
        #expect(chain.contains("NSUnderlyingErrorKey"))
        // The core's numbers are PhotoKit's (checked on every debug run of the app).
        #expect(check.contains("PHPhotosError.errorDomain == ShareAvailability.photosErrorDomain"))
        #expect(check.contains("PHPhotosError.Code.networkAccessRequired.rawValue == ShareAvailability.networkAccessRequired"))
        #expect(try Self.file("PhotoKitAnswer.swift").contains("cancelDataRequest("))
        // The share checks first, then Photos copies the file, readable only while it is open.
        let write = try #require(AppSource.body(of: "private static func write(", in: share))
        #expect(write.contains("firstBytes("), "shared without knowing it is on the iPhone")
        #expect(write.contains("FileProtectionType.completeUnlessOpen"))
        // No answer from Photos is no verdict.
        let prepare = try #require(AppSource.body(of: "static func prepare(", in: share))
        #expect(prepare.contains("case .noAnswer: return .unavailable(.unknown)"))
        let thumbnails = AppSource.code(try AppSource.read("App/Albumist/Views/AssetThumbnail.swift"))
        #expect(thumbnails.contains("func assetLookup(for id: AssetID) async -> AssetLookup"))
        // Leftovers go at launch too, and never the folder of the sheet on screen.
        let app = AppSource.code(try AppSource.read("App/Albumist/App/AlbumistApp.swift"))
        #expect(try #require(AppSource.body(of: "init()", in: app)).contains("PhotoShare.removeLeftovers()"))
        #expect(try #require(AppSource.body(of: "static func removeLeftovers(", in: share)).contains("onScreen"))
        #expect(try #require(AppSource.body(of: "static func present(", in: share)).contains("onScreen = folder"))

        let viewer = AppSource.code(try Self.viewer(), keepStrings: true)
        #expect(viewer.contains("Label(\"Teilen\", systemImage: \"square.and.arrow.up\")"))
        #expect(viewer.contains("\"viewer.share\""))
        #expect(viewer.contains(".disabled(!shareState.canShare"))
        #expect(viewer.contains(".accessibilityHint("))
        #expect(viewer.contains("Das ganze Foto liegt nur in iCloud. Teilen kannst du es in der Fotos-App."))
        // Only still images, by Photos' own kind once known.
        #expect(try #require(AppSource.body(of: "private var shareButton", in: viewer)).contains("if isImage"))
        #expect(try #require(AppSource.body(of: "private var isImage", in: viewer)).contains("basics[current]"))
        // Only a verdict is kept; leftovers go when the view opens and closes.
        #expect(try #require(AppSource.body(of: "private func checkSharing(", in: viewer)).contains("found != .unknown"))
        #expect(try #require(AppSource.body(of: "private func opened(", in: viewer)).contains("PhotoShare.removeLeftovers()"))
        #expect(try #require(AppSource.body(of: "private func closed(", in: viewer)).contains("PhotoShare.removeLeftovers()"))
    }

    /// The share being prepared belongs to the photo on screen (`SharePreparation`, review D2,
    /// N7): a swipe, the details or closing the view leave it, and only its end for the photo
    /// still on screen shows the sheet or says that it failed; a file not shown is removed. The
    /// failure is said by the photo view itself, on its root (N1): the app's alert
    /// (`model.message`, on `RootView`) cannot show over the full-screen photo view and came up
    /// after it had closed.
    @Test func aShareIsForThePhotoOnScreenAndSaysItsFailureItself() throws {
        let source = try Self.viewer()
        let viewer = AppSource.code(source, keepStrings: true)
        #expect(!AppSource.code(source).contains("model.message"), "the photo view uses the app's alert")
        func position(_ text: String, in body: String, after: String.Index? = nil) throws -> String.Index {
            let range = try #require(body.range(of: text, range: (after ?? body.startIndex)..<body.endIndex), "\(text) not found in place")
            return range.lowerBound
        }
        // On the photo view's root, after the navigation root, not inside the pages.
        let body = try #require(AppSource.body(of: ["struct PhotoViewer", "var body: some View"], in: viewer))
        let root = try position("NavigationRoot { pager }", in: body)
        let alert = try position(".alert(\"Das hat nicht geklappt\", isPresented: shareFailed)", in: body, after: root)
        _ = try position("Button(\"OK\", role: .cancel) {}", in: body, after: alert)
        _ = try position("Text(\"Das Foto konnte nicht zum Teilen vorbereitet werden. Versuch es gleich noch einmal.\")", in: body, after: alert)
        for part in ["private var pager", "private var pages"] {
            #expect(!(try #require(AppSource.body(of: part, in: viewer))).contains(".alert("), "\(part) has the alert")
        }
        let failed = try #require(AppSource.body(of: "private var shareFailed", in: viewer))
        #expect(failed.contains("get: { preparation.failed }"))
        #expect(failed.contains("preparation.failureSeen()"))
        // The share: begun for the photo on screen, ended by the core's rule.
        let share = try #require(AppSource.body(of: "private func share(", in: viewer))
        let begun = try position("guard let ticket = preparation.begin(current) else { return }", in: share)
        let prepared = try position("await PhotoShare.prepare(ticket.photo", in: share, after: begun)
        let ended = try position("switch preparation.end(ticket, with: prepared.result, onScreen: current)", in: share, after: prepared)
        let shown = try position("case .present:", in: share, after: ended)
        _ = try position("PhotoShare.present(file)", in: share, after: shown)
        let discarded = try position("case .discard:", in: share, after: ended)
        _ = try position("PhotoShare.remove(file.deletingLastPathComponent())", in: share, after: discarded)
        let kept = try position("case .remember(let reason):", in: share, after: ended)
        _ = try position("sharing[ticket.photo] = reason", in: share, after: kept)
        #expect(viewer.contains(".disabled(!shareState.canShare || preparation.isPreparing)"))
        // Left on a swipe, when the details open and when the view closes.
        let leave = try #require(AppSource.body(of: "private func leaveShare(", in: viewer))
        #expect(leave.contains("preparation.leave()"))
        #expect(leave.contains("shareTask?.cancel()"))
        #expect(try #require(AppSource.body(of: ".onChange(of: current)", in: viewer)).contains("leaveShare()"))
        let info = try #require(AppSource.body(of: "private var infoButton", in: viewer))
        _ = try position("info = facts", in: info, after: try position("leaveShare()", in: info))
        #expect(try #require(AppSource.body(of: "private func closed(", in: viewer)).contains("leaveShare()"))
        // No answer, or no file written, is a failure; Photos' verdicts are kept.
        let result = try #require(AppSource.body(of: "var result: SharePreparation.Result", in: AppSource.code(try Self.file("PhotoShare.swift"))))
        #expect(result.contains("case .file: .file"))
        #expect(result.contains("case .unavailable(let reason): reason.canShare ? .failed : .unavailable(reason)"))
    }

    // MARK: What stays

    /// Everything the photo view did stays: the pages built around the photo, zoom, VoiceOver's
    /// zoom, pull down to close, the close and "i" buttons, ignoring with "Widerrufen", the
    /// details and "Zu Album hinzufügen", the callers' initializer and the honest loading states.
    @Test func whatTheViewerDidStays() throws {
        let viewer = AppSource.code(try Self.viewer(), keepStrings: true)
        for kept in ["PageWindow(around:", "window.following(", "MagnifyGesture()", ".accessibilityZoomAction",
                     "\"viewer.close\"", "\"viewer.info\"", "IgnoreUndoBar()", ".accessibilityAction(.escape)",
                     "AssetDetailView(facts:", "AddToAlbumSheet(assets:", "init(ids: [AssetID], current: AssetID, showsInfo: Bool = false)",
                     "Text(\"Foto wird geladen\")", "\"viewer.unavailable\"", "ThumbnailCache.shared.largeImage(for:",
                     "DragGesture(minimumDistance: 20)", "onClose()", ".tabViewStyle(.page(indexDisplayMode: .never))"] {
            #expect(viewer.contains(kept), "\(kept) is gone")
        }
        let thumbnails = AppSource.code(try AppSource.read("App/Albumist/Views/AssetThumbnail.swift"))
        for kept in ["func image(for id: AssetID, side: CGFloat) async -> UIImage?",
                     "func cover(for id: AssetID, pixels: CGSize) async -> CoverFetch",
                     "func largeImage(for id: AssetID, pixels: CGSize) async -> UIImage?"] {
            #expect(thumbnails.contains(kept), "\(kept) changed")
        }
        let asset = try #require(AppSource.body(of: "func asset(for id: AssetID) async -> ThumbnailRequest.Asset?", in: thumbnails))
        #expect(asset.contains("photoAsset(for: id)"), "a second way to look up photos")
    }

    /// Xcode's type checker gave up on one long SwiftUI expression in wave 1 ("failed to produce
    /// diagnostic for expression"): the photo view's bodies stay short, their pieces are typed
    /// properties of their own.
    @Test func theBodiesStayShort() throws {
        let viewer = try Self.viewer()
        for path in [["struct PhotoViewer", "var body: some View"], ["private struct ZoomablePhoto", "var body: some View"]] {
            let body = try #require(AppSource.body(of: path, in: viewer), "\(path) not found")
            let lines = body.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(lines.count <= 16, "\(path.joined(separator: " ")) has \(lines.count) lines")
        }
    }

    // MARK: Words

    /// The photo view's new words are in the catalog with their English.
    @Test func theNewWordsAreTranslated() throws {
        let catalog = try StringCatalogTests.catalog()
        let english = [
            "Live Photo abspielen": "Play Live Photo",
            "Das ganze Foto liegt nur in iCloud. Teilen kannst du es in der Fotos-App.":
                "The full photo is only in iCloud. You can share it from the Photos app.",
            "Teilen": "Share",
            "Das Foto konnte nicht zum Teilen vorbereitet werden. Versuch es gleich noch einmal.":
                "The photo could not be prepared for sharing. Please try again in a moment.",
        ]
        for (german, wanted) in english {
            let entry = try #require(catalog[german], "\(german) is not in the catalog")
            let value = (StringCatalogTests.localization(entry, "en")?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(value == wanted, "\(german): \(value ?? "no English")")
        }
    }
}
