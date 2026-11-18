import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// The rules behind the one-time purchase: free albums (FreeAlbumLedger, ChangePlan.freeAlbumUse)
/// and which App Store entitlements unlock (PurchaseRules). StoreKit itself is tested in the
/// app target (App/SortlyTests/PurchaseStoreKitTests.swift, StoreKit configuration file).
@Suite("Purchase: free albums and unlock")
struct PurchaseRulesTests {
    /// `Purchases.freeAlbumLimit` in the app (decision: 10 albums free).
    let limit = 10
    let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))

    /// A plan that creates `count` new albums with one photo each.
    func plan(_ id: String, creating count: Int) -> ChangePlan {
        let proposals = (0..<count).map { i in
            ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("\(id)-\(i)"), kind: .trip, title: "Album \(i)", folderPath: [], assetIDs: [AssetID("\(id)-\(i)")]),
                              decision: .createNew(title: nil, folderPath: nil))
        }
        var p = OrganizationPlanner().makePlan(from: proposals, inventory: CollectionInventory())
        p.id = SortlyID(id)
        return p
    }

    /// Every step marked as done, as after a run without problems.
    func applied(_ p: ChangePlan) -> ChangePlan {
        var p = p
        for i in p.steps.indices { p.steps[i].state = done }
        p.status = .completed
        return p
    }

    // MARK: Limit

    @Test func exactlyAtTheLimitIsAllowedOneMoreIsNot() {
        var ledger = FreeAlbumLedger()
        let first = plan("first", creating: 7)
        #expect(first.freeAlbumUse(applied: false) == 7)
        #expect(ledger.allows(albums: 7, limit: limit, unlocked: false))
        ledger.record(plan: first.id, albums: applied(first).freeAlbumUse(applied: true))
        #expect(ledger.remaining(limit: limit) == 3)

        // Exactly the rest: allowed, and nothing is left afterwards.
        let exact = plan("exact", creating: 3)
        #expect(ledger.allows(albums: exact.freeAlbumUse(applied: false), limit: limit, unlocked: false))
        ledger.record(plan: exact.id, albums: applied(exact).freeAlbumUse(applied: true))
        #expect(ledger.used == 10)
        #expect(ledger.remaining(limit: limit) == 0)

        // At the limit: one more album needs the unlock, a plan that makes no album does not.
        #expect(!ledger.allows(albums: 1, limit: limit, unlocked: false))
        #expect(ledger.allows(albums: 0, limit: limit, unlocked: false))
        #expect(ledger.allows(albums: 1, limit: limit, unlocked: true))
        #expect(ledger.allows(albums: 500, limit: limit, unlocked: true))
    }

    /// A plan that would pass the limit half way is not started at all (never cut off in the
    /// middle); the unlock card offers to make the albums that are still free.
    @Test func planPassingTheLimitHalfWayIsStoppedBeforeItStarts() {
        let ledger = FreeAlbumLedger(byPlan: ["earlier": 8])
        let big = plan("big", creating: 5)
        #expect(big.freeAlbumUse(applied: false) == 5)
        #expect(!ledger.allows(albums: 5, limit: limit, unlocked: false))
        #expect(ledger.remaining(limit: limit) == 2) // "Die ersten 2 jetzt kostenlos anlegen"
        let firstTwo = plan("two", creating: 2)
        #expect(ledger.allows(albums: firstTwo.freeAlbumUse(applied: false), limit: limit, unlocked: false))
    }

    /// Extending an existing album counts once per album, however many steps add to it.
    @Test func extendingAnAlbumCountsOncePerAlbum() {
        let inventory = CollectionInventory([CollectionSnapshot(id: "rom", title: "Rom", assetIDs: ["old"])])
        let proposal = AlbumProposal(id: SortlyID("s"), kind: .trip, title: "Rom", folderPath: [], assetIDs: ["new1", "new2"])
        var p = OrganizationPlanner().makePlan(from: [ConfirmedProposal(proposal: proposal, decision: .extendExisting("rom"))], inventory: inventory)
        p.steps.append(PlanStep(id: "extra", operation: .addAssets(album: .existing("rom"), assets: ["new3"]), sourceID: nil))
        #expect(p.freeAlbumUse(applied: false) == 1)
    }

    /// Only what really happened counts: a plan that made 2 of 3 albums uses 2.
    @Test func onlyAlbumsThatReallyCameCount() {
        var p = applied(plan("partial", creating: 3))
        let lastCreate = p.steps.lastIndex { if case .createAlbum = $0.operation { true } else { false } }!
        p.steps[lastCreate].state = .failed(reason: "interrupted")
        p.status = .completedWithErrors
        #expect(p.freeAlbumUse(applied: false) == 3)
        #expect(p.freeAlbumUse(applied: true) == 2)
        var ledger = FreeAlbumLedger()
        ledger.record(plan: p.id, albums: p.freeAlbumUse(applied: true))
        #expect(ledger.remaining(limit: limit) == 8)
    }

    /// An interrupted plan continues without a new check. Until it is counted its albums are
    /// held back, so a second plan cannot use them first and the total pass the limit.
    @Test func interruptedPlanHoldsItsFreeAlbumsBack() {
        var ledger = FreeAlbumLedger(byPlan: ["earlier": 4])
        let interrupted = plan("interrupted", creating: 5)
        let reserved = [interrupted.id: interrupted.freeAlbumUse(applied: false)]
        #expect(ledger.remaining(limit: limit, reserved: reserved) == 1)
        #expect(!ledger.allows(albums: 2, limit: limit, unlocked: false, reserved: reserved))
        #expect(ledger.allows(albums: 1, limit: limit, unlocked: false, reserved: reserved))

        // Continued and finished: now counted, the reservation holds nothing any more.
        ledger.record(plan: interrupted.id, albums: 5)
        #expect(ledger.used == 9)
        #expect(ledger.remaining(limit: limit, reserved: reserved) == 1)
        // Taken back instead: nothing counted, nothing held.
        ledger.giveBack(plan: interrupted.id, albums: 5)
        #expect(ledger.remaining(limit: limit, reserved: reserved) == 6)
    }

    // MARK: Counting never twice

    /// The ledger is stored as one value. The app counts a plan before it writes the
    /// finalization to the database; ending in between finalizes the plan again at the next
    /// launch. Whatever reached the disk, the plan counts exactly once.
    @Test func crashBetweenCountingAndStoreWriteCountsOnce() throws {
        let p = applied(plan("p", creating: 3))
        var ledger = FreeAlbumLedger(legacyUsed: 2)
        // Counted, ledger on disk, app ends before the database write.
        ledger.record(plan: p.id, albums: p.freeAlbumUse(applied: true))
        let onDisk = try JSONEncoder().encode(ledger)
        var relaunched = try JSONDecoder().decode(FreeAlbumLedger.self, from: onDisk)
        #expect(relaunched == ledger)
        // The finalization runs again.
        let countedAgain = relaunched.record(plan: p.id, albums: p.freeAlbumUse(applied: true))
        #expect(!countedAgain)
        #expect(relaunched.used == 5)

        // App ended before the ledger was written: counted at the next launch, once.
        var notWritten = FreeAlbumLedger(legacyUsed: 2)
        let counted = notWritten.record(plan: p.id, albums: 3)
        #expect(counted)
        let countedTwice = notWritten.record(plan: p.id, albums: 3)
        #expect(!countedTwice)
        #expect(notWritten.used == 5)
    }

    /// A completed undo gives the albums back when its finalization runs, once, also when
    /// the app ends in between and the finalization runs again; the launch check (plans the
    /// journal shows as taken back) never gives back a second time either.
    @Test func undoGivesAlbumsBackOnceAcrossACrash() throws {
        let p = applied(plan("p", creating: 4))
        var ledger = FreeAlbumLedger()
        ledger.record(plan: p.id, albums: 4)
        #expect(ledger.remaining(limit: limit) == 6)
        ledger.giveBack(plan: p.id, albums: p.freeAlbumUse(applied: true))
        #expect(ledger.remaining(limit: limit) == 10)
        var relaunched = try JSONDecoder().decode(FreeAlbumLedger.self, from: JSONEncoder().encode(ledger))
        let givenBackAgain = relaunched.giveBack(plan: p.id, albums: 4)
        #expect(!givenBackAgain)
        let settledAgain = relaunched.settleUndone([p.id])
        #expect(!settledAgain)
        let countedAfterUndo = relaunched.record(plan: p.id, albums: 4)
        #expect(!countedAfterUndo) // an undone plan never counts again
        #expect(relaunched.remaining(limit: limit) == 10)

        // The app ended after the undo but before the albums were given back: the launch
        // check settles it.
        var beforeGiveBack = FreeAlbumLedger(byPlan: [p.id.rawValue: 4])
        let settled = beforeGiveBack.settleUndone([p.id])
        #expect(settled)
        #expect(beforeGiveBack.remaining(limit: limit) == 10)
        // The finalization of the undo runs afterwards: nothing more to give back.
        let givenBackAfterSettling = beforeGiveBack.giveBack(plan: p.id, albums: 4)
        #expect(!givenBackAfterSettling)
        #expect(beforeGiveBack.remaining(limit: limit) == 10)
    }

    /// A plan counted in the older total (versions before the per-plan count) is given back
    /// once, and the give-back stays when the two copies of the count (user defaults,
    /// keychain) went apart: the app ended between the two writes, or one write never reached
    /// the disk. The copies used to be put together with the larger older total, which took
    /// the give-back away again while the plan stayed marked as given back: its undone albums
    /// counted for good.
    @Test func olderTotalGiveBackSurvivesCopiesThatWentApart() throws {
        let old = applied(plan("old", creating: 3))
        let before = FreeAlbumLedger(legacyUsed: 7)
        var written = before
        let givenBack = written.giveBack(plan: old.id, albums: old.freeAlbumUse(applied: true))
        #expect(givenBack)
        #expect(written.remaining(limit: limit) == 6)
        // Only one copy has the give-back, in either order.
        for merged in [before.merged(with: written), written.merged(with: before)] {
            var relaunched = try JSONDecoder().decode(FreeAlbumLedger.self, from: JSONEncoder().encode(merged))
            #expect(relaunched.remaining(limit: limit) == 6)
            // The undo's finalization and the launch check run again: nothing more comes back,
            // and the plan is not counted again either.
            let givenBackAgain = relaunched.giveBack(plan: old.id, albums: 3)
            let settledAgain = relaunched.settleUndone([old.id])
            let countedAgain = relaunched.record(plan: old.id, albums: 3)
            #expect(!givenBackAgain && !settledAgain && !countedAgain)
            #expect(relaunched.remaining(limit: limit) == 6)
            // Putting the copies together again changes nothing.
            #expect(relaunched.merged(with: before) == relaunched)
            #expect(relaunched.merged(with: written) == relaunched)
        }
    }

    /// Two plans of the older total given back in different copies both come back; giving
    /// back more than the older total held never makes more than the allowance free, and a
    /// later plan still counts in full.
    @Test func olderTotalGiveBacksAddUpAcrossCopiesButNeverPassTheAllowance() {
        let start = FreeAlbumLedger(legacyUsed: 5)
        var a = start
        a.giveBack(plan: SortlyID("a"), albums: 2)
        var b = start
        b.giveBack(plan: SortlyID("b"), albums: 2)
        let both = a.merged(with: b)
        #expect(both.used == 1)
        #expect(both == b.merged(with: a))
        var over = both
        over.giveBack(plan: SortlyID("c"), albums: 9)
        #expect(over.used == 0)
        #expect(over.remaining(limit: limit) == limit)
        #expect(over.merged(with: start).remaining(limit: limit) == limit)
        over.record(plan: SortlyID("new"), albums: 4)
        #expect(over.remaining(limit: limit) == 6)
    }

    /// The ledger an earlier version wrote (its older total already lowered by its give-backs)
    /// is read as it was; a version before this one reads the albums still counted.
    @Test func ledgerOfEarlierVersionsStaysReadableBothWays() throws {
        let earlier = Data(#"{"legacyUsed":4,"byPlan":{"a":2},"returned":["x"]}"#.utf8)
        let decoded = try JSONDecoder().decode(FreeAlbumLedger.self, from: earlier)
        #expect(decoded.used == 6)
        // The same history kept by this version: put together, "x" comes back once.
        var now = FreeAlbumLedger(legacyUsed: 6, byPlan: ["a": 2])
        now.giveBack(plan: SortlyID("x"), albums: 2)
        #expect(now.used == 6)
        #expect(decoded.merged(with: now).used == 6)
        #expect(now.merged(with: decoded).used == 6)
        struct EarlierReader: Decodable { var legacyUsed: Int; var byPlan: [String: Int]; var returned: Set<String> }
        let read = try JSONDecoder().decode(EarlierReader.self, from: JSONEncoder().encode(now))
        #expect(read.legacyUsed == 4)
        #expect(read.returned == ["x"])
    }

    /// A UI run starts with a set number of free albums left, in a count of its own that
    /// begins empty at every launch. Taking back plans of earlier runs (never counted in it)
    /// gave their albums back from that start, again at every launch that finalized the undo
    /// once more: the run then had more free albums than it set.
    @Test func setStartIsNotGivenBackByPlansItNeverCounted() throws {
        var ledger = FreeAlbumLedger(startingWithUsed: 9)
        #expect(ledger.remaining(limit: limit) == 1)
        ledger.giveBack(plan: SortlyID("earlier-1"), albums: 3)
        ledger.giveBack(plan: SortlyID("earlier-2"), albums: 2)
        #expect(ledger.remaining(limit: limit) == 1)
        // A plan of this run counts and comes back as usual.
        ledger.record(plan: SortlyID("now"), albums: 1)
        #expect(ledger.remaining(limit: limit) == 0)
        ledger.giveBack(plan: SortlyID("now"), albums: 1)
        #expect(ledger.remaining(limit: limit) == 1)
        let relaunched = try JSONDecoder().decode(FreeAlbumLedger.self, from: JSONEncoder().encode(ledger))
        #expect(relaunched.remaining(limit: limit) == 1)
    }

    /// A retry ("Erneut versuchen") does not count the albums the first run made again.
    @Test func retryDoesNotCountTheFirstRunsAlbumsAgain() {
        var retry = applied(plan("retry", creating: 1))
        retry.steps.append(PlanStep(id: "add", operation: .addAssets(album: .existing("made-by-first-run"), assets: ["x"]), sourceID: nil, state: done))
        retry.albumsFromRetriedPlan = ["made-by-first-run"]
        #expect(retry.freeAlbumUse(applied: true) == 1)
    }

    /// The ledger written by versions before the per-plan count keeps its total.
    @Test func ledgerDecodesAndKeepsItsOlderTotal() throws {
        let ledger = FreeAlbumLedger(legacyUsed: 3, byPlan: ["a": 2], returned: ["b"])
        let decoded = try JSONDecoder().decode(FreeAlbumLedger.self, from: JSONEncoder().encode(ledger))
        #expect(decoded == ledger)
        #expect(decoded.remaining(limit: limit) == 5)
        // Never below zero, even with a total above the limit.
        #expect(FreeAlbumLedger(legacyUsed: 14).remaining(limit: limit) == 0)
    }

    // MARK: Unlock (StoreKit entitlements)

    let unlock = "app.albumist.ios.unlock"

    @Test func onlyAVerifiedNotRevokedPurchaseOfTheProductUnlocks() {
        typealias E = PurchaseRules.Entitlement
        #expect(!PurchaseRules.isUnlocked(by: [], productID: unlock))
        #expect(PurchaseRules.isUnlocked(by: [E(productID: unlock)], productID: unlock))
        // Refunded: locked again.
        #expect(!PurchaseRules.isUnlocked(by: [E(productID: unlock, isRevoked: true)], productID: unlock))
        // A receipt StoreKit cannot verify never unlocks.
        #expect(!PurchaseRules.isUnlocked(by: [E(productID: unlock, isVerified: false)], productID: unlock))
        // Another product (a future tip jar, a test product) does not unlock.
        #expect(!PurchaseRules.isUnlocked(by: [E(productID: "app.albumist.ios.other")], productID: unlock))
        // One valid purchase among refunded ones is enough (bought again after a refund).
        #expect(PurchaseRules.isUnlocked(by: [E(productID: unlock, isRevoked: true), E(productID: unlock)], productID: unlock))
    }

    /// Family Sharing (if switched on for the product in App Store Connect): a shared purchase
    /// unlocks like an own one; when the organizer stops sharing, StoreKit revokes it.
    @Test func familySharedPurchaseUnlocksUntilSharingStops() {
        typealias E = PurchaseRules.Entitlement
        #expect(PurchaseRules.isUnlocked(by: [E(productID: unlock, isFamilyShared: true)], productID: unlock))
        #expect(!PurchaseRules.isUnlocked(by: [E(productID: unlock, isRevoked: true, isFamilyShared: true)], productID: unlock))
    }

    /// An older read of StoreKit's list never undoes what the running app was just told.
    @Test func olderReadNeverLocksWhatWasJustBoughtOrApproved() {
        typealias E = PurchaseRules.Entitlement
        var known = PurchaseRules.SessionKnowledge()
        // Ask to Buy approved at launch, or a purchase: the update arrives first ...
        known.saw(transactionID: 7, productID: unlock, isRevoked: false, unlockProductID: unlock)
        // ... and the launch read, started earlier, comes back without it.
        let read1 = known.isUnlocked(listed: [], productID: unlock)
        #expect(read1)
        // Later reads list it: still unlocked.
        let read2 = known.isUnlocked(listed: [E(productID: unlock, transactionID: 7)], productID: unlock)
        #expect(read2)
        // Other products the app was handed never unlock.
        var other = PurchaseRules.SessionKnowledge()
        other.saw(transactionID: 8, productID: "app.albumist.ios.other", isRevoked: false, unlockProductID: unlock)
        let read3 = other.isUnlocked(listed: [], productID: unlock)
        #expect(!read3)
    }

    /// A refund arrives as an update; a read that still lists the purchase unrevoked does not
    /// unlock it again. Another valid purchase (bought again, or shared) still unlocks.
    @Test func olderReadNeverUnlocksWhatWasJustRefunded() {
        typealias E = PurchaseRules.Entitlement
        var known = PurchaseRules.SessionKnowledge()
        known.saw(transactionID: 7, productID: unlock, isRevoked: false, unlockProductID: unlock)
        known.saw(transactionID: 7, productID: unlock, isRevoked: true, unlockProductID: unlock)
        let read4 = known.isUnlocked(listed: [E(productID: unlock, transactionID: 7)], productID: unlock)
        #expect(!read4)
        let read5 = known.isUnlocked(listed: [], productID: unlock)
        #expect(!read5)
        // A late "not revoked" message about the same transaction does not bring it back.
        known.saw(transactionID: 7, productID: unlock, isRevoked: false, unlockProductID: unlock)
        let read6 = known.isUnlocked(listed: [], productID: unlock)
        #expect(!read6)
        let read7 = known.isUnlocked(listed: [E(productID: unlock, isFamilyShared: true, transactionID: 9)], productID: unlock)
        #expect(read7)
    }

    /// The list itself reports a revocation the app was not told about (refund while closed):
    /// that transaction stops counting, also when the app saw it bought earlier.
    @Test func revocationInTheListEndsWhatTheAppSaw() {
        typealias E = PurchaseRules.Entitlement
        var known = PurchaseRules.SessionKnowledge()
        known.saw(transactionID: 7, productID: unlock, isRevoked: false, unlockProductID: unlock)
        let read8 = known.isUnlocked(listed: [E(productID: unlock, isRevoked: true, transactionID: 7)], productID: unlock)
        #expect(!read8)
        let read9 = known.isUnlocked(listed: [E(productID: unlock, transactionID: 7)], productID: unlock)
        #expect(!read9)
        #expect(known.revoked == [7])
        #expect(known.unlocking.isEmpty)
    }

    // MARK: Price

    /// The price shown is always StoreKit's (`product.displayPrice`): 2,99 € in the launch
    /// week and 4,99 € after are set in App Store Connect. No price may be written into the
    /// app's code or strings, or the launch week would show the wrong one.
    @Test func noPriceIsWrittenIntoTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("App/Sortly")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let checked = files.filter { ["swift", "xcstrings", "plist"].contains($0.pathExtension) }
            // Text drawn into the demo photos (a receipt shows "89,90 €"), not a price of Albumist.
            .filter { $0.lastPathComponent != "DemoLibrary.swift" }
        #expect(checked.count > 20)
        let price = try Regex(#"[0-9]+[,.][0-9]{2}\s?(€|EUR)|€\s?[0-9]|\b[0-9][,.]99\b"#)
        var found: [String] = []
        for file in checked {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains(price) {
                found.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(found.isEmpty, "Hard-coded price: \(found.joined(separator: "\n"))")
    }
}

/// W7: the unlock button without a price from the App Store.
@Suite("Unlock button without a price")
struct UnlockButtonTests {
    @Test func noPriceMeansLoadingAndNoTap() {
        #expect(PurchaseRules.unlockButton(hasPrice: false, isPurchasing: false) == .loadingPrice)
        #expect(!PurchaseRules.unlockButton(hasPrice: false, isPurchasing: false).isEnabled)
        #expect(PurchaseRules.unlockButton(hasPrice: true, isPurchasing: false) == .buy)
        #expect(PurchaseRules.unlockButton(hasPrice: true, isPurchasing: false).isEnabled)
        #expect(PurchaseRules.unlockButton(hasPrice: true, isPurchasing: true) == .purchasing)
        #expect(!PurchaseRules.unlockButton(hasPrice: false, isPurchasing: true).isEnabled)
    }

    @Test func priceIsLoadedAgainWithGrowingPauses() {
        #expect((0...6).map(PurchaseRules.priceRetryDelay) == [2, 4, 8, 16, 30, 30, 30])
        #expect(PurchaseRules.priceRetryDelay(attempt: -1) == 2)
    }
}
