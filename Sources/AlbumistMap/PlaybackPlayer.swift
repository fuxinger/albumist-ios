import Foundation

/// The player of "Reise abspielen" (concept §4.4, §7, §9) as a value: which state the playback is
/// in, which day, and how far (`time`, seconds of the `PlaybackPlan`). Nothing in it runs by
/// itself: the app's display link calls `tick(now:)` every frame and feeds it the events
/// (`handle(_:now:)`), each with the time of the same clock (`CACurrentMediaTime()`), so every
/// transition and timing is tested without a timer. The notices it returns tell the app what to
/// measure and when to move the camera.
///
/// - A day first waits until Apple's map has drawn its first picture (`waitingForTiles`; the app
///   sets the camera to the day's start and watches `PlaybackTileWatch`); if that takes
///   `tileTimeout` or the map reports a failure, the day runs as a slideshow (`slideshowDay`):
///   never a half-loaded satellite image (concept §7).
/// - Pause freezes the time where the last tick left it: from the next tick on the camera stands
///   still. "Weiter" goes on from there.
/// - A jump starts the day at its beginning (waiting for its tiles again); while paused it only
///   moves there.
/// - Locking the iPhone, switching apps, a call (`appInactive`) pause and go back to the start of
///   the day; `appActive` plays that day again from its start.
/// - Heat (concept §9): from "serious" on, and in Low Power Mode, the rest of the days run as
///   slideshows (no 3D map: it heats the iPhone); "critical" pauses. Back to normal, the next day
///   plays on the map again.
/// - After the last day: `finished`; `play` starts again from the first day ("Nochmal").
public struct PlaybackPlayer: Hashable, Sendable {
    public enum State: String, Hashable, Sendable, CaseIterable {
        case playing, paused, waitingForTiles, slideshowDay, finished
    }

    /// `ProcessInfo.ThermalState`, as the player needs it.
    public enum Heat: Int, Hashable, Sendable, Comparable, CaseIterable {
        case nominal, fair, serious, critical

        public static func < (a: Heat, b: Heat) -> Bool { a.rawValue < b.rawValue }
    }

    public enum PauseReason: String, Hashable, Sendable {
        /// The pause button (or the start without autoplay).
        case user
        /// The app went inactive: locked, another app, a call.
        case inactive
        /// The iPhone got critically hot.
        case heat
    }

    public enum Event: Hashable, Sendable {
        case play
        case pause
        /// Day index from 0; out of range: the first or last day.
        case jump(day: Int)
        /// Apple's map has drawn the day's first picture (`PlaybackTileWatch`).
        case tilesRendered
        /// Apple's map could not load it.
        case tilesFailed
        case appInactive
        case appActive
        case heat(Heat)
        case lowPowerMode(Bool)
    }

    /// Why a day (or the rest of one) runs as a slideshow.
    public enum SlideshowReason: Hashable, Sendable {
        /// Apple's map took `tileTimeout` or longer (the seconds waited).
        case timedOut(waited: Double)
        /// Apple's map reported a failure (the seconds waited until then).
        case failed(waited: Double)
        /// Low Power Mode or heat: the map is not used.
        case saving
    }

    /// What happened, for the app's measurements and picture.
    public enum Notice: Hashable, Sendable {
        /// The day starts waiting for Apple's map: the app sets the camera to its start.
        case waitingForTiles(day: Int)
        /// The day plays on the map after waiting this long.
        case mapDay(day: Int, waited: Double)
        /// The day (or the rest of it) runs as a slideshow.
        case slideshowDay(day: Int, reason: SlideshowReason)
        case paused(PauseReason)
        case resumed
        case finished
    }

    /// The longest a day waits for Apple's map (concept §7: "Dauert das länger als 1,5 s, läuft
    /// dieser Tag als Bilderfolge").
    public static let tileTimeout = 1.5
    /// A wait shorter than this shows no cover (`showsCover(now:)`): a day whose map is ready at
    /// once does not flash a card.
    public static let coverDelay = 0.12

    /// When each day starts, from the plan.
    public let dayStarts: [Double]
    public let duration: Double

    public private(set) var state: State = .paused
    public private(set) var day = 0
    /// Seconds of the plan: where the picture is.
    public private(set) var time = 0.0
    /// Why it is paused (`nil` unless `state` is `.paused`).
    public private(set) var pauseReason: PauseReason? = .user
    /// What `play` goes back to.
    public private(set) var resumeState: State = .waitingForTiles
    /// Since when the day waits for Apple's map.
    public private(set) var waitingSince: Double?
    public private(set) var heat: Heat = .nominal
    public private(set) var lowPowerMode = false
    /// The time at the moment `anchorNow`, from which playing counts on.
    private var anchorTime = 0.0
    private var anchorNow = 0.0
    /// The last clock reading, for events that come with no usable one.
    private var lastNow = 0.0

