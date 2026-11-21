import Foundation

/// "Anlegen" on a suggestion's card makes its album at once, without the preview, and a banner
/// "„Name“ angelegt · Widerrufen" can take it back (design decision 7B). It is the preview's own
/// plan and run: the planner, the executor with its journal, the free albums, the history and
/// its undo. These rules say which suggestions and plans may skip the preview, which name the
/// banner says, how a run ended for the banner, and how long the banner stays.
public enum QuickCreate {
    /// Whether a tap on "Anlegen" may make the suggestion at once with `decision`: only an album
    /// of its own, and nothing personal. Adding to an album of the user's ("Ergänzen …" goes
    /// through the preview, decision Punkt 5), renaming, moving or merging one, a suggestion still
    /// undecided (a name is missing, several albums fit) and personal content ("Ansehen …") open
    /// the suggestion first.
    ///
    /// Personal as its card treats it (`ProposalCardText`): a sensitive suggestion, or one whose
    /// preview is hidden because every photo is a sensitive document (`hidesPreview`, the app's
    /// `previewHidden(for:)`). Its card shows no photo, so the user has never seen what would go
    /// into Photos (second review of the cards). The app's `createNow`, where every "Anlegen"
    /// ends, passes it.
    public static func mayCreateAtOnce(_ proposal: AlbumProposal, decision: ProposalDecision, hidesPreview: Bool = false) -> Bool {
        guard case .createNew = decision else { return false }
        return !proposal.isSensitive && !hidesPreview
    }

    /// Whether `plan` may run without the preview: it makes exactly one album with photos in it,
    /// puts photos only into what it makes, and changes nothing that exists (no album of the
    /// user's gets photos, is renamed, moved, emptied or deleted). And the planner found nothing
    /// to point out: an album of the same name in the same folder is said in the preview, never
    /// made beside it unseen.
    public static func mayRunWithoutPreview(_ plan: ChangePlan) -> Bool {
        guard plan.conflicts.isEmpty, plan.reverts == nil, plan.retries == nil else { return false }
        var albums = 0
        var photos = 0
        for step in plan.steps {
            switch step.operation {
            case .createAlbum: albums += 1
            case .createFolder: continue
            case .addAssets(.planned, let assets): photos += assets.count
            case .addAssets(.existing, _), .renameCollection, .moveCollection, .removeAssets, .deleteCollection: return false
            }
        }
        return albums == 1 && photos > 0
    }

    /// The new album's name as the plan writes it to Photos: what the banner says, so the name
    /// on the card, in the banner and in Photos is the same ("Der Kartenname ist genau der
    /// Albumname in Fotos"). Nil unless the plan makes exactly one album.
    public static func albumTitle(of plan: ChangePlan) -> String? {
        let titles = plan.steps.compactMap { step -> String? in
            if case .createAlbum(_, let title, _) = step.operation { return title }
            return nil
        }
        return titles.count == 1 ? titles[0] : nil
    }

    /// How the run of such a plan ended, by what Photos confirmed (`PlanReceipt`, the numbers
    /// of the receipt and the history).
    public enum Ending: Hashable, Sendable {
        /// The album is in Photos with every photo: the banner.
        case created
        /// The album is in Photos, but steps failed (photos missing): the banner, and a note
        /// that Albumist suggests the missing photos again.
        case createdWithGaps(failedSteps: Int)
        /// No album was made (the run stopped before it, Photos refused, or it is unconfirmed).
        case notCreated
    }

    public static func ending(of finished: ChangePlan) -> Ending {
        let receipt = PlanReceipt(plan: finished, inventory: CollectionInventory())
        guard receipt.albumsCreated == 1 else { return .notCreated }
        return receipt.failedSteps > 0 ? .createdWithGaps(failedSteps: receipt.failedSteps) : .created
    }

    /// How long the banner stays: long enough to read the album's name and reach "Widerrufen"
    /// (longer than the 6 s of "Fotos ignoriert": a name takes longer to read than a number).
    /// With VoiceOver or Switch Control, and in a UI test, 20 s, as for "Fotos ignoriert". Later
    /// the album is taken back from the history like any change.
    public static func bannerDuration(assistive: Bool) -> Duration {
        assistive ? .seconds(20) : .seconds(8)
    }
}

/// The banner after "Anlegen" (decision 7B): "„Name“ angelegt · Widerrufen". "Widerrufen" takes
/// back exactly `plan`, through the undo of the history.
public struct QuickCreateBanner: Identifiable, Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// "„Name“ angelegt" with "Widerrufen".
        case shown
        /// "Widerrufen" was tapped: Albumist checks whether taking it back deletes the album
        /// (iOS then asks once more, and the banner says so first).
        case checking
        /// Being taken back. `deletesAlbum`: iOS asks once more before the album goes.
        case undoing(deletesAlbum: Bool)
    }

    /// The plan that made the album.
    public let plan: ChangePlan
    /// The suggestion the album came from (its card shows "Angelegt" meanwhile).
    public let proposalID: SortlyID
    /// The album's name in Photos.
    public let title: String
    public var phase: Phase

    public var id: SortlyID { plan.id }

    /// Nil unless `plan` made exactly one album.
    public init?(plan: ChangePlan, proposalID: SortlyID) {
        guard let title = QuickCreate.albumTitle(of: plan) else { return nil }
        self.plan = plan
        self.proposalID = proposalID
        self.title = title
        phase = .shown
    }

    /// "Widerrufen" can be tapped (not while it is being taken back).
    public var canUndo: Bool { phase == .shown }
}

/// The suggestions made with "Anlegen" while "Nicht jetzt" had set them aside, as long as their
/// banner shows (review B of design wave 1, findings 4 and 9). Their pick, and then their album,
/// would move their card to its area under the finger: the suggestion list keeps it under "Nicht
/// jetzt" instead, from the tap until the banner ends. A completed "Widerrufen" sets the
/// suggestion aside again, as it was before the tap; a banner that goes by itself leaves the
/// album, and the lifted rejection, as they are. One memory for both, kept by the app with the
/// banner.
public struct QuickCreateSetAside: Hashable, Sendable {
    private var proposals: [SortlyID: AlbumProposal] = [:]

    public init() {}

    /// Its card stays under "Nicht jetzt": made, or being made, from there.
    public func contains(_ id: SortlyID) -> Bool {
        proposals[id] != nil
    }

    /// "Anlegen" is making `proposal`'s album; `setAside`: "Nicht jetzt" had set it aside
    /// (noted before the pick takes the decision's place).
    public mutating func begin(_ proposal: AlbumProposal, setAside: Bool) {
        proposals[proposal.id] = setAside ? proposal : nil
    }

    /// Nothing was made: the suggestion's decision says again where its card is.
    public mutating func notMade(_ id: SortlyID) {
        proposals[id] = nil
    }

    /// The banner for the suggestion `id` shows. The banner it replaces can no longer be taken
    /// back, so only `id` is remembered (one album is made at a time).
    public mutating func bannerShown(for id: SortlyID) {
        proposals = proposals.filter { $0.key == id }
    }

    /// The banner for the suggestion `id` went by itself: its album stays.
    public mutating func bannerGone(for id: SortlyID) {
        proposals[id] = nil
    }

    /// "Widerrufen" took the album of the suggestion `id` back: the suggestion to set aside
    /// again, nil if "Nicht jetzt" had not set it aside. Once.
    public mutating func undone(_ id: SortlyID) -> AlbumProposal? {
        proposals.removeValue(forKey: id)
    }
}
