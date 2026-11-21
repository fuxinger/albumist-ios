import Foundation
import AlbumistCore

/// Device conditions for the UI tests (DeviceConditionUITests). The first iPhone test (15.11.)
/// found what no simulator run had shown: a warm phone ended the analysis, Photos ignored a
/// deletion, the trial year was forgotten. These launch arguments make the real app behave as
/// it does on a device under such a condition, so every case runs on CI before it reaches a
/// phone. Like every UI test switch they work only in debug builds started with
/// `-AlbumistUITestUnlocked`; in a release build every factory below hands back the plain service.
extension UITestSupport {
    private static func flag(_ name: String) -> Bool {
        isRunning && ProcessInfo.processInfo.arguments.contains(name)
    }

    /// The argument after `name` (`-AlbumistUITestPace normal:40,hot:6`).
    private static func value(_ name: String) -> String? {
        guard isRunning else { return nil }
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: Start

    /// `-AlbumistUITestFastStart`: every UI test runs alone on a fresh simulator (one runner per
    /// group of tests). The onboarding counts as done when photo access is granted, and the
    /// demo library is created if it is not there yet, then analysed. The onboarding itself
    /// is tested by test1, which starts without this flag.
    static let fastStart = flag("-AlbumistUITestFastStart")

    /// `-AlbumistUITestLaunchAnalysis`: the analysis starts at launch as in the shipped app (UI
    /// runs normally start it themselves), to test that a killed app goes on by itself.
    static let startsAnalysisAtLaunch = rebuildsDatabase || flag("-AlbumistUITestLaunchAnalysis")

    // MARK: Moments

    /// `-AlbumistUITestFirstFinishMoment`: the first 100 % (DS-08, `FirstAnalysisMomentStore`)
    /// may show in this UI run, held `FirstAnalysisMoment.Timing.heldForUITest`, so a test finds
    /// it (`ShowAndHandwritingUITests`). Other UI runs never show it: the start page would change
    /// under the audits that follow the first analysis (UI run 43774578089 ended test 1 on a page
    /// that changed during its audit).
    static let showsFirstFinishMoment = flag("-AlbumistUITestFirstFinishMoment")

    /// `-AlbumistUITestFirstFinishOwed`: this launch starts as a fresh installation does for the
    /// first 100 %: owed, whatever an earlier test left in the defaults and whether an analysis
    /// was completed before. The simulators of the UI groups are not fresh; with
    /// `-AlbumistUITestRebuildDatabase` the analysis at launch is then the first full one.
    static let startsFirstFinishOwed = flag("-AlbumistUITestFirstFinishOwed")

    // MARK: Device

    /// `-AlbumistUITestPace normal:40,gentle:40,hot:6,normal`: the device's state as a script,
    /// one step per check the analysis makes (before every photo; every 2 s while it waits).
    /// `gentle` is a warm phone, `hot` a hot one, `battery` a nearly empty battery, `lowpower`
    /// Low Power Mode. A step without a count lasts; after the script the real state counts.
    static let paceScript = value("-AlbumistUITestPace")

    /// `-AlbumistUITestExpireInBackground`: the worst case of background time running out. When
    /// the app goes to the background the running analysis ends there (as when iOS takes the
    /// time away); coming back must continue without a tap.
    static let expiresInBackground = flag("-AlbumistUITestExpireInBackground")

    // MARK: Photos

    /// `-AlbumistUITestUnreadable 7`: seven photos have no readable preview yet (still syncing
    /// from iCloud), like on a phone with "Optimize iPhone Storage".
    static let unreadablePhotos = value("-AlbumistUITestUnreadable").flatMap { Int($0) } ?? 0

    /// `-AlbumistUITestICloudOnly`: the originals of screenshots and documents are only in iCloud.
    static let documentsOnlyInICloud = flag("-AlbumistUITestICloudOnly")

    /// `-AlbumistUITestOffline`: no network for place names (airplane mode, no signal).
    static let geocoderOffline = flag("-AlbumistUITestOffline")

    /// `-AlbumistUITestLimitedAccess`: full access is reported as "selected photos only".
    static let reportsLimitedAccess = flag("-AlbumistUITestLimitedAccess")

    /// `-AlbumistUITestEmptyLibrary`: a phone without photos, on a database of its own (the
    /// photos the other tests use stay where they are).
    static let emptyLibrary = flag("-AlbumistUITestEmptyLibrary")

    /// `-AlbumistUITestLargeLibrary 3000`: that many more photos (small, with dates and places
    /// of 120 trips) are added once, to find what gets slow with a real-sized library.
    static let largeLibrary = value("-AlbumistUITestLargeLibrary").flatMap { Int($0) } ?? 0

    /// `-AlbumistUITestCreateOnly` with `-AlbumistUITestLargeLibrary`: the launch only creates the
    /// photos and then ends the app, so the stress test measures the analysis in a fresh
    /// launch and knows when creating is done (the app is gone). Creating 50 000 photos while
    /// catch-up runs analysed them made both phases unreadable (stress run 43823462215).
    static let createsOnly = flag("-AlbumistUITestCreateOnly")

    /// `-AlbumistUITestCreateMarker <path>`: where the create-only launch writes how far it is
    /// and `done` at the end (a file in the test runner's own folder; on the simulator both
    /// processes see the Mac's file system). The runner did not notice the app end on its own.
    static let createMarker = value("-AlbumistUITestCreateMarker")

    /// `-AlbumistUITestWatchMain`: the system log gets a line whenever the main thread did not
    /// answer for more than a second (`UITEST_MAIN_BLOCKED`), so a stress run shows whether a
    /// slow tap or a still card was the app's main thread or the UI test's own snapshot.
    static let watchesMain = flag("-AlbumistUITestWatchMain")

    /// `-AlbumistUITestWatchMainLog <path>`: every stall over half a second also goes into this
    /// file of the test runner's ("<end as seconds since 1970> <ms>"), so the stress test can
    /// assert that the main thread was free when Pause was tapped, and every device test can
    /// print its stalls (alone it writes the file without the `UITEST_MAIN_BLOCKED` lines).
    static let watchMainLog = value("-AlbumistUITestWatchMainLog")

    /// `-AlbumistUITestProgressLog <path>`: every change of the analysis card's progress line
    /// (the label and value XCTest reads) goes into this file of the test runner's with its
    /// time (`ProgressLineLog`), so the stress test measures how long the line stood still
    /// from the app's own clock instead of from its reads, which took 5–7 s each while the
    /// analysis ran (stress run 44116350940).
    static let progressLog = value("-AlbumistUITestProgressLog")

    // MARK: Writing

    /// `-AlbumistUITestDeletionFault declined|ignored`: the first deletion of albums in this
    /// launch is declined in the iOS question ("Nicht erlauben"), or Photos reports success and
    /// deletes nothing (first iPhone test 15.11.). Later attempts go through.
    static let deletionFault = value("-AlbumistUITestDeletionFault")

    /// `-AlbumistUITestDiskFull analysis|plan`: the device's storage is full from the 25th
    /// analysed photo, or right after the first change a plan made in Photos. It is free again
    /// once the app goes to the background (the user cleared space in Settings).
    static let diskFullDuring = value("-AlbumistUITestDiskFull")

    /// `-AlbumistUITestSlowPlan`: after the first change in Photos every change takes 30 s
    /// longer, so closing the app during "Jetzt umsetzen" always lands in the middle of the plan.
    static let slowsPlan = flag("-AlbumistUITestSlowPlan")

    // MARK: Services (AppModel builds its services through these)

    /// The database file, with a full disk prepared when a test asks for it.
    static func databaseURL(_ real: URL) -> URL {
        #if DEBUG
        guard isRunning else { return real }
        var url = real
        if emptyLibrary {
            url = real.deletingLastPathComponent().appendingPathComponent("uitest-empty.sqlite")
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        if diskFullDuring != nil { StorageFault.install(fileMarker: url.lastPathComponent) }
        return url
        #else
        return real
        #endif
    }

    static func analyzer(_ base: VisionAnalyzer) -> any ContentAnalyzing {
        #if DEBUG
        if isRunning { return UITestAnalyzer(base: slowsAnalysis ? SlowedAnalyzer(base: base) : base) }
        #endif
        return base
    }

    static func geocoder(_ base: SystemGeocoder) -> any ReverseGeocoding {
        #if DEBUG
        if geocoderOffline { return OfflineGeocoder() }
        #endif
        return base
    }

    @MainActor
    static func conditions(_ base: DeviceConditions) -> any AnalysisConditions {
        #if DEBUG
        if paceScript != nil || expiresInBackground {
            return ScriptedConditions(base: base, script: paceScript ?? "", expiresInBackground: expiresInBackground)
        }
        #endif
        return base
    }

    // MARK: Launch

    /// Before the model loads (AlbumistApp.init).
    @MainActor
    static func prepareLaunch() {
        #if DEBUG
        if fastStart { AppModel.shared.onboardingDone = true }
        if watchesMain || watchMainLog != nil {
            MainThreadWatch.shared.watchForStress(log: watchMainLog, lines: watchesMain)
        }
        if let progressLog { ProgressLineLog.start(path: progressLog) }
        #endif
    }

    /// After the model loaded: the demo library for a fast start, the large library.
    @MainActor
    static func didLaunch(_ model: AppModel) async {
        #if DEBUG && targetEnvironment(simulator)
        guard isRunning, model.phase == .ready, model.access.canRead else { return }
        if fastStart, !emptyLibrary, !DemoLibrary.shared.isDone {
            await DemoLibrary.shared.seed(then: model)
        }
        if largeLibrary > 0, createsOnly {
            let added = await LargeLibrary.createIfNeeded(count: largeLibrary, marker: createMarker)
            NSLog("UITEST_LARGE_LIBRARY create-only launch done (added: %@)", added ? "yes" : "no")
            exit(0)
        }
        if largeLibrary > 0, await LargeLibrary.createIfNeeded(count: largeLibrary) {
            model.startAnalysis(cause: .tap)
        }
        #endif
    }
}
