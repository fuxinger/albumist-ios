import Foundation
import Testing
@testable import AlbumistCore

/// Videos in the photo view and on the thumbnails (design wave 3, DS-16): how long a video is,
/// in figures and for VoiceOver in German and English, where it is while it plays, when it
/// starts and loops by itself, its sound, what Photos' answer says of where it is (Albumist
/// never loads from iCloud), and seeking while the finger moves on the slider.
@Suite("Videos: length, start, sound and iCloud (DS-16)")
struct VideoPlaybackTests {
    // MARK: How long

    /// Minutes and seconds as Photos shows them on a video's thumbnail; hours only from an hour on.
    @Test func theLengthReadsAsInPhotos() {
        let cases: [(Double, String)] = [
            (5, "0:05"), (15, "0:15"), (59, "0:59"), (60, "1:00"), (125, "2:05"), (600, "10:00"),
            (3599, "59:59"), (3600, "1:00:00"), (3723, "1:02:03"), (36_061, "10:01:01"),
        ]
        for (seconds, text) in cases {
            #expect(VideoDuration(seconds: seconds)?.text == text, "\(seconds) s")
        }
    }

    /// To the nearest second, halves up; a clip shorter than half a second is never "0:00".
    @Test func theLengthIsRoundedToTheNearestSecond() {
        #expect(VideoDuration(seconds: 14.4)?.seconds == 14)
        #expect(VideoDuration(seconds: 14.5)?.seconds == 15)
        #expect(VideoDuration(seconds: 14.6)?.text == "0:15")
        #expect(VideoDuration(seconds: 59.5)?.text == "1:00")
        #expect(VideoDuration(seconds: 3599.5)?.text == "1:00:00")
        #expect(VideoDuration(seconds: 0.2)?.text == "0:01")
        #expect(VideoDuration(seconds: 0.001)?.seconds == 1)
    }

    /// No length, no badge: a photo has none, and a broken file's never crashes the grid.
    @Test func withoutALengthThereIsNone() {
        for seconds in [0, -3, Double.nan, -Double.infinity, Double.infinity] {
            #expect(VideoDuration(seconds: seconds) == nil, "\(seconds)")
        }
        #expect(VideoDuration(seconds: 1e300) != nil)
        #expect(VideoDuration(seconds: 1e300)?.text.isEmpty == false)
        // While a video's length is not known yet it counts as the shortest.
        #expect(VideoDuration.oneSecond == VideoDuration(seconds: 1))
        #expect(VideoDuration.oneSecond.text == "0:01")
    }

    /// The slider and the times follow what plays (review F, F7): a slow-motion video plays as a
    /// composition longer than the asset says, an edit may trim it. Once the playing item knows
    /// its length and it differs from the asset's by more than a second, that length; else the
    /// asset's, so the times do not jump by a rounding.
    @Test func theLengthIsWhatPlays() throws {
        let asset = try #require(VideoDuration(seconds: 10))
        #expect(VideoDuration.playing(asset: asset, item: 40.2)?.seconds == 40, "slow motion")
        #expect(VideoDuration.playing(asset: asset, item: 6)?.seconds == 6, "trimmed")
        for close in [10.4, 9.2, 11, 9] {
            #expect(VideoDuration.playing(asset: asset, item: close) == asset, "\(close) s")
        }
        for unknown in [Double.nan, .infinity, 0, -1] {
            #expect(VideoDuration.playing(asset: asset, item: unknown) == asset, "\(unknown)")
        }
        // Photos said nothing of its length: the item's, once it knows it.
        #expect(VideoDuration.playing(asset: nil, item: 12.6)?.seconds == 13)
        #expect(VideoDuration.playing(asset: nil, item: .nan) == nil)
    }

    /// The figures read the same in German and English; what VoiceOver says does not.
    @Test func theFiguresAreTheSameInBothLanguages() {
        let length = VideoDuration(seconds: 3723)
        #expect(length?.text == "1:02:03")
        #expect(length?.spoken(.german) != length?.spoken(.english))
    }

