import Foundation

// Contracts between the platform-independent pipeline and the iOS implementations
// (PhotoKit, Vision, MapKit). The app provides conforming types; tests provide fakes.

/// Photo library access as granted by the user (prompt §7, Schritt 1).
public enum LibraryAccess: String, Sendable, Codable {
    case notDetermined, full, limited, denied, restricted

    /// Full access is needed to organize the whole library; limited access works on the
    /// selected photos only and says so in the UI.
    public var canRead: Bool { self == .full || self == .limited }
}

public protocol PhotoLibraryReading: Sendable {
    func access() async -> LibraryAccess
    /// Snapshots of all readable assets. Hidden assets only when the user opted in.
    ///
    /// File details (original name, type, RAW flag) cost a few milliseconds per asset, so they
    /// are read only for assets that are not in `knownDetails` or whose modification date
    /// differs from the one given there. The others come with `uniformTypeIdentifier == nil`
    /// and without the RAW flag; the store keeps their earlier values.
    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date]) async throws -> [AssetSnapshot]
    /// The same, saying how far it is (`progress(read, total)`, from any thread) while it
    /// reads, so the count moves during a long first read: reading 50,000 photos without
    /// their file details took minutes on the simulator with nothing moving on the card
    /// (stress run 43833158673). `progress` answers whether to go on: `false` (Pause) ends
    /// the read with `LibraryReadPaused`, which carries the photos read so far. They are never
    /// taken as the whole library (that would count the rest as deleted), but their file
    /// details are kept, so a user who pauses again and again still gets further each time.
    /// Readers that are quick anyway use the plain one.
    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date],
                     progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> [AssetSnapshot]
    func currentInventory() async throws -> CollectionInventory
}

/// A library read ended by Pause: the photos read until then (see `fetchAssets(progress:)`).
public struct LibraryReadPaused: Error, Sendable {
    public var read: [AssetSnapshot]
    public init(read: [AssetSnapshot]) { self.read = read }
}

public extension PhotoLibraryReading {
    func fetchAssets(includeHidden: Bool, knownDetails: [AssetID: Date],
                     progress: @escaping @Sendable (Int, Int) -> Bool) async throws -> [AssetSnapshot] {
        try await fetchAssets(includeHidden: includeHidden, knownDetails: knownDetails)
    }
}

/// One classifier label as produced by the image classifier.
public struct LabelScore: Hashable, Sendable, Codable {
    public var identifier: String
    public var confidence: Double
    /// Vision's own calibration for this label says it is right at high precision (90 %),
    /// whatever the raw confidence: confidences are not comparable between labels (0.4 can be
    /// sure for one and a guess for another). `nil` in results stored before it was asked.
    /// Nothing relies on it yet; the confidence thresholds work as before.
    public var isPrecise: Bool?

    public init(_ identifier: String, _ confidence: Double, isPrecise: Bool? = nil) {
        self.identifier = identifier
        self.confidence = confidence
        self.isPrecise = isPrecise
    }

    /// Calibrated precision Vision is asked for (`hasMinimumRecall(0.01, forPrecision:)`).
    public static let preciseAt: Float = 0.9
}

public enum AnalysisImageSource: String, Hashable, Sendable, Codable {
    /// Small preview that is always on the device, even with "Optimize iPhone Storage".
    case localPreview
    /// Full-resolution original (may have been downloaded from iCloud).
    case original
}

public struct AnimalObservation: Hashable, Sendable, Codable {
    public var kind: GroupKind
    public var observation: VisualObservation
    public init(kind: GroupKind, observation: VisualObservation) {
        self.kind = kind
        self.observation = observation
    }
}

/// Image content found on the local preview (speed-up 4: no iCloud download needed).
public struct ContentAnalysis: Hashable, Sendable, Codable {
    public var labels: [LabelScore]
    /// Face observations with embeddings; only when face grouping is enabled (GDPR Art. 9).
    public var faces: [VisualObservation]
    public var animals: [AnimalObservation]
    public var featurePrint: Embedding?
    /// The analyzer saw a page-like document (receipt, letter, form).
    public var looksLikeDocument: Bool
    /// The preview contains text regions worth reading in full.
    public var containsText: Bool
    public var source: AnalysisImageSource
    /// Runs in which the image could not be read (no local preview yet, still syncing).
    /// Such a photo is tried again in later runs and does not count as analyzed. `nil` = read.
    public var failedAttempts: Int?
    /// When the image could last not be read (`nil` in records of older versions).
    public var lastAttempt: Date?
    /// Vision's aesthetics score (-1…1, higher = better composed, sharper, better lit), for
    /// picking covers. `nil` in results stored before it was computed (they stay valid).
    public var aestheticsScore: Double?
    /// Vision says this is a utility image (screenshot, receipt, document, whiteboard, QR
    /// code) rather than a memorable photo. `nil` = not known.
    public var isUtility: Bool?

