import Foundation

/// The user's decision for one proposal (prompt §5.4).
public enum ProposalDecision: Hashable, Sendable, Codable {
    case undecided
    case reject
    /// Create a new album (also used for "zusätzliches Album erstellen").
    case createNew(title: String?, folderPath: [String]?)
    /// Keep the existing album unchanged (counts as organized).
    case keepExisting(CollectionID)
    /// Add missing matching media to the existing album (default for "ergänzbar").
    case extendExisting(CollectionID)
    case renameExisting(CollectionID, newTitle: String, extend: Bool)
    case moveExisting(CollectionID, folderPath: [String], extend: Bool)
    /// Merge several albums into one target: their media are added to it, the source albums
    /// stay as they are. `title` nil keeps an existing target's name exactly as the user wrote it.
    /// (Removing the source albums is not offered: it would delete the user's own albums without
    /// a delete guard, review P2-06. Decisions stored with `removeSourceAlbums` still decode; the
    /// key is ignored.)
    case merge(target: CollectionID?, sources: [CollectionID], title: String?, folderPath: [String]?)
}

/// A proposal together with the user's selection.
public struct ConfirmedProposal: Hashable, Sendable, Codable {
    public var proposal: AlbumProposal
    public var decision: ProposalDecision
    /// Optional (weak-evidence) members the user accepted.
    public var acceptedOptional: Set<AssetID>
    /// Members the user deselected.
    public var excluded: Set<AssetID>

    public init(proposal: AlbumProposal, decision: ProposalDecision, acceptedOptional: Set<AssetID> = [], excluded: Set<AssetID> = []) {
        self.proposal = proposal
        self.decision = decision
        self.acceptedOptional = acceptedOptional
        self.excluded = excluded
    }

    public var selectedAssets: Set<AssetID> {
        proposal.assetIDs.union(acceptedOptional.intersection(proposal.optionalAssetIDs)).subtracting(excluded)
    }
}

/// Turns confirmed decisions into a concrete `ChangePlan`. Pure function of its inputs:
/// planning never touches the photo library (prompt §16).
public struct OrganizationPlanner: Sendable {
    /// Root folder for everything Albumist creates ("Albumist"). Empty = top level.
    public var rootFolderTitle: String
    /// Maximum assets per add step – keeps each PhotoKit transaction small and resumable.
    public var chunkSize: Int

    public init(rootFolderTitle: String = "Albumist", chunkSize: Int = 500) {
        self.rootFolderTitle = rootFolderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        self.chunkSize = max(1, chunkSize)
    }

