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