    /// VoiceOver says what it is and how long, in words, one and more, without the parts that are
    /// zero (Photos' badge says nothing to VoiceOver; Albumist's grid cells do).
    @Test func voiceOverSaysVideoAndHowLongInGerman() {
        let cases: [(Double, String)] = [
            (15, "Video, 15 Sekunden"), (1, "Video, 1 Sekunde"), (60, "Video, 1 Minute"),
            (62, "Video, 1 Minute, 2 Sekunden"), (125, "Video, 2 Minuten, 5 Sekunden"), (3600, "Video, 1 Stunde"),
            (3723, "Video, 1 Stunde, 2 Minuten, 3 Sekunden"), (7201, "Video, 2 Stunden, 1 Sekunde"),
            (14.6, "Video, 15 Sekunden"), (0.2, "Video, 1 Sekunde"),
        ]
        for (seconds, spoken) in cases {
            #expect(VideoDuration(seconds: seconds)?.spoken(.german) == spoken, "\(seconds) s")
        }
    }

    @Test func voiceOverSaysVideoAndHowLongInEnglish() {
        let cases: [(Double, String)] = [
            (15, "Video, 15 seconds"), (1, "Video, 1 second"), (60, "Video, 1 minute"),
            (62, "Video, 1 minute, 2 seconds"), (125, "Video, 2 minutes, 5 seconds"), (3600, "Video, 1 hour"),
            (3723, "Video, 1 hour, 2 minutes, 3 seconds"), (7201, "Video, 2 hours, 1 second"),
        ]
        for (seconds, spoken) in cases {
            #expect(VideoDuration(seconds: seconds)?.spoken(.english) == spoken, "\(seconds) s")
        }
    }

    // MARK: Where it is while it plays

    /// The time passed and the time left, in whole seconds that always add up to the length, so
    /// the end reads "0:15" and "−0:00", never one second short.
    @Test func timePassedAndLeftAddUpToTheLength() throws {
        let length = try #require(VideoDuration(seconds: 15))
        let start = VideoPosition(at: 0, of: length)
        #expect(start.elapsedText == "0:00")
        #expect(start.remainingText == "\u{2212}0:15")
        let three = VideoPosition(at: 3.2, of: length)
        #expect(three.elapsedText == "0:03")
        #expect(three.remainingText == "\u{2212}0:12")
        let end = VideoPosition(at: 14.9, of: length)
        #expect(end.elapsedText == "0:15")
        #expect(end.remainingText == "\u{2212}0:00")
        let rounded = try #require(VideoDuration(seconds: 14.6))
        #expect(VideoPosition(at: 14.6, of: rounded).remaining == 0)
        for time in [-2, 99, Double.nan, Double.infinity] {
            let position = VideoPosition(at: time, of: length)
            #expect((0...15).contains(position.elapsed), "\(time)")
            #expect(position.elapsed + position.remaining == 15, "\(time)")
        }
    }

