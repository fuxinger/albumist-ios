import Foundation
import SortlyCore

/// How much battery the photo analysis uses, for the diagnostic report: "Akku: 1,8 % pro
/// 1.000 Fotos (Vordergrund 2,1 %, Hintergrund 1,2 %; 4.200 Fotos gemessen)". Asked for by the
/// owner on 19.11.2026 ("Sollte auch noch Batterie verbraucht analysieren").
///
/// The app records every continuous stretch of analysis (`BatteryStretchTracker`, fed by
/// `BatteryLog` on the device): battery level and power at its start and end, the photos the
/// image step finished in it, heat and Low Power Mode. Only numbers, nothing about the photos,
/// and nothing leaves the phone unless the user shares the report.
///
/// One continuous stretch: the app on screen or in the background, the analysis busy the whole
/// time, the phone on power or not the whole time.
public struct BatteryStretch: Codable, Sendable, Equatable {
    public enum Place: String, Codable, Sendable { case foreground, background }

    /// Why a stretch does not count for the number.
    public enum Exclusion: String, Codable, Sendable, CaseIterable {
        /// On power: the level says nothing about the use.
        case charging
        /// UIDevice said -1 (simulator, monitoring not ready).
        case levelUnknown
        /// The level went up without power being seen: plugged in and out between two readings,
        /// or iOS corrected the level. The drop cannot be known.
        case levelRose

        var label: String {
            switch self {
            case .charging: "charging"
            case .levelUnknown: "level unknown"
            case .levelRose: "level rose"
            }
        }
    }

    public var place: Place
    public var start: Date
    public var end: Date
    /// 0…1 as UIDevice says it; `nil` when unknown (-1).
    public var startLevel: Double?
    public var endLevel: Double?
    /// On power (charging or full) during the stretch.
    public var charging: Bool
    /// Photos the image step (`AnalysisPipeline.Stage.content`) finished in the stretch: the
    /// image step is most of the analysis' work, and a photo whose image labels alone were added
    /// counts as one, as on the card. A stretch without any (reading the library, places,
    /// texts) still counts its battery: that is part of what analysing the photos costs.
    public var photos: Int
    /// The highest heat level seen (`DeviceState.Thermal.rawValue`).
    public var hottest: Int
    /// Low Power Mode was on at some point.
    public var lowPower: Bool

    public init(place: Place, start: Date, end: Date, startLevel: Double?, endLevel: Double?, charging: Bool,
                photos: Int, hottest: Int, lowPower: Bool) {
        self.place = place
        self.start = start
        self.end = end
        self.startLevel = startLevel
        self.endLevel = endLevel
        self.charging = charging
        self.photos = photos
        self.hottest = hottest
        self.lowPower = lowPower
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// At most `limit` stretches, in order. Over it, the oldest without photos of the image step
    /// go first (second review: short stretches of checks without new photos never push out the
    /// ones with photos), then the oldest.
    public static func capped(_ stretches: [BatteryStretch], at limit: Int) -> [BatteryStretch] {
        var excess = stretches.count - limit
        guard excess > 0 else { return stretches }
        var kept: [BatteryStretch] = []
        for stretch in stretches {
            if excess > 0, stretch.photos == 0 { excess -= 1 } else { kept.append(stretch) }
        }
        return Array(kept.suffix(limit))
    }

    /// A level in percentage points, to a tenth: UIDevice gives a `Float` (0.85 arrives as
    /// 0.8500000238…), and the steps are whole points anyway.
    static func points(_ level: Double) -> Double { (level * 1_000).rounded() / 10 }

    /// Why it does not count; `nil` when it does.
    public var exclusion: Exclusion? {
        if charging { return .charging }
        guard let startLevel, let endLevel else { return .levelUnknown }
        if Self.points(endLevel) > Self.points(startLevel) { return .levelRose }
        return nil
    }

    /// Points the level fell; `nil` for a stretch that does not count.
    public var drop: Double? {
        guard exclusion == nil, let startLevel, let endLevel else { return nil }
        return Self.points(startLevel) - Self.points(endLevel)
    }
}

/// Cuts the analysis into `BatteryStretch`es from what the app sees with every change of the
/// analysis and every scene change. Kept by the app between launches (`Codable`), so a stretch
/// iOS ended by holding or quitting the app still counts up to its last reading.
public struct BatteryStretchTracker: Codable, Sendable, Equatable {
    /// Nothing seen for longer than this: iOS held the app (no background time), or the app was
    /// quit. The stretch ends where it was last seen, so time without analysis never counts.
    /// The analysis says something at least every few seconds while it works.
    public static let maxSilence: TimeInterval = 120
    /// A stretch this short without a photo is not kept (a moment "inactive", Control Center):
    /// unless its level moved, it holds nothing and would only fill the list.
    public static let minKept: TimeInterval = 10

