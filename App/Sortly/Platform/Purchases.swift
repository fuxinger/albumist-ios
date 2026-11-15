import Foundation
import Observation
import StoreKit
import SortlyCore

/// One-time unlock (decision 2026-11-13): free download, the first albums are free, then
/// a single non-consumable purchase unlocks everything. No subscription, no tracking.
/// The price always comes from StoreKit (`product.displayPrice`), never from the code: the
/// launch-week price and the regular price are set in App Store Connect and show as they are.
@MainActor
@Observable
final class Purchases {
    static let shared: Purchases = {
        // UI runs with `-SortlyUITestLocked` count free albums in a domain of their own that
        // starts empty at every launch, so the count never reaches the next run.
        if let defaults = UITestSupport.lockedPurchaseDefaults() {
            let purchases = Purchases(defaults: defaults)
            if let left = UITestSupport.freeAlbumsLeft {
                purchases.ledger = FreeAlbumLedger(legacyUsed: max(0, Purchases.freeAlbumLimit - left))
            }
            return purchases
        }
        return Purchases()
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

    private(set) var isUnlocked = false
    private(set) var product: Product?
    /// A purchase or a restore is in progress (buttons are disabled, the button shows progress).
    private(set) var isPurchasing = false
    var lastError: String?

    /// The free albums used, counted per plan (see `FreeAlbumLedger`). Kept in the user
    /// defaults, outside the database, so rebuilding the analysis does not hand out new ones.
    private(set) var ledger: FreeAlbumLedger
    /// Free albums held back for a plan that started but is not counted yet.
    private(set) var reserved: [SortlyID: Int] = [:]

    /// `defaults` and `productID` are for tests; the app uses the standard ones.
    init(defaults: UserDefaults = .standard, productID: String = Purchases.unlockProductID) {
        self.defaults = defaults
        self.productID = productID
        ledger = Self.loadLedger(from: defaults)
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
    /// run that tests the locked path (`-SortlyUITestLocked`).
    static var unlockedForUITests: Bool { UITestSupport.isRunning && !UITestSupport.locksPurchase }

    func recordUsage(plan: SortlyID, albums: Int) {
        if ledger.record(plan: plan, albums: albums) { saveLedger() }
    }

    /// After an undo the albums are gone again, so they do not count as used. Once per plan.
    func returnUsage(plan: SortlyID, albums: Int) {
        if ledger.giveBack(plan: plan, albums: albums) { saveLedger() }
    }

    /// Self-repair at launch: a plan the store shows as taken back never counts.
    func settleUndone(_ plans: Set<SortlyID>) {
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
    }

    // MARK: StoreKit

    @ObservationIgnored private var updates: Task<Void, Never>?

    /// The one call that shows Apple's purchase sheet. The unit tests put the StoreKit test
    /// session in its place: in the test host the sheet never appears and `Product.purchase()`
    /// never returns (CI runs 43763150106 and 43764929910, also with the window scene named),
    /// so they buy through the session and everything around this call stays the app's code.
    @ObservationIgnored var confirmPurchase: @MainActor (Product) async throws -> Product.PurchaseResult = { product in
        try await product.purchase()
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
        if transaction.revocationDate == nil {
            isUnlocked = true
            lastError = nil
        } else {
            // Revoked: another entitlement (bought by the user and shared) may still unlock.
            await refreshEntitlements(ignoring: transaction.id)
        }
    }

    /// `ignoring`: a transaction known to be revoked that StoreKit may still list for a moment.
    func refreshEntitlements(ignoring revoked: UInt64? = nil) async {
        var entitlements: [PurchaseRules.Entitlement] = []
        for await result in Transaction.currentEntitlements where result.unsafePayloadValue.id != revoked {
            switch result {
            case .verified(let transaction):
                entitlements.append(PurchaseRules.Entitlement(
                    productID: transaction.productID, isVerified: true, isRevoked: transaction.revocationDate != nil,
                    isFamilyShared: transaction.ownershipType == .familyShared))
            case .unverified(let transaction, _):
                entitlements.append(PurchaseRules.Entitlement(productID: transaction.productID, isVerified: false))
            }
        }
        isUnlocked = PurchaseRules.isUnlocked(by: entitlements, productID: productID)
    }

    func purchase() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        await loadProductIfNeeded()
        guard let product else {
            lastError = String(localized: "Der Kauf ist gerade nicht verfügbar. Bitte versuche es später noch einmal.")
            return
        }
        do {
            await handle(try await confirmPurchase(product))
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
                if transaction.productID == productID && transaction.revocationDate == nil { isUnlocked = true }
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
        isPurchasing = true
        defer { isPurchasing = false }
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
