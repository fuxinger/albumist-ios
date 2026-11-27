import Foundation

/// Per-area status of one asset plus derived overall status (prompt §6.1).
public struct AssetOrganizationState: Hashable, Sendable, Codable {
    public var assetID: AssetID
    public var areas: [OrganizationArea: AreaStatus]
    public var isUncertain: Bool
    /// The user ignored the photo (and did not exclude it). Every area of it says `.ignored` too;
    /// kept here as well because with every area turned off it has no area to say it in, and
    /// the photo still belongs in "Ignoriert" (finding N-01).
    public var isIgnored: Bool
    /// Excluded from the analysis; as `isIgnored`, also without any area.
    public var isExcluded: Bool

    public init(assetID: AssetID, areas: [OrganizationArea: AreaStatus] = [:], isUncertain: Bool = false,
                isIgnored: Bool = false, isExcluded: Bool = false) {
        self.assetID = assetID
        self.areas = areas
        self.isUncertain = isUncertain
        self.isIgnored = isIgnored
        self.isExcluded = isExcluded
    }

    private enum CodingKeys: String, CodingKey {
        case assetID, areas, isUncertain, isIgnored, isExcluded
    }

    /// A state encoded before `isIgnored` and `isExcluded` existed reads them as `false` (its
    /// areas still say "ignored" or "excluded"). Nothing stores states today; this keeps it so.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try c.decode(AssetID.self, forKey: .assetID)
        areas = try c.decode([OrganizationArea: AreaStatus].self, forKey: .areas)
        isUncertain = try c.decode(Bool.self, forKey: .isUncertain)
        isIgnored = try c.decodeIfPresent(Bool.self, forKey: .isIgnored) ?? false
        isExcluded = try c.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
    }
}

/// Facts the resolver needs about an asset in one area. Produced by the analysis layer.
public struct AreaFacts: Hashable, Sendable {
    /// The area does not apply (e.g. trips for a screenshot, places without location for chronology).
    public var applicable: Bool
    /// Analysis finished for this area.
    public var analyzed: Bool
    /// Analysis cannot run (no GPS for places, original unavailable, ...).
    public var analysisImpossible: Bool
    /// A user album that Albumist matched to the asset's proposal already holds it.
    public var inMatchingExistingAlbum: Bool
    /// A Albumist-applied, verified assignment exists.
    public var organizedByAlbumist: Bool
    /// An open proposal includes the asset.
    public var proposed: Bool
    /// Part of a confirmed but not yet executed plan.
    public var pendingInPlan: Bool
    /// Classification is contradictory or below the reliability needed.
    public var uncertain: Bool

    public init(
        applicable: Bool = true,
        analyzed: Bool = true,
        analysisImpossible: Bool = false,
        inMatchingExistingAlbum: Bool = false,
        organizedByAlbumist: Bool = false,
        proposed: Bool = false,
        pendingInPlan: Bool = false,
        uncertain: Bool = false
    ) {
        self.applicable = applicable
        self.analyzed = analyzed
        self.analysisImpossible = analysisImpossible
        self.inMatchingExistingAlbum = inMatchingExistingAlbum
        self.organizedByAlbumist = organizedByAlbumist
        self.proposed = proposed
        self.pendingInPlan = pendingInPlan
        self.uncertain = uncertain
    }
}

/// Derives organization states. The status depends on the *areas the user chose as primary*,
/// never on "is in any album" (prompt §6.1, Scenario M).
public struct OrganizationStatusResolver: Sendable {
    public var primaryAreas: Set<OrganizationArea>

    public init(primaryAreas: Set<OrganizationArea>) {
        self.primaryAreas = primaryAreas
    }

    public func areaStatus(_ facts: AreaFacts, ignored: Bool, excluded: Bool) -> AreaStatus {
        if excluded { return .excluded }
        if ignored { return .ignored }
        if !facts.applicable { return .notApplicable }
        if facts.organizedByAlbumist { return .organized }
        if facts.inMatchingExistingAlbum { return .preExisting }
        if facts.pendingInPlan { return .pendingConfirmation }
        if facts.analysisImpossible { return .analysisImpossible }
        if !facts.analyzed { return .analysisPending }
        if facts.proposed { return .proposed }
        return .unorganized
    }

    public func state(
        for assetID: AssetID,
        facts: [OrganizationArea: AreaFacts],
        ignored: Bool = false,
        excluded: Bool = false
    ) -> AssetOrganizationState {
        var areas: [OrganizationArea: AreaStatus] = [:]
        var uncertain = false
        for (area, f) in facts {
            areas[area] = areaStatus(f, ignored: ignored, excluded: excluded)
            if f.uncertain && f.applicable && primaryAreas.contains(area) { uncertain = true }
        }
        // As the areas say it: excluded comes first.
        return AssetOrganizationState(assetID: assetID, areas: areas, isUncertain: uncertain,
                                      isIgnored: ignored && !excluded, isExcluded: excluded)
    }

