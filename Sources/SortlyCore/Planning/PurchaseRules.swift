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

        public init(productID: String, isVerified: Bool = true, isRevoked: Bool = false, isFamilyShared: Bool = false) {
            self.productID = productID
            self.isVerified = isVerified
            self.isRevoked = isRevoked
            self.isFamilyShared = isFamilyShared
        }
    }

    /// True when a verified, not revoked entitlement for `productID` exists. A purchase shared
    /// by the family counts like an own one: StoreKit only hands it out when sharing is on.
    public static func isUnlocked(by entitlements: [Entitlement], productID: String) -> Bool {
        entitlements.contains { $0.productID == productID && $0.isVerified && !$0.isRevoked }
    }
}