    public struct Observation: Sendable {
        public var now: Date
        /// The analysis works: a run is busy and does not wait for the device (heat, battery).
        public var analysing: Bool
        public var onScreen: Bool
        public var stage: AnalysisPipeline.Stage?
        /// The stage's count, as the progress says it.
        public var completed: Int
        public var device: DeviceState

        public init(now: Date, analysing: Bool, onScreen: Bool, stage: AnalysisPipeline.Stage?, completed: Int,
                    device: DeviceState) {
            self.now = now
            self.analysing = analysing
            self.onScreen = onScreen
            self.stage = stage
            self.completed = completed
            self.device = device
        }

        var place: BatteryStretch.Place { onScreen ? .foreground : .background }
    }

    /// The stretch in progress, with the step last seen and the count photos are counted from.
    ///
    /// The count is settled only by a second reading of the same step (second review of the
    /// battery branch): the app sets a step and its count in two statements, and a run (the
    /// overnight refinement too) starts with the last run's step and count still set. A reading
    /// right after a new step or a new start can therefore pair a step with another step's count
    /// (the image step with the places' 6.000, then its own 13.990 analysed before), and that jump
    /// is no work. Whatever order the app publishes in, a count is never taken from such a reading.
    public struct Open: Codable, Sendable, Equatable {
        public var stretch: BatteryStretch
        var lastSeen: Date
        var stage: AnalysisPipeline.Stage?
        /// `nil` until a reading of the same step settles it.
        var completed: Int?
    }

    public private(set) var open: Open?

    /// Whether the analysis works, for `Observation.analysing`: a busy run that waits neither for
    /// the device (heat, battery) nor for Apple's place names (only the overnight refinement
    /// waits for them; second review). Waiting is no work of the analysis.
    public static func isAnalysing(running: Bool, waitingForDevice: Bool, waitingForApple: Bool) -> Bool {
        running && !waitingForDevice && !waitingForApple
    }

    public init() {}

    /// Takes one observation; returns the stretch it ended, if any and worth keeping (empty
    /// otherwise; never more than one, as a stretch it begins cannot end in the same call).
    public mutating func observe(_ seen: Observation) -> [BatteryStretch] {
        var ended: [BatteryStretch] = []
        /// A stretch that ends only because the screen or the power changed hands its settled
        /// count on: the run and its step go on.
        var settled: Int?
        if var current = open {
            if seen.now.timeIntervalSince(current.lastSeen) > Self.maxSilence {
                ended.append(current.stretch)
                open = nil
            } else if !seen.analysing || seen.place != current.stretch.place || seen.device.isCharging != current.stretch.charging {
                // The power changed between the last reading and this one: the stretch ends at
                // the last reading, which still belongs to it.
                if seen.device.isCharging == current.stretch.charging { Self.advance(&current, with: seen) }
                if seen.analysing, current.completed != nil, current.stage == seen.stage { settled = seen.completed }
                ended.append(current.stretch)
                open = nil
            } else {
                Self.advance(&current, with: seen)
                open = current
            }
        }
        if open == nil, seen.analysing {
            let stretch = BatteryStretch(place: seen.place, start: seen.now, end: seen.now, startLevel: seen.device.batteryLevel,
                                         endLevel: seen.device.batteryLevel, charging: seen.device.isCharging, photos: 0,
                                         hottest: seen.device.thermal.rawValue, lowPower: seen.device.isLowPowerMode)
            open = Open(stretch: stretch, lastSeen: seen.now, stage: seen.stage, completed: settled)
        }
        return ended.filter(Self.isKept)
    }

    /// Ends the stretch in progress at its last reading (iOS ended the background time).
    public mutating func close() -> BatteryStretch? {
        defer { open = nil }
        return open.map(\.stretch).flatMap { Self.isKept($0) ? $0 : nil }
    }

    private static func isKept(_ stretch: BatteryStretch) -> Bool {
        stretch.photos > 0 || stretch.duration >= minKept || stretch.startLevel != stretch.endLevel
    }

    private static func advance(_ current: inout Open, with seen: Observation) {
        // Only the image step's photos, and only what this stretch saw it do: a run that goes
        // on starts the step at the photos analysed before (`contentBefore`), which is no work.
        // A new step only settles on its next reading (`Open`).
        if seen.stage != current.stage {
            current.stage = seen.stage
            current.completed = nil
        } else {
            if seen.stage == .content, let from = current.completed, seen.completed > from {
                current.stretch.photos += seen.completed - from
            }
            current.completed = seen.completed
        }
        current.lastSeen = seen.now
        current.stretch.end = seen.now
        current.stretch.endLevel = seen.device.batteryLevel
        current.stretch.hottest = max(current.stretch.hottest, seen.device.thermal.rawValue)
        current.stretch.lowPower = current.stretch.lowPower || seen.device.isLowPowerMode
    }
}

/// The number for the report, from the recorded stretches.
///
/// Rule for "enough measured" (a battery level moves in whole points, on some iPhones in five):
/// a number only once the counted stretches together cover at least 500 photos and a drop of
/// at least 3 points (10 on a phone that reports 5-point steps). With 3 points the reading can
/// be off by about one point, so the number is a rough one, which is what the report needs.
/// Many photos (2.000 or more) for less drop give a rough bound, "etwa höchstens 0,8 %": the
/// minimum drop spread over the photos. Each stretch can be off by up to a point, so it is no
/// hard limit (second review), and with fewer photos it would say too little to be worth
/// showing. Anything else says "noch zu wenig gemessen".
public struct BatteryUse: Sendable, Equatable {
    public static let minPhotos = 500
    public static let minDrop = 3.0
    public static let minDropCoarse = 10.0
    /// From this many photos, a drop below the minimum gives a rough bound.
    public static let boundPhotos = 2_000

