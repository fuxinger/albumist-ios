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
    /// run: told before the wait for the overview, with whether Albumist is on screen. The
    /// overnight refinement that completes the analysis tells it too (second review, K7). Eight
    /// marked lines of DS-08 in `AppModel.swift` (three of the moment, five of the legs of the
    /// first analysis, X9) and one of V13, nothing else there.
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
        #expect(model.components(separatedBy: "FirstAnalysisMomentStore.shared.").count - 1 == 1, "told from another place too")
        #expect(model.components(separatedBy: "firstAnalysisCompletedAway()").count - 1 == 1, "told from another place too")
        #expect(raw.components(separatedBy: "\(Self.mark): the first 100 %").count - 1 == 8, "the marked lines of DS-08 in AppModel.swift changed")
        // And one of the sorting show's "Anlegen" (verification review V13), nothing else of H13.
        #expect(raw.components(separatedBy: Self.mark).count - 1 == 9, "the marked lines of H13 in AppModel.swift changed")
    }

    /// "On screen" as a run ends means not in the background (second review, K7 b): Control
    /// Center, an alert or a call banner in front leave the scene inactive, not gone, and must not
    /// spend the moment. The card claims it once Albumist is active again (`claim` waits for
    /// `isOnScreen`); gone to the background before, it is not shown later (`leftScreen`).
    @Test func aRunThatEndsBehindControlCenterStillCounts() throws {
        let store = try Self.code(Self.store)
        let tell = try Self.body(["extension AppModel", "func firstAnalysisRunEnded("], in: store)
        #expect(tell.contains("UIApplication.shared.applicationState != .background"), "\(tell)")
        #expect(!tell.contains("isOnScreen"), "the end of a run asks whether the scene is active: \(tell)")
        let ring = try Self.code(Self.ringCard)
        let start = try Self.body(["struct FirstAnalysisMomentHeader", "private func start()"], in: ring)
        #expect(start.contains("store.claim(onScreen: model.isOnScreen)"), "\(start)")
        #expect(ring.contains(".onChange(of: model.isOnScreen) { _, onScreen in if onScreen { start() } }"))
        let initializer = try Self.body(["final class FirstAnalysisMomentStore", "private init()"], in: store)
        #expect(initializer.contains("UIApplication.didEnterBackgroundNotification") && initializer.contains("self?.leftScreen()"))
    }

    /// The analysis completed where no run of the app ended (the overnight refinement): the store
    /// hears it there, before the marker says so, and a first 100 % that happened without the
    /// user is spent. Coming to the front no longer looks at the marker: a quick first analysis
    /// completed it without "Analyse fertig", and the moment waits for the first celebrated
    /// finish (second review, K7 a).
    @Test func theRefinementThatCompletesTheAnalysisTellsTheStore() throws {
        let model = try Self.code(Self.model)
        let refine = try Self.body(["private func refinePass("], in: model)
        let told = try #require(refine.range(of: "firstAnalysisCompletedAway()"), "the refinement does not tell the moment: \(refine)")
        let marked = try #require(refine.range(of: "AnalysisMarker.finished()"), "\(refine)")
        #expect(told.upperBound < marked.lowerBound, "told after the marker says completed")
        // Whether it was completed before, and whether every photo is allowed: after only the
        // shared photos, a completion with every photo analysed the rest (verification review Y).
        let store = try Self.code(Self.store)
        let away = try Self.body(["extension AppModel", "func firstAnalysisCompletedAway()"], in: store)
        #expect(away.contains("FirstAnalysisMomentStore.shared.completedAway(first: !AnalysisMarker.completedOnce, fullAccess: access == .full)"),
                "\(away)")
        #expect(!store.contains("willEnterForegroundNotification"), "coming to the front spends it by the marker")
        #expect(!store.contains("cameToFront"), "coming to the front spends it by the marker")
    }

    /// After a quick first analysis the store waits seven days for a run of the whole library
    /// (verification review V6): the end of a run says whether it was one, from the marker before
    /// this run's end sets it (no analysis completed since `AnalysisMarker.reset`: the first
    /// analysis, "Analyse neu aufbauen", another part of the library), so `AppModel.swift` passes
    /// nothing new. When the first completion was is kept next to the moment, and a wait that is
    /// over spends it at launch.
    @Test func aQuickFirstAnalysisWaitsAWeekForTheWholeLibrary() throws {
        let store = try Self.code(Self.store)
        let tell = try Self.body(["extension AppModel", "func firstAnalysisRunEnded("], in: store)
        #expect(tell.contains("FirstAnalysisMomentStore.shared.runEnded(firstAnalysisRun, finished: finished, celebrates: celebrates,"),
                "\(tell)")
        // The same run as it starts (the legs, `FirstAnalysisLegsSourceTests`) and as it ends. Every
        // photo readable: after a quick first analysis of only the shared photos, the first such
        // run analyses the rest of the library (K7's case).
        let run = try Self.body(["extension AppModel", "private var firstAnalysisRun: FirstAnalysisMoment.Run"], in: store)
        #expect(run.contains("FirstAnalysisMoment.Run(wholeLibrary: !AnalysisMarker.completedOnce, fullAccess: access == .full)"),
                "\(run)")
        let ended = try Self.body(["final class FirstAnalysisMomentStore",
                                   "func runEnded(_ run: FirstAnalysisMoment.Run, finished: Bool, celebrates: Bool, onScreen: Bool)"],
                                  in: store)
        #expect(ended.contains("guard finished else { return }"), "\(ended)")
        #expect(ended.contains("moment.runEnded(run, finished: finished, celebrates: celebrates, onScreen: onScreen, at: Date())"),
                "\(ended)")
        let type = try Self.body(["final class FirstAnalysisMomentStore"], in: store)
        #expect(type.contains("private static let firstCompletedKey = \"analysis.firstFinishMoment.firstCompleted\""), "\(type)")
        let initializer = try Self.body(["final class FirstAnalysisMomentStore", "private init()"], in: store)
        #expect(initializer.contains("let since = fresh ? nil : UserDefaults.standard.object(forKey: Self.firstCompletedKey) as? Date"), "\(initializer)")
        let lapse = try #require(initializer.range(of: "moment.lapse(at: Date())"), "the wait is not looked at, at launch: \(initializer)")
        let kept = try #require(initializer.range(of: "keep()"), "\(initializer)")
        #expect(lapse.upperBound < kept.lowerBound, "\(initializer)")
        let keep = try Self.body(["final class FirstAnalysisMomentStore", "private func keep()"], in: store)
        #expect(keep.contains("UserDefaults.standard.set(since, forKey: Self.firstCompletedKey)"), "\(keep)")
        #expect(keep.contains("UserDefaults.standard.removeObject(forKey: Self.firstCompletedKey)"), "\(keep)")
        // Whether that quick first analysis saw only the shared photos, kept beside it.
        #expect(type.contains("private static let sharedOnlyKey = \"analysis.firstFinishMoment.sharedOnly\""), "\(type)")
        #expect(initializer.contains("let sharedOnly = !fresh && UserDefaults.standard.bool(forKey: Self.sharedOnlyKey)"), "\(initializer)")
        #expect(keep.contains("UserDefaults.standard.set(true, forKey: Self.sharedOnlyKey)"), "\(keep)")
        #expect(keep.contains("UserDefaults.standard.removeObject(forKey: Self.sharedOnlyKey)"), "\(keep)")
    }

    /// The observers are written `any NSObjectProtocol`, as every existential of the App
    /// (`ExistentialAny` is on, App/project.yml; second review, K3).
    @Test func everyNSObjectProtocolIsWrittenAsAnExistential() throws {
        let project = try AppSource.read("App/project.yml")
        #expect(project.contains("SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY: YES"))
        var bare: [String] = []
        for path in AppSource.swiftFiles(under: "App") {
            let code = AppSource.code(try AppSource.read(path))
            for match in code.matches(of: /(\bany\s+)?\bNSObjectProtocol\b/) where match.output.1 == nil {
                bare.append(URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        #expect(bare.isEmpty, "\(bare)")
        let store = try Self.code(Self.store)
        #expect(store.contains("@ObservationIgnored private var observers: [any NSObjectProtocol] = []"))
    }

    /// Kept in `UserDefaults` under a key of its own (`AnalysisMarker.reset` does not clear it,
    /// a rebuilt database does not lose it, a device backup brings it back), never in the
    /// database. Leaving the screen ends a moment not seen. The store is made at launch, while the
    /// marker still says whether an analysis was completed before this version kept the moment.
    @Test func whatIsKeptLivesInUserDefaults() throws {
        let store = try Self.code(Self.store)
        let type = try Self.body(["final class FirstAnalysisMomentStore"], in: store)
        #expect(type.contains("private static let key = \"analysis.firstFinishMoment\""))
        #expect(type.contains("UserDefaults.standard.set(moment.kept.rawValue, forKey: Self.key)"))
        let initializer = try Self.body(["final class FirstAnalysisMomentStore", "private init()"], in: store)
        #expect(initializer.contains("FirstAnalysisMoment(kept: kept, completedBefore: !fresh && AnalysisMarker.completedOnce,"),
                "\(initializer)")
        #expect(initializer.contains("firstCompleted: since, sharedOnly: sharedOnly)"), "\(initializer)")
        #expect(initializer.contains("UIApplication.didEnterBackgroundNotification") && initializer.contains("self?.leftScreen()"))
        let launched = try Self.body(["final class FirstAnalysisMomentStore", "func launched()"], in: store)
        #expect(launched.trimmingCharacters(in: .whitespacesAndNewlines) == "{}", "\(launched)")
        let away = try Self.body(["final class FirstAnalysisMomentStore", "func completedAway(first: Bool, fullAccess: Bool)"], in: store)
        #expect(away.contains("moment.completedAway(first: first, fullAccess: fullAccess)") && away.contains("keep()"), "\(away)")
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
        // Besides, only a moment cut short, above the done line (verification review V12).
        #expect(card.components(separatedBy: "FirstAnalysisMomentHeader(").count - 1 == 2, "\(card)")
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
        #expect(view.contains(".onDisappear {") && view.contains("store.cardWent()"), "\(view)")
        // Shown only while it plays: no gap above "Analyse fertig" while it waits for the screen.
        #expect(view.contains("if store.moment.playing {"), "\(view)")
        // The wide figures; decoration for VoiceOver, found by the UI runs.
        #expect(header.contains(".font(.wideNumber(.largeTitle))"))
        #expect(header.contains(".accessibilityIdentifier(\"analysis.firstFinish\")"))
        #expect(header.contains(".accessibilityHidden(!UITestSupport.isRunning)"))
        #expect(bar.contains("FirstAnalysisMoment.segments(shares: shares, width: Double(rect.width), joined: joined)"))
    }

    /// Its card going while it plays does not lose it (verification review V12): the header tells
    /// the store that its card went (`cardWent`), which the rule answers by the time it showed and
    /// whether VoiceOver said it (`claim` hears that from `UIAccessibility.isVoiceOverRunning`, as
    /// the header says it right after the claim). Only the fold after its hold ends it.
    @Test func aCardThatGoesWhileItPlaysDoesNotLoseIt() throws {
        let ring = try Self.code(Self.ringCard)
        let view = try Self.body(["struct FirstAnalysisMomentHeader", "var body: some View"], in: ring)
        let gone = try #require(view.range(of: ".onDisappear {"), "\(view)")
        let after = view[gone.upperBound...]
        // Only the header that plays it tells (two places may show it, one goes as the other comes).
        let own = try #require(after.range(of: "guard let run else { return }"), "\(view)")
        let told = try #require(after.range(of: "store.cardWent()"), "the card's going ends the moment: \(view)")
        #expect(own.upperBound < told.lowerBound, "\(view)")
        #expect(!view.contains("store.ended()"), "the card's going ends the moment: \(view)")
        // A run that replaced its card leaves the start page on its done line once it ended: the
        // moment cut short plays there (only then, never one due for the first time).
        let overview = try Self.code(Self.overview)
        let done = try #require(overview.range(of: "FirstAnalysisMomentHeader(again: true)"), "the done line cannot play it")
        let row = try #require(overview[done.upperBound...].range(of: "doneRow"), "not above the done line")
        #expect(overview[done.upperBound..<row.lowerBound].count < 80, "not right above the done line")
        let raw = try AppSource.read(Self.overview)
        #expect(raw.contains("FirstAnalysisMomentHeader(again: true) \(Self.mark)"), "unmarked")
        let start = try Self.body(["struct FirstAnalysisMomentHeader", "private func start()"], in: ring)
        let only = try #require(start.range(of: "if again, !store.moment.cutShort { return }"), "\(start)")
        let claims = try #require(start.range(of: "store.claim(onScreen: model.isOnScreen)"), "\(start)")
        #expect(only.upperBound < claims.lowerBound, "\(start)")
        let play = try Self.body(["struct FirstAnalysisMomentHeader", "private func play() async"], in: ring)
        #expect(play.contains("store.ended()"), "\(play)")
        let store = try Self.code(Self.store)
        let claim = try Self.body(["final class FirstAnalysisMomentStore", "func claim(onScreen: Bool)"], in: store)
        #expect(claim.contains("moment.claim(at: Date(), onScreen: onScreen, announced: UIAccessibility.isVoiceOverRunning)"), "\(claim)")
        let went = try Self.body(["final class FirstAnalysisMomentStore", "func cardWent()"], in: store)
        #expect(went.contains("moment.cardWent(at: Date())"), "\(went)")
    }

    /// A 100 % played again (its card went within the hold and came back, V12) shows its bar
    /// joining again (verification review X10): the header's state lives on while its card is
    /// away (another tab, a pushed page), so `start` sets the bar apart again before the claim,
    /// after the guards that keep a header that plays from starting anew. Only `play` joins it.
    /// The header's state is SwiftUI's, which does not run here: the order is read from the code.
    @Test func aMomentPlayedAgainJoinsItsBarAgain() throws {
        let ring = try Self.code(Self.ringCard)
        let start = try Self.body(["struct FirstAnalysisMomentHeader", "private func start()"], in: ring)
        let playing = try #require(start.range(of: "guard run == nil, model.isOnScreen else { return }"), "\(start)")
        let cut = try #require(start.range(of: "if again, !store.moment.cutShort { return }"), "\(start)")
        let apart = try #require(start.range(of: "joined = false"), "a second play starts with its bar joined: \(start)")
        let claim = try #require(start.range(of: "store.claim(onScreen: model.isOnScreen)"), "\(start)")
        #expect(playing.upperBound < apart.lowerBound && cut.upperBound < apart.lowerBound,
                "the bar comes apart under a moment that plays: \(start)")
        #expect(apart.upperBound < claim.lowerBound, "the bar comes apart after the claim showed it: \(start)")
        let play = try Self.body(["struct FirstAnalysisMomentHeader", "private func play() async"], in: ring)
        #expect(play.contains("withAnimation(.easeInOut(duration: T.join)) { joined = true }"), "\(play)")
        let header = try Self.body(["struct FirstAnalysisMomentHeader"], in: ring)
        #expect(header.components(separatedBy: "joined = true").count - 1 == 1, "joined elsewhere: \(header)")
    }

    /// UI runs show it only when a test asks for it (`-AlbumistUITestFirstFinishMoment`), held
    /// long enough to be found; otherwise the start page would change under the audits after
    /// the first analysis. A test may also start it afresh (`-AlbumistUITestFirstFinishOwed`):
    /// the simulators of the UI groups are not fresh. Never so in the shipped app.
    @Test func uiRunsShowItOnlyWhenATestAsks() throws {
        let store = try Self.code(Self.store)
        let claim = try Self.body(["final class FirstAnalysisMomentStore", "func claim(onScreen: Bool)"], in: store)
        #expect(claim.contains("guard moment.dueSince != nil, !UITestSupport.isRunning || UITestSupport.showsFirstFinishMoment "
                               + "else { return false }"), "\(claim)")
        let ring = try Self.code(Self.ringCard)
        let play = try Self.body(["struct FirstAnalysisMomentHeader", "private func play() async"], in: ring)
        #expect(play.contains("let hold = UITestSupport.showsFirstFinishMoment ? T.heldForUITest : T.hold"), "\(play)")
        // Afresh: nothing kept is read and no analysis completed before counts (the test rebuilds
        // the database, which resets the marker right after).
        let initializer = try Self.body(["final class FirstAnalysisMomentStore", "private init()"], in: store)
        #expect(initializer.contains("let fresh = UITestSupport.startsFirstFinishOwed"), "\(initializer)")
        #expect(initializer.contains("let kept = fresh ? nil : UserDefaults.standard.string(forKey: Self.key)"), "\(initializer)")
        // The UI test that asks for both, and finds the moment by its identifier.
        let test = try AppSource.read(Self.uiTest)
        for asked in ["\"-AlbumistUITestFirstFinishMoment\"", "\"-AlbumistUITestFirstFinishOwed\"",
                      "\"-AlbumistUITestRebuildDatabase\"", "\"analysis.firstFinish\""] {
            #expect(test.contains(asked), "the UI test does not use \(asked)")
        }
    }

    /// UI test 1's "not again" half has teeth (verification review V7): both full analyses run
    /// slowed (`-AlbumistUITestSlowAnalysis`, 150 ms more per photo, one lane: the demo library's
    /// 241 photos take more than the 30 s "Analyse fertig" needs, on any Mac), and the test asserts
    /// that the second finish was celebrated before it asserts that no moment came. The switch is
    /// inert outside UI runs.
    @Test func theUITestsSecondFullAnalysisIsCelebrated() throws {
        let test = AppSource.code(try AppSource.read(Self.uiTest), keepStrings: true)
        let body = try Self.body(["final class ShowAndHandwritingUITests", "func test1_FirstFullAnalysisShowsItsHundredPercentOnce()"], in: test)
        let launches = body.components(separatedBy: "launch([").dropFirst().map { $0.prefix(while: { $0 != "]" }) }
        #expect(launches.count == 2, "\(launches)")
        for launch in launches {
            #expect(launch.contains("\"-AlbumistUITestSlowAnalysis\""), "a full analysis that may end before 30 s: \(launch)")
        }
        let celebrated = try #require(body.range(of: "XCTAssertTrue(next.celebrated"), "the second finish may go uncelebrated: \(body)")
        let noMoment = try #require(body.range(of: "XCTAssertFalse(next.moment"), "\(body)")
        #expect(celebrated.upperBound < noMoment.lowerBound, "\(body)")
        let support = try Self.code("App/Albumist/Platform/UITestSupport.swift")
        #expect(support.contains("static let slowsAnalysis: Bool = isRunning && ProcessInfo.processInfo.arguments.contains(\"-AlbumistUITestSlowAnalysis\")"))
        let demo = try Self.code("App/Albumist/Platform/DemoLibrary.swift")
        #expect(demo.contains("+ 45 + 12 + Self.screenshots.count + Self.documents.count + 1"), "the demo library changed size")
    }

    /// The UI test keeps what its wait for "Analyse fertig" saw (verification review Y, Y6): the
    /// 20 s it waits for the card or the moment count "Analyse fertig" seen in them as celebrated,
    /// so a run that starts in the 5 s after (it replaces the card) cannot turn a celebrated
    /// finish into a failure.
    @Test func theUITestKeepsWhatItsWaitSaw() throws {
        let test = AppSource.code(try AppSource.read(Self.uiTest), keepStrings: true)
        let watch = try Self.body(["final class ShowAndHandwritingUITests", "private func watchAnalysis("], in: test)
        let seen = "end.celebrated = end.celebrated || finished.exists"
        let wait = try #require(watch.range(of: "UITestWait.holds(timeout: 20) {"), "\(watch)")
        let during = try #require(watch.range(of: seen), "the wait forgets what it saw: \(watch)")
        let moment = try #require(watch.range(of: "end.moment = moment.waitForExistence(timeout: 5)"), "\(watch)")
        #expect(wait.upperBound < during.lowerBound && during.upperBound < moment.lowerBound, "\(watch)")
        let after = try #require(watch.range(of: seen, options: .backwards), "\(watch)")
        #expect(moment.upperBound < after.lowerBound, "the end forgets what the wait saw: \(watch)")
        #expect(!watch.contains("end.celebrated = finished.exists"), "\(watch)")
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
        #expect(readers == [Self.store: 2, Self.ringCard: 1], "\(readers)")
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
