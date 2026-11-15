import Foundation
import Synchronization
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// A full analysis on a library shaped like the owner's iPhone (5,683 items, ~1,040
/// screenshots, 19 countries, 103 trips, ~1,600 photos with a location that need Apple's
/// geocoder), with simulated time: every photo, text and town lookup takes its device time on
/// a simulated clock, sleeps advance it at once. Every `Progress` event is recorded with its
/// simulated time and checked against what the analysis card must never show: a stage that
/// does not say when it begins, a count that goes back or stands at "N von N" while work goes
/// on, a bar that jumps back after Pause, a silent stretch, a Pause that takes long.
///
/// Before every build for the device (promise 15.11.). `SORTLY_SIM_SCALE` (default 1) scales
/// the library; proportions, the geocoder's limit and the online budget stay.
@Suite("Full simulated run: what the analysis card shows")
struct FullRunDisplayTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    /// The uninterrupted run (a) always simulates the whole library; the other scenarios half
    /// of it (same proportions, same geocoder limit and online budget), so the suite stays fast.
    /// `SORTLY_SIM_SCALE=1` runs every scenario at full size (about 20 s on Linux).
    static let scaleOverride: Double? = ProcessInfo.processInfo.environment["SORTLY_SIM_SCALE"].flatMap(Double.init)
    static let scale: Double = scaleOverride ?? 0.5

    // MARK: Scenarios

    /// (a) One uninterrupted full run.
    @Test func uninterruptedFullRun() async throws {
        let sim = try Sim(scale: Self.scaleOverride ?? 1)
        #expect(sim.library.total == 5_683 || Self.scaleOverride != nil)
        let run = await sim.run("a")
        sim.expectComplete(run)
        // Every photo looked at exactly once, also with batches cut every second and photos
        // without a date.
        #expect(sim.analyzer.contentCalls.withLock { $0 } == sim.library.total)
        // Every stage was shown, in order (places has work: town names are looked up).
        #expect(run.stagesShown == Stage.allCases, "\(run.stagesShown)")
        // The online budget of a run in the app was used, then the rest waits for later.
        #expect(run.report?.onlineRequests == 60)
        #expect((run.report?.placesPendingOnline ?? 0) > 0)
        sim.finish()
    }

    /// (b) Pause in places (while Apple's geocoder refuses), in content and in text; each
    /// time a new run goes on.
    @Test func pauseInEveryStageThenResume() async throws {
        let sim = try Sim()
        // Apple refuses four lookups in a row: the run waits 30 s for it.
        sim.geocoder.refuseCalls(10..<14)
        let places = await sim.run("b1 pause in places", pause: .whenGeocoderRefusedFor(.seconds(5)))
        #expect(places.report?.pausedBecause == .userPaused)
        #expect(places.lastStage == .places, "paused in \(String(describing: places.lastStage))")
        sim.geocoder.refuseCalls(0..<0)
        // Fortsetzen within the hour does not ask Apple for town names again (device test
        // 15.11.: "es dauert lange, bis die App nach Pause weiterläuft").
        let askedInFirstRun = sim.geocoder.calls.withLock { $0 }

        let content = await sim.run("b2 pause in content", pause: .when(stage: .content, atLeast: 0.3))
        #expect(content.report?.pausedBecause == .userPaused)
        #expect(content.lastStage == .content)

        let text = await sim.run("b3 pause in text", pause: .when(stage: .text, atLeast: 0.4))
        #expect(text.report?.pausedBecause == .userPaused)
        #expect(text.lastStage == .text)

        let rest = await sim.run("b4 goes on to the end")
        sim.expectComplete(rest)
        #expect(sim.geocoder.calls.withLock { $0 } == askedInFirstRun)
        #expect(sim.clock.now < .seconds(3_600))
        // Pause finishes the photos in work and keeps them: none is looked at twice.
        #expect(sim.analyzer.contentCalls.withLock { $0 } == sim.library.total)
        sim.finish()
    }

    /// (c) The app is ended in the middle of the image analysis; a fresh pipeline on the same
    /// store goes on.
    @Test func restartMidContentWithFreshPipeline() async throws {
        let sim = try Sim()
        let first = await sim.run("c1 ended mid-content", pause: .when(stage: .content, atLeast: 0.5), action: .cancel)
        #expect(first.lastStage == .content)
        sim.restartPipeline()
        let second = await sim.run("c2 fresh pipeline")
        sim.expectComplete(second)
        // Nothing analysed twice beyond the photos in work when the app was ended.
        #expect(sim.analyzer.contentCalls.withLock { $0 } <= sim.library.total + 8)
        sim.finish()
    }

    /// (d) After a complete run, "Analyse neu aufbauen" clears the analysis, then a full run.
    @Test func rebuildAfterCompleteRun() async throws {
        let sim = try Sim()
        sim.expectComplete(await sim.run("d1 full"))
        try await sim.store.resetAnalysis(includingDecisions: false)
        sim.newAnalysis()
        let rebuilt = await sim.run("d2 after reset")
        sim.expectComplete(rebuilt)
        // Counted from zero again (nothing is left over from before the reset).
        #expect(rebuilt.first(.content)?.completed == 0)
        #expect(rebuilt.first(.places)?.completed == 0)
        sim.finish()
    }

    /// (e) The device warms up during the image analysis: normal, gentle, waiting, normal.
    @Test func devicePaceChangesDuringContent() async throws {
        let sim = try Sim()
        let conditions = sim.conditions
        conditions.plan.withLock {
            $0.anchor = nil
            $0.steps = [(.seconds(20), .gentle), (.seconds(60), .wait(.thermal)), (.seconds(90), .normal)]
        }
        sim.onProgress = { progress, t in
            if progress.stage == .content { conditions.plan.withLock { if $0.anchor == nil { $0.anchor = t } } }
        }
        let run = await sim.run("e pace")
        sim.expectComplete(run)
        #expect(sim.analyzer.contentCalls.withLock { $0 } == sim.library.total)
        #expect(run.waits == [.thermal, nil], "\(run.waits)")
        sim.finish()
    }

    /// (f) Apple's geocoder keeps refusing; a run within the hour does not ask again; the run
    /// after the hour uses up the online budget.
    @Test func throttledGeocoderAndUsedUpBudget() async throws {
        let sim = try Sim()
        sim.geocoder.refuseCalls(5..<Int.max)
        let throttled = await sim.run("f1 geocoder throttled")
        sim.expectComplete(throttled)
        #expect(throttled.report?.placesThrottled == true)
        sim.geocoder.refuseCalls(0..<0)
        let asked = sim.geocoder.calls.withLock { $0 }
        let soon = await sim.run("f2 within the hour")
        sim.expectComplete(soon)
        #expect(soon.report?.onlineRequests == 0)
        #expect(sim.geocoder.calls.withLock { $0 } == asked)
        #expect(soon.first(.places)?.completed == throttled.last(.places)?.completed)
        sim.clock.advance(.seconds(AnalysisPipeline.foregroundOnlineCooldown))
        let budget = await sim.run("f3 after the hour, budget used up")
        sim.expectComplete(budget)
        #expect(budget.report?.onlineRequests == 60)
        #expect((budget.report?.placesPendingOnline ?? 0) > 0)
        sim.finish()
    }

    // MARK: The new card (progress display v3)

    /// (g) P2: iOS holds the app for 10 minutes in the middle of the image analysis (no
    /// continued task). The time in between is not counted: no finish time for 30 s after it
    /// comes back (invariant 9), then a right one again.
    @Test func backgroundGapResettles() async throws {
        let sim = try Sim()
        let suspended = Mutex(false)
        sim.onProgress = { [weak sim] progress, _ in
            guard progress.stage == .content, progress.total > 0,
                  Double(progress.completed) >= 0.3 * Double(progress.total),
                  suspended.withLock({ let was = $0; $0 = true; return !was }) else { return }
            sim?.suspend(.seconds(600))
        }
        let run = await sim.run("g background")
        sim.expectComplete(run)
        #expect(suspended.withLock { $0 })
        let late = sim.finishTimes.filter { entry in
            guard case .at(let date) = entry.shown, entry.end - entry.t < .seconds(400) else { return false }
            return abs(date.timeIntervalSince(SimClock.base.addingTimeInterval(entry.end.seconds))) > 120
        }
        #expect(late.isEmpty, "\(late.count) finish times more than 2 min off after the gap")
        sim.finish()
    }

    /// (h) P8: an empty library finishes without a finish time and without a count standing.
    @Test func emptyLibraryShowsNoTime() async throws {
        let sim = try Sim(scale: 0.05, empty: true)
        let run = await sim.run("h empty")
        sim.expectComplete(run)
        #expect(sim.finishTimes.isEmpty)
        #expect(run.progress.compactMap(\.workload).first?.photos == 0)
        sim.finish()
    }

    /// The workload is said exactly once per run, with the library's amounts; the bar's widths
    /// come from it. "Gerade angesehen" never shows a screenshot (B4).
    @Test func workloadIsSaidOnceWithTheLibrarysAmounts() async throws {
        let sim = try Sim(scale: 0.2)
        let run = await sim.run("workload")
        sim.expectComplete(run)
        let workloads = run.progress.compactMap(\.workload)
        #expect(workloads.count == 1)
        let w = try #require(workloads.first)
        #expect(w.photos == sim.library.total)
        #expect(w.located == sim.library.located)
        #expect(w.screenshots == sim.library.screenshots)
        #expect(w.contentLeft == sim.library.total)
        #expect(w.textLeft == sim.library.screenshots)
        let screenshots = Set(sim.library.assets.filter(\.isScreenshotLike).map(\.id))
        let recent = run.progress.flatMap(\.recent)
        #expect(!recent.isEmpty)
        #expect(recent.allSatisfy { !screenshots.contains($0) })
        #expect(run.progress.allSatisfy { $0.recent.count <= 3 })
        // The second run has nothing left to look at.
        let again = await sim.run("workload again")
        let second = try #require(again.progress.compactMap(\.workload).first)
        #expect(second.contentLeft == 0 && second.textLeft == 0)
        sim.finish()
    }

    /// P16, point 3: the suggestions offered before the image analysis ("Schon fertig: …",
    /// "Ansehen") keep their ids in the final set, so a decision made on them stays.
    @Test func earlyProposalsKeepTheirIDs() async throws {
        let sim = try Sim(scale: 0.2)
        let paused = await sim.run("early", pause: .when(stage: .content, atLeast: 0.2))
        #expect(paused.report?.earlyProposals == true)
        let early = try #require(try await sim.pipeline.latestProposals())
        let earlyIDs = Set(early.proposals.filter { [.trips, .places, .frequentPlaces].contains($0.kind.area) }.map(\.id))
        #expect(!earlyIDs.isEmpty)
        let done = AlreadyDone.counts(proposals: early.proposals, step: .content)
        #expect(done.trips > 0 && done.places > 0, "\(done)")
        let rest = await sim.run("final")
        sim.expectComplete(rest)
        let final = try #require(try await sim.pipeline.latestProposals())
        let missing = earlyIDs.subtracting(final.proposals.map(\.id))
        #expect(missing.isEmpty, "\(missing.count) of \(earlyIDs.count) early suggestions are not in the final set")
        sim.finish()
    }

    // MARK: Focused checks of the engine fixes

    /// A wait for Apple's geocoder (its limit of about 40 lookups a minute, or a refusal) is
    /// said every 2 s with the time left, so the card can show it instead of a count that
    /// stands for up to a minute.
    @Test func geocoderWaitsAreAnnounced() async throws {
        let clock = SimClock()
        let geocoder = SimGeocoder(clock: clock, map: Self.map)
        geocoder.refuseCalls(45..<46)
        let requests: [PlaceResolutionService.Request] = (0..<60).map { i in
            .init(assetID: AssetID("w-\(i)"), coordinate: GeoCoordinate(latitude: 48 + Double(i) * 0.1, longitude: 11))
        }
        let service = PlaceResolutionService(map: Self.map, geocoder: geocoder, cache: MemoryPlaceCache(),
                                             policy: PlaceResolutionPolicy(deepestLevel: .locality, onlineAllowed: true, language: .german),
                                             time: clock.source)
        let seen = Mutex<[(Duration, Duration?)]>([])
        _ = try await service.resolve(requests, maxRateLimitWait: .seconds(30),
                                      progress: { _ in seen.withLock { $0.append((clock.now, nil)) } },
                                      waiting: { left in seen.withLock { $0.append((clock.now, left)) } }) { _ in }
        let events = seen.withLock { $0 }
        let gaps = zip(events, events.dropFirst()).map { $1.0 - $0.0 }
        #expect(gaps.allSatisfy { $0 <= .seconds(2) + SimCost.geocode }, "\(gaps.max() ?? .zero)")
        // The throttle's wait and the refusal's wait were both said, with the time left.
        #expect(events.contains { $0.1 != nil && $0.1! > .seconds(20) })
        #expect(clock.now > .seconds(60))
    }

    /// Lookups left for a later run (budget, refusal, Pause) are not counted as done: the run
    /// that goes on starts where this one ended, not below.
    @Test func placesLeftForLaterAreNotCountedAsDone() async throws {
        let sim = try Sim(scale: 0.1)
        let first = await sim.run("places first")
        let last = try #require(first.last(.places))
        #expect(last.completed < last.total)
        let second = await sim.run("places again")
        #expect(second.first(.places)?.completed == last.completed)
        sim.finish()
    }

    /// The trip detection says that it begins: the card no longer stands at
    /// "Mediathek wird gelesen · N von N" while trips are computed.
    @Test func patternsSayWhenTheyBegin() async throws {
        let sim = try Sim(scale: 0.05)
        let run = await sim.run("patterns")
        let patterns = run.progress.filter { $0.stage == .patterns }
        #expect(patterns.first?.completed == 0)
        #expect(patterns.last?.completed == 1)
    }

    /// The image analysis saves and reports at least once a second, also on a warm device
    /// (a break after every photo, half the lanes): before, 50 photos made one step of
    /// 13 s or more.
    @Test func contentCountMovesEverySecondOnAWarmDevice() async throws {
        let sim = try Sim(scale: 0.05)
        sim.conditions.plan.withLock { $0.steps = [(.zero, .gentle)] }
        let run = await sim.run("gentle")
        sim.expectComplete(run)
        let content = run.timeline.filter { if case .progress(let p) = $0.kind { return p.stage == .content } else { return false } }
        let gaps = zip(content, content.dropFirst()).map { $1.t - $0.t }
        #expect(gaps.allSatisfy { $0 <= .seconds(2) }, "\(gaps.max() ?? .zero)")
        sim.finish()
    }

    /// A run that goes on in the text stage shows the texts read so far at once, not "0" first
    /// (the bar went back below where the paused run had got to).
    @Test func resumedTextStageStartsWhereItStopped() async throws {
        let sim = try Sim(scale: 0.1)
        let paused = await sim.run("text paused", pause: .when(stage: .text, atLeast: 0.5))
        let last = try #require(paused.last(.text))
        let resumed = await sim.run("text resumed")
        let first = try #require(resumed.first(.text))
        #expect(first.completed >= last.completed && first.total == last.total, "\(first) after \(last)")
        sim.finish()
    }
}