    public func makePlan(
        id: SortlyID = SortlyID(),
        from items: [ConfirmedProposal],
        inventory: CollectionInventory,
        overrides: OverrideSet = OverrideSet(),
        now: Date = Date()
    ) -> ChangePlan {
        var builder = Builder(inventory: inventory, root: rootFolderTitle, planID: id, chunkSize: chunkSize)
        var conflicts: [PlanConflict] = []
        var notes: [PlanNote] = []
        var respectedRemovals = 0
        var optionalNotIncluded = 0

        // Detect duplicate titles among new albums before building.
        var newTitles: [String: [SortlyID]] = [:]
        for item in items {
            if case .createNew(let title, let path) = item.decision {
                let t = title ?? item.proposal.title
                let p = path ?? item.proposal.folderPath
                newTitles[(p + [AlbumTitle.normalized(t)]).joined(separator: "/"), default: []].append(item.proposal.id)
            }
        }
        for (key, sources) in newTitles where sources.count > 1 {
            let parts = key.split(separator: "/").map(String.init)
            let title = items.first { $0.proposal.id == sources[0] }.map { item -> String in
                if case .createNew(let t, _) = item.decision { return t ?? item.proposal.title }
                return item.proposal.title
            } ?? parts.last ?? key
            conflicts.append(.duplicatePlannedTitle(title: title, folderPath: Array(parts.dropLast()), sources: sources))
        }

        for item in items.sorted(by: { $0.proposal.id.rawValue < $1.proposal.id.rawValue }) {
            let sourceID = item.proposal.id
            if overrides.isRejected(sourceID) { notes.append(.skippedRejected(sourceID)); continue }
            optionalNotIncluded += item.proposal.optionalAssetIDs.subtracting(item.acceptedOptional).count

            func filtered(for album: CollectionID?) -> [AssetID] {
                let candidates = item.selectedAssets.filter { overrides.mayAdd($0, toSource: sourceID) && !overrides.isIgnored($0) && !overrides.isExcluded($0) }
                guard let album else { return candidates.sorted() }
                let allowed = candidates.filter { overrides.mayAdd($0, toAlbum: album) }
                respectedRemovals += candidates.count - allowed.count
                return allowed.sorted()
            }

            func requireEditable(_ id: CollectionID) -> Bool {
                guard let album = inventory[id] else { conflicts.append(.albumMissing(id)); return false }
                guard album.isEditableAlbum else { conflicts.append(.albumNotEditable(id)); return false }
                builder.touch(id)
                return true
            }

            switch item.decision {
            case .undecided, .reject, .keepExisting:
                continue

            case .createNew(let title, let path):
                if overrides.mustNotRecreate(sourceID) { notes.append(.skippedDeletedByUser(sourceID)); continue }
                let albumTitle = AlbumTitle.sanitize(title ?? item.proposal.title)
                let folderPath = path ?? item.proposal.folderPath
                let parent = builder.folder(for: folderPath, source: sourceID)
                if let existing = builder.existingAlbum(titled: albumTitle, in: parent) {
                    conflicts.append(.titleExistsInFolder(title: albumTitle, existing: existing))
                }
                let key = builder.createAlbum(title: albumTitle, parent: parent, source: sourceID)
                builder.add(filtered(for: nil), to: .planned(key), source: sourceID)

            case .extendExisting(let albumID):
                guard requireEditable(albumID) else { continue }
                let missing = filtered(for: albumID).filter { !(inventory[albumID]?.assetIDs.contains($0) ?? false) }
                builder.add(missing, to: .existing(albumID), source: sourceID)

            case .renameExisting(let albumID, let newTitle, let extend):
                guard requireEditable(albumID), let album = inventory[albumID] else { continue }
                let clean = AlbumTitle.sanitize(newTitle)
                if clean != album.title {
                    builder.append(.renameCollection(albumID, from: album.title, to: clean), source: sourceID)
                }
                if extend {
                    builder.add(filtered(for: albumID).filter { !album.assetIDs.contains($0) }, to: .existing(albumID), source: sourceID)
                }

            case .moveExisting(let albumID, let path, let extend):
                guard requireEditable(albumID), let album = inventory[albumID] else { continue }
                let target = builder.folder(for: path, source: sourceID)
                if target != builder.currentParentRef(of: album) {
                    builder.append(.moveCollection(albumID, from: album.parentID, to: target), source: sourceID)
                }
                if extend {
                    builder.add(filtered(for: albumID).filter { !album.assetIDs.contains($0) }, to: .existing(albumID), source: sourceID)
                }

            case .merge(let target, let sources, let title, let path):
                let validSources = sources.filter { requireEditable($0) }
                guard validSources.count == sources.count else { continue }
                var union = Set<AssetID>()
                for s in validSources { union.formUnion(inventory[s]?.assetIDs ?? []) }
                union.formUnion(item.selectedAssets)
                let ref: AlbumRef
                let targetMembers: Set<AssetID>
                if let target, requireEditable(target), let album = inventory[target] {
                    ref = .existing(target)
                    targetMembers = album.assetIDs
                    // Renamed only when a new name was asked for; extending is no reason to
                    // touch the name the user gave the album.
                    if let title {
                        let clean = AlbumTitle.sanitize(title)
                        if clean != album.title { builder.append(.renameCollection(target, from: album.title, to: clean), source: sourceID) }
                    }
                } else {
                    let parent = builder.folder(for: path ?? item.proposal.folderPath, source: sourceID)
                    ref = .planned(builder.createAlbum(title: AlbumTitle.sanitize(title ?? item.proposal.title), parent: parent, source: sourceID))
                    targetMembers = []
                }
                builder.add(union.subtracting(targetMembers).sorted(), to: ref, source: sourceID)
            }
        }

        if respectedRemovals > 0 { notes.append(.respectedManualRemovals(count: respectedRemovals)) }
        if optionalNotIncluded > 0 { notes.append(.optionalItemsNotIncluded(count: optionalNotIncluded)) }

        return ChangePlan(
            id: id,
            createdAt: now,
            confirmedAt: nil,
            status: .draft,
            baseline: builder.baseline,
            baselineCollectionIDs: Set(inventory.collections.keys),
            steps: builder.steps,
            conflicts: conflicts,
            notes: notes,
            resolvedKeys: [:]
        )
    }

