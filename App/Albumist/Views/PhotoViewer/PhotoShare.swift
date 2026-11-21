import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AlbumistCore

/// Sharing the photo the photo view shows (design wave 2, DS-10: "Teilen"), with iOS's share
/// sheet. Only what is on the iPhone: the photo's data as Photos hands it out (its current
/// version, edits included, as Photos shares it), never loaded from iCloud; Albumist itself
/// sends nothing anywhere, the user picks where it goes.
///
/// For the share sheet the data goes into a temporary file with the photo's own name
/// (`SharedPhotoFile`), in a folder of its own; the folder is removed when the share sheet
/// closes, and whatever is left over (the app was ended meanwhile) when the photo view opens or
/// closes. Nothing else is written and the photo in the library is not touched. "Bild sichern"
/// is not offered: it would put a second copy of the photo into the library.
enum PhotoShare {
    enum Prepared: Sendable {
        case file(URL)
        /// Why not: only in iCloud, gone, or (`unknown`) Photos did not answer in time.
        case unavailable(ShareAvailability)
    }

    /// Where the files for the share sheet are made, each in a folder of its own.
    static let root = FileManager.default.temporaryDirectory.appending(path: "PhotoShare", directoryHint: .isDirectory)

    /// Whether the whole photo is on the iPhone: Photos is asked for its data, without network.
    /// `unknown` while Photos does not answer (the button stays on, a tap asks again).
    @MainActor
    static func availability(of id: AssetID) async -> ShareAvailability {
        guard let asset = await ThumbnailCache.shared.asset(for: id) else { return .unknown }
        return await load(asset).availability
    }

    /// The photo in a file for the share sheet, or why there is none.
    @MainActor
    static func prepare(_ id: AssetID, fallbackName: String) async -> Prepared {
        guard let asset = await ThumbnailCache.shared.asset(for: id) else { return .unavailable(.unavailable) }
        return await write(asset, fallbackName: fallbackName)
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
        sheet.excludedActivityTypes = [.saveToCameraRoll]
        sheet.completionWithItemsHandler = { _, _, _, _ in remove(folder) }
        if let popover = sheet.popoverPresentationController {
            // On an iPad: from the bar's right end, where the button is.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.maxX - 100, y: top.view.safeAreaInsets.top - 44, width: 44, height: 44)
        }
        top.present(sheet, animated: true)
    }

    /// One share's folder; never anything outside the share folder.
    static func remove(_ folder: URL) {
        guard folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The files of shares that were not cleaned up after (the app was ended meanwhile).
    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Loading

    private struct Loaded: Sendable {
        var data: Data?
        var type: String?
        var inCloud = false
        /// False: Photos did not answer in time, or the caller went away.
        var answered = true

        var availability: ShareAvailability {
            if data != nil { return .onDevice }
            if inCloud { return .onlyInICloud }
            return answered ? .unavailable : .unknown
        }
    }

    private static func load(_ asset: ThumbnailRequest.Asset) async -> Loaded {
        let answer = PhotoKitAnswer.image(fallback: Loaded(answered: false))
        answer.limit(.seconds(20))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard answer.begin(continuation) else { return }
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.version = .current
                options.deliveryMode = .highQualityFormat
                let id = PHImageManager.default().requestImageDataAndOrientation(for: asset.value, options: options) { data, type, _, info in
                    // Only a preview is here, the photo itself is in iCloud.
                    let inCloud = ((info as [AnyHashable: Any]?)?[PHImageResultIsInCloudKey] as? Bool) ?? false
                    answer.finish(Loaded(data: data, type: type, inCloud: inCloud))
                }
                answer.started(id)
            }
        } onCancel: {
            answer.cancel()
        }
    }

    /// The data in a file named as Photos names the photo ("IMG_1234.HEIC"), off the main thread.
    private static func write(_ asset: ThumbnailRequest.Asset, fallbackName: String) async -> Prepared {
        let loaded = await load(asset)
        guard let data = loaded.data else { return .unavailable(loaded.availability) }
        let original = PHAssetResource.assetResources(for: asset.value).first { $0.type == .photo }?.originalFilename
        let type = loaded.type.flatMap { UTType($0)?.preferredFilenameExtension }
        let name = SharedPhotoFile.name(original: original, typeExtension: type, fallback: fallbackName)
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name, directoryHint: .notDirectory)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            return .file(file)
        } catch {
            remove(folder)
            return .unavailable(.unavailable)
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
