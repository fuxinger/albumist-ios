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
        #expect(title.contains("PhotoTitle(facts: factsByID[id], photoDate: photoDate"))
        #expect(title.contains("words: proposalWords"))
        #expect(title.contains("currentZone: .current"))
        #expect(title.contains("clock: clock"))
        // Without facts, the date Photos keeps for the photo (review D, M7).
        let calls = AppSource.calls(of: "model.photoTitle(", in: viewer)
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0.contains("photoDate: basics[id]?.date") && $0.contains("clock: clock") })
        let basics = AppSource.code(try Self.file("PhotoBasics.swift"))
        #expect(basics.contains("creationDate"))
        #expect(basics.contains("ThumbnailCache.shared.asset(for:"))
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
        // The short form where the long one does not fit, cut at its start if even that is too
        // long, so the time is never what goes on a narrow iPhone (L1).
        #expect(bar.contains("ViewThatFits(in: .horizontal)"))
        #expect(bar.contains("title.shortTitle, title.shortSubtitle"))
        #expect(bar.contains(".truncationMode(.head)"))
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
        // The app's sound mixes with the user's and follows the silent switch, set once before
        // the first Live Photo plays (review D, H2).
        #expect(player.contains("setCategory(.ambient"))
        let follow = try #require(AppSource.body(of: "func follow(", in: player))
        #expect(follow.contains("LiveAudio.prepare()"))
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
        // A failed share is said, not remembered; a file not shown is removed.
        let sharing = try #require(AppSource.body(of: "private func share(", in: viewer))
        #expect(sharing.contains("case .unavailable(.unknown):"))
        #expect(sharing.contains("model.message = .failure("))
        #expect(sharing.contains("Das Foto konnte nicht zum Teilen vorbereitet werden. Versuch es gleich noch einmal."))
        #expect(sharing.contains("PhotoShare.remove(file.deletingLastPathComponent())"))
        #expect(try #require(AppSource.body(of: "private func checkSharing(", in: viewer)).contains("found != .unknown"))
        let appear = try #require(AppSource.body(of: ".onAppear", in: viewer))
        let disappear = try #require(AppSource.body(of: ".onDisappear", in: viewer))
        #expect(appear.contains("PhotoShare.removeLeftovers()"))
        #expect(disappear.contains("PhotoShare.removeLeftovers()"))
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
