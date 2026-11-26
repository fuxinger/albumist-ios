import Foundation

/// What Albumist remembers about an album it created or extended (prompt §5.6).
public struct ManagedAlbumState: Hashable, Sendable, Codable {
    public var albumID: CollectionID
    /// Internal proposal/rule identity the album belongs to.
    public var sourceID: AlbumistID
    public var lastKnownTitle: String
    public var lastKnownParentID: CollectionID?
    /// Members as of the last reconciliation.
    public var lastKnownMembers: Set<AssetID>
    /// Members Albumist added itself (needed for safe undo).
    public var addedByAlbumist: Set<AssetID>
    /// True if Albumist created the album (vs. extended an existing user album).
    public var createdByAlbumist: Bool
    /// Further suggestions that were applied to this album (two suggestions put into one album).
    public var otherSourceIDs: Set<AlbumistID> = []

    /// Every suggestion this album stands for.
    public var allSourceIDs: Set<AlbumistID> { otherSourceIDs.union([sourceID]) }

    enum CodingKeys: String, CodingKey {
        case albumID, sourceID, lastKnownTitle, lastKnownParentID, lastKnownMembers, otherSourceIDs
        // Stored keys (database and safety backup) keep the old working name: records on devices
        // carry them. The rename to Albumist (tools/rename_albumist.py) changes the case names only.
        case addedByAlbumist = "addedBySortly"
        case createdByAlbumist = "createdBySortly"
    }

    public init(
        albumID: CollectionID,
        sourceID: AlbumistID,
        lastKnownTitle: String,
        lastKnownParentID: CollectionID?,
        lastKnownMembers: Set<AssetID>,
        addedByAlbumist: Set<AssetID>,
        createdByAlbumist: Bool
    ) {
        self.albumID = albumID
        self.sourceID = sourceID
        self.lastKnownTitle = lastKnownTitle
        self.lastKnownParentID = lastKnownParentID
        self.lastKnownMembers = lastKnownMembers
        self.addedByAlbumist = addedByAlbumist
        self.createdByAlbumist = createdByAlbumist
    }
}

extension ManagedAlbumState {
    /// Records saved before `otherSourceIDs` existed still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        albumID = try c.decode(CollectionID.self, forKey: .albumID)
        sourceID = try c.decode(AlbumistID.self, forKey: .sourceID)
        lastKnownTitle = try c.decode(String.self, forKey: .lastKnownTitle)
        lastKnownParentID = try c.decodeIfPresent(CollectionID.self, forKey: .lastKnownParentID)
        lastKnownMembers = try c.decode(Set<AssetID>.self, forKey: .lastKnownMembers)
        addedByAlbumist = try c.decode(Set<AssetID>.self, forKey: .addedByAlbumist)
        createdByAlbumist = try c.decode(Bool.self, forKey: .createdByAlbumist)
        otherSourceIDs = try c.decodeIfPresent(Set<AlbumistID>.self, forKey: .otherSourceIDs) ?? []
    }
}

/// External change detected on a managed album.
public enum ExternalAlbumChange: Hashable, Sendable, Codable {
    case renamed(albumID: CollectionID, from: String, to: String)
    case moved(albumID: CollectionID, from: CollectionID?, to: CollectionID?)
    case assetsAddedByUser(albumID: CollectionID, assets: Set<AssetID>)
    case assetsRemovedByUser(albumID: CollectionID, assets: Set<AssetID>)
    case deleted(albumID: CollectionID, sourceID: AlbumistID)
}

/// Compares stored managed-album states with the current inventory and turns the
/// differences into user overrides, so manual decisions win (Scenarios E and F).
public struct ManagedAlbumTracker: Sendable {
    public init() {}

    public struct Reconciliation: Sendable {
        public var changes: [ExternalAlbumChange]
        public var updatedStates: [ManagedAlbumState]
        /// Overrides derived from the user's manual actions.
        public var newOverrides: [UserOverride]
    }

