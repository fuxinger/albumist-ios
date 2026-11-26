import Foundation
import AlbumistCore
import AlbumistMap

// What the playback's screen shows (TripPlaybackModel): the day's title and date, the photos beside
// the dot, the bar's day ticks and the end card's summary, all worked out from the plan and the
// state the model publishes.

extension TripPlaybackModel {
    var isRunning: Bool { state == .playing || state == .waitingForTiles || state == .slideshowDay }

    /// "Tag 3 von 9 · Skógafoss" (the dragged-to day while the bar is dragged).
    var title: String {
        if let previewDay {
            return PlaybackText.dayTitle(index: previewDay, of: plan.days.count, place: placeName(playbackDay(previewDay)?.placeIndex))
        }
        return PlaybackText.dayTitle(index: dayIndex, of: plan.days.count, place: placeName(titlePlaceIndex))
    }

    /// "Mittwoch, 14. Juni 2023": the day as the clocks where the photos were taken saw it.
    var dateText: String {
        guard let shown = playbackDay(previewDay ?? dayIndex) else { return "" }
        return PlaybackText.date(shown.day)
    }

    /// The photos beside the dot now.
    var stack: [AssetID?] { stackIDs(for: stackPlaceIndex) }

    /// "+46": the day's photos beyond those in the stack.
    var moreText: String? {
        guard let shown = playbackDay(dayIndex) else { return nil }
        return PlaybackText.more(dayPhotos: shown.photoCount, shown: Self.stackSize)
    }

    /// Where each day after the first starts on the bar, 0 to 1.
    var dayFractions: [Double] {
        guard plan.duration > 0 else { return [] }
        return plan.days.dropFirst().map { $0.start / plan.duration }
    }

    /// "9 Tage · 412 Fotos · ca. 1.000 km vor Ort" for the end card.
    var summary: String { PlaybackText.summary(of: trip) }

    /// A place's photos (at most three) when photos are shown and it has some, else three quiet
    /// tiles (`nil`).
    func stackIDs(for placeIndex: Int?) -> [AssetID?] {
        if showsPhotos, let placeIndex, trip.geometry.places.indices.contains(placeIndex) {
            let ids = trip.geometry.places[placeIndex].coverCandidates.prefix(Self.stackSize)
            if !ids.isEmpty { return ids.map { Optional($0) } }
        }
        return Array(repeating: nil, count: Self.stackSize)
    }

    private func placeName(_ index: Int?) -> String? {
        guard let index, trip.geometry.places.indices.contains(index) else { return nil }
        return trip.geometry.places[index].name
    }

    private func playbackDay(_ index: Int) -> PlaybackDay? {
        plan.days.indices.contains(index) ? plan.days[index] : nil
    }
}
