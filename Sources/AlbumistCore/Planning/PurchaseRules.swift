import Foundation

/// Which App Store entitlements unlock Albumist (one-time purchase, decision 2026-11-13).
/// Kept free of StoreKit so the rule is tested on Linux; the app maps StoreKit's
/// `Transaction.currentEntitlements` onto `Entitlement`.
public enum PurchaseRules {
    public struct Entitlement: Hashable, Sendable {
        public var productID: String
        /// StoreKit could verify the signed transaction (an unverified one never unlocks).
        public var isVerified: Bool
        /// Refunded, or no longer shared by the family organizer.
        public var isRevoked: Bool
        /// Bought by a family member and shared through Family Sharing (only delivered when
        /// Family Sharing is switched on for the product in App Store Connect).
        public var isFamilyShared: Bool
        /// StoreKit's transaction id, to match the list with what the app already saw.
        public var transactionID: UInt64?

        public init(productID: String, isVerified: Bool = true, isRevoked: Bool = false, isFamilyShared: Bool = false,
                    transactionID: UInt64? = nil) {
            self.productID = productID
            self.isVerified = isVerified
            self.isRevoked = isRevoked
            self.isFamilyShared = isFamilyShared
            self.transactionID = transactionID
        }
    }

    /// What the running app itself was told about the unlock's transactions: a purchase
    /// result, or an update (Ask to Buy approved, bought elsewhere, refunded, sharing ended).
    /// StoreKit's list of entitlements may lag behind both (in the Xcode test environment a
    /// purchase was missing from it right after it was made), and reads of the list run at
    /// the same time as purchases and updates (launch, restore, redeemed offer code). Merged
    /// with this, an older read can neither lock what was just bought nor unlock what was
    /// just refunded.
    public struct SessionKnowledge: Sendable, Equatable {
        /// Verified transactions of the unlock that the app was handed and that are not revoked.
        public private(set) var unlocking: Set<UInt64> = []
        /// Transactions of the unlock known to be revoked; the list never brings them back.
        public private(set) var revoked: Set<UInt64> = []

        public init() {}

        /// A verified transaction the app was handed. Others than the unlock are ignored.
        public mutating func saw(transactionID id: UInt64, productID: String, isRevoked: Bool, unlockProductID: String) {
            guard productID == unlockProductID else { return }
            if isRevoked {
                unlocking.remove(id)
                revoked.insert(id)
            } else if !revoked.contains(id) {
                unlocking.insert(id)
            }
        }

        /// StoreKit's list merged with this knowledge. A transaction the list shows revoked is
        /// remembered as revoked; a known revoked one in the list is left out; a known
        /// unlocking one counts even when the list does not show it yet.
        public mutating func isUnlocked(listed: [Entitlement], productID: String) -> Bool {
            var counted: [Entitlement] = []
            for entitlement in listed {
                if let id = entitlement.transactionID {
                    if revoked.contains(id) { continue }
                    if entitlement.isRevoked && entitlement.isVerified && entitlement.productID == productID {
                        unlocking.remove(id)
                        revoked.insert(id)
                        continue
                    }
                }
                counted.append(entitlement)
            }
            return PurchaseRules.isUnlocked(by: counted, productID: productID) || !unlocking.isEmpty
        }
    }

    /// True when a verified, not revoked entitlement for `productID` exists. A purchase shared
    /// by the family counts like an own one: StoreKit only hands it out when sharing is on.
    public static func isUnlocked(by entitlements: [Entitlement], productID: String) -> Bool {
        entitlements.contains { $0.productID == productID && $0.isVerified && !$0.isRevoked }
    }

    /// What the unlock button shows (plugin review W7). Without a price from the App Store the
    /// button cannot buy anything: it says "Preis wird geladen …" and cannot be tapped, instead
    /// of "Freischalten" followed by "Der Kauf ist gerade nicht verfügbar" (App Review 2.1).
    public enum UnlockButton: Hashable, Sendable {
        case loadingPrice, buy, purchasing

        public var isEnabled: Bool { self == .buy }
    }

    public static func unlockButton(hasPrice: Bool, isPurchasing: Bool) -> UnlockButton {
        if isPurchasing { return .purchasing }
        return hasPrice ? .buy : .loadingPrice
    }

    /// Seconds before the next try to load the price (offline at the start): 2, 4, 8, … 30.
    public static func priceRetryDelay(attempt: Int) -> Int {
        min(30, 2 << min(max(0, attempt), 4))
    }
}
