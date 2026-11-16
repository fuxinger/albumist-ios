import CoreLocation
import Foundation
import Observation
import Photos
import SortlyCore
import UIKit
import UniformTypeIdentifiers

/// "Mit Beispielfotos ausprobieren" (plugin review K6, option 1, Fuchs 16.11.2026): for an
/// empty or nearly empty library (an App Review device, a new iPhone), Albumist adds a small
/// set of sample photos with dates and places, so everything it does can be tried at once.
/// Part of the shipped app; the simulator's own demo library (`DemoLibrary`) stays separate.
///
/// - The photos really go into Photos (only there can Albumist make albums of them). The
///   overview says so before anything is added.
/// - The images are drawn here (sky, sea, hills, houses): no third-party pictures, no licence
///   question, the same on every device. Rules and the list of photos: `SampleLibrary`.
/// - Albumist writes down the identifier of every photo it adds, chunk by chunk. "Beispielfotos
///   wieder entfernen" deletes exactly those, through the iOS question, together with the
///   albums Albumist made of nothing but them. This is the only place in Albumist that deletes
///   photos, and only its own sample photos; the general write interface (`PhotoKitLibrary`)
///   still cannot delete any.
@MainActor
@Observable
final class SamplePhotos {
    static let shared = SamplePhotos()

    private static let idsKey = "samples.localIdentifiers"

