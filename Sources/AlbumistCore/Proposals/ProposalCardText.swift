import Foundation

/// What a suggestion's card says (design wave 1: E1, E6 "Karten-Arten", E7): the album's name,
/// one line of status as a sentence with the album's name (Punkt 3), and its one action.
///
/// - The title is exactly the name of the album that creating it makes in Photos
///   (`ProposalOutcome`); a suggestion for the user's own album keeps its own title, and the
///   status names the album.
/// - "16 Fotos · Neues Album"; "Kommt in dein Album „Toskana“ · +12 Fotos"; "Schon in deinem
///   Album „Island“"; "Name fehlt · 38 Fotos"; "9 Fotos · Persönlicher Inhalt"; "Benennt dein
///   Album „Sommer“ um"; "Verschiebt dein Album „Garten“".
/// - "Sicher", "Wahrscheinlich", "Möglich" are said only when the user should look before
///   anything is created: "16 Fotos · Möglich · Bitte kurz ansehen" (`needsLook`). A choice the
///   user made in the suggestion ("Anpassen") needs no second look.
public struct ProposalCardText: Equatable, Sendable {
    /// The status line, for views that style a part of it (the badge "Name fehlt", the lock of
    /// personal content).
    public enum Status: Equatable, Sendable {
        case newAlbum
        case addsTo(album: String, newPhotos: Int)
        case alreadyIn(album: String)
        case nameMissing
        /// Personal or sensitive content (`AlbumProposal.isSensitive`, or every photo is a
        /// sensitive document): looked at before it becomes an album.
        case personal
        /// Albumist is unsure: the confidence when that is the reason, nil when an album of the
        /// user only possibly fits or several fit.
        case pleaseLook(Reliability?)
        /// The user's album `album` gets a new name (the card's title); nothing is added to it.
        case renames(album: String)
        /// The user's album `album` moves into another folder; nothing is added to it.
        case moves(album: String)
    }

    public let title: String
    /// The status line, its parts joined with " · ".
    public let subtitle: String?
    public let action: ProposalCardAction
    /// The user should look at the suggestion before anything is created ("Bitte kurz ansehen").
    public let needsLook: Bool

    public let status: Status
    public let outcome: ProposalOutcome
    /// The photos of the suggestion without those the user took out of it.
    public let photoCount: Int
    /// Personal or sensitive content (`AlbumProposal.isSensitive`, or every photo is a sensitive
    /// document): never created without a look. Its status says so ("Persönlicher Inhalt") once
    /// it has a name.
    public let isPersonal: Bool
    /// Every photo is a sensitive document: the card shows "Vorschau ausgeblendet" instead of a cover.
    public let hidesPreview: Bool
    /// The parts of `subtitle`, in order: "Name fehlt" is the first part of `.nameMissing`.
    public let subtitleParts: [String]
    /// What VoiceOver says after the name: the status line's parts in words, never a symbol
    /// drawn with them (the lock of "Persönlicher Inhalt"), and "Vorschau ausgeblendet", which
    /// only the cover shows. A card reads "name, status" (`PhotoCard`), so the status line
    /// speaks this (review B of design wave 1, 5).
    public let spokenStatus: String
    /// The card as VoiceOver reads it, one element: name, status, count.
    public let accessibilityLabel: String

    /// - Parameters:
    ///   - decision: the user's decision (`AppModel.decisions`); one that creates or changes
    ///     something is what the card shows, any other (none, "Nicht jetzt") shows what Albumist
    ///     recommends (`ProposalDecision.recommended`).
    ///   - userTitle: the name the user gave it (`AppModel.userTitles`), or the one typed in the
    ///     open suggestion.
    ///   - removed: photos the user took out of it.
    ///   - hidesPreview: every photo is a sensitive document (`AppModel.previewHidden(for:)`).
    ///   - rootFolderTitle: the folder Albumist puts its albums in (`OrganizationSettings`).
    public init(proposal: AlbumProposal, decision: ProposalDecision?, userTitle: String?, match: MatchResult?,
                inventory: CollectionInventory, removed: Set<AssetID> = [], hidesPreview: Bool = false,
                rootFolderTitle: String = "", words: ProposalWords = .german) {
        let chosen = decision?.isAccepted == true
        let effective = chosen ? decision! : ProposalDecision.recommended(for: proposal, match: match, userTitle: userTitle)
        let outcome = ProposalOutcome(proposal: proposal, decision: effective, userTitle: userTitle, match: match,
                                      inventory: inventory, removed: removed, rootFolderTitle: rootFolderTitle)
        let count = proposal.assetIDs.subtracting(removed).count
        let personal = proposal.isSensitive || hidesPreview

        let (status, action) = Self.statusAndAction(of: outcome)
            ?? Self.newAlbum(proposal, chosen: chosen, personal: personal, match: match, count: count)
        let parts = Self.parts(of: status, count: count, words: words)
        self.title = Self.title(of: outcome, proposal: proposal, userTitle: userTitle)
        self.subtitle = parts.joined(separator: " · ")
        self.subtitleParts = parts
        self.action = action
        self.needsLook = { if case .pleaseLook = status { true } else { false } }()
        self.status = status
        self.outcome = outcome
        self.photoCount = count
        self.isPersonal = personal
        self.hidesPreview = hidesPreview
        let spoken = parts + (hidesPreview ? [words.previewHidden] : [])
        self.spokenStatus = spoken.joined(separator: ", ")
        self.accessibilityLabel = ([self.title] + spoken).joined(separator: ", ")
    }

