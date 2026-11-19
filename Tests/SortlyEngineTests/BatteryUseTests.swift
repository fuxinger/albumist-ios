import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore

/// "Sollte auch noch Batterie verbraucht analysieren" (owner, 19.11.2026): the diagnostic report
/// says how much battery the photo analysis uses, as "% Akku pro 1.000 Fotos". The stretches are
/// recorded on the device (`BatteryStretchTracker`), the number comes from them (`BatteryUse`).
@Suite("Battery use of the analysis")
struct BatteryUseTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func device(_ level: Double?, charging: Bool = false, thermal: DeviceState.Thermal = .nominal,
                       lowPower: Bool = false) -> DeviceState {
        DeviceState(thermal: thermal, batteryLevel: level, isCharging: charging, isLowPowerMode: lowPower)
    }

    static func seen(_ seconds: TimeInterval, analysing: Bool = true, onScreen: Bool = true,
                     stage: AnalysisPipeline.Stage? = .content, completed: Int = 0,
                     _ device: DeviceState) -> BatteryStretchTracker.Observation {
        .init(now: t0.addingTimeInterval(seconds), analysing: analysing, onScreen: onScreen,
              stage: stage, completed: completed, device: device)
    }

    static func stretch(_ place: BatteryStretch.Place = .foreground, from start: Double?, to end: Double?,
                        photos: Int, charging: Bool = false, minutes: Double = 10) -> BatteryStretch {
        BatteryStretch(place: place, start: t0, end: t0.addingTimeInterval(minutes * 60),
                       startLevel: start, endLevel: end, charging: charging, photos: photos,
                       hottest: DeviceState.Thermal.nominal.rawValue, lowPower: false)
    }

    // MARK: Recording the stretches

    @Test func aRunInTheAppIsOneStretchWithItsPhotosAndLevels() {
        var tracker = BatteryStretchTracker()
        #expect(tracker.observe(Self.seen(0, completed: 2_431, Self.device(0.84))).isEmpty)
        #expect(tracker.observe(Self.seen(1, completed: 2_431, Self.device(0.84))).isEmpty)
        #expect(tracker.observe(Self.seen(60, completed: 2_600, Self.device(0.83, thermal: .fair))).isEmpty)
        #expect(tracker.observe(Self.seen(120, completed: 2_900, Self.device(0.82, lowPower: true))).isEmpty)
        let closed = tracker.observe(Self.seen(125, analysing: false, completed: 2_900, Self.device(0.82)))
        #expect(closed.count == 1)
        let s = closed[0]
        #expect(s.place == .foreground)
        #expect(s.start == Self.t0 && s.end == Self.t0.addingTimeInterval(125))
        #expect(s.startLevel == 0.84 && s.endLevel == 0.82)
        // The count a resumed run starts from is not this stretch's work.
        #expect(s.photos == 469)
        #expect(s.hottest == DeviceState.Thermal.fair.rawValue)
        #expect(s.lowPower)
        #expect(!s.charging)
        #expect(tracker.open == nil)
    }

    @Test func onlyTheImageStepCountsAsPhotos() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, stage: .places, completed: 0, Self.device(0.9)))
        _ = tracker.observe(Self.seen(30, stage: .places, completed: 1_600, Self.device(0.9)))
        // The image step begins with the photos analysed before (contentBefore): no jump counted.
        _ = tracker.observe(Self.seen(40, stage: .content, completed: 1_200, Self.device(0.9)))
        _ = tracker.observe(Self.seen(41, stage: .content, completed: 1_200, Self.device(0.9)))
        _ = tracker.observe(Self.seen(90, stage: .content, completed: 1_500, Self.device(0.89)))
        _ = tracker.observe(Self.seen(100, stage: .text, completed: 0, Self.device(0.89)))
        _ = tracker.observe(Self.seen(130, stage: .text, completed: 80, Self.device(0.89)))
        let s = tracker.observe(Self.seen(140, analysing: false, stage: .text, completed: 80, Self.device(0.89)))
        #expect(s.map(\.photos) == [300])
    }

    /// Second review: the app sets the stage and the count in two steps, so a reading can show
    /// the new step with the old step's count (places 6.000) before the image step's own count
    /// (13.990 analysed before). Only the photos after that count; nothing from the jump.
    @Test func aNewStepWithTheOldStepsCountAddsNothing() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, stage: .places, completed: 0, Self.device(0.9)))
        _ = tracker.observe(Self.seen(1, stage: .places, completed: 0, Self.device(0.9)))
        _ = tracker.observe(Self.seen(30, stage: .places, completed: 6_000, Self.device(0.9)))
        _ = tracker.observe(Self.seen(31, stage: .content, completed: 6_000, Self.device(0.9)))
        _ = tracker.observe(Self.seen(32, stage: .content, completed: 13_990, Self.device(0.9)))
        _ = tracker.observe(Self.seen(90, stage: .content, completed: 14_000, Self.device(0.89)))
        let ended = tracker.observe(Self.seen(91, analysing: false, stage: .content, completed: 14_000, Self.device(0.89)))
        #expect(ended.map(\.photos) == [10])
    }

    /// The same when the step's first count was replaced by a later one before it was read: the
    /// first photos are not counted, never the jump.
    @Test func aNewStepWhoseFirstCountWasMissedCountsFromItsSecond() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, stage: .places, completed: 0, Self.device(0.9)))
        _ = tracker.observe(Self.seen(1, stage: .places, completed: 6_000, Self.device(0.9)))
        _ = tracker.observe(Self.seen(2, stage: .content, completed: 6_000, Self.device(0.9)))
        _ = tracker.observe(Self.seen(3, stage: .content, completed: 13_995, Self.device(0.9)))
        _ = tracker.observe(Self.seen(60, stage: .content, completed: 14_000, Self.device(0.89)))
        let ended = tracker.observe(Self.seen(61, analysing: false, stage: .content, completed: 14_000, Self.device(0.89)))
        #expect(ended.map(\.photos) == [5])
    }

    /// A run (or the overnight refinement) starts with the last run's step and count still set,
    /// and sets its own a moment later: nothing of that counts.
    @Test func aRunStartingWithTheLastRunsCountAddsNothing() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, stage: .content, completed: 5_000, Self.device(0.9)))
        _ = tracker.observe(Self.seen(1, stage: .content, completed: 5_683, Self.device(0.9)))
        let ended = tracker.observe(Self.seen(60, analysing: false, stage: .content, completed: 5_683, Self.device(0.89)))
        #expect(ended.map(\.photos) == [0])
    }

    @Test func leavingTheScreenStartsABackgroundStretch() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, completed: 0, Self.device(0.8)))
        _ = tracker.observe(Self.seen(1, completed: 0, Self.device(0.8)))
        let first = tracker.observe(Self.seen(60, onScreen: false, completed: 100, Self.device(0.79)))
        #expect(first.map(\.place) == [.foreground])
        #expect(first.map(\.photos) == [100])
        _ = tracker.observe(Self.seen(100, onScreen: false, completed: 180, Self.device(0.78)))
        let second = tracker.observe(Self.seen(110, onScreen: true, completed: 200, Self.device(0.78)))
        #expect(second.map(\.place) == [.background])
        #expect(second.map(\.photos) == [100])
        #expect(second.first?.startLevel == 0.79)
        #expect(tracker.open?.stretch.place == .foreground)
    }

    @Test func aBreakForHeatOrBatteryEndsTheStretch() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, completed: 0, Self.device(0.5)))
        let closed = tracker.observe(Self.seen(60, analysing: false, completed: 50, Self.device(0.49)))
        #expect(closed.count == 1)
        // While it waits nothing is recorded.
        #expect(tracker.observe(Self.seen(600, analysing: false, completed: 50, Self.device(0.47))).isEmpty)
        #expect(tracker.open == nil)
    }

    @Test func pluggingInEndsTheStretchAtTheLastReadingWithoutPower() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, completed: 0, Self.device(0.6)))
        _ = tracker.observe(Self.seen(1, completed: 0, Self.device(0.6)))
        _ = tracker.observe(Self.seen(60, completed: 200, Self.device(0.58)))
        let closed = tracker.observe(Self.seen(70, completed: 230, Self.device(0.59, charging: true)))
        #expect(closed.count == 1)
        #expect(closed[0].endLevel == 0.58)
        #expect(closed[0].end == Self.t0.addingTimeInterval(60))
        #expect(closed[0].photos == 200)
        #expect(!closed[0].charging)
        // The part on power is a stretch of its own, which never counts.
        let charged = tracker.observe(Self.seen(150, analysing: false, completed: 600, Self.device(0.62, charging: true)))
        #expect(charged.map(\.charging) == [true])
        #expect(charged.map(\.photos) == [370])
    }

    /// iOS held the app (no background time): nothing was seen for minutes. The stretch ends
    /// where it was last seen, so time without analysis never counts.
    @Test func aLongSilenceEndsTheStretchWhereItWasLastSeen() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, onScreen: false, completed: 0, Self.device(0.7)))
        _ = tracker.observe(Self.seen(1, onScreen: false, completed: 0, Self.device(0.7)))
        _ = tracker.observe(Self.seen(30, onScreen: false, completed: 40, Self.device(0.7)))
        let closed = tracker.observe(Self.seen(3_600, onScreen: false, completed: 40, Self.device(0.55)))
        #expect(closed.count == 1)
        #expect(closed[0].end == Self.t0.addingTimeInterval(30))
        #expect(closed[0].endLevel == 0.7)
        // A new stretch starts at the new reading.
        #expect(tracker.open?.stretch.start == Self.t0.addingTimeInterval(3_600))
        #expect(tracker.open?.stretch.startLevel == 0.55)
    }

    @Test func closingEndsAtTheLastReading() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, onScreen: false, completed: 0, Self.device(0.7)))
        _ = tracker.observe(Self.seen(1, onScreen: false, completed: 0, Self.device(0.7)))
        _ = tracker.observe(Self.seen(45, onScreen: false, completed: 90, Self.device(0.69)))
        let closed = tracker.close()
        #expect(closed?.end == Self.t0.addingTimeInterval(45))
        #expect(closed?.photos == 90)
        #expect(tracker.open == nil)
        #expect(tracker.close() == nil)
    }

    @Test func aShortStretchWithoutPhotosIsNotKept() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, completed: 10, Self.device(0.7)))
        // "inactive" for a moment (Control Center): neither stretch holds anything.
        #expect(tracker.observe(Self.seen(2, onScreen: false, completed: 10, Self.device(0.7))).isEmpty)
        #expect(tracker.observe(Self.seen(3, onScreen: true, completed: 10, Self.device(0.7))).isEmpty)
    }

    /// A short stretch whose level moved is kept: its point belongs to the analysis' cost.
    @Test func aShortStretchWhoseLevelMovedIsKept() {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, completed: 10, Self.device(0.71)))
        let closed = tracker.observe(Self.seen(4, onScreen: false, completed: 10, Self.device(0.70)))
        #expect(closed.map(\.endLevel) == [0.70])
    }

    @Test func theTrackerSurvivesARelaunch() throws {
        var tracker = BatteryStretchTracker()
        _ = tracker.observe(Self.seen(0, onScreen: false, completed: 0, Self.device(0.7)))
        _ = tracker.observe(Self.seen(1, onScreen: false, completed: 0, Self.device(0.7)))
        _ = tracker.observe(Self.seen(30, onScreen: false, completed: 60, Self.device(0.69)))
        let data = try JSONEncoder().encode(tracker)
        var restored = try JSONDecoder().decode(BatteryStretchTracker.self, from: data)
        #expect(restored == tracker)
        // Opened again an hour later: the stretch iOS ended counts up to its last reading.
        let closed = restored.observe(Self.seen(3_600, completed: 60, Self.device(0.5)))
        #expect(closed.map(\.photos) == [60])
        #expect(closed.map(\.endLevel) == [0.69])
    }

    /// Second review: waiting for the device (heat, battery) or for Apple's place names is no
    /// analysis work; only a busy run counts.
    @Test func onlyABusyRunThatWaitsForNothingIsAnalysing() {
        #expect(BatteryStretchTracker.isAnalysing(running: true, waitingForDevice: false, waitingForApple: false))
        #expect(!BatteryStretchTracker.isAnalysing(running: true, waitingForDevice: true, waitingForApple: false))
        #expect(!BatteryStretchTracker.isAnalysing(running: true, waitingForDevice: false, waitingForApple: true))
        #expect(!BatteryStretchTracker.isAnalysing(running: false, waitingForDevice: false, waitingForApple: false))
    }

    /// Second review: at the cap, stretches without photos of the image step go first (short
    /// stretches of checks without new photos never push out the ones with photos).
    @Test func theCapDropsStretchesWithoutPhotosFirst() {
        let withPhotos = (0..<3).map { Self.stretch(from: 0.9, to: 0.89, photos: 100 + $0) }
        let without = (0..<3).map { _ in Self.stretch(from: 0.9, to: 0.9, photos: 0) }
        let list = [without[0], withPhotos[0], without[1], withPhotos[1], without[2], withPhotos[2]]
        #expect(BatteryStretch.capped(list, at: 4) == [withPhotos[0], withPhotos[1], without[2], withPhotos[2]])
        #expect(BatteryStretch.capped(list, at: 2) == [withPhotos[1], withPhotos[2]])
        #expect(BatteryStretch.capped(list, at: 10) == list)
    }

    // MARK: The number

    @Test func percentPerThousandPhotosForeachPlaceAndCombined() {
        let use = BatteryUse([
            Self.stretch(.foreground, from: 0.90, to: 0.86, photos: 2_000),
            Self.stretch(.background, from: 0.80, to: 0.77, photos: 2_500),
        ])
        #expect(use.foreground.estimate == .perThousand(2))
        #expect(use.background.estimate == .perThousand(1.2))
        // Weighted by photos, not the mean of the two.
        #expect(use.all.photos == 4_500)
        #expect(abs(use.all.drop - 7) < 1e-9)
        guard case .perThousand(let all) = use.all.estimate else { Issue.record("no number"); return }
        #expect(abs(all - 7.0 / 4.5) < 1e-9)
    }

    @Test func stretchesThatCannotBeTrustedDoNotCount() {
        let use = BatteryUse([
            Self.stretch(from: 0.91, to: 0.86, photos: 1_000),
            Self.stretch(from: 0.50, to: 0.60, photos: 900, charging: true),
            Self.stretch(from: nil, to: 0.41, photos: 900),
            Self.stretch(from: 0.42, to: nil, photos: 900),
            Self.stretch(from: 0.31, to: 0.21, photos: 0),
            Self.stretch(from: 0.21, to: 0.26, photos: 700),
        ])
        #expect(use.all.photos == 1_000)
        // The stretch without photos is work of the analysis too (below).
        #expect(use.all.stretches == 2)
        #expect(use.all.estimate == .perThousand(15))
        #expect(use.notCounted == [.charging: 1, .levelUnknown: 2, .levelRose: 1])
    }

    /// Reading the library, the places and the texts are part of what analysing costs: their
    /// battery counts, spread over the photos of the image step.
    @Test func workWithoutImagePhotosStillCosts() {
        let use = BatteryUse([
            Self.stretch(from: 0.93, to: 0.92, photos: 0),
            Self.stretch(from: 0.92, to: 0.88, photos: 1_000),
            Self.stretch(from: 0.88, to: 0.87, photos: 0),
        ])
        #expect(use.all.estimate == .perThousand(6))
        #expect(use.all.stretches == 3)
        // Without any photo there is still no number.
        #expect(BatteryUse([Self.stretch(from: 0.93, to: 0.83, photos: 0)]).all.estimate == .tooLittle)
    }

    @Test func aStretchWithoutDropCountsItsPhotos() {
        let use = BatteryUse([
            Self.stretch(from: 0.90, to: 0.87, photos: 600),
            Self.stretch(from: 0.87, to: 0.87, photos: 400),
        ])
        #expect(use.all.estimate == .perThousand(3))
    }

    @Test func tooFewPhotosOrTooLittleDropSaysSo() {
        // 3 points, but only 400 photos.
        #expect(BatteryUse([Self.stretch(from: 0.90, to: 0.87, photos: 400)]).all.estimate == .tooLittle)
        // 600 photos, but 2 points could be 1 or 3.
        #expect(BatteryUse([Self.stretch(from: 0.90, to: 0.88, photos: 600)]).all.estimate == .tooLittle)
        #expect(BatteryUse([]).all.estimate == .tooLittle)
        #expect(BatteryUse([]).foreground.photos == 0)
    }

    @Test func manyPhotosWithLittleDropGiveAnUpperBound() {
        // 4.000 photos for 2 points: about at most 3 points (each stretch can be a point off),
        // so about at most 0,75 % per 1.000.
        let use = BatteryUse([Self.stretch(from: 0.90, to: 0.88, photos: 4_000)])
        #expect(use.all.estimate == .aboutAtMost(0.75))
    }

    /// Some iPhones say the level only in 5-point steps: 5 points measured could be almost 0 or
    /// almost 10, so a number needs 10 points there.
    @Test func phonesWithFivePointStepsNeedMoreDrop() {
        let coarse = BatteryUse([
            Self.stretch(from: 0.85, to: 0.80, photos: 1_500),
            Self.stretch(.background, from: 0.75, to: 0.75, photos: 400),
        ])
        #expect(coarse.coarseSteps)
        #expect(coarse.all.estimate == .tooLittle)
        // The upper bound goes by the larger minimum too: under 10 points for 2.500 photos.
        #expect(BatteryUse([Self.stretch(from: 0.85, to: 0.80, photos: 2_500)]).all.estimate == .aboutAtMost(4))
        let enough = BatteryUse([Self.stretch(from: 0.85, to: 0.75, photos: 2_000)])
        #expect(enough.all.estimate == .perThousand(5))
        let fine = BatteryUse([Self.stretch(from: 0.85, to: 0.81, photos: 1_000)])
        #expect(!fine.coarseSteps)
        #expect(fine.all.estimate == .perThousand(4))
    }

    @Test func levelsAsUIDeviceGivesThemStillReadAsFivePointSteps() {
        // UIDevice reports a Float: 0.85 arrives as 0.8500000238418579.
        let use = BatteryUse([Self.stretch(from: Double(Float(0.85)), to: Double(Float(0.80)), photos: 900)])
        #expect(use.coarseSteps)
        #expect(abs(use.all.drop - 5) < 1e-4)
    }

    @Test func foregroundAndBackgroundAreJudgedApart() {
        let use = BatteryUse([
            Self.stretch(.foreground, from: 0.90, to: 0.86, photos: 2_000),
            Self.stretch(.background, from: 0.80, to: 0.79, photos: 300),
        ])
        #expect(use.foreground.estimate == .perThousand(2))
        #expect(use.background.estimate == .tooLittle)
        guard case .perThousand = use.all.estimate else { Issue.record("combined has enough"); return }
    }

    // MARK: Text

    @Test func numbersFollowTheLanguage() {
        let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")
        #expect(BatteryUse.number(1.84, locale: de) == "1,8")
        #expect(BatteryUse.number(1.84, locale: en) == "1.8")
        #expect(BatteryUse.number(2, locale: de) == "2")
        #expect(BatteryUse.count(4_200, locale: de) == "4.200")
        #expect(BatteryUse.count(4_200, locale: en) == "4,200")
    }

    @Test func theDetailLineForSupportHasCountsAndTheLastStretches() {
        let use = BatteryUse([
            Self.stretch(.foreground, from: 0.90, to: 0.86, photos: 2_000, minutes: 20),
            Self.stretch(.background, from: 0.80, to: 0.77, photos: 2_500, minutes: 30),
            Self.stretch(from: 0.50, to: 0.60, photos: 900, charging: true),
        ])
        let line = use.detail
        #expect(line.hasPrefix("battery stretches 3, counted 2 (foreground 1, background 1), not counted: charging 1"))
        #expect(line.contains("steps 1 point"))
        #expect(line.contains("fg 90→86 % 2000 photos 20 min"))
        #expect(line.contains("bg 80→77 % 2500 photos 30 min"))
        #expect(BatteryUse([]).detail == "battery stretches 0")
    }
}
