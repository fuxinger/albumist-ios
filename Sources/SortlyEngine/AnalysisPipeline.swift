import Foundation
import Synchronization
import SortlyCore
import SortlyStore

/// Pause for one run, set by the app without waiting for the pipeline actor. A Pause tapped
/// while the run is still starting is not lost (the run used to clear the flag when it began),
/// and a Pause that arrives after its run ended cannot stop the next one.
public final class AnalysisRunControl: Sendable {
    private let paused = Mutex(false)
    public init() {}
    public func pause() { paused.withLock { $0 = true } }
    public var isPaused: Bool { paused.withLock { $0 } }
}

/// Snapshot of the latest proposals, stored so the app opens instantly (prompt §14).
public struct ProposalSnapshot: Sendable, Codable, Hashable {
    public var generatedAt: Date
    public var scope: OrganizationScope
    public var proposals: [AlbumProposal]
    /// Matches of the shown and of the dismissed suggestions.
    public var matches: [SortlyID: MatchResult]
    /// Suggestions the user dismissed: never shown, but an own album that fits one still
    /// counts as sorted (`Suggestions`).
    public var dismissed: [AlbumProposal] = []
    /// Albums that stand for photos without an album of their own (`StandIn`).
    public var standIns: [StandIn] = []

    public init(generatedAt: Date, scope: OrganizationScope, proposals: [AlbumProposal], matches: [SortlyID: MatchResult],
                dismissed: [AlbumProposal] = [], standIns: [StandIn] = []) {
        self.generatedAt = generatedAt
        self.scope = scope
        self.proposals = proposals
        self.matches = matches
        self.dismissed = dismissed
        self.standIns = standIns
    }

    enum CodingKeys: String, CodingKey { case generatedAt, scope, proposals, matches, dismissed, standIns }