    /// The status and the action of a card whose outcome alone decides them: every one but a
    /// new album.
    private static func statusAndAction(of outcome: ProposalOutcome) -> (Status, ProposalCardAction)? {
        switch outcome {
        case .needsName: (.nameMissing, .name)
        case .addsTo(_, let album, let newPhotos): (.addsTo(album: album, newPhotos: newPhotos), .add(albumName: album, newPhotos: newPhotos))
        case .alreadyIn(_, let album): (.alreadyIn(album: album), .look)
        case .renames(_, let album, _): (.renames(album: album), .look)
        case .moves(_, let album, _): (.moves(album: album), .look)
        case .chooseAlbum: (.pleaseLook(nil), .look)
        case .newAlbum: nil
        }
    }

    /// The status and the action of a new album: looked at first when it is personal, when
    /// Albumist is unsure and the user did not choose it, or when a similar album of the user
    /// exists.
    private static func newAlbum(_ proposal: AlbumProposal, chosen: Bool, personal: Bool, match: MatchResult?,
                                 count: Int) -> (Status, ProposalCardAction) {
        if personal { return (.personal, .look) }
        if !chosen && proposal.reliability < .likely { return (.pleaseLook(proposal.reliability), .look) }
        // A similar album of the user exists: the user sees it first (review 16.11.).
        if !chosen && match?.status == .possibleMatch { return (.pleaseLook(nil), .look) }
        // An album without photos is no album: nothing to create at once.
        return (.newAlbum, count > 0 ? .create : .look)
    }

    /// The parts of the status line, in order.
    private static func parts(of status: Status, count: Int, words: ProposalWords) -> [String] {
        switch status {
        case .newAlbum: [words.photos(count), words.newAlbum]
        case .addsTo(let album, let newPhotos): [words.addsTo(album: album), words.addedPhotos(newPhotos)]
        case .alreadyIn(let album): [words.alreadyIn(album: album)]
        case .nameMissing: [words.nameMissing, words.photos(count)]
        case .personal: [words.photos(count), words.personal]
        case .renames(let album): [words.renames(album: album)]
        case .moves(let album): [words.moves(album: album)]
        case .pleaseLook(let reliability):
            [words.photos(count)] + (reliability.map { [words.reliability($0)] } ?? []) + [words.pleaseLook]
        }
    }

    /// The card's title: the album's name the outcome gives, else the user's name for it or the
    /// suggestion's title.
    private static func title(of outcome: ProposalOutcome, proposal: AlbumProposal, userTitle: String?) -> String {
        switch outcome {
        case .newAlbum(let title, _): title
        // The name the plan gives the user's album; the status names it as it is called now.
        case .renames(_, _, let title): title
        // The place's own title ("Häufiger Ort in Lindau") until it has a name.
        case .needsName: proposal.title
        default: userTitle.flatMap(UserTitle.stored) ?? proposal.title
        }
    }
}

/// The one action a suggestion's card offers (decision "Punkt 2" of 16.11.2026): "Anlegen"
/// creates the album at once (7B), the others open a page first, which their "…" says.
public enum ProposalCardAction: Equatable, Sendable {
    /// "Anlegen": a new album, created at once.
    case create
    /// "Ergänzen …": the photos go into the user's own album, through the preview (Punkt 5).
    case add(albumName: String, newPhotos: Int)
    /// "Benennen …": a place or group only the user can name.
    case name
    /// "Ansehen …": personal content, an album that is complete or that the suggestion renames or
    /// moves, or Albumist is unsure.
    case look
}

/// What creating a suggestion would do in Photos, worked out exactly as the plan does it
/// (`OrganizationPlanner`, `AppModel.buildPlan`), so the card and the open suggestion name the
/// album that the plan and the receipt will name.
public enum ProposalOutcome: Equatable, Sendable {
    /// A new album with exactly this name, in this folder path (below the root folder, which is
    /// part of it when it is set).
    case newAlbum(title: String, folderPath: [String])
    /// A place or group only the user can name, without a name yet: nothing is created before
    /// it has one. It then becomes a new album in `folderPath`.
    case needsName(folderPath: [String])
    /// The photos go into the user's album `title` (its name in Photos); `newPhotos` are not in
    /// it yet.
    case addsTo(album: CollectionID, title: String, newPhotos: Int)
    /// The user's album already holds every photo: nothing changes.
    case alreadyIn(album: CollectionID, title: String)
    /// The user's album, called `from` in Photos, gets the name `to`; no photos are added (it
    /// holds every one, or the decision adds none).
    case renames(album: CollectionID, from: String, to: String)
    /// The user's album `title` moves into the folder `folderPath` (below the root folder, which
    /// is part of it when it is set); no photos are added.
    case moves(album: CollectionID, title: String, folderPath: [String])
    /// Several albums fit (or none clearly): the user chooses, Albumist does not guess.
    case chooseAlbum

