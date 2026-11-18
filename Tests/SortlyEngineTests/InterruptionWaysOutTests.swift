import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyStore
import SortlyTestSupport

/// Review P2 (18.11.2026, PRUEFER-2-SCHUTZ-DER-FOTOS.md, its test file as the template): the
/// app's flow (`AppModel.run`, `finalize`, `load`, `resumeInterruptedPlan`,
/// `undoInterruptedPlan`, `keepInterruptedPlanAsIs`, `undo`) with the real database
/// (`SortlyStore`, in memory) and the test library. The app "dies" at every step boundary:
/// before and after every write to Photos and after every journal write. Then each way out is
/// taken. Whatever happens, the library afterwards is as it was before the plan, or the app
/// names what stays (`UndoRemainder`, P2-01). Before, "Alles zurücknehmen" right after Photos
/// made an album or folder left it behind empty, and after photos went into the user's album
/// it left them there, and the plan disappeared from the history without a word.
@Suite("Interrupted at every step, then each way out (review P2)", .serialized)
struct InterruptionWaysOutTests {
    static func ids(_ range: Range<Int>) -> Set<AssetID> { Set(range.map { AssetID("a-\($0)") }) }
    static let allAssets = ids(0..<300)
    static let ownSommer = ids(250..<255)
    static let ownOma = ids(260..<263)
    static let extra = ids(100..<110)
    static let plannedAlbums: [String: Set<AssetID>] = ["Rom": ids(0..<60), "Paris": ids(60..<70)]
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)

    final class KillSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var tripped: Bool { lock.withLock { value } }
        func trip() { lock.withLock { value = true } }
    }

    enum Kill: Sendable, CustomStringConvertible {
        case none
        case beforeWrite(Int)
        case afterWrite(Int)
        case afterSave(Int)
        var description: String {
            switch self {
            case .none: "no interruption"
            case .beforeWrite(let n): "before Photos write \(n)"
            case .afterWrite(let n): "after Photos write \(n), before the journal"
            case .afterSave(let n): "after journal write \(n)"
            }
        }
    }

    actor Counter {
        private(set) var writes = 0
        func nextWrite() -> Int { defer { writes += 1 }; return writes }
    }

    struct Dead: Error {}

    /// The library until the app "dies": after that no write reaches it. Like PhotoKit, a
    /// create hears the new id inside the change, before Photos stores it.
    struct KillableLibrary: PhotoLibraryWriting {
        let inner: InMemoryPhotoLibrary
        let kill: KillSwitch
        let counter: Counter
        let spec: Kill
        private func write<T>(_ call: () async throws -> T) async throws -> T {
            if kill.tripped { throw Dead() }
            let n = await counter.nextWrite()
            if case .beforeWrite(let k) = spec, k == n { kill.trip(); throw Dead() }
            let value = try await call()
            if case .afterWrite(let k) = spec, k == n { kill.trip(); throw Dead() }
            return value
        }
        func canWrite() async -> Bool { await inner.canWrite() }
        func currentInventory() async throws -> CollectionInventory { try await inner.currentInventory() }
        func availableAssets(_ ids: [AssetID]) async throws -> Set<AssetID> { try await inner.availableAssets(ids) }
        func collection(_ id: CollectionID) async throws -> CollectionSnapshot? { try await inner.collection(id) }
        func createFolder(title: String, parent: CollectionID?) async throws -> CollectionID { try await write { try await inner.createFolder(title: title, parent: parent) } }
        func createAlbum(title: String, parent: CollectionID?) async throws -> CollectionID { try await write { try await inner.createAlbum(title: title, parent: parent) } }
        func createFolder(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try await write { try await inner.createFolder(title: title, parent: parent, noted: noted) }
        }
        func createAlbum(title: String, parent: CollectionID?, noted: @escaping @Sendable (CollectionID) async -> Void) async throws -> CollectionID {
            try await write { try await inner.createAlbum(title: title, parent: parent, noted: noted) }
        }
        func addAssets(_ assets: [AssetID], to album: CollectionID) async throws { try await write { try await inner.addAssets(assets, to: album) } }
        func removeAssets(_ assets: [AssetID], from album: CollectionID) async throws { try await write { try await inner.removeAssets(assets, from: album) } }
        func renameCollection(_ id: CollectionID, to title: String) async throws { try await write { try await inner.renameCollection(id, to: title) } }
        func moveCollection(_ id: CollectionID, from oldParent: CollectionID?, to newParent: CollectionID?) async throws {
            try await write { try await inner.moveCollection(id, from: oldParent, to: newParent) }
        }
        func deleteCollection(_ id: CollectionID) async throws { try await write { try await inner.deleteCollection(id) } }
        func deleteCollections(_ ids: [CollectionID]) async throws { try await write { try await inner.deleteCollections(ids) } }
    }

    /// The journal until the app "dies": what was written before is in the database. The id
    /// written down inside a create counts as a journal write of its own.
    actor KillableJournal: PlanJournal {
        let inner: SortlyStore
        let kill: KillSwitch
        let killAfterSave: Int?
        private(set) var saves = 0
        /// Every version written, to lose the last one (`loseLastEntry`).
        private(set) var history: [ChangePlan] = []
        /// The last journal write never reached the disk (power loss before it was on the
        /// storage): the journal is back at the entry before it (review P2-07).
        func loseLastEntry() async throws {
            guard history.count >= 2 else { return }
            try await inner.save(history[history.count - 2])
        }
        init(inner: SortlyStore, kill: KillSwitch, killAfterSave: Int?) {
            self.inner = inner
            self.kill = kill
            self.killAfterSave = killAfterSave
        }
        private func persisted() {
            if let k = killAfterSave, saves == k { kill.trip() }
            saves += 1
        }
        func save(_ plan: ChangePlan) async throws {
            if kill.tripped { throw Dead() }
            try await inner.save(plan)
            history.append(plan)
            persisted()
        }
        func save(_ plans: [ChangePlan]) async throws {
            if kill.tripped { throw Dead() }
            try await inner.save(plans)
            persisted()
        }
        func noteCreated(_ id: CollectionID, key: String, in plan: ChangePlan) async throws {
            if kill.tripped { throw Dead() }
            try await inner.noteCreated(id, key: key, in: plan)
            if let stored = try await inner.plan(plan.id) { history.append(stored) }
            persisted()
        }
        func plan(_ id: SortlyID) async throws -> ChangePlan? { try await inner.plan(id) }
    }

    struct RunEnd: Sendable {
        var result: ChangePlan?
        var died: Bool
        var writes: Int
        var saves: Int
    }

    /// The app's flow, without the screens, purchases and the selection.
    struct App: Sendable {
        let store: SortlyStore
        let library: InMemoryPhotoLibrary

        func pending() async throws -> [SortlyID] {
            try await store.value([SortlyID].self, forKey: SortlyStore.pendingFinalizationKey) ?? []
        }
        func setPending(adding: SortlyID? = nil, removing: Set<SortlyID> = []) async throws {
            var list = try await pending()
            if let adding, !list.contains(adding) { list.append(adding) }
            list.removeAll { removing.contains($0) }
            try await store.setValue(list, forKey: SortlyStore.pendingFinalizationKey)
        }

        /// `AppModel.finalize`.
        @discardableResult
        func finalize(_ plan: ChangePlan) async -> Bool {
            do {
                let after = try await library.currentInventory()
                try await store.saveInventory(after)
                let states = ManagedAlbumTracker().record(plan, into: try await store.managedAlbums(), inventory: after)
                var done = plan
                done.finalizedAt = Date()
                let left = try await pending().filter { $0 != plan.id }
                try await store.finalize(done, managedAlbums: states, values: [SortlyStore.pendingFinalizationKey: left])
                return true
            } catch {
                return false
            }
        }

        /// `AppModel.finishPendingFinalizations` and `storeWaitingResults`.
        func finishPending() async throws {
            var drop = Set<SortlyID>()
            for id in try await pending() {
                guard let plan = try await store.plan(id) else { drop.insert(id); continue }
                switch plan.status {
                case .completed, .completedWithErrors:
                    if plan.finalizedAt == nil { await finalize(plan) } else { drop.insert(id) }
                case .running, .confirmed:
                    continue
                case .draft, .cancelled:
                    drop.insert(id)
                }
            }
            if !drop.isEmpty { try await setPending(removing: drop) }
        }

        func check() async throws -> ManagedAlbumCheck.Outcome {
            try await ManagedAlbumCheck(store: store, library: library, pause: .zero).run(access: .full)
        }

        /// `AppModel.run`.
        func run(_ plan: ChangePlan, kill spec: Kill = .none, loseLastJournalEntry: Bool = false) async -> RunEnd {
            let kill = KillSwitch()
            let counter = Counter()
            var confirmed = plan
            if confirmed.status == .draft { confirmed.status = .confirmed }
            if confirmed.confirmedAt == nil { confirmed.confirmedAt = Date() }
            var afterSave: Int?
            if case .afterSave(let k) = spec { afterSave = k }
            let journal = KillableJournal(inner: store, kill: kill, killAfterSave: afterSave)
            var result: ChangePlan?
            do {
                try await finishPending()
                try await setPending(adding: confirmed.id)
                let lib = KillableLibrary(inner: library, kill: kill, counter: counter, spec: spec)
                let ended = try await ChangeExecutor(library: lib, store: journal).execute(confirmed)
                if !kill.tripped {
                    result = ended
                    if ended.status == .completed || ended.status == .completedWithErrors { await finalize(ended) }
                }
            } catch {}
            if loseLastJournalEntry, kill.tripped { try? await journal.loseLastEntry() }
            return RunEnd(result: result, died: kill.tripped, writes: await counter.writes, saves: await journal.saves)
        }

        /// `AppModel.load`: results of finished plans stored, albums checked, open plan read.
        func relaunch() async throws -> ChangePlan? {
            try await finishPending()
            _ = try await check()
            return try await store.openInterruptedPlan()
        }

        /// "Fortsetzen" (`AppModel.resumeInterruptedPlan`).
        func resume(_ interrupted: ChangePlan) async throws -> RunEnd {
            _ = try await check()
            let overrides = OverrideSet(try await store.overrides())
            return await run(interrupted.respecting(overrides))
        }

        /// "So lassen" (`AppModel.keepInterruptedPlanAsIs`).
        @discardableResult
        func keep(_ interrupted: ChangePlan) async throws -> ChangePlan {
            let settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted, keeping: true)
            let kept = settled.keptAsIs(current: try await library.currentInventory())
            try await store.save(kept)
            if kept.status == .cancelled { try await setPending(removing: [interrupted.id]) } else { await finalize(kept) }
            return kept
        }

        /// "Alles zurücknehmen" for an interrupted plan (`AppModel.undoInterruptedPlan`): the
        /// outcome and what the app names.
        func takeBack(_ interrupted: ChangePlan) async throws -> (InterruptedPlanUndo.Outcome, UndoRemainder) {
            let settled = try await ChangeExecutor(library: library, store: store).reconcileInterrupted(interrupted)
            let way = InterruptedPlanUndo(settled: settled, current: try await library.currentInventory())
            try await setPending(adding: interrupted.id)
            let outcome = try await way.carryOut(journal: store, finalize: { await self.finalize($0) }, run: { _ = await self.run($0) })
            if outcome == .nothingToTakeBack { try await setPending(removing: [interrupted.id]) }
            return (outcome, way.remainder)
        }

        /// "Rückgängig machen" in the history (`AppModel.undo`), and what the app names
        /// afterwards. Nil when the app does not offer it.
        func undo(_ id: SortlyID) async throws -> (RunEnd, UndoRemainder)? {
            try await finishPending()
            guard let executed = try await store.plan(id), executed.reverts == nil,
                  executed.status == .completed || executed.status == .completedWithErrors,
                  !(try await store.undoneTargets().contains(id)) else { return nil }
            let checked = try await check()
            var owned: [CollectionID: Set<AssetID>] = [:]
            for state in checked.managedAlbums { owned[state.albumID, default: []].formUnion(state.addedBySortly) }
            let earlier = try await store.reverts(of: id)
            let created = Set(checked.managedAlbums.filter { $0.createdBySortly }.map { $0.albumID })
            let undoPlan = UndoPlanner().undoPlan(for: executed, current: checked.inventory, owned: owned, createdByAlbumist: created, earlierUndos: earlier)
            let ended = await run(undoPlan)
            return (ended, UndoRemainder(plan: executed, current: try await library.currentInventory()))
        }
    }

    static func freshApp() throws -> App {
        App(store: try SortlyStore(url: nil), library: InMemoryPhotoLibrary(assets: allAssets, collections: [
            CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: ownSommer),
            CollectionSnapshot(id: "familie", title: "Familie", kind: .folder, childIDs: ["oma"]),
            CollectionSnapshot(id: "oma", title: "Oma", parentID: "familie", assetIDs: ownOma),
        ]))
    }

    func proposal(_ id: String, _ title: String, _ path: [String], _ assets: Set<AssetID>, _ decision: ProposalDecision) -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: SortlyID(id), kind: .trip, title: title, folderPath: path, assetIDs: assets), decision: decision)
    }

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    /// Two new albums in a new folder (one filled in two parts) and the user's album extended.
    func representativePlan(_ inventory: CollectionInventory) -> ChangePlan {
        confirmed(planner.makePlan(from: [
            proposal("r", "Rom", ["Reisen"], Self.ids(0..<60), .createNew(title: nil, folderPath: nil)),
            proposal("p", "Paris", ["Reisen"], Self.ids(60..<70), .createNew(title: nil, folderPath: nil)),
            proposal("s", "Sommer", [], Self.extra, .extendExisting("sommer")),
        ], inventory: inventory))
    }

    /// What must never happen, however it ends.
    static func violations(_ inv: CollectionInventory) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for c in inv.collections.values {
            if !seen.insert("\(c.parentID?.rawValue ?? "-")/\(c.kind == .folder)/\(c.title)").inserted { out.append("twice: \(c.title)") }
        }
        if let s = inv["sommer"] {
            if s.title != "Sommer" || s.parentID != nil { out.append("Sommer renamed or moved") }
            if !s.assetIDs.isSuperset(of: ownSommer) { out.append("Sommer lost own photos") }
            if !s.assetIDs.isSubset(of: ownSommer.union(extra)) { out.append("Sommer got unplanned photos") }
        } else { out.append("Sommer missing") }
        if let f = inv["familie"] {
            if f.title != "Familie" || f.kind != .folder || f.parentID != nil { out.append("Familie changed") }
        } else { out.append("Familie missing") }
        if let o = inv["oma"] {
            if o.title != "Oma" || o.parentID != "familie" || o.assetIDs != ownOma { out.append("Oma changed") }
        } else { out.append("Oma missing") }
        for a in inv.albums where a.id != "sommer" && a.id != "oma" {
            if !a.assetIDs.isSubset(of: plannedAlbums[a.title] ?? []) { out.append("\(a.title) holds unplanned photos") }
        }
        return out
    }

    /// What differs from the library before the plan and is not named by `remainder`, in words.
    static func unnamedLeftovers(_ inv: CollectionInventory, initial: CollectionInventory, remainder: UndoRemainder) -> [String] {
        var out: [String] = []
        let named = Set(remainder.collections.map(\.id))
        for c in inv.collections.values where initial[c.id] == nil {
            let holdsNamed = inv.collections.values.contains { named.contains($0.id) && inv.path(of: $0.id).contains(c.title) }
            if !(named.contains(c.id) || holdsNamed) {
                out.append(c.kind == .folder ? "folder stays (\(c.title))" : c.assetIDs.isEmpty ? "empty album stays (\(c.title))" : "album with photos stays (\(c.title))")
            } else if !c.assetIDs.isEmpty {
                out.append("named album holds photos (\(c.title))")
            }
        }
        for s in initial.collections.values {
            guard let n = inv[s.id] else { out.append("user's album missing (\(s.title))"); continue }
            if n.title != s.title || n.parentID != s.parentID { out.append("user's album changed (\(s.title))") }
            let namedPhotos = remainder.photos.first { $0.album == s.id }?.assets ?? []
            if n.assetIDs != s.assetIDs.union(namedPhotos) { out.append("unnamed photos in the user's album (\(s.title))") }
        }
        return out.sorted()
    }

    // MARK: Interrupted at every step boundary, then the three ways out

    @Test func interruptedAtEveryStepThenEachWayOutLeavesNothingUnnamed() async throws {
        let probe = try Self.freshApp()
        let clean = await probe.run(representativePlan(try await probe.check().inventory))
        #expect(clean.result?.status == .completed)
        var specs: [Kill] = []
        for n in 0..<clean.writes { specs.append(.beforeWrite(n)); specs.append(.afterWrite(n)) }
        for n in 0..<clean.saves { specs.append(.afterSave(n)) }
        #expect(specs.count > 30)

        var problems: [String] = []
        var leftUnclear = 0
        for spec in specs {
            for way in ["resume", "take back", "keep"] {
                let label = "\(spec), \(way)"
                let app = try Self.freshApp()
                let initial = try await app.library.currentInventory()
                let plan = representativePlan(try await app.check().inventory)
                let first = await app.run(plan, kill: spec)
                #expect(first.died, "\(label)")
                problems += Self.violations(try await app.library.currentInventory()).map { "\($0) [interrupted: \(label)]" }
                let atInterruption = try await app.library.currentInventory()

                guard let interrupted = try await app.relaunch() else {
                    // Nothing open: the plan finished (cut off before its results were stored)
                    // or never started. The ordinary undo in the history remains.
                    if let (undone, remainder) = try await app.undo(plan.id) {
                        #expect(undone.result?.status == .completed, "\(label)")
                        problems += Self.unnamedLeftovers(try await app.library.currentInventory(), initial: initial, remainder: remainder).map { "\($0) [\(label)]" }
                    }
                    continue
                }
                #expect(interrupted.id == plan.id, "\(label)")

                switch way {
                case "resume":
                    _ = try await app.resume(interrupted)
                    problems += Self.violations(try await app.library.currentInventory()).map { "\($0) [\(label)]" }
                    #expect(try await app.store.openInterruptedPlan() == nil, "\(label)")
                    let (undone, remainder) = try #require(try await app.undo(plan.id), "\(label)")
                    #expect(undone.result?.status == .completed, "\(label)")
                    problems += Self.unnamedLeftovers(try await app.library.currentInventory(), initial: initial, remainder: remainder).map { "\($0) [\(label), then undo]" }

                case "take back":
                    let (outcome, remainder) = try await app.takeBack(interrupted)
                    let inv = try await app.library.currentInventory()
                    problems += Self.violations(inv).map { "\($0) [\(label)]" }
                    #expect(try await app.store.openInterruptedPlan() == nil, "\(label)")
                    problems += Self.unnamedLeftovers(inv, initial: initial, remainder: remainder).map { "\($0) [\(label)]" }
                    let stored = try await app.store.plan(plan.id)
                    if remainder.isEmpty {
                        #expect(inv == initial, "\(label)")
                        #expect(outcome == .undone || outcome == .nothingToTakeBack, "\(label): \(outcome)")
                    } else {
                        // Something stays: the plan is not dropped, and the outcome says so.
                        leftUnclear += 1
                        #expect(outcome == .leftUnclear, "\(label): \(outcome)")
                        #expect(stored?.status != .cancelled, "\(label)")
                        #expect(try await app.store.planHistory().contains { $0.id == plan.id }, "\(label)")
                    }

                default:
                    let kept = try await app.keep(interrupted)
                    // "So lassen" changes nothing in Photos.
                    #expect(try await app.library.currentInventory() == atInterruption, "\(label)")
                    #expect(try await app.store.openInterruptedPlan() == nil, "\(label)")
                    if kept.status != .cancelled {
                        let (undone, remainder) = try #require(try await app.undo(plan.id), "\(label)")
                        #expect(undone.result?.status == .completed, "\(label)")
                        problems += Self.unnamedLeftovers(try await app.library.currentInventory(), initial: initial, remainder: remainder).map { "\($0) [\(label), then undo]" }
                    } else {
                        #expect(try await app.library.currentInventory() == initial, "\(label)")
                    }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(8))")
        // Only the interruption right after the photos reached the user's own album leaves
        // something that cannot be proven; every album and folder is provably Albumist's.
        #expect(leftUnclear > 0)
    }

    /// "Alles zurücknehmen" right after Photos created an album, and right after Albumist's
    /// photos reached the user's own album: what stays in Photos, what Albumist still knows of
    /// it, and the same suggestions carried out again (they come back to the selection).
    @Test(arguments: [true, false])
    func takeBackRightAfterAWriteLeavesNothingWithoutATrace(albumCreated: Bool) async throws {
        let app = try Self.freshApp()
        let initial = try await app.library.currentInventory()
        let plan = representativePlan(try await app.check().inventory)
        // Probe which write makes "Rom" or fills "Sommer", and end right after it.
        let probe = try Self.freshApp()
        let probePlan = representativePlan(try await probe.check().inventory)
        var kill: Kill?
        for n in 0..<20 {
            let p = try Self.freshApp()
            _ = await p.run(probePlan, kill: .afterWrite(n))
            let inv = try await p.library.currentInventory()
            let hit = albumCreated
                ? inv.albums.contains { $0.title == "Rom" } && inv.albums.first { $0.title == "Rom" }?.assetIDs.isEmpty == true
                : inv["sommer"]?.assetIDs != Self.ownSommer
            if hit { kill = .afterWrite(n); break }
        }
        let spec = try #require(kill)
        #expect(await app.run(plan, kill: spec).died)
        let interrupted = try #require(try await app.relaunch())
        let (outcome, remainder) = try await app.takeBack(interrupted)
        let inv = try await app.library.currentInventory()
        let stored = try #require(try await app.store.plan(plan.id))
        if albumCreated {
            // Provably Albumist's (its id was written down inside the change): all gone.
            #expect(outcome == .undone)
            #expect(remainder.isEmpty)
            #expect(inv == initial)
            #expect(stored.status == .cancelled)
        } else {
            // The photos in "Sommer" cannot be proven Albumist's: they stay, and are named.
            #expect(outcome == .leftUnclear)
            #expect(remainder.collections.isEmpty)
            #expect(remainder.photos.map(\.album) == ["sommer"])
            #expect(remainder.photos.first?.assets == Self.extra)
            #expect(Self.unnamedLeftovers(inv, initial: initial, remainder: remainder).isEmpty)
            #expect(stored.status != .cancelled)
            #expect(try await app.store.planHistory().contains { $0.id == plan.id })
        }
        // The same suggestions again: never a second album of the same name.
        let again = representativePlan(try await app.check().inventory)
        #expect(await app.run(again).result?.status == .completed)
        #expect(Self.violations(try await app.library.currentInventory()).isEmpty)
        let (undone, rest) = try #require(try await app.undo(again.id))
        #expect(undone.result?.status == .completed)
        #expect(Self.unnamedLeftovers(try await app.library.currentInventory(), initial: initial, remainder: rest)
            .allSatisfy { $0 == "unnamed photos in the user's album (Sommer)" } == true)
    }

    // MARK: P2-07: the journal one entry behind Photos

    /// The last journal write before the app ended never reached the disk (power loss), but
    /// Photos has the change. Before, "Fortsetzen" then made "Reisen", "Paris" and "Rom" a
    /// second time (the step was no longer journaled as running, so nothing was checked), and
    /// the undo left albums with photos behind.
    @Test func journalOneEntryBehindPhotosNeverMakesAnAlbumTwice() async throws {
        let probe = try Self.freshApp()
        let clean = await probe.run(representativePlan(try await probe.check().inventory))
        var problems: [String] = []
        for n in 0..<clean.writes {
            let label = "journal loses its last entry after Photos write \(n)"
            let app = try Self.freshApp()
            let initial = try await app.library.currentInventory()
            let plan = representativePlan(try await app.check().inventory)
            #expect(await app.run(plan, kill: .afterWrite(n), loseLastJournalEntry: true).died, "\(label)")
            guard let interrupted = try await app.relaunch() else { continue }
            _ = try await app.resume(interrupted)
            problems += Self.violations(try await app.library.currentInventory()).map { "\($0) [\(label), resumed]" }
            if let (undone, remainder) = try await app.undo(plan.id) {
                #expect(undone.result?.status == .completed, "\(label)")
                let end = try await app.library.currentInventory()
                problems += Self.violations(end).map { "\($0) [\(label), undone]" }
                problems += Self.unnamedLeftovers(end, initial: initial, remainder: remainder).map { "\($0) [\(label), undone]" }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(8))")
    }
}
