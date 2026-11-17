import Foundation
import SortlyCore
import SortlyStore

/// The ring's last count, shown in its place while the count is made anew ("Wird neu gezählt ·
/// Zuletzt 1.234 von 2.000 sortiert", `OverviewView`), so the sorted count never falls step by
/// step on the way:
/// - after "Analyse neu aufbauen", which removes the suggestions through which photos in the
///   user's own albums count: until the first new suggestions or the end of the analysis
///   (device test 15.11., "Und oben null");
/// - while photos analysed before "Themen" or "Dokumente" became a main area get their image
///   labels: a photo sorted by its trip that gets a theme needs a theme album from then on, and
///   the sorted count fell photo by photo while the labels came in (third review of the labels
///   fix, finding 2; Fuchs: no number goes back). Begins when the count would fall, with the
///   count on screen then; held until every such photo was looked at once
///   (`DerivedLibraryStatus.labelsUntried`), or a run went through with the labels asked for. A
///   photo whose labels could not be read yet waits for its retry without holding the ring.
///
/// After either, the ring shows the new count. It can be lower than the one held: it counts
/// what the main areas ask for now (a photo with a theme also needs its theme album).
public struct RecountState: Codable, Equatable, Sendable {
    public var fully: Int
    public var total: Int
    /// Held for the labels of the new areas. `nil`: "Analyse neu aufbauen" (and what earlier
    /// versions stored, which knew only that one).
    public var labels: Bool?

    public init(fully: Int, total: Int, labels: Bool? = nil) {
        self.fully = fully
        self.total = total
        self.labels = labels
    }

    /// Held while the photos analysed before get their labels (see above).
    public var isForLabels: Bool { labels == true }

    /// The hold after a newly derived status (`AppModel.assignDerived`).
    /// - `current`: the hold until now.
    /// - `shown`: the count on screen until now; held when a hold for the labels begins.
    /// - `newSuggestions`: suggestions of a full run exist (not the early set of a first run).
    /// - `ended`: the last run's report while no run is busy; `nil` while one is, while the
    ///   analysis is being rebuilt, and before the first run after a launch.
    public static func next(_ current: RecountState?, shown: OrganizationStatusResolver.Progress, derived: DerivedLibraryStatus,
                            settings: OrganizationSettings, newSuggestions: Bool, ended: AnalysisPipeline.Report?) -> RecountState? {
        let analysisDone = ended?.isComplete == true
        // A run went through with the labels asked for: each photo waiting for them was looked
        // at once. One the analyzer failed on last in that run has no attempt noted (no photo
        // after it showed the analyzer working) and would otherwise hold the ring for good.
        let labelsLookedAt = analysisDone && ended?.settingsUsed.labels == true
        let labelsPending = !labelsLookedAt && waitsForLabels(derived, settings: settings)
        if let held = current {
            if held.isForLabels { return labelsPending ? held : nil }
            // "Analyse neu aufbauen" goes on until the first new suggestions or the end of the
            // analysis. Labels still to come then: held on with the same count, for them.
            guard newSuggestions || analysisDone else { return held }
            return labelsPending ? RecountState(fully: held.fully, total: held.total, labels: true) : nil
        }
        // Begins when the sorted count would fall, with the count on screen: while it does not,
        // the ring shows its own (nothing shown yet after a launch: the next status is compared).
        guard labelsPending, shown.total > 0, derived.progress.fully < shown.fully else { return nil }
        return RecountState(fully: shown.fully, total: shown.total, labels: true)
    }

    /// Photos analysed before "Themen" or "Dokumente" was turned on wait for their first look for
    /// labels, and the ring counts one of the two (a main area that is on).
    public static func waitsForLabels(_ derived: DerivedLibraryStatus, settings: OrganizationSettings) -> Bool {
        let counted = settings.primaryAreas.intersection(settings.enabledAreas)
        return derived.labelsUntried > 0 && (counted.contains(.imageCategories) || counted.contains(.documents))
    }
}

extension AnalysisPipeline {
    /// The analysed photos still without their image labels, and of them those whose labels
    /// could not be read yet (a failed try is noted, `LabelAttempts`): for the overview
    /// (`DerivedLibraryStatus.derive`). Both empty while neither "Themen" nor "Dokumente" is on,
    /// and once the labels are caught up (second review of the labels fix, 11).
    public static func photosWaitingForLabels(in store: SortlyStore, settings: OrganizationSettings) async throws
        -> (missing: Set<AssetID>, retrying: Set<AssetID>) {
        guard wantsLabels(settings) else { return ([], []) }
        let missing = try await store.unlabelledAssets(version: contentVersion, labelsVersion: labelsVersion)
        guard !missing.isEmpty else { return ([], []) }
        return (missing, try await store.unlabelledAssets(version: contentVersion, labelsVersion: labelsVersion, withResult: "labels"))
    }
}
