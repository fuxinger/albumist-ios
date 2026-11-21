import Testing
@testable import AlbumistMap

/// The player of "Reise abspielen" as a value: every state, event and timing, with clock readings
/// that are exact binary fractions, so the waits it reports compare exactly.
@Suite("Playback player")
struct PlaybackPlayerTests {
    /// Three days: 0 to 4 s, 4 to 10 s, 10 to 15 s.
    func player() -> PlaybackPlayer {
        PlaybackPlayer(dayStarts: [0, 4, 10], duration: 15)
    }

    /// A player playing day 0 on the map since `now` (time 0).
    func playingPlayer(at now: Double = 0) -> PlaybackPlayer {
        var player = player()
        _ = player.handle(.play, now: now)
        _ = player.handle(.tilesRendered, now: now)
        return player
    }

    @Test func itStartsPausedAtTheFirstDay() {
        let player = player()
        #expect(player.state == .paused)
        #expect(player.pauseReason == .user)
        #expect(player.resumeState == .waitingForTiles)
        #expect(player.day == 0)
        #expect(player.time == 0)
        #expect(player.dayCount == 3)
        #expect(player.dayEnd(0) == 4)
        #expect(player.dayEnd(1) == 10)
        #expect(player.dayEnd(2) == 15)
        #expect(!player.isRunning)
        #expect(!player.slideshowOnly)
        // Nothing is drawn yet: the map behind is not ready.
        #expect(player.showsCover(now: 0))
    }

    @Test func playWaitsForTheFirstDaysMap() {
        var player = player()
        #expect(player.handle(.play, now: 100) == [.resumed, .waitingForTiles(day: 0)])
        #expect(player.state == .waitingForTiles)
        #expect(player.waitingSince == 100)
        #expect(player.pauseReason == nil)
        #expect(player.isRunning)
        // A short wait shows no card; a longer one covers the map.
        #expect(!player.showsCover(now: 100.0625))
        #expect(player.showsCover(now: 100.125))
        // Waiting, the time stands at the day's start.
        #expect(player.tick(now: 101) == [])
        #expect(player.time == 0)
        #expect(player.handle(.tilesRendered, now: 101.25) == [.mapDay(day: 0, waited: 1.25)])
        #expect(player.state == .playing)
        #expect(player.waitingSince == nil)
        #expect(!player.showsCover(now: 101.25))
        // The time counts from the map's first picture.
        #expect(player.tick(now: 101.25) == [])
        #expect(player.time == 0)
        #expect(player.tick(now: 102.75) == [])
        #expect(player.time == 1.5)
        // Play while running changes nothing.
        #expect(player.handle(.play, now: 103) == [])
        #expect(player.state == .playing)
    }

    @Test func aDayWhoseMapTakesTooLongRunsAsASlideshow() {
        var player = player()
        _ = player.handle(.play, now: 0)
        #expect(player.tick(now: 1.25) == [])
        #expect(player.state == .waitingForTiles)
        #expect(player.tick(now: 1.5) == [.slideshowDay(day: 0, reason: .timedOut(waited: 1.5))])
        #expect(player.state == .slideshowDay)
        #expect(player.showsCover(now: 1.5))
        // The slideshow day runs from its start, counted from the timeout.
        #expect(player.time == 0)
        #expect(player.tick(now: 2.5) == [])
        #expect(player.time == 1)
        // Drawn after the timeout: too late, the day stays a slideshow.
        #expect(player.handle(.tilesRendered, now: 2.75) == [])
        #expect(player.handle(.tilesFailed, now: 2.75) == [])
        #expect(player.state == .slideshowDay)
        // At its end the next day waits for the map again.
        #expect(player.tick(now: 5.5) == [.waitingForTiles(day: 1)])
        #expect(player.state == .waitingForTiles)
        #expect(player.day == 1)
        #expect(player.time == 4)
        #expect(player.waitingSince == 5.5)
    }

