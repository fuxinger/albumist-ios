import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The thumbnails: their calm ground, their size, the videos' length (SwiftLint's file length).
extension VideoViewerSourceTests {
    // MARK: Thumbnails

    /// A thumbnail waits on a soft tinted ground (the covers' family, `ThumbnailGroundTint`),
    /// never the flat grey of before; its photo fades in only after a wait (`ThumbnailAppearance`)
    /// and is there at once from memory, so a rebuilt cell never flickers. Hidden previews keep
    /// their neutral ground (design rule 9).
    @Test func thumbnailsWaitOnACalmGround() throws {
        let thumbnails = try Self.thumbnails(keepStrings: true)
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains("ThumbnailGround()"))
        #expect(!shown.contains("tertiarySystemFill"))
        #expect(shown.contains(".transition(.opacity)"))
        let show = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func show("], in: thumbnails))
        #expect(show.contains("ThumbnailAppearance.fade(seeded: seeded, waited:"))
        #expect(show.contains("withAnimation(fade.map { Animation.easeOut(duration: $0) })"))
        let ground = try #require(AppSource.body(of: ["struct ThumbnailGround", "var body: some View"], in: thumbnails))
        #expect(ground.contains("ThumbnailGroundTint(dark: scheme == .dark, increasedContrast: contrast == .increased)"))
        #expect(ground.contains("Theme.card"))
        #expect(ground.contains("Theme.accent.opacity(tint.top)") && ground.contains("Theme.accent.opacity(tint.bottom)"))
        #expect(!ground.contains("tertiarySystemFill"))
        // A cover with no photo yet (an empty album) waits on the same ground; a hidden one stays neutral.
        let cover = try #require(AppSource.body(of: ["struct CoverThumbnail", "var body: some View"], in: thumbnails))
        #expect(Self.squeezed(cover).contains("ifhidden{HiddenThumbnail()}else{ThumbnailGround()"))
        let hidden = try #require(AppSource.body(of: ["struct HiddenThumbnail", "var body: some View"], in: thumbnails))
        #expect(hidden.contains("tertiarySystemFill") && hidden.contains("\"eye.slash\""))
    }

