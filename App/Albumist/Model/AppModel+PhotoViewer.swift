import Foundation
import AlbumistCore

/// What the photo view shows of a photo (design wave 2, DS-10): its place, day and time as the
/// title, as Photos shows them (`PhotoTitle`).
extension AppModel {
    /// The title of `id`: in the app's language (`proposalWords`, so the title never speaks
    /// another language than the bar around it), "Heute" by the day on the photo's clock, the
    /// time on `clock` (`deviceClock`). Without facts (not analysed yet) the date Photos keeps
    /// for it (`photoDate`, `PhotoBasics`) counts, on the iPhone's clock.
    func photoTitle(for id: AssetID, photoDate: Date?, clock: PhotoTitle.Clock, now: Date = Date()) -> PhotoTitle {
        PhotoTitle(facts: factsByID[id], photoDate: photoDate, now: now, currentZone: .current, words: proposalWords, clock: clock)
    }

    /// 12 or 24 hours, as the iPhone is set (Settings › General › Date & Time, else its
    /// region's): the hour cycle of the current locale (review D, L2: before, it was read once
    /// per launch from a date format). The photo view keeps it and reads it again when the
    /// iPhone's settings change.
    nonisolated static func deviceClock(_ locale: Locale = .current) -> PhotoTitle.Clock {
        PhotoTitle.Clock(hourCycle: locale.hourCycle)
    }
}