    @Test func tilesDrawnAfterTheTimeoutBeforeTheTickAreTooLateToo() {
        var player = player()
        _ = player.handle(.play, now: 0)
        // No tick came between 1.5 s and the drawing: as if the tick had come first.
        #expect(player.handle(.tilesRendered, now: 1.75) == [.slideshowDay(day: 0, reason: .timedOut(waited: 1.75))])
        #expect(player.state == .slideshowDay)
        #expect(player.time == 0)
        #expect(player.tick(now: 2.75) == [])
        #expect(player.time == 1)
        // Just inside the limit is a map day.
        var inTime = self.player()
        _ = inTime.handle(.play, now: 0)
        #expect(inTime.handle(.tilesRendered, now: 1.4375) == [.mapDay(day: 0, waited: 1.4375)])
    }

    @Test func aMapThatFailsRunsTheDayAsASlideshow() {
        var player = player()
        _ = player.handle(.play, now: 0)
        #expect(player.handle(.tilesFailed, now: 0.5) == [.slideshowDay(day: 0, reason: .failed(waited: 0.5))])
        #expect(player.state == .slideshowDay)
        // A failure or drawing when nothing waits changes nothing.
        var playing = playingPlayer()
        #expect(playing.handle(.tilesFailed, now: 1) == [])
        #expect(playing.handle(.tilesRendered, now: 1) == [])
        #expect(playing.state == .playing)
        var paused = self.player()
        #expect(paused.handle(.tilesFailed, now: 1) == [])
        #expect(paused.handle(.tilesRendered, now: 1) == [])
        #expect(paused.state == .paused)
    }

