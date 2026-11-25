import Testing
@testable import AlbumistMap

/// The player and the device's conditions: going inactive pauses and plays the same day from its
/// start, coming back does not undo a user's pause, from serious heat on the rest runs as
/// slideshows, critical heat pauses, and low power mode runs the days as slideshows.
extension PlaybackPlayerTests {
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
}