// MARK: - Simulated device

typealias Stage = AnalysisPipeline.Stage
typealias PipelineProgress = AnalysisPipeline.Progress

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Device time per piece of work (an iPhone of the owner's kind). Content and text run in
/// lanes side by side; the simulated clock adds up the work, so each value is the time per
/// photo with all lanes busy (4 lanes à 0.4 s, 2 lanes à 1 s).
enum SimCost {
    static let content: Duration = .milliseconds(100)
    static let text: Duration = .milliseconds(500)
    static let geocode: Duration = .milliseconds(300)
    /// One photo's own time in a lane: what Pause may still wait for.
    static func item(_ stage: Stage?) -> Duration {
        switch stage {
        case .places: geocode
        case .content: content * 4
        case .text: text * 2
        default: .zero
        }
    }
}

/// Simulated clock: sleeping and work advance it at once; hooks see every step.
final class SimClock: @unchecked Sendable {
    private let state = Mutex<Duration>(.zero)
    private let hooks = Mutex<[@Sendable (Duration) -> Void]>([])
    static let base = Fixture.date("2026-11-15 08:00")

    var now: Duration { state.withLock { $0 } }
    var date: Date { Self.base.addingTimeInterval(now.seconds) }

    func advance(_ d: Duration) {
        let t = state.withLock { $0 += d; return $0 }
        for hook in hooks.withLock({ $0 }) { hook(t) }
    }

    func onTick(_ hook: @escaping @Sendable (Duration) -> Void) { hooks.withLock { $0.append(hook) } }

    /// iOS holds the app: time passes without any work and without the hooks.
    func jump(_ d: Duration) { state.withLock { $0 += d } }

    var source: TimeSource { TimeSource(elapsed: { self.now }, sleep: { self.advance($0) }) }
}

extension Sim {
    /// Logs a suspension in the run in progress and lets the time pass.
    func suspend(_ d: Duration) {
        currentLog?.add(.suspended(d), at: clock.now)
        clock.jump(d)
    }
}

/// The device's pace: `steps` (time after `anchor`, pace from then on); normal before.
final class SimConditions: AnalysisConditions, @unchecked Sendable {
    struct Plan: Sendable {
        var anchor: Duration? = .zero
        var steps: [(after: Duration, pace: AnalysisPace)] = []
    }
    let clock: SimClock
    let plan = Mutex(Plan())
    init(clock: SimClock) { self.clock = clock }
    func pauseReason() async -> PauseReason? { nil }
    func pace() async -> AnalysisPace {
        let now = clock.now
        return plan.withLock { plan in
            guard let anchor = plan.anchor else { return .normal }
            return plan.steps.last { now - anchor >= $0.after }?.pace ?? .normal
        }
    }
    func isOnWiFi() async -> Bool { true }
}

/// Apple's geocoder: 0.3 s per lookup, refuses the calls in `refused` (rate limit).
final class SimGeocoder: ReverseGeocoding, @unchecked Sendable {
    let clock: SimClock
    let map: OfflineWorldMap
    let calls = Mutex(0)
    let refusals = Mutex<[Duration]>([])
    private let refused = Mutex<Range<Int>>(0..<0)
    var onCall: (@Sendable (Stage) -> Void)?

    init(clock: SimClock, map: OfflineWorldMap) {
        self.clock = clock
        self.map = map
    }

    func refuseCalls(_ range: Range<Int>) { refused.withLock { $0 = range } }

    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
        onCall?(.places)
        clock.advance(SimCost.geocode)
        let n = calls.withLock { $0 += 1; return $0 - 1 }
        if refused.withLock({ $0.contains(n) }) {
            refusals.withLock { $0.append(clock.now) }
            throw GeocodingError.rateLimited(retryAfter: nil)
        }
        let destination = SimLibrary.destinations.min { GeoMath.distance($0.coordinate, coordinate) < GeoMath.distance($1.coordinate, coordinate) }!
        let code = map.lookup(coordinate).country.map { String($0.isoCode.prefix(2)) }
        return PlaceComponents(isoCountryCode: code, locality: "\(destination.name) \(Int(coordinate.latitude * 20))/\(Int(coordinate.longitude * 20))",
                               timeZoneIdentifier: destination.zone)
    }
}