    /// A thumbnail is asked for again when its cell is drawn at another size (a grid zoomed to
    /// other columns, H10's DS-06b): the task follows the id and the side, and the image it shows
    /// meanwhile stays (no flash of the ground).
    @Test func aThumbnailIsAskedForAtTheSizeItShows() throws {
        let thumbnails = try Self.thumbnails()
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains(".task(id: Slot(id: id, side: side)) {"))
        #expect(shown.contains("let seeded = image != nil && loadedID == id"))
        let slot = try #require(AppSource.body(of: ["struct AssetThumbnail", "private struct Slot"], in: thumbnails))
        #expect(Self.squeezed(slot) == "{varid:AssetIDvarside:CGFloat}")
        // A request at the new side that brings nothing keeps the photo the cell shows: the
        // ground would stand where the photo was (review F, note on `show`).
        let show = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func show("], in: thumbnails))
        #expect(Self.inOrder(["if loaded == nil, image != nil, loadedID == id { return }", "withAnimation(", "image = loaded"], in: show),
                "\(show)")
    }

    /// A video's thumbnail says how long it is, "0:15" on a small solid light ground in its
    /// bottom-leading corner (design rule 1; the grids' selection ring is bottom-trailing), only
    /// where it fits, and VoiceOver hears "Video, 15 Sekunden" with the photo's cell. The length
    /// comes from the asset the thumbnails' lookup fetches anyway: no fetch per cell (100,000
    /// photos in a grid). Covers and the mosaic of a card leave it out.
    @Test func aVideosLengthCostsNoFetch() throws {
        let thumbnails = try Self.thumbnails(keepStrings: true)
        #expect(Self.count(#"PHAsset\.fetchAssets\("#, in: thumbnails) == 1, "a second fetch")
        let lookUp = try #require(AppSource.body(of: "private func lookUpWaiting(", in: thumbnails))
        #expect(lookUp.contains("remember(asset, for: id, at: now)"))
        let remember = try #require(AppSource.body(of: "private func remember(", in: thumbnails))
        #expect(Self.inOrder(["assets.setObject(asset.value, forKey: id as NSString)", "asset.value.mediaType == .video",
                              "videoLengths[id] = asset.value.duration"], in: remember), "\(remember)")
        let length = try #require(AppSource.body(of: "func videoLength(for id: AssetID) -> VideoDuration?", in: thumbnails))
        #expect(!length.contains("await") && length.contains("videoLengths[id.rawValue]"))
        // The records keep what was looked at last: past their limit the older half goes, not
        // all (review F, F14). Where a record went, the length comes from the asset still in
        // memory: a thumbnail from the image cache passes no lookup that would write it again.
        #expect(thumbnails.contains("private var videoLengths = RecentRecords<Double>(limit: ThumbnailCache.recordLimit)"))
        #expect(thumbnails.contains("private var keptSides = RecentRecords<CGFloat>(limit: ThumbnailCache.recordLimit)"))
        for owner in ["private func keep(", "private func lookUpWaiting(", "private func lookUpAsset(", "private func remember("] {
            let body = try #require(AppSource.body(of: owner, in: thumbnails))
            #expect(!body.contains("removeAll()"), "\(owner): the records emptied whole")
        }
        #expect(Self.inOrder(["if let seconds = videoLengths[id.rawValue]", "assets.object(forKey: id.rawValue as NSString)",
                              "asset.mediaType == .video", "VideoDuration(seconds: asset.duration)"], in: length), "\(length)")
        // Gone with the assets on a memory warning.
        let start = try #require(AppSource.body(of: ["final class ThumbnailCache", "init()"], in: thumbnails))
        #expect(start.contains("$0.videoLengths.removeAll()") && start.contains("$0.keptSides.removeAll()"))
        // Read with the thumbnail, from memory, in the initializer and when the photo came.
        let made = try #require(AppSource.body(of: ["struct AssetThumbnail", "init(id: AssetID, side: CGFloat = 80, anchor: Alignment = .center)"],
                                               in: thumbnails))
        #expect(Self.squeezed(made).contains("_video=State(initialValue:kept==nil?nil:ThumbnailCache.shared.videoLength(for:id))"))
        let show = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func show("], in: thumbnails))
        #expect(show.contains("video = ThumbnailCache.shared.videoLength(for: id)"))
        // The badge: solid light ground, one line, stops growing, hidden from VoiceOver itself.
        let badge = try #require(AppSource.body(of: ["struct VideoLengthBadge", "var body: some View"], in: thumbnails))
        for part in ["Text(verbatim: length.text)", ".monospacedDigit()", ".lineLimit(1)", ".background(Color.white, in: Capsule())",
                     ".environment(\\.colorScheme, .light)", ".dynamicTypeSize(...DynamicTypeSize.accessibility1)", ".accessibilityHidden(true)"] {
            #expect(badge.contains(part), "\(part) is missing")
        }
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains(".overlay(alignment: .bottomLeading) {"))
        #expect(thumbnails.contains("VideoBadge.fits(badgeWidth:"))
        // VoiceOver: the value of the cell around it; without a video nothing of the thumbnail.
        #expect(shown.contains(".accessibilityValue(spokenLength.map { Text(verbatim: $0) } ?? Text(verbatim: \"\"))"))
        #expect(shown.contains(".accessibilityHidden(spokenLength == nil)"))
        let spoken = try #require(AppSource.body(of: ["struct AssetThumbnail", "private var spokenLength"], in: thumbnails))
        #expect(spoken.contains("showsVideoLength"))
        // Covers and the mosaic leave it out.
        for owner in ["struct CoverThumbnail", "struct ThumbnailGrid"] {
            let body = try #require(AppSource.body(of: [owner, "var body: some View"], in: thumbnails))
            #expect(body.contains(".environment(\\.thumbnailShowsVideoLength, false)"), "\(owner)")
        }
    }

    /// A video trimmed in Photos: the length on its thumbnail follows (review F, F14 c). The
    /// assets kept in memory are snapshots; on a change in Photos each kept video the change
    /// touched gets its new asset and length, or loses both when it was deleted, worked out on
    /// the lookups' queue (a change's details may read the Photos database). Nothing else goes:
    /// emptied on each change, the grids lost their badges and the photo view its waiting
    /// thumbnail, and Albumist's own albums alone are many changes (they change no photo).
    @Test func aVideosLengthFollowsAChangeInPhotos() throws {
        // Albumist's own albums change no photo: a change during a plan is not kept for the walk
        // (when and how often it runs: `changesInPhotosAreWalkedTogetherInTheirOrder`).
        let watcher = try Self.code("App/Albumist/Platform/LibraryChangeWatcher.swift")
        let changed = try #require(AppSource.body(of: "private func changed(_ change: ThumbnailRequest.Change)", in: watcher))
        #expect(changed.contains("if !AppModel.shared.execution.isRunning { ThumbnailCache.shared.changeArrived(change) }"), "\(changed)")
        let thumbnails = try Self.thumbnails()
        let refresh = try #require(AppSource.body(of: "private func libraryChanged(_ changes: [ThumbnailRequest.Change]) async", in: thumbnails))
        #expect(Self.inOrder(["for key in videoLengths.keys", "assets.object(forKey: key as NSString)",
                              "await ThumbnailRequest.changed(kept, by: changes)",
                              "if case .changed(let asset) = answer { assets.setObject(asset.value, forKey: key as NSString) }"],
                             in: refresh), "\(refresh)")
        // Each record as the core's rule says (`aTrimmedVideosCellOnScreenShowsItsNewLength`).
        #expect(!refresh.contains("removeAll"), "the records emptied on every change")
        let details = try #require(AppSource.body(of: "nonisolated static func changed(", in: thumbnails))
        #expect(Self.inOrder(["lookups.async {", "change.value.changeDetails(for: current)", "objectWasDeleted",
                              "objectAfterChanges"], in: details), "\(details)")
    }

    /// The walk over the kept video records for changes in Photos is coalesced (review V11): the
    /// changes reach the main actor in the order Photos told them (its own serial queue, then the
    /// main queue, first in first out) and wait (`ChangeBacklog`); the watcher's debounced task
    /// walks all of them at once, one walk at a time (at once when many wait), never once per
    /// change, and not at all without a video record. Within a walk the changes count in their
    /// order: the last one that touched a video decides, and a deletion is final.
    @Test func changesInPhotosAreWalkedTogetherInTheirOrder() throws {
        let watcher = try Self.code("App/Albumist/Platform/LibraryChangeWatcher.swift")
        let told = try #require(AppSource.body(of: "nonisolated func photoLibraryDidChange(", in: watcher))
        #expect(Self.inOrder(["let change = ThumbnailRequest.Change(changeInstance)", "DispatchQueue.main.async {",
                              "MainActor.assumeIsolated {", "LibraryChangeWatcher.shared.changed(change)"], in: told), "\(told)")
        #expect(!told.contains("libraryChanged"), "a walk per change")
        let changed = try #require(AppSource.body(of: "private func changed(_ change: ThumbnailRequest.Change)", in: watcher))
        #expect(Self.inOrder(["if !AppModel.shared.execution.isRunning { ThumbnailCache.shared.changeArrived(change) }",
                              "scheduleCatchUp()"], in: changed), "\(changed)")
        let debounced = try #require(AppSource.body(of: "private func scheduleCatchUpNow(", in: watcher))
        #expect(Self.inOrder(["pending = Task {", "try? await Task.sleep(for: .seconds(delay))", "guard !Task.isCancelled else { return }",
                              "ThumbnailCache.shared.followChanges()", "if model.analysis.isRunning {"], in: debounced), "\(debounced)")
        let thumbnails = try Self.thumbnails()
        #expect(thumbnails.contains("private var backlog = ChangeBacklog<ThumbnailRequest.Change>(limit: ThumbnailCache.changeLimit)"))
        let arrived = try #require(AppSource.body(of: "func changeArrived(_ change: ThumbnailRequest.Change)", in: thumbnails))
        #expect(Self.squeezed(arrived) == "{ifbacklog.arrived(change){followChanges()}}", "\(arrived)")
        let follow = try #require(AppSource.body(of: "func followChanges()", in: thumbnails))
        #expect(Self.inOrder(["guard let waiting = backlog.take(recordsKept: videoLengths.count > 0 || recordsWentUnchecked) else { return }",
                              "Task {",
                              "await libraryChanged(waiting)", "if backlog.walked() { followChanges() }"], in: follow), "\(follow)")
        let refresh = try #require(AppSource.body(of: "private func libraryChanged(_ changes: [ThumbnailRequest.Change]) async", in: thumbnails))
        #expect(refresh.contains("await ThumbnailRequest.changed(kept, by: changes)"), "\(refresh)")
        let details = try #require(AppSource.body(of: "nonisolated static func changed(", in: thumbnails))
        #expect(Self.inOrder(["lookups.async {", "for (key, asset) in kept {", "var current = asset.value", "for change in changes {",
                              "change.value.changeDetails(for: current)", "objectWasDeleted", "found[key] = .deleted", "break",
                              "objectAfterChanges", "current = after", "found[key] = .changed(Asset(after))"], in: details), "\(details)")
    }

    /// A trimmed video's cell on screen shows its new length, on its badge and to VoiceOver,
    /// without being made anew, once the change was walked, some seconds after it (the watcher's
    /// pause; review V4): each record follows the core's rule (`KeptVideoLength`), and a
    /// small observed revision, raised when a length a cell may show changed, makes the cells on
    /// screen read their record again. A record whose asset is no longer in memory cannot be
    /// checked: it goes with the thumbnail kept for it, so the next look asks Photos again (a
    /// thumbnail from memory passes no lookup that would write the record anew).
    @Test func aTrimmedVideosCellOnScreenShowsItsNewLength() throws {
        let thumbnails = try Self.thumbnails()
        let refresh = try #require(AppSource.body(of: "func libraryChanged(", in: thumbnails))
        #expect(Self.inOrder(["for key in videoLengths.keys", "if let asset = assets.object(forKey: key as NSString)",
                              "kept[key] = ThumbnailRequest.Asset(asset)", "} else if let seconds = videoLengths[key]",
                              "apply(KeptVideoLength.step(kept: seconds, inMemory: false, found: nil), to: key)",
                              "await ThumbnailRequest.changed(kept, by: ", "guard let seconds = videoLengths[key] else { continue }",
                              "assets.setObject(asset.value, forKey: key as NSString)",
                              "apply(KeptVideoLength.step(kept: seconds, inMemory: true, found: answer.lengthFound), to: key)",
                              "if readAgain { lengthRevision.raise() }"], in: refresh), "\(refresh)")
        let apply = try #require(AppSource.body(of: "private func apply(_ step: KeptVideoLength.Step, to key: String) -> Bool", in: thumbnails))
        #expect(Self.inOrder(["case .keep:", "case .update(let seconds, _):", "videoLengths[key] = seconds", "case .drop(let checked):",
                              "videoLengths[key] = nil", "if checked {", "assets.removeObject(forKey: key as NSString)",
                              "} else if let side = keptSides[key] {", "cache.removeObject(forKey: Self.thumbnailKey(AssetID(key), side))",
                              "keptSides[key] = nil", "return step.readsAgain"], in: apply), "\(apply)")
        let found = try #require(AppSource.body(of: "var lengthFound: KeptVideoLength.Found", in: thumbnails))
        #expect(Self.inOrder(["case .changed(let asset): .changed(seconds: asset.value.duration)", "case .deleted: .deleted"], in: found))
        // The revision is observed (the cache is not), raised only by a correction.
        #expect(thumbnails.contains("let lengthRevision = VideoLengthRevision()"))
        #expect(Self.inOrder(["@MainActor", "@Observable", "final class VideoLengthRevision"], in: thumbnails))
        let revision = try #require(AppSource.body(of: "final class VideoLengthRevision", in: thumbnails))
        #expect(revision.contains("private(set) var value = 0") && revision.contains("value &+= 1"), "\(revision)")
        #expect(Self.count(#"lengthRevision\.raise\(\)"#, in: thumbnails) == 1)
        // The cell on screen reads its record again: the badge and VoiceOver's words follow.
        let shown = try #require(AppSource.body(of: ["struct AssetThumbnail", "var body: some View"], in: thumbnails))
        #expect(shown.contains(".onChange(of: ThumbnailCache.shared.lengthRevision.value) { readLengthAgain() }"), "\(shown)")
        let again = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func readLengthAgain("], in: thumbnails))
        #expect(Self.inOrder(["guard loadedID == id", "ThumbnailCache.shared.videoLength(for: id)"], in: again), "\(again)")
    }

    /// A cell on screen never loses its video's length because the thumbnails know nothing of it
    /// (review X2): only a length they know replaces what it shows. Nothing known is not "no
    /// video": after a memory warning, or once a record went unchecked, the records of unchanged
    /// videos are gone too, and every older video cell alive lost its badge and its "Video, …"
    /// for VoiceOver at the next correction, until it was made anew.
    @Test func aCellKeepsItsLengthWhileTheThumbnailsKnowNone() throws {
        let thumbnails = try Self.thumbnails()
        let again = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func readLengthAgain("], in: thumbnails))
        #expect(again.contains("video = known"), "a known length does not replace what the cell shows: \(again)")
        #expect(!again.contains("video = ThumbnailCache.shared.videoLength(for: id)"), "nothing known takes the badge away: \(again)")
        #expect(!again.contains("video = nil"), "\(again)")
    }

    /// A trimmed video's badge follows also when its asset was no longer in memory as the change
    /// was walked (review X1: after a trip to Photos it may be gone, a memory warning takes all).
    /// The walk tells the cells when it dropped a record unchecked (the core's `readsAgain`), and
    /// the first change after a memory warning is walked without a record too, to tell them. A
    /// cell on screen that shows a length the thumbnails no longer know keeps it and asks Photos
    /// again, then shows what Photos said (`KeptVideoLength.reading`, `afterAsking`). The cells
    /// that ask after one revision wait for one lookup together: no task and no lookup per cell,
    /// one fetch for 30 video cells on screen, of Photos' metadata only (no image, no download).
    @Test func aCellOnScreenAsksPhotosAgainForALengthThatWentUnchecked() throws {
        let thumbnails = try Self.thumbnails()
        let start = try #require(AppSource.body(of: ["final class ThumbnailCache", "init()"], in: thumbnails))
        #expect(Self.inOrder(["$0.videoLengths.removeAll()", "$0.recordsWentUnchecked = true"], in: start), "\(start)")
        let follow = try #require(AppSource.body(of: "func followChanges()", in: thumbnails))
        #expect(follow.contains("backlog.take(recordsKept: videoLengths.count > 0 || recordsWentUnchecked)"), "\(follow)")
        let refresh = try #require(AppSource.body(of: "private func libraryChanged(", in: thumbnails))
        #expect(Self.inOrder(["if recordsWentUnchecked {", "recordsWentUnchecked = false", "readAgain = true",
                              "if readAgain { lengthRevision.raise() }"], in: refresh), "\(refresh)")
        // The cell follows the core's rule, and asks through the cache.
        let again = try #require(AppSource.body(of: ["struct AssetThumbnail", "private func readLengthAgain("], in: thumbnails))
        #expect(Self.squeezed(again).contains(
            "switchKeptVideoLength.reading(shown:showsVideoLength?video:nil,known:ThumbnailCache.shared.videoLength(for:id)){"), "\(again)")
        #expect(Self.inOrder(["case .show(let known): video = known", "case .keep: break", "case .askAgain:", "let asked = id",
                              "ThumbnailCache.shared.askLengthAgain(for: asked) { answer in", "guard loadedID == asked else { return }",
                              "video = KeptVideoLength.afterAsking(shown: video, answer: answer)"], in: again), "\(again)")
        for perCell in ["Task {", "Task.detached", "assetLookup(", "lookUp(", "image(for:"] {
            #expect(!again.contains(perCell), "\(perCell): a lookup per cell")
        }
        // One lookup for the cells that ask after one revision: the first ask starts it, the
        // others of the same moment join it before it runs.
        let ask = try #require(AppSource.body(of: "func askLengthAgain(for id: AssetID", in: thumbnails))
        #expect(Self.inOrder(["if lengthAsks.isEmpty { Task { await answerLengthAsks() } }",
                              "lengthAsks[id.rawValue, default: []].append(answered)"], in: ask), "\(ask)")
        #expect(Self.count(#"Task\s*\{"#, in: ask) == 1, "\(ask)")
        let answer = try #require(AppSource.body(of: "private func answerLengthAsks(", in: thumbnails))
        #expect(Self.inOrder(["let asks = lengthAsks", "lengthAsks = [:]", "Self.batchLimit", "await ThumbnailRequest.lookUp(ids)",
                              "remember(asset, for: id, at: now)", "for answered in cells"], in: answer), "\(answer)")
        #expect(Self.count(#"ThumbnailRequest\.lookUp\("#, in: answer) == 1, "\(answer)")
        for request in ["requestImage(", "requestPlayerItem(", "requestAVAsset(", "isNetworkAccessAllowed"] {
            #expect(!answer.contains(request), "\(request): more than Photos' metadata")
        }
        // Kept as the queue's lookups keep what they found; still one fetch in the file.
        let waiting = try #require(AppSource.body(of: "private func lookUpWaiting(", in: thumbnails))
        #expect(waiting.contains("remember(asset, for: id, at: now)"), "\(waiting)")
        #expect(Self.count(#"ThumbnailRequest\.lookUp\("#, in: thumbnails) == 2)
        #expect(Self.count(#"PHAsset\.fetchAssets\("#, in: thumbnails) == 1)
    }
}