    /// Runs that may fail to read an image before it is given up and counted as analyzed.
    public static let maxFailedAttempts = 3
    /// Time between two reads of a photo that could not be read. Catch-up runs follow each
    /// other within seconds while iCloud syncs (every change in Photos starts one); without a
    /// gap, three of them gave a photo up for good before its preview had even arrived.
    public static let retrySpacing: TimeInterval = 3600

    /// Whether a photo that could not be read is due for another try.
    public func isDueForRetry(now: Date) -> Bool {
        guard failedAttempts != nil, let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Self.retrySpacing
    }

    public init(
        labels: [LabelScore] = [],
        faces: [VisualObservation] = [],
        animals: [AnimalObservation] = [],
        featurePrint: Embedding? = nil,
        looksLikeDocument: Bool = false,
        containsText: Bool = false,
        source: AnalysisImageSource = .localPreview,
        aestheticsScore: Double? = nil,
        isUtility: Bool? = nil
    ) {
        self.aestheticsScore = aestheticsScore
        self.isUtility = isUtility
        self.labels = labels
        self.faces = faces
        self.animals = animals
        self.featurePrint = featurePrint
        self.looksLikeDocument = looksLikeDocument
        self.containsText = containsText
        self.source = source
    }

    /// This result with the labels of `fresh`, a look at the same image with only the labels
    /// asked for (`ContentAnalysisRequest.labelsOnly`): "Themen" or "Dokumente" turned on after
    /// the photo was analysed. Everything else stays as it was found then; what the earlier
    /// look did not have (a score, the utility flag) is taken from the new one.
    public func addingLabels(of fresh: ContentAnalysis) -> ContentAnalysis {
        var merged = self
        merged.labels = fresh.labels
        merged.looksLikeDocument = looksLikeDocument || fresh.looksLikeDocument
        merged.containsText = containsText || fresh.containsText
        merged.aestheticsScore = aestheticsScore ?? fresh.aestheticsScore
        merged.isUtility = isUtility ?? fresh.isUtility
        return merged
    }

    /// Labels that indicate a document even if the analyzer did not flag one.
    static let documentLabels: Set<String> = ["document", "receipt", "printed_page", "paper", "envelope", "letter", "text", "menu", "ticket", "invoice"]

    /// Speed-up 5: full text recognition only for screenshots and document-like images.
    public func needsTextRecognition(for asset: AssetSnapshot) -> Bool {
        if asset.kind == .video { return false }
        if asset.isScreenshotLike { return true }
        if looksLikeDocument { return true }
        // A photographed letter, receipt or whiteboard the labels missed: Vision's utility
        // flag finds documents the label list alone does not.
        if isUtility == true { return true }
        return labels.contains { Self.documentLabels.contains($0.identifier) && $0.confidence >= 0.5 }
    }
}

/// Failed reads of a photo that only needed its labels (`ContentAnalysisRequest.labelsOnly`),
/// stored apart from its content result (kind "labels"), which stays exactly as it was. Counted
/// and spaced like `ContentAnalysis.failedAttempts`: given up for its labels after
/// `ContentAnalysis.maxFailedAttempts` runs, at least `ContentAnalysis.retrySpacing` apart.
public struct LabelAttempts: Hashable, Sendable, Codable {
    public var failedAttempts: Int
    public var lastAttempt: Date
    public init(failedAttempts: Int, lastAttempt: Date) {
        self.failedAttempts = failedAttempts
        self.lastAttempt = lastAttempt
    }

    public func isDueForRetry(now: Date) -> Bool {
        now.timeIntervalSince(lastAttempt) >= ContentAnalysis.retrySpacing
    }
}

public struct ContentAnalysisRequest: Hashable, Sendable {
    public var classify = true
    public var detectFaces = false
    public var detectAnimals = true
    public var featurePrint = true
    public init(classify: Bool = true, detectFaces: Bool = false, detectAnimals: Bool = true, featurePrint: Bool = true) {
        self.classify = classify
        self.detectFaces = detectFaces
        self.detectAnimals = detectAnimals
        self.featurePrint = featurePrint
    }

    /// Only the image labels: for photos analysed while "Themen" and "Dokumente" were off,
    /// once one of them is turned on (the rest of their result stays).
    public static let labelsOnly = ContentAnalysisRequest(classify: true, detectFaces: false, detectAnimals: false, featurePrint: false)
}

/// Recognized text of a screenshot or document.
public struct TextAnalysis: Hashable, Sendable, Codable {
    public var text: String
    public var barcodePayloads: [String]
    public var source: AnalysisImageSource
    public init(text: String, barcodePayloads: [String] = [], source: AnalysisImageSource) {
        self.text = text
        self.barcodePayloads = barcodePayloads
        self.source = source
    }
}

