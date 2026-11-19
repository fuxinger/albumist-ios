import CoreImage
import Foundation
import ImageIO
import Photos
import UIKit
import Vision
import SortlyCore

/// CGImage plus orientation, safe to pass between tasks (the image is immutable).
struct LoadedImage: @unchecked Sendable {
    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation
}

enum ImageQuality {
    /// The small preview Photos always keeps on the device (no download, speed-up 4).
    case localPreview
    /// The full original; may need iCloud.
    case original
}

/// The small previews of the next few photos, loaded ahead while the current ones are
/// analysed (the content stage tells which, see `ContentAnalyzing.willAnalyze`). Requests for
/// a preview go through the same manager with the same size and options, or the cache misses.
enum PreviewCache {
    /// PhotoKit's image managers are thread-safe.
    nonisolated(unsafe) static let manager = PHCachingImageManager()
    static let size = CGSize(width: 512, height: 512)

    static func options() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false
        options.version = .current
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        return options
    }

    /// The fetch is bounded on the image lane; a Photos that does not answer only means no
    /// previews are loaded ahead (the analysis hears of it with its next photo).
    static func start(_ ids: [AssetID]) async {
        guard !ids.isEmpty,
              let fetched = try? await PhotoKitLibrary.fetchAssets(ids, what: "fetchPreviewAssets"),
              !Task.isCancelled else { return }
        manager.startCachingImages(for: fetched.assets, targetSize: size, contentMode: .aspectFit, options: options())
    }

    /// Loads started by `willAnalyze` that have not finished: stopped with the image step
    /// (`ContentAnalyzing.contentEnded`), so none outlives the run (third review, N7).
    private static let pending = PendingStarts()

    static func startAhead(_ ids: [AssetID]) {
        guard !ids.isEmpty else { return }
        pending.add { await PreviewCache.start(ids) }
    }

    /// The image step ended: loads still waiting for Photos stop, and the previews go.
    static func stopAll() {
        pending.cancelAll()
        manager.stopCachingImagesForAllAssets()
    }

    /// On a memory warning the previews loaded ahead go (P4-06). The analysis asks Photos for
    /// each photo it reads (`ImageLoader`), so it goes on, only without the photos loaded ahead;
    /// `willAnalyze` loads the next ones ahead again.
    @MainActor static func registerForMemoryWarnings() {
        MemoryPressure.shared.register("analysis previews", owner: manager) { $0.stopCachingImagesForAllAssets() }
    }

    /// Analysed: its preview is not kept for longer than needed.
    static func stop(_ asset: PHAsset) {
        manager.stopCachingImages(for: [asset], targetSize: size, contentMode: .aspectFit, options: options())
    }
}

/// Tasks started for the run that the run does not wait for; cancelled together.
final class PendingStarts: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func add(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        // Kept before the task can end and remove itself (it waits for the lock meanwhile).
        lock.withLock {
            tasks[id] = Task {
                await work()
                self.remove(id)
            }
        }
    }

    func cancelAll() {
        let running = lock.withLock { () -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        for task in running { task.cancel() }
    }

    private func remove(_ id: UUID) {
        lock.withLock { tasks[id] = nil }
    }
}

/// What the image requests of this launch ended with, counted per outcome: in the diagnostic
/// report and, in UI runs, on the analysis card (UI runs reported every demo photo unreadable
/// and nothing said why).
enum ImageLoadStats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func note(_ outcome: String) {
        lock.lock()
        counts[outcome, default: 0] += 1
        lock.unlock()
    }

    static var summary: String {
        lock.lock()
        defer { lock.unlock() }
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// Why PhotoKit handed back no image, from the info it gave.
    static func reason(_ info: [AnyHashable: Any]?) -> String {
        var parts: [String] = []
        if let error = info?[PHImageErrorKey] as? NSError { parts.append("error \(error.domain) \(error.code)") }
        if (info?[PHImageResultIsInCloudKey] as? Bool) == true { parts.append("in cloud") }
        if (info?[PHImageResultIsDegradedKey] as? Bool) == true { parts.append("degraded") }
        return parts.isEmpty ? "no info" : parts.joined(separator: " ")
    }
}

