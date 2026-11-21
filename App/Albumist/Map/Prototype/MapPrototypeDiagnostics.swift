import Foundation
import AlbumistMap

/// The map prototype's part of the diagnostic report (concept 2.0 §9: "Der Diagnosebericht
/// schreibt mit"): the latest 60-second test of each view, the altitude check of the photos and
/// the map summary of the user's own trips with its build time. Kept as JSON in the user
/// defaults, so a test made before a relaunch is still in the report the owner sends.
///
/// Counts and times only (`MapMeasurements.lines`, `MapDiagnostics.lines`): no coordinate, no
/// place, trip or country name, no country code. Empty until the prototype measured something.
enum MapPrototypeDiagnostics {
    private static let resultsKey = "mapPrototype.results"
    private static let altitudeKey = "mapPrototype.altitudeCheck"
    private static let summaryKey = "mapPrototype.summaryLines"

    /// The lines for `AppModel.diagnosticReport`.
    static func lines() -> [String] {
        let measured = MapMeasurements.lines(results: storedResults(), altitude: storedAltitude())
        let summary = load([String].self, summaryKey) ?? []
        return measured + summary
    }

    /// The latest test of each view, one per view.
    static func storedResults() -> [MapMeasurements.TestResult] {
        load([MapMeasurements.TestResult].self, resultsKey) ?? []
    }

    static func storedAltitude() -> MapMeasurements.AltitudeCheck? {
        load(MapMeasurements.AltitudeCheck.self, altitudeKey)
    }

    /// Keeps `result` as its view's latest test.
    static func store(_ result: MapMeasurements.TestResult) {
        var results = storedResults().filter { $0.source != result.source }
        results.append(result)
        save(results, resultsKey)
    }

    static func store(_ altitude: MapMeasurements.AltitudeCheck) {
        save(altitude, altitudeKey)
    }

    /// The summary of the user's own trips as the report has it (`MapDiagnostics`: counts and
    /// the build time).
    static func store(summary: MapSummary, buildMilliseconds: Int) {
        save(MapDiagnostics.lines(for: summary, buildMilliseconds: buildMilliseconds), summaryKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save(_ value: some Encodable, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
