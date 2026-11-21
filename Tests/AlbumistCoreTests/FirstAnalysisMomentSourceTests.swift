import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// DS-08 as the App wires it: the model tells the rule (`FirstAnalysisMoment`, tested in
/// `FirstAnalysisMomentTests`) at launch and at the end of each run, what is kept lives in
/// `UserDefaults`, and the ring card shows the moment above "Analyse fertig", quietly and once.
/// The App does not build on Linux, so these tests read its code (`AppSource`). How it looks and
/// feels, light and dark, with Reduce Motion and VoiceOver, is a device check.
@Suite("First analysis moment in the App (DS-08)")
struct FirstAnalysisMomentSourceTests {
    static let model = "App/Albumist/Model/AppModel.swift"
    static let store = "App/Albumist/Model/AppModel+FirstAnalysisMoment.swift"
    static let ringCard = "App/Albumist/Views/Start/RingCard.swift"
    static let overview = "App/Albumist/Views/OverviewView.swift"
    static let progressCard = "App/Albumist/Views/AnalysisProgressCard.swift"
    static let marker = "App/Albumist/Platform/AnalysisMarker.swift"
    static let mark = "// Design W3 H13"
    static let switches = "App/Albumist/Platform/UITestSwitches.swift"
    static let uiTest = "App/AlbumistUITests/ShowAndHandwritingUITests.swift"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ path: [String], in file: String) throws -> String {
        try #require(AppSource.body(of: path, in: file), "\(path) is not there")
    }

    /// Launch: what is kept is read while `AnalysisMarker` still says whether an analysis was
    /// completed before (the load resets it for a restored backup or a new database). End of a
    /// run: told before the marker says "completed" and before the wait for the overview, with
    /// whether Albumist is on screen. Two marked lines in `AppModel.swift`, nothing else there.
    @Test func theModelTellsTheRuleAtLaunchAndAtTheEndOfARun() throws {
        let raw = try AppSource.read(Self.model)
        let model = try Self.code(Self.model)
        let load = try Self.body(["private func load() async"], in: model)
        let launched = try #require(load.range(of: "FirstAnalysisMomentStore.shared.launched()"), "load() does not read the moment first")
        let reset = try #require(load.range(of: "AnalysisMarker.reset()"))
        #expect(launched.upperBound < reset.lowerBound, "the moment is read after the marker may have been reset")
        let guardLine = try #require(load.range(of: "guard phase == .loading else { return }"))
        #expect(load[guardLine.upperBound..<launched.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "something runs before the moment is read")

        let run = try Self.body(["func startAnalysisNow("], in: model)
        let owed = try #require(run.range(of: "finishMoment.runEnded(finished: end.isFinished, celebrates: celebrate)"))
        let told = try #require(run.range(of: "firstAnalysisRunEnded(finished: end.isFinished, celebrates: celebrate)"),
                                "the end of a run does not tell the first analysis moment")
        #expect(owed.upperBound < told.lowerBound)
        for later in ["AnalysisMarker.finished()", "endCard()", "await refreshDerived()", "finishMoment.afterWait("] {
            let at = try #require(run.range(of: later), "\(later)")
            #expect(told.upperBound < at.lowerBound, "told after \(later)")
        }
        #expect(model.components(separatedBy: "firstAnalysisRunEnded(").count - 1 == 1, "told from another place too")
        #expect(raw.components(separatedBy: Self.mark).count - 1 == 2, "the marked lines of DS-08 in AppModel.swift changed")

        let store = try Self.code(Self.store)
        let tell = try Self.body(["extension AppModel", "func firstAnalysisRunEnded("], in: store)
        #expect(tell.contains("completedBefore: AnalysisMarker.completedOnce, onScreen: isOnScreen"), "\(tell)")
    }

    /// Kept in `UserDefaults` under a key of its own (`AnalysisMarker.reset` does not clear it,
    /// a rebuilt database does not lose it, a device backup brings it back), never in the
    /// database. Leaving the screen ends a moment not seen; coming back after an analysis was
    /// completed meanwhile spends it.
    @Test func whatIsKeptLivesInUserDefaults() throws {
        let store = try Self.code(Self.store)
        let type = try Self.body(["final class FirstAnalysisMomentStore"], in: store)
        #expect(type.contains("private static let key = \"analysis.firstFinishMoment\""))
        #expect(type.contains("UserDefaults.standard.set(moment.kept.rawValue, forKey: Self.key)"))
        let initializer = try Self.body(["final class FirstAnalysisMomentStore", "private init()"], in: store)
        #expect(initializer.contains("FirstAnalysisMoment(kept: kept, completedBefore: !fresh && AnalysisMarker.completedOnce)"), "\(initializer)")
        #expect(initializer.contains("UIApplication.didEnterBackgroundNotification") && initializer.contains("self?.leftScreen()"))
        #expect(initializer.contains("UIApplication.willEnterForegroundNotification") && initializer.contains("self?.cameToFront()"))
        let front = try Self.body(["final class FirstAnalysisMomentStore", "private func cameToFront()"], in: store)
        #expect(front.contains("AnalysisMarker.completedOnce"), "\(front)")
        let launched = try Self.body(["final class FirstAnalysisMomentStore", "func launched()"], in: store)
        #expect(launched.contains("cameToFront()"), "\(launched)")
        for database in ["AlbumistStore", "store.value(", "store.set(", "setValue("] {
            #expect(!store.contains(database), "the moment is kept in the database: \(database)")
        }
        let marker = try Self.code(Self.marker)
        #expect(!marker.contains("firstFinishMoment"), "AnalysisMarker clears the moment with where the analysis got to")
    }

    /// The one place: above "Analyse fertig" on the ring card, where the progress was. Nowhere
    /// else in the App.
    @Test func itRidesOnAnalyseFertig() throws {
        let overview = try Self.code(Self.overview)
        let card = try Self.body(["var analysisCard: some View"], in: overview)
        let moment = try #require(card.range(of: "if case .finished = state { FirstAnalysisMomentHeader() }"), "\(card)")
        let finished = try #require(card.range(of: "AnalysisProgressCard(state: state) { showAnalysis = true }"))
        #expect(moment.upperBound < finished.lowerBound, "the moment is not above the card")
        let raw = try AppSource.read(Self.overview)
        #expect(raw.contains("if case .finished = state { FirstAnalysisMomentHeader() } \(Self.mark): the first 100 %"))
        for path in AppSource.swiftFiles(under: "App/Albumist") where !path.hasSuffix("OverviewView.swift") && !path.hasSuffix("Start/RingCard.swift") {
            let code = try Self.code(path)
            #expect(!code.contains("FirstAnalysisMomentHeader") && !code.contains("JoiningBar("), "\(path) shows the moment")
        }
    }

    /// Quiet: no haptic of its own (the success tap of "Analyse fertig" stays the only one),
    /// nothing flies, nothing glows; with Reduce Motion it only fades. Once: it plays on the
    /// store's claim, says itself to VoiceOver there and nowhere else, and ends when the card goes.
    @Test func itIsQuietAndOnce() throws {
        let ring = try Self.code(Self.ringCard)
        let header = try Self.body(["struct FirstAnalysisMomentHeader"], in: ring)
        let bar = try Self.body(["struct JoiningBar"], in: ring)
        #expect(!ring.contains(".sensoryFeedback("), "a second haptic on the ring card")
        let progress = try Self.code(Self.progressCard)
        #expect(progress.components(separatedBy: ".sensoryFeedback(").count - 1 == 1, "the haptic of \"Analyse fertig\" changed")
        for flying in ["AssetThumbnail", "CoverPhoto", "ThumbnailCache", "matchedGeometryEffect", "ShowFlight", "Image(uiImage:"] {
            #expect(!header.contains(flying), "the moment shows photos: \(flying)")
        }
        for glow in [".shadow(", ".blur(", "Gradient(", "glassEffect", "symbolEffect"] {
            #expect(!header.contains(glow) && !bar.contains(glow), "the moment glows: \(glow)")
        }
        #expect(header.contains("private var calm: Bool { reduceMotion || UITestSupport.isRunning }"))
        #expect(header.contains("JoiningBar(shares: model.analysis.widths.shares, joined: calm || joined ? 1 : 0)"), "\(header)")
        let play = try Self.body(["struct FirstAnalysisMomentHeader", "private func play() async"], in: ring)
        #expect(play.contains("if !calm {"), "\(play)")
        #expect(play.contains("withAnimation(calm ? .easeInOut(duration: T.fade) : .smooth(duration: T.fold)) { store.ended() }"), "\(play)")
        let start = try Self.body(["struct FirstAnalysisMomentHeader", "private func start()"], in: ring)
        #expect(start.contains("guard run == nil, model.isOnScreen else { return }"), "\(start)")
        let claim = try #require(start.range(of: "store.claim(onScreen: model.isOnScreen)"), "\(start)")
        let claimed = try #require(start.range(of: "guard claimed else { return }"), "\(start)")
        let said = try #require(start.range(of: "AccessibilityNotification.Announcement(spoken).post()"), "\(start)")
        #expect(claim.upperBound < claimed.lowerBound && claimed.upperBound < said.lowerBound, "said before it was claimed")
        #expect(ring.components(separatedBy: "AccessibilityNotification.Announcement(").count - 1 == 1, "said more than once")
        let view = try Self.body(["struct FirstAnalysisMomentHeader", "var body: some View"], in: ring)
        #expect(view.contains(".onDisappear {") && view.contains("store.ended()"), "\(view)")
        // Shown only while it plays: no gap above "Analyse fertig" while it waits for the screen.
        #expect(view.contains("if store.moment.playing {"), "\(view)")
        // The wide figures; decoration for VoiceOver, found by the UI runs.
        #expect(header.contains(".font(.wideNumber(.largeTitle))"))
        #expect(header.contains(".accessibilityIdentifier(\"analysis.firstFinish\")"))
        #expect(header.contains(".accessibilityHidden(!UITestSupport.isRunning)"))
        #expect(bar.contains("FirstAnalysisMoment.segments(shares: shares, width: Double(rect.width), joined: joined)"))
    }

    /// UI runs show it only when a test asks for it (`-AlbumistUITestFirstFinishMoment`), held
    /// long enough to be found; otherwise the start page would change under the audits after
    /// the first analysis. A test may also start it afresh (`-AlbumistUITestFirstFinishOwed`):
    /// the simulators of the UI groups are not fresh. Never so in the shipped app.
    @Test func uiRunsShowItOnlyWhenATestAsks() throws {
        let store = try Self.code(Self.store)
        let claim = try Self.body(["final class FirstAnalysisMomentStore", "func claim(onScreen: Bool)"], in: store)
        #expect(claim.contains("guard moment.dueSince != nil, !UITestSupport.isRunning || UITestSupport.showsFirstFinishMoment else { return false }"), "\(claim)")
        let ring = try Self.code(Self.ringCard)
        let play = try Self.body(["struct FirstAnalysisMomentHeader", "private func play() async"], in: ring)
        #expect(play.contains("let hold = UITestSupport.showsFirstFinishMoment ? T.heldForUITest : T.hold"), "\(play)")
        // Afresh: nothing kept is read, no analysis completed before counts, and the launch does
        // not look at the marker (the test rebuilds the database, which resets it right after).
        let initializer = try Self.body(["final class FirstAnalysisMomentStore", "private init()"], in: store)
        #expect(initializer.contains("let fresh = UITestSupport.startsFirstFinishOwed"), "\(initializer)")
        #expect(initializer.contains("let kept = fresh ? nil : UserDefaults.standard.string(forKey: Self.key)"), "\(initializer)")
        let launched = try Self.body(["final class FirstAnalysisMomentStore", "func launched()"], in: store)
        #expect(launched.contains("guard !UITestSupport.startsFirstFinishOwed else { return }"), "\(launched)")
        // The UI test that asks for both, and finds the moment by its identifier.
        let test = try AppSource.read(Self.uiTest)
        for asked in ["\"-AlbumistUITestFirstFinishMoment\"", "\"-AlbumistUITestFirstFinishOwed\"",
                      "\"-AlbumistUITestRebuildDatabase\"", "\"analysis.firstFinish\""] {
            #expect(test.contains(asked), "the UI test does not use \(asked)")
        }
    }

    /// The switches of DS-08 live with the other UI-test switches (`UITestSwitches.swift`), read
    /// through `flag`, which is false unless a debug build was started by the UI tests
    /// (`UITestSupport.isRunning` is false in a release build), and nothing else in the App reads
    /// them than the store and the ring card.
    @Test func theFirstFinishSwitchesAreInertOutsideUIRuns() throws {
        let switches = try Self.code(Self.switches)
        #expect(switches.contains("static let showsFirstFinishMoment = flag(\"-AlbumistUITestFirstFinishMoment\")"))
        #expect(switches.contains("static let startsFirstFinishOwed = flag(\"-AlbumistUITestFirstFinishOwed\")"))
        let flag = try Self.body(["extension UITestSupport", "private static func flag(_ name: String) -> Bool"], in: switches)
        #expect(flag.contains("isRunning && ProcessInfo.processInfo.arguments.contains(name)"), "\(flag)")
        let support = try Self.code("App/Albumist/Platform/UITestSupport.swift")
        let running = try Self.body(["enum UITestSupport", "static let isRunning: Bool ="], in: support)
        let release = try #require(running.range(of: "#else"), "\(running)")
        #expect(running[release.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("false"), "\(running)")
        // Read by the store (the claim and the fresh start) and the ring card (the hold) only.
        var readers: [String: Int] = [:]
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = try Self.code(path)
            let count = code.components(separatedBy: "UITestSupport.showsFirstFinishMoment").count - 1
                + code.components(separatedBy: "UITestSupport.startsFirstFinishOwed").count - 1
            if count > 0 { readers[path] = count }
        }
        #expect(readers == [Self.store: 3, Self.ringCard: 1], "\(readers)")
        // No other trace of the old flag in the store.
        #expect(!(try Self.code(Self.store)).contains("ProcessInfo.processInfo.arguments"))
    }

    /// What VoiceOver says, in German and English.
    @Test func theSpokenLineIsInTheCatalog() throws {
        let data = try #require(try AppSource.read("App/Albumist/Resources/Localizable.xcstrings").data(using: .utf8))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings["Analyse fertig: %@"] as? [String: Any], "the spoken line is not in the catalog")
        let english = (((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        #expect(english == "Analysis complete: %@")
        let ring = try Self.code(Self.ringCard)
        #expect(ring.contains("String(localized: \"Analyse fertig: \\(percent)\")"))
    }
}
