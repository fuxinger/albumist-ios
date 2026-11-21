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

        let status: Status
        let action: ProposalCardAction
        switch outcome {
        case .needsName:
            (status, action) = (.nameMissing, .name)
        case .addsTo(_, let album, let newPhotos):
            (status, action) = (.addsTo(album: album, newPhotos: newPhotos), .add(albumName: album, newPhotos: newPhotos))
        case .alreadyIn(_, let album):
            (status, action) = (.alreadyIn(album: album), .look)
        case .renames(_, let album, _):
            (status, action) = (.renames(album: album), .look)
        case .moves(_, let album, _):
            (status, action) = (.moves(album: album), .look)
        case .chooseAlbum:
            (status, action) = (.pleaseLook(nil), .look)
        case .newAlbum:
            if personal {
                (status, action) = (.personal, .look)
            } else if !chosen && proposal.reliability < .likely {
                (status, action) = (.pleaseLook(proposal.reliability), .look)
            } else if !chosen && match?.status == .possibleMatch {
                // A similar album of the user exists: the user sees it first (review 16.11.).
                (status, action) = (.pleaseLook(nil), .look)
            } else {
                // An album without photos is no album: nothing to create at once.
                (status, action) = (.newAlbum, count > 0 ? .create : .look)
            }
        }

        let parts: [String]
        switch status {
        case .newAlbum: parts = [words.photos(count), words.newAlbum]
        case .addsTo(let album, let newPhotos): parts = [words.addsTo(album: album), words.addedPhotos(newPhotos)]
        case .alreadyIn(let album): parts = [words.alreadyIn(album: album)]
        case .nameMissing: parts = [words.nameMissing, words.photos(count)]
        case .personal: parts = [words.photos(count), words.personal]
        case .renames(let album): parts = [words.renames(album: album)]
        case .moves(let album): parts = [words.moves(album: album)]
        case .pleaseLook(let reliability):
            parts = [words.photos(count)] + (reliability.map { [words.reliability($0)] } ?? []) + [words.pleaseLook]
        }

        switch outcome {
        case .newAlbum(let title, _): self.title = title
        // The name the plan gives the user's album; the status names it as it is called now.
        case .renames(_, _, let title): self.title = title
        // The place's own title ("Häufiger Ort in Lindau") until it has a name.
        case .needsName: self.title = proposal.title
        default: self.title = userTitle.flatMap(UserTitle.stored) ?? proposal.title
        }
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
        let members = proposal.assetIDs.subtracting(removed)

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

        switch decision {
        case .undecided, .reject:
            self = proposal.requiresUserName && name == nil ? .needsName(folderPath: folder(nil)) : .chooseAlbum
        case .createNew(let title, let path):
            self = .newAlbum(title: AlbumTitle.sanitize(title ?? name ?? proposal.title), folderPath: folder(path))
        case .keepExisting(let id):
            self = existing(id, adds: false)
        case .extendExisting(let id):
            self = existing(id, adds: true)
        case .renameExisting(let id, let newTitle, let extend):
            // Renamed only when the name differs (`OrganizationPlanner`): its own name again is
            // no change.
            let clean = AlbumTitle.sanitize(newTitle), current = albumTitle(id)
            let added = extend ? missing(in: id) : 0
            if added > 0 {
                self = .addsTo(album: id, title: clean, newPhotos: added)
            } else if clean != current {
                self = .renames(album: id, from: current, to: clean)
            } else {
                self = .alreadyIn(album: id, title: current)
            }
        case .moveExisting(let id, let path, let extend):
            let target = folder(path), added = extend ? missing(in: id) : 0
            if added > 0 {
                self = .addsTo(album: id, title: albumTitle(id), newPhotos: added)
            } else if isMoved(id, into: target) {
                self = .moves(album: id, title: albumTitle(id), folderPath: target)
            } else {
                self = .alreadyIn(album: id, title: albumTitle(id))
            }
        case .merge(let target, _, let title, let path):
            if let target {
                self = existing(target, title: title.map(AlbumTitle.sanitize), adds: true)
            } else {
                self = .newAlbum(title: AlbumTitle.sanitize(title ?? proposal.title), folderPath: folder(path))
            }
        }
    }
}
