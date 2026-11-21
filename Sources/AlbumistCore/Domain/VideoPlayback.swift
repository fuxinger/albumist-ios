import Foundation

/// How long a video is (design wave 3, DS-16), as Photos shows it on a video's thumbnail and
/// under the playing video: "0:15", "2:05", "1:02:03"; for VoiceOver in words, "Video, 15
/// Sekunden" / "Video, 15 seconds".
///
/// Whole seconds, to the nearest one (halves up); a clip shorter than half a second counts as one
/// second, so a video never reads "0:00". Nil for no length: a photo, or a file Photos cannot read.
public struct VideoDuration: Equatable, Sendable {
    public let seconds: Int

    /// Longer than any video (115 days): a broken file's absurd length is cut here instead of
    /// trapping when it becomes a whole number.
    static let longest = 10_000_000.0

    public init?(seconds duration: Double) {
        guard duration.isFinite, duration > 0 else { return nil }
        seconds = max(1, Int(min(duration, Self.longest).rounded(.toNearestOrAwayFromZero)))
    }

    /// "0:15", "2:05", "59:59", "1:00:00": minutes and seconds, hours from an hour on. The same in
    /// German and English.
    public var text: String { VideoClock.text(seconds, withHours: seconds >= 3600) }

    /// "Video, 1 Minute, 2 Sekunden" / "Video, 1 minute, 2 seconds": what it is and how long.
    public func spoken(_ words: ProposalWords) -> String {
        "Video, " + VideoClock.spoken(seconds, words)
    }
}

/// Where a playing video is (DS-16): the time passed and the time left, in whole seconds that
/// always add up to its length, so the end reads "0:15" and "−0:00", never a second short. A
/// video of an hour or more shows hours on both sides, so the times keep their width while it
/// plays.
public struct VideoPosition: Equatable, Sendable {
    public let elapsed: Int
    public let length: Int

    /// - Parameter time: The player's time in seconds; before the start or after the end, or not
    ///   a number, it stays within the video.
    public init(at time: Double, of duration: VideoDuration) {
        length = duration.seconds
        let total = Double(duration.seconds)
        let clamped = time.isFinite ? min(max(time, 0), total) : (time > 0 ? total : 0)
        elapsed = min(Int(clamped.rounded(.toNearestOrAwayFromZero)), length)
    }

    public var remaining: Int { length - elapsed }

    /// "0:03"; "0:00:03" in a video of an hour or more.
    public var elapsedText: String { VideoClock.text(elapsed, withHours: length >= 3600) }

    /// "−0:12" (with a real minus sign); "−1:02:00" in a video of an hour or more.
    public var remainingText: String { "\u{2212}" + VideoClock.text(remaining, withHours: length >= 3600) }

    /// For VoiceOver on the slider: "3 Sekunden von 15 Sekunden" / "3 seconds of 15 seconds".
    public func spoken(_ words: ProposalWords) -> String {
        VideoClock.spoken(elapsed, words) + words.t(" von ", " of ") + VideoClock.spoken(length, words)
    }

    /// How far VoiceOver's swipe up or down on the slider moves, in seconds: a tenth of the
    /// video, at least one second and at most ten.
    public static func step(for duration: VideoDuration) -> Double {
        min(10, max(1, Double(duration.seconds) / 10))
    }
}

/// Seconds as a clock reads them, and in words.
enum VideoClock {
    static func text(_ seconds: Int, withHours: Bool) -> String {
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        let paddedSeconds = rest < 10 ? "0\(rest)" : "\(rest)"
        guard withHours else { return "\(seconds / 60):\(paddedSeconds)" }
        let paddedMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        return "\(hours):\(paddedMinutes):\(paddedSeconds)"
    }

    /// "1 Stunde, 2 Minuten, 3 Sekunden"; the parts that are zero are left out, nothing at all
    /// is "0 Sekunden".
    static func spoken(_ seconds: Int, _ words: ProposalWords) -> String {
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(words.number(hours) + " " + (hours == 1 ? words.t("Stunde", "hour") : words.t("Stunden", "hours")))
        }
        if minutes > 0 {
            parts.append("\(minutes) " + (minutes == 1 ? words.t("Minute", "minute") : words.t("Minuten", "minutes")))
        }
        if rest > 0 || parts.isEmpty {
            parts.append("\(rest) " + (rest == 1 ? words.t("Sekunde", "second") : words.t("Sekunden", "seconds")))
        }
        return parts.joined(separator: ", ")
    }
}