    /// Paused at the start of the first day, ready to `play`.
    public init(plan: PlaybackPlan) {
        self.init(dayStarts: plan.days.map(\.start), duration: plan.duration)
    }

    /// A player for days starting at `dayStarts` (ascending, the first at 0) and lasting
    /// `duration` in all.
    public init(dayStarts: [Double], duration: Double) {
        self.dayStarts = dayStarts.isEmpty ? [0] : dayStarts
        self.duration = duration.isFinite ? max(duration, self.dayStarts.last ?? 0) : (self.dayStarts.last ?? 0)
    }

    public var dayCount: Int { dayStarts.count }

    /// Days run as slideshows (concept §9: Low Power Mode, and heat from "serious" on).
    public var slideshowOnly: Bool { heat >= .serious || lowPowerMode }

    /// Playing on the map, waiting for it, or showing a slideshow day: the time is not frozen.
    public var isRunning: Bool { state == .playing || state == .waitingForTiles || state == .slideshowDay }

    /// When day `index` ends: the next day's start, or the end of the playback.
    public func dayEnd(_ index: Int) -> Double {
        index + 1 < dayStarts.count ? dayStarts[index + 1] : duration
    }

    /// Whether a card covers Apple's map: a slideshow day, a wait longer than `coverDelay`, and a
    /// pause while a day waited or ran as a slideshow (the map behind is not ready).
    public func showsCover(now: Double) -> Bool {
        switch state {
        case .slideshowDay: return true
        case .waitingForTiles: return waitingSince.map { now - $0 >= Self.coverDelay } ?? true
        case .paused: return resumeState != .playing
        case .playing, .finished: return false
        }
    }

    // MARK: Events

    public mutating func handle(_ event: Event, now: Double) -> [Notice] {
        let now = usable(now)
        switch event {
        case .play: return play(now)
        case .pause: return pause(.user)
        case .jump(let index): return jump(to: index, now)
        case .tilesRendered: return tilesRendered(now)
        case .tilesFailed: return tilesFailed(now)
        case .appInactive: return inactive()
        case .appActive: return active(now)
        case .heat(let level): return heatChanged(level, now)
        case .lowPowerMode(let on):
            let saving = slideshowOnly
            lowPowerMode = on
            return savingStarted(wasSaving: saving, now)
        }
    }

    /// Moves the time on to `now`: a day that waited `tileTimeout` becomes a slideshow day, a day
    /// at its end hands over to the next (which waits for its map) or the playback finishes.
    public mutating func tick(now: Double) -> [Notice] {
        let now = usable(now)
        switch state {
        case .waitingForTiles:
            guard let since = waitingSince, now - since >= Self.tileTimeout else { return [] }
            return slideshow(.timedOut(waited: now - since), now)
        case .playing, .slideshowDay:
            // Never backwards, even for a clock that steps back.
            time = min(max(time, anchorTime + now - anchorNow), duration)
            guard time >= dayEnd(day) else { return [] }
            if day + 1 < dayCount { return startDay(day + 1, now) }
            state = .finished
            time = duration
            return [.finished]
        case .paused, .finished:
            return []
        }
    }

    // MARK: Transitions

    private mutating func play(_ now: Double) -> [Notice] {
        switch state {
        case .paused:
            pauseReason = nil
            switch resumeState {
            case .playing where slideshowOnly:
                state = .slideshowDay
                anchor(now)
                return [.resumed, .slideshowDay(day: day, reason: .saving)]
            case .playing, .slideshowDay:
                state = resumeState
                anchor(now)
                return [.resumed]
            case .waitingForTiles, .paused, .finished:
                return [.resumed] + startDay(day, now)
            }
        case .finished:
            return startDay(0, now)
        case .playing, .waitingForTiles, .slideshowDay:
            return []
        }
    }

    private mutating func pause(_ reason: PauseReason) -> [Notice] {
        guard isRunning else { return [] }
        // The time stays where the last tick put it: the camera stands still from the next one.
        resumeState = state
        state = .paused
        pauseReason = reason
        waitingSince = nil
        return [.paused(reason)]
    }

    private mutating func jump(to index: Int, _ now: Double) -> [Notice] {
        let target = min(max(index, 0), dayCount - 1)
        guard state != .paused else {
            day = target
            time = dayStarts[target]
            resumeState = .waitingForTiles
            return []
        }
        return startDay(target, now)
    }

    private mutating func tilesRendered(_ now: Double) -> [Notice] {
        guard state == .waitingForTiles, let since = waitingSince else { return [] }
        let waited = max(0, now - since)
        // Drawn only after the limit (the tick that would have ended the wait has not come yet):
        // too late, as if the tick had come first.
        if waited >= Self.tileTimeout { return slideshow(.timedOut(waited: waited), now) }
        state = .playing
        waitingSince = nil
        anchor(now)
        return [.mapDay(day: day, waited: waited)]
    }

