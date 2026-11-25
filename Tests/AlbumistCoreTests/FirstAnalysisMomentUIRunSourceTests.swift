import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// DS-08 in UI runs: the moment shows there only when a test asks for it, the switches that ask
/// are inert outside UI runs, and UI test 1 (`ShowAndHandwritingUITests`) shows it once and
/// never again with teeth. Split from `FirstAnalysisMomentSourceTests`, whose paths and helpers
/// it uses; the App does not build on Linux, so these tests read its code (`AppSource`).
@Suite("First analysis moment in UI runs (DS-08)")
struct FirstAnalysisMomentUIRunSourceTests {
    static let store = FirstAnalysisMomentSourceTests.store
    static let ringCard = FirstAnalysisMomentSourceTests.ringCard
    static let switches = "App/Albumist/Platform/UITestSwitches.swift"
    static let uiTest = "App/AlbumistUITests/ShowAndHandwritingUITests.swift"

    static func code(_ path: String) throws -> String {
        try FirstAnalysisMomentSourceTests.code(path)
    }

    static func body(_ path: [String], in file: String) throws -> String {
        try FirstAnalysisMomentSourceTests.body(path, in: file)
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
        #expect(play.contains("let hold = UITestSupport.showsFirstFinishMoment ? Timing.heldForUITest : Timing.hold"), "\(play)")
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
}