final class SimAnalyzer: ContentAnalyzing, @unchecked Sendable {
    let clock: SimClock
    let contentCalls = Mutex(0)
    var onCall: (@Sendable (Stage) -> Void)?
    init(clock: SimClock) { self.clock = clock }

    func analyzeContent(_ asset: AssetSnapshot, request: ContentAnalysisRequest) async throws -> ContentAnalysis {
        onCall?(.content)
        contentCalls.withLock { $0 += 1 }
        clock.advance(SimCost.content)
        let labels = asset.isScreenshotLike ? [LabelScore("document", 0.3)] : [LabelScore(asset.id.rawValue.hasSuffix("3") ? "dog" : "outdoor", 0.8)]
        return ContentAnalysis(labels: labels, source: .localPreview)
    }

    func recognizeText(_ asset: AssetSnapshot, allowNetwork: Bool) async throws -> TextAnalysis {
        onCall?(.text)
        clock.advance(SimCost.text)
        let text = asset.id.rawValue.hasSuffix("1") ? "Ihre Bestellung Bestellnummer 302-1234567 Lieferung" : "Akku 80 % Einstellungen WLAN"
        return TextAnalysis(text: text, source: .original)
    }
}

/// The owner's library, scaled: 5,683 items over 3.5 years, ~1,040 screenshots, 103 trips to
/// 19 countries, ~1,600 photos with a location (trips and some at home), the rest at home
/// without a location.
struct SimLibrary {
    struct Destination { var name: String; var coordinate: GeoCoordinate; var zone: String }
    static let destinations: [Destination] = [
        .init(name: "Rom", coordinate: Fixture.Places.rome, zone: "Europe/Rome"),
        .init(name: "Paris", coordinate: GeoCoordinate(latitude: 48.8566, longitude: 2.3522), zone: "Europe/Paris"),
        .init(name: "Barcelona", coordinate: GeoCoordinate(latitude: 41.3874, longitude: 2.1686), zone: "Europe/Madrid"),
        .init(name: "Lissabon", coordinate: GeoCoordinate(latitude: 38.7223, longitude: -9.1393), zone: "Europe/Lisbon"),
        .init(name: "New York", coordinate: GeoCoordinate(latitude: 40.7128, longitude: -74.0060), zone: "America/New_York"),
        .init(name: "Tokio", coordinate: GeoCoordinate(latitude: 35.6762, longitude: 139.6503), zone: "Asia/Tokyo"),
        .init(name: "Reykjavík", coordinate: GeoCoordinate(latitude: 64.1466, longitude: -21.9426), zone: "Atlantic/Reykjavik"),
        .init(name: "Athen", coordinate: GeoCoordinate(latitude: 37.9838, longitude: 23.7275), zone: "Europe/Athens"),
        .init(name: "Sydney", coordinate: Fixture.Places.sydney, zone: "Australia/Sydney"),
        .init(name: "Wien", coordinate: GeoCoordinate(latitude: 48.2082, longitude: 16.3738), zone: "Europe/Vienna"),
        .init(name: "Prag", coordinate: GeoCoordinate(latitude: 50.0755, longitude: 14.4378), zone: "Europe/Prague"),
        .init(name: "Amsterdam", coordinate: GeoCoordinate(latitude: 52.3676, longitude: 4.9041), zone: "Europe/Amsterdam"),
        .init(name: "London", coordinate: GeoCoordinate(latitude: 51.5072, longitude: -0.1276), zone: "Europe/London"),
        .init(name: "Kopenhagen", coordinate: GeoCoordinate(latitude: 55.6761, longitude: 12.5683), zone: "Europe/Copenhagen"),
        .init(name: "Luzern", coordinate: GeoCoordinate(latitude: 47.0502, longitude: 8.3093), zone: "Europe/Zurich"),
        .init(name: "Budapest", coordinate: GeoCoordinate(latitude: 47.4979, longitude: 19.0402), zone: "Europe/Budapest"),
        .init(name: "Split", coordinate: GeoCoordinate(latitude: 43.5081, longitude: 16.4402), zone: "Europe/Zagreb"),
        .init(name: "Istanbul", coordinate: GeoCoordinate(latitude: 41.0082, longitude: 28.9784), zone: "Europe/Istanbul"),
        .init(name: "Hamburg", coordinate: GeoCoordinate(latitude: 53.5511, longitude: 9.9937), zone: "Europe/Berlin"),
    ]

