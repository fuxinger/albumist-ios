import Foundation
import Observation
import StoreKit
import AlbumistCore
import UIKit

/// One-time unlock (decision 2026-11-13): free download, the first albums are free, then
/// a single non-consumable purchase unlocks everything. No subscription, no tracking.
/// The price always comes from StoreKit (`product.displayPrice`), never from the code: the
/// launch-week price and the regular price are set in App Store Connect and show as they are.
@MainActor
@Observable
final class Purchases {
    static let shared: Purchases = {
        // UI runs with `-AlbumistUITestLocked` count free albums in a domain of their own that
        // starts empty at every launch, so the count never reaches the next run. The set
        // start is used by no plan: taking back a plan of an earlier run (never counted here)
        // gives nothing back, also when its undo is finalized again after a relaunch.
        if let defaults = UITestSupport.lockedPurchaseDefaults() {
            let purchases = Purchases(defaults: defaults)
            if let left = UITestSupport.freeAlbumsLeft {
                purchases.ledger = FreeAlbumLedger(startingWithUsed: max(0, Purchases.freeAlbumLimit - left))
            }
            return purchases
        }
        return Purchases(keychain: .device)
    }()

    /// Albums Albumist may create or extend before the unlock is needed. Change here only.
    static let freeAlbumLimit = 10
    static let unlockProductID = "app.albumist.ios.unlock"
    /// The ledger as one value (see `saveLedger`).
    private static let ledgerKey = "purchases.ledger"
    // Before the ledger was one value it lived in three keys; read once to carry it over.
    private static let usedKey = "purchases.albumsUsed"
    private static let byPlanKey = "purchases.albumsByPlan"
    private static let returnedKey = "purchases.returnedPlans"

    let productID: String
    private let defaults: UserDefaults
    /// The shipped app keeps a second copy in the keychain, which survives deleting and
    /// installing Albumist again (plugin review N4). Tests and UI runs keep only their defaults
    /// (unit tests pass a stand-in).
    private let keychain: LedgerKeychain.Copy?
    /// Reads the keychain copy and merges it in; `keychainRead()` waits for it.
    @ObservationIgnored private var keychainMerge: Task<Void, Never>?

    private(set) var isUnlocked = false
    private(set) var product: Product?
    /// A purchase or a restore is in progress (buttons are disabled, the button shows progress).
    private(set) var isPurchasing = false
    var lastError: String?

    /// The free albums used, counted per plan (see `FreeAlbumLedger`). Kept in the user
    /// defaults, outside the database, so rebuilding the analysis does not hand out new ones.
    private(set) var ledger: FreeAlbumLedger
    /// Free albums held back for a plan that started but is not counted yet.
    private(set) var reserved: [AlbumistID: Int] = [:]

    /// `defaults` and `productID` are for tests; the app uses the standard ones.
    init(defaults: UserDefaults = .standard, productID: String = Purchases.unlockProductID, keychain: LedgerKeychain.Copy? = nil) {
        self.defaults = defaults
        self.productID = productID
        self.keychain = keychain
        ledger = Self.loadLedger(from: defaults)
        if let keychain {
            // After a new install the defaults are empty and the keychain still knows the count.
            // Read off the main thread: in UI run 45589509156 this read held the main thread for
            // 2.3 s at launch (the keychain answers through another process). The read is queued
            // here, before any write of this object, and the copy's queue runs them in order: a
            // count made while the read waits is never what it sees, and the merge writes both back.
            let answer = keychain.beginLoad()
            keychainMerge = Task { [weak self] in
                let saved = await answer()
                self?.merge(keychainCopy: saved)
            }
        }
    }

    /// Waits until the keychain copy is read and merged (at once without one). Every check that
    /// lets a plan use free albums waits for it (`AppModel.run`), so a new install never gets
    /// the albums the keychain already counted.
    func keychainRead() async {
        await keychainMerge?.value
    }

    private func merge(keychainCopy saved: FreeAlbumLedger?) {
        let before = ledger
        ledger = before.merged(with: saved ?? FreeAlbumLedger())
        if ledger != before || saved != ledger { saveLedger() }
    }

