import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AlbumistCore

/// Sharing the photo the photo view shows (design wave 2, DS-10: "Teilen"), with iOS's share
/// sheet. Only what is on the iPhone: the file Photos keeps for the photo, as Photos shares it
/// (the edited version if it was edited, else the original), never loaded from iCloud; Albumist
/// itself sends nothing anywhere, the user picks where it goes. Only still images are shared.
///
/// Whether the file is on the iPhone is asked with its first bytes only (review D, M3: the whole
/// photo was read into memory for this, up to 100 MB for a ProRAW photo). For the share sheet
/// Photos copies the file into a temporary file with the photo's own name (`SharedPhotoFile`),
/// in a folder of its own, without it ever being held in memory. The folder is removed when the
/// share sheet closes; whatever is left over (the app was ended meanwhile) at the next launch
/// and when the photo view opens or closes, but never the folder of the sheet on screen (M5).
/// Nothing else is written and the photo in the library is not touched. "Bild sichern" and "Zu
/// geteiltem Album hinzufügen" are not offered: they would put a second copy of the photo into
/// the library or into iCloud (L8).
enum PhotoShare {
    enum Prepared: Sendable {
        case file(URL)
        /// Why not: only in iCloud, or Photos has nothing to share (the photo is gone, or no
        /// still image). `unknown`: Photos did not answer in time or the file could not be
        /// written; nothing is known, the user is told and may try again (M6).
        case unavailable(ShareAvailability)
    }

    /// Where the files for the share sheet are made, each in a folder of its own.
    static let root = FileManager.default.temporaryDirectory.appending(path: "PhotoShare", directoryHint: .isDirectory)

    /// The folder of the share whose sheet is open: `removeLeftovers` never removes it.
    @MainActor private(set) static var onScreen: URL?

    /// Whether the photo can be shared, without reading it (`firstBytes`). `unknown` while
    /// Photos does not answer (the button stays on, a tap asks again).
    @MainActor
    static func availability(of id: AssetID) async -> ShareAvailability {
        switch await ThumbnailCache.shared.assetLookup(for: id) {
        case .found(let asset): return await check(asset)
        case .unknown: return .unavailable
        case .noAnswer: return .unknown
        }
    }

    /// The photo in a file for the share sheet, or why there is none.
    @MainActor
    static func prepare(_ id: AssetID, fallbackName: String) async -> Prepared {
        switch await ThumbnailCache.shared.assetLookup(for: id) {
        case .found(let asset): return await write(asset, fallbackName: fallbackName)
        case .unknown: return .unavailable(.unavailable)
        case .noAnswer: return .unavailable(.unknown)
        }
    }