    /// - Parameter changing: albums an unfinished plan of Albumist is still changing (an
    ///   interrupted run or undo). What is missing there may be Albumist's own doing, not the
    ///   user's: such an album is compared again once that plan is settled, so an interrupted
    ///   undo never turns into "deleted by the user" decisions the user did not make.
    public func reconcile(_ states: [ManagedAlbumState], with inventory: CollectionInventory, changing: Set<CollectionID> = [],
                          now: Date = Date()) -> Reconciliation {
        var changes: [ExternalAlbumChange] = []
        var updated: [ManagedAlbumState] = []
        var overrides: [UserOverride] = []

        for var state in states {
            if changing.contains(state.albumID) {
                updated.append(state)
                continue
            }
            guard let album = inventory[state.albumID] else {
                // Deleted on purpose by the user: never silently re-create it (for any of the
                // suggestions it stood for).
                changes.append(.deleted(albumID: state.albumID, sourceID: state.sourceID))
                for source in state.allSourceIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
                    overrides.append(UserOverride(scope: .source(source), decision: .doNotRecreateAlbum, createdAt: now))
                }
                continue
            }
            if album.title != state.lastKnownTitle {
                changes.append(.renamed(albumID: album.id, from: state.lastKnownTitle, to: album.title))
                state.lastKnownTitle = album.title
            }
            if album.parentID != state.lastKnownParentID {
                changes.append(.moved(albumID: album.id, from: state.lastKnownParentID, to: album.parentID))
                state.lastKnownParentID = album.parentID
            }
            let removed = state.lastKnownMembers.subtracting(album.assetIDs)
            let added = album.assetIDs.subtracting(state.lastKnownMembers)
            if !removed.isEmpty {
                changes.append(.assetsRemovedByUser(albumID: album.id, assets: removed))
                for asset in removed {
                    overrides.append(UserOverride(scope: .assetInAlbum(asset, album.id), decision: .neverAdd, createdAt: now))
                }
                state.addedByAlbumist.subtract(removed)
            }
            if !added.isEmpty {
                changes.append(.assetsAddedByUser(albumID: album.id, assets: added))
            }
            state.lastKnownMembers = album.assetIDs
            updated.append(state)
        }
        return Reconciliation(changes: changes, updatedStates: updated, newOverrides: overrides)
    }

    /// Albums Albumist asked for whose request got no answer, and which have landed since
    /// (`lateCreates`, by plan, as `AlbumistStore.lateCreates` reads them): recorded as Albumist's like any
    /// album it made, when the album check sees them first, not only when their plan was
    /// finalized (round-3 review of the PhotoKit limits, L3). Albums a plan still changes
    /// (`changing`) are left to that plan.
    public func recordingLateAlbums(_ states: [ManagedAlbumState], lateCreates: [(plan: AlbumistID, ids: [CollectionID])],
                                    inventory: CollectionInventory, changing: Set<CollectionID> = []) -> [ManagedAlbumState] {
        var result = states
        var known = Set(states.map(\.albumID))
        for (plan, ids) in lateCreates {
            for id in ids where !known.contains(id) && !changing.contains(id) {
                guard let album = inventory[id], album.kind == .userAlbum else { continue }
                result.append(ManagedAlbumState(albumID: id, sourceID: plan, lastKnownTitle: album.title, lastKnownParentID: album.parentID,
                                                lastKnownMembers: album.assetIDs, addedByAlbumist: [], createdByAlbumist: true))
                known.insert(id)
            }
        }
        return result
    }

    /// `reconcile` against the library itself (plugin review W3). A deletion is recorded for
    /// good (the suggestion never comes back), so an album missing from the album list counts
    /// as deleted only once Photos confirms it when asked for that album on its own: the list
    /// can lack some albums for a while (iCloud still syncing after a restore from a backup, a
    /// library being updated). An album found that way, with the folders above it, is added to
    /// the list everything else works with. Only when every remembered album still seems gone,
    /// the whole list is read once more after `pause` (the user may also have deleted them all).
    /// A failed read throws: nothing is recorded, and planning waits (audit 2, 1.5).
    /// - Parameter listed: the album list as just read.
    /// - Returns: the reconciliation and the album list it compared with.
    public func reconcile(_ states: [ManagedAlbumState], listed: CollectionInventory, in library: any PhotoLibraryWriting,
                          changing: Set<CollectionID> = [], pause: Duration = .milliseconds(300),
                          now: Date = Date()) async throws -> (reconciliation: Reconciliation, inventory: CollectionInventory) {
        var current = try await completed(listed, states: states, changing: changing, in: library)
        var result = reconcile(states, with: current, changing: changing, now: now)
        if !states.isEmpty, result.updatedStates.isEmpty {
            try? await Task.sleep(for: pause)
            current = try await completed(try await library.currentInventory(), states: states, changing: changing, in: library)
            result = reconcile(states, with: current, changing: changing, now: now)
        }
        return (result, current)
    }

    /// The list with every remembered album it lacks looked up on its own, and the folders
    /// above an album found that way.
    private func completed(_ listed: CollectionInventory, states: [ManagedAlbumState], changing: Set<CollectionID>,
                           in library: any PhotoLibraryWriting) async throws -> CollectionInventory {
        var current = listed
        for state in states where current[state.albumID] == nil && !changing.contains(state.albumID) {
            guard let found = try await library.collection(state.albumID) else { continue }
            current.upsert(found)
            var parent = found.parentID
            var depth = 0
            while let id = parent, current[id] == nil, depth < 32, let folder = try await library.collection(id) {
                current.upsert(folder)
                parent = folder.parentID
                depth += 1
            }
        }
        return current
    }
}