    var assets: [AssetSnapshot]
    var total: Int { assets.count }
    var screenshots: Int
    var located: Int
    var trips: Int

    init(scale: Double) {
        func scaled(_ n: Int) -> Int { max(1, Int((Double(n) * scale).rounded())) }
        let trips = scaled(103), perTrip = 12
        let screenshots = scaled(1_040)
        let homeLocated = scaled(1_600) - trips * perTrip
        let home = scaled(5_683) - screenshots - trips * perTrip
        let start = Fixture.date("2023-05-01"), days = 1_290
        var lib = LibraryBuilder()
        // Trips: 2–3 days every ~12 days, 12 photos spread over towns around the destination.
        var tripDays = Set<Int>()
        for i in 0..<trips {
            let first = 5 + i * (days - 10) / trips
            let length = 2 + i % 2
            let destination = Self.destinations[(i * 7) % Self.destinations.count]
            for p in 0..<perTrip {
                let day = first + p * length / perTrip
                tripDays.insert(day)
                let date = start.addingTimeInterval(Double(day) * 86_400 + 9 * 3_600 + Double(p) * 1_500)
                _ = lib.photo(at: date, destination.coordinate, jitterMeters: 8_000)
            }
        }
        // Everyday life at home: every ninth-ish photo has a location.
        let homeDays = (0..<days).filter { !tripDays.contains($0) }
        for i in 0..<home {
            let day = homeDays[i * homeDays.count / home]
            let date = start.addingTimeInterval(Double(day) * 86_400 + 12 * 3_600 + Double(i % 7) * 1_800)
            let located = homeLocated > 0 && i % max(1, home / homeLocated) == 0
            _ = lib.photo(at: date, located ? Fixture.Places.munichHome : nil, jitterMeters: 3_000)
        }
        for i in 0..<screenshots {
            let date = start.addingTimeInterval(Double(i * days / screenshots) * 86_400 + 20 * 3_600)
            _ = lib.photo(at: date, nil, subtypes: .screenshot)
        }
        // Some saved pictures carry no date at all (the image analysis takes them last).
        var assets = lib.assets
        for i in stride(from: 7, to: assets.count, by: 200) where assets[i].location == nil && !assets[i].isScreenshotLike {
            assets[i].creationDate = nil
        }
        self.assets = assets
        self.screenshots = screenshots
        self.located = lib.assets.filter { $0.usableLocation != nil }.count
        self.trips = trips
    }
}

