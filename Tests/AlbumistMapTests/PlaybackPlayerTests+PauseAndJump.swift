import Testing
@testable import AlbumistMap

/// The user's pause and jumps: a pause freezes the picture from the next tick, a jump starts its
/// day and waits for its map, a jump while paused only moves there, nothing moves after the end,
/// and "Nochmal" or a jump from the end plays again.
extension PlaybackPlayerTests {
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
}