/// Loads images from PhotoKit for analysis.
enum ImageLoader {
    /// Throws `PhotosNotResponding` when Photos does not hand over the photo in time (the fetch
    /// is bounded on the image lane, `PhotoKitLibrary.fetchAssets`).
    static func image(for id: AssetID, quality: ImageQuality, allowNetwork: Bool) async throws -> LoadedImage? {
        guard let asset = try await PhotoKitLibrary.fetchAssets([id]).assets.first else {
            ImageLoadStats.note("asset missing")
            throw AnalysisError.unreadable
        }
        switch quality {
        case .localPreview:
            defer { PreviewCache.stop(asset) }
            do {
                if let image = try await load(asset, manager: PreviewCache.manager, target: PreviewCache.size,
                                              options: PreviewCache.options(), waitsForFinal: false, stat: "preview") {
                    return image
                }
            } catch AnalysisError.originalNotAvailable {
                // Asked below like an empty answer.
            }
            // No small preview: the image is made from the original on the device instead,
            // never from iCloud. The fast format has no preview of a photo Photos has not made
            // thumbnails for yet (every photo the simulator's demo library had just created).
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = false
            options.version = .current
            options.deliveryMode = .highQualityFormat
            // .exact: .fast may hand back a larger stored copy (1–2k px, up to ~16 MB each).
            options.resizeMode = .exact
            return try await load(asset, manager: PHImageManager.default(), target: PreviewCache.size,
                                  options: options, waitsForFinal: true, stat: "local original")
        case .original:
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = allowNetwork
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            return try await load(asset, manager: PHImageManager.default(), target: CGSize(width: 2_400, height: 2_400),
                                  options: options, waitsForFinal: true, stat: "original")
        }
    }

    /// One request resumes the caller exactly once: with the final image, with an error, or
    /// with CancellationError when the analysis stops (the PhotoKit request, maybe an iCloud
    /// download, is cancelled with it instead of running on).
    private static func load(_ asset: PHAsset, manager: PHImageManager, target: CGSize, options: PHImageRequestOptions,
                             waitsForFinal: Bool, stat: String) async throws -> LoadedImage? {
        let request = ImageRequest(manager: manager)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LoadedImage?, Error>) in
                guard request.start(continuation) else { return }
                let id = manager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        request.finish(.failure(CancellationError()))
                        return
                    }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if isDegraded && waitsForFinal { return } // wait for the final image
                    if let image, let loaded = LoadedImage(image) {
                        ImageLoadStats.note("\(stat) ok")
                        request.finish(.success(loaded))
                    } else if image != nil {
                        ImageLoadStats.note("\(stat) not drawable")
                        request.finish(.success(nil))
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
                        ImageLoadStats.note("\(stat) in cloud")
                        request.finish(.failure(AnalysisError.originalNotAvailable))
                    } else {
                        ImageLoadStats.note("\(stat) none (\(ImageLoadStats.reason(info)))")
                        request.finish(.success(nil))
                    }
                }
                request.attach(id)
                // PhotoKit may never call back (assetsd stalled): the lane gives up after a while
                // instead of hanging the analysis. A download from iCloud gets longer.
                let limit: Double = options.isNetworkAccessAllowed ? 180 : 30
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
                    if request.timeOut() { ImageLoadStats.note("\(stat) timed out") }
                }
            }
        } onCancel: {
            request.cancel()
        }
    }
}

extension LoadedImage {
    /// One Core Image context for all images (creating one per photo is costly).
    nonisolated(unsafe) static let sharedContext = CIContext()

    /// The bitmap of a PhotoKit image; one backed by Core Image is rendered once.
    init?(_ image: UIImage) {
        if let cg = image.cgImage {
            self.init(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
        } else if let ci = image.ciImage, let cg = LoadedImage.sharedContext.createCGImage(ci, from: ci.extent) {
            self.init(cgImage: cg, orientation: CGImagePropertyOrientation(image.imageOrientation))
        } else {
            return nil
        }
    }
}

/// State of one PhotoKit image request. PhotoKit may call back more than once (degraded,
/// then final), on any thread, even before `requestImage` returns; cancellation can come at
/// any point in between. Every path goes through the lock, so the continuation is resumed
/// once and a cancelled request is cancelled in PhotoKit too.
private final class ImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    /// The manager that made the request (only it can cancel it).
    private let manager: PHImageManager
    private var continuation: CheckedContinuation<LoadedImage?, Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false