    @Test func aWholePlaybackOnTheMapEndsAfterThePlanAndTheWaits() {
        var player = player()
        var notices = player.handle(.play, now: 0)
        // Apple's map draws each day a quarter second after the camera was set.
        var drawsAt: Double? = 0.25
        var frame = 0
        while player.state != .finished && frame < 10_000 {
            frame += 1
            let now = Double(frame) / 64
            if let at = drawsAt, now >= at {
                drawsAt = nil
                notices += player.handle(.tilesRendered, now: now)
            }
            let new = player.tick(now: now)
            let startsADay = new.contains { notice in
                if case .waitingForTiles = notice { return true }
                return false
            }
            if startsADay { drawsAt = now + 0.25 }
            notices += new
        }
        #expect(notices == [
            .resumed, .waitingForTiles(day: 0), .mapDay(day: 0, waited: 0.25),
            .waitingForTiles(day: 1), .mapDay(day: 1, waited: 0.25),
            .waitingForTiles(day: 2), .mapDay(day: 2, waited: 0.25),
            .finished,
        ])
        // 15 s of plan and three waits of a quarter second.
        #expect(Double(frame) / 64 == 15.75)
        #expect(player.state == .finished)
        #expect(player.time == 15)
        #expect(player.day == 2)
        #expect(!player.isRunning)
        #expect(!player.showsCover(now: 16))
    }

    @Test func aDayOverrunByALateTickStartsTheNextDayAtItsStart() {
        var player = playingPlayer()
        // A frame came late: the overrun is not carried into the next day, which waits anyway.
        #expect(player.tick(now: 5) == [.waitingForTiles(day: 1)])
        #expect(player.day == 1)
        #expect(player.time == 4)
        // A very late frame does not skip a day.
        _ = player.handle(.tilesRendered, now: 5)
        #expect(player.tick(now: 60) == [.waitingForTiles(day: 2)])
        #expect(player.day == 2)
        #expect(player.time == 10)
    }

    @Test func pauseFreezesThePictureFromTheNextTick() {
        var player = playingPlayer()
        #expect(player.tick(now: 1) == [])
        #expect(player.time == 1)
        // Paused between two frames: the time stays where the last frame put it.
        #expect(player.handle(.pause, now: 1.0078125) == [.paused(.user)])
        #expect(player.state == .paused)
        #expect(player.pauseReason == .user)
        #expect(player.resumeState == .playing)
        #expect(player.time == 1)
        #expect(!player.isRunning)
        // The map is ready behind: no card.
        #expect(!player.showsCover(now: 1.25))
        // Every later frame shows the same picture.
        for now in [1.015625, 2.0, 30.0] {
            #expect(player.tick(now: now) == [])
            #expect(player.time == 1)
        }
        // A second pause is nothing.
        #expect(player.handle(.pause, now: 3) == [])
        #expect(player.handle(.play, now: 40) == [.resumed])
        #expect(player.state == .playing)
        #expect(player.time == 1)
        #expect(player.tick(now: 40.5) == [])
        #expect(player.time == 1.5)
    }

    @Test func pauseWhileWaitingWaitsAgainOnPlay() {
        var player = player()
        _ = player.handle(.play, now: 0)
        #expect(player.handle(.pause, now: 0.5) == [.paused(.user)])
        #expect(player.resumeState == .waitingForTiles)
        #expect(player.waitingSince == nil)
        #expect(player.showsCover(now: 0.5))
        // The wait does not time out while paused, and a late drawing is ignored.
        #expect(player.tick(now: 5) == [])
        #expect(player.handle(.tilesRendered, now: 5) == [])
        #expect(player.state == .paused)
        #expect(player.handle(.play, now: 10) == [.resumed, .waitingForTiles(day: 0)])
        #expect(player.waitingSince == 10)
        #expect(player.tick(now: 11) == [])
        #expect(player.tick(now: 11.5) == [.slideshowDay(day: 0, reason: .timedOut(waited: 1.5))])
    }

    @Test func pauseDuringASlideshowDayGoesOnAsASlideshow() {
        var player = player()
        _ = player.handle(.play, now: 0)
        _ = player.handle(.tilesFailed, now: 0)
        #expect(player.tick(now: 1) == [])
        #expect(player.time == 1)
        #expect(player.handle(.pause, now: 1.5) == [.paused(.user)])
        #expect(player.resumeState == .slideshowDay)
        #expect(player.showsCover(now: 1.5))
        #expect(player.handle(.play, now: 3) == [.resumed])
        #expect(player.state == .slideshowDay)
        #expect(player.tick(now: 4) == [])
        #expect(player.time == 2)
    }

    @Test func aJumpStartsTheDayAndWaitsForItsMap() {
        var player = playingPlayer()
        _ = player.tick(now: 1)
        #expect(player.handle(.jump(day: 2), now: 1.5) == [.waitingForTiles(day: 2)])
        #expect(player.state == .waitingForTiles)
        #expect(player.day == 2)
        #expect(player.time == 10)
        #expect(player.waitingSince == 1.5)
        // Back to an earlier day.
        _ = player.handle(.tilesRendered, now: 2)
        #expect(player.handle(.jump(day: 0), now: 3) == [.waitingForTiles(day: 0)])
        #expect(player.time == 0)
        // Out of range: the first or last day.
        #expect(player.handle(.jump(day: 7), now: 4) == [.waitingForTiles(day: 2)])
        #expect(player.handle(.jump(day: -3), now: 5) == [.waitingForTiles(day: 0)])
    }

    @Test func aJumpWhileWaitingWaitsAfreshForTheNewDay() {
        var player = player()
        _ = player.handle(.play, now: 0)
        #expect(player.tick(now: 1.25) == [])
        #expect(player.handle(.jump(day: 1), now: 1.25) == [.waitingForTiles(day: 1)])
        #expect(player.waitingSince == 1.25)
        // The first day's wait would have ended at 1.5 s; the new day's counts from the jump.
        #expect(player.tick(now: 2) == [])
        #expect(player.state == .waitingForTiles)
        #expect(player.tick(now: 2.75) == [.slideshowDay(day: 1, reason: .timedOut(waited: 1.5))])
        #expect(player.time == 4)
        // A jump during a slideshow day waits for the map again.
        #expect(player.handle(.jump(day: 2), now: 3) == [.waitingForTiles(day: 2)])
        #expect(player.state == .waitingForTiles)
    }

    @Test func aJumpWhilePausedOnlyMovesThere() {
        var player = player()
        #expect(player.handle(.jump(day: 1), now: 0) == [])
        #expect(player.state == .paused)
        #expect(player.day == 1)
        #expect(player.time == 4)
        #expect(player.handle(.play, now: 10) == [.resumed, .waitingForTiles(day: 1)])
        // Paused while playing: after a jump, play waits for the new day's map.
        _ = player.handle(.tilesRendered, now: 10)
        _ = player.tick(now: 11)
        _ = player.handle(.pause, now: 11)
        #expect(player.resumeState == .playing)
        #expect(player.handle(.jump(day: 2), now: 12) == [])
        #expect(player.resumeState == .waitingForTiles)
        #expect(player.time == 10)
        #expect(player.pauseReason == .user)
        #expect(player.showsCover(now: 12))
        #expect(player.handle(.play, now: 13) == [.resumed, .waitingForTiles(day: 2)])
    }

    @Test func theEndAndOnceMore() {
        var player = playingPlayer()
        _ = player.tick(now: 4)
        _ = player.handle(.tilesRendered, now: 4)
        _ = player.tick(now: 10)
        _ = player.handle(.tilesRendered, now: 10)
        #expect(player.tick(now: 14.5) == [])
        #expect(player.tick(now: 15) == [.finished])
        #expect(player.state == .finished)
        #expect(player.time == 15)
        // Nothing moves after the end.
        #expect(player.tick(now: 20) == [])
        #expect(player.handle(.pause, now: 20) == [])
        #expect(player.handle(.tilesRendered, now: 20) == [])
        #expect(player.handle(.appInactive, now: 20) == [])
        #expect(player.handle(.appActive, now: 20) == [])
        #expect(player.state == .finished)
        // "Nochmal": the first day again.
        #expect(player.handle(.play, now: 30) == [.waitingForTiles(day: 0)])
        #expect(player.day == 0)
        #expect(player.time == 0)
        // A jump from the end plays that day.
        _ = player.handle(.jump(day: 2), now: 31)
        _ = player.handle(.tilesRendered, now: 31)
        _ = player.tick(now: 36)
        #expect(player.state == .finished)
        #expect(player.handle(.jump(day: 1), now: 40) == [.waitingForTiles(day: 1)])
    }

    @Test func goingInactivePausesAndPlaysTheSameDayFromItsStart() {
        var player = playingPlayer()
        _ = player.tick(now: 4)
        _ = player.handle(.tilesRendered, now: 4)
        _ = player.tick(now: 6.5)
        #expect(player.time == 6.5)
        #expect(player.handle(.appInactive, now: 6.75) == [.paused(.inactive)])
        #expect(player.state == .paused)
        #expect(player.pauseReason == .inactive)
        #expect(player.day == 1)
        #expect(player.time == 4)
        #expect(player.resumeState == .waitingForTiles)
        #expect(player.showsCover(now: 7))
        #expect(player.tick(now: 8) == [])
        // Inactive twice is nothing.
        #expect(player.handle(.appInactive, now: 9) == [])
        #expect(player.handle(.appActive, now: 20) == [.resumed, .waitingForTiles(day: 1)])
        #expect(player.state == .waitingForTiles)
        #expect(player.waitingSince == 20)
        #expect(player.time == 4)
        // Active again while running is nothing.
        #expect(player.handle(.appActive, now: 21) == [])
    }

    @Test func goingInactiveWhileWaitingOrInASlideshowToo() {
        var waiting = player()
        _ = waiting.handle(.play, now: 0)
        #expect(waiting.handle(.appInactive, now: 0.5) == [.paused(.inactive)])
        #expect(waiting.handle(.appActive, now: 3) == [.resumed, .waitingForTiles(day: 0)])
        var slideshow = player()
        _ = slideshow.handle(.play, now: 0)
        _ = slideshow.handle(.tilesFailed, now: 0)
        _ = slideshow.tick(now: 2)
        #expect(slideshow.handle(.appInactive, now: 2) == [.paused(.inactive)])
        #expect(slideshow.time == 0)
        // Back, the day waits for the map again: its failure may be over.
        #expect(slideshow.handle(.appActive, now: 3) == [.resumed, .waitingForTiles(day: 0)])
    }

    @Test func comingBackDoesNotUndoAUsersPause() {
        var player = playingPlayer()
        _ = player.tick(now: 2)
        _ = player.handle(.pause, now: 2)
        #expect(player.handle(.appInactive, now: 3) == [])
        #expect(player.handle(.appActive, now: 4) == [])
        #expect(player.state == .paused)
        #expect(player.pauseReason == .user)
        #expect(player.resumeState == .playing)
        #expect(player.time == 2)
        #expect(player.handle(.play, now: 5) == [.resumed])
        #expect(player.state == .playing)
    }

    @Test func fromSeriousHeatOnTheRestRunsAsSlideshows() {
        var player = playingPlayer()
        _ = player.tick(now: 1)
        #expect(player.handle(.heat(.fair), now: 1) == [])
        #expect(player.state == .playing)
        #expect(player.handle(.heat(.serious), now: 1.25) == [.slideshowDay(day: 0, reason: .saving)])
        #expect(player.slideshowOnly)
        #expect(player.state == .slideshowDay)
        #expect(player.time == 1)
        #expect(player.tick(now: 2.25) == [])
        #expect(player.time == 2)
        // Hotter still, but not critical: nothing new.
        #expect(player.handle(.heat(.serious), now: 2.5) == [])
        // The next day starts as a slideshow at once, without waiting for the map.
        #expect(player.tick(now: 4.25) == [.slideshowDay(day: 1, reason: .saving)])
        #expect(player.time == 4)
        // Cooled down: the day runs on as a slideshow, the next waits for the map.
        #expect(player.handle(.heat(.nominal), now: 5) == [])
        #expect(!player.slideshowOnly)
        #expect(player.state == .slideshowDay)
        #expect(player.tick(now: 10.25) == [.waitingForTiles(day: 2)])
    }

    @Test func seriousHeatWhileWaitingOrPaused() {
        var waiting = player()
        _ = waiting.handle(.play, now: 0)
        #expect(waiting.handle(.heat(.serious), now: 0.5) == [.slideshowDay(day: 0, reason: .saving)])
        #expect(waiting.time == 0)
        // Paused on the map, it comes back as a slideshow.
        var paused = playingPlayer()
        _ = paused.tick(now: 1)
        _ = paused.handle(.pause, now: 1)
        #expect(paused.handle(.heat(.serious), now: 2) == [])
        #expect(paused.state == .paused)
        #expect(paused.handle(.play, now: 3) == [.resumed, .slideshowDay(day: 0, reason: .saving)])
        #expect(paused.time == 1)
        #expect(paused.tick(now: 4) == [])
        #expect(paused.time == 2)
        // Paused before a day's map was ready, it starts the day as a slideshow.
        var beforeStart = player()
        _ = beforeStart.handle(.heat(.serious), now: 0)
        #expect(beforeStart.handle(.play, now: 1) == [.resumed, .slideshowDay(day: 0, reason: .saving)])
    }

    @Test func criticalHeatPauses() {
        var player = playingPlayer()
        _ = player.tick(now: 1)
        #expect(player.handle(.heat(.critical), now: 1.25) == [.paused(.heat)])
        #expect(player.state == .paused)
        #expect(player.pauseReason == .heat)
        #expect(player.resumeState == .playing)
        #expect(player.time == 1)
        // Inactive and back does not resume a pause for heat.
        #expect(player.handle(.appInactive, now: 2) == [])
        #expect(player.handle(.appActive, now: 3) == [])
        // Cooling down does not resume by itself either.
        #expect(player.handle(.heat(.serious), now: 4) == [])
        #expect(player.state == .paused)
        // "Weiter" goes on as a slideshow while it is still hot.
        #expect(player.handle(.play, now: 5) == [.resumed, .slideshowDay(day: 0, reason: .saving)])
        #expect(player.time == 1)
        // Critical while waiting: paused, and the wait starts afresh.
        var waiting = self.player()
        _ = waiting.handle(.play, now: 0)
        #expect(waiting.handle(.heat(.critical), now: 0.5) == [.paused(.heat)])
        #expect(waiting.resumeState == .waitingForTiles)
        _ = waiting.handle(.heat(.nominal), now: 1)
        #expect(waiting.handle(.play, now: 2) == [.resumed, .waitingForTiles(day: 0)])
        // Critical while paused keeps the pause as it was.
        var paused = self.player()
        #expect(paused.handle(.heat(.critical), now: 0) == [])
        #expect(paused.pauseReason == .user)
    }

    @Test func lowPowerModeRunsTheDaysAsSlideshows() {
        var player = playingPlayer()
        _ = player.tick(now: 1)
        #expect(player.handle(.lowPowerMode(true), now: 1) == [.slideshowDay(day: 0, reason: .saving)])
        #expect(player.slideshowOnly)
        #expect(player.handle(.lowPowerMode(true), now: 2) == [])
        #expect(player.tick(now: 4) == [.slideshowDay(day: 1, reason: .saving)])
        // Heat on top of Low Power Mode is nothing new.
        #expect(player.handle(.heat(.serious), now: 5) == [])
        _ = player.handle(.heat(.nominal), now: 5)
        #expect(player.slideshowOnly)
        #expect(player.handle(.lowPowerMode(false), now: 6) == [])
        #expect(!player.slideshowOnly)
        #expect(player.state == .slideshowDay)
        #expect(player.tick(now: 10) == [.waitingForTiles(day: 2)])
        // Switched on before the start: the first day is a slideshow at once.
        var before = self.player()
        #expect(before.handle(.lowPowerMode(true), now: 0) == [])
        #expect(before.handle(.play, now: 1) == [.resumed, .slideshowDay(day: 0, reason: .saving)])
    }

    @Test func coverDelayAndCoverPerState() {
        var player = player()
        _ = player.handle(.play, now: 0)
        #expect(!player.showsCover(now: 0))
        #expect(!player.showsCover(now: 0.0625))
        #expect(player.showsCover(now: 0.125))
        _ = player.handle(.tilesRendered, now: 0.125)
        #expect(!player.showsCover(now: 0.125))
        _ = player.handle(.jump(day: 1), now: 1)
        _ = player.handle(.tilesFailed, now: 1)
        #expect(player.showsCover(now: 1))
    }

    @Test func brokenClockReadingsTakeTheLastOne() {
        var player = player()
        _ = player.handle(.play, now: 2)
        _ = player.handle(.tilesRendered, now: 2)
        _ = player.tick(now: 3)
        #expect(player.time == 1)
        #expect(player.tick(now: .nan) == [])
        #expect(player.time == 1)
        #expect(player.tick(now: .infinity) == [])
        #expect(player.time == 1)
        // A clock stepping back does not move the picture back.
        #expect(player.tick(now: 2.5) == [])
        #expect(player.time == 1)
        #expect(player.tick(now: 3.5) == [])
        #expect(player.time == 1.5)
        // An event without a usable reading waits from the last one.
        _ = player.handle(.jump(day: 1), now: .nan)
        #expect(player.waitingSince == 3.5)
        #expect(player.handle(.tilesRendered, now: -.infinity) == [.mapDay(day: 1, waited: 0)])
    }

    @Test func aPlayerOfNoDaysOrABrokenDuration() {
        var empty = PlaybackPlayer(dayStarts: [], duration: .nan)
        #expect(empty.dayStarts == [0])
        #expect(empty.duration == 0)
        #expect(empty.dayCount == 1)
        _ = empty.handle(.play, now: 0)
        _ = empty.handle(.tilesRendered, now: 0)
        #expect(empty.tick(now: 0) == [.finished])
        // A duration before the last day's start ends with that day.
        let short = PlaybackPlayer(dayStarts: [0, 5], duration: 3)
        #expect(short.duration == 5)
        #expect(short.dayEnd(1) == 5)
    }

    @Test func aPlayerFollowsItsPlan() {
        let plan = PlaybackPlan(trip: DemoTrip.iceland())
        let player = PlaybackPlayer(plan: plan)
        #expect(player.dayCount == 9)
        #expect(player.dayStarts == plan.days.map(\.start))
        #expect(player.duration == plan.duration)
        for day in plan.days {
            #expect(player.dayEnd(day.index) == day.end)
        }
    }
}