    public enum Estimate: Sendable, Equatable {
        /// Percentage points per 1.000 photos.
        case perThousand(Double)
        /// About at most this per 1.000 photos (the minimum drop over the photos).
        case aboutAtMost(Double)
        case tooLittle
    }

    public struct Group: Sendable, Equatable {
        public var photos = 0
        /// Percentage points.
        public var drop = 0.0
        public var stretches = 0
        public var seconds = 0.0
        public var estimate = Estimate.tooLittle

        mutating func add(_ stretch: BatteryStretch, drop: Double) {
            photos += stretch.photos
            self.drop += drop
            stretches += 1
            seconds += stretch.duration
        }

        mutating func judge(minDrop: Double) {
            guard photos > 0 else { estimate = .tooLittle; return }
            if photos >= BatteryUse.minPhotos, drop >= minDrop {
                estimate = .perThousand(drop * 1_000 / Double(photos))
            } else if photos >= BatteryUse.boundPhotos, drop < minDrop {
                estimate = .aboutAtMost(minDrop * 1_000 / Double(photos))
            } else {
                estimate = .tooLittle
            }
        }
    }

    public var foreground = Group()
    public var background = Group()
    /// Both together, weighted by photos.
    public var all = Group()
    /// Every level read is a multiple of 5 points: the phone reports 5-point steps.
    public var coarseSteps = false
    public var notCounted: [BatteryStretch.Exclusion: Int] = [:]
    /// The stretches as given, for the detail line.
    private var recorded: [BatteryStretch] = []

    public init(_ stretches: [BatteryStretch]) {
        recorded = stretches
        var levels: [Double] = []
        for stretch in stretches {
            if !stretch.charging { levels += [stretch.startLevel, stretch.endLevel].compactMap { $0 }.map(BatteryStretch.points) }
            guard let drop = stretch.drop else {
                if let reason = stretch.exclusion { notCounted[reason, default: 0] += 1 }
                continue
            }
            all.add(stretch, drop: drop)
            switch stretch.place {
            case .foreground: foreground.add(stretch, drop: drop)
            case .background: background.add(stretch, drop: drop)
            }
        }
        coarseSteps = !levels.isEmpty && levels.allSatisfy { $0.truncatingRemainder(dividingBy: 5) == 0 }
        let minDrop = coarseSteps ? Self.minDropCoarse : Self.minDrop
        foreground.judge(minDrop: minDrop)
        background.judge(minDrop: minDrop)
        all.judge(minDrop: minDrop)
    }

    /// "1,8" / "1.8": one decimal at most, in the report's language.
    public static func number(_ value: Double, locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    /// "4.200" / "4,200".
    public static func count(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }

    /// One line for support, in English like the rest of the report: the counts, the steps and
    /// the last three stretches.
    public var detail: String {
        guard !recorded.isEmpty else { return "battery stretches 0" }
        let reasons = BatteryStretch.Exclusion.allCases.compactMap { reason in
            notCounted[reason].map { "\(reason.label) \($0)" }
        }
        var line = "battery stretches \(recorded.count), counted \(all.stretches) (foreground \(foreground.stretches), "
            + "background \(background.stretches)), not counted: \(reasons.isEmpty ? "none" : reasons.joined(separator: ", "))"
        line += ", steps \(coarseSteps ? "5 points" : "1 point")"
        line += ", minutes counted foreground \(Int((foreground.seconds / 60).rounded())), background \(Int((background.seconds / 60).rounded()))"
        let last = recorded.suffix(3).map(Self.describe)
        line += "; last: " + last.joined(separator: "; ")
        return line
    }

    private static func describe(_ s: BatteryStretch) -> String {
        let level = { (value: Double?) in value.map { String(Int(BatteryStretch.points($0).rounded())) } ?? "?" }
        let heat = DeviceState.Thermal(rawValue: s.hottest).map { "\($0)" } ?? "?"
        var text = "\(s.place == .foreground ? "fg" : "bg") \(level(s.startLevel))→\(level(s.endLevel)) % \(s.photos) photos "
            + "\(Int((s.duration / 60).rounded())) min, heat \(heat)"
        if s.lowPower { text += ", low power" }
        if let reason = s.exclusion { text += ", \(reason.label)" }
        return text
    }
}
