import Foundation

/// The free-album count, per plan (the app keeps it in UserDefaults, outside the database, so
/// rebuilding the analysis does not hand out new free albums). Every change is idempotent per
/// plan id, because the finalization that calls it runs again after a crash:
/// - a plan is counted once, from what it really changed;
/// - a completed undo gives that plan's albums back once (audit 2, 6.3);
/// - at launch, plans the store shows as taken back are settled again.
public struct FreeAlbumLedger: Hashable, Sendable {
    /// Albums counted as one total by versions before the per-plan count.
    public var legacyUsed: Int
    /// Plan id → albums that plan created or extended.
    public var byPlan: [String: Int]
    /// Plans whose albums were given back after an undo.
    public var returned: Set<String>

    public init(legacyUsed: Int = 0, byPlan: [String: Int] = [:], returned: Set<String> = []) {
        self.legacyUsed = legacyUsed
        self.byPlan = byPlan
        self.returned = returned
    }

    public var used: Int { legacyUsed + byPlan.values.reduce(0, +) }

    /// Returns whether anything changed.
    @discardableResult
    public mutating func record(plan: SortlyID, albums: Int) -> Bool {
        guard albums > 0, byPlan[plan.rawValue] == nil, !returned.contains(plan.rawValue) else { return false }
        byPlan[plan.rawValue] = albums
        return true
    }

    /// After an undo the albums are gone again. Plans counted by an older version give back
    /// `albums` from the old total. Once per plan.
    @discardableResult
    public mutating func giveBack(plan: SortlyID, albums: Int) -> Bool {
        guard returned.insert(plan.rawValue).inserted else { return false }
        if byPlan.removeValue(forKey: plan.rawValue) == nil, albums > 0 {
            legacyUsed = max(0, legacyUsed - albums)
        }
        return true
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
}