    /// The photo is excluded from the analysis. Read from the state and from every area, not only
    /// the main ones: the user's choice holds whatever counts, also with no main area counted or
    /// every area off (finding N-01).
    public static func isExcluded(_ state: AssetOrganizationState) -> Bool {
        state.isExcluded || state.areas.values.contains(.excluded)
    }

    /// The user ignored the photo (as `isExcluded`, whatever counts).
    public static func isIgnored(_ state: AssetOrganizationState) -> Bool {
        state.isIgnored || state.areas.values.contains(.ignored)
    }

    /// What `overall`, `isOutsideMainAreas` and `ringPart` read from a state, in one pass over
    /// its areas (`ringPart` asks both for every photo of the library). The main areas are those
    /// the state has: a state has only the areas that are on (`LibraryStatus`), so these are the
    /// counted main areas (`SortedCountCard.countedAreas`).
    private struct Reading {
        var excluded: Bool
        var ignored: Bool
        /// Main areas that apply (neither `.notApplicable` nor `.analysisImpossible`).
        var relevant = 0
        /// Of them, sorted (`.organized`, `.preExisting`).
        var done = 0
        /// Of them, one still `.analysisPending`.
        var pending = false
    }

    private func read(_ state: AssetOrganizationState) -> Reading {
        var r = Reading(excluded: state.isExcluded, ignored: state.isIgnored)
        for (area, status) in state.areas {
            if status == .excluded { r.excluded = true } else if status == .ignored { r.ignored = true }
            guard primaryAreas.contains(area), status != .notApplicable, status != .analysisImpossible else { continue }
            r.relevant += 1
            if status == .organized || status == .preExisting { r.done += 1 }
            if status == .analysisPending { r.pending = true }
        }
        return r
    }

    /// No main area applies to this photo, and the user did not ignore or exclude it. Also when
    /// no main area counts at all (none chosen, or the chosen ones turned off): there is nothing
    /// to sort towards, so no photo is open (finding N-01; the overview says "Kein Bereich zählt
    /// als sortiert"). Before, such a photo was "Nicht sortiert" in the lists and the photo info.
    public func isOutsideMainAreas(_ state: AssetOrganizationState) -> Bool {
        Self.isOutsideMainAreas(read(state))
    }

    private static func isOutsideMainAreas(_ r: Reading) -> Bool {
        !r.excluded && !r.ignored && r.relevant == 0
    }

    public func overall(_ state: AssetOrganizationState) -> OverallStatus {
        Self.overall(read(state))
    }

    private static func overall(_ r: Reading) -> OverallStatus {
        if r.excluded { return .excluded }
        if r.ignored { return .ignored }
        if r.relevant == 0 {
            // Nothing the user cares about applies – counts as organized, never as an open task.
            // Also with no main area counted (none chosen or none on): it was `.unorganized`
            // then, and every photo, ignored ones too, showed as "Nicht sortiert" next to "Kein
            // Bereich zählt als sortiert" (finding N-01). `ringPart` says `.outsideMainAreas`.
            return .fullyOrganized
        }
        if r.pending && r.done == 0 { return .pending }
        if r.done == r.relevant { return .fullyOrganized }
        return r.done > 0 ? .partiallyOrganized : .unorganized
    }

    /// Where a photo stands in the ring ("32 von 50 sortiert"). The one definition of "sorted"
    /// that the ring (`progress`) and the library's lists (`buckets`) both use, so the list
    /// "Sortiert" always holds exactly the ring's sorted photos and "Nicht sortiert" the rest of
    /// its total (Fable review P1-05, P1-06; decisions Fuchs 18.11.).
    public enum RingPart: Hashable, Sendable, CaseIterable {
        /// Counted, and sorted in every main area that applies.
        case sorted
        /// Counted: sorted in some main areas, not yet in others.
        case partlySorted
        /// Counted, nothing sorted yet.
        case unsorted
        /// Counted, its analysis is not done yet.
        case pending
        /// The user ignored it: neither sorted nor open, so not counted (decision Fuchs
        /// 18.11.: before, ignoring a photo made the ring smaller, and with ignored photos it
        /// never reached 100 %).
        case ignored
        /// Excluded from the analysis: not counted either.
        case excluded
        /// No main area applies (a photo from home when only places and trips count), or no
        /// main area counts at all (finding N-01).
        case outsideMainAreas
        /// Not in the part of the library the user chose ("Nur 2026").
        case outsideScope