    init(manager: PHImageManager) {
        self.manager = manager
    }

    /// Stores the continuation, or resumes it at once when the task was already cancelled.
    func start(_ continuation: CheckedContinuation<LoadedImage?, Error>) -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func attach(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { manager.cancelImageRequest(id) }
    }

    func finish(_ result: Result<LoadedImage?, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    /// Gives up on a request PhotoKit never answered: resumes with no image and cancels it in
    /// PhotoKit. True if the request was still waiting.
    func timeOut() -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        let id = requestID
        lock.unlock()
        guard let pending else { return false }
        if let id { manager.cancelImageRequest(id) }
        pending.resume(returning: nil)
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let id { manager.cancelImageRequest(id) }
        pending?.resume(throwing: CancellationError())
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// On-device image understanding with Apple's Vision framework (no network, no upload).
struct VisionAnalyzer: ContentAnalyzing {
    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        guard asset.kind == .image || asset.kind == .video else { return ContentAnalysis() }
        guard let image = try await ImageLoader.image(for: asset.id, quality: .localPreview, allowNetwork: false) else {
            throw AnalysisError.unreadable
        }
        var labels: [LabelScore] = []
        if request.classify {
            let observations = try await ClassifyImageRequest().perform(on: image.cgImage, orientation: image.orientation)
            labels = observations.compactMap { observation in
                // Vision's calibration per label (a raw confidence means something different for
                // every label): kept with the label, and a label it is sure of is kept even
                // below the usual confidence floor.
                let precise = observation.hasMinimumRecall(0.01, forPrecision: LabelScore.preciseAt)
                guard observation.confidence >= 0.1 || precise else { return nil }
                return LabelScore(observation.identifier, Double(observation.confidence), isPrecise: precise)
            }
        }
        // Same image, same pass: how good a photo it is (for covers) and whether it is a
        // utility image (documents, receipts). Optional: a failure here never costs the labels.
        let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: image.cgImage, orientation: image.orientation)
        // Individual faces and pets need identity embeddings; they are produced only after
        // the user opted in (GDPR Art. 9). The grouping UI ships in a later iteration.
        return ContentAnalysis(labels: labels, source: .localPreview,
                               aestheticsScore: aesthetics.map { Double($0.overallScore) },
                               isUtility: aesthetics?.isUtility)
    }

    func willAnalyze(_ upcoming: [AssetSnapshot]) async {
        // Not waited for: a fetch Photos is slow to answer never holds up the photo analysed now.
        PreviewCache.startAhead(upcoming.filter { $0.kind == .image || $0.kind == .video }.map(\.id))
    }

    func contentEnded() {
        PreviewCache.stopAll()
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        // OCR needs the full resolution. Screenshots are usually on the device anyway; other
        // originals come from iCloud only with consent (allowNetwork). Fallback: local preview.
        var source: AnalysisImageSource = .original
        var loaded: LoadedImage?
        do {
            loaded = try await ImageLoader.image(for: asset.id, quality: .original, allowNetwork: allowNetwork)
        } catch let quiet as PhotosNotResponding {
            throw quiet // Photos does not answer: the preview would wait behind it.
        } catch {
            loaded = nil
        }
        if loaded == nil {
            loaded = try await ImageLoader.image(for: asset.id, quality: .localPreview, allowNetwork: false)
            source = .localPreview
        }
        guard let image = loaded else { throw AnalysisError.unreadable }

        var textRequest = RecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        let lines = try await textRequest.perform(on: image.cgImage, orientation: image.orientation)
            .compactMap { $0.topCandidates(1).first?.string }
        let barcodes = (try? await DetectBarcodesRequest().perform(on: image.cgImage, orientation: image.orientation))?
            .compactMap(\.payloadString) ?? []
        return TextAnalysis(text: lines.joined(separator: "\n"), barcodePayloads: barcodes, source: source)
    }
}