// MARK: - Recording

struct SimEvent: Sendable {
    enum Kind: Sendable {
        case progress(PipelineProgress)
        case waiting(PauseReason?)
        case pauseRequested
        case work(Stage)
        /// iOS held the app (background without the continued task): the clock jumps, nothing
        /// is reported meanwhile.
        case suspended(Duration)
    }
    var t: Duration
    var wall: ContinuousClock.Instant
    var kind: Kind
}

final class RunLog: @unchecked Sendable {
    let label: String
    let events = Mutex<[SimEvent]>([])
    var start: Duration = .zero
    var end: Duration = .zero
    var report: AnalysisPipeline.Report?
    var error: (any Error)?

    init(label: String) { self.label = label }

    func add(_ kind: SimEvent.Kind, at t: Duration) {
        events.withLock { $0.append(SimEvent(t: t, wall: .now, kind: kind)) }
    }

    var timeline: [SimEvent] { events.withLock { $0 } }
    var progress: [PipelineProgress] {
        timeline.compactMap { if case .progress(let p) = $0.kind { p } else { nil } }
    }
    var waits: [PauseReason?] {
        timeline.compactMap { if case .waiting(let w) = $0.kind { .some(w) } else { nil } }
    }
    var stagesShown: [Stage] {
        progress.reduce(into: [Stage]()) { if $0.last != $1.stage { $0.append($1.stage) } }
    }
    var lastStage: Stage? { progress.last?.stage }
    func first(_ stage: Stage) -> PipelineProgress? { progress.first { $0.stage == stage } }
    func last(_ stage: Stage) -> PipelineProgress? { progress.last { $0.stage == stage } }
    var pauseTime: Duration? {
        timeline.first { if case .pauseRequested = $0.kind { true } else { false } }?.t
    }
}

/// The analysis card's bar as AppModel computes it (`receive`, `overall`, `shownOverall`,
/// `AnalysisMarker`): late or lower updates are dropped, and a run that goes on shows at
/// least where the interrupted one got to while it catches up.
struct DisplayModel {
    var stage: Stage?
    var completed = 0
    var total = 0
    var marker: (stage: Int, overall: Double)?
    var resumeFrom: (stage: Int, overall: Double)?

    var overall: Double { stage.map { PipelineProgress.overall(stage: $0, completed: completed, total: total) } ?? 0 }
    var isCatchingUp: Bool {
        guard let resumeFrom else { return false }
        return (stage?.number ?? 0) < resumeFrom.stage
    }
    var shown: Double { isCatchingUp ? max(overall, resumeFrom?.overall ?? 0) : overall }

    mutating func start() {
        stage = nil
        completed = 0
        total = 0
        resumeFrom = marker
    }

    mutating func receive(_ progress: PipelineProgress) {
        if let stage {
            if progress.stage.number < stage.number { return }
            if progress.stage == stage, progress.completed < completed { return }
        }
        stage = progress.stage
        completed = progress.completed
        total = progress.total
        if !isCatchingUp { marker = (progress.stage.number, overall) }
    }

    mutating func end(complete: Bool) {
        if complete { marker = nil }
        resumeFrom = nil
        stage = nil
    }
}

// MARK: - Harness

enum PauseTrigger: Sendable {
    case when(stage: Stage, atLeast: Double)
    case whenGeocoderRefusedFor(Duration)
}

enum PauseAction: Sendable { case pause, cancel }

final class Sim: @unchecked Sendable {
    let clock = SimClock()
    let library: SimLibrary
    let store: SortlyStore
    let reader: InMemoryLibraryReader
    let analyzer: SimAnalyzer
    let geocoder: SimGeocoder
    let conditions: SimConditions
    private(set) var pipeline: AnalysisPipeline!
    var runs: [RunLog] = []
    /// The run before, of the same analysis (cleared by "Analyse neu aufbauen").
    private var previous: [RunLog] = []
    private var display = DisplayModel()
    /// The bar's value last shown in this analysis (pause and resume included).
    private var lastShown: Double = 0
    /// The card's bar as the app draws it: six steps with widths fixed for the whole analysis
    /// (from the first workload said, kept over Pause and a restart: S6), gliding between reports.
    private var widths: StepWidths?
    private var lastShownBar: Double = 0
    /// The highest real value of this analysis (the app's `shownOverall` with `resumeFrom`).
    private var lastRealBar: Double = 0
    /// Every finish time the card showed: (simulated time, what it said, the run's real end).
    var finishTimes: [(run: String, t: Duration, shown: FinishEstimate, end: Duration, complete: Bool)] = []
    var violations: [String] = []
    var onProgress: (@Sendable (PipelineProgress, Duration) -> Void)?
    private let current = Mutex<RunLog?>(nil)
    var currentLog: RunLog? { current.withLock { $0 } }
    /// The Pause (or the end of the app) planned for the run in progress. Data, not closures:
    /// a closure kept in a Mutex and called on every tick slowed the simulation down many times.
    private struct Armed: @unchecked Sendable {
        var trigger: PauseTrigger
        var action: PauseAction
        var control: AnalysisRunControl
        var task: Task<AnalysisPipeline.Report, any Error>?
    }
    private let armed = Mutex<Armed?>(nil)
    private let wallStart = ContinuousClock.now