/// Whether Apple's map has drawn the picture the camera was set to.
@Suite("Playback tile watch")
struct PlaybackTileWatchTests {
    @Test func aRenderingAfterTheCameraWasSetDecides() {
        var watch = PlaybackTileWatch()
        watch.cameraSet(now: 0)
        #expect(watch.watchingSince == 0)
        watch.willStartRendering(now: 0.015625)
        #expect(watch.check(now: 1) == nil)
        #expect(watch.didFinishRendering(fully: true, now: 0.5) == .rendered)
        #expect(watch.watchingSince == nil)
        #expect(watch.isRendered)
        // Afterwards nothing more is reported.
        #expect(watch.didFinishRendering(fully: true, now: 0.75) == nil)
        #expect(watch.check(now: 2) == nil)
    }

    @Test func aRenderingThatEndsNotFullyOrAFailureIsAFailure() {
        var watch = PlaybackTileWatch()
        watch.cameraSet(now: 0)
        watch.willStartRendering(now: 0.0625)
        #expect(watch.didFinishRendering(fully: false, now: 0.5) == .failed)
        #expect(!watch.isRendered)
        watch.cameraSet(now: 1)
        #expect(watch.didFail(now: 1.25) == .failed)
        #expect(watch.watchingSince == nil)
        // A failure while nothing is watched is no verdict.
        #expect(watch.didFail(now: 2) == nil)
    }

