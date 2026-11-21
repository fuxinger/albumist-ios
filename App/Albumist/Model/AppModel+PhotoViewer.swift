import Foundation
import AlbumistCore

/// What the photo view shows of a photo (design wave 2, DS-10): its place, day and time as the
/// title, as Photos shows them (`PhotoTitle`).
extension AppModel {
    /// The title of `id`: in the app's language (`proposalWords`, so the title never speaks
    /// another language than the bar around it), "Heute" by the iPhone's day and time zone, the
    /// time on the iPhone's clock setting.
    func photoTitle(for id: AssetID, now: Date = Date()) -> PhotoTitle {
        PhotoTitle(facts: factsByID[id], now: now, currentZone: .current, words: proposalWords, clock: Self.deviceClock)
    }

    /// 12 or 24 hours, as the iPhone is set (Settings › General › Date & Time, or the region's
    /// own): the "j" template asks for the hour as the user wants it. Read once per launch:
    /// the template lookup is slow, and the photo view asks for a title on every frame of a pull.
    static let deviceClock: PhotoTitle.Clock = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current) ?? ""
        return format.contains("a") ? .twelveHour : .twentyFourHour
    }()
}
