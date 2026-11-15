import Foundation
import Observation
import SortlyCore
import SortlyEngine
import SortlyStore
import SortlyWorldMap

/// App state and use cases. Views read it; all work happens in the core/engine actors.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case failed(String)
    }

    struct AnalysisState: Equatable {
        /// First run, a run that goes on after an interruption, or a check for new photos
        /// after everything was analysed once (the card shows each one differently).
        enum Kind: Equatable { case first, resume, check }

        var isRunning = false
        var stage: AnalysisPipeline.Stage?
        var completed = 0
        var total = 0
        var lastReport: AnalysisPipeline.Report?
        var lastRun: Date?
        var kind: Kind = .first
        /// The device asked for a break (very warm, battery nearly empty); the run goes on by
        /// itself (first device test 15.11.: a warm iPhone ended the analysis for good).
        var waiting: PauseReason?
        /// Where an unfinished earlier run got to. A run that goes on shows this instead of
        /// "Schritt 1" again until it is back there (first device test 15.11.).
        var resumeFrom: AnalysisMarker.Point?
        /// The last run ended before it was done without the user pausing it: opening the
        /// app again goes on by itself.
        var needsResume = false

        var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }
        /// Progress over all stages: one bar that fills once instead of restarting per stage.
        var overall: Double {
            stage.map { AnalysisPipeline.Progress.overall(stage: $0, completed: completed, total: total) } ?? 0
        }
        /// Still on the quick first steps of a run that goes on from further ahead.
        var isCatchingUp: Bool {
            guard let resumeFrom else { return false }
            return (stage?.number ?? 0) < resumeFrom.stage
        }
        /// The bar: never below where the interrupted run had got to.
        var shownOverall: Double {
            isCatchingUp ? max(overall, resumeFrom?.overall ?? 0) : overall
        }
        /// Photos still to look at in the current stage (images or texts).
        var remaining: Int { max(0, total - completed) }
    }

    /// How many photos (in the chosen part of the library) are analysed: shown on the card,
    /// so "Analyse aktuell" says what it means (first device test 15.11.).
    struct AnalysisCounts: Equatable {
        var photos = 0
        var analyzed = 0
        /// Not readable yet (no local preview, still syncing): tried again in later runs.
        var unreadable = 0
    }

    struct ExecutionState: Equatable {
        var isRunning = false
        /// The plan this state belongs to: progress of an earlier run never lands on a later one.
        var planID: SortlyID?
        var completedSteps = 0
        var totalSteps = 0
        var finished: ChangePlan?
        var failure: String?
        /// Steps that failed or were skipped (the sorting show gives them no checkmark).
        var unsuccessfulSteps: Set<Int> = []
    }

    // MARK: State

    var phase: Phase = .loading
    var access: LibraryAccess = .notDetermined
    var settings = OrganizationSettings() { didSet { bucketCache = [:] } }
    var analysis = AnalysisState()
    var snapshot: ProposalSnapshot?
    var decisions: [SortlyID: ProposalDecision] = [:]
    var userTitles: [SortlyID: String] = [:]
    var facts: [AssetFacts] = [] { didSet { bucketCache = [:]; atlasCache = [:]; atlasYearsCache = nil; countryCache = [:]; datesCache = nil; factsIndex = nil } }
    var states: [AssetID: AssetOrganizationState] = [:] { didSet { bucketCache = [:] } }
    /// Filtered and sorted library buckets; rebuilt only when facts or states change, not on
    /// every redraw of the library (a selection tap redraws it).
    @ObservationIgnored private var bucketCache: [InboxBucket: [AssetFacts]] = [:]
    /// The atlas is shown on the overview, which redraws often during an analysis.
    @ObservationIgnored private var atlasCache: [Int: TravelAtlas] = [:]
    @ObservationIgnored private var atlasYearsCache: [Int]?

    /// Travel atlas for all years (`nil`) or one calendar year; computed once per facts change.
    func travelAtlas(year: Int? = nil) -> TravelAtlas {
        // Cache hits must still register the dependency, or views would never see new facts.
        access(keyPath: \.facts)
        if let cached = atlasCache[year ?? 0] { return cached }
        let atlas = TravelAtlas.compute(facts: facts, year: year)
        atlasCache[year ?? 0] = atlas
        return atlas
    }

    var atlasYears: [Int] {
        access(keyPath: \.facts)
        if let cached = atlasYearsCache { return cached }
        let years = TravelAtlas.years(facts: facts)
        atlasYearsCache = years
        return years
    }

    @ObservationIgnored private var countryCache: [String: CountryPhotos] = [:]
    @ObservationIgnored private var datesCache: [AssetID: Date]?
    @ObservationIgnored private var factsIndex: [AssetID: AssetFacts]?

    /// Facts by photo id (search hits, photo view).
    var factsByID: [AssetID: AssetFacts] {
        access(keyPath: \.facts)
        if let factsIndex { return factsIndex }
        let index = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        factsIndex = index
        return index
    }

    /// Capture date of every photo, for time-ordered previews.
    var creationDates: [AssetID: Date] {
        access(keyPath: \.facts)
        if let datesCache { return datesCache }
        let dates = Dictionary(facts.compactMap { f in f.asset.creationDate.map { (f.id, $0) } }, uniquingKeysWith: { first, _ in first })
        datesCache = dates
        return dates
    }

    /// Photos the user took out of a suggestion ("Aus Vorschlag entfernen").
    var removedFromProposals: [SortlyID: Set<AssetID>] = [:]

    /// The photos of a suggestion as the user sees them: without removed ones, oldest first.
    func members(of proposal: AlbumProposal) -> [AssetID] {
        PreviewPicker.chronological(proposal.assetIDs.subtracting(removedFromProposals[proposal.id] ?? []), dates: creationDates)
    }

    /// Preview photos spread over the suggestion's time span, with the cover photo.
    func previewIDs(for proposal: AlbumProposal, count: Int = 8) -> [AssetID] {
        PreviewPicker.pick(proposal.assetIDs.subtracting(removedFromProposals[proposal.id] ?? []),
                           dates: creationDates, cover: proposal.coverAssetID, count: count)
    }

    /// Takes photos out of one suggestion only; they stay in the library and in other suggestions.
    func removeFromProposal(_ assets: Set<AssetID>, proposal: AlbumProposal) async {
        guard let store, !assets.isEmpty else { return }
        removedFromProposals[proposal.id, default: []].formUnion(assets)
        for asset in assets {
            try? await store.addOverride(UserOverride(scope: .assetInSource(asset, proposal.id), decision: .neverAdd))
        }
        saveSafetyBackup()
        if let rematched = try? await pipeline?.rematch() { snapshot = rematched }
    }

    /// The photos of one atlas country (all years or one year), newest first.
    func countryPhotos(_ code: String, year: Int? = nil) -> CountryPhotos {
        let key = "\(code)|\(year ?? 0)"
        access(keyPath: \.facts)
        if let cached = countryCache[key] { return cached }
        let photos = CountryPhotos.collect(countryCode: code, facts: facts, year: year)
        countryCache[key] = photos
        return photos
    }

    /// The open country suggestion that covers most of these photos, if there is one,
    /// so the atlas can offer "Album anlegen" right where the photos are shown.
    func countryProposal(for country: CountryPhotos) -> AlbumProposal? {
        let ids = country.assetIDs
        guard !ids.isEmpty else { return nil }
        return openProposals
            .filter { $0.kind == .placeCollection(.country) }
            .map { ($0, $0.assetIDs.intersection(ids).count) }
            .filter { $0.1 * 2 > $0.0.assetIDs.count }
            .max { $0.1 < $1.1 }?.0
    }
    var progress = OrganizationStatusResolver.Progress()
    var inventory = CollectionInventory()
    var mergeSuggestions: [AlbumOverlapAnalyzer.MergeSuggestion] = []
    /// Executed plans, newest first. Undo runs are not listed on their own; they mark the
    /// plan they took back (see `undonePlans`).
    var history: [ChangePlan] = []
    /// Plans whose changes were taken back by a completed undo (over the whole journal).
    var undonePlans: Set<SortlyID> = []
    /// How many finished plans the history shows; "Ältere anzeigen" loads more.
    var historyLimit = 50
    /// More finished plans exist than the history shows.
    var historyHasMore = false
    /// Albums Albumist created or extended, with exactly the media it added.
    var managedAlbums: [ManagedAlbumState] = []
    var plan: ChangePlan?
    /// A plan that stopped half way because the app was closed while it ran.
    var interruptedPlan: ChangePlan?
    var analysisCounts = AnalysisCounts()
    /// The part of the library Albumist works on: everything, or the trial year chosen at
    /// the start (kept for every later run).
    var analysisScope: OrganizationScope = .all
    /// Photos changed while a run was busy: one more run follows when it ends.
    @ObservationIgnored var catchUpAfterRun = false
    /// The user's own trip splits and merges (I07), for the settings.
    private(set) var tripCorrections = TripCorrections()
    var execution = ExecutionState()
    var message: String?
    /// Where Siri, Shortcuts or a Spotlight result wants to go; the overview opens it.
    var route: Route?

    enum Route: Hashable {
        case suggestion(SortlyID)
        case country(String)
    }

    let library = PhotoKitLibrary()
    private(set) var store: SortlyStore?
    /// Offline country outlines, also used for the shareable travel atlas.
    private(set) var worldMap: OfflineWorldMap?
    private var pipeline: AnalysisPipeline?
    private var analysisTask: Task<Void, Never>?
    /// The run in progress: Pause reaches exactly this run, at once (no hop to the pipeline,
    /// so a Pause during the start of a run is not lost and a late one stops no later run).
    @ObservationIgnored private var analysisControl: AnalysisRunControl?
    /// Counts runs: progress that arrives late from an earlier run is dropped.
    @ObservationIgnored private var analysisGeneration = 0
    /// Runs in a row that ended early by themselves (an error, Vision failing): tried again
    /// a little later instead of only at the next start of the app.
    @ObservationIgnored private var unattendedRetries = 0
    /// "Analyse neu aufbauen" is clearing the tables: no analysis starts meanwhile.
    @ObservationIgnored private var analysisResetting = false
    /// One plan at a time (apply, resume, undo, take back): claimed before the first await of
    /// every entry point, released when it ends.
    @ObservationIgnored private var executionClaimed = false
    /// Decisions that exist only for an open preview: kept in memory, never written to disk.
    /// Value: what was stored before the preview (nil = undecided).
    @ObservationIgnored private var previewOnly: [SortlyID: ProposalDecision?] = [:]

    private enum Key {
        static let settings = "user.settings"
        static let decisions = "user.decisions"
        static let titles = "user.titles"
        static let onboardingDone = "onboarding.done"
        /// Plans that started and whose results are not stored yet (finished at the next launch).
        static let pendingFinalization = SortlyStore.pendingFinalizationKey
    }

    var onboardingDone: Bool {
        get { UserDefaults.standard.bool(forKey: Key.onboardingDone) }
        set { UserDefaults.standard.set(newValue, forKey: Key.onboardingDone) }
    }

    var resolver: OrganizationStatusResolver { OrganizationStatusResolver(primaryAreas: settings.primaryAreas) }

    // MARK: Lifecycle

    /// Loads the app state once. The app and a Siri or Spotlight intent can both ask for
    /// it at launch; the second caller waits for the first instead of opening the database twice.
    func bootstrap() async {
        if let bootstrapTask { return await bootstrapTask.value }
        let task = Task { await load() }
        bootstrapTask = task
        await task.value
    }

    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?

    private func load() async {
        guard phase == .loading else { return }
        do {
            if UITestSupport.rebuildsDatabase, let url = try? Self.databaseURL() { Self.quarantineDatabase(at: url) }
            let store = try SortlyStore(url: try Self.databaseURL())
            self.store = store
            access = await library.access()
            // A rebuilt (or newly restored) database gets the user's decisions back first.
            await restoreFromBackupIfNeeded(store)
            lastSafetyBackup = Self.safetyBackupDate()
            settings = try await store.value(OrganizationSettings.self, forKey: Key.settings) ?? OrganizationSettings()
            await dropOldRootFolderDefault(store)
            decisions = try await store.value([SortlyID: ProposalDecision].self, forKey: Key.decisions) ?? [:]
            userTitles = try await store.value([SortlyID: String].self, forKey: Key.titles) ?? [:]
            let map = await Task.detached(priority: .userInitiated) { try? WorldMapResource.load() }.value
            worldMap = map
            pipeline = AnalysisPipeline(
                store: store, reader: library,
                analyzer: UITestSupport.slowsAnalysis ? SlowedAnalyzer(base: VisionAnalyzer()) as any ContentAnalyzing : VisionAnalyzer() as any ContentAnalyzing,
                geocoder: SystemGeocoder(locale: Locale(identifier: settings.titleLanguage.rawValue)),
                map: map, conditions: DeviceConditions(), settings: settings,
                foregroundOnlineBudget: 60,
                // UI tests slow each photo down to see a run in progress: one lane keeps that.
                contentLanes: UITestSupport.slowsAnalysis ? 1 : 4
            )
            tripCorrections = (try? await pipeline?.tripCorrections()) ?? TripCorrections()
            analysisScope = (try? await pipeline?.storedScope()) ?? .all
            await refreshDerived()
            // A plan that finished right before the app was closed stores its results now.
            await finishPendingFinalizations()
            // A plan that stopped half way (app closed during "Jetzt umsetzen") is offered
            // on the overview: continue or take back.
            interruptedPlan = try? await store.unfinishedPlans().last
            phase = onboardingDone && access.canRead ? .ready : .onboarding
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Decision 15.11. (Fuchs): no "Albumist" folder above the albums. Earlier installs that
    /// kept the old default switch once, unless albums were already made in that folder, so
    /// nothing ends up in two places.
    private func dropOldRootFolderDefault(_ store: SortlyStore) async {
        let key = "settings.rootFolderDefaultDropped"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard settings.rootFolderTitle == "Albumist", (try? await store.managedAlbums())?.isEmpty ?? false else { return }
        settings.rootFolderTitle = ""
        try? await store.setValue(settings, forKey: Key.settings)
    }

    /// "Neu aufbauen" on the start error screen: the damaged database is set aside (one copy
    /// is kept for support) and Albumist starts fresh. Photos and albums are not touched.
    func rebuildAfterFailure() async {
        guard case .failed = phase else { return }
        if let url = try? Self.databaseURL() {
            Self.quarantineDatabase(at: url)
        }
        bootstrapTask = nil
        phase = .loading
        await bootstrap()
        // The new database is empty: the analysis starts right away, as at a normal launch.
        if phase == .ready && access.canRead && !UITestSupport.isRunning {
            LibraryChangeWatcher.shared.start()
            startAnalysis()
        }
    }

    /// Moves the database together with its write-ahead log and shared memory file into a
    /// dated quarantine folder (the log can hold the last saved changes, so it is never just
    /// deleted). The two newest quarantines are kept for support.
    private static func quarantineDatabase(at url: URL) {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent().appendingPathComponent("Quarantine", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = folder.appendingPathComponent(stamp, isDirectory: true)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
                try fm.moveItem(atPath: url.path + suffix, toPath: target.appendingPathComponent(url.lastPathComponent + suffix).path)
            }
        } catch {
            // Could not move: the start fails again and shows the error instead of losing data.
            return
        }
        let old = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in old.dropFirst(2) { try? fm.removeItem(at: stale) }
    }

    // MARK: Safety backup

    /// When the decisions were last copied for the device backup (shown under Verlauf).
    private(set) var lastSafetyBackup: Date?
    /// Set when this start restored the decisions from the copy; the overview says so once.
    var restoredFromBackup: BackupRestore?

    struct BackupRestore: Equatable {
        /// When the copy was made.
        var date: Date
        var albums: Albums

        enum Albums: Equatable {
            /// The copy had no album records or history.
            case noAlbums
            /// Album records and history came back too.
            case included
            /// The copy came from another library (new iPhone): only the decisions came back.
            case otherLibrary
            /// Album records wait until Albumist may see all photos (to check the library).
            case waiting
        }
    }
    @ObservationIgnored private var safetyBackupTask: Task<Void, Never>?

    /// The copy of the user's decisions. Unlike the database it is part of the iPhone backup.
    static func safetyBackupURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(AppInfo.supportFolderName) Backup", isDirectory: true)
            .appendingPathComponent("decisions.json")
    }

    static func safetyBackupDate() -> Date? {
        guard let url = try? safetyBackupURL() else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Copies the decisions shortly after a change (several changes in a row are one write),
    /// or at once.
    func saveSafetyBackup(immediately: Bool = false) {
        guard store != nil, UITestSupport.allowsSafetyBackup else { return }
        safetyBackupTask?.cancel()
        safetyBackupTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            await self?.writeSafetyBackup()
        }
    }

    /// Writes the copy and returns once it is on disk (the app is going to the background).
    func writeSafetyBackupNow() async {
        safetyBackupTask?.cancel()
        await writeSafetyBackup()
    }

    private func writeSafetyBackup() async {
        // While album records of the copy still wait for photo access, the copy stays as it is.
        guard let store, UITestSupport.allowsSafetyBackup, pendingLibraryRestore == nil,
              let snapshot = try? await store.safetyBackupSnapshot(), let url = try? Self.safetyBackupURL() else { return }
        // Nothing decided yet and no earlier copy: nothing to keep.
        if snapshot.backup.isEmpty && !FileManager.default.fileExists(atPath: url.path) { return }
        if safetyBackupWriter == nil {
            safetyBackupWriter = SafetyBackupWriter(url: url) { url in
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: url.path)
            }
        }
        // One write at a time, and an older snapshot never replaces a newer one (audit 2, 3.2).
        let written = (try? await safetyBackupWriter?.write(snapshot.backup, sequence: snapshot.sequence)) ?? false
        if written { lastSafetyBackup = snapshot.backup.createdAt }
    }
    @ObservationIgnored private var safetyBackupWriter: SafetyBackupWriter?

    /// Album records and history from the copy that still wait for photo access (to check
    /// that the copy belongs to this library). While they wait, the copy is not overwritten.
    @ObservationIgnored private var pendingLibraryRestore: SafetyBackup?

    /// Restores the copy into a database without decisions (rebuilt after damage, or a new
    /// install from an iPhone backup). The decisions come back at once; album records and
    /// history only when the copy belongs to this library, which needs photo access to check.
    /// Returns true when something was restored.
    @discardableResult
    private func restoreFromBackupIfNeeded(_ store: SortlyStore) async -> Bool {
        pendingLibraryRestore = nil
        guard UITestSupport.allowsSafetyBackup, let url = try? Self.safetyBackupURL(),
              let backup = try? SafetyBackup.read(from: url), !backup.isEmpty else { return false }
        var restored = false
        if (try? await store.hasSafetyData()) == false {
            restored = (try? await store.restore(backup, includingLibraryState: false)) == true
        }
        var albums = restoredFromBackup?.albums ?? .noAlbums
        if !backup.managedAlbums.isEmpty || !backup.plans.isEmpty, (try? await store.hasLibraryState()) == false {
            switch await belongsToThisLibrary(backup) {
            case true?:
                if (try? await store.restoreLibraryState(backup)) == true {
                    restored = true
                    albums = .included
                }
            case false?:
                // Another library (new iPhone with new album identifiers): the old album
                // records would read as "deleted by you". The copy is renewed without them.
                albums = .otherLibrary
                saveSafetyBackup(immediately: true)
            case nil:
                albums = .waiting
                pendingLibraryRestore = backup
            }
        }
        if restored || restoredFromBackup != nil {
            restoredFromBackup = BackupRestore(date: backup.createdAt, albums: albums)
        }
        return restored
    }

    /// Nil while that cannot be told yet: no photo access, or limited access that may hide
    /// the albums.
    private func belongsToThisLibrary(_ backup: SafetyBackup) async -> Bool? {
        guard !backup.managedAlbums.isEmpty else { return true }
        guard access.canRead, let inventory = try? await library.currentInventory() else { return nil }
        if backup.matchesLibrary(albums: Set(inventory.albums.map(\.id))) { return true }
        return access == .full ? false : nil
    }

    /// After the photo access was granted or widened: album records waiting in the copy
    /// come back now if they belong to this library.
    private func restoreWaitingLibraryState() async {
        guard pendingLibraryRestore != nil, access.canRead, let store else { return }
        guard await restoreFromBackupIfNeeded(store) else {
            // Another library: the card already says so; the copy was renewed.
            return
        }
        settings = (try? await store.value(OrganizationSettings.self, forKey: Key.settings)) ?? settings
        decisions = (try? await store.value([SortlyID: ProposalDecision].self, forKey: Key.decisions)) ?? decisions
        userTitles = (try? await store.value([SortlyID: String].self, forKey: Key.titles)) ?? userTitles
        await pipeline?.update(settings: settings)
        await refreshDerived()
        // Plans of the copy that ran but were not finished then are finished now (audit 2, 3.1).
        await finishPendingFinalizations()
        interruptedPlan = try? await store.unfinishedPlans().last
        saveSafetyBackup()
    }

    static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(AppInfo.supportFolderName, isDirectory: true)
        // The database holds recognized text of screenshots and documents: encrypted at rest
        // once the device was unlocked after boot (needed so background analysis still works).
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: protection)
        try? FileManager.default.setAttributes(protection, ofItemAtPath: base.path)
        // The analysis can be rebuilt from the library; keep the whole folder out of backups.
        // (Set on the folder: a resource value on a file that does not exist yet is lost.)
        var folder = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let url = base.appendingPathComponent("sortly.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(protection, ofItemAtPath: path)
            }
        }
        return url
    }

    func requestAccess() async {
        access = await library.requestAccess()
        await restoreWaitingLibraryState()
    }

    /// Reads the access again, e.g. after the user came back from the Settings app.
    func refreshAccess() async {
        access = await library.access()
        await restoreWaitingLibraryState()
    }

    func finishOnboarding(scope: OrganizationScope) {
        onboardingDone = true
        phase = .ready
        if access.canRead { LibraryChangeWatcher.shared.start() }
        ContinuedAnalysis.requestNotificationPermission()
        startAnalysis(scope: scope, userInitiated: true)
    }

    /// "Nur 2026" or the whole library, also later in Settings and on the overview. A run in
    /// progress stops first; the new one goes on from what is analysed already.
    func changeScope(_ scope: OrganizationScope) {
        guard scope != analysisScope else { return }
        analysisScope = scope
        Task {
            // Stored first: whichever run starts next (this one, a catch-up, the next launch)
            // works on the new part, also if another run slips in before ours.
            try? await pipeline?.setScope(scope)
            if analysis.isRunning {
                analysisControl?.pause()
                await analysisTask?.value
            }
            // Changed again meanwhile: that call starts its own run.
            guard analysisScope == scope else { return }
            // Only now: late progress of the old run cannot mark the new part as half done.
            AnalysisMarker.reset()
            startAnalysis(userInitiated: true)
        }
    }

    // MARK: Settings

    func saveSettings() {
        let settings = settings
        Task {
            try? await store?.setValue(settings, forKey: Key.settings)
            saveSafetyBackup()
            await pipeline?.update(settings: settings)
            await refreshDerived()
        }
    }

    // MARK: Analysis

    /// `userInitiated`: started by a tap. Every long run asks iOS to go on in the background
    /// with progress on the Lock Screen (iOS 26 continued processing), not only the first one
    /// (first device test 15.11.: shown once, then never again).
    /// `scope`: a new part of the library to work on; `nil` keeps the stored one.
    func startAnalysis(scope: OrganizationScope? = nil, mode: AnalysisPipeline.Mode = .incremental, userInitiated: Bool = false) {
        guard !analysis.isRunning, !analysisResetting, let pipeline else { return }
        analysis.isRunning = true
        analysis.needsResume = false
        analysis.stage = nil
        analysis.completed = 0
        analysis.total = 0
        analysis.waiting = nil
        analysis.resumeFrom = AnalysisMarker.unfinished
        analysis.kind = analysis.resumeFrom != nil ? .resume : (AnalysisMarker.completedOnce ? .check : .first)
        if userInitiated {
            ContinuedAnalysis.begin()
            unattendedRetries = 0
        }
        analysisGeneration += 1
        let generation = analysisGeneration
        let control = AnalysisRunControl()
        analysisControl = control
        analysisTask = Task {
            if let scope {
                try? await pipeline.setScope(scope)
                analysisScope = scope
            }
            // The report of this run only: a run that fails never reuses the success of the
            // one before (audit 2, 4.2).
            var finished: AnalysisPipeline.Report?
            do {
                let report = try await pipeline.run(mode: mode, control: control, onProgress: { progress in
                    Task { @MainActor in AppModel.shared.receive(progress, run: generation) }
                }, onWaiting: { reason in
                    Task { @MainActor in
                        let model = AppModel.shared
                        guard model.analysisGeneration == generation, model.analysis.isRunning else { return }
                        model.analysis.waiting = reason
                    }
                })
                analysis.lastReport = report
                analysis.lastRun = Date()
                finished = report
            } catch {
                message = error.localizedDescription
            }
            if analysisControl === control { analysisControl = nil }
            analysis.isRunning = false
            analysis.stage = nil
            analysis.waiting = nil
            if finished?.isComplete == true {
                AnalysisMarker.finished()
                analysis.resumeFrom = nil
            }
            // Ended early without the user's Pause (an error, the app's time ran out, the photo
            // access was changed in Settings): the next time the app is opened it goes on by
            // itself; with the access back, from where it was.
            let reason = finished?.pausedBecause
            analysis.needsResume = finished == nil || (reason != nil && reason != .userPaused)
            if reason == .accessRevoked {
                // Shown as it is now (limited or none), so the overview offers the way back.
                access = await library.access()
            }
            await refreshDerived()
            // Trip identities (names and corrections stay with their trip) are kept in the copy.
            saveSafetyBackup()
            // "Analyse fertig" only when it really finished (not paused, stopped or failed).
            if finished?.isComplete == true, !Task.isCancelled {
                ContinuedAnalysis.notifyFinished(openSuggestions: openProposals.count)
            }
            BackgroundWork.scheduleRefinement()
            if finished?.isComplete == true { unattendedRetries = 0 }
            // Photos changed in Photos while this ran (new pictures, an album): one more pass.
            if catchUpAfterRun {
                catchUpAfterRun = false
                if reason != .userPaused { LibraryChangeWatcher.shared.scheduleCatchUp() }
            } else if analysis.needsResume {
                retryUnattendedRun(after: generation)
            }
        }
    }

    /// A run that ended early by itself (an error, Vision failing, the app's time ran out)
    /// goes on a little later, a few times, instead of waiting until the app is opened again.
    /// Nothing happens when another run started meanwhile or the user paused.
    private func retryUnattendedRun(after run: Int) {
        guard unattendedRetries < 2 else { return }
        unattendedRetries += 1
        let delay = 30 * unattendedRetries
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard analysisGeneration == run, analysis.needsResume, !analysis.isRunning,
                  phase == .ready, access.canRead, !execution.isRunning, !analysisResetting else { return }
            startAnalysis()
        }
    }

    /// Progress of the running analysis. Late updates of an earlier run are dropped (a run
    /// that starts right after another one would otherwise show the old run's stage), and a
    /// count never goes back within a stage (the updates hop here one by one and can overtake
    /// each other).
    private func receive(_ progress: AnalysisPipeline.Progress, run: Int) {
        guard run == analysisGeneration, analysis.isRunning else { return }
        if let stage = analysis.stage {
            if progress.stage.number < stage.number { return }
            if progress.stage == stage, progress.completed < analysis.completed { return }
        }
        // Trips and places are ready before the image analysis: show them now.
        if progress.stage == .content, analysis.stage != .content, snapshot == nil {
            Task { await refreshDerived() }
        }
        // First scan: the photos are known after reading the library (for the scan show).
        if progress.stage == .patterns, analysis.stage == .inventory, facts.isEmpty {
            Task { await refreshDerived() }
        }
        analysis.stage = progress.stage
        analysis.completed = progress.completed
        analysis.total = progress.total
        analysis.waiting = nil
        // Kept across launches: a run that iOS ended goes on from here (see `resumeFrom`).
        if !analysis.isCatchingUp {
            AnalysisMarker.unfinished = .init(stage: progress.stage.number, overall: analysis.overall)
        }
        keepRunningInBackgroundIfLong()
    }

    /// A run with real work left asks iOS to go on after the user leaves the app.
    func keepRunningInBackgroundIfLong() {
        guard analysis.isRunning, let stage = analysis.stage,
              [.places, .content, .text].contains(stage), analysis.remaining >= 100 else { return }
        ContinuedAnalysis.begin()
    }

    /// The app is on screen again: a run that iOS ended goes on by itself, and a run still
    /// busy asks for background time again (the last request may have run out).
    func sceneBecameActive() {
        if analysis.isRunning {
            keepRunningInBackgroundIfLong()
            return
        }
        guard analysis.needsResume, phase == .ready, !execution.isRunning, !analysisResetting else { return }
        unattendedRetries = 0
        guard access.canRead else {
            // The run ended because the access was taken away: it may be back from Settings.
            Task {
                await refreshAccess()
                if access.canRead { startAnalysis() }
            }
            return
        }
        startAnalysis()
    }

    func pauseAnalysis() {
        analysis.needsResume = false
        analysisControl?.pause()
    }

    /// Called by the background task while charging.
    func runBackgroundRefinement() async -> Bool {
        if phase == .loading { await bootstrap() }
        // A run from the app that iOS held in the background goes on while this charging
        // window keeps the app awake, instead of the window being handed back at once. It is
        // not ended when the window closes; it is held again and goes on later.
        while analysis.isRunning, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
        }
        guard let pipeline, !analysis.isRunning, !analysisResetting, access.canRead, !Task.isCancelled else { return false }
        analysis.isRunning = true
        defer { analysis.isRunning = false }
        // Late progress of the run before must not show up during this one.
        analysisGeneration += 1
        let control = AnalysisRunControl()
        analysisControl = control
        defer { if analysisControl === control { analysisControl = nil } }
        // Held like a foreground run, so "Analyse neu aufbauen" can wait until this run has
        // really ended before it clears the tables (audit 2, 4.1).
        let run = Task { try await pipeline.run(mode: .refinement, control: control) }
        analysisTask = Task { await withTaskCancellationHandler { _ = try? await run.value } onCancel: { run.cancel() } }
        do {
            let report = try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() }
            analysis.lastReport = report
            await refreshDerived()
            saveSafetyBackup(immediately: true)
            return report.pausedBecause == nil
        } catch {
            return false
        }
    }

    func refreshDerived() async {
        guard let store, let pipeline else { return }
        await reconcileManagedAlbums(quiet: true)
        do {
            snapshot = try await pipeline.latestProposals()
            facts = try await pipeline.currentFacts()
            inventory = try await store.loadInventory()
            let inventory = inventory
            // Albumist's own albums overlap on purpose (a country holds its trips).
            let own = Set(managedAlbums.map(\.albumID))
            mergeSuggestions = await Task.detached(priority: .utility) { AlbumOverlapAnalyzer().suggestions(in: inventory, excluding: own) }.value
            let plans = try await store.planHistory(limit: historyLimit + 1)
            historyHasMore = plans.count > historyLimit
            history = plans.prefix(historyLimit).filter { $0.reverts == nil }
            undonePlans = try await store.undoneTargets()
            Purchases.shared.settleUndone(undonePlans)
            // Photos that could not be read yet (failed attempts) do not count as looked at.
            let contents = try await store.results(ContentAnalysis.self, kind: "content")
            let analyzed = Set(contents.filter { $0.value.failedAttempts == nil }.keys)
            let unreadable = Set(contents.filter { $0.value.failedAttempts != nil }.keys)
            let stored = try await store.overrides()
            let overrides = OverrideSet(stored)
            var removed: [SortlyID: Set<AssetID>] = [:]
            for o in stored where o.decision == .neverAdd {
                if case .assetInSource(let asset, let source) = o.scope { removed[source, default: []].insert(asset) }
            }
            removedFromProposals = removed
            let facts = facts, snapshot = snapshot, settings = settings
            let computed = await Task.detached(priority: .userInitiated) {
                LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings, overrides: overrides, contentAnalyzed: analyzed)
            }.value
            states = computed
            // The trial year counts only its own photos (the ring said "839 von 5.683" over
            // the whole library while the suggestions were for 2026).
            let scope = analysisScope, calendar = Calendar.sortlyDefault
            let inScope = scope == .all ? facts : facts.filter { scope.includes($0, calendar: calendar) }
            let scopedIDs = Set(inScope.map(\.id))
            progress = resolver.progress(scope == .all ? Array(computed.values) : computed.filter { scopedIDs.contains($0.key) }.map(\.value))
            analysisCounts = AnalysisCounts(
                photos: inScope.count,
                analyzed: scope == .all ? analyzed.count : analyzed.intersection(scopedIDs).count,
                unreadable: scope == .all ? unreadable.count : unreadable.intersection(scopedIDs).count
            )
        } catch {
            message = error.localizedDescription
        }
        SpotlightIndex.scheduleUpdate(self)
    }

    // MARK: Proposals and decisions

    var proposals: [AlbumProposal] { snapshot?.proposals ?? [] }

    func match(for proposal: AlbumProposal) -> MatchResult? { snapshot?.matches[proposal.id] }

    func decision(for proposal: AlbumProposal) -> ProposalDecision {
        decisions[proposal.id] ?? .undecided
    }

    func recommendedDecision(for proposal: AlbumProposal) -> ProposalDecision {
        ProposalDecision.recommended(for: proposal, match: match(for: proposal), userTitle: userTitles[proposal.id])
    }

    /// Proposals that contain this photo (shown on the photo so it can be opened directly).
    func proposals(containing id: AssetID) -> [AlbumProposal] {
        proposals.filter { $0.assetIDs.contains(id) }
            .sorted { ($0.reliability, $0.assetIDs.count) > ($1.reliability, $1.assetIDs.count) }
    }

    var openProposals: [AlbumProposal] {
        proposals.filter { decisions[$0.id] == nil && match(for: $0)?.status != .alreadyComplete }
    }

    /// The best suggestions for a first round ("Dein Startpaket"): safe ones only (at least
    /// likely, nothing sensitive, no name needed, a clear action), trips and places first,
    /// then the biggest. Returned in display order, the order the preview lists them in.
    func starterSet(limit: Int) -> [AlbumProposal] {
        func rank(_ p: AlbumProposal) -> Int {
            switch p.kind.area {
            case .trips: 2
            case .places: 1
            default: 0
            }
        }
        return Array(openProposals
            .filter { $0.reliability >= .likely && !$0.isSensitive && !$0.requiresUserName && recommendedDecision(for: $0).isAccepted }
            .sorted { (rank($0), $0.assetIDs.count, $1.title) > (rank($1), $1.assetIDs.count, $0.title) }
            .prefix(limit)).inDisplayOrder()
    }

    /// "Die ersten N jetzt anlegen": keeps the biggest accepted suggestions within the free
    /// albums; the others go back to the open list (nothing is lost) and the plan is rebuilt.
    func keepFirstAccepted(_ limit: Int) async {
        let accepted = acceptedProposals.sorted { ($0.assetIDs.count, $1.title) > ($1.assetIDs.count, $0.title) }
        for p in accepted.dropFirst(max(0, limit)) { decisions[p.id] = nil }
        persistDecisions()
        await buildPlan()
    }

    func accept(_ proposals: [AlbumProposal]) {
        for p in proposals { setDecision(recommendedDecision(for: p), for: p) }
    }

    /// Decisions set only for a preview opened straight from a button ("Dein Startpaket",
    /// "Album anlegen"), with what was there before.
    struct PreviewSelection {
        fileprivate var entries: [(proposal: AlbumProposal, previous: ProposalDecision?, chosen: ProposalDecision)]
    }

    /// Selects suggestions for a preview. Leaving the preview without creating anything must
    /// undo this with `endPreview(_:)`: nothing may stay selected that the user never chose
    /// (Fuchs, 14.11.: "Ich hatte aber noch nichts ausgewählt").
    func selectForPreview(_ items: [(AlbumProposal, ProposalDecision)]) -> PreviewSelection {
        let entries = items.map { (proposal: $0.0, previous: decisions[$0.0.id], chosen: $0.1) }
        // In memory only: if the app is closed during the preview, nothing stays selected.
        for e in entries {
            if previewOnly[e.proposal.id] == nil { previewOnly[e.proposal.id] = .some(e.previous) }
            decisions[e.proposal.id] = e.chosen
        }
        return PreviewSelection(entries: entries)
    }

    /// Back from a preview: decisions that are still the preview's own go back to what they
    /// were. Applied suggestions were already cleared by the execution and stay as they are.
    func endPreview(_ selection: PreviewSelection) {
        for e in selection.entries {
            // Chosen on purpose meanwhile (or already applied and cleared): stays as it is.
            guard previewOnly.removeValue(forKey: e.proposal.id) != nil, decisions[e.proposal.id] == e.chosen else { continue }
            decisions[e.proposal.id] = e.previous
        }
    }

    /// "Auswahl aufheben" on the preview: every selected suggestion goes back to the open list.
    func clearSelection() {
        for (id, decision) in decisions where decision.isAccepted { decisions[id] = nil }
        previewOnly.removeAll()
        persistDecisions()
    }

    var acceptedProposals: [AlbumProposal] {
        proposals.filter { decisions[$0.id]?.isAccepted == true }
    }

    /// Selected suggestions that still change something in Photos: an album that is kept
    /// as it is needs nothing, so it does not count on the "N ausgewählte Alben anlegen" button.
    var proposalsToApply: [AlbumProposal] {
        proposals.filter { p in
            guard let decision = decisions[p.id] else { return false }
            return decision.isAccepted && !decision.isKeepExisting
        }
    }

    func setDecision(_ decision: ProposalDecision, for proposal: AlbumProposal) {
        let wasRejected = decisions[proposal.id] == .reject
        decisions[proposal.id] = decision
        previewOnly[proposal.id] = nil // chosen on purpose now
        persistDecisions()
        if decision == .reject {
            let override = UserOverride(scope: .source(proposal.id), decision: .rejectProposal)
            Task {
                try? await store?.addOverride(override)
                saveSafetyBackup()
            }
        } else if wasRejected || decision.isAccepted {
            // "Nicht jetzt" is reversible: accepting later lifts the stored rejection.
            Task { await removeRejection(of: [proposal.id]) }
        }
    }

    /// Removes stored "Nicht jetzt" rejections, so the suggestions can be offered and applied again.
    private func removeRejection(of sources: Set<SortlyID>?) async {
        guard let store, let all = try? await store.overrides() else { return }
        for o in all where o.decision == .rejectProposal {
            guard case .source(let s) = o.scope, sources?.contains(s) ?? true else { continue }
            try? await store.removeOverride(o.id)
        }
        saveSafetyBackup()
    }

    /// Number of suggestions the user put aside with "Nicht jetzt".
    func rejectedProposalCount() async -> Int {
        guard let all = try? await store?.overrides() else { return 0 }
        return all.filter { o in
            if o.decision == .rejectProposal, case .source = o.scope { return true }
            return false
        }.count
    }

    /// "Abgelehnte Vorschläge wieder zeigen": every rejection is lifted and the suggestions
    /// are built again.
    func restoreRejectedProposals() async {
        await removeRejection(of: nil)
        for (id, decision) in decisions where decision == .reject { decisions[id] = nil }
        persistDecisions()
        startAnalysis(userInitiated: true)
    }

    // MARK: Trip workshop (I07)

    /// A trip can be split or merged while Albumist has not made its album yet: an album that
    /// exists would lose the trip it stands for (take it back first, then reshape).
    func canReshape(_ proposal: AlbumProposal) -> Bool {
        guard case .trip = proposal.kind, proposal.dateRange != nil else { return false }
        return !managedAlbums.contains { $0.allSourceIDs.contains(proposal.id) }
    }

    /// The trips right before and after this one that it could be merged with.
    func tripNeighbours(of proposal: AlbumProposal) -> (before: AlbumProposal?, after: AlbumProposal?) {
        guard let span = proposal.dateRange else { return (nil, nil) }
        let trips = proposals.filter { canReshape($0) }
        let around = TripWorkshop.neighbours(of: span, among: trips.compactMap(\.dateRange))
        return (around.before.map { trips[$0] }, around.after.map { trips[$0] })
    }

    /// "Reise teilen": a new trip starts on `day`. The analysis runs again right away.
    func splitTrip(at day: TripWorkshop.Day) async -> Bool {
        await changeTrips { $0.splitting(at: TripWorkshop.splitInstant(before: day)) }
    }

    /// "Zusammenlegen": two neighbouring trips become one, also in every later analysis.
    func mergeTrips(_ a: AlbumProposal, _ b: AlbumProposal) async -> Bool {
        guard let first = a.dateRange, let second = b.dateRange else { return false }
        let interval = TripWorkshop.mergeInterval(first, second, members: Array(a.assetIDs) + Array(b.assetIDs), dates: creationDates)
        return await changeTrips { $0.merging(interval) }
    }

    /// The user's own splits and merges at this trip, so they can be undone where they were made.
    func tripChanges(around proposal: AlbumProposal) -> [TripChange] {
        guard let span = proposal.dateRange else { return [] }
        return tripCorrections.changes(around: span)
    }

    /// "Aufheben" in the workshop: one split or merge is forgotten.
    func undoTripChange(_ change: TripChange) async -> Bool {
        await changeTrips { $0.removing(change) }
    }

    /// "Reisen wieder automatisch erkennen" in the settings.
    func resetTripCorrections() async {
        _ = await changeTrips { $0.withoutSplitsAndMerges() }
    }

    /// Stores the change (it is part of the decisions copy in the backup) and starts the
    /// analysis that applies it. Not while an analysis already read the old corrections.
    private func changeTrips(_ change: (TripCorrections) -> TripCorrections) async -> Bool {
        guard let pipeline, !analysis.isRunning, !execution.isRunning else { return false }
        do {
            let updated = change(try await pipeline.tripCorrections())
            try await pipeline.setTripCorrections(updated)
            tripCorrections = updated
            saveSafetyBackup()
            startAnalysis()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    /// Overrides for planning. A suggestion the user accepted after "Nicht jetzt" is not
    /// skipped, even if its stored rejection has not been removed yet.
    private func planningOverrides(_ store: SortlyStore) async throws -> OverrideSet {
        let accepted = Set(decisions.filter { $0.value.isAccepted }.map(\.key))
        return OverrideSet(try await store.overrides().filter { o in
            if o.decision == .rejectProposal, case .source(let s) = o.scope, accepted.contains(s) { return false }
            return true
        })
    }

    /// "Passt nicht": this album is never offered for this suggestion again. A decision that
    /// pointed at the album is dropped, and the matching runs again right away.
    func rejectMatch(_ album: CollectionID, for proposal: AlbumProposal) async {
        guard let store else { return }
        do {
            try await store.addOverride(UserOverride(scope: .albumForSource(album, proposal.id), decision: .notMatchingAlbum))
            saveSafetyBackup()
            switch decisions[proposal.id] {
            case .extendExisting(album)?, .keepExisting(album)?:
                decisions[proposal.id] = nil
                persistDecisions()
            case .renameExisting(let id, _, _)? where id == album:
                decisions[proposal.id] = nil
                persistDecisions()
            case .moveExisting(let id, _, _)? where id == album:
                decisions[proposal.id] = nil
                persistDecisions()
            default:
                break
            }
            if let rematched = try await pipeline?.rematch() { snapshot = rematched }
        } catch {
            message = error.localizedDescription
        }
    }

    func setUserTitle(_ title: String, for proposal: AlbumProposal) {
        userTitles[proposal.id] = title
        Task { [userTitles] in
            try? await store?.setValue(userTitles, forKey: Key.titles)
            saveSafetyBackup()
        }
    }

    private func persistDecisions() {
        let decisions = storedDecisions(decisions)
        Task {
            try? await store?.setValue(decisions, forKey: Key.decisions)
            saveSafetyBackup()
        }
        SpotlightIndex.scheduleUpdate(self)
    }

    /// What may be written to disk: preview-only selections are replaced by what was there before.
    private func storedDecisions(_ current: [SortlyID: ProposalDecision]) -> [SortlyID: ProposalDecision] {
        var result = current
        for (id, previous) in previewOnly { result[id] = previous }
        return result
    }

    // MARK: Plan and execution

    func buildPlan() async {
        guard let store else { return }
        // The user's latest changes in Photos count before anything is planned.
        guard let current = await reconcileManagedAlbums() else { return }
        do {
            let overrides = try await planningOverrides(store)
            let confirmed = acceptedProposals.map { proposal in
                var decision = decisions[proposal.id] ?? .undecided
                if case .createNew(nil, let path) = decision, let title = userTitles[proposal.id], !title.isEmpty {
                    decision = .createNew(title: title, folderPath: path)
                }
                return ConfirmedProposal(proposal: proposal, decision: decision)
            }
            plan = OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle).makePlan(from: confirmed, inventory: current, overrides: overrides)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Plan for one proposal only, so "Album anlegen" in a suggestion does it right away
    /// (still through the normal preview, with undo).
    func singlePlan(for proposal: AlbumProposal) async -> ChangePlan? {
        guard let store else { return nil }
        guard let current = await reconcileManagedAlbums() else { return nil }
        do {
            let overrides = try await planningOverrides(store)
            var decision = decisions[proposal.id] ?? .undecided
            if case .createNew(nil, let path) = decision, let title = userTitles[proposal.id], !title.isEmpty {
                decision = .createNew(title: title, folderPath: path)
            }
            let plan = OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: current, overrides: overrides)
            return plan.steps.isEmpty ? nil : plan
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Applies a reviewed plan. Only one plan runs at a time.
    func execute(_ plan: ChangePlan) async {
        guard claimExecution() else { return }
        defer { releaseExecution() }
        await run(plan)
    }

    private func claimExecution() -> Bool {
        guard !executionClaimed, !execution.isRunning else { return false }
        executionClaimed = true
        return true
    }

    private func releaseExecution() { executionClaimed = false }

    /// Runs a plan; the caller holds the execution claim. `resume`: an interrupted plan that
    /// was confirmed before (its free albums were checked then).
    private func run(_ plan: ChangePlan, resume: Bool = false) async {
        guard let store else { return }
        // The free albums are checked here too, not only on the review screen.
        let wanted = plan.freeAlbumUse(applied: false)
        if plan.reverts == nil, !resume, !Purchases.shared.allows(albums: wanted) {
            execution = ExecutionState(planID: plan.id, failure: String(localized: "Die Gratis-Alben reichen für diese Änderungen nicht. Schalte Albumist frei, um weiterzumachen."))
            return
        }
        var confirmed = plan
        if confirmed.status == .draft { confirmed.status = .confirmed }
        if confirmed.confirmedAt == nil { confirmed.confirmedAt = Date() }
        let planID = confirmed.id
        execution = ExecutionState(isRunning: true, planID: planID, completedSteps: 0, totalSteps: plan.steps.count)
        let executor = ChangeExecutor(library: library, store: store)
        do {
            // Remembered before anything runs: if the app is closed after the plan finished
            // but before its results were stored, the next launch stores them.
            try await setPendingFinalization(adding: planID)
            let result = try await executor.execute(confirmed) { event in
                if case .stepFinished(let index, let state) = event {
                    let succeeded: Bool = if case .succeeded = state { true } else { false }
                    Task { @MainActor in
                        let model = AppModel.shared
                        guard model.execution.planID == planID else { return }
                        if !succeeded { model.execution.unsuccessfulSteps.insert(index) }
                        model.execution.completedSteps = index + 1
                    }
                }
            }
            execution.finished = result
            if result.status == .completed || result.status == .completedWithErrors {
                await finalize(result)
            }
        } catch {
            execution.failure = error.localizedDescription
        }
        execution.isRunning = false
        self.plan = nil
        startAnalysis()
    }

    /// Everything that follows a finished plan, stored in one transaction: Albumist's albums,
    /// applied suggestions leaving the open list, and the plan marked as finalized. The free
    /// albums are counted once per plan, from what really changed.
    private func finalize(_ result: ChangePlan) async {
        guard let store else { return }
        var undone: SortlyID?
        do {
            let after = try await library.currentInventory()
            try await store.saveInventory(after)
            inventory = after
            let states = ManagedAlbumTracker().record(result, into: try await store.managedAlbums(), inventory: after)
            var newDecisions = decisions
            if result.reverts == nil {
                // Applied proposals leave the open list; other accepted ones stay accepted.
                let applied = Set(result.steps.compactMap(\.sourceID))
                for id in applied where newDecisions[id]?.isAccepted == true {
                    newDecisions[id] = nil
                    previewOnly[id] = nil
                }
                // Counted before the store write: counting twice is impossible (per plan id),
                // and a crash in between is completed at the next launch.
                Purchases.shared.recordUsage(plan: result.id, albums: result.freeAlbumUse(applied: true))
            } else if let original = result.reverts, result.status == .completed, let executed = try await store.plan(original) {
                // A completed undo: part of the same recoverable finalization, so a crash right
                // after the undo still gives the free albums back (audit 2, 6.3). Both are
                // idempotent when the finalization runs again.
                Purchases.shared.returnUsage(plan: executed.id, albums: executed.freeAlbumUse(applied: true))
                // A removal that is taken back lets its suggestions come back as well.
                let sources = executed.removalSources
                if !sources.isEmpty {
                    for o in try await store.overrides() where o.decision == .rejectProposal {
                        if case .source(let s) = o.scope, sources.contains(s) { try await store.removeOverride(o.id) }
                    }
                }
                undone = original
            }
            var done = result
            done.finalizedAt = Date()
            let pending = (try await store.value([SortlyID].self, forKey: Key.pendingFinalization) ?? []).filter { $0 != result.id }
            try await store.finalize(done, managedAlbums: states, values: [
                Key.decisions: storedDecisions(newDecisions),
                Key.pendingFinalization: pending,
            ])
            decisions = newDecisions
            managedAlbums = states
            if let undone { undonePlans.insert(undone) }
            saveSafetyBackup()
            SpotlightIndex.scheduleUpdate(self)
            // Suggestions see the new albums at once (e.g. "Album vollständig").
            if let rematched = try await pipeline?.rematch() { snapshot = rematched }
        } catch {
            message = error.localizedDescription
        }
    }

    private func setPendingFinalization(adding id: SortlyID? = nil, removing gone: Set<SortlyID> = []) async throws {
        guard let store else { return }
        var pending = try await store.value([SortlyID].self, forKey: Key.pendingFinalization) ?? []
        if let id, !pending.contains(id) { pending.append(id) }
        pending.removeAll { gone.contains($0) }
        try await store.setValue(pending, forKey: Key.pendingFinalization)
    }

    /// At launch: plans that finished but whose results were not stored yet are finalized now;
    /// plans that never started or were dropped leave the list. An interrupted plan stays
    /// (it is offered to continue or take back).
    private func finishPendingFinalizations() async {
        guard let store, let pending = try? await store.value([SortlyID].self, forKey: Key.pendingFinalization), !pending.isEmpty else { return }
        var drop = Set<SortlyID>()
        for id in pending {
            guard let plan = try? await store.plan(id) else { drop.insert(id); continue }
            switch plan.status {
            case .completed, .completedWithErrors:
                if plan.finalizedAt == nil { await finalize(plan) } else { drop.insert(id) }
            case .running, .confirmed:
                continue
            case .draft, .cancelled:
                drop.insert(id)
            }
        }
        if !drop.isEmpty { try? await setPendingFinalization(removing: drop) }
    }

    /// Merge plan for overlapping albums: the largest album receives the missing media of
    /// the others. The other albums stay unless the user removes them later (prompt §3).
    /// The target keeps its name exactly as it is.
    func mergePlan(_ suggestion: AlbumOverlapAnalyzer.MergeSuggestion) async -> ChangePlan? {
        guard let store else { return nil }
        guard let current = await reconcileManagedAlbums() else { return nil }
        do {
            let albums = suggestion.albumIDs.compactMap { current[$0] }
            guard let target = albums.max(by: { $0.assetIDs.count < $1.assetIDs.count }) else { return nil }
            let proposal = AlbumProposal(id: SortlyID(), kind: .rule, title: target.title, assetIDs: [], reliability: .certain)
            let decision = ProposalDecision.merge(target: target.id, sources: albums.map(\.id), title: nil, folderPath: nil, removeSourceAlbums: false)
            let overrides = OverrideSet(try await store.overrides())
            return OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: current, overrides: overrides)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Plan for photos the user put into an album by hand: an existing album is extended,
    /// otherwise a new album is created (in the Albumist folder). Goes through the normal review.
    func manualPlan(assets: [AssetID], target: CollectionID?, newTitle: String?) async -> ChangePlan? {
        guard let store, !assets.isEmpty else { return nil }
        guard let current = await reconcileManagedAlbums() else { return nil }
        do {
            let title = newTitle ?? target.flatMap { current[$0]?.title } ?? ""
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let proposal = AlbumProposal(id: SortlyID(), kind: .rule, title: title, assetIDs: Set(assets), reliability: .certain)
            let decision: ProposalDecision = target.map { .extendExisting($0) } ?? .createNew(title: title, folderPath: nil)
            let overrides = OverrideSet(try await store.overrides())
            return OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: current, overrides: overrides)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    // MARK: Albums created by Albumist

    /// Detects changes the user made in the Photos app (renamed, deleted, photos removed)
    /// and turns them into overrides, so Albumist never undoes a manual decision. Returns the
    /// album list it compared with: planning uses exactly that snapshot, so nothing the user
    /// changed between two reads slips through (audit 2, 1.5). Nil if the albums could not be
    /// read or what was found could not be stored; planning then waits.
    @discardableResult
    private func reconcileManagedAlbums(quiet: Bool = false) async -> CollectionInventory? {
        guard let store else { return nil }
        do {
            let stored = try await store.managedAlbums()
            var current = try await library.currentInventory()
            // Only with full access: a limited library would look like deleted albums and photos.
            guard !stored.isEmpty, !execution.isRunning, await library.access() == .full else {
                managedAlbums = stored
                return current
            }
            let tracker = ManagedAlbumTracker()
            var result = tracker.reconcile(stored, with: current)
            // An empty album list is a valid answer (the user deleted the last album). Only when
            // every remembered album seems gone at once, a second read has to confirm it, and
            // that read is then the one everything works with.
            if result.updatedStates.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                current = try await library.currentInventory()
                result = tracker.reconcile(stored, with: current)
            }
            if !result.changes.isEmpty {
                // Overrides and the new last-known state in one transaction: a manual change
                // is never marked as seen without its override.
                try await store.applyReconciliation(overrides: result.newOverrides, managedAlbums: result.updatedStates)
                saveSafetyBackup()
            }
            managedAlbums = result.updatedStates
            return current
        } catch {
            // Fails closed (audit 2, 1.5): without knowing what the user changed in Photos,
            // nothing is planned, so a photo they took out is never put back by mistake.
            if !quiet { message = String(localized: "Albumist konnte deine Alben gerade nicht lesen. Versuche es gleich noch einmal.") }
            return nil
        }
    }

    /// Plan that takes Albumist's additions back out of one album (shown in the normal review).
    func removalPlan(for state: ManagedAlbumState) async -> ChangePlan? {
        guard let current = await reconcileManagedAlbums() else { return nil }
        // The state may have changed with the reconciliation (photos the user took out).
        guard let fresh = managedAlbums.first(where: { $0.albumID == state.albumID }) else { return nil }
        let plan = ManagedAlbumTracker().removalPlan(for: fresh, current: current)
        return plan.steps.isEmpty ? nil : plan
    }

    /// After a removal the suggestion behind the album is not offered again.
    func forgetProposal(_ source: SortlyID) async {
        try? await store?.addOverride(UserOverride(scope: .source(source), decision: .rejectProposal))
        saveSafetyBackup()
        await refreshDerived()
    }

    /// Finishes an interrupted plan. Steps that already ran are skipped; a step that was
    /// running is checked against the library first, so nothing is created twice. Photos the
    /// user has taken out of an album since then are not added anymore.
    func resumeInterruptedPlan() async {
        guard let store, let interrupted = interruptedPlan, claimExecution() else { return }
        defer { releaseExecution() }
        guard await reconcileManagedAlbums() != nil else { return }
        execution = ExecutionState()
        let overrides = (try? await store.overrides()).map { OverrideSet($0) } ?? OverrideSet()
        await run(interrupted.respecting(overrides), resume: true)
        if execution.failure == nil { interruptedPlan = nil }
    }

    /// Takes back what an interrupted plan already did, and drops the rest. Steps the
    /// interruption left open are first checked against the library (an album created or
    /// photos added right before the app was closed are taken back too).
    func undoInterruptedPlan() async {
        guard let store, let interrupted = interruptedPlan, claimExecution() else { return }
        defer { releaseExecution() }
        do {
            let settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted)
            let current = try await library.currentInventory()
            var undoPlan = UndoPlanner().undoPlan(for: settled, current: current)
            undoPlan.status = .confirmed
            undoPlan.confirmedAt = Date()
            var cancelled = settled
            cancelled.status = .cancelled
            // Both in one transaction: the undo is journaled before the plan stops being offered.
            try await store.save([cancelled] + (undoPlan.steps.isEmpty ? [] : [undoPlan]))
            try? await setPendingFinalization(removing: [interrupted.id])
            if !undoPlan.steps.isEmpty { await run(undoPlan) }
            interruptedPlan = nil
            await refreshDerived()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Guided repair (I16)

    /// "So lassen" for an interrupted plan: what already happened stays and is recorded like
    /// a finished plan (Albumist's albums, history, undo later); the rest is dropped. If
    /// nothing happened yet, the plan simply goes away.
    func keepInterruptedPlanAsIs() async {
        guard let store, let interrupted = interruptedPlan, claimExecution() else { return }
        defer { releaseExecution() }
        do {
            // Steps the interruption left open are checked against the library first.
            var settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted)
            for index in settled.steps.indices where !settled.steps[index].state.isFinished {
                settled.steps[index].state = .skipped(reason: StepState.leftByUserReason)
            }
            let succeeded = settled.steps.filter { if case .succeeded = $0.state { true } else { false } }.count
            if succeeded > 0 {
                settled.status = succeeded == settled.steps.count ? .completed : .completedWithErrors
                try await store.save(settled)
                await finalize(settled)
            } else {
                settled.status = .cancelled
                try await store.save(settled)
                try? await setPendingFinalization(removing: [interrupted.id])
            }
            interruptedPlan = nil
            await refreshDerived()
        } catch {
            message = error.localizedDescription
        }
    }

    /// "Erneut versuchen" for a plan that did not finish everything: a plan with only the
    /// steps that did not happen, for the normal review. Nil when nothing is left to do.
    func retryPlan(for executed: ChangePlan) async -> ChangePlan? {
        guard let store, let current = await reconcileManagedAlbums() else { return nil }
        do {
            guard let retry = RetryPlanner().retryPlan(for: executed, current: current) else { return nil }
            // Photos the user took out of an album since then are not added again.
            return retry.respecting(OverrideSet(try await store.overrides()))
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// A text for support: app, device, photo access and the state of every recent plan, with
    /// counts and reason codes only. No album names, places or photos (I16).
    func diagnosticReport(device: String, system: String) async -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["Albumist diagnostic report", "created \(iso.string(from: Date()))", ""]
        lines.append("app \(AppInfo.version), \(system), \(device), language \(Locale.current.language.languageCode?.identifier ?? "?")")
        lines.append("photo access \(access.rawValue), onboarding done \(onboardingDone)")
        lines.append("photos \(progress.total), fully sorted \(progress.fully), partly \(progress.partially), unsorted \(progress.unorganized), pending \(progress.pending)")
        if let report = analysis.lastReport {
            let last = analysis.lastRun.map { iso.string(from: $0) } ?? "?"
            lines.append("analysis last \(last), complete \(report.isComplete), paused \(report.pausedBecause?.rawValue ?? "no"), stages \(report.completedStages.count), content \(report.contentAnalyzed), text \(report.textRecognized), text waiting \(report.textWaitingForOriginal), places pending online \(report.placesPendingOnline), places throttled \(report.placesThrottled), analyzer failing \(report.analyzerUnavailable)")
        } else {
            lines.append("analysis not run in this session")
        }
        let scopeText: String
        switch analysisScope {
        case .all: scopeText = "all"
        case .year(let year): scopeText = "year \(year)"
        case .album: scopeText = "album"
        }
        lines.append("analysis scope \(scopeText), photos \(analysisCounts.photos), analysed \(analysisCounts.analyzed), unreadable \(analysisCounts.unreadable), running \(analysis.isRunning), waiting \(analysis.waiting?.rawValue ?? "no"), needs resume \(analysis.needsResume), background task \(ContinuedAnalysis.isActive)")
        lines.append("decisions copy \(lastSafetyBackup.map { iso.string(from: $0) } ?? "none"), albums waiting for access \(pendingLibraryRestore != nil)")
        if let store {
            let overrides = (try? await store.overrides().count) ?? -1
            let rules = (try? await store.currentRules().count) ?? -1
            lines.append("managed albums \(managedAlbums.count), overrides \(overrides), rules \(rules)")
            lines.append("")
            if let interrupted = interruptedPlan { lines.append("interrupted: " + PlanDiagnostics.describe(interrupted)) }
            let plans = (try? await store.planHistory(limit: 20)) ?? []
            lines.append("recent plans \(plans.count)")
            lines += plans.map(PlanDiagnostics.describe)
        }
        if let failure = execution.failure { lines.append("last execution failure: \(PlanDiagnostics.reasonCode(failure))") }
        if let deletion = DeletionLog.last { lines.append("last deletion \(deletion)") }
        return lines.joined(separator: "\n")
    }

    func undo(_ executed: ChangePlan) async {
        // Taking back the same plan twice would find nothing to do (or remove what the user
        // added in the meantime), so a plan is undone once.
        // A partial undo (completedWithErrors) does not count as undone: running it again takes
        // back only what is still Albumist's (audit 2, 1.6).
        guard !undonePlans.contains(executed.id), executed.reverts == nil, claimExecution() else { return }
        defer { releaseExecution() }
        // What the user changed by hand since counts first: a photo they took out and put back
        // is theirs now and stays.
        guard let current = await reconcileManagedAlbums() else { return }
        var owned: [CollectionID: Set<AssetID>] = [:]
        for state in managedAlbums { owned[state.albumID, default: []].formUnion(state.addedBySortly) }
        let undoPlan = UndoPlanner().undoPlan(for: executed, current: current, owned: owned)
        // Free albums and suggestions come back in `finalize`, with the undo itself.
        await run(undoPlan)
    }

    /// The change receipt of an executed plan (I01) and, if it was taken back, of its undo.
    /// Several undos when the first one was only partial: newest first.
    func receipt(for plan: ChangePlan) async -> (plan: PlanReceipt, undos: [PlanReceipt]) {
        let undos = (try? await store?.reverts(of: plan.id)) ?? []
        return (PlanReceipt(plan: plan, inventory: inventory), undos.map { PlanReceipt(plan: $0, inventory: inventory) })
    }

    /// "Ältere anzeigen" in the history.
    func loadMoreHistory() async {
        historyLimit += 50
        await refreshDerived()
    }

    // MARK: Library and search

    func bucketMembers(_ bucket: InboxBucket) -> [AssetFacts] {
        access(keyPath: \.facts)
        access(keyPath: \.states)
        access(keyPath: \.settings)
        if let cached = bucketCache[bucket] { return cached }
        let resolver = resolver
        let members = facts.filter { f in
            guard let state = states[f.id] else { return bucket == .all }
            return resolver.buckets(state).contains(bucket)
        }
        .sorted { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
        bucketCache[bucket] = members
        return members
    }

    func ignore(_ assets: [AssetID]) {
        Task {
            for id in assets { try? await store?.addOverride(UserOverride(scope: .asset(id), decision: .ignoreAsset)) }
            saveSafetyBackup()
            await refreshDerived()
        }
    }

    var searchParser: QueryParser {
        QueryParser(vocabulary: SearchVocabulary.build(facts: facts, inventory: inventory, groups: []))
    }

    /// Keywords Apple Intelligence derived from the last sentence-style query (shown in the UI).
    var lastSearchRewrite: String?

    func search(_ query: String) async -> (tokens: [SearchToken], results: [AssetID]) {
        lastSearchRewrite = nil
        let direct = await plainSearch(query)
        let wordCount = query.split(whereSeparator: \.isWhitespace).count
        // Sentences ("Fotos vom Grillen letzten Sommer") get help from the on-device model.
        guard wordCount >= 3, direct.results.isEmpty || direct.tokens.count < 2, SmartAssistant.isAvailable,
              let keywords = await SmartAssistant.searchKeywords(for: query) else { return direct }
        let assisted = await plainSearch(keywords)
        guard !assisted.results.isEmpty else { return direct }
        lastSearchRewrite = keywords
        return assisted
    }

    private func plainSearch(_ query: String) async -> (tokens: [SearchToken], results: [AssetID]) {
        let parsed = searchParser.parse(query)
        guard !parsed.filter.isEmpty else { return (parsed.tokens, []) }
        var textHits: Set<AssetID>?
        if !parsed.filter.freeText.isEmpty, let store {
            // Every text hit counts: the number shown and an album made from the search include all.
            textHits = Set((try? await store.searchText(parsed.filter.freeText.joined(separator: " "), limit: 1_000_000)) ?? [])
        }
        let overall = states.mapValues { resolver.overall($0) }
        let results = SearchEngine().search(parsed.filter, in: facts, statuses: overall, textHits: textHits)
        return (parsed.tokens, results)
    }

    // MARK: Reset

    /// "Analyse neu aufbauen": a running analysis stops first and is waited for, so it cannot
    /// write old results into the fresh tables; Spotlight forgets the old results too.
    func resetAnalysis() async {
        // No new run starts while the tables are cleared.
        analysisResetting = true
        defer { analysisResetting = false }
        if analysis.isRunning {
            analysisControl?.pause()
            analysisTask?.cancel()
        }
        // Foreground and background runs both have a task: waited for until they really
        // ended, not for a fixed time (audit 2, 4.1).
        await analysisTask?.value
        AnalysisMarker.reset()
        do {
            try await store?.resetAnalysis(includingDecisions: false)
        } catch {
            message = error.localizedDescription
        }
        snapshot = nil
        SpotlightIndex.clear()
        await refreshDerived()
    }
}