    /// What accepting the suggestion does with `decision`, as `AppModel.buildPlan` hands it to
    /// the planner: a new album without a name of its own takes the user's name for it
    /// (`userTitle`), else the suggestion's title; the planner tidies it (`AlbumTitle.sanitize`)
    /// and puts it below the root folder. A name typed but not stored yet may be passed as
    /// `userTitle` too: blank is no name (`UserTitle.stored`).
    public init(proposal: AlbumProposal, decision: ProposalDecision, userTitle: String?, match: MatchResult?,
                inventory: CollectionInventory, removed: Set<AssetID> = [], rootFolderTitle: String = "") {
        let name = userTitle.flatMap(UserTitle.stored)
        let root = OrganizationPlanner(rootFolderTitle: rootFolderTitle).rootFolderTitle
        func folder(_ path: [String]?) -> [String] { (root.isEmpty ? [] : [root]) + (path ?? proposal.folderPath) }
        let albums = UserAlbums(inventory: inventory, match: match, members: proposal.assetIDs.subtracting(removed))

        switch decision {
        case .undecided, .reject:
            self = proposal.requiresUserName && name == nil ? .needsName(folderPath: folder(nil)) : .chooseAlbum
        case .createNew(let title, let path):
            self = .newAlbum(title: AlbumTitle.sanitize(title ?? name ?? proposal.title), folderPath: folder(path))
        case .keepExisting(let id):
            self = albums.existing(id, adds: false)
        case .extendExisting(let id):
            self = albums.existing(id, adds: true)
        case .renameExisting(let id, let newTitle, let extend):
            self = albums.renamed(id, to: newTitle, adds: extend)
        case .moveExisting(let id, let path, let extend):
            self = albums.moved(id, into: folder(path), adds: extend)
        case .merge(let target, _, let title, let path):
            if let target {
                self = albums.existing(target, title: title.map(AlbumTitle.sanitize), adds: true)
            } else {
                self = .newAlbum(title: AlbumTitle.sanitize(title ?? proposal.title), folderPath: folder(path))
            }
        }
    }

    /// The user's albums as a decision for the suggestion's photos (`members`) meets them: in
    /// the inventory, or out of reach (limited access, a sync) as the match measured them.
    private struct UserAlbums {
        var inventory: CollectionInventory
        var match: MatchResult?
        var members: Set<AssetID>

        func albumTitle(_ id: CollectionID) -> String {
            if let album = inventory[id] { return album.title }
            return ([match?.best].compactMap { $0 } + (match?.alternatives ?? [])).first { $0.albumID == id }?.albumTitle ?? ""
        }

        /// The photos the album does not hold yet; without the album at hand (limited access, a
        /// sync), as the match measured it.
        func missing(in id: CollectionID) -> Int {
            if let album = inventory[id] { return members.subtracting(album.assetIDs).count }
            let candidate = ([match?.best].compactMap { $0 } + (match?.alternatives ?? [])).first { $0.albumID == id }
            return max(0, members.count - (candidate?.metrics.intersection ?? 0))
        }

        func existing(_ id: CollectionID, title: String? = nil, adds: Bool) -> ProposalOutcome {
            let shown = title ?? albumTitle(id)
            let count = adds ? missing(in: id) : 0
            return count > 0 ? .addsTo(album: id, title: shown, newPhotos: count) : .alreadyIn(album: id, title: shown)
        }

        /// Renamed only when the name differs (`OrganizationPlanner`): its own name again is no
        /// change.
        func renamed(_ id: CollectionID, to newTitle: String, adds: Bool) -> ProposalOutcome {
            let clean = AlbumTitle.sanitize(newTitle), current = albumTitle(id)
            let added = adds ? missing(in: id) : 0
            if added > 0 { return .addsTo(album: id, title: clean, newPhotos: added) }
            if clean != current { return .renames(album: id, from: current, to: clean) }
            return .alreadyIn(album: id, title: current)
        }

        func moved(_ id: CollectionID, into target: [String], adds: Bool) -> ProposalOutcome {
            let added = adds ? missing(in: id) : 0
            if added > 0 { return .addsTo(album: id, title: albumTitle(id), newPhotos: added) }
            if isMoved(id, into: target) { return .moves(album: id, title: albumTitle(id), folderPath: target) }
            return .alreadyIn(album: id, title: albumTitle(id))
        }

        /// Whether the plan moves album `id` into `path` (the root folder first): the folder the
        /// planner finds for it, existing folders by their title from the top, is not the album's
        /// own, or is not there yet and is made. An album out of reach moves as the decision says.
        func isMoved(_ id: CollectionID, into path: [String]) -> Bool {
            guard let album = inventory[id] else { return true }
            var parent: CollectionID?
            for title in path {
                guard let found = inventory.folders.first(where: { $0.title == title && $0.parentID == parent }) else { return true }
                parent = found.id
            }
            return parent != album.parentID
        }
    }
}