    init(scale: Double = FullRunDisplayTests.scale, empty: Bool = false) throws {
        library = SimLibrary(scale: scale)
        store = try SortlyStore(url: nil)
        reader = InMemoryLibraryReader(assets: empty ? [] : library.assets)
        analyzer = SimAnalyzer(clock: clock)
        geocoder = SimGeocoder(clock: clock, map: FullRunDisplayTests.map)
        conditions = SimConditions(clock: clock)
        let clock = self.clock
        let work: @Sendable (Stage) -> Void = { [weak self] stage in self?.current.withLock { $0 }?.add(.work(stage), at: clock.now) }
        analyzer.onCall = work
        geocoder.onCall = work
        clock.onTick { [weak self] t in self?.fire(t, nil) }
        restartPipeline()
    }

    /// A new pipeline on the same store (the app was ended and opened again).
    func restartPipeline() {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let clock = self.clock
        // As in AppModel.bootstrap: online budget 60, 4 lanes for images, 2 for texts, batches of 50.
        pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: FullRunDisplayTests.map,
            conditions: conditions, settings: settings, calendar: Fixture.calendar, time: clock.source,
            foregroundOnlineBudget: 60, contentLanes: 4, textLanes: 2, now: { clock.date }
        )
    }

    /// "Analyse neu aufbauen": the next run is a full one again (AnalysisMarker.reset()).
    func newAnalysis() {
        previous = []
        display = DisplayModel()
        lastShown = 0
        widths = nil
        lastShownBar = 0
        lastRealBar = 0
    }

    private func fire(_ t: Duration, _ progress: PipelineProgress?) {
        guard let hit = armed.withLock({ armed -> Armed? in
            guard let current = armed else { return nil }
            let due: Bool
            switch current.trigger {
            case .when(let stage, let share):
                guard let p = progress, p.stage == stage, p.total > 0 else { return nil }
                due = Double(p.completed) >= share * Double(p.total)
            case .whenGeocoderRefusedFor(let wait):
                guard let refused = geocoder.refusals.withLock({ $0.first }) else { return nil }
                due = t >= refused + wait
            }
            guard due, current.action == .pause || current.task != nil else { return nil }
            armed = nil
            return current
        }) else { return }
        current.withLock { $0 }?.add(.pauseRequested, at: t)
        switch hit.action {
        case .pause: hit.control.pause()
        case .cancel: hit.task?.cancel()
        }
    }

    @discardableResult
    func run(_ label: String, pause: PauseTrigger? = nil, action: PauseAction = .pause) async -> RunLog {
        let log = RunLog(label: label)
        current.withLock { $0 = log }
        let control = AnalysisRunControl()
        let pipeline = self.pipeline!
        let clock = self.clock
        let onProgress = self.onProgress
        if let pause { armed.withLock { $0 = Armed(trigger: pause, action: action, control: control) } }
        log.start = clock.now
        let task = Task {
            try await pipeline.run(control: control, onProgress: { [weak self] progress in
                let t = clock.now
                log.add(.progress(progress), at: t)
                onProgress?(progress, t)
                self?.fire(t, progress)
            }, onWaiting: { reason in
                log.add(.waiting(reason), at: clock.now)
            })
        }
        armed.withLock { $0?.task = task }
        display.start()
        do {
            log.report = try await task.value
        } catch {
            log.error = error
        }
        log.end = clock.now
        armed.withLock { $0 = nil }
        current.withLock { $0 = nil }
        check(log)
        checkCard(log)
        runs.append(log)
        previous.append(log)
        display.end(complete: log.report?.isComplete == true)
        if log.report?.isComplete == true {
            lastShown = 0
            widths = nil
            lastShownBar = 0
            lastRealBar = 0
        }
        return log
    }

    func expectComplete(_ run: RunLog, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(run.report?.isComplete == true, "\(run.label): \(String(describing: run.report?.pausedBecause)) \(String(describing: run.error))", sourceLocation: sourceLocation)
    }

    /// Fails the test with every violation found in all runs, and prints the run times.
    func finish(sourceLocation: SourceLocation = #_sourceLocation) {
        for run in runs {
            let wall = run.timeline.last.map { ($0.wall - wallStart).seconds } ?? 0
            let starts = run.timeline.reduce(into: [(Stage, ContinuousClock.Instant)]()) { acc, e in
                if case .progress(let p) = e.kind, acc.last?.0 != p.stage { acc.append((p.stage, e.wall)) }
            }
            let perStage = zip(starts, starts.dropFirst()).map { "\($0.0) \(String(format: "%.2f", ($1.1 - $0.1).seconds))" }
            let tl = run.timeline
            let worst = zip(tl, tl.dropFirst()).max { ($0.1.wall - $0.0.wall) < ($1.1.wall - $1.0.wall) }
            if let worst { print("SIM \(run.label) longest wall gap \(String(format: "%.3f", (worst.1.wall - worst.0.wall).seconds)) s: \(describe(worst.0.kind)) → \(describe(worst.1.kind)) at t=\(worst.0.t.seconds)") }
            print("SIM \(run.label) wall per stage: \(perStage.joined(separator: ", "))")
            print("SIM \(run.label): \(String(format: "%.0f", (run.end - run.start).seconds)) s simulated, \(run.progress.count) progress events, ended \(run.report?.isComplete == true ? "complete" : String(describing: run.report?.pausedBecause)) (wall \(String(format: "%.2f", wall)) s)")
        }
        let longestCPU = runs.flatMap { run in
            zip(run.timeline, run.timeline.dropFirst()).compactMap { a, b -> (Double, String)? in
                guard a.t == b.t else { return nil }
                return ((b.wall - a.wall).seconds, "\(run.label) \(describe(a.kind)) → \(describe(b.kind))")
            }
        }.max { $0.0 < $1.0 }
        if let longestCPU { print("SIM longest stretch without simulated time (CPU on Linux): \(String(format: "%.3f", longestCPU.0)) s, \(longestCPU.1)") }
        // How far the finish times were off, for complete runs (minutes, by time left).
        for run in runs where run.report?.isComplete == true {
            let mine = finishTimes.filter { $0.run == run.label }
            let errors = mine.compactMap { entry -> (left: Double, off: Double)? in
                guard case .at(let date) = entry.shown else { return nil }
                let realEnd = SimClock.base.addingTimeInterval(entry.end.seconds)
                return ((entry.end - entry.t).seconds, date.timeIntervalSince(realEnd))
            }
            if let worst = errors.max(by: { abs($0.off) < abs($1.off) }) {
                print("SIM \(run.label) finish times: \(errors.count) shown, worst \(Int(worst.off)) s off with \(Int(worst.left)) s left, first with \(Int(errors.first!.left)) s left")
            }
        }
        #expect(violations.isEmpty, Comment(rawValue: "\(violations.count) display violations:\n" + violations.prefix(40).joined(separator: "\n")), sourceLocation: sourceLocation)
    }

    private func describe(_ kind: SimEvent.Kind) -> String {
        switch kind {
        case .progress(let p): "\(p.stage) \(p.completed)/\(p.total)\(p.waitLeft.map { " waiting \(Int($0.seconds)) s" } ?? "")"
        case .waiting(let w): "waiting \(w.map(\.rawValue) ?? "over")"
        case .pauseRequested: "Pause"
        case .work(let s): "work \(s)"
        case .suspended(let d): "suspended \(Int(d.seconds)) s"
        }
    }

    private func fail(_ run: RunLog, _ invariant: Int, _ text: String, at t: Duration) {
        violations.append("[\(run.label)] invariant \(invariant) at t=\(String(format: "%.1f", t.seconds)) s: \(text)")
    }

    // MARK: Invariants

    private func check(_ run: RunLog) {
        let timeline = run.timeline
        let maxGap: Duration = .seconds(2)

        // 7. Ends complete or with a reason, never silently.
        if run.report == nil {
            fail(run, 7, "the run ended with an error instead of a reason: \(String(describing: run.error))", at: run.end)
        } else if run.report?.isComplete != true, run.report?.pausedBecause == nil {
            fail(run, 7, "the run ended neither complete nor with a reason (stages \(run.report!.completedStages))", at: run.end)
        }

        // 1. Stage order, and each stage says it begins before its work.
        var announced = Set<Stage>()
        var stageNow: Stage?
        for event in timeline {
            switch event.kind {
            case .progress(let p):
                if let stageNow, p.stage.number < stageNow.number {
                    fail(run, 1, "stage \(p.stage) shown after \(stageNow)", at: event.t)
                }
                if !announced.contains(p.stage), p.total > 0, p.completed >= p.total, [.patterns, .groups].contains(p.stage) {
                    fail(run, 1, "\(p.stage) first shown when done (\(p.completed)/\(p.total)): its work ran under the stage before", at: event.t)
                }
                announced.insert(p.stage)
                stageNow = p.stage
            case .work(let stage):
                if !announced.contains(stage) {
                    fail(run, 1, "\(stage) works before it says that it begins (card shows \(stageNow.map { "\($0)" } ?? "nothing"))", at: event.t)
                    announced.insert(stage)
                }
            default: break
            }
        }
        if run.report?.isComplete == true {
            let hasPlaces = run.first(.places) != nil || timeline.contains { if case .work(.places) = $0.kind { true } else { false } }
            let expected = Stage.allCases.filter { $0 != .places || hasPlaces }
            if run.stagesShown != expected { fail(run, 1, "complete run showed stages \(run.stagesShown)", at: run.end) }
        }

        // 2. Counts within a stage; and against where the run before ended.
        var lastOf: [Stage: PipelineProgress] = [:]
        var rawOverall = 0.0
        for event in timeline {
            guard case .progress(let p) = event.kind else { continue }
            if p.completed > p.total { fail(run, 2, "\(p.stage) \(p.completed) von \(p.total): above the total", at: event.t) }
            if let last = lastOf[p.stage] {
                if p.completed < last.completed { fail(run, 2, "\(p.stage) went back from \(last.completed) to \(p.completed) (von \(p.total))", at: event.t) }
                if p.total != last.total, last.total != 0 { fail(run, 2, "\(p.stage) total changed from \(last.total) to \(p.total)", at: event.t) }
            } else if [.places, .content, .text].contains(p.stage),
                      let before = previous.last(where: { $0.last(p.stage) != nil })?.last(p.stage), before.total == p.total, p.completed < before.completed {
                // Counts that persist across runs (the other steps are computed anew each run).
                fail(run, 2, "\(p.stage) starts at \(p.completed) von \(p.total), below where the run before ended (\(before.completed))", at: event.t)
            }
            lastOf[p.stage] = p
            // 3. The bar: never back within a run, nor below the paused run's while going on.
            let overall = PipelineProgress.overall(stage: p.stage, completed: p.completed, total: p.total)
            if overall + 1e-9 < rawOverall {
                fail(run, 3, "overall went back from \(pct(rawOverall)) to \(pct(overall)) at \(p.stage) \(p.completed)/\(p.total)", at: event.t)
            }
            rawOverall = max(rawOverall, overall)
            display.receive(p)
            if display.shown + 1e-9 < lastShown {
                fail(run, 3, "bar shows \(pct(display.shown)) after \(pct(lastShown)) (\(p.stage) \(p.completed)/\(p.total))", at: event.t)
            }
            lastShown = max(lastShown, display.shown)
        }

        // 4. No silent stretch while working; 5. no "N von N" while the stage still works.
        let pause = run.pauseTime
        let points: [(t: Duration, kind: SimEvent.Kind?)] = [(run.start, nil)]
            + timeline.filter { if case .work = $0.kind { false } else { true } }.map { ($0.t, $0.kind) }
            + [(run.end, nil)]
        var waiting = false
        var waitedWhileFull = false
        var shown: PipelineProgress?
        var fullSince: Duration?
        func leaveFull(at t: Duration) {
            defer { fullSince = nil; waitedWhileFull = false }
            guard let since = fullSince, let shown, !waitedWhileFull else { return }
            let until = min(t, pause ?? t)
            if until - since > maxGap {
                fail(run, 5, "\(shown.stage) stood at \(shown.completed) von \(shown.total) for \(String(format: "%.1f", (until - since).seconds)) s while the run went on", at: since)
            }
        }
        for (index, point) in points.enumerated() {
            if index > 0 {
                let before = points[index - 1]
                let afterPause = pause.map { before.t >= $0 } ?? false
                let suspended = if case .suspended? = before.kind { true } else { false }
                if point.t - before.t > maxGap, !waiting, !afterPause, !suspended {
                    fail(run, 4, "\(String(format: "%.1f", (point.t - before.t).seconds)) s without a progress event, card shows \(shown.map { "\($0.stage) \($0.completed)/\($0.total)" } ?? "nothing")", at: before.t)
                }
            }
            switch point.kind {
            case .progress(let p)?:
                if p.stage != shown?.stage { leaveFull(at: point.t) }
                shown = p
                if p.total > 0, p.completed >= p.total {
                    fullSince = fullSince ?? point.t
                } else {
                    fullSince = nil
                }
            case .waiting(let w)?:
                waiting = w != nil
                if waiting { waitedWhileFull = true }
            case nil where index > 0:
                // The run ended: the last suggestions count stands, that is the result.
                if shown?.stage != .proposals { leaveFull(at: point.t) }
            default:
                break
            }
        }

        // 6. Pause ends the run within one item plus 2 s.
        if let pause {
            let stage = timeline.last { if case .progress = $0.kind { $0.t <= pause } else { false } }.flatMap { e -> Stage? in
                if case .progress(let p) = e.kind { p.stage } else { nil }
            }
            let limit = SimCost.item(stage) + maxGap
            if run.end - pause > limit {
                fail(run, 6, "Pause in \(stage.map { "\($0)" } ?? "?") took \(String(format: "%.1f", (run.end - pause).seconds)) s (limit \(String(format: "%.1f", limit.seconds)) s)", at: pause)
            }
        }
    }

    private func pct(_ x: Double) -> String { String(format: "%.2f %%", x * 100) }

    /// The card as the app computes it on its 250 ms tick (AppModel.tick): the six-step bar with
    /// the widths of this analysis, the gliding bar, the finish time (`ProgressEstimator`).
    /// 3b. The drawn bar never goes back, also over Pause and restarts; never more than 1 % of a
    ///     step ahead of the real value.
    /// 8.  While the run works, something on the card changes at least every 10 s: the count,
    ///     Apple's wait, or the gliding bar (limit set by the product owner, 15.11.).
    /// 9.  No finish time while the run waits or after Pause; "Gleich fertig" only in the last
    ///     3 minutes (checked against the real end in `finish`).
    private func checkCard(_ run: RunLog) {
        let base = ContinuousClock.now
        func instant(_ t: Duration) -> ContinuousClock.Instant { base.advanced(by: t) }
        func wall(_ t: Duration) -> Date { SimClock.base.addingTimeInterval(t.seconds) }
        var estimator = ProgressEstimator()
        var glide = BarGlide()
        var step: AnalysisStep?
        var waiting = false
        var paused = false
        var lastChange: Duration = run.start
        var lastSeen: (step: AnalysisStep, completed: Int, wait: Int?)?
        var lastBar = 0.0
        var shown: [(Duration, FinishEstimate)] = []
        var suspendedUntil: Duration?
        for event in run.timeline {
            switch event.kind {
            case .progress(let p):
                let s = AnalysisStep(p.stage)
                if let workload = p.workload {
                    estimator.setWorkload(workload)
                    if widths == nil { widths = StepWidths(workload: workload) }
                }
                let w = widths ?? .standard
                if let step, s < step { continue }
                step = s
                if !paused { estimator.record(step: s, completed: p.completed, total: p.total, at: instant(event.t), appleWait: p.waitLeft != nil) }
                // As AppModel: the real value is never below where the analysis got to.
                let real = max(w.overall(step: s, completed: p.completed, total: p.total), lastRealBar)
                lastRealBar = real
                glide.update(real: real, at: instant(event.t), step: s, widths: w, itemsPerSecond: estimator.rate, total: p.total)
                let bar = glide.value(at: instant(event.t), gliding: !waiting && !paused)
                if bar + 1e-9 < lastShownBar {
                    fail(run, 3, "drawn bar went back from \(pct(lastShownBar)) to \(pct(bar)) at \(p.stage) \(p.completed)/\(p.total)", at: event.t)
                }
                if bar > glide.real + BarGlide.maxLead * w.width(of: s) + 1e-9 {
                    fail(run, 3, "drawn bar \(pct(bar)) more than 1 % of the step ahead of \(pct(glide.real))", at: event.t)
                }
                lastShownBar = max(lastShownBar, bar)
                let seen = (s, p.completed, p.waitLeft.map { Int($0.seconds) })
                let moved = lastSeen.map { $0.step != seen.0 || $0.completed != seen.1 || $0.wait != seen.2 } ?? true
                if moved || bar > lastBar + 1e-6 || waiting || paused {
                    if !waiting, !paused, event.t - lastChange > .seconds(10) {
                        fail(run, 8, "card stood still for \(String(format: "%.1f", (event.t - lastChange).seconds)) s while the run worked (\(p.stage) \(p.completed)/\(p.total))", at: lastChange)
                    }
                    lastChange = event.t
                }
                lastSeen = seen
                lastBar = bar
                if let finish = estimator.finish(at: instant(event.t), wall: wall(event.t)) {
                    if waiting || paused { fail(run, 9, "finish time shown while \(waiting ? "waiting" : "paused")", at: event.t) }
                    if let until = suspendedUntil, event.t - until < .seconds(30) {
                        fail(run, 9, "finish time shown \(Int((event.t - until).seconds)) s after the app came back from the background (settles 30 s first)", at: event.t)
                    }
                    shown.append((event.t, finish))
                }
            case .waiting(let reason):
                waiting = reason != nil
                if waiting { estimator.idle() }
                lastChange = event.t
            case .pauseRequested:
                paused = true
                estimator.idle()
            case .suspended(let d):
                // Nothing on screen meanwhile; the estimator sees only the gap (S4).
                lastChange = event.t + d
                suspendedUntil = event.t + d
            case .work:
                break
            }
        }
        finishTimes += shown.map { (run.label, $0.0, $0.1, run.end, run.report?.isComplete == true) }
        guard run.report?.isComplete == true else { return }
        for (t, finish) in shown where finish == .soon && run.end - t > .seconds(180) {
            fail(run, 9, "\"Gleich fertig\" \(Int((run.end - t).seconds)) s before the end", at: t)
        }
    }
}
