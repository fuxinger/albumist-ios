import Foundation
import Synchronization
import SortlyCore

// What the analysis card shows, as pure values (progress display, spec v3 with the five points
// chosen on 15.11.). The app only renders these; every rule here is tested on Linux
// (AnalysisDisplayTests, FullRunDisplayTests).

// MARK: Steps

/// The six steps the card shows (spec M2). The pipeline's `groups` stage belongs to the last
/// step: grouping people and pets comes with version 1.1.
public enum AnalysisStep: Int, CaseIterable, Sendable, Codable, Comparable {
    case library, trips, places, content, text, proposals

    public init(_ stage: AnalysisPipeline.Stage) {
        switch stage {
        case .inventory: self = .library
        case .patterns: self = .trips
        case .places: self = .places
        case .content: self = .content
        case .text: self = .text
        case .groups, .proposals: self = .proposals
        }
    }

    /// 1-based, for "Schritt 4 von 6".
    public var number: Int { rawValue + 1 }
    public static var count: Int { allCases.count }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// What the step counts.
    public enum Unit: Sendable { case photos, places, screenshots, none }

    public var unit: Unit {
        switch self {
        case .library, .content: .photos
        case .places: .places
        case .text: .screenshots
        case .trips, .proposals: .none
        }
    }

    /// Usual device time per item and per step, on an iPhone of the owner's kind (the same
    /// values the simulated full run uses: 4 lanes à 0.4 s per photo, 2 lanes à 1 s per text,
    /// town names limited by Apple). Used for the widths of the bar and, scaled by how fast
    /// this device really is, for the steps that have not started yet.
    public var secondsPerItem: Double {
        switch self {
        case .library: 0.003
        case .trips: 0.001
        case .places: 0.06
        case .content: 0.1
        case .text: 0.5
        case .proposals: 0.002
        }
    }

    public var fixedSeconds: Double {
        switch self {
        case .library: 2
        case .trips: 1
        case .places: 0
        case .content: 0
        case .text: 0
        case .proposals: 3
        }
    }

    /// Steps whose speed depends on the device (not on Apple's geocoder or on fixed costs):
    /// they tell how fast this iPhone is compared with the usual times.
    var measuresDevice: Bool { self == .content || self == .text }
}

/// How much work a run has, known right after the library was read and the trips were found
/// (said once with the end of the trips step).
public struct AnalysisWorkload: Sendable, Hashable, Codable {
    /// Photos in the part of the library the run works on.
    public var photos: Int
    /// Photos with a location (the places step counts these).
    public var located: Int
    /// Screenshots and screen recordings (the text step reads these).
    public var screenshots: Int
    /// Photos whose image contents are still to be looked at.
    public var contentLeft: Int
    /// Screenshots whose text is still to be read.
    public var textLeft: Int

    public init(photos: Int, located: Int, screenshots: Int, contentLeft: Int, textLeft: Int) {
        self.photos = photos
        self.located = located
        self.screenshots = screenshots
        self.contentLeft = contentLeft
        self.textLeft = textLeft
    }

    /// All items of a step (for the widths: the counts are over the whole library too).
    public func items(_ step: AnalysisStep) -> Int {
        switch step {
        case .library, .trips, .proposals, .content: photos
        case .places: located
        case .text: screenshots
        }
    }

    /// Items still to do in a step that has not started yet (for the finish time).
    public func itemsLeft(_ step: AnalysisStep) -> Int {
        switch step {
        case .library, .trips, .proposals: photos
        case .places: located
        case .content: contentLeft
        case .text: textLeft
        }
    }
}

// MARK: Widths of the bar

/// The share of the bar each step gets: its usual time with this library's amounts, fixed
/// for the whole analysis (stored with the marker, so a restart keeps them: S6). Without
/// amounts the fixed 5, 3, 12, 60, 12, 8 %.
public struct StepWidths: Sendable, Hashable, Codable {
    public private(set) var shares: [Double]

    public static let standard = StepWidths(validShares: [0.05, 0.03, 0.12, 0.60, 0.12, 0.08])
    /// Every step stays visible as a segment of its own.
    public static let minimumShare = 0.02

    private init(validShares: [Double]) { shares = validShares }

