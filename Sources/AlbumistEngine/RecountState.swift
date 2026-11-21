import Foundation
import AlbumistCore
import AlbumistStore

/// The ring's last count, shown in its place while the count is made anew ("Wird neu gezählt ·
/// Zuletzt 1.234 von 2.000 sortiert", `OverviewView`), so the sorted count never falls step by
/// step on the way:
/// - after "Analyse neu aufbauen", which removes the suggestions through which photos in the
///   user's own albums count: until the first new suggestions or the end of the analysis
///   (device test 15.11., "Und oben null");
/// - while photos analysed before "Themen" or "Dokumente" became a main area get their image
///   labels: a photo sorted by its trip that gets a theme needs a theme album from then on, and
///   the sorted count fell photo by photo while the labels came in (third review of the labels
///   fix, finding 2; Fuchs: no number goes back). Begins when the count would fall because of
///   the labels, with the count on screen then; held until every such photo was looked at once
///   (`DerivedLibraryStatus.labelsUntried`), or a run went through with the labels asked for. A
///   photo whose labels could not be read yet waits for its retry without holding the ring.
///   A fall with another cause (a sorted photo left its album in Photos, the main areas changed)
///   is shown as it is, also while labels are still to come (app-speed 18.11.2026, open point B
///   of the labels fix): only as many photos can fall because of their labels as were looked at
///   for them since the count on screen, each moving only itself.
///
/// After either, the ring shows the new count. It can be lower than the one held: it counts
/// what the main areas ask for now (a photo with a theme also needs its theme album); after the
/// labels, the overview then says why once (`LowerNote`).
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
    /// - `shownLabels`: the photos waiting for labels when `shown` was counted
    ///   (`LabelsWaiting`); `nil` before the first status.
    /// - `newSuggestions`: suggestions of a full run exist (not the early set of a first run).
    /// - `ended`: the last run's report while no run is busy; `nil` while one is, while the
    ///   analysis is being rebuilt, and before the first run after a launch.
    public static func next(_ current: RecountState?, shown: OrganizationStatusResolver.Progress, shownLabels: LabelsWaiting?,
                            derived: DerivedLibraryStatus, settings: OrganizationSettings, newSuggestions: Bool,
                            ended: AnalysisPipeline.Report?) -> RecountState? {
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
        // Begins when the sorted count would fall because of the labels, with the count on
        // screen: while it does not, the ring shows its own (nothing shown yet after a launch:
        // the next status is compared).
        guard labelsPending, shown.total > 0, derived.progress.fully < shown.fully,
              fallsForLabels(shown: shown, shownLabels: shownLabels, derived: derived) else { return nil }
        return RecountState(fully: shown.fully, total: shown.total, labels: true)
    }

    /// The photos waiting for labels at one count: not looked at yet (`labelsUntried`), and all
    /// still without them, those waiting for a retry included (`labelsMissing`).
    public struct LabelsWaiting: Sendable, Equatable {
        public var untried: Int
        public var missing: Int

        public init(untried: Int, missing: Int) {
            self.untried = untried
            self.missing = missing
        }

        public init(_ derived: DerivedLibraryStatus) {
            self.init(untried: derived.labelsUntried, missing: derived.labelsMissing)
        }
    }

    /// The fall from `shown` can come from the labels: photos were looked at for them since, and
    /// no more photos left "sortiert" than were looked at (a photo's labels move only that photo).
    /// Looked at: fewer not looked at yet, or fewer without labels (a photo waiting for its retry
    /// that got them now is no longer missing, though it was never "untried"; second review 3).
    /// A fall with nothing looked at, or a larger one, has another cause and is not held.
    static func fallsForLabels(shown: OrganizationStatusResolver.Progress, shownLabels: LabelsWaiting?,
                               derived: DerivedLibraryStatus) -> Bool {
        guard let shownLabels else { return false }
        let lookedAt = max(shownLabels.untried - derived.labelsUntried, shownLabels.missing - derived.labelsMissing)
        return lookedAt > 0 && shown.fully - derived.progress.fully <= lookedAt
    }

    /// Said once under the ring when the hold for the labels ended with a lower count than it
    /// held (app-speed 18.11.2026, open point A of the labels fix): "Neu gezählt: Zuvor waren es
    /// 1.234 sortiert. Die neue Zahl zählt alles, was sich seitdem geändert hat, etwa Fotos mit
    /// Themen oder Dokumenten, die jetzt auch ein passendes Album brauchen." Without it the ring
    /// came back lower with no word, which reads as a number going back. The words name the
    /// labels only as an example: a fall from another cause can be held with them (a photo
    /// ignored while the labels came in). Not when "Themen" and "Dokumente" no longer count
    /// (the user changed the main areas; that ended the hold). Kept until the user taps it away,
    /// the count is back at the number held, or a hold begins again (it says its own words).
    public struct LowerNote: Codable, Equatable, Sendable {
        /// The count the hold showed.
        public var held: Int

        public init(held: Int) {
            self.held = held
        }

        /// The note after a newly derived status: `before` and `after` are the hold until now
        /// and the one `RecountState.next` gave, `progress` the ring's own count now.
        public static func next(_ note: LowerNote?, before: RecountState?, after: RecountState?,
                                progress: OrganizationStatusResolver.Progress, settings: OrganizationSettings) -> LowerNote? {
            if after != nil { return nil }
            let counted = settings.primaryAreas.intersection(settings.enabledAreas)
            let labelsCount = counted.contains(.imageCategories) || counted.contains(.documents)
            if let before, before.isForLabels, labelsCount, progress.fully < before.fully { return LowerNote(held: before.fully) }
            guard let note, progress.fully < note.held else { return nil }
            return note
        }
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
    public static func photosWaitingForLabels(in store: AlbumistStore, settings: OrganizationSettings) async throws
        -> (missing: Set<AssetID>, retrying: Set<AssetID>) {
        guard wantsLabels(settings) else { return ([], []) }
        let missing = try await store.unlabelledAssets(version: contentVersion, labelsVersion: labelsVersion)
        guard !missing.isEmpty else { return ([], []) }
        return (missing, try await store.unlabelledAssets(version: contentVersion, labelsVersion: labelsVersion, withResult: "labels"))
    }
}
