import Foundation
import StoreKit
import StoreKitTest
import Testing
import SortlyCore
@testable import Sortly

private final class BundleToken {}

/// The purchase against StoreKit itself: the app's product from the StoreKit configuration
/// file (App/StoreKit/Albumist.storekit) in a local test session, no App Store account
/// needed. Every case of the one-time unlock is set up here and its outcome checked.
/// Purchases are driven through the session (buy, Ask to Buy approve/decline, failure,
/// refund), as StoreKitTest documents for unit tests: Apple's purchase sheet never appears
/// in the test host. The app's own listener and entitlement logic must react to them. The
/// rules behind it (free-album count, which entitlements unlock) are tested on Linux in
/// Tests/SortlyCoreTests/PurchaseRulesTests.swift.
@Suite("Purchase with StoreKit", .serialized)
@MainActor
struct PurchaseStoreKitTests {
    nonisolated static func configurationURL() throws -> URL {
        if let url = Bundle(for: BundleToken.self).url(forResource: "Albumist", withExtension: "storekit") { return url }
        // The file in the repository (the simulator reads the Mac's files) if the bundle lacks it.
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StoreKit/Albumist.storekit")
        guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileNoSuchFile) }
        return file
    }

    /// A fresh session without transactions or dialogs, German storefront. `price`: the same
    /// product with another price, as App Store Connect sets it for the launch week.
    ///
    /// Every test starts the same way, whatever ran before it: the StoreKit test environment
    /// is ready (brought up once per run, see `StoreKitEnvironment`), no StoreKit step of an
    /// earlier test is still running (one its test gave up on would otherwise act on this
    /// test's session, CI run 43949938467), and the new session holds nothing and StoreKit
    /// lists no unlock. That read of the list stays although it comes before the test's
    /// purchase: a purchase of an earlier test still in the list would let the checks after a
    /// restart, on a second device or after a restore pass without this test's purchase. A read
    /// before a purchase is what exposes StoreKit's late update for the first purchase after
    /// it (see `StoreKitEnvironment`); the bring-up makes that purchase before any test does.
    func session(price: String? = nil) async throws -> PurchaseTestStore {
        try await StoreKitEnvironment.ready()
        try await StoreKitSteps.shared.waitUntilIdle(seconds: 60)
        var url = try Self.configurationURL()
        if let price {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains(#""displayPrice" : "4.99""#))
            url = FileManager.default.temporaryDirectory.appendingPathComponent("Albumist-\(UUID().uuidString).storekit")
            try text.replacingOccurrences(of: #""displayPrice" : "4.99""#, with: #""displayPrice" : "\#(price)""#)
                .write(to: url, atomically: true, encoding: .utf8)
        }
        let file = url
        let store = try await onSessionQueue("set up the test session") {
            let session = try SKTestSession(contentsOf: file)
            StoreKitEnvironment.configure(session)
            return PurchaseTestStore(session)
        }
        let held = try await onSessionQueue("read the new session's transactions") {
            store.session.allTransactions().map { "\($0.productIdentifier) #\($0.identifier)" }
        }
        try #require(held.isEmpty, "the new session already holds \(held)")
        let unlock = Purchases.unlockProductID
        let gone = try await within("StoreKit lists no unlock") { await StoreKitEnvironment.waitUntil(listed: false, unlock, seconds: 15) }
        try #require(gone, "StoreKit still lists the unlock 15 s after the session was cleared")
        return store
    }

    /// Leaves no transaction behind for the next test. Runs on the session queue after
    /// everything this test asked of the session; the next `session()` waits for it.
    func clearAfterwards(_ store: PurchaseTestStore) {
        startOnSessionQueue("clear the session after the test") { store.session.clearTransactions() }
    }

    /// A Purchases object as on a fresh install: its own empty defaults.
    func freshInstall(_ name: String = UUID().uuidString, productID: String = Purchases.unlockProductID) -> (Purchases, UserDefaults) {
        let suite = "albumist.tests.purchases.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (Purchases(defaults: defaults, productID: productID), defaults)
    }

    /// Like `waitUntil`, without an issue when the time is up.
    func waitQuietly(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// A second listener on `Transaction.updates`, independent of the app's code: it shows
    /// whether StoreKit delivered an update at all, so a missing unlock is put down to the
    /// app's listener only when StoreKit did deliver.
    @MainActor final class UpdateObserver {
        var heard: [String] = []
        var sawUnlock = false
        private var task: Task<Void, Never>?

        static func start() -> UpdateObserver {
            let observer = UpdateObserver()
            observer.task = Task { @MainActor [weak observer] in
                for await result in Transaction.updates {
                    guard let observer else { return }
                    let update = result.unsafePayloadValue
                    observer.heard.append("#\(update.id) \(update.productID) revoked \(update.revocationDate != nil)")
                    if update.productID == Purchases.unlockProductID && update.revocationDate == nil { observer.sawUnlock = true }
                }
            }
            return observer
        }

        func stop() { task?.cancel() }
    }

    func waitUntil(_ what: @autoclosure () -> String, timeout: TimeInterval = 20, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out: \(what())")
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    @MainActor final class Flag { var done = false }

    /// "Kauf wiederherstellen" without blocking the test on `AppStore.sync()`: the test waits
    /// for the flag with a time limit instead.
    /// Counted as a running StoreKit step until it ends, also when its test stopped waiting.
    func restoreInBackground(_ purchases: Purchases) -> Flag {
        let flag = Flag()
        let token = StoreKitSteps.shared.begin("restore")
        Task { @MainActor in
            await purchases.restore()
            StoreKitSteps.shared.end(token)
            flag.done = true
        }
        return flag
    }

    func normalized(_ price: String) -> String {
        price.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// What the test session holds for the unlock (copied, so it can leave the session's thread).
    struct SessionTransaction: Sendable {
        let identifier: UInt
        let pendingAskToBuyConfirmation: Bool
    }

    func transactions(_ store: PurchaseTestStore) async throws -> [SessionTransaction] {
        let unlock = Purchases.unlockProductID // read here: Purchases belongs to the main actor
        return try await onSessionQueue("read the session's transactions") {
            store.session.allTransactions().filter { $0.productIdentifier == unlock }
                .map { SessionTransaction(identifier: $0.identifier, pendingAskToBuyConfirmation: $0.pendingAskToBuyConfirmation) }
        }
    }

    /// StoreKit answers from the configuration file only when it knows the test host (by its
    /// code signing identifier, see the post-build script of SortlyTests in project.yml);
    /// otherwise it asks the real App Store and every case below fails for that one reason.
    /// Checked once per test, with the reason in the message.
    func requireTestEnvironment() async throws {
        let started = Date()
        let unlock = Purchases.unlockProductID
        let result: Result<Int, any Error> = try await within("load the product") {
            do { return .success(try await Product.products(for: [unlock]).count) } catch { return .failure(error) }
        }
        let found = (try? result.get()) ?? 0
        var failure = "none"
        if case .failure(let error) = result { failure = String(describing: error) }
        try #require(found > 0, "StoreKit test environment not reached: no product after \(Int(Date().timeIntervalSince(started) * 1000)) ms, error \(failure), host \(Bundle.main.bundleIdentifier ?? "-")")
    }

    /// The test session's view of the transactions, for failure messages.
    func describe(_ store: PurchaseTestStore) async -> String {
        let all = (try? await onSessionQueue("describe the session") {
            store.session.allTransactions().map { "\($0.productIdentifier) #\($0.identifier) askToBuy \($0.pendingAskToBuyConfirmation)" }
        }) ?? ["(session did not answer)"]
        return all.joined(separator: "; ")
    }

    /// What the purchase call handed to the sheet, and the sheet's answer in a test without a session purchase.
    @MainActor final class Seen {
        var products: [String] = []
        var whilePurchasing: [Bool] = []
        var answer: () throws -> Product.PurchaseResult = { .userCancelled }
        /// Set when the session made the purchase but StoreKit never listed it: the test
        /// environment did not deliver it, the app's code had no part in that.
        var environment: String?
    }

    /// Buys the way StoreKitTest documents it for unit tests: through the test session, in
    /// place of Apple's purchase sheet (`Purchases.confirmPurchase`), which never appears in
    /// the test host. What the app gets back is StoreKit's own answer: the verified
    /// transaction, `.pending` while an Ask to Buy request waits, or the error the session
    /// throws. Everything around it (product loading, the answer's handling) is the app's code.
    func buyThroughSession(_ purchases: Purchases, _ store: PurchaseTestStore) -> Seen {
        let seen = Seen()
        purchases.confirmPurchase = { product in
            seen.products.append(product.id)
            seen.whilePurchasing.append(purchases.isPurchasing)
            let id = product.id
            storeKitTrace("session buy \(id): start")
            let heardBefore = StoreKitRunListener.shared.count
            let boughtAt: Date
            do {
                boughtAt = try await onSessionQueue("buy in the test session", seconds: 20) { () throws -> Date in
                    try store.session.buyProduct(productIdentifier: id)
                    return Date()
                }
            } catch {
                storeKitTrace("session buy \(id): threw \(error)")
                throw error
            }
            let held = try await onSessionQueue("read the session's transactions") {
                store.session.allTransactions().map { "#\($0.identifier) \($0.productIdentifier) askToBuy \($0.pendingAskToBuyConfirmation)" }
            }
            storeKitTrace("session buy \(id): done, session holds \(held)")
            // StoreKit answers with the purchase as the app's own entitlement (a verified
            // transaction), the same value `Product.purchase()` hands back.
            let listing = await Self.entitlement(for: id)
            guard let result = listing.entry else {
                let heard = StoreKitRunListener.shared.heard(since: heardBefore, afterBuyAt: boughtAt)
                seen.environment = "StoreKit did not list the session's purchase within \(listing.milliseconds) ms (test environment, not app code; ready after \(StoreKitEnvironment.roundTrips) round trips); the session holds \(held), the run listener heard \(heard)"
                storeKitTrace("session buy \(id): not in StoreKit's list, \(listing); run listener heard \(heard)")
                throw StoreKitError.unknown
            }
            storeKitTrace("session buy \(id): entitlement found \(listing), verified \(Self.isVerified(result))")
            return .success(result)
        }
        return seen
    }

    /// Right after a session purchase StoreKit may not list it yet (CI run 43772050228: missing
    /// once, present once), so the list is read again for up to 10 s (50 reads, 200 ms apart).
    /// Timed here, where the reads run (off the main actor).
    nonisolated static func entitlement(for id: String) async -> ListWait {
        let start = Date()
        for read in 1...50 {
            if let entry = await StoreKitEnvironment.entry(for: id) {
                return ListWait(reached: true, entry: entry, reads: read, seconds: Date().timeIntervalSince(start))
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return ListWait(reached: false, entry: nil, reads: 50, seconds: Date().timeIntervalSince(start))
    }

    nonisolated static func isVerified(_ result: VerificationResult<Transaction>) -> Bool {
        if case .verified = result { return true }
        return false
    }

    /// A start reads StoreKit's list of entitlements. Right after a purchase or refund made in
    /// the session the list may still show the state before (CI run 43772050228), so it is read
    /// again for up to 10 s until it shows `until`; the expectation after it decides.
    func readEntitlements(_ purchases: Purchases, until unlocked: Bool, _ step: String) async throws {
        for attempt in 1...20 {
            try await within(step) { await purchases.refreshEntitlements() }
            if purchases.isUnlocked == unlocked {
                if attempt > 1 { storeKitTrace("\(step): as expected after \(attempt) reads") }
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        storeKitTrace("\(step): still unlocked \(purchases.isUnlocked) after 20 reads")
    }

    /// The app's purchase call as one step with a time limit; what it ended with goes to the
    /// log either way (the CI log shows only the first line of a failed expectation).
    func purchaseStep(_ purchases: Purchases, _ step: String) async throws {
        do {
            try await within(step) { await purchases.purchase() }
        } catch {
            storeKitTrace("\(step): \(error); unlocked \(purchases.isUnlocked), purchasing \(purchases.isPurchasing), message \(purchases.lastError ?? "none")")
            throw error
        }
        storeKitTrace("\(step): unlocked \(purchases.isUnlocked), message \(purchases.lastError ?? "none")")
    }

    /// `purchaseStep` with the purchase made in the test session (`buyThroughSession`), for the
    /// two tests that expect the purchase call itself to unlock (buyingUnlocks…, failedPurchase…).
    /// When StoreKit never listed the session's purchase, the test's first issue names that
    /// cause, at the test's own line (CI run 44130064334 reported only "purchases.isUnlocked").
    /// The app's code has no part in that wait, so this only names the cause: every expectation
    /// after it still runs, and the app's error message fails `lastError == nil` in these tests
    /// either way. refundLocksAgain buys through the session without it: the app's listener runs
    /// there and may unlock all the same, and that test checks the unlock only.
    func purchaseInSession(_ purchases: Purchases, _ store: PurchaseTestStore, _ step: String,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws -> Seen {
        let seen = buyThroughSession(purchases, store)
        try await purchaseStep(purchases, step)
        if let failure = seen.environment {
            Issue.record(StoreKitEnvironmentFailure(description: failure), sourceLocation: sourceLocation)
        }
        return seen
    }

    // MARK: Product and price

    @Test func productAndPriceComeFromStoreKit() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, _) = freshInstall()
        try await within("load the product into Purchases") { await purchases.loadProduct() }
        let product = try #require(purchases.product)
        print("STOREKIT_PRICE regular \(product.displayPrice)")
        #expect(product.id == "app.albumist.ios.unlock")
        #expect(product.type == .nonConsumable)
        #expect(product.price == Decimal(string: "4.99"))
        #expect(normalized(product.displayPrice).contains("4,99") || product.displayPrice.contains("4.99"), "shown: \(product.displayPrice)")
        #expect(product.displayPrice.contains("€"), "shown: \(product.displayPrice)")
    }

    /// Launch week: App Store Connect sets 2,99 €, and that is what the app shows. Nothing in
    /// the app holds a price (checked on Linux, `noPriceIsWrittenIntoTheApp`).
    @Test func launchWeekPriceIsWhatStoreKitSays() async throws {
        let store = try await session(price: "2.99")
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, _) = freshInstall()
        try await within("load the product into Purchases") { await purchases.loadProduct() }
        let product = try #require(purchases.product)
        print("STOREKIT_PRICE launch week \(product.displayPrice)")
        #expect(product.price == Decimal(string: "2.99"))
        #expect(normalized(product.displayPrice).contains("2,99") || product.displayPrice.contains("2.99"), "shown: \(product.displayPrice)")
        #expect(!product.displayPrice.contains("4"), "shown: \(product.displayPrice)")
    }

    // MARK: Buying

    @Test func buyingUnlocksAndStaysUnlockedAfterARestart() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, defaults) = freshInstall()
        #expect(!purchases.isUnlocked)
        #expect(!purchases.allows(albums: Purchases.freeAlbumLimit + 1))
        // The product was never loaded (a start without network): buying loads it first.
        #expect(purchases.product == nil)
        let seen = try await purchaseInSession(purchases, store, "purchase")
        #expect(seen.products == [Purchases.unlockProductID])
        #expect(seen.whilePurchasing == [true])
        let afterPurchase = await describe(store)
        #expect(purchases.isUnlocked, "message: \(purchases.lastError ?? "none"), transactions: \(afterPurchase)")
        #expect(purchases.lastError == nil)
        #expect(!purchases.isPurchasing)
        #expect(purchases.allows(albums: 500))
        let bought = try await transactions(store)
        #expect(bought.count == 1)

        // Next launch: StoreKit still knows the purchase.
        let relaunched = Purchases(defaults: defaults)
        #expect(!relaunched.isUnlocked)
        try await within("read the entitlements after a restart") { await relaunched.refreshEntitlements() }
        #expect(relaunched.isUnlocked)
    }

    /// Bought on another device (or before the app was deleted): a new install unlocks at its
    /// start without any tap, and "Kauf wiederherstellen" finds it too.
    @Test func purchaseFromAnotherDeviceOrBeforeReinstallIsRestored() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        // The app is running while the purchase is made elsewhere: its listener unlocks.
        let (running, _) = freshInstall()
        running.start()
        defer { running.stop() }
        let observer = UpdateObserver.start()
        defer { observer.stop() }
        try await within("read the entitlements at the start") { await running.refreshEntitlements() }
        #expect(!running.isUnlocked)
        // A running app has listened since its launch. A purchase made right after `start()`
        // never reached the listener (CI run 43773400300), while updates a moment later did
        // (Ask to Buy approval, refund), so the app runs for a few seconds first. StoreKit
        // gives no signal for "now listening": `Transaction.updates` is an async sequence that
        // registers with StoreKit on its own schedule, so there is nothing to wait for instead.
        try await Task.sleep(for: .seconds(5))
        let unlock = Purchases.unlockProductID
        try await onSessionQueue("buy in the session (another device)") { try store.session.buyProduct(productIdentifier: unlock) }
        let bought = try await transactions(store)
        #expect(bought.count == 1)
        let heard = await waitQuietly(timeout: 20) { running.isUnlocked }
        storeKitTrace("purchase on another device: app unlocked \(heard); app's listener heard \(running.heardUpdates); independent listener heard \(observer.heard)")
        // The app's listener acts on every update StoreKit delivers ...
        #expect(heard || !observer.sawUnlock, "StoreKit delivered the purchase, the app's listener did not unlock")
        // ... and when StoreKit delivers none, the app shows the purchase when it is back on
        // screen (a re-read of StoreKit's list), without a restart.
        if !heard {
            for _ in 0..<20 where !running.isUnlocked {
                try await within("back on screen") { await running.becameActive() }
                if !running.isUnlocked { try await Task.sleep(for: .milliseconds(500)) }
            }
        }
        #expect(running.isUnlocked)

        let (secondDevice, _) = freshInstall()
        #expect(!secondDevice.isUnlocked)
        try await readEntitlements(secondDevice, until: true, "read the entitlements on the second device")
        #expect(secondDevice.isUnlocked)

        let (reinstalled, _) = freshInstall()
        reinstalled.lastError = "an earlier message"
        let restored = restoreInBackground(reinstalled)
        _ = await waitUntil("restore finished") { restored.done }
        #expect(reinstalled.isUnlocked)
        #expect(reinstalled.lastError == nil, "message: \(reinstalled.lastError ?? "none")")
        #expect(!reinstalled.isPurchasing)
    }

    @Test func restoreWithoutPurchaseSaysSo() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, _) = freshInstall()
        let restored = restoreInBackground(purchases)
        _ = await waitUntil("restore finished") { restored.done }
        #expect(!purchases.isUnlocked)
        #expect(purchases.lastError == String(localized: "Kein Kauf gefunden. Wenn du Albumist mit einem anderen Apple Account gekauft hast, melde dich damit im App Store an."),
                "message: \(purchases.lastError ?? "none")")
    }

    // MARK: Cancelled, pending, failed, offline

    @Test func cancelledPurchaseChangesNothing() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
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
        let recorded = try await transactions(store)
        #expect(recorded.isEmpty)
    }

    /// The app's purchase call around the sheet: it loads the product from StoreKit when
    /// needed, is marked as running while the sheet would be up, and turns every answer of the
    /// sheet into the right state and message (cancelled, cancelled as an error, waiting, no
    /// connection). The sheet itself is Apple's and cannot appear in the test host.
    @Test func purchaseCallTurnsEveryAnswerIntoTheRightState() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, _) = freshInstall()
        defer { purchases.stop() }
        #expect(purchases.product == nil)
        let seen = Seen()
        purchases.confirmPurchase = { product in
            seen.products.append(product.id)
            seen.whilePurchasing.append(purchases.isPurchasing)
            return try seen.answer()
        }

        purchases.lastError = "an earlier message"
        try await purchaseStep(purchases, "purchase, cancelled")
        #expect(seen.products == [Purchases.unlockProductID], "the product came from StoreKit")
        #expect(seen.whilePurchasing == [true])
        #expect(purchases.lastError == nil)
        #expect(!purchases.isPurchasing)

        seen.answer = { throw StoreKitError.userCancelled }
        purchases.lastError = "an earlier message"
        try await purchaseStep(purchases, "purchase, cancelled as an error")
        #expect(purchases.lastError == nil)

        seen.answer = { .pending }
        try await purchaseStep(purchases, "purchase, waiting")
        #expect(purchases.lastError == String(localized: "Der Kauf wartet noch auf eine Bestätigung, zum Beispiel durch die Familienfreigabe. Albumist schaltet sich danach von selbst frei."))

        seen.answer = { throw StoreKitError.networkError(URLError(.notConnectedToInternet)) }
        try await purchaseStep(purchases, "purchase, offline")
        #expect(purchases.lastError == String(localized: "Keine Verbindung zum App Store. Bitte prüfe deine Internetverbindung und versuche es noch einmal."))

        #expect(seen.products.count == 4)
        #expect(!purchases.isUnlocked)
        #expect(!purchases.isPurchasing)
        let recorded = try await transactions(store)
        #expect(recorded.isEmpty)
    }

    /// A purchase whose sheet never answers does not keep Buy and Restore disabled: after the
    /// time limit both work again, and the late end of the old attempt changes nothing.
    @Test func hungPurchaseFreesTheButtonsAfterItsTimeLimit() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, _) = freshInstall()
        purchases.purchaseTimeLimit = .seconds(1)
        purchases.confirmPurchase = { _ in
            try await Task.sleep(for: .seconds(600))
            return .userCancelled
        }
        let hung = Task { await purchases.purchase() }
        _ = await waitUntil("purchase running") { purchases.isPurchasing }
        let freed = await waitUntil("buttons free after the time limit", timeout: 10) { !purchases.isPurchasing }
        #expect(freed)
        // Restore is not refused as "already running".
        let restored = restoreInBackground(purchases)
        _ = await waitUntil("restore finished") { restored.done }
        #expect(purchases.lastError == String(localized: "Kein Kauf gefunden. Wenn du Albumist mit einem anderen Apple Account gekauft hast, melde dich damit im App Store an."),
                "message: \(purchases.lastError ?? "none")")
        // The hung sheet ends at last: nothing stays disabled.
        hung.cancel()
        await hung.value
        #expect(!purchases.isPurchasing)
        #expect(!purchases.isUnlocked)
    }

    /// StoreKit's answers for the re-read tests below, set by the test.
    @MainActor final class ListAnswers {
        var list: [PurchaseRules.Entitlement] = []
        var latest: PurchaseRules.Entitlement?
    }

    /// The re-read back on screen may only unlock: one empty or lagging list never locks a
    /// paying user. A refund the listener missed still locks: StoreKit's latest transaction
    /// carries it, also while the list still shows the purchase.
    @Test func reReadOnScreenNeverLocksButARefundStillDoes() async {
        typealias E = PurchaseRules.Entitlement
        let unlock = Purchases.unlockProductID
        let (purchases, _) = freshInstall()
        let answers = ListAnswers()
        purchases.entitlementsReader = { answers.list }
        purchases.latestReader = { answers.latest }
        answers.list = [E(productID: unlock, transactionID: 5)]
        await purchases.refreshEntitlements()
        #expect(purchases.isUnlocked, "the launch read finds the purchase")

        answers.list = []
        await purchases.becameActive()
        #expect(purchases.isUnlocked, "an empty list back on screen locked a paying user")
        await purchases.refreshEntitlements(mayLock: false)
        #expect(purchases.isUnlocked, "a read after a redeemed code locked a paying user")

        answers.list = [E(productID: unlock, transactionID: 5)]
        answers.latest = E(productID: unlock, isRevoked: true, transactionID: 5)
        await purchases.becameActive()
        #expect(!purchases.isUnlocked, "the refund in StoreKit's latest transaction did not lock")
        answers.latest = nil
        await purchases.becameActive()
        #expect(!purchases.isUnlocked, "a later read brought the refunded purchase back")

        answers.list = [E(productID: unlock, transactionID: 5), E(productID: unlock, transactionID: 9)]
        await purchases.becameActive()
        #expect(purchases.isUnlocked, "bought again after the refund")
    }

    /// The re-reads while a purchase is pending: they find the approval and stop then, they
    /// stop with `stop()`, and they stop after their number of passes.
    @Test func pendingReReadsUnlockAndStopInTime() async throws {
        typealias E = PurchaseRules.Entitlement
        let (purchases, _) = freshInstall()
        defer { purchases.stop() }
        let answers = ListAnswers()
        purchases.entitlementsReader = { answers.list }
        purchases.pendingCheckInterval = .milliseconds(100)
        await purchases.handle(.pending)
        _ = await waitUntil("re-read twice while pending") { purchases.entitlementReads >= 2 }
        #expect(!purchases.isUnlocked)
        answers.list = [E(productID: Purchases.unlockProductID, transactionID: 3)]
        _ = await waitUntil("approval found by a re-read") { purchases.isUnlocked }
        #expect(purchases.lastError == nil)
        let afterUnlock = purchases.entitlementReads
        try await Task.sleep(for: .milliseconds(800))
        #expect(purchases.entitlementReads == afterUnlock, "re-reads went on after the unlock")

        let (stopped, _) = freshInstall()
        stopped.entitlementsReader = { [] }
        stopped.pendingCheckInterval = .milliseconds(100)
        await stopped.handle(.pending)
        _ = await waitUntil("re-read while pending") { stopped.entitlementReads >= 1 }
        stopped.stop()
        let afterStop = stopped.entitlementReads
        try await Task.sleep(for: .milliseconds(800))
        #expect(stopped.entitlementReads == afterStop, "re-reads went on after stop()")

        let (limited, _) = freshInstall()
        defer { limited.stop() }
        limited.entitlementsReader = { [] }
        limited.pendingCheckInterval = .milliseconds(50)
        limited.pendingCheckCount = 3
        await limited.handle(.pending)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(limited.entitlementReads == 3, "reads: \(limited.entitlementReads)")
        #expect(!limited.isUnlocked)
    }

    /// Ask to Buy: StoreKit answers the purchase with `.pending` while the parent decides; the
    /// app says so. An approval arrives as the completed purchase: the app's own transaction
    /// listener unlocks, also after a restart. (The session's `buyProduct` ignores
    /// `askToBuyEnabled`, no request was pending in CI run 43770704675, and Apple's sheet cannot
    /// run in the test host. So the pending answer comes through `confirmPurchase`, and the
    /// approval is the session's purchase of the same product.)
    @Test func askToBuyWaitsAndUnlocksWhenApproved() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, defaults) = freshInstall()
        // The re-reads while pending are tested on their own (pendingReReadsUnlockAndStopInTime);
        // here only the listener, or the re-read back on screen, may unlock.
        purchases.pendingCheckInterval = .seconds(3600)
        purchases.start()
        defer { purchases.stop() }
        let seen = Seen()
        seen.answer = { .pending }
        purchases.confirmPurchase = { product in
            seen.products.append(product.id)
            return try seen.answer()
        }
        let observer = UpdateObserver.start()
        defer { observer.stop() }
        try await purchaseStep(purchases, "purchase with Ask to Buy")
        #expect(seen.products == [Purchases.unlockProductID])
        #expect(!purchases.isUnlocked)
        #expect(purchases.lastError == String(localized: "Der Kauf wartet noch auf eine Bestätigung, zum Beispiel durch die Familienfreigabe. Albumist schaltet sich danach von selbst frei."))

        let unlock = Purchases.unlockProductID
        try await onSessionQueue("approval: the purchase completes in the session") { try store.session.buyProduct(productIdentifier: unlock) }
        let heard = await waitQuietly(timeout: 20) { purchases.isUnlocked }
        storeKitTrace("Ask to Buy approved: app unlocked \(heard); app's listener heard \(purchases.heardUpdates); independent listener heard \(observer.heard)")
        // The app's listener acts on every approval StoreKit delivers ...
        #expect(heard || !observer.sawUnlock, "StoreKit delivered the approval, the app's listener did not unlock")
        // ... and when StoreKit delivers none, the app shows it when it is back on screen.
        if !heard {
            for _ in 0..<20 where !purchases.isUnlocked {
                try await within("back on screen") { await purchases.becameActive() }
                if !purchases.isUnlocked { try await Task.sleep(for: .milliseconds(500)) }
            }
        }
        #expect(purchases.isUnlocked)
        #expect(purchases.lastError == nil)
        // A read of StoreKit's list right after the approval (launch, restore, offer code)
        // never locks again, even if the list does not show the purchase yet.
        try await within("read the entitlements right after the approval") { await purchases.refreshEntitlements() }
        #expect(purchases.isUnlocked)

        let relaunched = Purchases(defaults: defaults)
        try await readEntitlements(relaunched, until: true, "read the entitlements after a restart")
        #expect(relaunched.isUnlocked)
    }

    /// Declined: no purchase ever arrives; the app stays locked, also after a restart.
    @Test func askToBuyDeclinedStaysLocked() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, defaults) = freshInstall()
        purchases.start()
        defer { purchases.stop() }
        purchases.confirmPurchase = { _ in .pending }
        try await purchaseStep(purchases, "purchase with Ask to Buy")
        #expect(!purchases.isUnlocked)
        try await Task.sleep(for: .seconds(2))
        try await within("read the entitlements after the decline") { await purchases.refreshEntitlements() }
        #expect(!purchases.isUnlocked)
        #expect(!purchases.allows(albums: Purchases.freeAlbumLimit + 1))
        let recorded = try await transactions(store)
        #expect(recorded.isEmpty)

        let relaunched = Purchases(defaults: defaults)
        try await within("read the entitlements after a restart") { await relaunched.refreshEntitlements() }
        #expect(!relaunched.isUnlocked)
    }

    /// A purchase that fails: StoreKit throws, the app shows the error and stays locked, and
    /// the next try (a real session purchase) works. The failure is StoreKit's error thrown
    /// through `confirmPurchase`: the session's `buyProduct` does not apply
    /// `failTransactionsEnabled` and `failureError`; it completed the purchase with both set
    /// (CI run 43772050228), and Apple's sheet, where they apply, cannot run in the test host.
    @Test func failedPurchaseShowsAnErrorAndStaysLocked() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, _) = freshInstall()
        let seen = Seen()
        seen.answer = { throw Product.PurchaseError.purchaseNotAllowed }
        purchases.confirmPurchase = { product in
            seen.products.append(product.id)
            return try seen.answer()
        }
        try await purchaseStep(purchases, "failing purchase")
        #expect(seen.products == [Purchases.unlockProductID])
        #expect(!purchases.isUnlocked)
        #expect(purchases.lastError == Product.PurchaseError.purchaseNotAllowed.localizedDescription, "message: \(purchases.lastError ?? "none")")
        #expect(!purchases.isPurchasing)
        try await within("read the entitlements after the failure") { await purchases.refreshEntitlements() }
        #expect(!purchases.isUnlocked)
        let recorded = try await transactions(store)
        #expect(recorded.isEmpty)
        // The next try works.
        _ = try await purchaseInSession(purchases, store, "purchase after the failure")
        #expect(purchases.isUnlocked, "message: \(purchases.lastError ?? "none")")
        #expect(purchases.lastError == nil)
    }

    /// No connection: the product cannot be loaded (the button shows no price) and buying
    /// says so; a network error during the purchase gets a plain message.
    @Test func offlineSaysSoAndNeverUnlocks() async throws {
        let store = try await session()
        defer { clearAfterwards(store) }
        let (unreachable, _) = freshInstall(productID: "app.albumist.ios.not-reachable")
        try await within("load a product StoreKit does not have") { await unreachable.loadProduct() }
        #expect(unreachable.product == nil)
        try await within("purchase without a product") { await unreachable.purchase() }
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
        let store = try await session()
        defer { clearAfterwards(store) }
        try await requireTestEnvironment()
        let (purchases, defaults) = freshInstall()
        purchases.start()
        defer { purchases.stop() }
        purchases.recordUsage(plan: SortlyID("before"), albums: 4)
        _ = buyThroughSession(purchases, store)
        try await purchaseStep(purchases, "purchase")
        #expect(purchases.isUnlocked, "message: \(purchases.lastError ?? "none")")
        purchases.recordUsage(plan: SortlyID("after"), albums: 20)
        let first = try await transactions(store).first
        let bought = try #require(first)
        let id = bought.identifier
        try await onSessionQueue("refund in the session") { try store.session.refundTransaction(identifier: id) }
        _ = await waitUntil("locked by the transaction listener after the refund") { !purchases.isUnlocked }
        // A read right after the refund never unlocks again, even if the list still shows it.
        try await within("read the entitlements right after the refund") { await purchases.refreshEntitlements() }
        let afterward = await describe(store)
        #expect(!purchases.isUnlocked, "transactions: \(afterward)")
        #expect(purchases.albumsUsed == 24)
        #expect(purchases.remainingFreeAlbums == 0)
        #expect(!purchases.allows(albums: 1))
        let relaunched = Purchases(defaults: defaults)
        try await readEntitlements(relaunched, until: false, "read the entitlements after a restart")
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

/// The StoreKit test session, handed to `onSessionQueue` so its blocking calls run on a thread
/// of their own: on the main actor, a session call that waits for the app's own StoreKit
/// client (which delivers on the main actor) would wait for the very thread it blocks.
final class PurchaseTestStore: @unchecked Sendable {
    let session: SKTestSession
    init(_ session: SKTestSession) { self.session = session }
}

struct StoreKitStepTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// The StoreKit test environment, brought up once per test run before the first test uses it,
/// and handed to the tests only once it answers the way they need it.
///
/// As the CI logs show it, StoreKit's list of entitlements follows state on the test
/// process's side, which catches up with a purchase made in the session only when StoreKit's
/// update notification for it arrives. For the first purchase after a read of the list that
/// notification can come 10 to 15 s late, after cold and after fast starts. CI run
/// 44157630387: the first round trip's purchase showed in the list after 15,316 ms, exactly
/// when the run's listener heard its update (listening for 20.7 s by then), the next two
/// within 10 ms. Before 9536ba7 the first read of the list came after the first purchase,
/// and that purchase was listed at once in 22 of 22 runs; since `session()` reads the list
/// before every test, the first purchase after that read was missing in 3 of 6 runs. So the
/// round trips below make that first purchase, before any test does.
///
/// First a listener on StoreKit's updates starts for the whole run (`StoreKitRunListener`, a
/// diagnostic). Then the test session is set up and the product loaded (on a just-booted
/// simulator the first set-up once did not answer within 30 s, CI run 43949938467). Then the
/// round trip of a purchase test is made until `promptInARow` in a row are prompt: a new
/// session that holds nothing, StoreKit's list read until it shows no unlock (as `session()`
/// does before every test), a purchase in the session, the list shows it, the transaction
/// finished the way the app finishes a purchase (on its own, not awaited), the session
/// cleared, the list no longer shows it. Prompt: every step within a fifth of what a test
/// allows for it (`RoundTrip`). A wait for the list stops after `waitCap`; that round trip is
/// not prompt, and the next one starts with a new session. Each round trip is printed with its
/// times and what the run's listener heard. The bring-up ends unready only when `budget` runs
/// out, a step does not answer, or a session holds transactions where it must be empty (new,
/// or just cleared); then every test that needs StoreKit fails with
/// `StoreKitEnvironmentFailure`, never passes.
///
/// The round trips involve StoreKit and the test session only, never the app's purchase code,
/// and every test still starts with an empty session and no unlock in StoreKit's list
/// (`session()`), so they cannot make an app failure pass.
@MainActor
enum StoreKitEnvironment {
    /// For the whole bring-up, a just-booted simulator included.
    nonisolated static let budget: Double = 300
    /// The longest a round trip waits for StoreKit's list to show a state (each time).
    nonisolated static let waitCap: Double = 30
    /// Prompt round trips in a row before the tests start.
    nonisolated static let promptInARow = 3
    /// From the start of the run's listener to the first round trip, so that it hears that
    /// purchase: a listener registers with StoreKit on its own schedule and gives no signal when
    /// it listens (one started right before a purchase missed it, CI run 43773400300).
    nonisolated static let listenerLead: Double = 5
    private static var bringingUp: Task<BringUp, Never>?
    /// The round trips the bring-up made until the environment was ready (for messages).
    private(set) static var roundTrips = 0

    /// Throws, for every test, why the environment is not ready (the first failure, once).
    static func ready() async throws {
        let task: Task<BringUp, Never>
        if let running = bringingUp {
            task = running
        } else {
            let unlock = Purchases.unlockProductID
            task = Task.detached { await StoreKitEnvironment.bringUp(unlock) }
            bringingUp = task
        }
        let result = await task.value
        roundTrips = result.trips
        if let failure = result.failure { throw StoreKitEnvironmentFailure(description: failure) }
    }

    /// No transactions, no dialogs, German storefront.
    nonisolated static func configure(_ session: SKTestSession) {
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.storefront = "DEU"
        session.locale = Locale(identifier: "de_DE")
        session.clearTransactions()
    }

    /// The product's entry in StoreKit's list of entitlements, nil if it has none (one read).
    nonisolated static func entry(for id: String) async -> VerificationResult<Transaction>? {
        for await result in Transaction.currentEntitlements where result.unsafePayloadValue.productID == id {
            return result
        }
        return nil
    }

    /// Reads StoreKit's list until it does (or does not) list the product; false if it still
    /// shows the other state after `seconds`.
    nonisolated static func waitUntil(listed: Bool, _ id: String, seconds: Double) async -> Bool {
        await StoreKitEnvironment.readUntil(listed: listed, id, seconds: seconds).reached
    }

    /// Like `waitUntil`, with the entry, the reads and the time, measured here where the reads
    /// run (off the main actor).
    nonisolated static func readUntil(listed: Bool, _ id: String, seconds: Double) async -> ListWait {
        let start = Date()
        var reads = 0
        while true {
            reads += 1
            let entry = await StoreKitEnvironment.entry(for: id)
            let waited = Date().timeIntervalSince(start)
            if (entry != nil) == listed { return ListWait(reached: true, entry: entry, reads: reads, seconds: waited) }
            if waited > seconds { return ListWait(reached: false, entry: nil, reads: reads, seconds: waited) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The bring-up (see above). Off the main actor: other suites keep it busy meanwhile.
    nonisolated private static func bringUp(_ unlock: String) async -> BringUp {
        let started = Date()
        let deadline = started.addingTimeInterval(budget)
        var done: [String] = []
        var trips = 0
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        func left() -> Double { max(1, deadline.timeIntervalSinceNow) }
        let listening = StoreKitRunListener.shared.start()
        done.append("run listener \(elapsed()) ms")
        do {
            let url = try PurchaseStoreKitTests.configurationURL()
            _ = try await onSessionQueue("bring up the test session", seconds: left()) {
                let session = try SKTestSession(contentsOf: url)
                StoreKitEnvironment.configure(session)
                return PurchaseTestStore(session)
            }
            done.append("session \(elapsed()) ms")
            // StoreKit answers from the configuration file only when it knows the test host (see
            // `requireTestEnvironment`); until the environment is up the list may come back empty.
            // StoreKit's own error is kept, so a signing or bundle-id problem says what it is
            // instead of only "no product" after the whole budget (second review 16.11.).
            var lastError = "none"
            while true {
                let load = try await within("load the product", seconds: left()) { () async -> ProductLoad in
                    do { return ProductLoad(count: try await Product.products(for: [unlock]).count, error: nil) } catch { return ProductLoad(count: 0, error: "\(error)") }
                }
                if load.count > 0 { break }
                if let error = load.error { lastError = error }
                if Date() > deadline {
                    throw StoreKitStepTimedOut(description: "no product from the test session (is the test host signed with its bundle id?); last StoreKit error: \(lastError)")
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            done.append("product \(elapsed()) ms")
            let lead = listenerLead - Date().timeIntervalSince(listening)
            if lead > 0 { try await Task.sleep(for: .seconds(lead)) }
            storeKitTrace("StoreKit test environment up after \(elapsed()) ms (\(done.joined(separator: ", "))); StoreKit's list first read \(Int(Date().timeIntervalSince(listening) * 1000)) ms after the run listener started; round trips until \(promptInARow) in a row are prompt")
            var inARow = 0
            while inARow < promptInARow {
                if trips > 0 { try await Task.sleep(for: .seconds(1)) }
                guard Date() < deadline else {
                    throw StoreKitEnvironmentFailure(description: "not \(promptInARow) prompt round trips in a row within \(Int(budget)) s (\(trips) round trips, each in the trace)")
                }
                trips += 1
                let trip = try await roundTrip(trips, url, unlock, until: deadline)
                inARow = trip.isPrompt ? inARow + 1 : 0
                storeKitTrace("StoreKit round trip \(trips) at \(elapsed()) ms: \(trip)")
            }
            done.append("\(trips) round trips \(elapsed()) ms")
            storeKitTrace("StoreKit test environment ready after \(elapsed()) ms (\(done.joined(separator: ", ")))")
            return BringUp(failure: nil, trips: trips)
        } catch {
            let failure = "StoreKit test environment not ready after \(elapsed()) ms (done: \(done.joined(separator: ", ")); round trips: \(trips)): \(error); host \(Bundle.main.bundleIdentifier ?? "-")"
            storeKitTrace(failure)
            return BringUp(failure: failure, trips: trips)
        }
    }

    /// One round trip the way a purchase test makes it. A wait for StoreKit's list stops after
    /// `waitCap` (that round trip is not prompt; the next one starts over with a new session);
    /// the step around it gives up 2 s later, so only a read that does not return ends the
    /// bring-up there. The calls on the session queue may take what is left of the budget: the
    /// queue is serial, so a call that hangs holds up every later one anyway. Each step is timed
    /// inside the session-queue call or the off-main step itself.
    nonisolated private static func roundTrip(_ number: Int, _ url: URL, _ unlock: String, until deadline: Date) async throws -> RoundTrip {
        func left() -> Double { max(1, deadline.timeIntervalSinceNow) }
        func cap() -> Double { min(waitCap, max(0, deadline.timeIntervalSinceNow)) }
        var trip = RoundTrip()
        let (store, setUp) = try await onSessionQueue("round trip: set up a session", seconds: left()) { () throws -> (PurchaseTestStore, Double) in
            let start = Date()
            let session = try SKTestSession(contentsOf: url)
            StoreKitEnvironment.configure(session)
            return (PurchaseTestStore(session), Date().timeIntervalSince(start))
        }
        trip.setUp = setUp
        let held = try await onSessionQueue("round trip: read the new session", seconds: left()) { store.session.allTransactions().count }
        guard held == 0 else { throw StoreKitEnvironmentFailure(description: "a new session already holds \(held) transactions") }
        let emptyWait = cap()
        let empty = try await within("round trip: StoreKit lists no unlock", seconds: emptyWait + 2) {
            await StoreKitEnvironment.readUntil(listed: false, unlock, seconds: emptyWait)
        }
        trip.noUnlock = empty
        guard empty.reached else { return trip }
        let heardBefore = StoreKitRunListener.shared.count
        let (boughtAt, buy) = try await onSessionQueue("round trip: buy in the session", seconds: left()) { () throws -> (Date, Double) in
            let start = Date()
            try store.session.buyProduct(productIdentifier: unlock)
            let end = Date()
            return (end, end.timeIntervalSince(start))
        }
        trip.buy = buy
        let listedWait = cap()
        let listed = try await within("round trip: StoreKit lists the purchase", seconds: listedWait + 2) {
            await StoreKitEnvironment.readUntil(listed: true, unlock, seconds: listedWait)
        }
        trip.listed = listed
        if let entry = listed.entry {
            // Finished the way the app finishes a purchase: on its own, not awaited (the first
            // one took 26.5 s in CI run 44157630387; no test waits for the app's either). Not a
            // counted step, so it holds up neither the bring-up nor the next `session()`.
            let transaction = entry.unsafePayloadValue
            Task.detached {
                let start = Date()
                await transaction.finish()
                storeKitTrace("StoreKit round trip \(number): finish ended after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            }
        }
        let (after, clear) = try await onSessionQueue("round trip: clear the session", seconds: left()) { () -> (Int, Double) in
            let start = Date()
            store.session.clearTransactions()
            let took = Date().timeIntervalSince(start)
            return (store.session.allTransactions().count, took)
        }
        trip.clear = clear
        guard after == 0 else { throw StoreKitEnvironmentFailure(description: "the session still holds \(after) transactions after clearing") }
        if listed.reached {
            let goneWait = cap()
            trip.gone = try await within("round trip: StoreKit lists no unlock after the clear", seconds: goneWait + 2) {
                await StoreKitEnvironment.readUntil(listed: false, unlock, seconds: goneWait)
            }
        }
        trip.heard = StoreKitRunListener.shared.heard(since: heardBefore, afterBuyAt: boughtAt)
        return trip
    }
}

/// Why StoreKit's test environment let a purchase test down: thrown by every test that needs
/// StoreKit when the bring-up failed, and recorded by a test whose session purchase StoreKit
/// never listed (`purchaseInSession`). Such a run fails with this reason, never passes.
struct StoreKitEnvironmentFailure: Error, CustomStringConvertible {
    let description: String
}

/// A listener on StoreKit's updates (`Transaction.updates`) for the whole test run,
/// independent of the app's code: a diagnostic. It prints every update with the time it
/// arrived, and each round trip and a session purchase StoreKit never lists say what it heard
/// after the buy, so the log shows whether StoreKit's list waited for the update (CI run
/// 44157630387: list and listener both 15,316 ms after the buy). It does not make the update
/// come sooner: it had been listening for 20.7 s then. The bring-up starts it first, at least
/// `StoreKitEnvironment.listenerLead` before the first round trip. It finishes nothing: where
/// a test starts the app's listener, that one does.
final class StoreKitRunListener: @unchecked Sendable {
    static let shared = StoreKitRunListener()
    private let lock = NSLock()
    private var started: Date?
    private var log: [(at: Date, text: String)] = []

    /// Starts listening, once per run; when it started.
    func start() -> Date {
        lock.withLock { () -> Date in
            if let started { return started }
            let now = Date()
            started = now
            Task.detached {
                for await result in Transaction.updates {
                    let update = result.unsafePayloadValue
                    self.record("#\(update.id) \(update.productID) revoked \(update.revocationDate != nil)")
                }
            }
            return now
        }
    }

    /// How many updates it heard so far.
    var count: Int { lock.withLock { log.count } }

    /// The updates from the `index`th on, each with the time it arrived after the buy.
    func heard(since index: Int, afterBuyAt boughtAt: Date) -> String {
        let heard = lock.withLock { log.dropFirst(index).map { "\($0.text) \(Int($0.at.timeIntervalSince(boughtAt) * 1000)) ms after the buy" } }
        return heard.isEmpty ? "nothing" : heard.joined(separator: ", ")
    }

    private func record(_ text: String) {
        let now = Date()
        let since = lock.withLock { () -> Int in
            log.append((at: now, text: text))
            return Int(now.timeIntervalSince(started ?? now) * 1000)
        }
        storeKitTrace("run listener heard \(text), \(since) ms after it started")
    }
}

/// One wait for StoreKit's list: whether it showed the state waited for, the product's entry
/// when it was listed, and the reads and time it took (measured where the reads ran).
struct ListWait: Sendable, CustomStringConvertible {
    let reached: Bool
    let entry: VerificationResult<Transaction>?
    let reads: Int
    let seconds: Double

    var milliseconds: Int { Int(seconds * 1000) }

    func reached(within limit: Double) -> Bool { reached && seconds <= limit }

    var description: String { "\(reached ? "after" : "not within") \(milliseconds) ms (reads: \(reads))" }
}

/// What one round trip of the bring-up measured (seconds), each step timed where it ran.
private struct RoundTrip: Sendable, CustomStringConvertible {
    /// A fifth of what a test allows for the same step: set-up 30 s, no unlock in StoreKit's
    /// list 15 s (`session()`), buy 20 s, the purchase in the list 10 s (`entitlement(for:)`),
    /// clear 60 s (the next test waits that long for it). The finish is not part of it: it runs
    /// on its own, as the app's does, and prints its time when it ends.
    static let setUpLimit: Double = 6
    static let noUnlockLimit: Double = 3
    static let buyLimit: Double = 4
    static let listedLimit: Double = 2
    static let clearLimit: Double = 12

    var setUp: Double = 0
    var noUnlock: ListWait?
    var buy: Double?
    var listed: ListWait?
    var clear: Double?
    var gone: ListWait?
    var heard = "nothing"

    var isPrompt: Bool {
        guard let noUnlock, let buy, let listed, let clear, let gone else { return false }
        return setUp <= Self.setUpLimit && noUnlock.reached(within: Self.noUnlockLimit) && buy <= Self.buyLimit
            && listed.reached(within: Self.listedLimit) && clear <= Self.clearLimit && gone.reached(within: Self.noUnlockLimit)
    }

    var description: String {
        var steps = ["session \(Self.ms(setUp)) ms"]
        if let noUnlock { steps.append("no unlock in the list \(noUnlock)") }
        if let buy { steps.append("buy \(Self.ms(buy)) ms") }
        if let listed { steps.append("purchase in the list \(listed)" + (listed.reached ? ", finish started" : "")) }
        if let clear { steps.append("clear \(Self.ms(clear)) ms") }
        if let gone { steps.append("no unlock after the clear \(gone)") }
        let listener = buy == nil ? "" : "; run listener heard \(heard)"
        return steps.joined(separator: ", ") + listener + (isPrompt ? "; prompt" : "; not prompt")
    }

    private static func ms(_ seconds: Double) -> Int { Int(seconds * 1000) }
}

/// How the bring-up ended: `failure` nil when the environment is ready.
private struct BringUp: Sendable {
    let failure: String?
    let trips: Int
}

/// One attempt to load the unlock product during the bring-up.
private struct ProductLoad: Sendable {
    let count: Int
    let error: String?
}

/// Every StoreKit step that started and has not ended, also one whose test stopped waiting
/// for it. A step given up on goes on running; `PurchaseStoreKitTests.session()` lets no
/// test start before it ended, so it never acts on the next test's session.
final class StoreKitSteps: @unchecked Sendable {
    static let shared = StoreKitSteps()
    private let lock = NSLock()
    private var steps: [Int: String] = [:]
    private var count = 0

    func begin(_ step: String) -> Int {
        lock.withLock {
            count += 1
            steps[count] = step
            return count
        }
    }

    func end(_ token: Int) {
        lock.withLock { steps[token] = nil }
    }

    var running: [String] {
        lock.withLock { steps.keys.sorted().compactMap { steps[$0] } }
    }

    func waitUntilIdle(seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let open = running
            if open.isEmpty { return }
            if Date() > deadline {
                throw StoreKitStepTimedOut(description: "StoreKit steps of an earlier test still running after \(Int(seconds)) s: \(open.joined(separator: "; "))")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// The one thread for the test session's blocking calls (set up, buy, refund, clear, read).
/// Not Swift's cooperative pool: the simulator on the CI runner has three cores, so the pool
/// has three threads, shared with the other suites running alongside. A blocking call that
/// hangs there takes one of them for as long as it hangs, also after its test gave up on it.
/// One serial queue also keeps the session's calls in order: none overlaps another.
let storeKitSessionQueue = DispatchQueue(label: "albumist.tests.storekit-session", qos: .userInitiated)

/// Runs one blocking call of the test session on `storeKitSessionQueue` and gives up after
/// `seconds`, so a call that never answers fails its test with the step's name. The call
/// counts as running (`StoreKitSteps`) until it really returns.
func onSessionQueue<T: Sendable>(_ step: String, seconds: Double = 30, _ call: @escaping @Sendable () throws -> T) async throws -> T {
    let token = StoreKitSteps.shared.begin(step)
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let once = ResumeOnce(continuation)
        storeKitSessionQueue.async {
            let result = Result<T, any Error> { try call() }
            StoreKitSteps.shared.end(token)
            once.resume(result)
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(.failure(StoreKitStepTimedOut(description: "StoreKit step did not finish within \(Int(seconds)) s: \(step)")))
        }
    }
}

/// A call on the session queue whose end nobody awaits (the clear after a test); counted as
/// running until it returns.
func startOnSessionQueue(_ step: String, _ call: @escaping @Sendable () -> Void) {
    let token = StoreKitSteps.shared.begin(step)
    storeKitSessionQueue.async {
        call()
        StoreKitSteps.shared.end(token)
    }
}

/// Runs one asynchronous StoreKit step (product, StoreKit's list, the app's purchase call)
/// off the main actor and gives up after `seconds`, so a step that never answers fails its
/// test with the step's name instead of stopping the whole test run. The step counts as
/// running (`StoreKitSteps`) until it really ends. Blocking calls of the test session go
/// through `onSessionQueue` instead.
func within<T: Sendable>(_ step: String, seconds: Double = 30, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let token = StoreKitSteps.shared.begin(step)
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
        let once = ResumeOnce(continuation)
        Task.detached {
            let result: Result<T, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            StoreKitSteps.shared.end(token)
            once.resume(result)
        }
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(.failure(StoreKitStepTimedOut(description: "StoreKit step did not finish within \(Int(seconds)) s: \(step)")))
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// A line the CI log keeps (its filter passes "Test case"): what a StoreKit step really did.
func storeKitTrace(_ text: String) {
    print("STOREKIT Test case trace: \(text)")
}