    /// From stored shares; anything that does not fit six positive shares gives the standard.
    public init(shares: [Double]) {
        guard shares.count == AnalysisStep.count, shares.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            self = .standard
            return
        }
        let sum = shares.reduce(0, +)
        self.shares = shares.map { $0 / sum }
    }

    public init(workload: AnalysisWorkload) {
        let seconds = AnalysisStep.allCases.map { step in
            Double(workload.items(step)) * step.secondsPerItem + step.fixedSeconds
        }
        let total = seconds.reduce(0, +)
        guard total > 0 else {
            self = .standard
            return
        }
        // Raised to the minimum, the rest scaled down so the sum stays 1.
        var shares = seconds.map { $0 / total }
        let small = shares.indices.filter { shares[$0] < Self.minimumShare }
        let raised = Double(small.count) * Self.minimumShare
        let restSum = shares.indices.filter { !small.contains($0) }.map { shares[$0] }.reduce(0, +)
        for i in shares.indices {
            shares[i] = small.contains(i) ? Self.minimumShare : shares[i] / restSum * (1 - raised)
        }
        self.init(shares: shares)
    }

    public func width(of step: AnalysisStep) -> Double { shares[step.rawValue] }
    public func start(of step: AnalysisStep) -> Double { shares.prefix(step.rawValue).reduce(0, +) }
    public func end(of step: AnalysisStep) -> Double { start(of: step) + width(of: step) }

    /// The bar for the whole analysis (0…1): never from the start again when a step begins.
    public func overall(step: AnalysisStep, completed: Int, total: Int) -> Double {
        let within = total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0
        return min(1, start(of: step) + width(of: step) * within)
    }

    /// How far each segment is filled for a value of the bar (0…1 per step).
    public func fills(for overall: Double) -> [Double] {
        AnalysisStep.allCases.map { step in
            let w = width(of: step)
            return w > 0 ? min(1, max(0, (overall - start(of: step)) / w)) : 0
        }
    }
}

// MARK: Finish time

/// What the card says about the end: a clock time, or "Gleich fertig".
public enum FinishEstimate: Sendable, Equatable {
    case soon
    case at(Date)

    /// How the date is said: today "Fertig gegen 23:40", tomorrow "Fertig morgen gegen 7:10",
    /// later in the week with the weekday, beyond that with the date.
    public enum Day: Sendable, Equatable { case today, tomorrow, weekday, date }

    public static func day(of date: Date, now: Date, calendar: Calendar) -> Day {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .tomorrow
        case 2...6: return .weekday
        default: return .date
        }
    }
}

