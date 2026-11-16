import Foundation
import SortlyCore

/// Derives each asset's per-area status from facts, proposals and matches (prompt §6.1).
/// Only areas that actually apply to an asset count: a home photo is not "unsorted" just
/// because it belongs to no trip, and a screenshot never needs a place.
///
/// For "Länder und Orte" and "Reisen" an area applies only where Albumist has an album for the
/// photo: its own suggestion (shown or dismissed), or a suggestion whose album stands for it
/// (`StandIn`). Where Albumist makes no album on purpose, the area does not apply:
/// - photos taken where the user lives get no place album (decision Fuchs 15.11.: the home
///   town and its surroundings, not the whole home country),
/// - a trip with too few photos gets no album (`TripSettings.minPhotos`), a routine visit is no
///   trip of its own (its place's album stands for it when there is one), a country with too
///   few photos gets no album (`PlaceSettings.minPhotos`).
/// Before, such photos counted as unsorted for good, with nothing that could ever sort them.
public enum LibraryStatus {
    /// Why a photo with a place or a trip is left out of the ring.
    public enum NotCounted: Hashable, Sendable {
        /// Taken where the user lives: no place album.
        case home
        /// Albumist suggests no album for it (too few photos, a routine visit without a place album).
        case noAlbum
    }

    /// How the photos of the main areas came to count as sorted, or why an area does not count
    /// for them. The counts are photo-and-area pairs (a photo sorted for its place and its trip
    /// counts twice); `notCounted` is per photo.
    public struct Reasons: Hashable, Sendable {
        public init() {}
        /// In an own album that fits the photo's suggestion.
        public var ownAlbum = 0
        /// In the album of a suggestion that stands for the photo (a trip album for its country).
        public var standInAlbum = 0
        /// In an own album that fits a suggestion the user dismissed.
        public var dismissedAlbum = 0
        /// Albumist put the photo into an album for this area.
        public var byAlbumist = 0
        /// Taken where the user lives: no place album.
        public var home = 0
        /// No album on purpose (too few photos, a routine visit without a place album).
        public var noAlbum = 0
        /// Per photo for which a main area was left out by one of the two rules above (home first).
        public var notCounted: [AssetID: NotCounted] = [:]

        /// One line of the diagnostic report, in photo-and-area pairs: "sorted per area by own
        /// album 800, stand-in album 620, dismissed suggestion 0, Albumist 0; not counted home
        /// 1354, no album 12".
        public var line: String {
            "sorted per area by own album \(ownAlbum), stand-in album \(standInAlbum), dismissed suggestion \(dismissedAlbum), Albumist \(byAlbumist); not counted home \(home), no album \(noAlbum)"
        }
    }

    public static func compute(
        facts: [AssetFacts],
        snapshot: ProposalSnapshot?,
        settings: OrganizationSettings,
        overrides: OverrideSet = OverrideSet(),
        contentAnalyzed: Set<AssetID>,
        organizedBySortly: [OrganizationArea: Set<AssetID>] = [:],
        calendar: Calendar = .sortlyDefault
    ) -> [AssetID: AssetOrganizationState] {
        computeWithReasons(facts: facts, snapshot: snapshot, settings: settings, overrides: overrides,
                           contentAnalyzed: contentAnalyzed, organizedBySortly: organizedBySortly, calendar: calendar).states
    }

    /// Where an album that fits a photo came from.
    private enum Source: Int { case own, standIn, dismissed }