/// A manual user decision that takes precedence over every automatic rule (prompt §8, §9).
public struct UserOverride: Hashable, Sendable, Codable, Identifiable {
    public enum Scope: Hashable, Sendable, Codable {
        case asset(AssetID)
        case assetInAlbum(AssetID, CollectionID)
        case assetInSource(AssetID, AlbumistID)
        case album(CollectionID)
        case source(AlbumistID)
        case area(OrganizationArea)
        /// One existing album for one suggestion.
        case albumForSource(CollectionID, AlbumistID)
    }

    public enum Decision: String, Hashable, Sendable, Codable {
        case neverAdd            // do not add this asset to that album again
        case alwaysAdd           // manual inclusion
        case ignoreAsset         // user does not want this asset organized
        case excludeFromAnalysis // do not analyze at all (sensitive)
        case doNotRecreateAlbum  // album was deleted by the user
        case rejectProposal      // proposal rejected, do not suggest again
        case notMatchingAlbum    // this album does not fit this suggestion, never offer it again
    }

    public var id: AlbumistID
    public var scope: Scope
    public var decision: Decision
    public var ruleID: AlbumistID?
    public var createdAt: Date

    public init(id: AlbumistID = AlbumistID(), scope: Scope, decision: Decision, ruleID: AlbumistID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.scope = scope
        self.decision = decision
        self.ruleID = ruleID
        self.createdAt = createdAt
    }
}

extension UserOverride {
    /// The photo this override ignores ("Ignorieren"), or nil for any other decision.
    public var ignoredAsset: AssetID? {
        if case .asset(let id) = scope, decision == .ignoreAsset { return id }
        return nil
    }
}

/// Fast lookup over all overrides.
public struct OverrideSet: Sendable {
    private var neverAddInAlbum: Set<String> = []
    private var neverAddInSource: Set<String> = []
    private var ignoredAssets: Set<AssetID> = []
    private var excludedAssets: Set<AssetID> = []
    private var rejectedSources: Set<AlbumistID> = []
    private var deletedSources: Set<AlbumistID> = []
    private var rejectedMatches: Set<String> = []

    public init(_ overrides: [UserOverride] = []) {
        for o in overrides { insert(o) }
    }

    public mutating func insert(_ o: UserOverride) {
        switch (o.scope, o.decision) {
        case let (.assetInAlbum(a, c), .neverAdd): neverAddInAlbum.insert(a.rawValue + "|" + c.rawValue)
        case let (.assetInSource(a, s), .neverAdd): neverAddInSource.insert(a.rawValue + "|" + s.rawValue)
        case let (.asset(a), .ignoreAsset): ignoredAssets.insert(a)
        case let (.asset(a), .excludeFromAnalysis): excludedAssets.insert(a)
        case let (.source(s), .rejectProposal): rejectedSources.insert(s)
        case let (.source(s), .doNotRecreateAlbum): deletedSources.insert(s)
        case let (.albumForSource(c, s), .notMatchingAlbum): rejectedMatches.insert(c.rawValue + "|" + s.rawValue)
        // No screen records "always add" or an album left out of the analysis (Periphery,
        // 21.11.2026: nothing read them); the cases stay in `Decision` and `Scope` so stored
        // overrides still decode.
        default: break
        }
    }