/// Measures the speed of the analysis and says when it will be done (point 1).
///
/// - The running step: items per second of active time in its last 60 s.
/// - Steps not started yet: their items times the usual time per item, scaled by how fast this
///   device was on the image and text steps measured so far (factor 1 before either was).
/// - Trustworthy only after 30 s and 20 items in the running step; after any time without
///   progress (waiting, Pause, background without the task, a gap of more than 5 s) it settles
///   again from there, and no time is shown meanwhile.
/// - Checked at most every 15 s; a shown time moves only when the new one differs by 2 min or
///   more. More than 30 min ahead it is rounded to 5 min, else to the minute; less than a
///   minute ahead it says "Gleich fertig".
///
/// Times are `ContinuousClock` instants handed in by the caller (tests pass their own), the
/// finish is a wall-clock `Date` handed in with them.
public struct ProgressEstimator: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public struct Rules: Sendable {
        public var minActive: Duration = .seconds(30)
        public var minItems = 20
        public var window: Duration = .seconds(60)
        public var maxGap: Duration = .seconds(5)
        public var refresh: Duration = .seconds(15)
        public var hysteresis: TimeInterval = 120
        public var roundAbove: TimeInterval = 30 * 60
        public var roundTo: TimeInterval = 5 * 60
        public var soon: TimeInterval = 60
        public init() {}
    }

    struct Sample: Sendable {
        var active: Duration
        var completed: Int
    }

    struct Running: Sendable {
        var step: AnalysisStep
        var completed: Int
        var total: Int
        /// When the last progress came; `nil` after a time without progress (settles again).
        var lastAt: Instant?
        var active: Duration = .zero
        var samples: [Sample] = []
        /// Where the measuring (re)started: 30 s and 20 items from here make it trustworthy.
        var settledFrom = Sample(active: .zero, completed: 0)
        /// Everything measured in this step, for its average speed once it is done.
        var measuredItems = 0
        var measuredActive: Duration = .zero
        var waitingForApple = false
    }

    public let rules: Rules
    private(set) var running: Running?
    /// Measured steps: items and active seconds.
    private(set) var measured: [AnalysisStep: (items: Int, seconds: Double)] = [:]
    public private(set) var workload: AnalysisWorkload?
    /// The finish time last accepted (unrounded) and when it was last checked.
    private var accepted: Date?
    private var lastCheck: Instant?

    public init(rules: Rules = Rules()) { self.rules = rules }

    public mutating func setWorkload(_ workload: AnalysisWorkload) { self.workload = workload }

    /// A progress report of the run. `appleWait`: the report says the run waits for Apple's
    /// geocoder (`Progress.waitLeft`). That time says nothing about the speed per item (the
    /// limit is Apple's, and after its online budget the step resolves the rest offline in
    /// seconds): it is not measured, and the speed settles again afterwards, but a time already
    /// shown stays. Measured in the simulated run with a refusing geocoder: counted, the waits
    /// put the finish time more than 5 min too late.
    public mutating func record(step: AnalysisStep, completed: Int, total: Int, at now: Instant, appleWait: Bool = false) {
        guard var r = running, r.step == step else {
            if let r = running { keepMeasured(r) }
            running = Running(step: step, completed: completed, total: total, lastAt: now,
                              samples: [Sample(active: .zero, completed: completed)],
                              settledFrom: Sample(active: .zero, completed: completed))
            return
        }
        defer { running = r }
        let previous = r.completed
        r.completed = max(r.completed, completed)
        r.total = total
        if appleWait {
            r.waitingForApple = true
            return
        }
        if r.waitingForApple {
            r.waitingForApple = false
            r.lastAt = now
            r.samples = [Sample(active: r.active, completed: r.completed)]
            r.settledFrom = Sample(active: r.active, completed: r.completed)
            return
        }
        guard let last = r.lastAt else {
            settle(&r, at: now)
            return
        }
        let gap = now - last
        if gap > rules.maxGap || gap < .zero {
            // Nothing came for a while (suspended in the background, a long wait): that time
            // is not counted, and the speed is measured anew from here.
            settle(&r, at: now)
            return
        }
        r.lastAt = now
        r.active += gap
        r.measuredActive += gap
        r.measuredItems += max(0, r.completed - previous)
        r.samples.append(Sample(active: r.active, completed: r.completed))
        // Keeps one sample at or before the start of the window.
        let windowStart = r.active - rules.window
        if let firstInside = r.samples.firstIndex(where: { $0.active >= windowStart }), firstInside > 1 {
            r.samples.removeFirst(firstInside - 1)
        }
    }

    /// The run waits (heat, battery), is paused, or is in the background without iOS running
    /// it: no time is shown, and the measuring settles again when progress comes.
    public mutating func idle() {
        running?.lastAt = nil
        accepted = nil
        lastCheck = nil
    }

    /// Forgets everything (a new run).
    public mutating func reset() { self = ProgressEstimator(rules: rules) }

    private mutating func settle(_ r: inout Running, at now: Instant) {
        r.lastAt = now
        r.samples = [Sample(active: r.active, completed: r.completed)]
        r.settledFrom = Sample(active: r.active, completed: r.completed)
        accepted = nil
        lastCheck = nil
    }

    private mutating func keepMeasured(_ r: Running) {
        guard r.measuredItems > 0, r.measuredActive > .zero else { return }
        let before = measured[r.step] ?? (0, 0)
        measured[r.step] = (before.items + r.measuredItems, before.seconds + r.measuredActive.seconds)
    }

    /// Items per second of the running step, once trustworthy.
    public var rate: Double? {
        guard let r = running, r.lastAt != nil, !r.waitingForApple, r.total > 1 else { return nil }
        guard r.active - r.settledFrom.active >= rules.minActive,
              r.completed - r.settledFrom.completed >= rules.minItems,
              let first = r.samples.first, let last = r.samples.last else { return nil }
        let seconds = (last.active - first.active).seconds
        let items = last.completed - first.completed
        guard seconds > 0, items > 0 else { return nil }
        return Double(items) / seconds
    }

    /// How much slower (> 1) or faster (< 1) this device is than the usual times, from the
    /// image and text steps measured so far.
    public var deviceFactor: Double {
        var items: [AnalysisStep: (Int, Double)] = measured.mapValues { ($0.items, $0.seconds) }
        if let r = running, r.measuredItems >= rules.minItems, r.measuredActive >= rules.minActive {
            let before = items[r.step] ?? (0, 0)
            items[r.step] = (before.0 + r.measuredItems, before.1 + r.measuredActive.seconds)
        }
        var usual = 0.0, real = 0.0
        for (step, value) in items where step.measuresDevice {
            usual += Double(value.0) * step.secondsPerItem
            real += value.1
        }
        guard usual > 0, real > 0 else { return 1 }
        return min(4, max(0.25, real / usual))
    }

    /// Time left in the running step, once trustworthy (Details: "noch etwa 12 Min.").
    public var stepRemaining: Duration? {
        guard let r = running, let rate else { return nil }
        return .seconds(Double(max(0, r.total - r.completed)) / rate)
    }

    /// This device's speed is measured (an image or text step ran long enough), or no work
    /// is left whose time depends on it. Before that a whole-analysis time would rest on the
    /// usual times only, which are a guess for this device (review I4).
    public var deviceKnown: Bool {
        if measured.keys.contains(where: \.measuresDevice) { return true }
        if let r = running, r.step.measuresDevice, rate != nil { return true }
        guard let r = running, let workload else { return false }
        return !AnalysisStep.allCases.contains { $0 > r.step && $0.measuresDevice && workload.itemsLeft($0) > 0 }
    }

    /// Time left for the whole analysis, once trustworthy: the running step measured, and the
    /// device measured (`deviceKnown`).
    public var remaining: Duration? {
        guard let r = running, let step = stepRemaining, let workload, deviceKnown else { return nil }
        let factor = deviceFactor
        let later = AnalysisStep.allCases.filter { $0 > r.step }.reduce(0.0) { sum, s in
            sum + (Double(workload.itemsLeft(s)) * s.secondsPerItem + s.fixedSeconds) * (s.measuresDevice ? factor : 1)
        }
        return step + .seconds(later)
    }

    /// The finish time to show now, or `nil` while there is none to trust.
    public mutating func finish(at now: Instant, wall: Date) -> FinishEstimate? {
        guard let r = running, r.lastAt != nil else { return nil }
        // The time shown has passed and the run goes on: a new one at once, without waiting
        // for the refresh or the hysteresis (review minor: "Gleich fertig" stayed for up to
        // 2 min after the end time).
        let passed = accepted.map { $0 <= wall } ?? false
        // Steps without a count (trips, suggestions) are short: the time shown stays.
        if r.total > 1, passed || (lastCheck.map({ now - $0 >= rules.refresh }) ?? true) {
            if let remaining {
                lastCheck = now
                let candidate = wall.addingTimeInterval(remaining.seconds)
                if passed || (accepted.map({ abs(candidate.timeIntervalSince($0)) >= rules.hysteresis }) ?? true) {
                    accepted = candidate
                }
            }
        }
        guard let accepted else { return nil }
        // No new time to show: "Gleich fertig" for at most a minute past the time, then none.
        if wall.timeIntervalSince(accepted) > rules.soon { return nil }
        return Self.display(accepted, wall: wall, rules: rules)
    }

    /// The wall clock jumped (set by hand, another time zone does not count: a `Date` stays
    /// the same instant): it moved more than `tolerance` apart from the time that really
    /// passed. `significantTimeChangeNotification` also comes at midnight and when the
    /// carrier corrects the time by a little (re-review a); then the time shown stays.
    public static func clockJumped(wallThen: Date, wallNow: Date, elapsed: Duration,
                                   tolerance: TimeInterval = 60) -> Bool {
        abs(wallNow.timeIntervalSince(wallThen) - elapsed.seconds) > tolerance
    }

    static func display(_ finish: Date, wall: Date, rules: Rules) -> FinishEstimate {
        let left = finish.timeIntervalSince(wall)
        if left < rules.soon { return .soon }
        let step = left > rules.roundAbove ? rules.roundTo : 60
        let rounded = (finish.timeIntervalSinceReferenceDate / step).rounded() * step
        return .at(Date(timeIntervalSinceReferenceDate: rounded))
    }
}

