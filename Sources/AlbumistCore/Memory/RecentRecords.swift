import Foundation

/// Records by key that keep what was set last, up to a limit (review F of design wave 3, F14):
/// past it the older half goes, not all of them. The thumbnails' records of a video's length and
/// of the side each thumbnail was kept at (`ThumbnailCache`) are only a shortcut to what is in
/// memory; emptied whole, a fast scroll through a large library lost them several times, and a
/// photo whose thumbnail was still in memory opened on a black page. Setting a record again makes
/// it the latest; reading it does not.
public struct RecentRecords<Value> {
    /// The most records kept; at least two.
    public let limit: Int
    private var values: [String: Value] = [:]
    /// When each record was set last, on a counter.
    private var stamps: [String: Int] = [:]
    private var clock = 0

    public init(limit: Int) {
        self.limit = max(limit, 2)
    }

    public var count: Int { values.count }

    /// The keys of the records kept, in no order.
    public var keys: [String] { Array(values.keys) }

    /// The record of `key`; setting it makes it the latest, nil lets it go.
    public subscript(key: String) -> Value? {
        get { values[key] }
        set {
            guard let newValue else {
                values[key] = nil
                stamps[key] = nil
                return
            }
            if values[key] == nil, values.count >= limit { dropOlderHalf() }
            clock += 1
            values[key] = newValue
            stamps[key] = clock
        }
    }

    /// All records go (a memory warning).
    public mutating func removeAll() {
        values.removeAll()
        stamps.removeAll()
    }

    /// The older half goes: every record set before the middle one.
    private mutating func dropOlderHalf() {
        let middle = stamps.values.sorted()[stamps.count / 2]
        stamps = stamps.filter { $0.value >= middle }
        values = values.filter { stamps[$0.key] != nil }
    }
}

extension RecentRecords: Sendable where Value: Sendable {}