/// When a video in the photo view plays by itself (DS-16). As in Photos it plays when it comes
/// into view and starts over at its end until it is paused (Photos' "Loop Videos", on since iOS
/// 18.2), but only where motion is welcome: not with Reduce Motion, not with Settings ›
/// Accessibility › Motion › "Auto-Play Video Previews" off. There it shows its still with
/// "Abspielen" and stops at its end. Low Power Mode does not hold it back: it keeps a Live
/// Photo's short motion still (`LiveMotion`, decoration), not the video the user opened to watch.
public struct VideoStart: Equatable, Sendable {
    /// It plays once it is on screen.
    public let byItself: Bool
    /// It starts over at its end.
    public let loops: Bool

    public init(reduceMotion: Bool, autoplayVideos: Bool) {
        byItself = !reduceMotion && autoplayVideos
        loops = byItself
    }
}

/// A video's sound in the photo view (DS-16). A video starts without sound: nothing makes a sound
/// the user did not ask for, and the user's music or podcast plays on (the app's sound mixes with
/// it and follows the silent switch, `LiveAudio`). "Ton an" gives the video its sound: as in
/// Photos it stops the user's music and plays with the silent switch on. The choice holds for
/// the next videos of the same photo view; a new photo view starts without sound again.
public struct VideoSound: Equatable, Sendable {
    /// What the app's sound does with the user's.
    public enum Session: Equatable, Sendable {
        /// Mixes with it and follows the silent switch (`.ambient`).
        case mixesWithOthers
        /// Stops it and plays with the silent switch on (`.playback`).
        case interruptsOthers
    }

    public private(set) var isOn = false

    public init() {}

    public mutating func toggle() {
        isOn.toggle()
    }

    public var session: Session { isOn ? .interruptsOthers : .mixesWithOthers }
}

/// Where a video is, as far as the photo view can play it (DS-16). Albumist never loads from
/// iCloud (`isNetworkAccessAllowed = false` for every request, the owner's promise): a video
/// whose file is only in iCloud shows its still where a sharp one is on the iPhone and says
/// calmly why it does not play, never a spinner that waits for a download.
public enum VideoAvailability: Equatable, Sendable {
    /// Not answered yet: nothing is said.
    case unknown
    /// The file is on the iPhone: it plays.
    case onDevice
    /// Only in iCloud: "Abspielen kannst du es in der Fotos-App".
    case onlyInICloud
    /// Photos has nothing to play now, or did not answer in time.
    case unavailable

    /// What Photos' answer to the request for the video's player item, with the network off,
    /// says: an item, it plays; "in the cloud" or Photos' "network access required", also under
    /// an error of another kind, it is only in iCloud; anything else, it is not available now
    /// (never "only in iCloud" by guess, as for sharing, `ShareAvailability.afterReading`).
    public static func afterRequest(gotItem: Bool, inCloud: Bool, errors: [(domain: String, code: Int)]) -> VideoAvailability {
        if gotItem { return .onDevice }
        if inCloud { return .onlyInICloud }
        return ShareAvailability.afterReading(errors: errors) == .onlyInICloud ? .onlyInICloud : .unavailable
    }

    /// Only a video on the iPhone plays.
    public var plays: Bool { self == .onDevice }

    /// What the photo view says under the video, with the bars.
    public var note: VideoNote? {
        switch self {
        case .unknown, .onDevice: nil
        case .onlyInICloud: .onlyInICloud
        case .unavailable: .unavailable
        }
    }
}

/// Why a video does not play, said under it on a solid ground (design rule 1).
public enum VideoNote: Equatable, Sendable {
    case onlyInICloud
    case unavailable
}

/// Seeking while the finger moves on the video's slider (DS-16), as Apple's technical Q&A
/// QA1820 does it ("chase" seeking): one seek at a time, to the exact frame; of the places the
/// finger passes while a seek runs only the last is asked for, when the running seek ends. So
/// the picture follows the finger without a queue of seeks behind it.
public struct ChaseSeek: Equatable, Sendable {
    /// The place being sought now.
    public private(set) var running: Double?
    /// The last place the finger passed while a seek ran.
    public private(set) var waiting: Double?

    public init() {}

    public var isRunning: Bool { running != nil }

    /// The finger is at `time`: the place to seek now, or nil while a seek runs (it is kept and
    /// asked for when that one ends).
    public mutating func want(_ time: Double) -> Double? {
        guard running != nil else {
            running = time
            return time
        }
        waiting = time
        return nil
    }

    /// The running seek ended: the next place to seek (the last one wanted meanwhile), or nil
    /// when there is none or it is the place just reached.
    public mutating func finished() -> Double? {
        guard let next = waiting, next != running else {
            running = nil
            waiting = nil
            return nil
        }
        running = next
        waiting = nil
        return next
    }
}