fileprivate extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

// MARK: Gliding bar

/// The bar between two real reports (point 2): it moves on at the measured speed instead of
/// standing and jumping, but never goes back and never gets more than 1 % of the running step
/// ahead of the last real value (nor past the step's end). When the real value is ahead, the
/// value jumps to it and the view eases there.
public struct BarGlide: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant
    public static let maxLead = 0.01

    public private(set) var real = 0.0
    public private(set) var shown = 0.0
    private var realAt: Instant?
    /// Bar units per second.
    private var speed: Double?
    private var cap = 0.0

    public init() {}

    /// A real value. `itemsPerSecond`: the running step's measured speed (`nil`: not known,
    /// no gliding); `total`: its items.
    public mutating func update(real value: Double, at now: Instant, step: AnalysisStep, widths: StepWidths,
                                itemsPerSecond: Double?, total: Int) {
        real = max(real, value)
        realAt = now
        let width = widths.width(of: step)
        cap = min(real + Self.maxLead * width, widths.end(of: step))
        if let itemsPerSecond, total > 0 {
            speed = width * itemsPerSecond / Double(total)
        } else {
            speed = nil
        }
        shown = max(shown, real)
    }

    /// The value to draw now. `gliding` is off while the run waits or is paused, with
    /// Reduce Motion, and while the app is not active: then the real value only.
    public mutating func value(at now: Instant, gliding: Bool) -> Double {
        guard gliding, let speed, let realAt else {
            shown = max(shown, real)
            return shown
        }
        let elapsed = max(0, (now - realAt).seconds)
        shown = max(shown, min(real + speed * elapsed, cap))
        return shown
    }

    /// A new run, or new widths for the run (review I3: the glide held the bar at the old
    /// widths' value, so it stood still until the real value under the new widths caught up).
    public mutating func reset() { self = BarGlide() }

    /// A run that goes on with the same analysis: starts from the value drawn last, so the
    /// bar does not lose the lead it had glided (review minor: up to 1 % of a step back).
    public mutating func reset(keeping drawn: Double) {
        self = BarGlide()
        shown = drawn
    }
}