    private(set) var isAdding = false
    private(set) var isRemoving = false
    private(set) var added = 0
    private(set) var total = 0
    /// Identifiers of the sample photos Albumist added (and has not removed yet).
    private(set) var storedIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: SamplePhotos.idsKey) ?? [])

    var arePresent: Bool { !storedIDs.isEmpty }
    var count: Int { SampleLibrary.specs().count }

    private func remember(_ ids: Set<String>) {
        storedIDs = ids
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.idsKey)
        } else {
            UserDefaults.standard.set(ids.sorted(), forKey: Self.idsKey)
        }
    }

    // MARK: Adding

    /// Draws the sample photos and adds them to Photos in small chunks, then starts the analysis.
    func add(model: AppModel) async {
        guard !isAdding, !isRemoving else { return }
        isAdding = true
        defer { isAdding = false }
        let specs = SampleLibrary.specs()
        total = specs.count
        added = 0
        for start in stride(from: 0, to: specs.count, by: 13) {
            let chunk = specs[start..<min(start + 13, specs.count)].map { spec in
                Item(data: Self.draw(spec).jpegData(compressionQuality: 0.82) ?? Data(), name: spec.filename, date: spec.date,
                     location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: spec.location.latitude, longitude: spec.location.longitude),
                                          altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: spec.date))
            }
            do {
                let ids = try await Self.save(chunk)
                // Written down after every chunk: an app that ends half way still removes them.
                remember(storedIDs.union(ids))
                added += chunk.count
            } catch {
                model.message = .failure(String(localized: "Die Beispielfotos konnten nicht angelegt werden. Bitte versuche es noch einmal."))
                break
            }
            await Task.yield()
        }
        if added > 0 { model.startAnalysis(userInitiated: true) }
    }

    struct Item: @unchecked Sendable {
        var data: Data
        var name: String
        var date: Date
        var location: CLLocation
    }

    /// Nonisolated: PhotoKit runs the change block on its own queue (a main-actor closure there
    /// traps at runtime under Swift 6). Returns the identifiers of the new photos.
    nonisolated static func save(_ items: [Item]) async throws -> Set<String> {
        let ids = LockedBox<[String]>([])
        try await PHPhotoLibrary.shared().performChanges {
            var made: [String] = []
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = item.name
                options.uniformTypeIdentifier = UTType.jpeg.identifier
                request.addResource(with: .photo, data: item.data, options: options)
                request.creationDate = item.date
                request.location = item.location
                if let id = request.placeholderForCreatedAsset?.localIdentifier { made.append(id) }
            }
            ids.value = made
        }
        return Set(ids.value)
    }

    // MARK: Removing

    /// Deletes Albumist's own sample photos (only the written-down identifiers) and the albums
    /// it made of nothing but them, with one iOS question. "Nicht erlauben" changes nothing.
    func remove(model: AppModel) async {
        guard !isAdding, !isRemoving, let store = model.store else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            let present = Self.existing(storedIDs)
            let inventory = try await model.library.currentInventory()
            let history = try await store.planHistory(limit: 1000)
            let removal = SampleLibrary.removal(sampleIDs: Set(storedIDs.map(AssetID.init)), libraryAssets: Set(present.map(AssetID.init)),
                                                managedAlbums: try await store.managedAlbums(), inventory: inventory, history: history)
            if !removal.isEmpty {
                try await Self.delete(assets: removal.assets.map(\.rawValue), collections: removal.albums.map(\.rawValue))
            }
            // The deleted albums are not the user's deletions: their records go, and plans that
            // only made sample albums give their free albums back.
            let gone = Set(removal.albums)
            let remaining = try await store.managedAlbums().filter { !gone.contains($0.albumID) }
            try await store.saveManagedAlbums(remaining)
            model.managedAlbums = remaining
            for plan in history where removal.plansToGiveBack.contains(plan.id) {
                Purchases.shared.returnUsage(plan: plan.id, albums: plan.freeAlbumUse(applied: true))
            }
            // Whatever is still there (the user deleted some in Photos already) is forgotten
            // only once it is really gone.
            remember(Self.existing(storedIDs))
            model.inventory = try await model.library.currentInventory()
            model.startAnalysis(userInitiated: true)
        } catch {
            let ns = error as NSError
            if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.Code.userCancelled.rawValue { return }
            model.message = .failure(String(localized: "Die Beispielfotos konnten nicht entfernt werden. Bitte versuche es noch einmal."))
        }
    }

    /// Of `ids`, the ones still in the library.
    nonisolated static func existing(_ ids: Set<String>) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var result = Set<String>()
        found.enumerateObjects { asset, _, _ in result.insert(asset.localIdentifier) }
        return result
    }

    /// One change request, so iOS asks once. Albums before the folders they are in.
    nonisolated static func delete(assets: [String], collections: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            if !assets.isEmpty {
                let photos = PHAsset.fetchAssets(withLocalIdentifiers: assets, options: nil)
                if photos.count > 0 { PHAssetChangeRequest.deleteAssets(photos) }
            }
            if !collections.isEmpty {
                let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: collections, options: nil)
                if albums.count > 0 { PHAssetCollectionChangeRequest.deleteAssetCollections(albums) }
                let folders = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: collections, options: nil)
                if folders.count > 0 { PHCollectionListChangeRequest.deleteCollectionLists(folders) }
            }
        }
    }

    // MARK: Drawing

    /// A landscape in the colours of its scene, different for every photo (seeded by its number).
    nonisolated static func draw(_ spec: SampleLibrary.Spec) -> UIImage {
        var rng = SampleRandom(seed: UInt64(spec.index))
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let (top, bottom, ground) = palette(spec.scene, shift: rng.unit())
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Sky.
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.7), options: [.drawsAfterEndLocation])
            }
            // Sun.
            UIColor(white: 1, alpha: 0.85).setFill()
            let r = 60 + 50 * rng.unit()
            cg.fillEllipse(in: CGRect(x: 200 + 1100 * rng.unit(), y: 120 + 200 * rng.unit(), width: r * 2, height: r * 2))
            let horizon = size.height * (0.55 + 0.12 * rng.unit())
            switch spec.scene {
            case .mountains:
                for layer in 0..<3 {
                    let shade = CGFloat(layer) * 0.12
                    UIColor(red: 0.35 + shade, green: 0.4 + shade, blue: 0.5 + shade, alpha: 1).setFill()
                    var x: CGFloat = -200
                    while x < size.width + 200 {
                        let w = 300 + 300 * rng.unit(), h = 250 + 300 * rng.unit() - CGFloat(layer) * 60
                        let path = UIBezierPath()
                        path.move(to: CGPoint(x: x, y: horizon + 80))
                        path.addLine(to: CGPoint(x: x + w / 2, y: horizon + 80 - h))
                        path.addLine(to: CGPoint(x: x + w, y: horizon + 80))
                        path.fill()
                        UIColor(white: 0.97, alpha: 1).setFill()
                        let cap = UIBezierPath()
                        cap.move(to: CGPoint(x: x + w / 2 - w * 0.12, y: horizon + 80 - h * 0.76))
                        cap.addLine(to: CGPoint(x: x + w / 2, y: horizon + 80 - h))
                        cap.addLine(to: CGPoint(x: x + w / 2 + w * 0.12, y: horizon + 80 - h * 0.76))
                        cap.fill()
                        UIColor(red: 0.35 + shade, green: 0.4 + shade, blue: 0.5 + shade, alpha: 1).setFill()
                        x += w * 0.7
                    }
                }
            case .city:
                var x: CGFloat = 0
                while x < size.width {
                    let w = 90 + 140 * rng.unit(), h = 200 + 380 * rng.unit()
                    let tone = 0.55 + 0.35 * rng.unit()
                    UIColor(red: tone, green: tone * 0.82, blue: tone * 0.65, alpha: 1).setFill()
                    cg.fill(CGRect(x: x, y: horizon - h, width: w, height: h + 10))
                    UIColor(white: 1, alpha: 0.55).setFill()
                    var wy = horizon - h + 30
                    while wy < horizon - 40 {
                        var wx = x + 16
                        while wx < x + w - 30 { cg.fill(CGRect(x: wx, y: wy, width: 18, height: 26)); wx += 36 }
                        wy += 52
                    }
                    x += w + 6
                }
            case .home:
                let houseX = 300 + 800 * rng.unit()
                UIColor(red: 0.85, green: 0.78, blue: 0.68, alpha: 1).setFill()
                cg.fill(CGRect(x: houseX, y: horizon - 260, width: 380, height: 270))
                UIColor(red: 0.62, green: 0.25, blue: 0.2, alpha: 1).setFill()
                let roof = UIBezierPath()
                roof.move(to: CGPoint(x: houseX - 40, y: horizon - 260))
                roof.addLine(to: CGPoint(x: houseX + 190, y: horizon - 420))
                roof.addLine(to: CGPoint(x: houseX + 420, y: horizon - 260))
                roof.fill()
            case .beach, .lake:
                break
            }
            // Ground or water.
            ground.setFill()
            cg.fill(CGRect(x: 0, y: horizon, width: size.width, height: size.height - horizon))
            if spec.scene == .beach {
                UIColor(red: 0.93, green: 0.85, blue: 0.66, alpha: 1).setFill()
                let sand = UIBezierPath()
                sand.move(to: CGPoint(x: 0, y: size.height))
                sand.addLine(to: CGPoint(x: 0, y: horizon + 220 + 80 * rng.unit()))
                sand.addQuadCurve(to: CGPoint(x: size.width, y: horizon + 300), controlPoint: CGPoint(x: size.width * 0.5, y: horizon + 180))
                sand.addLine(to: CGPoint(x: size.width, y: size.height))
                sand.fill()
            }
            if spec.scene == .lake || spec.scene == .home {
                // Trees along the shore or the garden.
                for _ in 0..<(5 + Int(6 * rng.unit())) {
                    let tx = size.width * rng.unit(), th = 120 + 120 * rng.unit()
                    UIColor(red: 0.16, green: 0.38 + 0.15 * rng.unit(), blue: 0.22, alpha: 1).setFill()
                    cg.fillEllipse(in: CGRect(x: tx, y: horizon - th, width: th * 0.7, height: th))
                }
            }
        }
    }

    nonisolated static func palette(_ scene: SampleLibrary.Scene, shift: CGFloat) -> (UIColor, UIColor, UIColor) {
        let s = shift * 0.1
        switch scene {
        case .home: return (UIColor(red: 0.45 + s, green: 0.65, blue: 0.9, alpha: 1), UIColor(red: 0.85, green: 0.9, blue: 0.95, alpha: 1),
                            UIColor(red: 0.35, green: 0.6 + s, blue: 0.3, alpha: 1))
        case .beach: return (UIColor(red: 0.2, green: 0.55 + s, blue: 0.9, alpha: 1), UIColor(red: 0.75, green: 0.9, blue: 0.98, alpha: 1),
                             UIColor(red: 0.1, green: 0.45 + s, blue: 0.7, alpha: 1))
        case .city: return (UIColor(red: 0.95, green: 0.6 + s, blue: 0.4, alpha: 1), UIColor(red: 0.98, green: 0.85, blue: 0.65, alpha: 1),
                            UIColor(red: 0.5 + s, green: 0.45, blue: 0.4, alpha: 1))
        case .mountains: return (UIColor(red: 0.3, green: 0.5 + s, blue: 0.85, alpha: 1), UIColor(red: 0.85, green: 0.92, blue: 1, alpha: 1),
                                 UIColor(red: 0.9 + s, green: 0.93, blue: 0.96, alpha: 1))
        case .lake: return (UIColor(red: 0.55 + s, green: 0.7, blue: 0.9, alpha: 1), UIColor(red: 0.95, green: 0.88, blue: 0.8, alpha: 1),
                            UIColor(red: 0.25, green: 0.45, blue: 0.6 + s, alpha: 1))
        }
    }
}

/// Small deterministic random numbers for drawing (the same picture on every device).
struct SampleRandom {
    private var state: UInt64
    init(seed: UInt64) { state = (seed &+ 1) &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func unit() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(Double(state >> 11) / Double(1 << 53))
    }
}
