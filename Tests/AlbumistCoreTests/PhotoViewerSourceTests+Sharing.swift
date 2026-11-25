import Foundation
import Testing
import AlbumistTestSupport

/// Sharing from the photo view, what stays, and its words (`PhotoViewerSourceTests`).
extension PhotoViewerSourceTests {
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
        let thumbnails = AppSource.code(try ThumbnailSource.read())
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
        for part in ["var pager", "private var pages"] {
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
        let leave = try #require(AppSource.body(of: "func leaveShare(", in: viewer))
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
        let thumbnails = AppSource.code(try ThumbnailSource.read())
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
        for path in [["struct PhotoViewer", "var body: some View"], ["struct ZoomablePhoto", "var body: some View"]] {
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
            // The photo view's own alert for a failed share (review D2, N1).
            "Das hat nicht geklappt": "That Didn\u{2019}t Work",
            "OK": "OK",
        ]
        for (german, wanted) in english {
            let entry = try #require(catalog[german], "\(german) is not in the catalog")
            let value = (StringCatalogTests.localization(entry, "en")?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(value == wanted, "\(german): \(value ?? "no English")")
        }
    }
}