// MARK: Card state

/// The card's state (spec "SwiftUI": running, slower, waiting, pausing since, paused,
/// finished, quick check). `nil` from `resolve`: the plain card ("Alle 5.683 Fotos analysiert").
public enum AnalysisCardState: Sendable, Equatable {
    public enum Wait: Sendable, Equatable {
        /// "Wartet, bis dein iPhone abkühlt"
        case cooling
        /// "Wartet aufs Laden"
        case charging
    }

    public struct Position: Sendable, Equatable {
        public var step: AnalysisStep
        public var completed: Int
        public var total: Int
        public init(step: AnalysisStep, completed: Int, total: Int) {
            self.step = step
            self.completed = completed
            self.total = total
        }
        /// A count to show ("2.431 von 5.683 Fotos"); steps without one show only their name.
        public var hasCount: Bool { total > 1 && step.unit != .none }
    }

    case quickCheck(showsPause: Bool)
    /// `catchingUp`: a run that goes on from step n is still on the quick steps before it.
    case running(Position?, slower: SlowReason?, appleWait: Bool, catchingUp: Int?)
    case waiting(Wait, Position?)
    /// Pause was tapped; `longer` after 10 s ("Dauert noch einen Moment.").
    case pausing(Position?, longer: Bool)
    case paused(Position?)
    case finished(photos: Int, proposals: Int)

    public struct Inputs: Sendable {
        public var isRunning = false
        /// A check for new photos after everything was analysed once, with little to do.
        public var isQuickCheck = false
        public var runningFor: Duration = .zero
        public var position: Position?
        public var catchingUpTo: Int?
        public var waiting: PauseReason?
        public var slower: SlowReason?
        public var appleWait = false
        /// Pause was tapped this long ago (the run is finishing the photos in work).
        public var pausingFor: Duration?
        /// The last run ended because the user paused it, at this position.
        public var pausedByUser = false
        public var pausedAt: Position?
        /// A long run just finished while the app was open.
        public var finished: (photos: Int, proposals: Int)?
        public init() {}
    }

    public static let pauseShownAfter: Duration = .seconds(5)
    public static let pausingLongerAfter: Duration = .seconds(10)

    public static func resolve(_ i: Inputs) -> AnalysisCardState? {
        if i.isRunning {
            if let pausing = i.pausingFor {
                return .pausing(i.position, longer: pausing >= pausingLongerAfter)
            }
            if i.isQuickCheck { return .quickCheck(showsPause: i.runningFor >= pauseShownAfter) }
            switch i.waiting {
            case .thermal?: return .waiting(.cooling, i.position)
            case .batteryLow?: return .waiting(.charging, i.position)
            default: break
            }
            return .running(i.position, slower: i.slower, appleWait: i.appleWait, catchingUp: i.catchingUpTo)
        }
        if i.pausedByUser { return .paused(i.pausedAt) }
        if let finished = i.finished { return .finished(photos: finished.photos, proposals: finished.proposals) }
        return nil
    }