    public func mayAdd(_ asset: AssetID, toAlbum album: CollectionID) -> Bool {
        !neverAddInAlbum.contains(asset.rawValue + "|" + album.rawValue) && !ignoredAssets.contains(asset) && !excludedAssets.contains(asset)
    }
    public func mayAdd(_ asset: AssetID, toSource source: AlbumistID) -> Bool {
        !neverAddInSource.contains(asset.rawValue + "|" + source.rawValue) && !ignoredAssets.contains(asset) && !excludedAssets.contains(asset)
    }
    /// The user took the photo out of the album by hand (seen by `ManagedAlbumTracker.reconcile`).
    public func tookOut(_ asset: AssetID, of album: CollectionID) -> Bool {
        neverAddInAlbum.contains(asset.rawValue + "|" + album.rawValue)
    }
    public func isIgnored(_ asset: AssetID) -> Bool { ignoredAssets.contains(asset) }
    /// Every photo the user ignored.
    public var ignored: Set<AssetID> { ignoredAssets }
    public func isExcluded(_ asset: AssetID) -> Bool { excludedAssets.contains(asset) }
    public func isRejected(_ source: AlbumistID) -> Bool { rejectedSources.contains(source) }
    public func mustNotRecreate(_ source: AlbumistID) -> Bool { deletedSources.contains(source) }
    /// The user said this album does not fit this suggestion.
    public func isRejectedMatch(_ album: CollectionID, for source: AlbumistID) -> Bool {
        rejectedMatches.contains(album.rawValue + "|" + source.rawValue)
    }
}

// MARK: - Recording executed plans

extension ManagedAlbumTracker {
    /// Updates the managed-album states after a plan ran: albums Albumist created or extended
    /// are remembered together with exactly the media Albumist added, so they can be listed,
    /// removed again and checked for manual changes later. `inventory` is read after the run.
    public func record(_ plan: ChangePlan, into states: [ManagedAlbumState], inventory: CollectionInventory) -> [ManagedAlbumState] {
        var byID: [CollectionID: ManagedAlbumState] = [:]
        for state in states where byID[state.albumID] == nil { byID[state.albumID] = state }
        var touched: Set<CollectionID> = []
        /// This plan's own verified changes per album, and the albums it created.
        var addedNow: [CollectionID: Set<AssetID>] = [:]
        var removedNow: [CollectionID: Set<AssetID>] = [:]
        var createdNow: Set<CollectionID> = []

        let record = plan.record
        /// What a membership step really changed (planned media for plans from older versions).
        /// An unverified intent counts only in an album this plan created: in any other album a
        /// photo that is there may be the user's (audit 2, 1.1).
        func changed(_ step: PlanStep, album: CollectionID, planned: [AssetID], added: Bool) -> [AssetID] {
            if let media = record?.media[step.id] {
                guard record?.unverified.contains(step.id) == true else { return media }
                guard plan.createdVerifiably(album) else { return [] }
                let members = inventory[album]?.assetIDs ?? []
                return media.filter { members.contains($0) == added }
            }
            if case .succeeded = step.state { return planned }
            return []
        }

        for step in plan.steps {
            let source = step.sourceID ?? plan.id
            switch step.operation {
            case .createAlbum(let key, let title, _):
                guard case .succeeded(let createdID, _) = step.state, let id = createdID ?? plan.resolvedKeys[key] else { continue }
                // An album found after an interruption may be the user's: never marked as created
                // by Albumist, so removing it later only takes Albumist's photos out.
                let adopted = record?.adoptedKeys.contains(key) == true
                byID[id] = ManagedAlbumState(albumID: id, sourceID: source, lastKnownTitle: title, lastKnownParentID: nil,
                                             lastKnownMembers: [], addedByAlbumist: [], createdByAlbumist: !adopted)
                touched.insert(id)
                if !adopted { createdNow.insert(id) }
            case .addAssets(let ref, let assets):
                let albumID: CollectionID? = switch ref {
                case .existing(let id): id
                case .planned(let key): plan.resolvedKeys[key]
                }
                guard let albumID else { continue }
                let added = changed(step, album: albumID, planned: assets, added: true)
                if added.isEmpty, byID[albumID] == nil, step.state.isFailedOrSkipped { continue }
                var state = byID[albumID] ?? ManagedAlbumState(
                    albumID: albumID, sourceID: source, lastKnownTitle: inventory[albumID]?.title ?? "",
                    lastKnownParentID: nil, lastKnownMembers: [], addedByAlbumist: [], createdByAlbumist: false)
                state.addedByAlbumist.formUnion(added)
                addedNow[albumID, default: []].formUnion(added)
                if source != state.sourceID { state.otherSourceIDs.insert(source) }
                byID[albumID] = state
                touched.insert(albumID)
            case .removeAssets(let album, let assets):
                let removed = changed(step, album: album, planned: assets, added: false)
                byID[album]?.addedByAlbumist.subtract(removed)
                removedNow[album, default: []].formUnion(removed)
                touched.insert(album)
            case .deleteCollection(let id, _):
                if case .succeeded = step.state {
                    byID[id] = nil
                } else if let media = record?.media[step.id] {
                    // Kept because the user had put photos in: only Albumist's photos left it.
                    byID[id]?.addedByAlbumist.subtract(media)
                    touched.insert(id)
                }
            default:
                break
            }
        }
        // An album Albumist asked for whose request got no answer, and which landed next to the
        // one the plan settled on: Albumist's own, recorded like any album it made, so it can be
        // listed and removed (third review of the PhotoKit limits, N2).
        for late in record?.mayStillLand(resolved: plan.resolvedKeys) ?? [] where byID[late] == nil {
            guard let album = inventory[late], album.kind == .userAlbum else { continue }
            byID[late] = ManagedAlbumState(albumID: late, sourceID: plan.id, lastKnownTitle: album.title, lastKnownParentID: nil,
                                           lastKnownMembers: [], addedByAlbumist: [], createdByAlbumist: true)
            touched.insert(late)
            createdNow.insert(late)
        }

        var result: [ManagedAlbumState] = []
        for var state in byID.values {
            let id = state.albumID
            if touched.contains(id) {
                // Only albums this plan changed are refreshed; the others keep their last
                // known state so manual changes are still detected by `reconcile`.
                // The state is what the album held right after this plan, built from the last
                // known members and the plan's verified changes, not read from the library
                // now: if the user took photos out (or deleted the album) between the run and
                // this moment, the next `reconcile` sees it as their decision (audit 2, 1.4).
                let added = addedNow[id] ?? []
                let known = state.lastKnownMembers.isEmpty && !createdNow.contains(id)
                    ? (inventory[id]?.assetIDs ?? [])
                    : state.lastKnownMembers
                let expected = known.union(added).subtracting(removedNow[id] ?? [])
                if let album = inventory[id] {
                    state.lastKnownTitle = album.title
                    state.lastKnownParentID = album.parentID
                }
                state.lastKnownMembers = expected
                state.addedByAlbumist.formIntersection(expected)
                // Nothing of Albumist's left: no longer managed. An album this plan created or
                // filled stays, even if the user emptied it already, so a later deletion is seen.
                if state.addedByAlbumist.isEmpty && !createdNow.contains(id) && added.isEmpty { continue }
            }
            result.append(state)
        }
        return result.sorted { ($0.lastKnownTitle, $0.albumID.rawValue) < ($1.lastKnownTitle, $1.albumID.rawValue) }
    }