    public static func computeWithReasons(
        facts: [AssetFacts],
        snapshot: ProposalSnapshot?,
        settings: OrganizationSettings,
        overrides: OverrideSet = OverrideSet(),
        contentAnalyzed: Set<AssetID>,
        organizedBySortly: [OrganizationArea: Set<AssetID>] = [:],
        calendar: Calendar = .sortlyDefault
    ) -> (states: [AssetID: AssetOrganizationState], reasons: Reasons) {
        var proposedIn: [OrganizationArea: Set<AssetID>] = [:]
        var uncertainIn: [OrganizationArea: Set<AssetID>] = [:]
        /// Photos with an album in the area: a suggestion of their own, dismissed or standing in.
        var albumIn: [OrganizationArea: Set<AssetID>] = [:]
        var fitting: [Source: [OrganizationArea: [AssetID: Set<CollectionID>]]] = [:]

        func isUncertain(_ p: AlbumProposal) -> Bool { p.reliability < .likely || p.requiresUserName }
        func note(_ albums: Set<CollectionID>, _ source: Source, _ area: OrganizationArea, _ ids: some Sequence<AssetID>) {
            guard !albums.isEmpty else { return }
            for id in ids { fitting[source, default: [:]][area, default: [:]][id, default: []].formUnion(albums) }
        }
        let open = snapshot?.proposals ?? []
        let dismissed = snapshot?.dismissed ?? []
        for p in open {
            let area = p.kind.area
            proposedIn[area, default: []].formUnion(p.assetIDs)
            albumIn[area, default: []].formUnion(p.assetIDs)
            if isUncertain(p) { uncertainIn[area, default: []].formUnion(p.assetIDs) }
            note(fittingAlbums(snapshot?.matches[p.id], kind: p.kind, title: p.title), .own, area, p.assetIDs)
        }
        for p in dismissed {
            albumIn[p.kind.area, default: []].formUnion(p.assetIDs)
            note(fittingAlbums(snapshot?.matches[p.id], kind: p.kind, title: p.title), .dismissed, p.kind.area, p.assetIDs)
        }
        let openIDs = Set(open.map(\.id))
        let byID = Dictionary((open + dismissed).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for s in snapshot?.standIns ?? [] {
            guard let by = byID[s.suggestion] else { continue }
            albumIn[s.area, default: []].formUnion(s.assetIDs)
            if openIDs.contains(by.id) { proposedIn[s.area, default: []].formUnion(s.assetIDs) }
            if isUncertain(by) { uncertainIn[s.area, default: []].formUnion(s.assetIDs) }
            note(fittingAlbums(snapshot?.matches[by.id], kind: by.kind, title: by.title), .standIn, s.area, s.assetIDs)
        }

        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        let mediaTypes = MediaTypeClassifier()
        var result: [AssetID: AssetOrganizationState] = [:]
        result.reserveCapacity(facts.count)
        var reasons = Reasons()

        for f in facts {
            let analyzed = contentAnalyzed.contains(f.id)
            // With suggestions made for this photo's part of the library, a photo without an album
            // in places or trips has none on purpose. Not a photo taken after the suggestions were
            // made: back from a trip, its photos count as unsorted until the next analysis has
            // made their suggestions, instead of leaving the ring.
            let suggested = snapshot.map { snapshot in
                snapshot.scope.includes(f, calendar: calendar) && (f.asset.creationDate ?? .distantPast) <= snapshot.generatedAt
            } ?? false
            var areas: [OrganizationArea: AreaFacts] = [:]
            for area in settings.enabledAreas {
                var a = AreaFacts()
                let byAlbumist = organizedBySortly[area]?.contains(f.id) ?? false
                let hasAlbum = byAlbumist || (albumIn[area]?.contains(f.id) ?? false)
                var notCounted: WritableKeyPath<Reasons, Int>?
                switch area {
                case .places:
                    a.applicable = !f.asset.isScreenshotLike
                    a.analysisImpossible = f.asset.usableLocation == nil
                    a.analyzed = f.asset.usableLocation == nil || f.gpsPlace != nil
                    if a.applicable && !a.analysisImpossible && !hasAlbum {
                        if f.atHome {
                            a.applicable = false
                            notCounted = \.home
                        } else if suggested && a.analyzed {
                            a.applicable = false
                            notCounted = \.noAlbum
                        }
                    }
                case .trips:
                    a.applicable = f.tripID != nil
                    if a.applicable && suggested && !hasAlbum {
                        a.applicable = false
                        notCounted = \.noAlbum
                    }
                case .frequentPlaces: a.applicable = f.frequentPlaceID != nil
                case .chronology: a.applicable = f.asset.creationDate != nil
                case .mediaTypes: a.applicable = !mediaTypes.categories(for: f.asset).isDisjoint(with: settings.mediaTypes.categories)
                case .screenshots:
                    a.applicable = f.asset.isScreenshotLike
                    a.analyzed = analyzed
                case .imageCategories:
                    a.applicable = !analyzed || !f.categories.isEmpty
                    a.analyzed = analyzed
                case .documents:
                    a.applicable = f.document != nil
                case .messenger:
                    a.applicable = f.messenger != nil
                case .peopleAndPets:
                    a.applicable = !f.groupIDs.isEmpty
                }
                a.proposed = proposedIn[area]?.contains(f.id) ?? false
                a.uncertain = uncertainIn[area]?.contains(f.id) ?? false
                let source = [Source.own, .standIn, .dismissed].first { source in
                    guard let albums = fitting[source]?[area]?[f.id] else { return false }
                    return !albums.isDisjoint(with: f.albumIDs)
                }
                a.inMatchingExistingAlbum = source != nil
                a.organizedBySortly = byAlbumist
                areas[area] = a
                guard settings.primaryAreas.contains(area), !overrides.isIgnored(f.id), !overrides.isExcluded(f.id) else { continue }
                if let notCounted {
                    reasons[keyPath: notCounted] += 1
                    if notCounted == \.home {
                        reasons.notCounted[f.id] = .home
                    } else if reasons.notCounted[f.id] == nil {
                        reasons.notCounted[f.id] = .noAlbum
                    }
                } else if a.applicable, byAlbumist {
                    reasons.byAlbumist += 1
                } else if a.applicable, let source {
                    switch source {
                    case .own: reasons.ownAlbum += 1
                    case .standIn: reasons.standInAlbum += 1
                    case .dismissed: reasons.dismissedAlbum += 1
                    }
                }
            }
            result[f.id] = resolver.state(for: f.id, facts: areas, ignored: overrides.isIgnored(f.id), excluded: overrides.isExcluded(f.id))
        }
        return (result, reasons)
    }

    /// The albums that make a suggestion's photos count as sorted (`AlbumMatcher.sortingAlbums`):
    /// a certain match, or with several matching albums those that are mostly this suggestion.
    /// A possible match and a read-only album (a smart album such as Favourites) never count.
    static func fittingAlbums(_ match: MatchResult?, kind: ProposalKind, title: String? = nil) -> Set<CollectionID> {
        AlbumMatcher().sortingAlbums(match, kind: kind, title: title)
    }

    /// Photos with a place or a trip that the ring leaves out (the line under the ring).
    public struct LeftOut: Hashable, Sendable {
        public init(home: Int = 0, noAlbum: Int = 0) {
            self.home = home
            self.noAlbum = noAlbum
        }
        /// Taken at home.
        public var home: Int
        /// Albumist suggests no album for them.
        public var noAlbum: Int
    }

    /// The photos among `states` that the ring leaves out by the two rules of `Reasons`.
    public static func leftOut(_ states: some Sequence<AssetOrganizationState>, reasons: Reasons,
                               resolver: OrganizationStatusResolver) -> LeftOut {
        var result = LeftOut()
        for state in states where resolver.isOutsideMainAreas(state) {
            switch reasons.notCounted[state.assetID] {
            case .home?: result.home += 1
            case .noAlbum?: result.noAlbum += 1
            case nil: break
            }
        }
        return result
    }

    /// The photos Albumist put into albums and that are still there, per area of the suggestion
    /// each album was made or extended for (prompt §6.1 "Organisiert"). The area comes from the
    /// suggestion in the snapshot (shown, dismissed, or left out with a stand-in); an album whose
    /// suggestion is unknown counts through the album matching alone.
    public static func organizedBySortly(_ managed: [ManagedAlbumState], inventory: CollectionInventory,
                                         snapshot: ProposalSnapshot?) -> [OrganizationArea: Set<AssetID>] {
        guard let snapshot else { return [:] }
        var areaOf: [SortlyID: OrganizationArea] = [:]
        for s in snapshot.standIns { if let dropped = s.dropped { areaOf[dropped] = s.area } }
        for p in snapshot.dismissed + snapshot.proposals { areaOf[p.id] = p.kind.area }
        var result: [OrganizationArea: Set<AssetID>] = [:]
        for state in managed {
            guard let album = inventory[state.albumID] else { continue }
            let ours = state.addedBySortly.intersection(album.assetIDs)
            guard !ours.isEmpty else { continue }
            for source in state.allSourceIDs {
                if let area = areaOf[source] { result[area, default: []].formUnion(ours) }
            }
        }
        return result
    }
}