    /// Albums created or extended so far. A completed undo gives its albums back.
    var albumsUsed: Int { ledger.used }

    var remainingFreeAlbums: Int { ledger.remaining(limit: Self.freeAlbumLimit, reserved: reserved) }

    /// True if a plan touching `albums` albums may run without the unlock (the rule itself is
    /// `FreeAlbumLedger.allows`, tested on Linux).
    func allows(albums: Int) -> Bool {
        ledger.allows(albums: albums, limit: Self.freeAlbumLimit, unlocked: isUnlocked || Self.unlockedForUITests, reserved: reserved)
    }

    /// Debug builds only: the end-to-end UI test runs without the purchase sheet, except the
    /// run that tests the locked path (`-AlbumistUITestLocked`).
    static var unlockedForUITests: Bool { UITestSupport.isRunning && !UITestSupport.locksPurchase }

    func recordUsage(plan: AlbumistID, albums: Int) {
        if ledger.record(plan: plan, albums: albums) { saveLedger() }
    }

    /// After an undo the albums are gone again, so they do not count as used. Once per plan.
    func returnUsage(plan: AlbumistID, albums: Int) {
        if ledger.giveBack(plan: plan, albums: albums) { saveLedger() }
    }

    /// Self-repair at launch: a plan the store shows as taken back never counts.
    func settleUndone(_ plans: Set<AlbumistID>) {
        if ledger.settleUndone(plans) { saveLedger() }
    }

    /// An interrupted plan continues without a new check, so its albums are held back until
    /// it is continued (then counted), kept as it is (counted) or taken back. Undo plans never
    /// use free albums.
    func reserve(for plan: ChangePlan?) {
        guard let plan, plan.reverts == nil else {
            reserved = [:]
            return
        }
        reserved = [plan.id: plan.freeAlbumUse(applied: false)]
    }

    private static func loadLedger(from defaults: UserDefaults) -> FreeAlbumLedger {
        if let data = defaults.data(forKey: ledgerKey), let ledger = try? JSONDecoder().decode(FreeAlbumLedger.self, from: data) {
            return ledger
        }
        return FreeAlbumLedger(
            legacyUsed: defaults.integer(forKey: usedKey),
            byPlan: defaults.dictionary(forKey: byPlanKey) as? [String: Int] ?? [:],
            returned: Set(defaults.stringArray(forKey: returnedKey) ?? [])
        )
    }