    /// Snapshots stored before dismissed suggestions and stand-ins were kept still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        scope = try c.decode(OrganizationScope.self, forKey: .scope)
        proposals = try c.decode([AlbumProposal].self, forKey: .proposals)
        matches = try c.decode([SortlyID: MatchResult].self, forKey: .matches)
        dismissed = try c.decodeIfPresent([AlbumProposal].self, forKey: .dismissed) ?? []
        standIns = try c.decodeIfPresent([StandIn].self, forKey: .standIns) ?? []
    }
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
        /// Set while the stage waits for Apple's geocoder (its limit of about 40 lookups a
        /// minute, or after it refused): about how long the wait still takes. Said every 2 s,
        /// so the card can show the wait instead of a count that stands for up to a minute;
        /// `nil` again when the lookups go on.
        public var waitLeft: Duration? = nil

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
        /// How long reading the texts took in this run (diagnostic report: photos per minute).
        public var textSeconds: Double = 0
        public var proposals = 0
        /// Vision failed for several photos in a row (not the photos' fault, e.g. no graphics
        /// hardware in the background): the run stopped without counting those against them.
        public var analyzerUnavailable = false
        /// Apple's geocoder kept refusing: the remaining town names wait for a later run.
        public var placesThrottled = false

        public var isComplete: Bool { pausedBecause == nil && completedStages.count == Stage.allCases.count }

        public init() {}
    }

    public static let contentVersion = 1
    /// 2: screenshot categories with whole-word flight rules and short keywords as whole words
    /// (first device test 15.11.); every stored screenshot is read once more.
    public static let textVersion = 2
    /// Analyzer errors in a row after which a run stops instead of going through every photo:
    /// when Vision itself fails, each further photo would fail the same way.
    static let analyzerFailureLimit = 5
    /// How long a run in the app waits for Apple's geocoder after it refused (once), before the
    /// remaining town names are left for a later run. Without a limit, four growing waits per
    /// place cell could hold step 3 for hours while the bar did not move.
    static let foregroundRateLimitWait: Duration = .seconds(30)

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
        /// Photos taken where the user lives (`TripAnalysis.atHome`), from the last analysis.
        static let home = "analysis.home"
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
    /// When a run in the app last asked Apple for town names and was left with towns still
    /// waiting (Apple refused, or the run's budget ran out). A run within the hour after it
    /// (Fortsetzen after a Pause, a restart) does not ask again: the lookups and Apple's waits
    /// held "Orte werden bestimmt" for a minute or more before the run got back to where it was
    /// (device test 15.11.: "es dauert lange, bis die App nach Pause weiterläuft"). The towns
    /// still missing come with the overnight refinement or a run after the hour.
    /// A round that got every town it asked for sets nothing: photos added after it (new trip
    /// photos, an import) get their towns in the next run. Otherwise one early lookup kept
    /// every later photo at region names for an hour (UI run 43779950348: "Latium" instead of
    /// "Rom", the Iceland trip "Reykjavík" instead of "Island", 5 instead of 22 towns).
    private var lastForegroundOnlineLookup: Date?
    static let foregroundOnlineCooldown: TimeInterval = 60 * 60

    /// "Analyse neu aufbauen" cleared the place cache: the next run asks Apple again at once,
    /// or the rebuilt trips would get no town names for an hour.
    public func forgetRecentOnlineLookups() {
        lastForegroundOnlineLookup = nil
    }
    public private(set) var settings: OrganizationSettings
    /// The run in progress: `pause()` reaches it through its control.
    private var activeControl: AnalysisRunControl?
    /// One run at a time. The actor alone does not ensure that: a second run would interleave
    /// with the first at every `await`, analyse the same photos and count them twice.
    private var runInProgress = false
    private var queuedRuns: [CheckedContinuation<Void, Never>] = []
    /// The mode of the run in progress (online place lookups ask it between requests).
    private var runMode: Mode = .incremental
    /// Told when the run in progress waits for the device, and when it goes on.
    private var runOnWaiting: @Sendable (PauseReason?) -> Void = { _ in }
    /// The photo access the run in progress started with.
    private var runAccess: LibraryAccess = .notDetermined
    /// A warm device: break after every photo. Waiting: how often the device is asked again.
    static let gentleBreak: Duration = .milliseconds(250)
    static let waitCheck: Duration = .seconds(2)
    /// Photos looked at side by side at full speed (image loading, which waits for the disk,
    /// overlaps with Vision); half of them when the device is warm, none while it waits.
    private let contentLanes: Int
    /// Text recognition reads larger images and is heavier: fewer side by side.
    private let textLanes: Int

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
        contentLanes: Int = 4,
        textLanes: Int = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.contentLanes = max(1, contentLanes)
        self.textLanes = max(1, textLanes)
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

    /// Pauses the run in progress at its next check; `run` then returns with `.userPaused`.
    /// Without a run in progress nothing happens (the next run is not affected).
    public func pause() { activeControl?.pause() }

    private func beginRun() async {
        guard runInProgress else {
            runInProgress = true
            return
        }
        await withCheckedContinuation { queuedRuns.append($0) }
    }

    private func endRun() {
        // Handed straight to the next waiting run, so no other caller slips in between.
        if queuedRuns.isEmpty { runInProgress = false } else { queuedRuns.removeFirst().resume() }
    }

    /// Checked between online place lookups, so Pause, heat or low battery stop that stage
    /// within one request instead of after all of them. The lookups left over wait for the
    /// overnight refinement; a run in the app goes on with the photos.
    private func stopRequested() async -> Bool {
        if activeControl?.isPaused == true || Task.isCancelled { return true }
        if runMode == .refinement { return await conditions.pauseReason() != nil }
        switch await conditions.pace() {
        case .normal, .gentle: return false
        case .wait, .stop: return true
        }
    }

    /// Asked before every photo: whether the run stops, and how many photos may be in work
    /// at once. A run in the app never ends because of the device: it slows down when warm
    /// and waits when hot, then goes on by itself. Only Pause, the end of the app's time and
    /// the overnight refinement's rules end a run.
    private func admission(lanes: Int) async -> (stop: PauseReason?, width: Int) {
        guard let control = activeControl else { return (.timeBudget, 0) }
        if control.isPaused { return (.userPaused, 0) }
        if Task.isCancelled { return (.timeBudget, 0) }
        if runMode == .refinement {
            if let reason = await conditions.pauseReason() { return (reason, 0) }
            return (nil, lanes)
        }
        let onWaiting = runOnWaiting
        var waitingFor: PauseReason?
        defer { if waitingFor != nil { onWaiting(nil) } }
        while true {
            switch await conditions.pace() {
            case .normal:
                return (nil, lanes)
            case .gentle:
                do { try await time.sleep(Self.gentleBreak) } catch { return (.timeBudget, 0) }
                return control.isPaused ? (.userPaused, 0) : (nil, max(1, lanes / 2))
            case .stop(let reason):
                return (reason, 0)
            case .wait(let reason):
                if waitingFor != reason {
                    waitingFor = reason
                    onWaiting(reason)
                }
                do { try await time.sleep(Self.waitCheck) } catch { return (.timeBudget, 0) }
                if control.isPaused { return (.userPaused, 0) }
                if Task.isCancelled { return (.timeBudget, 0) }
            }
        }
    }

    /// Access taken away or changed in Settings while the run is busy: photos cannot be read
    /// (or other ones can), and must not be marked unreadable for that. The run ends; the
    /// next one reads the library as it is then.
    private func accessChanged() async -> Bool {
        await reader.access() != runAccess
    }

    /// `onWaiting`: the run waits for the device (hot, battery nearly empty) and goes on by
    /// itself; called with `nil` when it goes on.
    /// `control`: the app's handle to pause exactly this run. A run that is called while
    /// another one is in progress waits until that one has ended.
    public func run(
        mode: Mode = .incremental,
        scope requested: OrganizationScope? = nil,
        control: AnalysisRunControl = AnalysisRunControl(),
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
        onWaiting: @escaping @Sendable (PauseReason?) -> Void = { _ in }
    ) async throws -> Report {
        await beginRun()
        defer { endRun() }
        activeControl = control
        defer { activeControl = nil }
        runMode = mode
        var report = Report()
        // Paused or ended while it waited for its turn: nothing is read.
        if control.isPaused { report.pausedBecause = .userPaused; return report }
        if Task.isCancelled { report.pausedBecause = .timeBudget; return report }
        let scope: OrganizationScope
        if let requested { scope = requested } else { scope = try await storedScope() }

        runOnWaiting = onWaiting
        func shouldStop() async -> PauseReason? { await admission(lanes: 1).stop }

        // 1. Inventory
        runAccess = await reader.access()
        guard runAccess.canRead else {
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
        // Said before the trips are computed, or the card stands at "Mediathek wird gelesen ·
        // N von N" meanwhile (simulated full run: step 2 was first shown when it was done).
        onProgress(Progress(stage: .patterns, completed: 0, total: 1))
        let all = try await store.allAssets()
        let corrections = try await store.value(TripCorrections.self, forKey: Key.tripCorrections, defaults: TripCorrections()) ?? TripCorrections()
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
        try await store.setValue(tripAnalysis.atHome, forKey: Key.home)
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
        report.placesThrottled = placeOutcome.stoppedBecauseThrottled
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
        // Said also when nothing is left to look at: every stage says when it begins, or the
        // card kept showing the stage before ("Orte werden bestimmt · 1.600 von 1.600") while
        // the run went on (device test 15.11.: "jetzt hängt es hier").
        onProgress(Progress(stage: .content, completed: contentBefore, total: contentBefore + contentTotal))
        // First results early: trips, countries and places need no image analysis. On a first
        // run (no suggestions yet) they are offered right away instead of after the image
        // analysis, which takes hours on a large library. The full set replaces them later;
        // suggestion ids are stable, so decisions made in between stay valid.
        if contentTotal > 0, try await latestProposals() == nil {
            let groups = try await store.value([ObservationGroup].self, forKey: Key.groups) ?? []
            _ = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope)
            report.earlyProposals = true
        }
        // Photos still to analyse that have a result of this version already: their labels
        // were saved by a run that ended before it marked them (or only their place or date
        // changed since), so they are not looked at twice; or they could not be read before.
        let stored = contentTotal > 0
            ? try await store.pendingResults(ContentAnalysis.self, kind: "content", version: Self.contentVersion, within: range)
            : [:]
        var contentDone = 0
        var cursor: AssetSnapshot?
        // Photos that are not read in this run: they could not be read (tried again in a later
        // run, spaced out), or the analyzer failed on them.
        var deferred = Set<AssetID>()
        // Analyzer errors in a row, not counted against the photos yet: only when a later photo
        // works was it the photo. When every photo fails, the analyzer is the problem.
        var suspects: [AssetID] = []
        let analyzer = self.analyzer
        while true {
            if let reason = await shouldStop() { report.pausedBecause = reason; return report }
            if await accessChanged() { report.pausedBecause = .accessRevoked; return report }
            // Deferred photos can come back only without a cursor (behind it they are past).
            let limit = batchSize + (cursor == nil ? deferred.count : 0)
            var raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, limit: limit, olderThan: cursor, within: range)
            if raw.isEmpty, cursor != nil {
                // Past the oldest dated photo: one plain pass picks up photos without a date.
                cursor = nil
                raw = try await store.assetsNeedingAnalysis(version: Self.contentVersion, limit: batchSize + deferred.count, within: range)
            }
            var batch = raw.filter { !deferred.contains($0.id) }
            if batch.isEmpty { break }
            if let last = raw.last, last.creationDate != nil { cursor = last }
            var finished: [AssetID] = []
            // Saved with the batch's marks in one transaction.
            var results: [(AssetID, ContentAnalysis)] = []
            var analyzed = 0
            var stopped: PauseReason?
            var cancelled = false
            // Saved and shown at least once a second: a batch of 50 photos took 5 s, on a warm
            // device 18 s, and the count stood still meanwhile (simulated full run). The photos
            // after the cut stay for the next batch.
            let batchStart = now()
            var cut = false
            var next = 0
            // Decided without looking at the image: labels stored already, or a photo that
            // could not be read a short while ago (not again in this run).
            batch = batch.filter { asset in
                guard let previous = stored[asset.id] else { return true }
                if previous.failedAttempts == nil {
                    finished.append(asset.id)
                } else if !previous.isDueForRetry(now: now()) {
                    deferred.insert(asset.id)
                } else {
                    return true
                }
                return false
            }
            await analyzer.willAnalyze(Array(batch.prefix(2 * contentLanes)))
            try await withThrowingTaskGroup(of: (AssetSnapshot, Result<ContentAnalysis, any Error>).self) { group in
                var inFlight = 0
                var width = contentLanes
                while true {
                    // Fill the lanes. Heat, low battery or Pause are checked before every
                    // photo, so a stop takes effect within one photo per lane.
                    while stopped == nil, !cancelled, next < batch.count, inFlight < width {
                        if next > 0, now().timeIntervalSince(batchStart) >= 1 { cut = true; break }
                        let (reason, lanes) = await admission(lanes: contentLanes)
                        if let reason { stopped = reason; break }
                        width = lanes
                        guard inFlight < width else { break }
                        let asset = batch[next]
                        if next + 2 * contentLanes < batch.count {
                            await analyzer.willAnalyze([batch[next + 2 * contentLanes]])
                        }
                        next += 1
                        inFlight += 1
                        group.addTask {
                            do {
                                return (asset, .success(try await analyzer.analyzeContent(asset, request: peopleRequest)))
                            } catch {
                                return (asset, .failure(error))
                            }
                        }
                    }
                    guard let (asset, outcome) = try await group.next() else { break }
                    inFlight -= 1
                    switch outcome {
                    case .success(let result):
                        results.append((asset.id, result))
                        finished.append(asset.id)
                        analyzed += 1
                        // The analyzer works: the photos it failed on just before were the problem.
                        for id in suspects {
                            if try await recordContentFailure(id) { finished.append(id) }
                        }
                        suspects = []
                    case .failure(let error):
                        deferred.insert(asset.id)
                        if error is CancellationError || Task.isCancelled {
                            // Stopped, not unreadable: what is done stays done, the rest waits.
                            cancelled = true
                        } else if !(error is AnalysisError) {
                            suspects.append(asset.id)
                            if suspects.count >= Self.analyzerFailureLimit, stopped == nil {
                                // Vision itself fails: going through every photo would mark all
                                // of them as unreadable. The run ends; the photos wait untouched.
                                report.analyzerUnavailable = true
                                stopped = .timeBudget
                            }
                        } else if await accessChanged() {
                            // Not the photo: the access was taken away. Nothing is counted.
                            stopped = .accessRevoked
                        } else if try await recordContentFailure(asset.id) {
                            // Not readable right now (no local preview yet, still syncing): tried
                            // again in later runs, and given up only after a few of them.
                            finished.append(asset.id)
                        }
                    }
                }
            }
            try await store.saveResults(results, kind: "content", version: Self.contentVersion, markingAnalyzed: finished)
            if cancelled { throw CancellationError() }
            if cut {
                // Goes on behind the last photo looked at (same order as the store's query);
                // without a date, from the start of the photos still to analyse.
                let last = batch[next - 1]
                cursor = last.creationDate != nil ? last : nil
            }
            contentDone += finished.count
            report.contentAnalyzed += analyzed
            onProgress(Progress(stage: .content, completed: contentBefore + contentDone,
                                total: contentBefore + max(contentTotal, contentDone)))
            if let stopped { report.pausedBecause = stopped; return report }
        }
        report.completedStages.append(.content)

        // 5. Text
        let textStart = now()
        let textOutcome = try await recognizeText(scoped, onProgress: onProgress)
        report.textSeconds = now().timeIntervalSince(textStart)
        report.textRecognized = textOutcome.recognized
        report.textWaitingForOriginal = textOutcome.waiting
        report.analyzerUnavailable = report.analyzerUnavailable || textOutcome.analyzerUnavailable
        if let reason = textOutcome.paused { report.pausedBecause = reason; return report }
        report.completedStages.append(.text)

        // 6. Groups
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }
        onProgress(Progress(stage: .groups, completed: 0, total: 0))
        let groups = try await groupObservations()
        report.completedStages.append(.groups)

        // 7. Proposals
        if let reason = await shouldStop() { report.pausedBecause = reason; return report }
        onProgress(Progress(stage: .proposals, completed: 0, total: 0))
        let snapshot = try await makeProposals(all: all, inventory: inventory, trips: trips, frequent: frequent, groups: groups, scope: scope)
        report.proposals = snapshot.proposals.count
        report.completedStages.append(.proposals)
        onProgress(Progress(stage: .proposals, completed: snapshot.proposals.count, total: snapshot.proposals.count))
        return report
    }

    // MARK: Stages

    /// Counts a failed read against a photo. Returns true when the photo is done with: read
    /// before (the image is unchanged, its earlier labels stay valid) or given up.
    private func recordContentFailure(_ id: AssetID) async throws -> Bool {
        let previous = try? await store.result(ContentAnalysis.self, kind: "content", asset: id)
        if let previous, previous.failedAttempts == nil { return true }
        let attempts = (previous?.failedAttempts ?? 0) + 1
        var failed = ContentAnalysis()
        failed.failedAttempts = attempts
        failed.lastAttempt = now()
        try await store.saveResult(failed, kind: "content", asset: id, version: Self.contentVersion)
        return attempts >= ContentAnalysis.maxFailedAttempts
    }

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
        let askedRecently = lastForegroundOnlineLookup.map { now().timeIntervalSince($0) < Self.foregroundOnlineCooldown } ?? false
        let budget = refining ? nil : (askedRecently ? 0 : foregroundOnlineBudget)
        onProgress(Progress(stage: .places, completed: before, total: total))
        // The count last shown, repeated with the time left while the run waits for the geocoder.
        let shown = Mutex(before)
        let outcome = try await service.resolve(requests, refining: refining, maxOnlineRequests: budget,
                                         maxRateLimitWait: refining ? nil : Self.foregroundRateLimitWait,
                                         shouldStop: { [weak self] in await self?.stopRequested() ?? true },
                                         onlineAllowed: { [weak self] in await self?.settings.privacy.allowOnlineGeocoding ?? false },
                                         progress: { processed in
                                             let completed = min(before + processed, total)
                                             shown.withLock { $0 = completed }
                                             onProgress(Progress(stage: .places, completed: completed, total: total))
                                         },
                                         waiting: { left in
                                             onProgress(Progress(stage: .places, completed: shown.withLock { $0 }, total: total, waitLeft: left))
                                         }) { batch in
            try await store.setPlaces(batch)
        }
        if !refining, outcome.onlineRequests > 0, !outcome.pendingOnline.isEmpty { lastForegroundOnlineLookup = now() }
        return outcome
    }

    struct TextOutcome {
        var recognized = 0
        var waiting = 0
        var paused: PauseReason?
        var analyzerUnavailable = false
    }

    private func recognizeText(
        _ all: [AssetSnapshot],
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> TextOutcome {
        var outcome = TextOutcome()
        guard settings.enabledAreas.contains(.screenshots) || settings.enabledAreas.contains(.documents) || settings.enabledAreas.contains(.messenger) else {
            return outcome
        }
        // Masked first: a read that fails below writes the earlier result back, which must be
        // the masked one.
        try await remaskStoredTexts()
        let done = try await store.results(TextResult.self, kind: "text", minimumVersion: Self.textVersion)
        let networkAllowed = await networkAllowedNow()
        let started = now()
        let needing: [AssetSnapshot]
        var screenshotLabels: [AssetID: Set<String>] = [:]
        do {
            // Every photo's labels are read once here and let go before the slow part: on a
            // large library they are the biggest thing this stage would hold for hours of OCR.
            let contents = try await store.results(ContentAnalysis.self, kind: "content")
            needing = all.filter { asset in
                guard let content = contents[asset.id] else { return false }
                return content.needsTextRecognition(for: asset)
            }
            for asset in needing where asset.isScreenshotLike {
                screenshotLabels[asset.id] = Set(contents[asset.id]?.labels.map(\.identifier) ?? [])
            }
        }
        let candidates = needing.filter { asset in
            guard let previous = done[asset.id] else { return true }
            return previous.shouldRetry(networkAllowed: networkAllowed, now: started)
        }
        // Counted over all screenshots and documents, so a later run goes on from the real state.
        let textBefore = needing.count - candidates.count
        // Said as soon as the count is known, also when nothing is left to read. A "0" said
        // before the count put the bar of a run that goes on in this step below where the
        // paused run had got to (simulated full run: 86 % back to 80 %).
        onProgress(Progress(stage: .text, completed: textBefore, total: needing.count))
        let documents = DocumentAnalyzer()
        let screenshots = ScreenshotClassifier()
        let analyzer = self.analyzer
        // Analyzer errors in a row, not counted against the photos yet (see the content stage).
        var suspects: [AssetID] = []
        var processed = 0
        var lastShown = now()
        // The count moves with every photo that takes time (device test 15.11.: shown only
        // every 20 photos, the stage looked stuck), and in steps of 20 when they go fast.
        func counted() {
            processed += 1
            let time = now()
            if processed % 20 == 0 || processed == candidates.count || time.timeIntervalSince(lastShown) >= 1 {
                lastShown = time
                onProgress(Progress(stage: .text, completed: textBefore + processed, total: needing.count))
            }
        }
        try await withThrowingTaskGroup(of: (AssetSnapshot, Bool, Result<TextAnalysis, any Error>).self) { group in
            var next = 0
            var inFlight = 0
            var width = textLanes
            var cancelled = false
            // A read that may download an original is in work: it goes alone, so leaving
            // Wi-Fi or switching off the consent applies to the very next photo (audit 2, 5.1).
            var downloading = false
            while true {
                while outcome.paused == nil, !cancelled, !downloading, next < candidates.count, inFlight < width {
                    let asset = candidates[next]
                    let previous = done[asset.id]
                    let allowNetwork = networkAllowed ? await networkAllowedNow() : false
                    // Needed the network and it is gone now: stays as it is for a later run.
                    if let previous, previous.waitingForOriginal || previous.text?.source == .localPreview, !allowNetwork {
                        next += 1
                        counted()
                        continue
                    }
                    if allowNetwork && inFlight > 0 { break }
                    let (reason, lanes) = await admission(lanes: textLanes)
                    if let reason { outcome.paused = reason; break }
                    width = lanes
                    guard inFlight < width else { break }
                    next += 1
                    downloading = allowNetwork
                    inFlight += 1
                    group.addTask {
                        do {
                            return (asset, allowNetwork, .success(try await analyzer.recognizeText(asset, allowNetwork: allowNetwork)))
                        } catch {
                            return (asset, allowNetwork, .failure(error))
                        }
                    }
                }
                guard let (asset, allowNetwork, read) = try await group.next() else { break }
                inFlight -= 1
                if allowNetwork { downloading = false }
                let previous = done[asset.id]
                var result = TextResult()
                switch read {
                case .success(let text):
                    result.document = documents.analyze(text: text.text)
                    if asset.isScreenshotLike {
                        let labels = screenshotLabels[asset.id] ?? []
                        let classified = screenshots.classify(text: text.text, barcodePayloads: text.barcodePayloads, imageLabels: labels)
                        result.screenshotCategories = classified.categories.filter { $0.value >= .plausible }.map(\.key.rawValue).sorted()
                    }
                    // Analysis used the full text; only a minimized copy is kept on disk.
                    var stored = text
                    stored.text = TextMinimizer.storable(text.text)
                    // Barcode contents (boarding passes, payment codes with IBAN, tickets with
                    // names) only serve the classification above and are never kept.
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
                    outcome.recognized += 1
                    // The analyzer works: the photos it failed on just before were the problem.
                    for id in suspects { try await recordTextFailure(id, previous: done[id]) }
                    suspects = []
                case .failure(AnalysisError.originalNotAvailable):
                    result = previous ?? TextResult()
                    if allowNetwork {
                        // Even the download failed: a few more tries, spaced out, then it stays.
                        result.waitingForOriginal = false
                        result.retries = (previous?.retries ?? 0) + 1
                        result.lastAttempt = now()
                    } else {
                        result.waitingForOriginal = true
                        outcome.waiting += 1
                    }
                case .failure(let error):
                    if error is CancellationError || Task.isCancelled {
                        cancelled = true
                        continue
                    }
                    if !(error is AnalysisError) {
                        // Vision failed, maybe not because of this photo: nothing is counted yet.
                        suspects.append(asset.id)
                        counted()
                        if suspects.count >= Self.analyzerFailureLimit, outcome.paused == nil {
                            outcome.analyzerUnavailable = true
                            outcome.paused = .timeBudget
                        }
                        continue
                    }
                    if await accessChanged() {
                        if outcome.paused == nil { outcome.paused = .accessRevoked }
                        continue
                    }
                    // Unreadable now: what was read before stays; a few more tries in later runs.
                    result = previous ?? TextResult()
                    result.waitingForOriginal = false
                    result.retries = (previous?.retries ?? 0) + 1
                    result.lastAttempt = now()
                }
                try await store.saveResult(result, kind: "text", asset: asset.id, version: Self.textVersion)
                counted()
            }
            if cancelled { throw CancellationError() }
        }
        return outcome
    }

    /// One more unsuccessful read of a photo's text: what was read before stays, and it is
    /// tried again later, spaced out (see `TextResult.shouldRetry`).
    private func recordTextFailure(_ id: AssetID, previous: TextResult?) async throws {
        var result = previous ?? TextResult()
        result.waitingForOriginal = false
        result.retries = (previous?.retries ?? 0) + 1
        result.lastAttempt = now()
        try await store.saveResult(result, kind: "text", asset: id, version: Self.textVersion)
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
        let feedback = try await store.value(GroupingFeedback.self, forKey: Key.groupingFeedback, defaults: GroupingFeedback()) ?? GroupingFeedback()
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
        let suggestions = ProposalEngine(settings: settings, calendar: calendar).suggestions(for: analysis, overrides: overrides)
        var matches = Self.match(suggestions.open, dismissed: suggestions.dismissed, against: inventory, overrides: overrides,
                                 assignments: Self.assignments(try await store.managedAlbums()))
        if generation != albumGeneration {
            // A plan was applied while this ran: match against the albums as they are now, or
            // the suggestions would offer albums that were just created.
            matches = Self.match(suggestions.open, dismissed: suggestions.dismissed, against: try await store.loadInventory(),
                                 overrides: OverrideSet(try await store.overrides()), assignments: Self.assignments(try await store.managedAlbums()))
        }
        let snapshot = ProposalSnapshot(generatedAt: now(), scope: scope, proposals: suggestions.open, matches: matches,
                                        dismissed: suggestions.dismissed, standIns: suggestions.standIns)
        try await store.setValue(snapshot, forKey: Key.proposals)
        return snapshot
    }

    /// The shown suggestions are matched on their own, as always. The dismissed ones are
    /// matched together with them, so an album that spans several trips stays a broader
    /// collection for a dismissed trip too; only their results are taken from that pass.
    static func match(_ open: [AlbumProposal], dismissed: [AlbumProposal], against inventory: CollectionInventory,
                      overrides: OverrideSet, assignments: [SortlyID: CollectionID]) -> [SortlyID: MatchResult] {
        var matches = AlbumMatcher().match(open, against: inventory, overrides: overrides, assignments: assignments)
        guard !dismissed.isEmpty else { return matches }
        let all = AlbumMatcher().match(open + dismissed, against: inventory, overrides: overrides, assignments: assignments)
        for p in dismissed { matches[p.id] = all[p.id] }
        return matches
    }

    /// Facts for every asset from the stored results (also used by search and status).
    /// The trips the user split or merged (I07). Kept in time, so they hold for every
    /// later analysis; the next run applies them.
    public func tripCorrections() async throws -> TripCorrections {
        try await store.value(TripCorrections.self, forKey: Key.tripCorrections, defaults: TripCorrections()) ?? TripCorrections()
    }

    public func setTripCorrections(_ corrections: TripCorrections) async throws {
        try await store.setValue(corrections, forKey: Key.tripCorrections)
    }

    /// The user's answers to "Bist du hier öfter?". Kept by position, so they hold for every
    /// later analysis; the next run applies them.
    public func recurringPlaceAnswers() async throws -> RecurringPlaceAnswers {
        try await store.value(RecurringPlaceAnswers.self, forKey: Key.recurringPlaces, defaults: RecurringPlaceAnswers()) ?? RecurringPlaceAnswers()
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
            inventory: inventory,
            home: try await store.value(Set<AssetID>.self, forKey: Key.home) ?? []
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
        snapshot.matches = Self.match(snapshot.proposals, dismissed: snapshot.dismissed, against: inventory, overrides: overrides,
                                      assignments: Self.assignments(try await store.managedAlbums()))
        try await store.setValue(snapshot, forKey: Key.proposals)
        return snapshot
    }
}