    // MARK: - Builder

    struct Builder {
        let inventory: CollectionInventory
        let root: String
        let planID: SortlyID
        let chunkSize: Int
        var steps: [PlanStep] = []
        var baseline: [CollectionID: String] = [:]
        var plannedFolders: [String: String] = [:]           // path → key
        var plannedAlbums: [String: [String: String]] = [:]  // parent → normalized title → key

        init(inventory: CollectionInventory, root: String, planID: SortlyID, chunkSize: Int) {
            self.inventory = inventory
            self.root = root
            self.planID = planID
            self.chunkSize = chunkSize
        }

        mutating func touch(_ id: CollectionID) {
            if let c = inventory[id] { baseline[id] = c.fingerprint }
        }

        mutating func append(_ op: PlannedOperation, source: SortlyID?) {
            let index = steps.count
            let content = String(describing: op)
            steps.append(PlanStep(id: "\(planID.rawValue)-\(index)-\(StableHash.hex(content).prefix(12))", operation: op, sourceID: source))
        }

        func refKey(_ ref: FolderRef) -> String {
            switch ref {
            case .topLevel: "top"
            case .existing(let id): "e:\(id.rawValue)"
            case .planned(let k): "p:\(k)"
            }
        }

        func currentParentRef(of album: CollectionSnapshot) -> FolderRef {
            album.parentID.map { .existing($0) } ?? .topLevel
        }

        /// Resolves `[root] + path` to existing folders where possible, planning the rest.
        mutating func folder(for path: [String], source: SortlyID?) -> FolderRef {
            let full = (root.isEmpty ? [] : [root]) + path
            var parent: FolderRef = .topLevel
            var walked: [String] = []
            for title in full {
                walked.append(title)
                let pathKey = walked.joined(separator: "/")
                if case .existing(let parentID) = parent, let match = childFolder(titled: title, parentID: parentID) {
                    parent = .existing(match)
                    continue
                }
                if case .topLevel = parent, let match = childFolder(titled: title, parentID: nil) {
                    parent = .existing(match)
                    continue
                }
                if let key = plannedFolders[pathKey] {
                    parent = .planned(key)
                    continue
                }
                let key = "folder:" + pathKey
                append(.createFolder(key: key, title: title, parent: parent), source: source)
                plannedFolders[pathKey] = key
                parent = .planned(key)
            }
            return parent
        }

        func childFolder(titled title: String, parentID: CollectionID?) -> CollectionID? {
            inventory.folders.first { $0.title == title && $0.parentID == parentID }?.id
        }

        func existingAlbum(titled title: String, in parent: FolderRef) -> CollectionID? {
            let parentID: CollectionID?
            switch parent {
            case .topLevel: parentID = nil
            case .existing(let id): parentID = id
            case .planned: return nil
            }
            let normalized = AlbumTitle.normalized(title)
            return inventory.albums.first { $0.parentID == parentID && AlbumTitle.normalized($0.title) == normalized }?.id
        }

