import Foundation
import AlbumistCore

/// What the result's stack of covers knows of the suggestions a plan came from (draft E3,
/// `ResultCoverStack`), taken as the plan starts (`AppModel.resultCoverSources`): the cover each
/// one's card showed, and the ones that are personal (a sensitive suggestion, one whose card
/// hides its preview, or one the analysis does not know), whose albums and photos stay off the
/// stack.
struct ResultCoverSources: Equatable {
    let plan: AlbumistID
    var covers: [AlbumistID: AssetID] = [:]
    var personal: Set<AlbumistID> = []
}

/// What the moments of design wave 2 need from the model (Scheibe 3): the covers the result lays
/// on its stack after a run (draft E3, `ResultCoverStack`). Kept apart from `AppModel.swift`.
extension AppModel {
    /// The albums Albumist made (its records): the result never calls them the user's own
    /// ("deiner Alben", `ResultHeadline`).
    var albumistAlbums: Set<CollectionID> {
        Set(managedAlbums.lazy.filter(\.createdByAlbumist).map(\.albumID))
    }

    /// What the stack must know of the suggestions `plan` came from, taken as it starts: the
    /// analysis may make its suggestions anew before the result shows. Personal: a sensitive
    /// suggestion, one whose card hides its preview, and one the analysis does not know
    /// (`ResultCoverStack.personalSources`: a retry or a plan of suggestions made anew keeps their
    /// old ids, a plan made by hand has one of its own).
    func resultCoverSources(for plan: ChangePlan) -> ResultCoverSources {
        let sources = Set(plan.steps.lazy.compactMap(\.sourceID))
        var taken = ResultCoverSources(plan: plan.id)
        var known = Set<AlbumistID>()
        var personal = Set<AlbumistID>()
        for proposal in proposals where sources.contains(proposal.id) {
            known.insert(proposal.id)
            if proposal.isSensitive || previewHidden(for: proposal) {
                personal.insert(proposal.id)
            } else if let cover = proposalCoverIDs(for: proposal).first {
                taken.covers[proposal.id] = cover
            }
        }
        taken.personal = ResultCoverStack.personalSources(of: plan, known: known, personal: personal)
        return taken
    }

    /// The covers the result after `plan` lays on its stack: which albums and which of their photos
    /// to try (`ResultCoverStack`), with the photos' ranks (never a sensitive document), dates and
    /// favourites, the cover each suggestion's card showed, and the personal suggestions, whose
    /// albums and photos stay off the stack. `taken`: what was known of the suggestions as the
    /// plan started; without it (another screen ran the plan) they are looked at now, by the same
    /// rule. `expected`: before the run, from what the plan sets out to do, so the covers load
    /// while it runs.
    func resultCoverStack(for plan: ChangePlan, taken: ResultCoverSources?, expected: Bool = false) -> ResultCoverStack {
        let sources: ResultCoverSources
        if let taken, taken.plan == plan.id {
            sources = taken
        } else {
            sources = resultCoverSources(for: plan)
        }
        let facts = factsByID
        var favorites = Set<AssetID>()
        for step in plan.steps {
            guard case .addAssets(_, let assets) = step.operation else { continue }
            for id in assets where facts[id]?.asset.isFavorite == true { favorites.insert(id) }
        }
        return ResultCoverStack(plan: plan, ranks: previewRanks, dates: creationDates, favorites: favorites,
                                covers: sources.covers, personalSources: sources.personal, expected: expected)
    }
}