    /// The finish moment (point 4: check mark, light haptic, "Analyse fertig" card, or the
    /// notification when the app is not open): only for a run that really finished (not paused,
    /// stopped, failed or cut off by Vision errors), was not a quick check, and ran long enough
    /// that someone waited for it.
    public static let finishMomentAfter: Duration = .seconds(30)

    public static func celebratesFinish(isComplete: Bool, wasQuickCheck: Bool, ranFor: Duration) -> Bool {
        isComplete && !wasQuickCheck && ranFor >= finishMomentAfter
    }

    /// Fill in accent, or grey only while paused (M5).
    public var isGrey: Bool { if case .paused = self { true } else { false } }
    /// Motion (the light sweep, the gliding bar) only while really working (rule 4); not
    /// while Apple's geocoder is waited for (review minor: the sweep ran during that wait).
    public var isWorking: Bool { if case .running(_, _, let appleWait, _) = self { !appleWait } else { false } }
}

// MARK: Photo mosaic

/// The photo mosaic with the trips found ("Erster Scan als Show", `ScanShow`) above the
/// progress card. Fuchs decided on 16.11.: only during the first analysis; later analyses show
/// only the calm card. One switch turns it off for the first analysis too.
public enum ScanShowRule {
    /// The switch: `false` shows the mosaic never.
    public static let onFirstAnalysis = true

    /// `firstAnalysis`: no analysis was completed yet (also when the first one goes on after a
    /// pause or a restart). `AnalysisMarker.reset()` ("Analyse neu aufbauen", another part of
    /// the library) clears that, so the next full analysis counts as a first one again.
    public static func shows(isRunning: Bool, firstAnalysis: Bool, isQuickCheck: Bool,
                             enabled: Bool = onFirstAnalysis) -> Bool {
        enabled && isRunning && firstAnalysis && !isQuickCheck
    }

    /// The mosaic's light sweep moves only while the analysis really works (rule 4, S1): not
    /// while it waits (heat, battery), is pausing or paused, not while Apple's geocoder is
    /// waited for, not off screen, and not from serious heat up (re-review N1: it ran at
    /// 10 Hz the whole run, also while the iPhone cooled down).
    public static func animates(card: AnalysisCardState?, isOnScreen: Bool, thermal: DeviceState.Thermal,
                                reduceMotion: Bool) -> Bool {
        (card?.isWorking ?? false) && isOnScreen && thermal < .serious && !reduceMotion
    }
}

// MARK: Already done

/// "Schon fertig: 51 Reisen, 38 Orte" (point 3): suggestions of the steps that are done, while
/// the analysis goes on. Trips and places are known after the places step; before, nothing.
public struct AlreadyDone: Sendable, Equatable {
    public var trips = 0
    public var places = 0
    public var isEmpty: Bool { trips == 0 && places == 0 }

    public init(trips: Int = 0, places: Int = 0) {
        self.trips = trips
        self.places = places
    }

    /// `step`: the running step; trips and places count from the image step on.
    public static func counts(proposals: [AlbumProposal], step: AnalysisStep?) -> AlreadyDone {
        guard let step, step >= .content else { return AlreadyDone() }
        var done = AlreadyDone()
        for proposal in proposals {
            switch proposal.kind {
            case .trip: done.trips += 1
            case .placeCollection, .frequentPlace: done.places += 1
            default: break
            }
        }
        return done
    }
}

// MARK: Throttled progress

/// Progress from the pipeline, kept here without a hop to the main actor for every report
/// (S2): the app takes the newest value once per tick (250 ms). The workload, said once, and
/// the photos just looked at are kept until taken.
public final class ProgressMailbox: Sendable {
    public struct Taken: Sendable {
        public var progress: AnalysisPipeline.Progress?
        public var workload: AnalysisWorkload?
        public var recent: [AssetID]
        /// The early suggestions were saved (kept until taken, like the workload).
        public var earlyProposals = false
    }

    private let state = Mutex(Taken(progress: nil, workload: nil, recent: []))

    public init() {}

    public func post(_ progress: AnalysisPipeline.Progress) {
        state.withLock {
            if let workload = progress.workload { $0.workload = workload }
            if !progress.recent.isEmpty { $0.recent = progress.recent }
            if progress.earlyProposals { $0.earlyProposals = true }
            $0.progress = progress
        }
    }

    /// The newest progress since the last call (`nil` if none came), and the rest.
    public func take() -> Taken {
        state.withLock {
            let taken = $0
            $0.progress = nil
            $0.workload = nil
            $0.recent = []
            $0.earlyProposals = false
            return taken
        }
    }
}