        /// Part of the ring's total ("von y").
        public var isCounted: Bool {
            switch self {
            case .sorted, .partlySorted, .unsorted, .pending: true
            case .ignored, .excluded, .outsideMainAreas, .outsideScope: false
            }
        }
    }

    /// The photo's part of the ring. `inScope`: the photo is in the part of the library the
    /// ring counts (`OrganizationScope`); the ring only ever sees such photos.
    public func ringPart(_ state: AssetOrganizationState, inScope: Bool = true) -> RingPart {
        let reading = read(state)
        let status = Self.overall(reading)
        // The user's choice comes first: an ignored photo stays in "Ignoriert" wherever it is.
        if status == .excluded { return .excluded }
        if status == .ignored { return .ignored }
        if !inScope { return .outsideScope }
        if Self.isOutsideMainAreas(reading) { return .outsideMainAreas }
        switch status {
        case .fullyOrganized: return .sorted
        case .partiallyOrganized: return .partlySorted
        case .unorganized: return .unsorted
        case .pending: return .pending
        case .ignored: return .ignored
        case .excluded: return .excluded
        }
    }

    /// Inbox buckets an asset belongs to (an asset can be in "all" plus one more). "Sortiert"
    /// and "Nicht sortiert" follow the ring (`ringPart`): a photo the ring does not count (no
    /// main area applies, or outside the chosen part of the library) is only in "Alle".
    public func buckets(_ state: AssetOrganizationState, inScope: Bool = true) -> Set<InboxBucket> {
        var result: Set<InboxBucket> = [.all]
        switch ringPart(state, inScope: inScope) {
        case .excluded: result.insert(.excluded); return result
        case .ignored: result.insert(.ignored); return result
        case .sorted: result.insert(.organized)
        case .partlySorted, .unsorted, .pending: result.insert(.unorganized)
        case .outsideMainAreas, .outsideScope: break
        }
        let primary = state.areas.filter { primaryAreas.contains($0.key) }.map(\.value)
        if primary.contains(.proposed) || primary.contains(.pendingConfirmation) { result.insert(.suggestions) }
        if state.isUncertain { result.insert(.uncertain) }
        return result
    }

    /// Library-wide progress figures for the overview screen.
    public struct Progress: Hashable, Sendable {
        public init() {}
        /// The ring's "von y": sorted, partly sorted, unsorted and pending photos. Ignored and
        /// excluded photos are not part of it (decision Fuchs 18.11.), so the ring can reach
        /// 100 % once everything not ignored is sorted.
        public var total = 0
        public var fully = 0
        public var partially = 0
        public var unorganized = 0
        public var pending = 0
        /// Ignored by the user: not part of `total` (neither sorted nor open).
        public var ignored = 0
        /// Excluded from the analysis: not part of `total`.
        public var excluded = 0
        /// Photos none of the main areas applies to (a screenshot without a place when only
        /// places and trips count). Not part of `total`: "13 von 246 sortiert" before anything
        /// was done confused testers (Fuchs, 14.11.). With no main area counted, every photo
        /// neither ignored nor excluded (finding N-01), so `total` is 0 then.
        public var outsideMainAreas = 0
        /// Every photo the app sees.
        public var allPhotos: Int { total + outsideMainAreas + ignored + excluded }

        public var fullyShare: Double { total == 0 ? 0 : Double(fully) / Double(total) }

        /// The share the ring shows for `fraction` (`ProgressRing`, also for VoiceOver): below 1
        /// at most 0.99, so 199 of 200 reads "99 %", never "100 %" while a photo is open (second
        /// review of the one meaning of sorted, 18.11.: the percent format rounds to the nearest).
        public static func shownShare(_ fraction: Double) -> Double {
            fraction < 1 ? min(fraction, 0.99) : 1
        }
    }

    /// The ring over `states` (the photos in the part of the library it counts), each photo
    /// counted by its `ringPart`.
    public func progress<S: Sequence>(_ states: S) -> Progress where S.Element == AssetOrganizationState {
        var p = Progress()
        for s in states {
            let part = ringPart(s)
            if part.isCounted { p.total += 1 }
            switch part {
            case .sorted: p.fully += 1
            case .partlySorted: p.partially += 1
            case .unsorted: p.unorganized += 1
            case .pending: p.pending += 1
            case .ignored: p.ignored += 1
            case .excluded: p.excluded += 1
            case .outsideMainAreas: p.outsideMainAreas += 1
            case .outsideScope: break
            }
        }
        return p
    }
}