    /// The share sheet for `file`, over whatever is on screen (the photo view); the file's
    /// folder goes when the sheet closes.
    @MainActor
    static func present(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        guard let top = topController() else {
            remove(folder)
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.excludedActivityTypes = [.saveToCameraRoll, UIActivity.ActivityType(rawValue: "com.apple.mobileslideshow.StreamShareService")]
        sheet.completionWithItemsHandler = { _, _, _, _ in
            remove(folder)
            Task { @MainActor in closed(folder) }
        }
        if let popover = sheet.popoverPresentationController {
            // On an iPad: from the bar's right end, where the button is.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.maxX - 100, y: top.view.safeAreaInsets.top - 44, width: 44, height: 44)
        }
        onScreen = folder
        top.present(sheet, animated: true)
    }

    /// One share's folder; never anything outside the share folder.
    static func remove(_ folder: URL) {
        guard folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The files of shares that were not cleaned up after (the app was ended while a sheet was
    /// open): at launch and when the photo view opens or closes. Never the folder of the sheet
    /// on screen: a full-screen step of an activity (Markup, Print) may make SwiftUI run the
    /// photo view's onDisappear and onAppear while the sheet is still up (review D, M5).
    @MainActor
    static func removeLeftovers() {
        let kept = onScreen?.lastPathComponent
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent != kept {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The sheet of `folder` closed.
    @MainActor
    private static func closed(_ folder: URL) {
        if onScreen?.lastPathComponent == folder.lastPathComponent { onScreen = nil }
    }

    // MARK: Photos' file

    /// The file Photos hands out for the photo: the edited version if it was edited
    /// (`.fullSizePhoto`), else the original (`.photo`). None for anything but a still image
    /// (review D, L4: a video was shared as its poster frame).
    private static func sharedResource(of asset: ThumbnailRequest.Asset) -> PHAssetResource? {
        guard asset.value.mediaType == .image else { return nil }
        let resources = PHAssetResource.assetResources(for: asset.value)
        return resources.first { $0.type == .fullSizePhoto } ?? resources.first { $0.type == .photo }
    }

    private static func check(_ asset: ThumbnailRequest.Asset) async -> ShareAvailability {
        guard let resource = sharedResource(of: asset) else { return .unavailable }
        return await firstBytes(of: resource)
    }

    /// Whether the file is on the iPhone: its first bytes are asked for with the network off,
    /// and the reading stops with them. An error means it is not here (the photo is only in
    /// iCloud); no answer in time, or the caller going away, is `unknown`.
    private static func firstBytes(of resource: PHAssetResource) async -> ShareAvailability {
        let answer = PhotoKitAnswer.resource(fallback: ShareAvailability.unknown)
        answer.limit(.seconds(10))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard answer.begin(continuation) else { return }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = false
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { _ in
                    answer.finish(.onDevice, stop: true)
                } completionHandler: { error in
                    answer.finish(error == nil ? .onDevice : .onlyInICloud)
                }
                answer.started(id)
            }
        } onCancel: {
            answer.cancel()
        }
    }

    /// The photo's file, checked first (`firstBytes`), copied by Photos into a file named as
    /// Photos names the photo ("IMG_1234.HEIC"; an edited one keeps the name with its own type's
    /// extension), readable only while it is open.
    private static func write(_ asset: ThumbnailRequest.Asset, fallbackName: String) async -> Prepared {
        guard let resource = sharedResource(of: asset) else { return .unavailable(.unavailable) }
        let found = await firstBytes(of: resource)
        guard found == .onDevice else { return .unavailable(found) }
        let original = PHAssetResource.assetResources(for: asset.value).first { $0.type == .photo }?.originalFilename
        let type = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
        let name = SharedPhotoFile.name(original: original ?? resource.originalFilename, typeExtension: type, fallback: fallbackName)
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: name, directoryHint: .notDirectory)
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUnlessOpen]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: protection)
        } catch {
            return .unavailable(.unknown)
        }
        guard await copy(resource, to: file) else {
            remove(folder)
            return .unavailable(.unknown)
        }
        try? FileManager.default.setAttributes(protection, ofItemAtPath: file.path)
        return .file(file)
    }

    /// Photos writes the file with the network off; false when it could not (the iPhone is
    /// full, the file went to iCloud meanwhile) or did not answer in time, or the caller went away.
    private static func copy(_ resource: PHAssetResource, to file: URL) async -> Bool {
        let answer = PhotoKitAnswer.write(fallback: false)
        answer.limit(.seconds(60))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard answer.begin(continuation) else { return }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = false
                PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                    answer.finish(error == nil)
                }
            }
        } onCancel: {
            answer.cancel()
        }
    }

    @MainActor
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// Why the share button is off (DS-10): only a preview of the photo is on the iPhone, the photo
/// itself is in iCloud, and Albumist never loads from iCloud. Two lines at most, on a solid
/// ground under the photo, never on it (design rule 1); it goes and comes with the bars.
struct ShareInICloudNote: View {
    var body: some View {
        Label {
            Text("Das ganze Foto liegt nur in iCloud. Teilen kannst du es in der Fotos-App.")
        } icon: {
            Image(systemName: "icloud")
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .floatingPanel(cornerRadius: 22)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("viewer.shareNote")
    }
}
