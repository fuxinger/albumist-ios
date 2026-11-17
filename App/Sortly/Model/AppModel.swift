import Foundation
import Observation
import UIKit
import SortlyCore
import SortlyEngine
import SortlyStore
import SortlyWorldMap
#if canImport(UIKit)
import UIKit
#endif

/// App state and use cases. Views read it; all work happens in the core/engine actors.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Phase: Equatable {
        case loading
        case onboarding
        /// The introduction was done, but the photo access was taken away later (plugin
        /// review W4): a screen of its own leads to Settings instead of the introduction.
        case noAccess
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
        /// Pause was tapped and the run is finishing the photos in work.
        var pausing = false
        /// Where an unfinished earlier run got to. A run that goes on shows this instead of
        /// "Schritt 1" again until it is back there (first device test 15.11.).
        var resumeFrom: AnalysisMarker.Point?
        /// The same as rules for the card: catching up, the value never shown lower, the
        /// widths that continue once (`ResumedRun`, tested in SortlyEngine).
        var resumed: ResumedRun?
        /// This run's workload, once said (after the trips step): the marker keeps the work
        /// left from it (`AnalysisWorkload.heavyLeft`).
        var workload: AnalysisWorkload?
        /// Photos in the library, from the library read (kept with the marker).
        var libraryPhotos: Int?
        /// How the last run ended, for the 100 % (`LastRunOutcome`): a run that threw has no
        /// outcome, so an earlier complete report never makes the details say 100 %.
        var outcome = LastRunOutcome()
        /// The places step's pass over the offline map: photos checked so far, of how many
        /// (the count of places only rises with the towns, review of d612bc0).
        var mapPass: AnalysisPipeline.MapPass?
        /// The last run ended before it was done without the user pausing it: opening the
        /// app again goes on by itself.
        var needsResume = false
        /// The bar's six segments, fixed for the whole analysis (from the first run's workload,
        /// kept with the marker over Pause and restarts: progress display S6).
        var widths: StepWidths = .standard
        /// Where the last run stood when it ended (the paused card: "Bei 2.433 von 5.683 Fotos").
        var stoppedAt: AnalysisCardState.Position?
        /// Apple's geocoder makes the places step wait ("Apple antwortet gleich").
        var appleWait = false

        var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }
        /// The step the card shows (six steps; the pipeline's groups belong to the last one).
        var step: AnalysisStep? { stage.map(AnalysisStep.init) }
        /// Progress over all steps: one bar that fills once instead of restarting per step.
        var overall: Double {
            step.map { widths.overall(step: $0, completed: completed, total: total) } ?? 0
        }
        var position: AnalysisCardState.Position? {
            step.map { AnalysisCardState.Position(step: $0, completed: completed, total: total) }
        }
        /// Still on the quick first steps of a run that goes on from further ahead.
        var isCatchingUp: Bool {
            resumed?.isCatchingUp(running: isRunning, at: stage?.number) ?? false
        }
        /// The value is held until the run passes where the run before stopped (`ResumedRun`).
        var isHolding: Bool { resumed?.holds(running: isRunning) ?? false }
        /// The last run finished the whole analysis: only then does the card say 100 %.
        var isComplete: Bool { outcome.isComplete(running: isRunning) }
        /// The label of a phase of its own ("Neue Fotos werden analysiert", "Analyse nach
        /// Update"): much more work than when the run it goes on from stopped (`ResumedRun`).
        var newWork: ResumedRun.NewWork? { resumed?.newWork }
        /// The bar's value: never below where the interrupted run had got to, unless a phase
        /// of its own started (`ResumedRun`). A run that ended shows where it stopped (the
        /// paused card said "0 %" or the value the run started from, stress run 43833158673).
        /// Never 100 % before the analysis is complete (`AnalysisPercent`).
        var shownOverall: Double {
            let stopped = isRunning ? nil : stoppedAt.map { widths.overall(step: $0.step, completed: $0.completed, total: $0.total) }
            let value = resumed.map { $0.shown(running: isRunning, catchingUp: isCatchingUp, overall: overall, stopped: stopped) }
                ?? stopped ?? overall
            return AnalysisPercent.value(value, isComplete: isComplete)
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
    /// Every change also reaches the background task's progress (read off the main thread).
    var analysis = AnalysisState() { didSet { ContinuedAnalysis.publish(analysis, finish: analysisFinish) } }

    // MARK: Analysis card (progress display v3)
    // Written by one tick every 250 ms while a run is busy (S2), never per progress report.
    // Kept as separate properties, so the gliding bar (4 changes a second) redraws only the bar.

    /// The card's state; the view only renders it.
    var analysisCard: AnalysisCardState?
    /// The bar as drawn: the real value plus the glide (point 2).
    var analysisBar: Double = 0
    /// "Fertig gegen 23:40" for the whole analysis (point 1); also on the Lock Screen.
    var analysisFinish: FinishEstimate? { didSet { if analysisFinish != oldValue { ContinuedAnalysis.publish(analysis, finish: analysisFinish) } } }
    /// Details: time left in the running step ("noch etwa 12 Min."), checked every 5 s.
    var analysisStepRemaining: Duration?
    /// Details: when this run started ("bisher 18 Min.").
    var analysisStartedAt: Date?
    /// "Gerade angesehen": the last photos of the image step, at most one change a second.
    var analysisRecent: [AssetID] = []
    /// The Lock Screen task really runs (chip "Läuft auch im Hintergrund"), or iOS refused it.
    var analysisBackground: ContinuedAnalysis.Status = .idle
    /// Albumist is on screen (scene active): no gliding, no thumbnails, no announcements otherwise.
    var isOnScreen = true
    /// A long run finished while the app was open: the card says so until the next run or until
    /// the suggestions are opened from it (point 4).
    var analysisFinished: AnalysisFinished?
    struct AnalysisFinished: Equatable {
        var photos: Int
        var proposals: Int
    }
    /// The check mark and haptic of the finished card play once, not on every return.
    @ObservationIgnored private var finishMomentPlayed = false

    /// True the first time the finished card is seen for this run: on screen only, so a run
    /// that ended while the app was in the background plays it when the user comes back
    /// (review minor: it was not shown at all then).
    func claimFinishMoment() -> Bool {
        guard analysisFinished != nil, isOnScreen, !finishMomentPlayed else { return false }
        finishMomentPlayed = true
        return true
    }

    @ObservationIgnored private var progressMailbox = ProgressMailbox()
    @ObservationIgnored private var estimator = ProgressEstimator()
    @ObservationIgnored private var glide = BarGlide()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var runClockStart = ContinuousClock.now
    @ObservationIgnored private var pausingSince: ContinuousClock.Instant?
    @ObservationIgnored private var lastRecentChange: ContinuousClock.Instant?
    @ObservationIgnored private var lastStepRemainingCheck: ContinuousClock.Instant?
    /// The widths came from a workload (this analysis), not the standard ones.
    @ObservationIgnored private var widthsFixed = false
    /// Seconds a run that goes on has worked (not waiting, not pausing, not held in the
    /// background): its time share moves the value from the floor (`ResumedRun.spend`).
    @ObservationIgnored private var resumedActive = 0.0
    /// When the overview last looked for the early suggestions without finding them.
    /// `refreshDerived` calls that overlap: only the newest assigns its result.
    @ObservationIgnored private var derivedCalls = LatestCall()
    /// The open database's stamp (`SortlyStore.identity`), written into the analysis marker.
    @ObservationIgnored private var databaseID: String?
    @ObservationIgnored private var lastEarlyLook: ContinuousClock.Instant?
    /// The fallback look still running (saving the early suggestions can take longer than
    /// 10 s: the looks must not pile up, re-review b).
    @ObservationIgnored private var earlyLookTask: Task<Void, Never>?
    /// Both clocks at the last tick, to tell a real clock jump (`timeChanged`).
    @ObservationIgnored private var lastTickClock: (ContinuousClock.Instant, Date)?
    /// The card showed this run as a full analysis at least once (not only the quick check).
    @ObservationIgnored private var runShowedBar = false
    var snapshot: ProposalSnapshot?
    var decisions: [SortlyID: ProposalDecision] = [:]
    var userTitles: [SortlyID: String] = [:]
    var facts: [AssetFacts] = [] { didSet { bucketCache = [:]; atlasCache = [:]; atlasYearsCache = nil; countryCache = [:]; datesCache = nil; factsIndex = nil; homeCandidatesCache = nil; detectedHomePlaceCache = nil; resetSearchIndex() } }
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
    /// How the sorted count came about, per reason (one line of the diagnostic report).
    @ObservationIgnored var statusReasons = LibraryStatus.Reasons()
    /// Photos with a place or a trip that the ring leaves out (taken at home, no album
    /// suggested), named under the ring so its smaller total is explained.
    var leftOut = LibraryStatus.LeftOut()
    /// "Analyse neu aufbauen" removes the proposals, and photos in the user's own matching
    /// albums count as sorted only through them: the ring fell to 0 % until new proposals came
    /// (device test 15.11., "Und oben null"). The last count stays on screen, marked as being
    /// recounted, until the first new proposals exist or the analysis ends.
    var recount: RecountState? = RecountState.load() {
        didSet { RecountState.save(recount) }
    }
    var inventory = CollectionInventory() { didSet { resetSearchIndex() } }
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
    /// A plan that stopped half way because the app was closed while it ran. Its free albums
    /// are held back until it is continued, kept or taken back (it continues without a new check).
    var interruptedPlan: ChangePlan? {
        didSet {
            Purchases.shared.reserve(for: interruptedPlan)
            // Something was cut off: no App Store rating question in this run (`ReviewPrompt`).
            if interruptedPlan != nil { ReviewPrompt.shared.interruptedPlanFound() }
        }
    }
    var analysisCounts = AnalysisCounts()
    /// The part of the library Albumist works on: everything, or the trial year chosen at
    /// the start (kept for every later run).
    var analysisScope: OrganizationScope = .all
    /// Photos changed while a run was busy: one more run follows when it ends.
    @ObservationIgnored var catchUpAfterRun = false
    /// The user's own trip splits and merges (I07), for the settings.
    private(set) var tripCorrections = TripCorrections()
    /// The user's answers to "Bist du hier öfter?", for the settings.
    private(set) var recurringPlaces = RecurringPlaceAnswers()
    /// What the latest analysis asks about recurring places, and where each trip mostly was.
    private(set) var recurringPlaceReport: RecurringPlaceReport?
    /// What the user set in "Dein Zuhause".
    private(set) var homeSettings = HomeSettings() { didSet { if homeSettings != oldValue { resetSearchIndex() } } }
    /// The home Albumist found by itself in the latest analysis.
    private(set) var detectedHome: DetectedHome?
    /// What the last change in "Dein Zuhause" did to the suggestions, until OK on the overview.
    private(set) var homeChangeNotice: HomeChangeNotice?
    /// A change in "Dein Zuhause" is being applied (the suggestions are made again).
    private(set) var homeChangeRunning = false
    /// An analysis was asked for while a change in "Dein Zuhause" was applied: it starts after,
    /// with what was asked for.
    @ObservationIgnored private var analysisAfterHomeChange: QueuedAnalysis?
    struct QueuedAnalysis {
        var scope: OrganizationScope?
        var mode: AnalysisPipeline.Mode
        var userInitiated: Bool
    }
    @ObservationIgnored private var homeCandidatesCache: [HomeCandidate]?
    @ObservationIgnored private var detectedHomePlaceCache: HomePlace?
    var execution = ExecutionState()
    var message: AppMessage?
    /// Where Siri, Shortcuts or a Spotlight result wants to go; the overview opens it.
    var route: Route?

    enum Route: Hashable {
        case suggestion(SortlyID)
        case country(String)
        /// All open suggestions: "Vorschläge prüfen" on the finished notification (point 4).
        case proposals
    }

    let library = AppPhotoLibrary()
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
    /// "Analyse neu aufbauen" is clearing the tables: no analysis starts meanwhile. Observed: the
    /// suggestion's "Ja, hier bin ich öfter" says why it waits.
    private(set) var analysisResetting = false
    /// One plan at a time (apply, resume, undo, take back): claimed before the first await of
    /// every entry point, released when it ends.
    @ObservationIgnored private var executionClaimed = false
    /// A plan has its claim: it runs, or is about to (`execution.isRunning` follows after an await).
    var isExecutionClaimed: Bool { executionClaimed }
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
            if UITestSupport.rebuildsDatabase, let url = try? Self.databaseURL() {
                SortlyStore.quarantineDatabase(at: url)
                // Where the analysis got to belongs to the database set aside (review of d612bc0:
                // the stale "64 %" was the stress run's drop to 38 %).
                AnalysisMarker.reset()
            }
            // Opened off the main thread: the integrity check and migrations read the file.
            let url = UITestSupport.databaseURL(try Self.databaseURL())
            let store = try await Task.detached(priority: .userInitiated) { try SortlyStore(url: url) }.value
            self.store = store
            // Where the analysis got to (UserDefaults, restored by a device backup) belongs to
            // this database only; the database folder is not backed up (review of 9f0bc40).
            let identity = try await store.identity()
            let hasPhotos = try await store.assetCount() > 0
            databaseID = identity.id
            if let marker = AnalysisMarker.unfinished,
               !ResumedRun.markerApplies(markerDatabase: marker.database, database: identity.id, databaseHasPhotos: hasPhotos) {
                AnalysisMarker.reset()
            } else if identity.isNew, !hasPhotos {
                // A new, empty database: its first analysis is a full one, not a quick check.
                AnalysisMarker.reset()
            }
            access = await library.access()
            // A rebuilt (or newly restored) database gets the user's decisions back first.
            await restoreFromBackupIfNeeded(store)
            lastSafetyBackup = Self.safetyBackupDate()
            do {
                // Fields added by an update come from the defaults (plugin review 15.11., K3).
                settings = try await store.value(OrganizationSettings.self, forKey: Key.settings, defaults: OrganizationSettings()) ?? OrganizationSettings()
            } catch {
                // Not readable even then: the app starts with the standard settings and says
                // so, instead of not starting at all.
                settings = OrganizationSettings()
                message = .failure(String(localized: "Deine Einstellungen ließen sich nicht lesen und stehen wieder auf den Standardwerten. Bitte prüfe sie in den Einstellungen."))
            }
            await dropOldRootFolderDefault(store)
            decisions = try await store.value([SortlyID: ProposalDecision].self, forKey: Key.decisions) ?? [:]
            userTitles = try await store.value([SortlyID: String].self, forKey: Key.titles) ?? [:]
            let map = await Task.detached(priority: .userInitiated) { try? WorldMapResource.load() }.value
            worldMap = map
            pipeline = AnalysisPipeline(
                store: store, reader: library,
                analyzer: UITestSupport.analyzer(VisionAnalyzer()),
                geocoder: UITestSupport.geocoder(SystemGeocoder(locale: Locale(identifier: settings.titleLanguage.rawValue))),
                map: map, conditions: UITestSupport.conditions(DeviceConditions()), settings: settings,
                foregroundOnlineBudget: 60,
                // UI tests slow each photo down to see a run in progress: one lane keeps that.
                contentLanes: UITestSupport.slowsAnalysis ? 1 : 4
            )
            tripCorrections = (try? await pipeline?.tripCorrections()) ?? TripCorrections()
            recurringPlaces = (try? await pipeline?.recurringPlaceAnswers()) ?? RecurringPlaceAnswers()
            homeSettings = (try? await pipeline?.homeSettings()) ?? HomeSettings()
            analysisScope = (try? await pipeline?.storedScope()) ?? .all
            // A plan that finished right before the app was closed stores its results now,
            // before the album check in `refreshDerived` compares: what the plan changed is not
            // the user's doing (plugin review W2).
            await finishPendingFinalizations()
            await refreshDerived()
            // A plan that stopped half way (app closed during "Jetzt umsetzen") is offered
            // on the overview: continue or take back.
            interruptedPlan = try? await store.openInterruptedPlan()
            // Photo access taken away after the introduction: a screen of its own, not the
            // introduction again, whose "Analyse starten" would replace the part of the library
            // chosen before (plugin review W4).
            switch StartScreen.after(onboardingDone: onboardingDone, access: access) {
            case .introduction: phase = .onboarding
            case .noPhotoAccess: phase = .noAccess
            case .main: phase = .ready
            }
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
            SortlyStore.quarantineDatabase(at: url)
        }
        // The new database starts from nothing: no "Macht da weiter … 64 %" over an empty one.
        AnalysisMarker.reset()
        bootstrapTask = nil
        phase = .loading
        await bootstrap()
        // The new database is empty: the analysis starts right away, as at a normal launch.
        if phase == .ready && access.canRead && !UITestSupport.isRunning {
            LibraryChangeWatcher.shared.start()
            startAnalysis()
        }
    }

    // MARK: Safety backup

    /// When the decisions were last copied for the device backup (shown under Verlauf).
    private(set) var lastSafetyBackup: Date?
    /// Set when this start restored the decisions from the copy; the overview says so once.
    var restoredFromBackup: BackupRestore?
    /// Suggestions an update of the matching rules set back to open (re-check 16.11.): their
    /// "ergänzen" was accepted under the old rules and is no longer a certain match. The
    /// overview says so until the user taps OK. The count is stored by the pipeline in the
    /// same transaction as the reopened decisions (`AnalysisPipeline.recheckedSuggestionsKey`).
    var recheckedSuggestions = 0

    /// "OK" on the card.
    func dismissRecheckNotice() {
        recheckedSuggestions = 0
        Task { try? await store?.setValue(0, forKey: AnalysisPipeline.recheckedSuggestionsKey) }
    }

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
        // The rule for full, limited and no access is `SafetyBackup.belongsToLibrary` (tested).
        var visible: Set<CollectionID>?
        if !backup.managedAlbums.isEmpty && access.canRead, let inventory = try? await library.currentInventory() {
            visible = Set(inventory.albums.map(\.id))
        }
        return backup.belongsToLibrary(access: access, visibleAlbums: visible)
    }

    /// After the photo access was granted or widened: album records waiting in the copy
    /// come back now if they belong to this library.
    private func restoreWaitingLibraryState() async {
        guard pendingLibraryRestore != nil, access.canRead, let store else { return }
        guard await restoreFromBackupIfNeeded(store) else {
            // Another library: the card already says so; the copy was renewed.
            return
        }
        settings = (try? await store.value(OrganizationSettings.self, forKey: Key.settings, defaults: OrganizationSettings())) ?? settings
        decisions = (try? await store.value([SortlyID: ProposalDecision].self, forKey: Key.decisions)) ?? decisions
        userTitles = (try? await store.value([SortlyID: String].self, forKey: Key.titles)) ?? userTitles
        await pipeline?.update(settings: settings)
        // Plans of the copy that ran but were not finished then are finished now (audit 2, 3.1),
        // before the album check in `refreshDerived` compares (plugin review W2).
        await finishPendingFinalizations()
        await refreshDerived()
        interruptedPlan = try? await store.openInterruptedPlan()
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
        followAccess()
    }

    /// Reads the access again, e.g. after the user came back from the Settings app.
    func refreshAccess() async {
        access = await library.access()
        await restoreWaitingLibraryState()
        followAccess()
    }

    /// The access is back on the "Kein Zugriff" screen (plugin review W4): Albumist goes on
    /// where it was, with the part of the library chosen before. The scope is not touched.
    private func followAccess() {
        guard phase == .noAccess, StartScreen.noPhotoAccess.afterAccessChange(to: access) == .main else { return }
        phase = .ready
        LibraryChangeWatcher.shared.start()
        if !UITestSupport.isRunning { startAnalysis() }
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
        // A change in "Dein Zuhause" is being applied: the run starts right after it, so it
        // never takes the run lock in the middle of the change. Several requests meanwhile are
        // one run; one started by a tap keeps what a tap gets (background time, retries reset).
        if homeChangeRunning {
            let queued = analysisAfterHomeChange
            analysisAfterHomeChange = QueuedAnalysis(scope: scope ?? queued?.scope,
                                                     mode: mode == .incremental ? (queued?.mode ?? mode) : mode,
                                                     userInitiated: userInitiated || (queued?.userInitiated ?? false))
            return
        }
        analysis.isRunning = true
        analysis.needsResume = false
        analysis.pausing = false
        analysis.stage = nil
        analysis.completed = 0
        analysis.total = 0
        analysis.waiting = nil
        analysis.appleWait = false
        analysis.stoppedAt = nil
        analysis.resumeFrom = AnalysisMarker.unfinished
        analysis.resumed = analysis.resumeFrom.map {
            ResumedRun(stage: $0.stage, completed: $0.completed, shown: $0.overall, left: $0.left, photos: $0.photos,
                       seconds: $0.secondsLeft, updated: $0.version.map { $0 != AnalysisPipeline.analysisVersion } ?? false,
                       newWork: $0.newWork, caughtUp: $0.caughtUp)
        }
        analysis.workload = nil
        analysis.libraryPhotos = nil
        analysis.outcome.started()
        resumedActive = 0
        analysis.mapPass = nil
        HeatLog.reset()
        analysis.kind = analysis.resumeFrom != nil ? .resume : (AnalysisMarker.completedOnce ? .check : .first)
        // The widths of the analysis this run goes on with; a new analysis gets them from its
        // workload (said at the end of the trips step).
        let storedWidths = analysis.resumeFrom?.widths
        analysis.widths = storedWidths ?? .standard
        widthsFixed = storedWidths != nil
        analysisFinished = nil
        finishMomentPlayed = false
        beginCard()
        if userInitiated {
            // A quick check for new photos ("Neu prüfen") needs no background time: asking for
            // it put "Albumist analysiert deine Fotos · Schritt 1 von 7" on the Lock Screen for
            // a few seconds after every check (device test 15.11. 23:16).
            if analysis.kind != .check {
                ContinuedAnalysis.requestNotificationPermission()
                ContinuedAnalysis.begin()
            }
            unattendedRetries = 0
        }
        analysisGeneration += 1
        let generation = analysisGeneration
        let control = AnalysisRunControl()
        analysisControl = control
        startTicks(run: generation)
        analysisTask = Task {
            if let scope {
                try? await pipeline.setScope(scope)
                analysisScope = scope
            }
            // The report of this run only: a run that fails never reuses the success of the
            // one before (audit 2, 4.2).
            var finished: AnalysisPipeline.Report?
            do {
                // Kept in the mailbox; the card's tick takes the newest every 250 ms (S2: no task
                // per report on the main actor).
                let mailbox = progressMailbox
                let report = try await pipeline.run(mode: mode, control: control, onProgress: { progress in
                    mailbox.post(progress)
                }, onWaiting: { reason in
                    // Into the same mailbox as the progress, so the tick applies both in the
                    // order the pipeline said them (see `ProgressMailbox.wait`).
                    mailbox.wait(reason)
                })
                analysis.lastReport = report
                analysis.lastRun = Date()
                finished = report
            } catch is CancellationError {
                // Stopped on purpose ("Analyse neu aufbauen", a new scope): not an error to show
                // (plugin review N3: "Swift.CancellationError error 1").
            } catch {
                message = .failure(error.localizedDescription)
            }
            if analysisControl === control { analysisControl = nil }
            // This run's own outcome (nil when it threw): the 100 % follows only this.
            analysis.outcome.ended(with: finished)
            BackgroundRunLog.runEnded(paused: finished?.pausedBecause?.rawValue,
                                      complete: finished?.isComplete == true,
                                      analyzerFailing: finished?.analyzerUnavailable == true,
                                      stage: analysis.stage?.number)
            // Ended early without the user's Pause (an error, the app's time ran out, the photo
            // access was changed in Settings): the next time the app is opened it goes on by
            // itself; with the access back, from where it was. Set before isRunning, so the Lock
            // Screen reads how this run ended, not the run before (ContinuedAnalysis.ending).
            let reason = finished?.pausedBecause
            // The last reports of this run, before it is shown as ended.
            tick(run: generation)
            let celebrate = AnalysisCardState.celebratesFinish(isComplete: finished?.isComplete == true,
                                                               wasQuickCheck: !runShowedBar,
                                                               ranFor: ContinuousClock.now - runClockStart)
            analysis.stoppedAt = analysis.position
            analysis.needsResume = finished == nil || (reason != nil && reason != .userPaused)
            analysis.isRunning = false
            analysis.pausing = false
            analysis.stage = nil
            analysis.waiting = nil
            analysis.appleWait = false
            endCard()
            if finished?.isComplete == true {
                AnalysisMarker.finished()
                analysis.resumeFrom = nil
                analysis.resumed = nil
            }
            if reason == .accessRevoked {
                // Shown as it is now (limited or none), so the overview offers the way back.
                access = await library.access()
            }
            await refreshDerived()
            // Trip identities (names and corrections stay with their trip) are kept in the copy.
            saveSafetyBackup()
            // "Analyse fertig" only when it really finished (not paused, stopped or failed), and
            // not for a quick check (point 4): in the app the card, outside it the notification.
            // Outside the app also the notification; the card shows the moment once the app
            // is on screen again.
            if celebrate, !Task.isCancelled {
                analysisFinished = AnalysisFinished(photos: analysisCounts.analyzed, proposals: openProposals.count)
                updateCard()
                if UIApplication.shared.applicationState != .active {
                    ContinuedAnalysis.notifyFinished(openSuggestions: openProposals.count)
                }
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

    /// Progress of the running analysis, taken from the mailbox by the tick. A count never goes
    /// back within a stage, and a stage never goes back (late reports of the same run).
    private func receive(_ progress: AnalysisPipeline.Progress, at now: ContinuousClock.Instant) {
        guard analysis.isRunning else { return }
        if let stage = analysis.stage {
            if progress.stage.number < stage.number { return }
            if progress.stage == stage, progress.completed < analysis.completed { return }
        }
        // Trips and places are ready before the image analysis: show them now ("Schon fertig").
        // (Compared by number: with the tick, the report that starts the image step may be
        // replaced by a later one before it is taken.)
        if progress.stage.number >= AnalysisPipeline.Stage.content.number,
           (analysis.stage?.number ?? 0) < AnalysisPipeline.Stage.content.number, snapshot == nil {
            Task { await refreshDerived() }
        }
        // First scan: the photos are known after reading the library (for the scan show).
        if progress.stage == .patterns, analysis.stage == .inventory, facts.isEmpty {
            Task { await refreshDerived() }
        }
        analysis.stage = progress.stage
        analysis.completed = progress.completed
        analysis.total = progress.total
        // Not cleared here: a report sent just before a wait for the device began can be taken
        // after it (the tick runs every 250 ms); the wait comes and goes with the pipeline's
        // own word, taken in order from the mailbox (`tick`).
        analysis.appleWait = progress.waitLeft != nil
        analysis.mapPass = progress.stage == .places ? progress.mapPass : nil
        let step = AnalysisStep(progress.stage)
        if !analysis.pausing {
            estimator.record(step: step, completed: progress.completed, total: progress.total, at: now,
                             appleWait: progress.waitLeft != nil)
        }
        if progress.stage == .inventory, progress.total > 0 {
            analysis.libraryPhotos = progress.total
            // A marker of an older version without the time left: the usual time for the
            // library's photos (`ResumedRun.library`, review of c772325).
            analysis.resumed?.library(photos: progress.total)
        }
        // A run that goes on (`ResumedRun`, reviews of 83db832 and 11ef3e1):
        // - the value never goes below the floor and moves with the time the run works
        //   (`ResumedRun.spend`, tick); the real value takes over once it is ahead;
        // - until the run passes the position the run before stopped at, the marker keeps
        //   that position and the card says "Macht da weiter" before that step;
        // - much more work starts a phase of its own with its label, with the workload (tick).
        if var resumed = analysis.resumed {
            resumed.back(at: progress.stage.number, completed: progress.completed, total: progress.total)
            analysis.resumed = resumed
        }
        // Kept across launches: a run that iOS ended goes on from here (see `resumeFrom`), with
        // the value shown, the position and the work left then. Before this run's workload is
        // known, the work left and the library of the run before are kept.
        // Before the run is back where the run before stopped, the marker keeps that position
        // (the furthest the analysis got) with the value shown now, so a run cut off meanwhile
        // goes on from here without counting work done before the stop again.
        do {
            let held = analysis.isHolding ? analysis.resumeFrom : nil
            let carried = analysis.workload == nil ? analysis.resumeFrom : nil
            AnalysisMarker.unfinished = .init(
                stage: held?.stage ?? progress.stage.number, overall: analysis.shownOverall,
                widths: widthsFixed ? analysis.widths : nil, database: databaseID,
                left: analysis.workload.map { $0.heavyLeft(at: step, completed: progress.completed, total: progress.total) }
                    ?? carried?.left,
                photos: carried?.photos ?? analysis.libraryPhotos,
                version: carried?.version ?? AnalysisPipeline.analysisVersion,
                newWork: analysis.newWork,
                completed: held != nil ? held?.completed : progress.completed,
                total: held != nil ? held?.total : progress.total,
                secondsLeft: estimator.estimatedRemaining.map { Double($0.components.seconds) }
                    ?? (carried != nil ? analysis.resumed?.secondsThen ?? carried?.secondsLeft : nil),
                caughtUp: held != nil ? analysis.resumed?.caughtUp : nil)
        }
        glide.update(real: analysis.shownOverall, at: now, step: step, widths: analysis.widths,
                     itemsPerSecond: estimator.rate, total: progress.total)
        keepRunningInBackgroundIfLong()
    }

    // MARK: Analysis card tick

    /// A run starts: everything the card measured for the run before is forgotten.
    private func beginCard() {
        tickTask?.cancel()
        progressMailbox = ProgressMailbox()
        estimator.reset()
        // Going on with the same analysis: from the bar drawn last (never a step back).
        if analysis.resumeFrom != nil {
            glide.reset(keeping: max(analysisBar, analysis.shownOverall))
        } else {
            glide.reset()
        }
        runClockStart = .now
        pausingSince = nil
        lastRecentChange = nil
        lastStepRemainingCheck = nil
        lastEarlyLook = nil
        runShowedBar = false
        analysisBar = glide.value(at: .now, gliding: false)
        analysisFinish = nil
        analysisStepRemaining = nil
        analysisStartedAt = Date()
        analysisRecent = []
        updateCard()
    }

    /// One tick every 250 ms for the run `run` (its generation), until the run ends.
    private func startTicks(run: Int) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(run: run)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The run ended: the tick stops; the card shows how it ended.
    private func endCard() {
        tickTask?.cancel()
        tickTask = nil
        pausingSince = nil
        analysisFinish = nil
        analysisStepRemaining = nil
        analysisRecent = []
        analysisBackground = .idle
        updateCard()
    }

    /// One tick (every 250 ms while a run is busy, S2): takes the newest progress, measures the
    /// speed, moves the bar, and decides what the card says. Nothing here runs per report.
    private func tick(run: Int) {
        guard run == analysisGeneration, analysis.isRunning else { return }
        let now = ContinuousClock.now
        let taken = progressMailbox.take()
        let previousTick = lastTickClock?.0
        lastTickClock = (now, Date())
        if let workload = taken.workload {
            estimator.setWorkload(workload)
            analysis.workload = workload
            // Much more work left than when the run it goes on from stopped, or new work the
            // number could not visibly move through: a phase of its own ("Analyse nach Update",
            // "Neue Fotos werden analysiert", "Weitere neue Fotos werden analysiert") with this
            // workload's widths, from its own start (`ResumedRun.workload`).
            var startsPhase = false
            if var resumed = analysis.resumed {
                startsPhase = resumed.workload(workload, remaining: estimator.estimatedRemaining.map {
                    Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
                })
                analysis.resumed = resumed
            }
            if startsPhase {
                analysis.widths = StepWidths(workload: workload)
                widthsFixed = true
                glide.reset()
                if let step = analysis.step {
                    glide.update(real: analysis.shownOverall, at: now, step: step, widths: analysis.widths,
                                 itemsPerSecond: nil, total: analysis.total)
                }
            } else if !widthsFixed {
                // Before this the first two steps used the standard widths. The bar goes on
                // under the new widths (review I3: holding the old value made it stand still
                // well into the places step). Where the new widths put the end of the trips
                // step below what was shown (8 % with the standard widths), they continue from
                // the value shown (`StepWidths.continuing`), so neither the bar nor the number
                // ever falls (review of 9f0bc40).
                let held = max(analysis.shownOverall, analysisBar)
                var widths = StepWidths(workload: workload)
                let at = taken.progress.map { (AnalysisStep($0.stage), $0.completed, $0.total) }
                    ?? analysis.step.map { ($0, analysis.completed, analysis.total) }
                // While a run that goes on holds its value, it is not continued from here: the
                // held value is drawn anyway, and the rest is spread from the stopped position
                // once the run is past it (`ResumedRun.back`, review of 11ef3e1).
                if !analysis.isHolding, let at, let continued = widths.continuing(held: held, step: at.0, completed: at.1, total: at.2) {
                    widths = continued
                }
                analysis.widths = widths
                widthsFixed = true
                glide.reset(keeping: analysisBar)
                if let step = analysis.step {
                    glide.update(real: analysis.shownOverall, at: now, step: step, widths: analysis.widths,
                                 itemsPerSecond: nil, total: analysis.total)
                }
            }
        }
        if let progress = taken.progress { receive(progress, at: now) }
        // Hot iPhone, battery nearly empty: as the pipeline said last, after its reports.
        if taken.waiting != analysis.waiting { analysis.waiting = taken.waiting }
        // "Schon fertig": the early suggestions are read once they are saved (the report that
        // starts the image step comes before that, review I2). Should that read miss them,
        // it is tried again during the image step (the only step they are made in; refreshDerived
        // is not cheap, so not in the later ones): every 10 s for each full 5,000 photos,
        // at least every 10 s (`AnalysisCardState.earlyLookInterval`: 50,000 photos, every 100 s).
        if taken.earlyProposals {
            lastEarlyLook = now
            Task { await refreshDerived() }
        } else if snapshot == nil, analysis.stage == .content, earlyLookTask == nil,
                  lastEarlyLook.map({ now - $0 >= AnalysisCardState.earlyLookInterval(photos: analysis.total) }) ?? true {
            lastEarlyLook = now
            earlyLookTask = Task {
                await refreshDerived()
                earlyLookTask = nil
            }
        }
        // Thumbnails at most once a second, and only while someone can see them (S9).
        if isOnScreen, !taken.recent.isEmpty, analysis.stage == .content,
           lastRecentChange.map({ now - $0 >= .seconds(1) }) ?? true, taken.recent != analysisRecent {
            analysisRecent = taken.recent
            lastRecentChange = now
        }
        if analysis.stage != .content, !analysisRecent.isEmpty { analysisRecent = [] }
        // No time while it waits, is paused, or is held in the background (S4).
        let background = ContinuedAnalysis.status
        let idle = analysis.waiting != nil || analysis.pausing || (!isOnScreen && background != .running)
        if idle {
            estimator.idle()
        }
        // A run that goes on: the value moves from the floor with the time it works, as a
        // share of the time left by the best estimate now (`ResumedRun.spend`, review of
        // 0305d20: nothing stands still, neither the number nor the bar).
        if var resumed = analysis.resumed, !resumed.ownStart, analysis.stage != nil {
            if !idle, let previousTick {
                let d = (now - previousTick).components
                resumedActive += min(1, Double(d.seconds) + Double(d.attoseconds) / 1e18)
            }
            let before = analysis.shownOverall
            resumed.spend(active: resumedActive, remaining: estimator.estimatedRemaining.map {
                Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18
            })
            if resumed != analysis.resumed {
                analysis.resumed = resumed
                if let step = analysis.step, analysis.shownOverall > before + 1e-9 {
                    glide.update(real: analysis.shownOverall, at: now, step: step, widths: analysis.widths,
                                 itemsPerSecond: estimator.rate, total: analysis.total)
                }
            }
        }
        let finish = estimator.finish(at: now, wall: Date())
        if finish != analysisFinish { analysisFinish = finish }
        if lastStepRemainingCheck.map({ now - $0 >= .seconds(5) }) ?? true {
            lastStepRemainingCheck = now
            let left = estimator.stepRemaining
            if left != analysisStepRemaining { analysisStepRemaining = left }
        }
        // The bar glides only while really working, on screen, without Reduce Motion (point 2).
        let gliding = analysis.waiting == nil && !analysis.pausing && isOnScreen && !UIAccessibility.isReduceMotionEnabled
        let bar = glide.value(at: now, gliding: gliding)
        if abs(bar - analysisBar) > 0.000_05 { analysisBar = bar }
        if background != analysisBackground { analysisBackground = background }
        updateCard(now: now)
    }

    /// Decides the card's state from the model (pure rules in `AnalysisCardState`).
    func updateCard(now: ContinuousClock.Instant = .now) {
        var i = AnalysisCardState.Inputs()
        i.isRunning = analysis.isRunning
        i.isQuickCheck = isQuickCheck
        i.runningFor = now - runClockStart
        i.position = analysis.position
        if analysis.isCatchingUp, let resume = analysis.resumeFrom {
            i.catchingUpTo = AnalysisPipeline.Stage.allCases.indices.contains(resume.stage - 1)
                ? AnalysisStep(AnalysisPipeline.Stage.allCases[resume.stage - 1]).number : nil
        }
        i.waiting = analysis.waiting
        i.slower = analysis.isRunning ? DeviceState(
            thermal: DeviceState.Thermal(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .critical,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        ).slowerReason : nil
        i.appleWait = analysis.appleWait
        i.pausingFor = analysis.pausing ? pausingSince.map { now - $0 } ?? .zero : nil
        i.pausedByUser = !analysis.isRunning && !analysis.needsResume && analysis.lastReport?.pausedBecause == .userPaused
        i.pausedAt = analysis.stoppedAt
        i.finished = analysisFinished.map { (photos: $0.photos, proposals: $0.proposals) }
        let state = AnalysisCardState.resolve(i)
        if analysis.isRunning, let state, state != .quickCheck(showsPause: true), state != .quickCheck(showsPause: false) {
            runShowedBar = true
        }
        if state != analysisCard { analysisCard = state }
    }

    /// The photo mosaic under the card: during the first analysis only (`ScanShowRule`).
    var showsScanShow: Bool {
        ScanShowRule.shows(isRunning: analysis.isRunning, firstAnalysis: !AnalysisMarker.completedOnce,
                           isQuickCheck: isQuickCheck)
    }

    /// The mosaic's light sweep moves (`ScanShowRule.animates`). Read with the card's state,
    /// which changes when the heat does (`slower`, `waiting`), so the view follows it.
    func scanShowAnimates(reduceMotion: Bool) -> Bool {
        ScanShowRule.animates(card: analysisCard, isOnScreen: isOnScreen,
                              thermal: DeviceState.Thermal(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .critical,
                              reduceMotion: reduceMotion)
    }

    /// A check for new photos after everything was analysed once: no step numbers and no bar
    /// that starts at zero again, only "Sucht neue Fotos", unless there is real work to show.
    var isQuickCheck: Bool {
        guard analysis.kind == .check else { return false }
        if let stage = analysis.stage, [.content, .text].contains(stage), analysis.remaining >= 50 { return false }
        return true
    }

    /// The clock or the time zone was changed (`significantTimeChangeNotification`): the
    /// finish time is a clock time, so it is measured anew (review minor).
    func timeChanged() {
        guard analysis.isRunning, let last = lastTickClock else { return }
        let now = (ContinuousClock.now, Date())
        lastTickClock = now
        // Midnight and small carrier corrections send this too: only a real jump counts.
        guard ProgressEstimator.clockJumped(wallThen: last.1, wallNow: now.1, elapsed: now.0 - last.0) else { return }
        estimator.idle()
        analysisFinish = nil
    }

    /// Scene changes (`SortlyApp`): gliding, thumbnails and announcements only on screen.
    func sceneChanged(onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        if !onScreen {
            analysisRecent = []
            // A rating question that waits is dropped: never when the user comes back (`ReviewPrompt`).
            ReviewPrompt.shared.sceneLeft()
        }
    }

    /// A run with real work left asks iOS to go on after the user leaves the app.
    func keepRunningInBackgroundIfLong() {
        // Only real image or text work counts. The places step reports every town still
        // missing as "remaining" although a run in the app looks up at most a few, so every
        // quick check asked iOS for background time (device test 15.11. 23:16: the Lock Screen
        // and the Dynamic Island showed the analysis every few seconds).
        guard analysis.isRunning, let stage = analysis.stage,
              [.content, .text].contains(stage), analysis.remaining >= 100 else { return }
        ContinuedAnalysis.begin()
    }

    /// The app is on screen again: a run that iOS ended goes on by itself, and a run still
    /// busy asks for background time again (the last request may have run out).
    func sceneBecameActive() {
        // Back from the Settings app on the "Kein Zugriff" screen: the access may be back (W4).
        if phase == .noAccess {
            Task { await refreshAccess() }
            return
        }
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
        // Shown at once: the photos in work are finished first, which can take a moment
        // (device test 15.11.: "Pause reagiert nicht"). The card changes in this same call, not
        // with the next tick (limit: a visible reaction in under 1 s).
        if analysis.isRunning, !analysis.pausing {
            analysis.pausing = true
            pausingSince = .now
            estimator.idle()
            updateCard()
        }
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
        updateCard()
        defer {
            analysis.isRunning = false
            analysis.pausing = false
            updateCard()
        }
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
            if analysis.outcome.refined(with: report) {
                // Complete now: nothing to go on with (review of c772325: the card read 100 %
                // and then "Macht da weiter · 37 %" from the marker of the run before).
                AnalysisMarker.finished()
                analysis.needsResume = false
                analysis.resumeFrom = nil
                analysis.resumed = nil
            }
            await refreshDerived()
            saveSafetyBackup(immediately: true)
            return report.pausedBecause == nil
        } catch {
            // Cut off (iOS ended the background time): what was analysed stays analysed.
            return false
        }
    }

    func refreshDerived() async {
        guard let store, let pipeline else { return }
        let call = derivedCalls.begin()
        await reconcileManagedAlbums(quiet: true)
        do {
            // Results of an older matching version are matched again once (review 16.11.).
            let refresh = try await pipeline.refreshMatchesIfOutdated()
            snapshot = refresh.snapshot
            reopenAfterRecheck(refresh.reopened)
            recheckedSuggestions = try await store.value(Int.self, forKey: AnalysisPipeline.recheckedSuggestionsKey) ?? 0
            recurringPlaceReport = try await pipeline.recurringPlaceReport()
            detectedHome = try await pipeline.detectedHome()
            homeChangeNotice = try await pipeline.homeChangeNotice()
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
            let contents = try await store.results(ContentAnalysis.self, kind: "content")
            let stored = try await store.overrides()
            let overrides = OverrideSet(stored)
            var removed: [SortlyID: Set<AssetID>] = [:]
            for o in stored where o.decision == .neverAdd {
                if case .assetInSource(let asset, let source) = o.scope { removed[source, default: []].insert(asset) }
            }
            removedFromProposals = removed
            // Everything that grows with the library is worked out off the main actor; here
            // it is only assigned (review of d612bc0: with 50,000 photos this was seconds of
            // main-thread work at every call, a lead for the 7 s Pause tap of the stress run).
            let facts = facts, snapshot = snapshot, settings = settings
            let managed = managedAlbums, scope = analysisScope
            let derived = await Task.detached(priority: .userInitiated) {
                DerivedLibraryStatus.derive(facts: facts, snapshot: snapshot, settings: settings, overrides: overrides,
                                            contents: contents, managed: managed, inventory: inventory, scope: scope)
            }.value
            // A newer call started meanwhile, or the part of the library changed: this result
            // is older than what is or will be shown (review of 9f0bc40).
            guard derivedCalls.isNewest(call), scope == analysisScope else { return }
            states = derived.states
            statusReasons = derived.reasons
            progress = derived.progress
            leftOut = derived.leftOut
            // Not with the early set of a first run (trips and places only): the count would
            // be shown as final hours before the image analysis is done (review minor).
            if recount != nil, (snapshot?.isEarly == false && !proposals.isEmpty)
                || (!analysis.isRunning && analysis.lastReport?.isComplete == true) {
                recount = nil
            }
            analysisCounts = AnalysisCounts(photos: derived.photos, analyzed: derived.analyzed, unreadable: derived.unreadable)
        } catch {
            message = .failure(error.localizedDescription)
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
    /// A possible match is no clear action: a similar album of the user exists, so the user
    /// looks at it first (review 16.11.).
    func starterSet(limit: Int) -> [AlbumProposal] {
        func rank(_ p: AlbumProposal) -> Int {
            switch p.kind.area {
            case .trips: 2
            case .places: 1
            default: 0
            }
        }
        return Array(openProposals
            .filter { ProposalDecision.isSafeToAcceptUnseen($0, match: match(for: $0)) }
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
            message = .failure(error.localizedDescription)
            return false
        }
    }

    // MARK: Places the user is often at

    /// A trip, or the album that gathers several trips to one place ("Reisen › Garmisch"):
    /// the suggestions where "Keine Reise, hier bin ich öfter" makes sense. Like the trip
    /// workshop, only while Albumist has not made the album yet: an album that exists would
    /// lose the trips it stands for.
    private func isTripLike(_ proposal: AlbumProposal) -> Bool {
        let tripFolder = Labels(settings.titleLanguage).folder(for: .trips)
        switch proposal.kind {
        case .trip: break
        case .placeCollection where proposal.folderPath.first == tripFolder: break
        default: return false
        }
        return !managedAlbums.contains { $0.allSourceIDs.contains(proposal.id) }
    }

    /// The open question "Bist du hier öfter?" on this suggestion: asked once per place, on
    /// any of its trips, until the user answers it there or on another trip.
    func recurringPlaceQuestion(for proposal: AlbumProposal) -> RecurringPlaceCandidate? {
        guard isTripLike(proposal), let report = recurringPlaceReport else { return nil }
        let facts = factsByID
        guard let question = report.question(for: proposal, tripOf: { facts[$0]?.tripID }) else { return nil }
        // Answered since the last analysis ("Nein" starts none): not asked again.
        return recurringPlaces.answer(near: question.center) == nil ? question : nil
    }

    /// Whether "Keine Reise, hier bin ich öfter" can be offered: the place of the trip is known.
    func canMarkRecurringPlace(_ proposal: AlbumProposal) -> Bool {
        guard isTripLike(proposal), let report = recurringPlaceReport else { return false }
        let facts = factsByID
        return report.place(for: proposal, tripOf: { facts[$0]?.tripID }) != nil
    }

    /// "Ja, hier bin ich öfter" and "Keine Reise, hier bin ich öfter" (`oftenHere`), or "Nein,
    /// das sind Reisen", for the place of this suggestion. The answer is kept by position,
    /// stored next to the trip corrections and part of the decisions copy in the backup. A
    /// "Ja" changes the trips, so the analysis runs again; a "Nein" changes nothing but the
    /// question.
    func answerRecurringPlace(_ oftenHere: Bool, for proposal: AlbumProposal) async -> Bool {
        guard let report = recurringPlaceReport else { return false }
        let facts = factsByID
        let tripOf: (AssetID) -> SortlyID? = { facts[$0]?.tripID }
        guard let center = report.question(for: proposal, tripOf: tripOf)?.center ?? report.place(for: proposal, tripOf: tripOf) else { return false }
        // The place's name as the suggestion shows it, for the settings only; never what the
        // place is to the user.
        let name: String? = proposal.reasons.lazy.compactMap { reason -> String? in
            switch reason {
            case .photosInPlaceDuringPeriod(_, let place, _, _), .photosInPlace(_, let place): place
            default: nil
            }
        }.first ?? (proposal.kind == .trip ? nil : proposal.title)
        // "Ja" changes the trips: applied like every change in "Dein Zuhause" (only the
        // suggestions are made again, what the user chose stays, the overview is told).
        if oftenHere {
            return await changeHome(places: { $0.answering(true, at: center, name: name, date: .now) })
        }
        return await changeRecurringPlaces(rerun: false) { $0.answering(false, at: center, name: name, date: .now) }
    }

    /// The album suggestion of a place the user is often at, for its name in the settings.
    func recurringPlaceProposal(for answer: PlaceAnswer) -> AlbumProposal? {
        let id = RecurringPlaces.proposalID(for: answer.id)
        return proposals.first { $0.id == id }
    }

    /// "Wieder als Reisen zeigen" in "Dein Zuhause": the stays there are trips again. Remembered
    /// as "Nein", so the question does not come right back. Like every change there, only the
    /// suggestions are made again.
    func withdrawRecurringPlace(_ answer: PlaceAnswer) async -> Bool {
        await changeHome(places: { $0.withdrawing(answer.id, date: .now) })
    }

    /// Like `changeTrips`: an answer that changes the trips is not stored while an analysis
    /// already read the old answers.
    private func changeRecurringPlaces(rerun: Bool, _ change: (RecurringPlaceAnswers) -> RecurringPlaceAnswers) async -> Bool {
        guard let pipeline, !rerun || (!analysis.isRunning && !execution.isRunning) else { return false }
        do {
            let updated = change(try await pipeline.recurringPlaceAnswers())
            try await pipeline.setRecurringPlaceAnswers(updated)
            recurringPlaces = updated
            saveSafetyBackup()
            if rerun { startAnalysis() }
            return true
        } catch {
            message = .failure(error.localizedDescription)
            return false
        }
    }

    // MARK: Dein Zuhause

    /// Changes in "Dein Zuhause" wait while an analysis or a plan runs: the analysis already
    /// read the old settings, and a plan must not see its suggestions change under it.
    var canChangeHome: Bool {
        pipeline != nil && !analysis.isRunning && !execution.isRunning && !executionClaimed && !homeChangeRunning && !analysisResetting
    }

    /// The detected home with its name from the user's own photos (town, or offline the region).
    /// Named once per analysis result, not on every redraw of the settings.
    var detectedHomePlace: HomePlace? {
        access(keyPath: \.facts)
        guard let detectedHome else { return nil }
        if let cached = detectedHomePlaceCache, cached.center == detectedHome.center { return cached }
        let place = HomePlace(center: detectedHome.center, components: HomeName.components(near: detectedHome.center, facts: facts))
        detectedHomePlaceCache = place
        return place
    }

    /// The places of the library the user can choose from, most photo days first.
    var homeCandidates: [HomeCandidate] {
        access(keyPath: \.facts)
        if let homeCandidatesCache { return homeCandidatesCache }
        let candidates = HomeCandidates.make(facts: facts)
        homeCandidatesCache = candidates
        return candidates
    }

    /// The places the user is often at ("Eltern", "Zweitwohnung", answers to "Bist du hier öfter?").
    var personalPlaces: [PlaceAnswer] { recurringPlaces.oftenHere }

    /// "Stimmt" on the detected home: from now on; the past stays as the detection sees it
    /// (`HomeSettings.confirmedFrom`). Not offered while the home has no name yet.
    func confirmDetectedHome() async {
        guard let place = detectedHomePlace, place.components != nil else { return }
        _ = await changeHome(home: { $0.confirming(place, date: .now) })
    }

    /// A place the user chose under "Ändern", their home since `since` ("Seit wann wohnst du
    /// dort?"). Before that day the detection decides, as after "Stimmt", so the years in the old
    /// town never become a trip; former homes the user entered win for their periods.
    func chooseHome(_ candidate: HomeCandidate, since: Date) async {
        let from = Calendar.current.startOfDay(for: since)
        _ = await changeHome(home: { $0.choosing(candidate.homePlace, from: from, date: .now) })
    }

    /// The proposed answer to "Seit wann wohnst du dort?": the first day of the latest stay near
    /// the place in the user's photos (`HomeCandidates.stayStart`); today without one.
    func homeStayStart(_ candidate: HomeCandidate) -> Date {
        HomeCandidates.stayStart(near: candidate.center, assets: facts.lazy.map(\.asset)) ?? Calendar.current.startOfDay(for: .now)
    }

    /// "Kein Zuhause festlegen".
    func chooseNoHome() async {
        _ = await changeHome(home: { $0.withoutHome(date: .now) })
    }

    /// "Automatisch erkennen": Albumist's detection decides again (former homes stay).
    func chooseAutomaticHome() async {
        _ = await changeHome(home: { $0.automatic(date: .now) })
    }

    /// "Früheres Zuhause hinzufügen": the user lived at `candidate` up to and including the day `until`.
    func addFormerHome(_ candidate: HomeCandidate, until: Date) async -> Bool {
        let day = Calendar.current.startOfDay(for: until)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return await changeHome(home: { $0.addingFormer(FormerHome(place: candidate.homePlace, until: end), date: .now) })
    }

    /// Several at once (a multiple delete in the list) is one change.
    func removeFormerHomes(_ ids: Set<SortlyID>) async {
        _ = await changeHome(home: { $0.removingFormer(ids, date: .now) })
    }

    /// "Ort hinzufügen": a place of the user's where stays are not trips.
    func addPersonalPlace(_ candidate: HomeCandidate, kind: PersonalPlaceKind, label: String?) async -> Bool {
        let name = candidate.components.locality ?? candidate.components.administrativeArea
        return await changeHome(places: { $0.addingPersonalPlace(at: candidate.center, name: name, kind: kind, label: label, date: .now) })
    }

    /// "OK" on the overview card.
    func dismissHomeChangeNotice() {
        homeChangeNotice = nil
        Task { try? await pipeline?.dismissHomeChangeNotice() }
    }

    /// Stores the change (part of the decisions copy in the backup) and makes the suggestions
    /// again from what the analysis already knows (`AnalysisPipeline.resuggest`): no photo is
    /// analysed again, no album changes, and suggestions the user already chose stay as they
    /// were. What changed shows on the overview.
    ///
    /// The change is stored with a pending mark (`PendingHomeChange`) in one transaction: if the
    /// app is ended before the suggestions are made, or making them fails, the next analysis
    /// makes them the same way. No analysis, plan or rebuild starts while this runs; one asked
    /// for meanwhile starts after it.
    /// While it cannot run (an analysis or a plan is busy) the user is told, nothing is stored.
    private func changeHome(home: (HomeSettings) -> HomeSettings = { $0 },
                            places: (RecurringPlaceAnswers) -> RecurringPlaceAnswers = { $0 }) async -> Bool {
        guard let pipeline else { return false }
        guard canChangeHome else {
            message = .busy
            return false
        }
        homeChangeRunning = true
        // A little time in the background, so leaving the app does not cut the change short
        // (if it does, the next analysis finishes it).
        let assertion = BackgroundAssertion(name: "Dein Zuhause")
        defer {
            assertion.end()
            homeChangeRunning = false
            if let queued = analysisAfterHomeChange {
                analysisAfterHomeChange = nil
                startAnalysis(scope: queued.scope, mode: queued.mode, userInitiated: queued.userInitiated)
            }
        }
        do {
            // The choices as they are now, before the change: a suggestion chosen a moment ago is
            // held like the others, whichever step makes the suggestions.
            try await store?.setValue(storedDecisions(decisions), forKey: Key.decisions)
            let updatedHome = home(try await pipeline.homeSettings())
            let updatedPlaces = places(try await pipeline.recurringPlaceAnswers())
            try await pipeline.setHomeChange(home: updatedHome, places: updatedPlaces)
            homeSettings = updatedHome
            recurringPlaces = updatedPlaces
            saveSafetyBackup()
            _ = try await pipeline.resuggest()
            await refreshDerived()
            saveSafetyBackup()
            return true
        } catch {
            message = .failure(error.localizedDescription)
            // What was stored stays; the next analysis makes the suggestions for it.
            await refreshDerived()
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
            message = .failure(error.localizedDescription)
        }
    }

    /// Decisions the pipeline set back to open after a rule update (already saved, together
    /// with the count the overview shows): dropped here too, and the backup copy follows.
    private func reopenAfterRecheck(_ ids: Set<SortlyID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            decisions[id] = nil
            previewOnly[id] = nil
        }
        persistDecisions()
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
            message = .failure(error.localizedDescription)
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
            message = .failure(error.localizedDescription)
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
        // Not while a change in "Dein Zuhause" makes the suggestions again: a plan must not see
        // its suggestions change under it. Said, not silently ignored (apply, undo, resume).
        if homeChangeRunning {
            message = .busy
            return false
        }
        guard !executionClaimed, !execution.isRunning else { return false }
        executionClaimed = true
        return true
    }

    private func releaseExecution() { executionClaimed = false }

    /// Runs a plan; the caller holds the execution claim. `resume`: an interrupted plan that
    /// was confirmed before (its free albums were checked then).
    private func run(_ plan: ChangePlan, resume: Bool = false) async {
        guard let store else { return }
        // One plan at a time, also when one was cut off: that one is settled first (plugin
        // review K2). Its continuation and its undo are the ways out and always run.
        if PlanGate.refusal(for: plan, interrupted: interruptedPlan) != nil {
            execution = ExecutionState(planID: plan.id, failure: interruptedPlanFirst)
            return
        }
        // The free albums are checked here too, not only on the review screen.
        let wanted = plan.freeAlbumUse(applied: false)
        if plan.reverts == nil, !resume, !Purchases.shared.allows(albums: wanted) {
            execution = ExecutionState(planID: plan.id, failure: String(localized: "Die Gratis-Alben reichen für diese Änderungen nicht. Schalte Albumist frei, um weiterzumachen."))
            return
        }
        // Every plan runs only once the results of finished plans are stored (after a full disk
        // they may still wait), so album records are written in run order: for an undo, the
        // albums of the plan it takes back are Albumist's records (review of 6c6ef79); for any
        // other plan, results stored late would rebuild a shared album's record without this
        // plan's photos, and undoing both would leave the album behind (review of 6b34b20).
        if !(await storeWaitingResults()) { return }
        var confirmed = plan
        if confirmed.status == .draft { confirmed.status = .confirmed }
        if confirmed.confirmedAt == nil { confirmed.confirmedAt = Date() }
        let planID = confirmed.id
        execution = ExecutionState(isRunning: true, planID: planID, completedSteps: 0, totalSteps: plan.steps.count)
        // No auto-lock in the middle of a plan, and a little time to finish a step if the
        // user switches away (see `ExecutionGuard`).
        let keepAwake = ExecutionGuard()
        let executor = ChangeExecutor(library: library, store: store)
        // For the App Store rating question: how this run ended (`ReviewPrompt`).
        var ended: ChangePlan?
        var resultsStored = false
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
            ended = result
            execution.finished = result
            if result.status == .completed || result.status == .completedWithErrors {
                resultsStored = await finalize(result)
            }
        } catch {
            execution.failure = failureText(error)
        }
        ReviewPrompt.shared.planEnded(ended, resultsStored: resultsStored)
        // A plan that stopped half way in this session (its journal could not be written, a
        // full disk) is offered at once, and nothing new runs next to it (review of 6c6ef79, K2).
        await reloadInterruptedPlan()
        keepAwake.end()
        execution.isRunning = false
        self.plan = nil
        startAnalysis()
    }

    /// What the user reads when a plan could not run: a plan stopped by a change in Photos
    /// (an album changed since the preview, access reduced) says which, in the words of the
    /// review screen, instead of "SortlyCore.ChangeExecutor.ExecutionError error 1".
    private func failureText(_ error: any Error) -> String {
        if let stopped = error as? ChangeExecutor.ExecutionError, case .blocked(let conflicts) = stopped, !conflicts.isEmpty {
            return conflicts.prefix(3).map { ConflictText.text($0, inventory: inventory) }.joined(separator: "\n")
        }
        return error.localizedDescription
    }

    /// Why nothing new runs while a plan that was cut off is open (plugin review K2).
    /// Names what was cut off: creating albums, or taking them back (review of the design
    /// branch: an interrupted undo was called "Anlegen" too).
    private var interruptedPlanFirst: String {
        interruptedPlan?.reverts != nil
            ? String(localized: "Ein früheres Zurücknehmen wurde unterbrochen. Entscheide in der Übersicht, wie es weitergeht; danach geht es hier weiter.")
            : String(localized: "Ein früheres Anlegen wurde unterbrochen. Entscheide in der Übersicht, wie es weitergeht; danach geht es hier weiter.")
    }

    /// The plan offered to continue, take back or keep, read again from the store after every
    /// run and every way out (review of 6c6ef79): also a plan that failed half way in this
    /// session, and the next one once one is settled.
    private func reloadInterruptedPlan() async {
        guard let store else { return }
        do {
            interruptedPlan = try await store.openInterruptedPlan()
        } catch {
            // Not readable now: the offer stays as it is, and so does the wait for it.
        }
    }

    /// Stores the results of plans that finished but whose results still wait (after a full
    /// disk). Before an undo is planned or run: without them, the albums of the plan it takes
    /// back would count as the user's (review of 6c6ef79). False if that did not work.
    private func storeWaitingResults() async -> Bool {
        guard let store else { return false }
        do {
            for waiting in try await store.plansAwaitingFinalization() {
                guard await finalize(waiting) else { return false }
            }
            return true
        } catch {
            message = .failure(error.localizedDescription)
            return false
        }
    }

    /// Everything that follows a finished plan, stored in one transaction: Albumist's albums,
    /// applied suggestions leaving the open list, and the plan marked as finalized. The free
    /// albums are counted once per plan, from what really changed. Returns whether the
    /// results were stored.
    @discardableResult
    private func finalize(_ result: ChangePlan) async -> Bool {
        guard let store else { return false }
        var undone: SortlyID?
        var stored = false
        do {
            let after = try await library.currentInventory()
            try await store.saveInventory(after)
            inventory = after
            let states = ManagedAlbumTracker().record(result, into: try await store.managedAlbums(), inventory: after)
            var newDecisions = decisions
            if result.reverts == nil {
                // Applied proposals leave the open list; other accepted ones stay accepted, also
                // those of this plan whose steps never ran (review of 6c6ef79).
                for id in result.appliedSources where newDecisions[id]?.isAccepted == true {
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
            // "So lassen" for an album this undo deleted leaves nothing to keep: the suggestion is
            // open again (UI run 43823834271). Only by the undo's own verified deletions, never
            // by an album list that may lack albums (limited access, iCloud sync).
            for id in ProposalDecision.keepsOfAlbumsDeleted(by: result, in: newDecisions) {
                newDecisions[id] = nil
                previewOnly[id] = nil
            }
            var done = result
            done.finalizedAt = Date()
            let pending = (try await store.value([SortlyID].self, forKey: Key.pendingFinalization) ?? []).filter { $0 != result.id }
            try await store.finalize(done, managedAlbums: states, values: [
                Key.decisions: storedDecisions(newDecisions),
                Key.pendingFinalization: pending,
            ])
            stored = true
            decisions = newDecisions
            managedAlbums = states
            if let undone { undonePlans.insert(undone) }
            saveSafetyBackup()
            SpotlightIndex.scheduleUpdate(self)
            // Suggestions see the new albums at once (e.g. "Album vollständig").
            if let rematched = try await pipeline?.rematch() { snapshot = rematched }
        } catch {
            message = .failure(error.localizedDescription)
        }
        return stored
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
            message = .failure(error.localizedDescription)
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
            message = .failure(error.localizedDescription)
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
            // While a plan runs, its own changes are not compared.
            guard !execution.isRunning else {
                managedAlbums = try await store.managedAlbums()
                return try await library.currentInventory()
            }
            // Only with full access. Albums of plans that are unfinished or whose results are
            // not stored yet are left alone (W2: the same answer before and after those results
            // are stored, so the order at launch does not matter), and an album only the list
            // lacks is looked up on its own first (W3). The list that comes back is the one
            // everything works with. See `ManagedAlbumCheck`.
            let checked = try await ManagedAlbumCheck(store: store, library: library).run(access: await library.access())
            if checked.foundChanges { saveSafetyBackup() }
            managedAlbums = checked.managedAlbums
            return checked.inventory
        } catch {
            // Fails closed (audit 2, 1.5): without knowing what the user changed in Photos,
            // nothing is planned, so a photo they took out is never put back by mistake.
            if !quiet { message = .failure(String(localized: "Albumist konnte deine Alben gerade nicht lesen. Versuche es gleich noch einmal.")) }
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
    /// user has taken out of an album since then are not added anymore. An album the plan
    /// created itself is filled when none of the interrupted step's photos reached it (the
    /// request never got to Photos); the user's own albums get nothing without a preview
    /// (`ChangeExecutor`, docs/DECISIONS.md).
    func resumeInterruptedPlan() async {
        guard let store, let interrupted = interruptedPlan, claimExecution() else { return }
        defer { releaseExecution() }
        guard await reconcileManagedAlbums() != nil else { return }
        execution = ExecutionState()
        let overrides = (try? await store.overrides()).map { OverrideSet($0) } ?? OverrideSet()
        await run(interrupted.respecting(overrides), resume: true)
        // The card goes away once the plan is done; what is left (photos for the user's own
        // albums that wait for a preview, a step Photos refused) is said, not left to be found
        // in the history.
        if let finished = execution.finished, finished.id == interrupted.id, finished.status == .completedWithErrors {
            // Keeps a reason said before, e.g. that the results could not be stored (finalize
            // put it into `message`), as the undo of an interrupted plan does (second review of
            // resume-fill, D2).
            let reasons = [execution.failure, message?.text].compactMap { $0 }
            message = .failure(([String(localized: "Der Rest ist angelegt, aber nicht alles hat geklappt. Der Vorgang steht unter Einstellungen › Verlauf und Rückgängig. Dort siehst du, was fehlt, und kannst es mit „Fehlendes erneut versuchen“ nachholen.")]
                                + reasons.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }).joined(separator: "\n\n"))
        }
        // Read again, not cleared: a plan that stopped once more stays offered, and so does
        // another one that is still open (review of 6c6ef79).
        await reloadInterruptedPlan()
    }

    /// Takes back what an interrupted plan already did, and drops the rest. Steps the
    /// interruption left open are first checked against the library (an album created or
    /// photos added right before the app was closed are taken back too).
    ///
    /// What the plan did is first kept and recorded like "So lassen" (history, receipt, free
    /// albums) and then taken back by an ordinary undo of it. Only a completed undo cancels the
    /// plan; when the undo does not get everything back ("Nicht erlauben" in the iOS question),
    /// the plan stays in the history and the rest can be taken back there (plugin review K1).
    /// Before, it was cancelled first and its albums stayed in Photos without a trace. The
    /// order, and what each ending leaves, is `InterruptedPlanUndo.carryOut`.
    func undoInterruptedPlan() async {
        // An interrupted undo cannot itself be taken back: Photos cannot bring deleted albums
        // back, and undo plans put no photos back. What it already did is kept and recorded
        // instead (as with "So lassen"), so the receipt offers "Rest rückgängig machen".
        // Before, it was cancelled unrecorded, and the next check took the albums it had
        // deleted for albums the user deleted, so their suggestions never came back.
        if interruptedPlan?.reverts != nil {
            await keepInterruptedPlanAsIs()
            return
        }
        guard let store, let interrupted = interruptedPlan, claimExecution() else { return }
        defer { releaseExecution() }
        // Without write access nothing could be taken back: nothing changes, the card stays.
        guard await library.canWrite() else {
            execution = ExecutionState(planID: interrupted.id, failure: ConflictText.text(.writeAccessMissing, inventory: inventory))
            return
        }
        execution = ExecutionState()
        // The selection before: a completed undo gives it back to the suggestions the plan
        // carried out (they leave it with the plan's results).
        let selection = decisions
        let previews = previewOnly
        do {
            let settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted)
            let way = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())
            // If the app ends before the plan's results are stored, the next launch stores them.
            try await setPendingFinalization(adding: interrupted.id)
            let outcome = try await way.carryOut(journal: store, finalize: { await self.finalize($0) }, run: { await self.run($0) })
            switch outcome {
            case .nothingToTakeBack:
                try? await setPendingFinalization(removing: [interrupted.id])
            case .undone:
                for id in way.selectionToRestore(after: outcome) {
                    decisions[id] = selection[id]
                    previewOnly[id] = previews[id]
                }
                persistDecisions()
            case .partlyUndone:
                // The receipt offers "Rest rückgängig machen".
                message = .failure([String(localized: "Nicht alles ließ sich zurücknehmen. Der unterbrochene Vorgang steht jetzt unter Einstellungen › Verlauf und Rückgängig. Dort kannst du den Rest zurücknehmen."),
                                    execution.failure].compactMap { $0 }.joined(separator: "\n\n"))
            case .notStarted:
                // Nothing was taken back: the receipt offers "Rückgängig machen" (review of 6c6ef79).
                // Keeps the reason storing earlier results failed (e.g. a full disk), which
                // finalize put into `message` (review of 6b34b20).
                let reasons = [execution.failure, message?.text].compactMap { $0 }
                message = .failure(([String(localized: "Albumist konnte den unterbrochenen Vorgang gerade nicht zurücknehmen. Er steht jetzt unter Einstellungen › Verlauf und Rückgängig. Dort kannst du ihn zurücknehmen.")]
                                    + reasons.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }).joined(separator: "\n\n"))
            case .undoInterrupted, .resultsNotStored:
                // Offered on the overview again: the undo that was cut off, or the one that
                // runs once the plan's results are stored. Run and finalization said why.
                break
            }
        } catch {
            message = .failure(error.localizedDescription)
        }
        // What is still open, from the store: nothing, or the undo itself.
        await reloadInterruptedPlan()
        await refreshDerived()
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
            let settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted)
            // Also an album Photos made before its check failed is recorded (plugin review K1).
            let kept = settled.keptAsIs(current: try await library.currentInventory())
            try await store.save(kept)
            if kept.status == .cancelled {
                try? await setPendingFinalization(removing: [interrupted.id])
            } else {
                await finalize(kept)
            }
            // Read again, not cleared: another plan still open is offered next (review of 6c6ef79).
            await reloadInterruptedPlan()
            await refreshDerived()
        } catch {
            message = .failure(error.localizedDescription)
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
            message = .failure(error.localizedDescription)
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
        // Where the sorted count comes from, per main area (device test 15.11.: 811 sorted before
        // "Analyse neu aufbauen", 141 after it).
        var areaLines: [String] = []
        for area in OrganizationArea.allCases where settings.primaryAreas.contains(area) {
            var counts: [AreaStatus: Int] = [:]
            for state in states.values { if let status = state.areas[area] { counts[status, default: 0] += 1 } }
            let parts = AreaStatus.allCases.compactMap { status in counts[status].map { "\(status.rawValue) \($0)" } }
            areaLines.append("\(area.rawValue): " + parts.joined(separator: ", "))
        }
        lines.append("main areas " + areaLines.joined(separator: "; ") + "; outside main areas \(progress.outsideMainAreas)")
        lines.append(statusReasons.line)
        if let report = analysis.lastReport {
            let last = analysis.lastRun.map { iso.string(from: $0) } ?? "?"
            lines.append("analysis last \(last), complete \(report.isComplete), paused \(report.pausedBecause?.rawValue ?? "no"), stages \(report.completedStages.count), content \(report.contentAnalyzed), text \(report.textRecognized), text waiting \(report.textWaitingForOriginal), text seconds \(Int(report.textSeconds)), places pending online \(report.placesPendingOnline), places throttled \(report.placesThrottled), analyzer failing \(report.analyzerUnavailable)")
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
        lines.append("image loads \(ImageLoadStats.summary)")
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
        lines += BackgroundRunLog.summary
        return lines.joined(separator: "\n")
    }

    func undo(_ executed: ChangePlan) async {
        // Asked to take it back: never an App Store rating question for this plan (`ReviewPrompt`).
        ReviewPrompt.shared.undoStarted(executed.id)
        // Taking back the same plan twice would find nothing to do (or remove what the user
        // added in the meantime), so a plan is undone once.
        // A partial undo (completedWithErrors) does not count as undone: running it again takes
        // back only what is still Albumist's (audit 2, 1.6).
        guard !undonePlans.contains(executed.id), executed.reverts == nil, let store, claimExecution() else { return }
        defer { releaseExecution() }
        // Results that still wait (after a full disk) are stored first: the undo goes by
        // Albumist's records, and an album without one is the user's (review of 6c6ef79). An
        // earlier undo stored that way may have taken the plan back already.
        guard await storeWaitingResults(), !undonePlans.contains(executed.id) else { return }
        // What the user changed by hand since counts first: a photo they took out and put back
        // is theirs now and stays.
        guard let current = await reconcileManagedAlbums() else { return }
        var owned: [CollectionID: Set<AssetID>] = [:]
        for state in managedAlbums { owned[state.albumID, default: []].formUnion(state.addedBySortly) }
        // Undos of this plan that did not get everything back (plugin review W1): an album one
        // of them brought back gets the photos still missing, never a second album.
        let earlier: [ChangePlan]
        do { earlier = try await store.reverts(of: executed.id) } catch { message = .failure(error.localizedDescription); return }
        // An album another plan made, left with only this plan's photos, goes too (plugin review N5).
        let created: Set<CollectionID> = Set(managedAlbums.filter { $0.createdBySortly }.map { $0.albumID })
        let undoPlan = UndoPlanner().undoPlan(for: executed, current: current, owned: owned, createdByAlbumist: created, earlierUndos: earlier)
        // A plan that was cut off is settled first (plugin review K2).
        if PlanGate.refusal(for: undoPlan, interrupted: interruptedPlan) != nil {
            message = AppMessage(title: interruptedPlan?.reverts != nil
                                 ? String(localized: "Erst das unterbrochene Zurücknehmen abschließen")
                                 : String(localized: "Erst das unterbrochene Anlegen abschließen"),
                                 text: interruptedPlanFirst)
            return
        }
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

    /// The photos the last "Ignorieren" newly ignored, for "Widerrufen" right after it
    /// (design review D4: ignoring could not be taken back). A new id per action, so the
    /// note shows again and its timer starts over.
    struct IgnoreUndo: Identifiable, Equatable {
        let id = UUID()
        let assets: [AssetID]
    }

    var lastIgnored: IgnoreUndo?

    /// "Ignorieren": no confirmation, because it can be taken back right away ("Widerrufen")
    /// and later in the "Ignoriert" area ("Nicht mehr ignorieren").
    func ignore(_ assets: [AssetID]) {
        Task {
            guard let store else { return }
            do {
                let added = try await store.ignoreAssets(assets)
                saveSafetyBackup()
                await refreshDerived()
                guard !added.isEmpty else { lastIgnored = nil; return }
                let undo = IgnoreUndo(assets: added)
                lastIgnored = undo
                announceAndExpire(undo)
            } catch {
                message = .failure(error.localizedDescription)
            }
        }
    }

    /// Said once by VoiceOver, and the offer ends here, not in the note: a note in a viewer
    /// that closed within seconds kept it alive, and it came back much later on another
    /// screen; every reappearance also announced it again (review of the design branch).
    /// Longer with VoiceOver (time to reach the button), and in UI tests, whose audit of the
    /// note takes a few seconds itself.
    private func announceAndExpire(_ undo: IgnoreUndo) {
        #if canImport(UIKit)
        let voiceOver = UIAccessibility.isVoiceOverRunning
        UIAccessibility.post(notification: .announcement, argument: String(localized: "\(undo.assets.count) Fotos ignoriert"))
        #else
        let voiceOver = false
        #endif
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(voiceOver || UITestSupport.isRunning ? 20 : 6))
            if self?.lastIgnored?.id == undo.id { self?.lastIgnored = nil }
        }
    }

    /// "Nicht mehr ignorieren" and "Widerrufen": Albumist counts and suggests these photos again.
    func unignore(_ assets: [AssetID]) {
        if let last = lastIgnored, !Set(last.assets).isDisjoint(with: assets) { lastIgnored = nil }
        Task {
            guard let store else { return }
            do {
                try await store.unignoreAssets(assets)
                saveSafetyBackup()
                await refreshDerived()
            } catch {
                message = .failure(error.localizedDescription)
            }
        }
    }

    /// Search index over the current facts and album names, built once per change and off
    /// the main thread (a large library takes a moment); every search then only combines
    /// prepared sets.
    @ObservationIgnored private var searchIndexCache: SearchIndex?
    @ObservationIgnored private var searchIndexTask: Task<SearchIndex, Never>?
    @ObservationIgnored private var searchIndexGeneration = 0

    private func resetSearchIndex() {
        searchIndexCache = nil
        searchIndexTask = nil
        searchIndexGeneration += 1
    }

    func searchIndex() async -> SearchIndex {
        if let searchIndexCache { return searchIndexCache }
        if let searchIndexTask { return await searchIndexTask.value }
        let facts = facts, inventory = inventory, generation = searchIndexGeneration
        let home = homeSettings
        let task = Task.detached(priority: .userInitiated) { SearchIndex(facts: facts, inventory: inventory, home: home) }
        searchIndexTask = task
        let index = await task.value
        // Facts that changed meanwhile start a new index on the next search.
        if generation == searchIndexGeneration {
            searchIndexCache = index
            searchIndexTask = nil
        }
        return index
    }

    /// Keywords Apple Intelligence derived from the last sentence-style query (shown in the UI).
    var lastSearchRewrite: String?

    func search(_ query: String) async -> SearchResult {
        lastSearchRewrite = nil
        let direct = await plainSearch(query)
        let wordCount = query.split(whereSeparator: \.isWhitespace).count
        // Sentences ("Fotos vom Grillen bei Oma letzten Sommer") get help from the on-device
        // model when the rule-based reading left words out or found nothing for all of them.
        let incomplete = direct.ids.isEmpty || direct.isRelaxed || direct.tokens.contains { $0.kind == .ignored }
        guard wordCount >= 3, incomplete, SmartAssistant.isAvailable,
              let keywords = await SmartAssistant.searchKeywords(for: query) else { return direct }
        let assisted = await plainSearch(keywords)
        guard !assisted.ids.isEmpty, !assisted.isRelaxed || direct.ids.isEmpty else { return direct }
        lastSearchRewrite = keywords
        return assisted
    }

    private func plainSearch(_ query: String) async -> SearchResult {
        let index = await searchIndex()
        // Reading the query compares unknown words with every word on screenshots (typos);
        // off the main thread, so typing stays smooth in a large library.
        let parsed = await Task.detached(priority: .userInitiated) { index.parse(query) }.value
        // The organization state of every photo only when the query asks for it ("nicht sortiert").
        let statuses = parsed.usesStatus ? states.mapValues { resolver.overall($0) } : [:]
        return await Task.detached(priority: .userInitiated) { SearchEngine().run(parsed, in: index, statuses: statuses) }.value
    }

    /// Completions for the word being typed, from the user's own places, topics and albums.
    func searchSuggestions(for query: String) async -> [SearchSuggestion] {
        let index = await searchIndex()
        return index.suggestions(for: query)
    }

    /// Starting points for the empty search field, from the user's own library.
    func featuredSearches() async -> [SearchSuggestion] {
        let index = await searchIndex()
        let english = !(Bundle.main.preferredLocalizations.first?.hasPrefix("de") ?? true)
        return index.featuredSuggestions(english: english)
    }

    // MARK: Reset

    /// "Analyse neu aufbauen": a running analysis stops first and is waited for, so it cannot
    /// write old results into the fresh tables; Spotlight forgets the old results too.
    /// Clears the analysis for "Analyse neu aufbauen". false when it was refused (a change in
    /// "Dein Zuhause" is being applied; the busy message is shown): the caller starts no run.
    @discardableResult
    func resetAnalysis() async -> Bool {
        // Not while a change in "Dein Zuhause" makes the suggestions again (the pipeline would
        // wait for it; the settings screen and the overview would show it half done).
        if homeChangeRunning {
            message = .busy
            return false
        }
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
        if progress.total > 0, recount == nil {
            recount = RecountState(fully: progress.fully, total: progress.total)
        }
        do {
            // Through the pipeline: it waits for a run or a change in "Dein Zuhause" that is
            // still writing, so nothing old lands in the fresh tables.
            try await pipeline?.resetAnalysis()
        } catch {
            message = .failure(error.localizedDescription)
        }
        snapshot = nil
        SpotlightIndex.clear()
        await refreshDerived()
        return true
    }
}

/// The ring's last count while "Analyse neu aufbauen" builds the proposals again.
struct RecountState: Codable, Equatable {
    var fully: Int
    var total: Int

    private static let key = "overview.recount"

    static func load() -> RecountState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecountState.self, from: data)
    }

    static func save(_ state: RecountState?) {
        if let state, let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// An alert with its own title (design review W15: every message, error or not, came with
/// the title "Hinweis"). The text says what happened and what the user can do.
struct AppMessage: Equatable {
    var title: String
    var text: String

    /// Something did not work.
    static func failure(_ text: String) -> AppMessage {
        AppMessage(title: String(localized: "Das hat nicht geklappt"), text: text)
    }

    /// Asked for while Albumist cannot do it (a change in "Dein Zuhause", an analysis or a plan
    /// is busy): try again in a moment.
    static var busy: AppMessage {
        AppMessage(title: String(localized: "Gerade nicht möglich"),
                   text: String(localized: "Albumist ist gerade beschäftigt. Versuch es gleich noch einmal."))
    }
}
