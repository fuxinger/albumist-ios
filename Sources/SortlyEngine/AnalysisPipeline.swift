import Foundation
import SortlyCore
import SortlyStore

/// Snapshot of the latest proposals, stored so the app opens instantly (prompt §14).
public struct ProposalSnapshot: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var scope: OrganizationScope
    public var proposals: [AlbumProposal]
    public var matches: [SortlyID: MatchResult]
}

/// Runs the analysis stages in a fixed, resumable order (prompt §13, §14):
///
/// 1. inventory  – read assets and albums, detect new/changed/removed items
/// 2. patterns   – trips and frequent places from time and GPS only (no network)
/// 3. places     – offline map + throttled online lookups, trip photos first
/// 4. content    – categories, animals, (opt-in) faces on local previews
/// 5. text       – OCR only for screenshots and document-like images
/// 6. groups     – person/pet grouping with the user's feedback
/// 7. proposals  – album proposals, matched against existing albums
///
/// Every stage persists its results as it goes, so pausing, a background expiry or a
/// crash loses at most one batch. Each result carries a version: raising a version
/// re-runs only the affected stage.
public actor AnalysisPipeline {
    public enum Stage: String, CaseIterable, Sendable, Codable {
        case inventory, patterns, places, content, text, groups, proposals

        /// Rough share of a full first run; the image analysis takes most of the time.
        public var share: Double {
            switch self {
            case .inventory: 0.05
            case .patterns: 0.03
            case .places: 0.12
            case .content: 0.6
            case .text: 0.12
            case .groups: 0.03
            case .proposals: 0.05
            }
        }

        /// 1-based position, for "Schritt 4 von 7".
        public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    }

    public enum Mode: String, Sendable, Codable {
        /// New and changed items only (also used for the first run).
        case incremental
        /// Overnight pass: finer town names, iCloud originals for text, fresh proposals.
        case refinement
    }

    public struct Progress: Sendable, Hashable {
        public var stage: Stage
        public var completed: Int
        public var total: Int

        /// One value for the whole run (0…1), so a bar never jumps back when the next stage starts.
        public static func overall(stage: Stage, completed: Int, total: Int) -> Double {
            let before = Stage.allCases.prefix { $0 != stage }.reduce(0) { $0 + $1.share }
            let within = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0
            return min(1, before + stage.share * within)
        }
    }

    public struct Report: Sendable, Hashable {
        public var completedStages: [Stage] = []
        /// Trips and places were offered before the image analysis (first run only).
        public var earlyProposals = false
        public var pausedBecause: PauseReason?
        public var newOrChanged = 0
        public var removed = 0
        public var placesResolved = 0
        public var placesPendingOnline = 0
        public var onlineRequests = 0
        public var contentAnalyzed = 0
        public var textRecognized = 0
        public var textWaitingForOriginal = 0
        public var proposals = 0

        public var isComplete: Bool { pausedBecause == nil && completedStages.count == Stage.allCases.count }
    }

    public static let contentVersion = 1
    public static let textVersion = 1

    enum Key {
        static let trips = "analysis.trips"
        static let frequentPlaces = "analysis.frequentPlaces"
        static let groups = "analysis.groups"
        static let tripCorrections = "user.tripCorrections"
        /// The user's answers to "Bist du hier öfter?" (part of the decisions copy in the backup).
        static let recurringPlaces = "user.recurringPlaces"
        /// Places to ask about, where each trip was, the photos of the places the user is often at.
        static let recurringPlaceReport = "analysis.recurringPlaces"
        /// Trip identities across runs (kept by "Analyse neu aufbauen", like other user data).
        static let tripIdentities = "user.tripIdentities"
        static let groupingFeedback = "user.groupingFeedback"
        /// Version of the masks the stored texts went through (see `TextMinimizer.maskVersion`).
        static let textMaskVersion = "analysis.textMaskVersion"
        static let proposals = "analysis.proposals"
        /// The trial run's year chosen at the start (kept by "Analyse neu aufbauen").
        static let scope = "user.analysisScope"
    }

    private let store: SortlyStore
    private let reader: any PhotoLibraryReading
    private let analyzer: any ContentAnalyzing
    private let geocoder: (any ReverseGeocoding)?
    private let map: OfflineWorldMap?
    private let conditions: any AnalysisConditions
    private let calendar: Calendar
    private let time: TimeSource
    private let batchSize: Int
    private let now: @Sendable () -> Date
    /// Bumped whenever the albums changed outside a run (a plan was applied): a run that
    /// computed its matches before that matches again before it saves them.
    private var albumGeneration = 0
    /// Online place lookups per normal run; the rest waits for the overnight refinement run.
    /// Keeps the first analysis from spending up to an hour on town names before photos are
    /// looked at (the geocoder allows about 40 requests a minute). `nil` = no limit.
    private let foregroundOnlineBudget: Int?
    public private(set) var settings: OrganizationSettings
    private var userPaused = false
    /// The mode of the run in progress (online place lookups ask it between requests).
    private var runMode: Mode = .incremental
    /// A warm device: break after every photo. Waiting: how often the device is asked again.
    static let gentleBreak: Duration = .milliseconds(250)
    static let waitCheck: Duration = .seconds(2)

    public init(
        store: SortlyStore,
        reader: any PhotoLibraryReading,
        analyzer: any ContentAnalyzing,
        geocoder: (any ReverseGeocoding)?,
        map: OfflineWorldMap?,
        conditions: any AnalysisConditions,
        settings: OrganizationSettings,
        calendar: Calendar = .sortlyDefault,
        time: TimeSource = .live(),
        batchSize: Int = 50,
        foregroundOnlineBudget: Int? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.store = store
        self.reader = reader
        self.analyzer = analyzer
        self.geocoder = geocoder
        self.map = map
        self.conditions = conditions
        self.settings = settings
        self.calendar = calendar
        self.time = time
        self.batchSize = max(1, batchSize)
        self.foregroundOnlineBudget = foregroundOnlineBudget
    }

    public func update(settings: OrganizationSettings) { self.settings = settings }

    /// What runs without an explicit scope work on. First device test 15.11.: "nur 2026" at
    /// the start applied to the first run only; every later run suggested the whole library.
    public func storedScope() async throws -> OrganizationScope {
        try await store.value(OrganizationScope.self, forKey: Key.scope) ?? .all
    }

    public func setScope(_ scope: OrganizationScope) async throws {
        try await store.setValue(scope, forKey: Key.scope)
    }

    /// A trial run over one year analyses only the photos of that year (and the trips that
    /// touch it); the rest is looked at once the user takes in the whole library.
    static func dateRange(of scope: OrganizationScope, calendar: Calendar) -> Range<Date>? {
        guard case .year(let year) = scope,
              let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
        return start..<end
    }

    /// Pauses at the next batch boundary; `run` then returns with `.userPaused`.
    public func pause() { userPaused = true }

    /// Checked between online place lookups, so Pause, heat or low battery stop that stage
    /// within one request instead of after all of them. The lookups left over wait for the
    /// overnight refinement; a run in the app goes on with the photos.
    private func stopRequested() async -> Bool {
        if userPaused || Task.isCancelled { return true }
        if runMode == .refinement { return await conditions.pauseReason() != nil }
        switch await conditions.pace() {
        case .normal, .gentle: return false
        case .wait, .stop: return true
        }
    }

    /// `onWaiting`: the run waits for the device (hot, battery nearly empty) and goes on by
    /// itself; called with `nil` when it goes on.
    public func run(
        mode: Mode = .incremental,
        scope requested: OrganizationScope? = nil,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
        onWaiting: @escaping @Sendable (PauseReason?) -> Void = { _ in }
    ) async throws -> Report {
        userPaused = false
        runMode = mode
        var report = Report()
        let scope: OrganizationScope
        if let requested { scope = requested } else { scope = try await storedScope() }

        /// Asked before every photo. A run in the app never ends because of the device: it
        /// slows down when warm and waits when hot, then goes on by itself. Only Pause, the
        /// end of the app's time and the overnight refinement's rules end a run.
        func shouldStop() async -> PauseReason? {
            if userPaused { return .userPaused }
            if Task.isCancelled { return .timeBudget }
            if mode == .refinement { return await conditions.pauseReason() }
            var waitingFor: PauseReason?
            defer { if waitingFor != nil { onWaiting(nil) } }
            while true {
                switch await conditions.pace() {
                case .normal:
                    return nil
                case .gentle:
                    do { try await time.sleep(Self.gentleBreak) } catch { return .timeBudget }
                    return userPaused ? .userPaused : nil
                case .stop(let reason):
                    return reason
                case .wait(let reason):
                    if waitingFor != reason {
                        waitingFor = reason
                        onWaiting(reason)
                    }
                    do { try await time.sleep(Self.waitCheck) } catch { return .timeBudget }
                    if userPaused { return .userPaused }
                    if Task.isCancelled { return .timeBudget }
                }
            }
        }

        // 1. Inventory
        guard await reader.access().canRead else {
            report.pausedBecause = .accessRevoked
            return report
        }
        let assets = try await reader.fetchAssets(includeHidden: settings.privacy.includeHiddenAssets,
                                                  knownDetails: try await store.assetsWithFileDetails())
        report.newOrChanged = try await store.upsertAssets(assets).count
        report.removed = try await store.removeAssets(notIn: Set(assets.map(\.id)))
        let inventory = try await reader.currentInventory()
        try await store.saveInventory(inventory)
        onProgress(Progress(stage: .inventory, completed: assets.count, total: assets.count))
        report.completedStages.append(.inventory)
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }

        // 2. Patterns (pure computation over metadata, seconds even for large libraries)
        let all = try await store.allAssets()
        let corrections = try await store.value(TripCorrections.self, forKey: Key.tripCorrections) ?? TripCorrections()
        let answers = try await recurringPlaceAnswers()
        let tripAnalysis = TripDetector(configuration: settings.trips.advanced, calendar: calendar).analyse(in: all, corrections: corrections, places: answers)
        let detected = tripAnalysis.trips
        // Trips keep their identity when their photos change a little (an older photo
        // imported, the first one deleted): decisions and deleted albums stay attached.
        var known = try await store.value([TripIdentity].self, forKey: Key.tripIdentities) ?? []
        if known.isEmpty {
            // First run with identities: the trips of the last analysis are the starting point.
            known = (try await store.value([Trip].self, forKey: Key.trips) ?? []).map(TripIdentity.init)
        }
        var trips = TripIdentity.carryOver(detected, from: known)
        try await store.setValue(Self.mergedIdentities(known, trips, library: Set(all.map(\.id))), forKey: Key.tripIdentities)
        try await store.setValue(RecurringPlaceReport(tripAnalysis, trips: trips, answers: answers), forKey: Key.recurringPlaceReport)
        var frequent = FrequentPlaceDetector(configuration: settings.frequentPlaces.advanced, calendar: calendar).detect(in: all)
        for i in frequent.indices { frequent[i].userName = settings.frequentPlaces.names[frequent[i].id] }
        try await store.setValue(trips, forKey: Key.trips)
        try await store.setValue(frequent, forKey: Key.frequentPlaces)
        report.completedStages.append(.patterns)
        onProgress(Progress(stage: .patterns, completed: 1, total: 1))

        // The photos this run analyses: all of them, or one year and the trips that touch it.
        let range = Self.dateRange(of: scope, calendar: calendar)
        let scoped: [AssetSnapshot]
        if let range {
            let inYear = Set(all.filter { $0.creationDate.map(range.contains) ?? false }.map(\.id))
            let tripMembers = Set(trips.filter { !inYear.isDisjoint(with: $0.geotaggedAssetIDs) }.flatMap(\.geotaggedAssetIDs))
            scoped = all.filter { inYear.contains($0.id) || tripMembers.contains($0.id) }
        } else {
            scoped = all
        }

        // 3. Places
        let placeOutcome = try await resolvePlaces(scoped, trips: trips, frequent: frequent, refining: mode == .refinement, onProgress: onProgress)
        report.placesResolved = placeOutcome.resolved
        report.placesPendingOnline = placeOutcome.pendingOnline.count
        report.onlineRequests = placeOutcome.onlineRequests
        // Day trip or weekend is decided in the destination's days, once places know its time
        // zone (an evening in New York is already the next day in Munich).
        let zones = try await store.places().compactMapValues(\.components.timeZoneIdentifier)
        if !zones.isEmpty {
            let localTrips = TripDetector.inDestinationTime(trips, assets: Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }),
                                                            timeZones: zones, calendar: calendar)
            if localTrips != trips {
                trips = localTrips
                try await store.setValue(trips, forKey: Key.trips)
            }
        }
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }
        report.completedStages.append(.places)

        // 4. Content
        let peopleRequest = ContentAnalysisRequest(
            classify: settings.enabledAreas.contains(.imageCategories) || settings.enabledAreas.contains(.documents),
            detectFaces: settings.people.faceGroupingEnabled && settings.enabledAreas.contains(.peopleAndPets),
            detectAnimals: settings.people.petGroupingEnabled && settings.enabledAreas.contains(.peopleAndPets),
            featurePrint: true
        )
        let contentTotal = try await store.countNeedingAnalysis(version: Self.contentVersion, within: range)
        // Shown over the whole library: after a pause the count goes on from what is done
        // (first device test 15.11.: "1.450 von 14.332", then "2.700 von 12.708").
        let inRange = range.map { r in all.filter { $0.creationDate.map(r.contains) ?? false }.count } ?? all.count
        let contentBefore = max(0, inRange - contentTotal)
        if contentTotal > 0 {
            onProgress(Progress(stage: .content, completed: contentBefore, total: contentBefore + contentTotal))
        }
        // First results early: trips, countries and places need no image analysis. On a first
        // run (no suggestions yet) they are offered right away instead of after the image
        // analysis, which takes hours on a large library. The full set replaces them later;
        // suggestion ids are stable, so decisions made in between stay valid.
        if contentTotal > 0, try await latestProposals() == nil {
            let groups = try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
            _ = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope)
            report.earlyProposals = true
        }
        var contentDone = 0
        var cursor: AssetSnapshot?
        // Photos that could not be read in this run: tried again in a later run, not now.
        var deferred = Set<AssetID>()
        while true {
            if let reason = await shouldStop() { report.pausedBecause = reason; return report }
            var raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, limit: batchSize + deferred.count, olderThan: cursor, within: range)
            if raw.isEmpty, cursor != nil {
                // Past the oldest dated photo: one plain pass picks up photos without a date.
                cursor = nil
                raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, limit: batchSize + deferred.count, within: range)
            }
            let batch = raw.filter { !deferred.contains($0.id) }
            if batch.isEmpty { break }
            if let last = raw.last, last.creationDate != nil { cursor = last }
            var finished: [AssetID] = []
            var stopped: PauseReason?
            for asset in batch {
                // Checked per photo: heat, low battery or Pause stop within one image.
                if let reason = await shouldStop() { stopped = reason; break }
                do {
                    let result = try await analyzer.analyzeContent(asset, request: peopleRequest)
                    try await store.saveResult(result, kind: "content", asset: asset.id, version: Self.contentVersion)
                    finished.append(asset.id)
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        // Stopped, not unreadable: what is done stays done, the rest waits.
                        try await store.markAnalyzed(finished, version: Self.contentVersion)
                        throw CancellationError()
                    }
                    // Not readable right now (no local preview yet, still syncing): tried again
                    // in later runs, and given up only after a few of them.
                    let previous = try? await store.result(ContentAnalysis.self, kind: "content", asset: asset.id)
                    if let previous, previous.failedAttempts == nil {
                        // Read before and the image is unchanged (an edit drops the old result):
                        // the earlier labels stay valid.
                        finished.append(asset.id)
                        continue
                    }
                    let earlier = previous?.failedAttempts ?? 0
                    var failed = ContentAnalysis()
                    failed.failedAttempts = earlier + 1
                    try await store.saveResult(failed, kind: "content", asset: asset.id, version: Self.contentVersion)
                    if earlier + 1 >= ContentAnalysis.maxFailedAttempts { finished.append(asset.id) } else { deferred.insert(asset.id) }
                }
            }
            try await store.markAnalyzed(finished, version: Self.contentVersion)
            contentDone += finished.count
            report.contentAnalyzed += finished.count
            onProgress(Progress(stage: .content, completed: contentBefore + contentDone,
                                total: contentBefore + max(contentTotal, contentDone)))
            if let stopped { report.pausedBecause = stopped; return report }
        }
        report.completedStages.append(.content)

        // 5. Text
        let textOutcome = try await recognizeText(scoped, shouldStop: shouldStop, onProgress: onProgress)
        report.textRecognized = textOutcome.recognized
        report.textWaitingForOriginal = textOutcome.waiting
        if let reason = textOutcome.paused { report.pausedBecause = reason; return report }
        report.completedStages.append(.text)

        // 6. Groups
        let groups = try await groupObservations()
        report.completedStages.append(.groups)

        // 7. Proposals
        let snapshot = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope)
        report.proposals = snapshot.proposals.count
        report.completedStages.append(.proposals)
        onProgress(Progress(stage: .proposals, completed: snapshot.proposals.count, total: snapshot.proposals.count))
        return report
    }

    // MARK: Stages

    private func resolvePlaces(
        _ all: [AssetSnapshot], trips: [Trip], frequent: [FrequentPlace], refining: Bool,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> PlaceResolutionService.Outcome {
        let policy = PlaceResolutionPolicy(settings: settings)
        let existing = try await store.places()
        let tripMembers = Set(trips.flatMap(\.geotaggedAssetIDs))
        let frequentMembers = Set(frequent.flatMap(\.assetIDs))
        let requests: [PlaceResolutionService.Request] = all.compactMap { asset in
            guard let coordinate = asset.usableLocation else { return nil }
            if let place = existing[asset.id] {
                let pendingTown = policy.deepestLevel >= .locality && place.precisionMeters == nil
                let refine = refining && place.needsRefinement(to: policy.cellMeters(refining: true))
                guard pendingTown || refine else { return nil }
            }
            let priority = tripMembers.contains(asset.id) ? 10 : (frequentMembers.contains(asset.id) ? 5 : 0)
            return .init(assetID: asset.id, coordinate: coordinate, priority: priority)
        }
        guard !requests.isEmpty else { return .init() }
        let service = PlaceResolutionService(map: map, geocoder: geocoder, cache: store, policy: policy, time: time)
        let store = self.store
        // Counted over every photo with a location, not only this run's requests: a run that
        // starts again after a pause goes on from the real state instead of from zero.
        let total = all.filter { $0.usableLocation != nil }.count
        let before = max(0, total - requests.count)
        let budget = refining ? nil : foregroundOnlineBudget
        onProgress(Progress(stage: .places, completed: before, total: total))
        return try await service.resolve(requests, refining: refining, maxOnlineRequests: budget,
                                         shouldStop: { [weak self] in await self?.stopRequested() ?? true },
                                         onlineAllowed: { [weak self] in await self?.settings.privacy.allowOnlineGeocoding ?? false },
                                         progress: { processed in
                                             onProgress(Progress(stage: .places, completed: min(before + processed, total), total: total))
                                         }) { batch in
            try await store.setPlaces(batch)
        }
    }

    private func recognizeText(
        _ all: [AssetSnapshot],
        shouldStop: () async -> PauseReason?,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> (recognized: Int, waiting: Int, paused: PauseReason?) {
        guard settings.enabledAreas.contains(.screenshots) || settings.enabledAreas.contains(.documents) || settings.enabledAreas.contains(.messenger) else {
            return (0, 0, nil)
        }
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let done = try await store.results(TextResult.self, kind: "text", minimumVersion: Self.textVersion)
        try await remaskStoredTexts()
        let networkAllowed = await networkAllowedNow()
        let started = now()
        let needing = all.filter { asset in
            guard let content = contents[asset.id] else { return false }
            return content.needsTextRecognition(for: asset)
        }
        let candidates = needing.filter { asset in
            guard let previous = done[asset.id] else { return true }
            return previous.shouldRetry(networkAllowed: networkAllowed, now: started)
        }
        // Counted over all screenshots and documents, so a later run goes on from the real state.
        let textBefore = needing.count - candidates.count
        if !candidates.isEmpty {
            onProgress(Progress(stage: .text, completed: textBefore, total: needing.count))
        }
        var recognized = 0, waiting = 0
        let documents = DocumentAnalyzer()
        let screenshots = ScreenshotClassifier()
        for (index, asset) in candidates.enumerated() {
            if let reason = await shouldStop() { return (recognized, waiting, reason) }
            let previous = done[asset.id]
            let allowNetwork = networkAllowed ? await networkAllowedNow() : false
            // Needed the network and it is gone now: stays as it is for a later run.
            if let previous, previous.waitingForOriginal || previous.text?.source == .localPreview, !allowNetwork { continue }
            var result = TextResult()
            do {
                let text = try await analyzer.recognizeText(asset, allowNetwork: allowNetwork)
                result.document = documents.analyze(text: text.text)
                if asset.isScreenshotLike {
                    let labels = Set(contents[asset.id]?.labels.map(\.identifier) ?? [])
                    let classified = screenshots.classify(text: text.text, barcodePayloads: text.barcodePayloads, imageLabels: labels)
                    result.screenshotCategories = classified.categories.filter { $0.value >= .plausible }.map(\.key.rawValue).sorted()
                }
                // Analysis used the full text; only a minimized copy is kept on disk.
                var stored = text
                stored.text = TextMinimizer.storable(text.text)
                // Barcode contents (boarding passes, payment codes with IBAN, tickets with names)
                // only serve the classification above and are never kept.
                stored.barcodePayloads = []
                result.text = stored
                // The search index follows the new text; empty or withheld text removes the old one.
                if stored.text.isEmpty {
                    try await store.removeText(for: asset.id)
                } else {
                    try await store.indexText(stored.text, for: asset.id)
                }
                if text.source == .localPreview {
                    // Only the small preview was readable: read again from the original later.
                    result.retries = (previous?.retries ?? 0) + 1
                    result.lastAttempt = now()
                }
                recognized += 1
            } catch AnalysisError.originalNotAvailable {
                result = previous ?? TextResult()
                if allowNetwork {
                    // Even the download failed: a few more tries, spaced out, then it stays.
                    result.waitingForOriginal = false
                    result.retries = (previous?.retries ?? 0) + 1
                    result.lastAttempt = now()
                } else {
                    result.waitingForOriginal = true
                    waiting += 1
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // Unreadable now: what was read before stays; a few more tries in later runs.
                result = previous ?? TextResult()
                result.waitingForOriginal = false
                result.retries = (previous?.retries ?? 0) + 1
                result.lastAttempt = now()
            }
            try await store.saveResult(result, kind: "text", asset: asset.id, version: Self.textVersion)
            if index % 20 == 19 || index == candidates.count - 1 {
                onProgress(Progress(stage: .text, completed: textBefore + index + 1, total: needing.count))
            }
        }
        return (recognized, waiting, nil)
    }

    /// iCloud rule: originals only with consent, on Wi-Fi unless cellular is allowed. Read from
    /// the current settings before every photo, so switching the consent off or leaving Wi-Fi
    /// stops the next download at once, not only the next run (audit 2, 5.1).
    private func networkAllowedNow() async -> Bool {
        guard settings.privacy.allowNetworkForAnalysis else { return false }
        if settings.privacy.allowCellularDownloads { return true }
        let onWiFi = await conditions.isOnWiFi()
        // The settings may have changed while waiting for the network state.
        return onWiFi && settings.privacy.allowNetworkForAnalysis
    }

    /// Texts stored before the masks got stricter are masked again once (no new reading of
    /// the photos): the stored copy only ever loses detail.
    private func remaskStoredTexts() async throws {
        let done = try await store.value(Int.self, forKey: Key.textMaskVersion) ?? 1
        guard done < TextMinimizer.maskVersion else { return }
        let current = try await store.results(TextResult.self, kind: "text", minimumVersion: Self.textVersion)
        for (asset, var result) in try await store.results(TextResult.self, kind: "text") {
            guard let text = result.text?.text, !text.isEmpty else { continue }
            let masked = TextMinimizer.storable(text)
            guard masked != text else { continue }
            result.text?.text = masked
            // An outdated result keeps its old version, so it is still read again later.
            let version = current[asset] != nil ? Self.textVersion : 0
            try await store.saveResult(result, kind: "text", asset: asset, version: version)
            if masked.isEmpty {
                try await store.removeText(for: asset)
            } else {
                try await store.indexText(masked, for: asset)
            }
        }
        try await store.setValue(TextMinimizer.maskVersion, forKey: Key.textMaskVersion)
    }

    private func groupObservations() async throws -> [ObservationGroup] {
        guard settings.enabledAreas.contains(.peopleAndPets) else {
            try await store.setValue([ObservationGroup](), forKey: Key.groups)
            return []
        }
        let contents = try await store.results(ContentAnalysis.self, kind: "content")
        let feedback = try await store.value(GroupingFeedback.self, forKey: Key.groupingFeedback) ?? GroupingFeedback()
        let grouper = ObservationGrouper(distanceThreshold: settings.people.advanced.distanceThreshold, minGroupSize: settings.people.advanced.minGroupSize)
        var groups: [ObservationGroup] = []
        if settings.people.faceGroupingEnabled {
            let faces = contents.keys.sorted().flatMap { contents[$0]!.faces }
            groups += grouper.group(faces, kind: .person, feedback: feedback)
        }
        if settings.people.petGroupingEnabled {
            let animals = contents.keys.sorted().flatMap { contents[$0]!.animals }
            for kind in [GroupKind.dog, .cat, .otherAnimal] {
                groups += grouper.group(animals.filter { $0.kind == kind }.map(\.observation), kind: kind, feedback: feedback)
            }
        }
        try await store.setValue(groups, forKey: Key.groups)
        return groups
    }

    private func makeProposals(
        all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace],
        groups: [ObservationGroup], scope: OrganizationScope
    ) async throws -> ProposalSnapshot {
        // The albums are read again: a plan applied while this run was busy (minutes or hours
        // on a large library) created albums the matching must see, or it would suggest them
        // a second time.
        let generation = albumGeneration
        var inventory = inventory
        if let fresh = try? await reader.currentInventory(), fresh != inventory {
            inventory = fresh
            try await store.saveInventory(fresh)
        }
        let facts = try await currentFacts(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups)
            .filter { scope.includes($0, calendar: calendar) }
        let overrides = OverrideSet(try await store.overrides())
        let scopedIDs = Set(facts.map(\.id))
        let oftenHere = try await recurringPlaceReport()?.places ?? []
        let analysis = AnalysisSnapshot(
            facts: facts,
            trips: scope == .all ? trips : trips.filter { !scopedIDs.isDisjoint(with: $0.geotaggedAssetIDs) },
            frequentPlaces: scope == .all ? frequent : [],
            groups: groups,
            // Like trips: a place with photos in the trial year comes with all its photos.
            recurringPlaces: scope == .all ? oftenHere : oftenHere.filter { !scopedIDs.isDisjoint(with: $0.assetIDs) }
        )
        let proposals = ProposalEngine(settings: settings, calendar: calendar).proposals(for: analysis, overrides: overrides)
        var matches = AlbumMatcher().match(proposals, against: inventory, overrides: overrides,
                                           assignments: Self.assignments(try await store.managedAlbums()))
        if generation != albumGeneration {
            // A plan was applied while this ran: match against the albums as they are now, or
            // the suggestions would offer albums that were just created.
            matches = AlbumMatcher().match(proposals, against: try await store.loadInventory(), overrides: OverrideSet(try await store.overrides()),
                                           assignments: Self.assignments(try await store.managedAlbums()))
        }
        let snapshot = ProposalSnapshot(generatedAt: Date(), scope: scope, proposals: proposals, matches: matches)
        try await store.setValue(snapshot, forKey: Key.proposals)
        return snapshot
    }

    /// Facts for every asset from the stored results (also used by search and status).
    /// The trips the user split or merged (I07). Kept in time, so they hold for every
    /// later analysis; the next run applies them.
    public func tripCorrections() async throws -> TripCorrections {
        try await store.value(TripCorrections.self, forKey: Key.tripCorrections) ?? TripCorrections()
    }

    public func setTripCorrections(_ corrections: TripCorrections) async throws {
        try await store.setValue(corrections, forKey: Key.tripCorrections)
    }

    /// The user's answers to "Bist du hier öfter?". Kept by position, so they hold for every
    /// later analysis; the next run applies them.
    public func recurringPlaceAnswers() async throws -> RecurringPlaceAnswers {
        try await store.value(RecurringPlaceAnswers.self, forKey: Key.recurringPlaces) ?? RecurringPlaceAnswers()
    }

    public func setRecurringPlaceAnswers(_ answers: RecurringPlaceAnswers) async throws {
        try await store.setValue(answers, forKey: Key.recurringPlaces)
    }

    /// What the last analysis found about places visited again and again.
    public func recurringPlaceReport() async throws -> RecurringPlaceReport? {
        try await store.value(RecurringPlaceReport.self, forKey: Key.recurringPlaceReport)
    }

    public func currentFacts() async throws -> [AssetFacts] {
        try await currentFacts(
            all: try await store.allAssets(),
            inventory: try await store.loadInventory(),
            trips: try await store.value([Trip].self, forKey: Key.trips) ?? [],
            frequent: try await store.value([FrequentPlace].self, forKey: Key.frequentPlaces) ?? [],
            groups: try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
        )
    }

    private func currentFacts(all: [AssetSnapshot], inventory: CollectionInventory, trips: [Trip], frequent: [FrequentPlace], groups: [ObservationGroup]) async throws -> [AssetFacts] {
        FactsAssembler.assemble(
            assets: all,
            places: try await store.places(),
            contents: try await store.results(ContentAnalysis.self, kind: "content"),
            texts: try await store.results(TextResult.self, kind: "text"),
            trips: trips,
            frequentPlaces: frequent,
            groups: groups,
            inventory: inventory
        )
    }

    /// The remembered identities, updated with this run's trips. Identities of trips that are
    /// not detected right now stay while any of their photos is still in the library (a trip
    /// can come back when its photos sync again or a correction is undone).
    static func mergedIdentities(_ known: [TripIdentity], _ trips: [Trip], library: Set<AssetID>) -> [TripIdentity] {
        let current = Set(trips.map(\.id))
        return trips.map(TripIdentity.init) + known.filter { identity in
            !current.contains(identity.id) && identity.members.contains(where: library.contains)
        }
    }

    /// Suggestion → the album it was applied to, from the managed-album records.
    static func assignments(_ states: [ManagedAlbumState]) -> [SortlyID: CollectionID] {
        Dictionary(states.flatMap { state in state.allSourceIDs.map { ($0, state.albumID) } }, uniquingKeysWith: { first, _ in first })
    }

    public func latestProposals() async throws -> ProposalSnapshot? {
        try await store.value(ProposalSnapshot.self, forKey: Key.proposals)
    }

    /// Re-runs only the album matching against the stored inventory and overrides, after
    /// albums were created or the user said an album does not fit. The suggestions then show
    /// the right state at once instead of after the next analysis.
    public func rematch() async throws -> ProposalSnapshot? {
        albumGeneration += 1
        guard var snapshot = try await latestProposals() else { return nil }
        let inventory = try await store.loadInventory()
        let overrides = OverrideSet(try await store.overrides())
        snapshot.matches = AlbumMatcher().match(snapshot.proposals, against: inventory, overrides: overrides,
                                                assignments: Self.assignments(try await store.managedAlbums()))
        try await store.setValue(snapshot, forKey: Key.proposals)
        return snapshot
    }
}