/// What an analyzer throws when the photo itself is the problem. Any other error (Vision or
/// the system failing, e.g. no access to the graphics hardware in the background) says
/// nothing about the photo: the pipeline does not count it against the photo while every
/// photo fails the same way.
public enum AnalysisError: Error, Equatable, Sendable {
    /// The original is only in iCloud and downloading is not allowed right now.
    case originalNotAvailable
    /// The asset vanished or cannot be decoded.
    case unreadable
}

public protocol ContentAnalyzing: Sendable {
    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis
    /// Reads text from the best available image. Throws `AnalysisError.originalNotAvailable`
    /// when the original would have to be downloaded and `allowNetwork` is false.
    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis
    /// The next few photos the content stage will look at, so their previews can be loaded
    /// ahead while the current ones are analysed. A hint; nothing depends on it.
    func willAnalyze(_ upcoming: [AssetSnapshot]) async
}

extension ContentAnalyzing {
    public func willAnalyze(_ upcoming: [AssetSnapshot]) async {}
}

public enum PauseReason: String, Sendable, Codable {
    case userPaused, thermal, lowPower, batteryLow, timeBudget, accessRevoked
}

/// How a run in the app reacts to the device. First device test 15.11.: a warm iPhone ended
/// the analysis for good and nothing started it again ("bricht die Suche ab").
public enum AnalysisPace: Sendable, Equatable {
    /// Full speed.
    case normal
    /// Warm: a short break after every photo, so the device cools down while the run goes on.
    case gentle
    /// Too hot or the battery nearly empty: the run waits and goes on by itself.
    case wait(PauseReason)
    /// The run ends here; a later run goes on from the same place.
    case stop(PauseReason)
}

/// What the device reports (ProcessInfo, UIDevice), and the rules that turn it into a pause
/// or a pace. Kept apart from UIKit so every combination is tested.
public struct DeviceState: Sendable, Equatable {
    /// `ProcessInfo.ThermalState`, in the same order.
    public enum Thermal: Int, Sendable, Comparable {
        case nominal, fair, serious, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var thermal: Thermal
    /// 0…1; `nil` when unknown (UIDevice says -1, e.g. in the simulator).
    public var batteryLevel: Double?
    /// Charging or full: on power.
    public var isCharging: Bool
    public var isLowPowerMode: Bool

    public init(thermal: Thermal = .nominal, batteryLevel: Double? = nil, isCharging: Bool = false, isLowPowerMode: Bool = false) {
        self.thermal = thermal
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.isLowPowerMode = isLowPowerMode
    }

    /// Below this level, without power, the overnight refinement does not run.
    public static let refinementBatteryFloor = 0.2
    /// Below this level, without power, a run in the app waits until the phone is charged.
    public static let appBatteryFloor = 0.1

    private func isBelow(_ floor: Double) -> Bool {
        guard !isCharging, let batteryLevel else { return false }
        return batteryLevel < floor
    }

    /// The overnight refinement (nobody waits for it): any of these ends it until the next
    /// charging window.
    public var refinementPauseReason: PauseReason? {
        if thermal >= .serious { return .thermal }
        if isLowPowerMode && !isCharging { return .lowPower }
        if isBelow(Self.refinementBatteryFloor) { return .batteryLow }
        return nil
    }

    /// A run in the app (the user started it or waits for it): very warm only slows it down,
    /// too hot or a nearly empty battery make it wait, and it goes on by itself. Low Power
    /// Mode does not stop it; iOS already runs the phone slower then. First device test 15.11.:
    /// a warm iPhone ended the analysis for good and nothing started it again.
    public var appPace: AnalysisPace {
        if thermal == .critical { return .wait(.thermal) }
        if isBelow(Self.appBatteryFloor) { return .wait(.batteryLow) }
        if thermal == .serious { return .gentle }
        return .normal
    }

    /// Why a run in the app goes slower than usual, said on the card under the count, so a
    /// finish time that moves later is explained (progress display T13). Only while the run
    /// does not wait (`appPace` is not `.wait`).
    public var slowerReason: SlowReason? {
        if case .wait = appPace { return nil }
        if thermal == .serious { return .warm }
        if isLowPowerMode { return .lowPower }
        return nil
    }
}

/// See `DeviceState.slowerReason`.
public enum SlowReason: String, Sendable, Codable {
    /// "Langsamer, weil dein iPhone warm ist"
    case warm
    /// "Langsamer, weil der Stromsparmodus an ist"
    case lowPower
}

/// Device conditions (thermal state, power, network). Implemented with ProcessInfo,
/// UIDevice and NWPathMonitor in the app.
public protocol AnalysisConditions: Sendable {
    /// The overnight refinement: any reason ends the run until the next charging window.
    func pauseReason() async -> PauseReason?
    /// Runs in the app (the user waits for them): slow down or wait, but do not end.
    func pace() async -> AnalysisPace
    func isOnWiFi() async -> Bool
}

extension AnalysisConditions {
    /// Without a rule of its own, a reason ends a run in the app too.
    public func pace() async -> AnalysisPace {
        if let reason = await pauseReason() { return .stop(reason) }
        return .normal
    }
}