        mutating func createAlbum(title: String, parent: FolderRef, source: SortlyID?) -> String {
            let parentKey = refKey(parent)
            let normalized = AlbumTitle.normalized(title)
            var key = "album:\(parentKey)/\(normalized)"
            var suffix = 2
            while plannedAlbums[parentKey]?.values.contains(key) == true {
                key = "album:\(parentKey)/\(normalized)#\(suffix)"
                suffix += 1
            }
            plannedAlbums[parentKey, default: [:]][normalized + "#\(steps.count)"] = key
            append(.createAlbum(key: key, title: title, parent: parent), source: source)
            return key
        }

        mutating func add(_ assets: [AssetID], to album: AlbumRef, source: SortlyID?) {
            guard !assets.isEmpty else { return }
            var start = 0
            while start < assets.count {
                let chunk = Array(assets[start..<min(start + chunkSize, assets.count)])
                append(.addAssets(album: album, assets: chunk), source: source)
                start += chunkSize
            }
        }
    }
}

extension ProposalDecision {
    /// What "Übernehmen" does for a proposal (prompt §5.4): keep a complete album, extend a
    /// matching one, otherwise create a new album. Ambiguous cases and unnamed personal
    /// places/groups stay undecided until the user chooses.
    ///
    /// Only a certain match (`extendable`) changes an album of the user. A possible match
    /// (`possibleMatch`) gets an album of its own; the user can still pick the existing album
    /// under "Anpassen" (review 16.11., A1–A4: "Unklar heißt nicht erledigt").
    public static func recommended(for proposal: AlbumProposal, match: MatchResult?, userTitle: String? = nil) -> ProposalDecision {
        let title = userTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if proposal.requiresUserName && (title ?? "").isEmpty { return .undecided }
        switch match?.status {
        case .alreadyComplete:
            if let id = match?.best?.albumID { return .keepExisting(id) }
        case .extendable:
            if let best = match?.best, best.isEditable { return .extendExisting(best.albumID) }
        case .multipleMatches, .ambiguous:
            return .undecided
        default:
            break
        }
        return .createNew(title: (title?.isEmpty ?? true) ? nil : title, folderPath: nil)
    }

    /// Whether a suggestion may be accepted without the user looking at it ("Dein Startpaket",
    /// "Empfohlene auswählen"): at least likely, nothing sensitive, no name needed, a clear
    /// action, and no similar album of the user that only possibly fits (review 16.11.).
    /// An album that already holds everything is no action: "15 empfohlene auswählen" turned
    /// 15 complete suggestions into "Ausgewählt" without anything to create (UI run
    /// 43823834271), and once their albums were taken back they stayed that way.
    ///
    /// An album of the user that also holds other photos is extended only when the user looked
    /// at it: "Italien" with the way there through Austria, extended because of its name
    /// ("Gleicher Name gewinnt", review P1-02).
    public static func isSafeToAcceptUnseen(_ proposal: AlbumProposal, match: MatchResult?) -> Bool {
        let recommended = recommended(for: proposal, match: match)
        let extendsMixedAlbum = recommended.extendedAlbum != nil
            && (match?.best?.relation == .partialOverlap || match?.best?.relation == .broaderCollection)
        return proposal.reliability >= .likely && !proposal.isSensitive && !proposal.requiresUserName
            && match?.status != .possibleMatch && recommended.isAccepted && !recommended.isKeepExisting
            && !extendsMixedAlbum
    }

