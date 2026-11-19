import Foundation

/// Everything the plan preview ("Vorschau") shows about one plan, worked out in one go.
///
/// The screen used to work these out in its body, again at every redraw: the summary, the
/// album list with folder paths, the conflict texts with album names, the free albums and,
/// on "Alben jetzt anlegen", the albums of the sorting show. Each walks over every step and
/// every photo of the plan, so a large plan cost that much at every frame of a keyboard or
/// scroll animation. The app now makes this once per plan and album list, off the main
/// thread, and the body only reads it (`PlanReviewView`).
public struct PlanReviewFacts: Hashable, Sendable {
    /// The plan these facts belong to.
    public var planID: SortlyID
    public var summary: PlanSummary
    /// Every album the plan creates or extends (`ChangePlan.albumPreview`).
    public var albums: [PlannedAlbumPreview]
    /// The plan's conflicts in plan order, each with the name of the album it is about.
    public var conflicts: [ResolvedConflict]
    /// A conflict stops the plan until the user decides again.
    public var isBlocking: Bool
    /// Albums the plan takes from the free allowance (`ChangePlan.freeAlbumUse(applied: false)`).
    public var freeAlbumUse: Int
    /// The plan has no steps.
    public var hasNoSteps: Bool
    /// The albums the plan fills, for the sorting show (`ChangePlan.filledAlbums`).
    public var filledAlbums: [FilledAlbum]

    /// `order`: suggestion ids in the order of the list the user chose from (see `albumPreview`).
    /// `ranks`: how well each photo suits a cover or the sorting show (`PreviewRank`).
    public init(plan: ChangePlan, inventory: CollectionInventory, order: [SortlyID] = [], ranks: [AssetID: PreviewRank] = [:]) {
        planID = plan.id
        summary = plan.summary
        albums = plan.albumPreview(inventory: inventory, order: order, ranks: ranks)
        conflicts = plan.conflicts.map { ResolvedConflict($0, inventory: inventory) }
        isBlocking = plan.conflicts.contains(where: \.isBlocking)
        freeAlbumUse = plan.freeAlbumUse(applied: false)
        hasNoSteps = plan.steps.isEmpty
        filledAlbums = plan.filledAlbums(inventory: inventory, ranks: ranks)
    }
}

/// A conflict with the current name of the album it names, so its text needs no inventory.
public struct ResolvedConflict: Hashable, Sendable {
    public var conflict: PlanConflict
    /// The title of the album the conflict is about, when it names one that is still there.
    public var albumTitle: String?

    public init(_ conflict: PlanConflict, inventory: CollectionInventory) {
        self.conflict = conflict
        switch conflict {
        case .albumMissing(let id), .albumNotEditable(let id), .albumChangedSincePreview(let id):
            albumTitle = inventory[id]?.title
        case .duplicatePlannedTitle, .titleExistsInFolder, .assetsUnavailable, .writeAccessMissing:
            albumTitle = nil
        }
    }
}

/// One album a plan fills, as the sorting show plays it.
public struct FilledAlbum: Hashable, Sendable {
    /// Index of the album's last "add photos" step: the album counts as done once that step is.
    public var lastStep: Int
    /// The planned title of a new album, or the current title of an existing one; nil when
    /// neither is known (the app says "Album").
    public var title: String?
    /// The photos the plan adds, over all of the album's steps, in plan order.
    public var assets: [AssetID]
    /// The photos the show lets fly and puts on the album's cover: at most `shownLimit` of
    /// `assets`, ordinary photos first, never a sensitive document (`PreviewPicker.firstSuited`).
    /// The show still counts every photo of `assets`.
    public var shown: [AssetID]

    /// More than the show ever shows of one album (the pile, five flying photos, the cover).
    public static let shownLimit = 6
}

extension ChangePlan {
    /// The albums the plan fills, in the order of their first "add photos" step. Chunked steps
    /// of one album are merged; steps that add nothing are left out. `ranks`: how well each
    /// photo suits the show (`PreviewRank`; missing ones are photos).
    public func filledAlbums(inventory: CollectionInventory, ranks: [AssetID: PreviewRank] = [:]) -> [FilledAlbum] {
        var titles: [String: String] = [:]
        for step in steps {
            if case .createAlbum(let key, let title, _) = step.operation { titles[key] = title }
        }
        var order: [AlbumRef] = []
        var lastStep: [AlbumRef: Int] = [:]
        var assets: [AlbumRef: [AssetID]] = [:]
        for (index, step) in steps.enumerated() {
            guard case .addAssets(let ref, let ids) = step.operation, !ids.isEmpty else { continue }
            if lastStep[ref] == nil { order.append(ref) }
            lastStep[ref] = index
            assets[ref, default: []].append(contentsOf: ids)
        }
        return order.map { ref in
            let title: String? = switch ref {
            case .planned(let key): titles[key]
            case .existing(let id): inventory[id]?.title
            }
            let photos = assets[ref] ?? []
            return FilledAlbum(lastStep: lastStep[ref] ?? 0, title: title, assets: photos,
                               shown: PreviewPicker.firstSuited(photos, count: FilledAlbum.shownLimit, ranks: ranks))
        }
    }
}