    private mutating func tilesFailed(_ now: Double) -> [Notice] {
        guard state == .waitingForTiles, let since = waitingSince else { return [] }
        return slideshow(.failed(waited: max(0, now - since)), now)
    }

    private mutating func inactive() -> [Notice] {
        guard isRunning else { return [] }
        state = .paused
        pauseReason = .inactive
        resumeState = .waitingForTiles
        waitingSince = nil
        time = dayStarts[day]
        return [.paused(.inactive)]
    }

    private mutating func active(_ now: Double) -> [Notice] {
        guard state == .paused, pauseReason == .inactive else { return [] }
        pauseReason = nil
        return [.resumed] + startDay(day, now)
    }

    private mutating func heatChanged(_ level: Heat, _ now: Double) -> [Notice] {
        let saving = slideshowOnly
        heat = level
        if level == .critical && isRunning { return pause(.heat) }
        return savingStarted(wasSaving: saving, now)
    }

    /// Saving began (Low Power Mode or heat): the day on the map, or waiting for it, goes on as
    /// a slideshow. Saving ending changes nothing now: the next day waits for the map again.
    private mutating func savingStarted(wasSaving: Bool, _ now: Double) -> [Notice] {
        guard slideshowOnly, !wasSaving, state == .playing || state == .waitingForTiles else { return [] }
        return slideshow(.saving, now)
    }

    /// The day goes on as a slideshow from the current time.
    private mutating func slideshow(_ reason: SlideshowReason, _ now: Double) -> [Notice] {
        state = .slideshowDay
        waitingSince = nil
        anchor(now)
        return [.slideshowDay(day: day, reason: reason)]
    }

    /// Day `index` from its start: waiting for Apple's map, or a slideshow while saving.
    private mutating func startDay(_ index: Int, _ now: Double) -> [Notice] {
        day = index
        time = dayStarts[index]
        pauseReason = nil
        if slideshowOnly { return slideshow(.saving, now) }
        state = .waitingForTiles
        waitingSince = now
        return [.waitingForTiles(day: index)]
    }

    private mutating func anchor(_ now: Double) {
        anchorTime = time
        anchorNow = now
    }

    /// `now` when it is a number (and remembered), else the last one.
    private mutating func usable(_ now: Double) -> Double {
        guard now.isFinite else { return lastNow }
        lastNow = now
        return now
    }
}

/// Whether Apple's map has drawn the picture the camera was set to (concept §7: "Vor jedem Tag
/// wartet das Abspielen, bis das Kartenbild fertig ist"), from `MKMapView`'s callbacks: after
/// `cameraSet(now:)`, a rendering that starts and finishes fully is `.rendered`; one that
/// finishes not fully, or a loading failure, is `.failed`. When no rendering starts within
/// `settleSeconds` and the map's last rendering had finished fully, the map already showed that
/// picture (the camera did not move, or moved within what was drawn): `.rendered` too.
public struct PlaybackTileWatch: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        case rendered, failed
    }

    /// How long after the camera was set a rendering must start to count as the one it caused.
    public static let settleSeconds = 0.15

    /// MapKit's last word: its last rendering finished fully, and none started since.
    public private(set) var isRendered = false
    /// Since when it watches (the camera was set then); `nil` when it does not.
    public private(set) var watchingSince: Double?
    private var renderingStarted = false

    public init() {}

    /// The camera was set to the picture to wait for.
    public mutating func cameraSet(now: Double) {
        watchingSince = now
        renderingStarted = false
    }

    /// Stops watching (the wait ended otherwise).
    public mutating func stop() {
        watchingSince = nil
        renderingStarted = false
    }

    /// `mapViewWillStartRenderingMap(_:)`.
    public mutating func willStartRendering(now: Double) {
        isRendered = false
        if watchingSince != nil { renderingStarted = true }
    }

    /// `mapViewDidFinishRenderingMap(_:fullyRendered:)`: the verdict when it ends a rendering that
    /// started after the camera was set.
    public mutating func didFinishRendering(fully: Bool, now: Double) -> Verdict? {
        isRendered = fully
        guard watchingSince != nil, renderingStarted else { return nil }
        stop()
        return fully ? .rendered : .failed
    }

    /// `mapViewDidFailLoadingMap(_:withError:)`.
    public mutating func didFail(now: Double) -> Verdict? {
        isRendered = false
        guard watchingSince != nil else { return nil }
        stop()
        return .failed
    }

    /// Called every frame: `.rendered` once `settleSeconds` passed since the camera was set with
    /// no rendering started and the map fully drawn.
    public mutating func check(now: Double) -> Verdict? {
        guard let since = watchingSince, !renderingStarted, isRendered, now - since >= Self.settleSeconds else { return nil }
        stop()
        return .rendered
    }
}