    /// Plan that takes back what Albumist did to one album: an album Albumist created is deleted
    /// if it only holds media Albumist added, otherwise only Albumist's additions leave the album.
    /// Media the user added by hand always stay. Originals are never touched.
    public func removalPlan(for state: ManagedAlbumState, current: CollectionInventory, id: AlbumistID = AlbumistID(), now: Date = Date()) -> ChangePlan {
        var steps: [PlanStep] = []
        var notes: [PlanNote] = []
        func append(_ op: PlannedOperation) {
            steps.append(PlanStep(id: "\(id.rawValue)-\(steps.count)-\(StableHash.hex(String(describing: op)).prefix(12))", operation: op, sourceID: state.sourceID))
        }
        if let album = current[state.albumID], album.isEditableAlbum {
            let ours = album.assetIDs.intersection(state.addedByAlbumist)
            if state.createdByAlbumist && album.assetIDs.isSubset(of: state.addedByAlbumist) {
                append(.deleteCollection(album.id, title: album.title))
            } else if !ours.isEmpty {
                append(.removeAssets(album: album.id, assets: ours.sorted()))
                let manual = album.assetIDs.subtracting(ours).count
                if state.createdByAlbumist && manual > 0 { notes.append(.respectedManualRemovals(count: manual)) }
            }
        }
        var plan = ChangePlan(
            id: id,
            createdAt: now,
            confirmedAt: nil,
            status: .draft,
            baseline: current[state.albumID].map { [$0.id: $0.fingerprint] } ?? [:],
            baselineCollectionIDs: Set(current.collections.keys),
            steps: steps,
            conflicts: [],
            notes: notes,
            resolvedKeys: [:]
        )
        // Deleted only while it still holds nothing but Albumist's photos.
        plan.deleteGuards = [state.albumID: state.addedByAlbumist]
        return plan
    }
}
