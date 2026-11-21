import Foundation
import AlbumistCore
import AlbumistEngine
import AlbumistMap
import AlbumistStore

extension AppModel {
    /// The map summary of the user's own trips (stored trips + facts + home settings), made off
    /// the main thread, and how long `MapSummary.build` took. Nil when there is no store yet.
    ///
    /// For the map prototype (concept 2.0 §13, wave 0): made when the page asks, not stored.
    /// The trips are those the last analysis stored; while an analysis runs the summary says so
    /// (its numbers are preliminary).
    func mapPrototypeSummary() async -> (summary: MapSummary, milliseconds: Int)? {
        guard let store else { return nil }
        let trips = (try? await AnalysisPipeline.storedTrips(in: store)) ?? []
        let input = MapInput(facts: facts, trips: trips, homeSettings: homeSettings, detectedHome: detectedHome,
                             analysisRunning: analysis.isRunning)
        return await Task.detached(priority: .userInitiated) { () -> (summary: MapSummary, milliseconds: Int) in
            let clock = ContinuousClock()
            let started = clock.now
            let summary = MapSummary.build(input)
            let elapsed = clock.now - started
            let milliseconds = Int((elapsed / .milliseconds(1)).rounded())
            return (summary: summary, milliseconds: milliseconds)
        }.value
    }
}