    /// A video of an hour or more shows hours on both sides, so the times do not change width
    /// while it plays.
    @Test func aLongVideoShowsHoursOnBothSides() throws {
        let position = VideoPosition(at: 3, of: try #require(VideoDuration(seconds: 3723)))
        #expect(position.elapsedText == "0:00:03")
        #expect(position.remainingText == "\u{2212}1:02:00")
    }

    /// VoiceOver says the place on the slider in words.
    @Test func voiceOverSaysWhereTheVideoIs() throws {
        let length = try #require(VideoDuration(seconds: 15))
        #expect(VideoPosition(at: 3, of: length).spoken(.german) == "3 Sekunden von 15 Sekunden")
        #expect(VideoPosition(at: 3, of: length).spoken(.english) == "3 seconds of 15 seconds")
        #expect(VideoPosition(at: 0, of: length).spoken(.german) == "0 Sekunden von 15 Sekunden")
        let long = try #require(VideoDuration(seconds: 125))
        #expect(VideoPosition(at: 61, of: long).spoken(.english) == "1 minute, 1 second of 2 minutes, 5 seconds")
    }

    /// VoiceOver's swipe up or down on the slider moves a tenth of the video, at least a second
    /// and at most ten.
    @Test func voiceOverMovesByAStepThatFitsTheLength() throws {
        #expect(VideoPosition.step(for: try #require(VideoDuration(seconds: 5))) == 1)
        #expect(VideoPosition.step(for: try #require(VideoDuration(seconds: 15))) == 1.5)
        #expect(VideoPosition.step(for: try #require(VideoDuration(seconds: 60))) == 6)
        #expect(VideoPosition.step(for: try #require(VideoDuration(seconds: 3600))) == 10)
    }

    /// The slider's thumb glides: the photo view reads where a playing video is about every
    /// 300th of its length, 30 times a second for a short clip, and at least twice a second for
    /// a long one, so the times change on the second (review F, F13: a three-second clip jumped
    /// twelve times). Before its length is known, as for a short clip.
    @Test func theThumbGlides() throws {
        func interval(_ seconds: Double?) -> Double {
            VideoPosition.tickInterval(for: seconds.flatMap { VideoDuration(seconds: $0) }, lowPowerMode: false)
        }
        #expect(interval(3) == 1.0 / 30)
        #expect(interval(10) == 1.0 / 30)
        #expect(abs(interval(30) - 0.1) < 1e-9)
        #expect(abs(interval(90) - 0.3) < 1e-9)
        #expect(interval(150) == 0.5)
        #expect(interval(3600) == 0.5)
        #expect(interval(nil) == 1.0 / 30)
    }

    /// In Low Power Mode the photo view reads where a playing video is at most 10 times a second
    /// (review V14): the thumb still moves without jumps, and a short clip costs the iPhone a
    /// third of the work. A long video ticks as before. The photo view knows the mode from its
    /// start (`VideoStart`).
    @Test func inLowPowerModeTheThumbTicksAtMostTenTimesASecond() throws {
        func interval(_ seconds: Double?) -> Double {
            VideoPosition.tickInterval(for: seconds.flatMap { VideoDuration(seconds: $0) }, lowPowerMode: true)
        }
        for seconds in [1.0, 3, 10, 29] {
            #expect(interval(seconds) == 0.1, "\(seconds) s")
        }
        #expect(abs(interval(90) - 0.3) < 1e-9)
        #expect(interval(3600) == 0.5)
        #expect(interval(nil) == 0.1)
        #expect(VideoStart(reduceMotion: false, autoplayVideos: true, lowPowerMode: true).lowPowerMode)
        #expect(!VideoStart(reduceMotion: false, autoplayVideos: true, lowPowerMode: false).lowPowerMode)
    }

    // MARK: Starting by itself

    /// As in Photos a video plays when it comes into view and starts over at its end, but only
    /// where motion is welcome: not with Reduce Motion, not with "Auto-Play Video Previews" off.
    /// There it waits for "Abspielen" and stops at its end.
    @Test func aVideoStartsByItselfOnlyWhereMotionIsWelcome() {
        let welcome = VideoStart(reduceMotion: false, autoplayVideos: true, lowPowerMode: false)
        #expect(welcome.byItself)
        #expect(welcome.loops)
        for lowPowerMode in [false, true] {
            for (reduceMotion, autoplay) in [(true, true), (false, false), (true, false)] {
                let calm = VideoStart(reduceMotion: reduceMotion, autoplayVideos: autoplay, lowPowerMode: lowPowerMode)
                #expect(!calm.byItself, "Reduce Motion \(reduceMotion), autoplay \(autoplay), Low Power Mode \(lowPowerMode)")
                #expect(!calm.loops, "Reduce Motion \(reduceMotion), autoplay \(autoplay), Low Power Mode \(lowPowerMode)")
            }
        }
    }

    /// Low Power Mode keeps a Live Photo's short motion still (it is decoration). A video the
    /// user opened to watch still starts by itself, but plays once and stops at its end instead
    /// of looping for good (review F, F8).
    @Test func inLowPowerModeAVideoPlaysOnce() {
        #expect(!LiveMotion.playsHint(reduceMotion: false, lowPowerMode: true, autoplayVideos: true))
        let saving = VideoStart(reduceMotion: false, autoplayVideos: true, lowPowerMode: true)
        #expect(saving.byItself)
        #expect(!saving.loops)
    }

    /// A video keeps the screen on while it plays, as any video the user watches; one that loops
    /// lets the iPhone lock after its first play, as it may loop on while nobody watches (review
    /// F, F8: before, an open video kept the iPhone awake for good).
    @Test func aLoopingVideoLetsTheIPhoneLockAfterItsFirstPlay() {
        let looping = VideoStart(reduceMotion: false, autoplayVideos: true, lowPowerMode: false)
        #expect(looping.keepsScreenOn(loopsDone: 0, soundOn: false))
        #expect(!looping.keepsScreenOn(loopsDone: 1, soundOn: false))
        #expect(!looping.keepsScreenOn(loopsDone: 40, soundOn: false))
        for once in [VideoStart(reduceMotion: true, autoplayVideos: true, lowPowerMode: false),
                     VideoStart(reduceMotion: false, autoplayVideos: true, lowPowerMode: true)] {
            #expect(once.keepsScreenOn(loopsDone: 0, soundOn: false), "\(once)")
        }
    }

    /// A looping video with its sound on is watched: it keeps the screen on while it plays, as
    /// any video with sound; only a muted loop lets the iPhone lock after its first play (review
    /// V3: half a minute into a 20-second clip with "Ton an" the screen dimmed and locked).
    @Test func aLoopingVideoWithItsSoundKeepsTheScreenOn() {
        let looping = VideoStart(reduceMotion: false, autoplayVideos: true, lowPowerMode: false)
        for loops in [0, 1, 40] {
            #expect(looping.keepsScreenOn(loopsDone: loops, soundOn: true), "\(loops) loops")
        }
        #expect(!looping.keepsScreenOn(loopsDone: 1, soundOn: false), "a muted loop")
        let once = VideoStart(reduceMotion: true, autoplayVideos: true, lowPowerMode: false)
        #expect(once.keepsScreenOn(loopsDone: 0, soundOn: true))
    }

    // MARK: Sound

    /// A video starts without sound, so nothing makes a sound the user did not ask for and the
    /// user's music plays on. "Ton an" gives it sound, which stops the user's music and plays with
    /// the silent switch on, as in Photos; the choice holds for the next videos of the same photo
    /// view, a new photo view starts without sound again.
    @Test func aVideoStartsWithoutSoundUntilTheUserTurnsItOn() {
        var sound = VideoSound()
        #expect(!sound.isOn)
        #expect(sound.session == .mixesWithOthers)
        sound.toggle()
        #expect(sound.isOn)
        #expect(sound.session == .interruptsOthers)
        sound.toggle()
        #expect(!sound.isOn)
        #expect(sound.session == .mixesWithOthers)
        #expect(!VideoSound().isOn)
    }

    /// Once "Ton an" stopped the user's music, the music is told it may go on when the photo view
    /// closes, after the video's player is gone; "Ton aus" alone does not tell it (told under a
    /// running player, the end of the app's audio session would stop the video too, review F,
    /// F1). Music the photo view never stopped is told nothing.
    @Test func theUsersMusicIsToldToGoOnWhenThePhotoViewCloses() {
        var sound = VideoSound()
        #expect(!sound.interruptedOthers)
        sound.toggle()
        #expect(sound.interruptedOthers)
        sound.toggle()
        #expect(!sound.isOn)
        #expect(sound.interruptedOthers, "\"Ton aus\": the music is still to be told")
        #expect(!VideoSound().interruptedOthers)
    }

    // MARK: Only what is on the iPhone

    /// Photos' answer to the request for a video with the network off says where it is: a player
    /// item, it is on the iPhone; "in the cloud" or Photos' "network access required", also under
    /// another error, it is only in iCloud; anything else, not available now (never "only in
    /// iCloud" by guess).
    @Test func photosAnswerSaysWhereTheVideoIs() {
        let network = (domain: ShareAvailability.photosErrorDomain, code: ShareAvailability.networkAccessRequired)
        let other = (domain: "NSCocoaErrorDomain", code: 4)
        #expect(VideoAvailability.afterRequest(gotItem: true, inCloud: false, errors: []) == .onDevice)
        #expect(VideoAvailability.afterRequest(gotItem: true, inCloud: true, errors: []) == .onDevice)
        #expect(VideoAvailability.afterRequest(gotItem: false, inCloud: true, errors: []) == .onlyInICloud)
        #expect(VideoAvailability.afterRequest(gotItem: false, inCloud: false, errors: [network]) == .onlyInICloud)
        #expect(VideoAvailability.afterRequest(gotItem: false, inCloud: false, errors: [other, network]) == .onlyInICloud)
        #expect(VideoAvailability.afterRequest(gotItem: false, inCloud: false, errors: [other]) == .unavailable)
        #expect(VideoAvailability.afterRequest(gotItem: false, inCloud: false, errors: []) == .unavailable)
    }

    /// Only a video on the iPhone plays; a video only in iCloud says so and where it plays; one
    /// Photos did not answer for is not available now, and nothing is said while it is asked.
    @Test func onlyAVideoOnTheIPhonePlays() {
        #expect(VideoAvailability.onDevice.plays)
        for other in [VideoAvailability.unknown, .onlyInICloud, .unavailable] {
            #expect(!other.plays, "\(other)")
        }
        #expect(VideoAvailability.unknown.note == nil)
        #expect(VideoAvailability.onDevice.note == nil)
        #expect(VideoAvailability.onlyInICloud.note == .onlyInICloud)
        #expect(VideoAvailability.unavailable.note == .unavailable)
    }

    /// A video its player cannot play (a file it cannot decode) is not available now: the calm
    /// note "Dieses Video lässt sich gerade nicht abspielen.", said at once, also when it never
    /// played (review F, F11). A failure changes nothing else: a video not on the iPhone, or not
    /// answered yet, stays as it is.
    @Test func aVideoItsPlayerCannotPlayIsNotAvailable() {
        #expect(VideoAvailability.onDevice.afterPlayer(failed: true) == .unavailable)
        #expect(VideoAvailability.onDevice.afterPlayer(failed: true).note == .unavailable)
        #expect(VideoAvailability.onDevice.afterPlayer(failed: false) == .onDevice)
        for other in [VideoAvailability.unknown, .onlyInICloud, .unavailable] {
            #expect(other.afterPlayer(failed: true) == other, "\(other)")
            #expect(other.afterPlayer(failed: false) == other, "\(other)")
        }
    }

    // MARK: Seeking with the finger

    /// While the finger moves on the slider, one seek runs at a time, to the exact frame; the
    /// places the finger passes meanwhile are not all asked for, only the last one, when the
    /// running seek ends (Apple's technical Q&A QA1820), so the picture follows the finger
    /// without a queue of seeks behind it.
    @Test func seekingFollowsTheFingerOneSeekAtATime() {
        var seek = ChaseSeek()
        #expect(seek.want(2) == 2)
        #expect(seek.want(3) == nil)
        #expect(seek.want(4) == nil)
        #expect(seek.finished() == 4)
        #expect(seek.finished() == nil)
        #expect(seek.want(5) == 5)
        #expect(seek.finished() == nil)
        // The place that is running already is not asked for again.
        #expect(seek.want(6) == 6)
        #expect(seek.want(6) == nil)
        #expect(seek.finished() == nil)
        #expect(!seek.isRunning)
    }
}