    /// "So lassen" decisions for albums an undo deleted: such a decision changes nothing and
    /// is not counted as open either, so its suggestion could never be created again (UI run
    /// 43823834271: two plans taken back, their 15 suggestions stayed "Ausgewählt" with "Neues
    /// Album" and nothing to create). They go back to open.
    ///
    /// Only albums the undo's own deletion steps removed (verified by the executor), never an
    /// album that an album list lacks: with limited access or during an iCloud sync the list can
    /// hold few or no albums, and a deliberate "So lassen" must not be lost to that (review of
    /// 697852f: the Startpaket could then extend that album).
    public static func keepsOfAlbumsDeleted(by plan: ChangePlan, in decisions: [SortlyID: ProposalDecision]) -> Set<SortlyID> {
        guard plan.reverts != nil else { return [] }
        let deleted = Set(plan.steps.compactMap { step -> CollectionID? in
            guard case .deleteCollection(let id, _) = step.operation, case .succeeded = step.state else { return nil }
            return id
        })
        guard !deleted.isEmpty else { return [] }
        return Set(decisions.compactMap { id, decision in
            if case .keepExisting(let album) = decision, deleted.contains(album) { return id }
            return nil
        })
    }

    /// The existing album an accepted decision adds photos to: "ergänzen", or renaming or
    /// moving with extending. nil when it adds nothing to an album of the user.
    public var extendedAlbum: CollectionID? {
        switch self {
        case .extendExisting(let id): id
        case .renameExisting(let id, _, true), .moveExisting(let id, _, true): id
        default: nil
        }
    }

    /// After the matching rules changed (a new `AlbumMatcher.version`): the suggestions whose
    /// accepted, not yet applied decision still adds photos to an album that is no longer a
    /// certain match for it (`AlbumMatcher.sortingAlbums`). They go back to open, so the user
    /// decides again (re-check 16.11.: a Startpaket "ergänzen" on what is now only a possible
    /// match must not run). Applied suggestions have no decision any more; `protected` are the
    /// suggestions of a plan that already started (an interrupted one): never touched.
    public static func uncertainExtensions(_ decisions: [SortlyID: ProposalDecision], proposals: [AlbumProposal],
                                           matches: [SortlyID: MatchResult], protected: Set<SortlyID> = []) -> Set<SortlyID> {
        let matcher = AlbumMatcher()
        var result = Set<SortlyID>()
        for proposal in proposals where !protected.contains(proposal.id) {
            guard let decision = decisions[proposal.id], decision.isAccepted, let album = decision.extendedAlbum else { continue }
            if !matcher.sortingAlbums(matches[proposal.id], kind: proposal.kind, title: proposal.title).contains(album) {
                result.insert(proposal.id)
            }
        }
        return result
    }

    /// The suggestions whose accepted decision adds photos to an album recorded for their ID
    /// (`recorded`, from the managed-album records) while that album was made for other photos (`AlbumMatcher.isStillAlbum`):
    /// the ID went to another place (a frequent place that is gone leaves its ID to a new one in
    /// its cell). They go back to open after each analysis, so "ergänzen" never runs on photos
    /// the user did not choose it for. An album the user picked for a suggestion is not recorded
    /// for it and stays chosen; `protected` as in `uncertainExtensions`.
    public static func extensionsOfOtherPhotos(_ decisions: [SortlyID: ProposalDecision], proposals: [AlbumProposal],
                                               inventory: CollectionInventory, recorded: [SortlyID: Set<CollectionID>],
                                               overrides: OverrideSet, protected: Set<SortlyID> = []) -> Set<SortlyID> {
        var result = Set<SortlyID>()
        for proposal in proposals where !protected.contains(proposal.id) {
            guard let decision = decisions[proposal.id], decision.isAccepted, let album = decision.extendedAlbum,
                  recorded[proposal.id]?.contains(album) == true, let members = inventory[album]?.assetIDs else { continue }
            let shared = members.isDisjoint(with: proposal.assetIDs) ? 0 : 1
            if !AlbumMatcher.isStillAlbum(album, of: proposal, shared: shared, inventory: inventory, overrides: overrides) {
                result.insert(proposal.id)
            }
        }
        return result
    }

    public var isAccepted: Bool {
        switch self {
        case .undecided, .reject: false
        default: true
        }
    }

    /// The album already holds everything: accepting changes nothing in Photos.
    public var isKeepExisting: Bool {
        if case .keepExisting = self { return true }
        return false
    }
}
