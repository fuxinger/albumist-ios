import Foundation
import StoreKit
import StoreKitTest
import Testing
import SortlyCore
@testable import Sortly

private final class BundleToken {}

/// The purchase against StoreKit itself: the app's product from the StoreKit configuration
/// file (App/StoreKit/Albumist.storekit) in a local test session, no App Store account
/// needed. Every case of the one-time unlock is set up here and its outcome checked. The
/// rules behind it (free-album count, which entitlements unlock) are tested on Linux in
/// Tests/SortlyCoreTests/PurchaseRulesTests.swift.
@Suite("Purchase with StoreKit", .serialized)
@MainActor
struct PurchaseStoreKitTests {
    static func configurationURL() throws -> URL {
        if let url = Bundle(for: BundleToken.self).url(forResource: "Albumist", withExtension: "storekit") { return url }
        // The file in the repository (the simulator reads the Mac's files) if the bundle lacks it.
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StoreKit/Albumist.storekit")
        guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileNoSuchFile) }
        return file
    }

    /// A fresh session without transactions or dialogs, German storefront. `price`: the same
    /// product with another price, as App Store Connect sets it for the launch week.
    func session(price: String? = nil) throws -> SKTestSession {
        var url = try Self.configurationURL()
        if let price {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains(#""displayPrice" : "4.99""#))
            url = FileManager.default.temporaryDirectory.appendingPathComponent("Albumist-\(UUID().uuidString).storekit")
            try text.replacingOccurrences(of: #""displayPrice" : "4.99""#, with: #""displayPrice" : "\#(price)""#)
                .write(to: url, atomically: true, encoding: .utf8)
        }
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.storefront = "DEU"
        session.locale = Locale(identifier: "de_DE")
        session.clearTransactions()
        return session
    }

    /// A Purchases object as on a fresh install: its own empty defaults.
    func freshInstall(_ name: String = UUID().uuidString, productID: String = Purchases.unlockProductID) -> (Purchases, UserDefaults) {
        let suite = "albumist.tests.purchases.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (Purchases(defaults: defaults, productID: productID), defaults)
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out: \(what)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    func normalized(_ price: String) -> String {
        price.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func transactions(_ session: SKTestSession) -> [SKTestTransaction] {
        session.allTransactions().filter { $0.productIdentifier == Purchases.unlockProductID }
    }

    // MARK: Product and price

    @Test func productAndPriceComeFromStoreKit() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let (purchases, _) = freshInstall()
        await purchases.loadProduct()
        let product = try #require(purchases.product)
        print("STOREKIT_PRICE regular \(product.displayPrice)")
        #expect(product.id == "app.albumist.ios.unlock")
        #expect(product.type == .nonConsumable)
        #expect(product.price == Decimal(string: "4.99"))
        #expect(normalized(product.displayPrice).contains("4,99") || product.displayPrice.contains("4.99"))
        #expect(product.displayPrice.contains("€"))
    }

    /// Launch week: App Store Connect sets 2,99 €, and that is what the app shows. Nothing in
    /// the app holds a price (checked on Linux, `noPriceIsWrittenIntoTheApp`).
    @Test func launchWeekPriceIsWhatStoreKitSays() async throws {
        let session = try session(price: "2.99")
        defer { session.clearTransactions() }
        let (purchases, _) = freshInstall()
        await purchases.loadProduct()
        let product = try #require(purchases.product)
        print("STOREKIT_PRICE launch week \(product.displayPrice)")
        #expect(product.price == Decimal(string: "2.99"))
        #expect(normalized(product.displayPrice).contains("2,99") || product.displayPrice.contains("2.99"))
        #expect(!product.displayPrice.contains("4"))
    }

    // MARK: Buying

    @Test func buyingUnlocksAndStaysUnlockedAfterARestart() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let (purchases, defaults) = freshInstall()
        #expect(!purchases.isUnlocked)
        #expect(!purchases.allows(albums: Purchases.freeAlbumLimit + 1))
        // The product was never loaded (a start without network): buying loads it first.
        #expect(purchases.product == nil)
        await purchases.purchase()
        #expect(purchases.isUnlocked)
        #expect(purchases.lastError == nil)
        #expect(!purchases.isPurchasing)
        #expect(purchases.allows(albums: 500))
        #expect(transactions(session).count == 1)

        // Next launch: StoreKit still knows the purchase.
        let relaunched = Purchases(defaults: defaults)
        #expect(!relaunched.isUnlocked)
        await relaunched.refreshEntitlements()
        #expect(relaunched.isUnlocked)
    }

    /// Bought on another device (or before the app was deleted): a new install unlocks at its
    /// start without any tap, and "Kauf wiederherstellen" finds it too.
    @Test func purchaseFromAnotherDeviceOrBeforeReinstallIsRestored() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        try session.buyProduct(productIdentifier: Purchases.unlockProductID)
        #expect(transactions(session).count == 1)

        let (secondDevice, _) = freshInstall()
        #expect(!secondDevice.isUnlocked)
        await secondDevice.refreshEntitlements()
        #expect(secondDevice.isUnlocked)

        let (reinstalled, _) = freshInstall()
        reinstalled.lastError = "an earlier message"
        // `AppStore.sync()` may ask the App Store; the test waits for the outcome instead of
        // blocking on the call.
        Task { await reinstalled.restore() }
        _ = await waitUntil("restore finished") { reinstalled.isUnlocked && !reinstalled.isPurchasing }
        #expect(reinstalled.isUnlocked)
        #expect(reinstalled.lastError == nil)
    }

    @Test func restoreWithoutPurchaseSaysSo() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let (purchases, _) = freshInstall()
        Task { await purchases.restore() }
        _ = await waitUntil("restore finished") { purchases.lastError != nil && !purchases.isPurchasing }
        #expect(!purchases.isUnlocked)
        print("STOREKIT_RESTORE_EMPTY \(purchases.lastError ?? "-")")
        #expect(purchases.lastError != nil)
    }

    // MARK: Cancelled, pending, failed, offline

    @Test func cancelledPurchaseChangesNothing() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let (purchases, defaults) = freshInstall()
        purchases.recordUsage(plan: SortlyID("plan"), albums: 3)
        purchases.lastError = "an earlier message"
        await purchases.handle(.userCancelled)
        #expect(!purchases.isUnlocked)
        #expect(purchases.lastError == nil)
        purchases.lastError = "an earlier message"
        purchases.handle(StoreKitError.userCancelled)
        #expect(purchases.lastError == nil)
        #expect(Purchases(defaults: defaults).remainingFreeAlbums == Purchases.freeAlbumLimit - 3)
        #expect(transactions(session).isEmpty)
    }

    /// Ask to Buy: the purchase waits for the parent; the app says so and unlocks by itself
    /// once it is approved, and stays locked when it is declined.
    @Test func askToBuyWaitsAndUnlocksWhenApproved() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let (purchases, _) = freshInstall()
        purchases.start()
        await purchases.purchase()
        #expect(!purchases.isUnlocked)
        #expect(purchases.lastError == String(localized: "Der Kauf wartet noch auf eine Bestätigung, zum Beispiel durch die Familienfreigabe. Albumist schaltet sich danach von selbst frei."))
        let pending = try #require(transactions(session).first { $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        _ = await waitUntil("unlocked after approval") { purchases.isUnlocked }
        #expect(purchases.isUnlocked)
        #expect(purchases.lastError == nil)
    }

    @Test func askToBuyDeclinedStaysLocked() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let (purchases, _) = freshInstall()
        purchases.start()
        await purchases.purchase()
        let pending = try #require(transactions(session).first { $0.pendingAskToBuyConfirmation })
        try session.declineAskToBuyTransaction(identifier: pending.identifier)
        try await Task.sleep(for: .seconds(2))
        await purchases.refreshEntitlements()
        #expect(!purchases.isUnlocked)
        #expect(!purchases.allows(albums: Purchases.freeAlbumLimit + 1))
    }

    @Test func failedPurchaseShowsAnErrorAndStaysLocked() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        session.failTransactionsEnabled = true
        let (purchases, _) = freshInstall()
        await purchases.purchase()
        print("STOREKIT_FAILED \(purchases.lastError ?? "-")")
        #expect(!purchases.isUnlocked)
        #expect(purchases.lastError != nil)
        #expect(!purchases.isPurchasing)
        // The next try works.
        session.failTransactionsEnabled = false
        await purchases.purchase()
        #expect(purchases.isUnlocked)
        #expect(purchases.lastError == nil)
    }

    /// No connection: the product cannot be loaded (the button shows no price) and buying
    /// says so; a network error during the purchase gets a plain message.
    @Test func offlineSaysSoAndNeverUnlocks() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let (unreachable, _) = freshInstall(productID: "app.albumist.ios.not-reachable")
        await unreachable.loadProduct()
        #expect(unreachable.product == nil)
        await unreachable.purchase()
        #expect(!unreachable.isUnlocked)
        #expect(!unreachable.isPurchasing)
        #expect(unreachable.lastError == String(localized: "Der Kauf ist gerade nicht verfügbar. Bitte versuche es später noch einmal."))

        let (purchases, _) = freshInstall()
        purchases.handle(StoreKitError.networkError(URLError(.notConnectedToInternet)))
        #expect(purchases.lastError == String(localized: "Keine Verbindung zum App Store. Bitte prüfe deine Internetverbindung und versuche es noch einmal."))
        purchases.handle(URLError(.timedOut))
        #expect(purchases.lastError == String(localized: "Keine Verbindung zum App Store. Bitte prüfe deine Internetverbindung und versuche es noch einmal."))
        #expect(!purchases.isUnlocked)
    }

    // MARK: Refund

    /// A refund arrives as an update of the transaction: Albumist locks again, the albums it
    /// already made stay (they belong to the user), the free count is unchanged.
    @Test func refundLocksAgain() async throws {
        let session = try session()
        defer { session.clearTransactions() }
        let (purchases, defaults) = freshInstall()
        purchases.start()
        purchases.recordUsage(plan: SortlyID("before"), albums: 4)
        await purchases.purchase()
        #expect(purchases.isUnlocked)
        purchases.recordUsage(plan: SortlyID("after"), albums: 20)
        let bought = try #require(transactions(session).first)
        try session.refundTransaction(identifier: bought.identifier)
        _ = await waitUntil("locked after refund") { !purchases.isUnlocked }
        #expect(!purchases.isUnlocked)
        #expect(purchases.albumsUsed == 24)
        #expect(purchases.remainingFreeAlbums == 0)
        #expect(!purchases.allows(albums: 1))
        let relaunched = Purchases(defaults: defaults)
        await relaunched.refreshEntitlements()
        #expect(!relaunched.isUnlocked)
    }

    // MARK: Free-album count in the app

    @Test func freeAlbumCountIsOneValueAndSurvivesARestart() throws {
        let (purchases, defaults) = freshInstall()
        #expect(Purchases.freeAlbumLimit == 10)
        #expect(purchases.remainingFreeAlbums == 10)
        #expect(purchases.allows(albums: 10))
        #expect(!purchases.allows(albums: 11))
        purchases.recordUsage(plan: SortlyID("p"), albums: 4)
        purchases.recordUsage(plan: SortlyID("p"), albums: 4) // finalized again after a crash
        #expect(purchases.albumsUsed == 4)
        #expect(defaults.data(forKey: "purchases.ledger") != nil)
        let relaunched = Purchases(defaults: defaults)
        #expect(relaunched.albumsUsed == 4)
        relaunched.returnUsage(plan: SortlyID("p"), albums: 4)
        relaunched.returnUsage(plan: SortlyID("p"), albums: 4)
        relaunched.settleUndone([SortlyID("p")])
        #expect(Purchases(defaults: defaults).albumsUsed == 0)
    }

    /// Installs that counted in three separate keys keep their count.
    @Test func olderCountIsCarriedOver() {
        let (_, defaults) = freshInstall()
        defaults.set(3, forKey: "purchases.albumsUsed")
        defaults.set(["a": 2], forKey: "purchases.albumsByPlan")
        defaults.set(["b"], forKey: "purchases.returnedPlans")
        let purchases = Purchases(defaults: defaults)
        #expect(purchases.albumsUsed == 5)
        purchases.recordUsage(plan: SortlyID("b"), albums: 1) // given back before: never again
        purchases.recordUsage(plan: SortlyID("c"), albums: 1)
        #expect(Purchases(defaults: defaults).albumsUsed == 6)
    }

    /// An interrupted plan holds its albums back until it is continued, kept or taken back.
    @Test func interruptedPlanHoldsItsAlbumsBack() {
        let (purchases, _) = freshInstall()
        let proposals = (0..<4).map { i in
            ConfirmedProposal(proposal: AlbumProposal(id: SortlyID("p\(i)"), kind: .trip, title: "Album \(i)", folderPath: [], assetIDs: [AssetID("a\(i)")]),
                              decision: .createNew(title: nil, folderPath: nil))
        }
        let interrupted = OrganizationPlanner().makePlan(from: proposals, inventory: CollectionInventory())
        purchases.reserve(for: interrupted)
        #expect(purchases.remainingFreeAlbums == 6)
        #expect(!purchases.allows(albums: 7))
        var undo = interrupted
        undo.reverts = SortlyID("other")
        purchases.reserve(for: undo)
        #expect(purchases.remainingFreeAlbums == 10)
        purchases.reserve(for: nil)
        #expect(purchases.remainingFreeAlbums == 10)
    }
}