    /// One value, written at once. With three separate keys an app ended between two writes
    /// could keep a plan that is neither counted nor marked as given back, and the next
    /// finalization would give its albums back a second time.
    private func saveLedger() {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.ledgerKey)
        keychain?.save(ledger)
    }

    // MARK: StoreKit

    @ObservationIgnored private var updates: Task<Void, Never>?

    /// What this run of the app was told about the unlock's transactions, merged with every
    /// read of StoreKit's list (see `PurchaseRules.SessionKnowledge`).
    @ObservationIgnored private var known = PurchaseRules.SessionKnowledge()

    /// A purchase or restore that never returns would keep Buy and Restore disabled until the
    /// next launch; after this time they work again (the late answer is still handled).
    @ObservationIgnored var purchaseTimeLimit: Duration = .seconds(120)
    @ObservationIgnored private var attempt = 0

    #if DEBUG
    /// Unit tests only (release builds cannot replace the sheet): the StoreKit test session in
    /// place of Apple's purchase sheet. In the test host the sheet never appears and
    /// `Product.purchase()` never returns (CI runs 43763150106 and 43764929910, also with the
    /// window scene named), so the tests buy through the session and everything around this
    /// one call stays the app's code.
    @ObservationIgnored var confirmPurchase: (@MainActor (Product) async throws -> Product.PurchaseResult)?
    #endif

    /// Apple's purchase sheet, shown in the window scene on screen (Apple's guidance since
    /// iOS 17 is to name the scene instead of leaving StoreKit to look for one).
    private func confirm(_ product: Product) async throws -> Product.PurchaseResult {
        #if DEBUG
        if let confirmPurchase { return try await confirmPurchase(product) }
        #endif
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            return try await product.purchase(confirmIn: scene)
        }
        return try await product.purchase()
    }

    /// Marks a purchase or restore as running, with the time limit above. Returns the
    /// attempt's number for `endAttempt`.
    private func beginAttempt() -> Int {
        attempt += 1
        let mine = attempt
        isPurchasing = true
        let limit = purchaseTimeLimit
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            self?.endAttempt(mine)
        }
        return mine
    }

    /// Only the attempt still running ends it: a late end of an older one never re-enables
    /// the buttons during a newer purchase.
    private func endAttempt(_ mine: Int) {
        if attempt == mine { isPurchasing = false }
    }

    /// Unit tests: stops the transaction listener (each test's own Purchases object).
    func stop() {
        updates?.cancel()
        updates = nil
        pendingWatch?.cancel()
        pendingWatch = nil
    }

    #if DEBUG
    /// Unit tests: every transaction update the listener received, in order.
    @ObservationIgnored private(set) var heardUpdates: [String] = []
    /// Unit tests: StoreKit's list and latest transaction of the unlock in place of StoreKit's
    /// own, to test the decisions of the re-reads with any answer (an empty list, a refund
    /// the listener missed). Release builds always ask StoreKit.
    @ObservationIgnored var entitlementsReader: (@MainActor () async -> [PurchaseRules.Entitlement])?
    @ObservationIgnored var latestReader: (@MainActor () async -> PurchaseRules.Entitlement?)?
    /// Unit tests: how often StoreKit's list was read (the pending re-reads stop in time).
    @ObservationIgnored private(set) var entitlementReads = 0
    #endif

    // MARK: Second paths besides the listener

    /// `Transaction.updates` is the way an approval (Ask to Buy), a purchase on another device
    /// or a refund reaches the running app, but its delivery is not guaranteed: in the Xcode
    /// test environment some updates never reached the listener (CI runs 43804944398 and
    /// 43808888243), and on a device one can come while the listener is not yet listening.
    /// Two cheap re-reads of StoreKit's entitlements close that gap; merged with `known`,
    /// they never undo anything.
    @ObservationIgnored private var pendingWatch: Task<Void, Never>?
    /// While a purchase waits for approval: how often, and for how long, the list is re-read.
    @ObservationIgnored var pendingCheckInterval: Duration = .seconds(5)
    @ObservationIgnored var pendingCheckCount = 120

    /// The app came back on screen: an approval or a purchase elsewhere shows now at the
    /// latest, without a restart.
    ///
    /// This read may only unlock: a purchase known only from StoreKit's list is not in `known`,
    /// so one empty or lagging read would otherwise lock a paying user. Locking is left to
    /// the listener, the launch read and "Kauf wiederherstellen", and to an explicit
    /// revocation: StoreKit's latest transaction of the unlock, refunded while the listener
    /// missed it, locks here too.
    func becameActive() async {
        guard !(Self.hostsUnitTests && self === Purchases.shared) else { return }
        if let latest = await latestEntitlement(), latest.isVerified, latest.isRevoked, let id = latest.transactionID {
            known.saw(transactionID: id, productID: latest.productID, isRevoked: true, unlockProductID: productID)
            await refreshEntitlements()
        } else {
            await refreshEntitlements(mayLock: false)
        }
        if isUnlocked {
            lastError = nil
            await finishUnfinished()
        }
    }

    /// Transactions of the unlock that the re-read found but nobody finished (their update
    /// never reached the listener): finished now, so StoreKit stops handing them out.
    private func finishUnfinished() async {
        #if DEBUG
        if entitlementsReader != nil { return }
        #endif
        for await result in Transaction.unfinished where result.unsafePayloadValue.productID == productID {
            if case .verified(let transaction) = result { Self.finishLater(transaction) }
        }
    }

    /// After a pending answer (Ask to Buy): the list is re-read for a while, so the approval
    /// unlocks even when its update does not reach the listener.
    private func watchPending() {
        pendingWatch?.cancel()
        let interval = pendingCheckInterval
        let count = pendingCheckCount
        pendingWatch = Task { [weak self] in
            for _ in 0..<count {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, !self.isUnlocked else { return }
                await self.refreshEntitlements(mayLock: false)
                if self.isUnlocked {
                    self.lastError = nil
                    return
                }
            }
        }
    }

    /// Debug builds hosting the unit tests: the app's own instance stays away from the App
    /// Store, so the StoreKit tests (PurchaseStoreKitTests) talk to their test session only
    /// and nothing the host asked the real App Store at launch gets in between.
    static var hostsUnitTests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    func start() {
        guard updates == nil, !(Self.hostsUnitTests && self === Purchases.shared) else { return }
        updates = Task { [weak self] in
            // A purchase approved later (Ask to Buy), made on another device, refunded or no
            // longer shared by the family arrives here and is applied (see `apply(update:)`);
            // the transaction is finished afterwards (see `finishLater`).
            for await result in Transaction.updates {
                guard let self else { return }
                #if DEBUG
                let update = result.unsafePayloadValue
                self.heardUpdates.append("#\(update.id) \(update.productID) revoked \(update.revocationDate != nil)")
                #endif
                if case .verified(let transaction) = result { await self.apply(update: transaction) }
                Self.finishLater(result.unsafePayloadValue)
            }
        }
        Task {
            await refreshEntitlements()
            await loadProduct()
        }
    }

    /// Name and price from StoreKit. Loaded again whenever the unlock is shown or bought, so
    /// a start without network does not leave the button without a price for good.
    func loadProduct() async {
        do {
            if let loaded = try await Product.products(for: [productID]).first { product = loaded }
        } catch {
            // Offline or App Store not reachable: tried again when the unlock is shown.
        }
    }

    func loadProductIfNeeded() async {
        if product == nil { await loadProduct() }
    }

    /// A transaction that changed (approved, bought elsewhere, refunded, sharing ended). The
    /// update itself decides: right after it StoreKit may not list the change in
    /// `currentEntitlements` yet (in the Xcode test environment a purchase was missing there
    /// right after it was made, CI run 43772050228), so reading the list alone could miss an
    /// approval or keep a refunded purchase unlocked.
    func apply(update transaction: Transaction) async {
        guard transaction.productID == productID else { return }
        let revoked = transaction.revocationDate != nil
        known.saw(transactionID: transaction.id, productID: transaction.productID, isRevoked: revoked, unlockProductID: productID)
        if !revoked {
            isUnlocked = true
            lastError = nil
        } else {
            // Revoked: another entitlement (bought by the user and shared) may still unlock.
            await refreshEntitlements()
        }
    }

    /// StoreKit's list, merged with what this run was told (`known`): a read that started
    /// before a purchase, approval or refund cannot undo it.
    /// `mayLock` false: the read may only unlock (re-reads on screen, while pending, after a
    /// redeemed offer code); see `becameActive()`.
    func refreshEntitlements(mayLock: Bool = true) async {
        let listed = await listedEntitlements()
        let merged = known.isUnlocked(listed: listed, productID: productID)
        if mayLock {
            isUnlocked = merged
        } else if merged {
            isUnlocked = true
        }
    }

    private func listedEntitlements() async -> [PurchaseRules.Entitlement] {
        #if DEBUG
        entitlementReads += 1
        if let entitlementsReader { return await entitlementsReader() }
        #endif
        var entitlements: [PurchaseRules.Entitlement] = []
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                entitlements.append(PurchaseRules.Entitlement(
                    productID: transaction.productID, isVerified: true, isRevoked: transaction.revocationDate != nil,
                    isFamilyShared: transaction.ownershipType == .familyShared, transactionID: transaction.id))
            case .unverified(let transaction, _):
                entitlements.append(PurchaseRules.Entitlement(productID: transaction.productID, isVerified: false,
                                                              transactionID: transaction.id))
            }
        }
        return entitlements
    }

    /// StoreKit's latest transaction of the unlock (it carries a refund as `revocationDate`).
    private func latestEntitlement() async -> PurchaseRules.Entitlement? {
        #if DEBUG
        if let latestReader { return await latestReader() }
        #endif
        guard let result = await Transaction.latest(for: productID) else { return nil }
        let transaction = result.unsafePayloadValue
        var verified = false
        if case .verified = result { verified = true }
        return PurchaseRules.Entitlement(productID: transaction.productID, isVerified: verified,
                                         isRevoked: transaction.revocationDate != nil,
                                         isFamilyShared: transaction.ownershipType == .familyShared, transactionID: transaction.id)
    }

    func purchase() async {
        guard !isPurchasing else { return }
        let mine = beginAttempt()
        defer { endAttempt(mine) }
        await loadProductIfNeeded()
        guard let product else {
            lastError = String(localized: "Der Kauf ist gerade nicht verfügbar. Bitte versuche es später noch einmal.")
            return
        }
        do {
            await handle(try await confirm(product))
        } catch {
            handle(error)
        }
    }

    /// What a purchase ended with (separate from `purchase()` so every outcome is tested).
    func handle(_ result: Product.PurchaseResult) async {
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                if transaction.productID == productID && transaction.revocationDate == nil {
                    known.saw(transactionID: transaction.id, productID: transaction.productID, isRevoked: false, unlockProductID: productID)
                    isUnlocked = true
                }
                lastError = nil
                Self.finishLater(transaction)
            case .unverified(let transaction, _):
                // Never unlock on an unverified receipt, but close the transaction so
                // it does not come back on every launch.
                Self.finishLater(transaction)
                lastError = String(localized: "Der Kauf konnte nicht bestätigt werden. Tippe auf „Kauf wiederherstellen“ oder versuche es später noch einmal.")
            }
        case .pending:
            lastError = String(localized: "Der Kauf wartet noch auf eine Bestätigung, zum Beispiel durch die Familienfreigabe. Albumist schaltet sich danach von selbst frei.")
            watchPending()
        case .userCancelled:
            // The user decided against it: an older message would only confuse.
            lastError = nil
        @unknown default:
            break
        }
    }

    /// Apple's order: deliver what was bought, then finish the transaction. The finish runs on
    /// its own so it never holds up the unlock or the purchase call: StoreKit may take long
    /// or fail with it (the Xcode test environment logged "Error finishing transaction ...
    /// StoreKitInternalError.unknown", CI run 43770704675). An unfinished transaction only
    /// comes back through `Transaction.updates` at the next start and is finished then.
    private static func finishLater(_ transaction: Transaction) {
        Task.detached { await transaction.finish() }
    }

    /// A purchase or restore that threw.
    func handle(_ error: any Error) {
        if let storeError = error as? StoreKitError {
            switch storeError {
            case .userCancelled:
                lastError = nil
                return
            case .networkError:
                lastError = Self.offlineMessage
                return
            default:
                break
            }
        }
        if error is URLError {
            lastError = Self.offlineMessage
            return
        }
        lastError = error.localizedDescription
    }

    private static var offlineMessage: String {
        String(localized: "Keine Verbindung zum App Store. Bitte prüfe deine Internetverbindung und versuche es noch einmal.")
    }

    /// "Kauf wiederherstellen": also on a second device or after a new install. StoreKit
    /// usually knows the purchase without it; the sync asks the App Store when it does not.
    func restore() async {
        guard !isPurchasing else { return }
        let mine = beginAttempt()
        defer { endAttempt(mine) }
        var syncError: (any Error)?
        do { try await AppStore.sync() } catch { syncError = error }
        await refreshEntitlements()
        if isUnlocked {
            lastError = nil
        } else if let syncError {
            handle(syncError)
        } else {
            // Without a word the button would seem to do nothing.
            lastError = String(localized: "Kein Kauf gefunden. Wenn du Albumist mit einem anderen Apple Account gekauft hast, melde dich damit im App Store an.")
        }
    }
}