    @Test func aRenderingThatStartedBeforeTheCameraWasSetDoesNotCount() {
        var watch = PlaybackTileWatch()
        watch.willStartRendering(now: 0)
        watch.cameraSet(now: 0.0625)
        // It finishes, but drew the picture before: no verdict, the map is ready though.
        #expect(watch.didFinishRendering(fully: true, now: 0.125) == nil)
        #expect(watch.isRendered)
        // No new rendering within the settle time: the map already shows the picture.
        #expect(watch.check(now: 0.1875) == nil)
        #expect(watch.check(now: 0.25) == .rendered)
        #expect(watch.watchingSince == nil)
    }

    @Test func aMapAlreadyDrawnSettles() {
        var watch = PlaybackTileWatch()
        watch.willStartRendering(now: 0)
        #expect(watch.didFinishRendering(fully: true, now: 1) == nil)
        watch.cameraSet(now: 2)
        #expect(watch.check(now: 2.125) == nil)
        #expect(watch.check(now: 2.25) == .rendered)
        #expect(watch.check(now: 2.5) == nil)
    }

    @Test func aMapNotYetDrawnDoesNotSettle() {
        var watch = PlaybackTileWatch()
        watch.cameraSet(now: 0)
        #expect(watch.check(now: 5) == nil)
        // A rendering that started within the settle time decides, not the settle time.
        var started = PlaybackTileWatch()
        started.willStartRendering(now: 0)
        _ = started.didFinishRendering(fully: true, now: 0.5)
        started.cameraSet(now: 1)
        started.willStartRendering(now: 1.0625)
        #expect(started.check(now: 1.5) == nil)
        #expect(started.didFinishRendering(fully: true, now: 1.75) == .rendered)
    }

    @Test func stoppedItReportsNothing() {
        var watch = PlaybackTileWatch()
        watch.cameraSet(now: 0)
        watch.stop()
        watch.willStartRendering(now: 0.0625)
        #expect(watch.didFinishRendering(fully: true, now: 0.5) == nil)
        #expect(watch.didFail(now: 0.75) == nil)
        #expect(watch.check(now: 1) == nil)
    }
}
