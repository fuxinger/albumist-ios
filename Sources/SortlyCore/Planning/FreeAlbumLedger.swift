import Foundation

/// The free-album count, per plan (the app keeps it in UserDefaults and a copy in the
/// keychain, outside the database, so rebuilding the analysis or installing again does not
/// hand out new free albums). Every change is idempotent per
/// plan id, because the finalization that calls it runs again after a crash:
/// - a plan is counted once, from what it really changed;
/// - a completed undo gives that plan's albums back once (audit 2, 6.3), also a plan of the
///   older total: what it gave back is kept per plan, so putting the two copies together
///   never takes a give-back away or makes one twice;
/// - at launch, plans the store shows as taken back are settled again.
/// The app stores it as one value (Codable), so an app ended between two writes can never
/// keep half of a change (a plan neither counted nor marked as given back).
public struct FreeAlbumLedger: Hashable, Sendable, Codable {
    /// Albums counted as one total by versions before the per-plan count, as they counted
    /// them. A give-back never lowers it; it is kept in `legacyReturned`.
    public var legacyUsed: Int
    /// Plan id → albums that plan created or extended.
    public var byPlan: [String: Int]
    /// Plans whose albums were given back after an undo.
    public var returned: Set<String>
    /// Plan id → albums given back from `legacyUsed` (plans counted by an older version).
    public var legacyReturned: [String: Int]

    /// The `byPlan` entry of a set start (`init(startingWithUsed:)`); no plan has this id.
    static let setStartKey = "albumist.set-start"

    public init(legacyUsed: Int = 0, byPlan: [String: Int] = [:], returned: Set<String> = [], legacyReturned: [String: Int] = [:]) {
        self.legacyUsed = legacyUsed
        self.byPlan = byPlan
        self.returned = returned
        self.legacyReturned = legacyReturned
    }

    /// A count that starts with `used` albums no plan can give back (UI runs start with a set
    /// number of free albums left, in a count of their own that begins empty at every launch:
    /// plans of earlier runs were never counted in it, so taking them back gives nothing).
    public init(startingWithUsed used: Int) {
        self.init(byPlan: used > 0 ? [Self.setStartKey: used] : [:])
    }

    /// What is left of the older total after its give-backs, never below zero.
    public var legacyLeft: Int { max(0, legacyUsed - legacyReturned.values.reduce(0, +)) }

    public var used: Int { legacyLeft + byPlan.values.reduce(0, +) }

    /// Free albums left of `limit`. `reserved`: plans that started but are not counted yet
    /// (an interrupted plan can be continued without a new check, so its albums are held
    /// back; otherwise a second plan could use them first and the total would pass the
    /// limit). A reservation of a plan that is already counted or given back holds nothing.
    public func remaining(limit: Int, reserved: [SortlyID: Int] = [:]) -> Int {
        let held = reserved.reduce(0) { sum, entry in
            byPlan[entry.key.rawValue] != nil || returned.contains(entry.key.rawValue) ? sum : sum + max(0, entry.value)
        }
        return max(0, limit - used - held)
    }

    /// Whether a plan that uses `albums` free albums may run: always once unlocked; without
    /// the unlock only while it fits into what is left, exactly at the limit included. A plan
    /// that creates or extends no album (removing, taking back) always may.
    public func allows(albums: Int, limit: Int, unlocked: Bool, reserved: [SortlyID: Int] = [:]) -> Bool {
        unlocked || albums <= 0 || albums <= remaining(limit: limit, reserved: reserved)
    }

    /// Returns whether anything changed.
    @discardableResult
    public mutating func record(plan: SortlyID, albums: Int) -> Bool {
        guard albums > 0, byPlan[plan.rawValue] == nil, !returned.contains(plan.rawValue) else { return false }
        byPlan[plan.rawValue] = albums
        return true
    }

    /// After an undo the albums are gone again. Plans counted by an older version give back
    /// `albums` from the old total, at most what is left of it, kept per plan together with
    /// the plan marked as given back (one value, one write). Once per plan.
    @discardableResult
    public mutating func giveBack(plan: SortlyID, albums: Int) -> Bool {
        guard returned.insert(plan.rawValue).inserted else { return false }
        if byPlan.removeValue(forKey: plan.rawValue) == nil {
            let fromOlderTotal = min(albums, legacyLeft)
            if fromOlderTotal > 0 { legacyReturned[plan.rawValue] = fromOlderTotal }
        }
        return true
    }

    /// The two copies of the count put together (plugin review N4: the count lived only in the
    /// user defaults, so deleting and installing Albumist again handed out new free albums;
    /// the app now keeps a second copy in the keychain, which survives that). Nothing used is
    /// ever lost: every plan either copy counted stays counted, a plan given back in either
    /// copy stays given back, and the old total is the larger one, less what either copy gave
    /// back from it (per plan, so a give-back neither gets lost nor counts twice).
    public func merged(with other: FreeAlbumLedger) -> FreeAlbumLedger {
        let returned = returned.union(other.returned)
        var byPlan = byPlan.merging(other.byPlan) { max($0, $1) }
        for plan in returned { byPlan[plan] = nil }
        return FreeAlbumLedger(legacyUsed: max(legacyUsed, other.legacyUsed), byPlan: byPlan, returned: returned,
                               legacyReturned: legacyReturned.merging(other.legacyReturned) { max($0, $1) })
    }

    /// Plans the store shows as taken back never count, even if the app ended between the
    /// undo and giving back. Only per-plan counts are touched: whether the old total already
    /// gave a plan back cannot be known, so it stays as it is.
    @discardableResult
    public mutating func settleUndone(_ plans: Set<SortlyID>) -> Bool {
        var changed = false
        for id in plans where byPlan.removeValue(forKey: id.rawValue) != nil {
            returned.insert(id.rawValue)
            changed = true
        }
        return changed
    }

    // MARK: Stored form

    // `legacyUsed` is written as what is left of the older total, as versions before the
    // per-plan give-backs read it (they lowered it themselves); the total as counted is
    // `legacyCounted`. A value without it (an earlier version wrote it) is that version's
    // total, its give-backs already taken off.
    private enum CodingKeys: String, CodingKey {
        case legacyUsed, byPlan, returned, legacyCounted, legacyReturned
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        byPlan = try c.decode([String: Int].self, forKey: .byPlan)
        returned = try c.decode(Set<String>.self, forKey: .returned)
        if let counted = try c.decodeIfPresent(Int.self, forKey: .legacyCounted) {
            legacyUsed = counted
            legacyReturned = try c.decodeIfPresent([String: Int].self, forKey: .legacyReturned) ?? [:]
        } else {
            legacyUsed = try c.decode(Int.self, forKey: .legacyUsed)
            legacyReturned = [:]
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(legacyLeft, forKey: .legacyUsed)
        try c.encode(byPlan, forKey: .byPlan)
        try c.encode(returned, forKey: .returned)
        try c.encode(legacyUsed, forKey: .legacyCounted)
        try c.encode(legacyReturned, forKey: .legacyReturned)
    }
}
