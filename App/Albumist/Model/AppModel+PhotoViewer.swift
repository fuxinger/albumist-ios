import Foundation
import AlbumistCore

/// What the photo view shows of a photo (design wave 2, DS-10): its place, day and time as the
/// title, as Photos shows them (`PhotoTitle`).
extension AppModel {
    /// The title of `id`: in the app's language (`proposalWords`, so the title never speaks
    /// another language than the bar around it), "Heute" by the day on the photo's clock, the
    /// time on `clock` (`deviceClock`). Without facts (not analysed yet) the date Photos keeps
    /// for it (`photo`, `PhotoBasics`) counts, on the clock its facts will have: without a
    /// location the home clock (`homeZone`, review D2, N10), with one the iPhone's.
    func photoTitle(for id: AssetID, photo: PhotoBasics?, homeZone: TimeZone?, clock: PhotoTitle.Clock,
                    now: Date = Date()) -> PhotoTitle {
        PhotoTitle(facts: factsByID[id], photoDate: photo?.date, photoLocated: photo?.isLocated ?? false, homeZone: homeZone,
                   now: now, currentZone: .current, words: proposalWords, clock: clock)
    }

    /// The clock the analysis tells photos without a place on (review P1-15): the home time
    /// zone it keeps (`AnalysisPipeline.homeTimeZone()`; the iPhone's at the first analysis, kept
    /// when the iPhone travels, the zone of the home once one is known). Nil before the first
    /// analysis kept one. For the title of a photo not analysed yet (review D2, N10).
    func homeTimeZone() async -> TimeZone? {
        guard let store, let identifier = try? await store.value(String.self, forKey: Self.homeTimeZoneKey) else { return nil }
        return TimeZone(identifier: identifier)
    }

    /// The key the analysis keeps the home time zone under (`AnalysisPipeline.Key.homeTimeZone`,
    /// internal to the engine; `PhotoViewerSourceTests` keeps the two the same).
    nonisolated static let homeTimeZoneKey = "user.homeTimeZone"

    /// 12 or 24 hours, as the iPhone is set (Settings › General › Date & Time, else its
    /// region's): the hour cycle of the current locale (review D, L2: before, it was read once
    /// per launch from a date format). The photo view keeps it and reads it again when the
    /// iPhone's settings change.
    nonisolated static func deviceClock(_ locale: Locale = .current) -> PhotoTitle.Clock {
        PhotoTitle.Clock(hourCycle: locale.hourCycle)
    }
}
