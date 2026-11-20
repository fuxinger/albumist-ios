import Foundation
import SortlyCore

/// Suggestions the user chose (accepted, not created yet) before a change in "Dein Zuhause"
/// would have changed or dropped them. A change of home never changes what the user already
/// chose: such a suggestion keeps the content it had when it was chosen, in this and every
/// later run, until it is created, deselected, or the suggestions give it back unchanged.
/// Store key `user.heldSuggestions`.
public enum HeldSuggestions {
    /// `held` with the suggestions of `before` that the user chose and that `new` would change
    /// or drop. A suggestion held already keeps the version it was chosen in.
    public static func adding(_ before: [AlbumProposal], to held: [AlbumProposal], decisions: [SortlyID: ProposalDecision],
                              new: Suggestions) -> [AlbumProposal] {
        var result = held
        var heldIDs = Set(held.map(\.id))
        let newByID = Dictionary((new.open + new.dismissed).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for p in before where decisions[p.id]?.isAccepted == true && !heldIDs.contains(p.id) && newByID[p.id] != p {
            result.append(p)
            heldIDs.insert(p.id)
        }
        return result
    }

    /// Puts the held suggestions that are still chosen into `suggestions` in place of their new
    /// version (or back, when they are gone). Returns those still held: one that is no longer
    /// chosen, or that the suggestions now make exactly as it was chosen, is let go.
    /// Photos no longer in `library` (deleted in Photos, or a backup restored on another
    /// iPhone) leave a held suggestion; one with none of its photos left is let go.
    /// `inView`: the photos that may be shown, when fewer than `library` (under "Ausgewählte
    /// Fotos" the others are set aside, review P1-07): the suggestion keeps them and is shown
    /// with the shared ones only, or not at all with none shared.
    public static func apply(_ held: [AlbumProposal], decisions: [SortlyID: ProposalDecision], library: Set<AssetID>,
                             inView: Set<AssetID>? = nil, to suggestions: inout Suggestions) -> [AlbumProposal] {
        var still: [AlbumProposal] = []
        for var p in held where decisions[p.id]?.isAccepted == true {
            p.assetIDs.formIntersection(library)
            p.optionalAssetIDs.formIntersection(library)
            guard !p.assetIDs.isEmpty else { continue }
            p.coverAssetID = cover(of: p)
            var shown = p
            if let inView {
                shown.assetIDs.formIntersection(inView)
                shown.optionalAssetIDs.formIntersection(inView)
                shown.coverAssetID = cover(of: shown)
            }
            if let i = suggestions.open.firstIndex(where: { $0.id == p.id }) {
                if suggestions.open[i] == p { continue }
                if shown.assetIDs.isEmpty { suggestions.open.remove(at: i) } else { suggestions.open[i] = shown }
            } else {
                suggestions.dismissed.removeAll { $0.id == p.id }
                if !shown.assetIDs.isEmpty { suggestions.open.append(shown) }
            }
            still.append(p)
        }
        return still
    }

    /// The cover of `p`, or its first photo when the cover left it.
    private static func cover(of p: AlbumProposal) -> AssetID? {
        guard let cover = p.coverAssetID, !p.assetIDs.contains(cover), !p.optionalAssetIDs.contains(cover) else { return p.coverAssetID }
        return p.assetIDs.min()
    }
}

/// A change in "Dein Zuhause" (or of the places the user is often at) that no suggestions were
/// made for yet (store key `analysis.pendingHomeChange`). Stored in the same transaction as the
/// change itself, and removed in the same transaction as the first suggestions made after it,
/// whichever step makes them: `AnalysisPipeline.resuggest()`, a run that got the lock first, or
/// the next launch's run when the app was ended in between. Each of them holds what the user
/// chose (`HeldSuggestions`) and tells the overview (`HomeChangeNotice`) against `before`.
/// Under `analysis.*`: "Analyse neu aufbauen" starts over and has nothing to compare with.
public struct PendingHomeChange: Sendable, Codable {
    /// The suggestions before the first change that is not applied yet.
    public var before: ProposalSnapshot
    public var date: Date

    public init(before: ProposalSnapshot, date: Date) {
        self.before = before
        self.date = date
    }
}

/// What a change in "Dein Zuhause" did to the suggestions, for the overview until the user taps
/// OK (store key `user.homeChangeNotice`). Counted against the suggestions before the first
/// change since the last OK, so changing back and forth does not count twice.
public struct HomeChangeNotice: Hashable, Sendable, Codable {
    /// Suggestions shown before the first change (the baseline), with their titles.
    public var shownBefore: [SortlyID: String]
    /// Suggestions shown or dismissed before the first change.
    public var knownBefore: Set<SortlyID>
    /// Suggestions shown before that are gone now.
    public var removed: Int
    /// Up to three of their titles, for the card.
    public var removedTitles: [String]
    /// Suggestions that are new.
    public var added: Int
    /// Suggestions the user had chosen that stay as they were chosen.
    public var held: Int
    public var date: Date

    /// Titles kept for the card.
    static let titleCount = 3

    public init(before: ProposalSnapshot, after: ProposalSnapshot, held: Set<SortlyID>, date: Date) {
        let shown = Dictionary(before.proposals.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        self.init(shownBefore: shown, knownBefore: Set(shown.keys).union(before.dismissed.map(\.id)), after: after, held: held, date: date)
    }

    init(shownBefore: [SortlyID: String], knownBefore: Set<SortlyID>, after: ProposalSnapshot, held: Set<SortlyID>, date: Date) {
        self.shownBefore = shownBefore
        self.knownBefore = knownBefore
        let present = Set(after.proposals.map(\.id)).union(after.dismissed.map(\.id))
        let gone = Set(shownBefore.keys).subtracting(present)
        removed = gone.count
        removedTitles = Array(gone.compactMap { shownBefore[$0] }.sorted().prefix(Self.titleCount))
        added = Set(after.proposals.map(\.id)).subtracting(knownBefore).count
        self.held = held.intersection(shownBefore.keys).count
        self.date = date
    }

    /// A second change before the user tapped OK: counted against the same baseline.
    public func followed(by after: ProposalSnapshot, held: Set<SortlyID>, date: Date) -> HomeChangeNotice {
        HomeChangeNotice(shownBefore: shownBefore, knownBefore: knownBefore, after: after, held: held, date: date)
    }

    /// Nothing to say: no suggestion went, came or was held.
    public var isEmpty: Bool { removed == 0 && added == 0 && held == 0 }
}
