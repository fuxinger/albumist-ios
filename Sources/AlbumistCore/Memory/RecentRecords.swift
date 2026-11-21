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

/// What a change in Photos does to the kept record of one video's length (review F of design
/// wave 3, F14 c, V4). The thumbnails keep each video's length (`ThumbnailCache`) from the asset
/// their lookup fetched, a snapshot: a video trimmed in Photos keeps its old length until the
/// change corrects it, and the cells on screen read theirs again when a length they may show
/// changed, so the badge and VoiceOver's words follow at once.
public enum KeptVideoLength {
    /// What the change said of a kept video whose asset was in memory.
    public enum Found: Equatable, Sendable {
        /// It changed (trimmed, edited, a favourite): its length now, in seconds.
        case changed(seconds: Double)
        case deleted
    }

    /// What happens to the record.
    public enum Step: Equatable, Sendable {
        /// Nothing: the change did not touch the video, or not its length.
        case keep
        /// The record takes the new length; `shown`: the length a thumbnail shows changed.
        case update(seconds: Double, shown: Bool)
        /// The record goes. Checked: the video was deleted. Unchecked: its asset is no longer in
        /// memory, so the change cannot be checked against it; the thumbnail kept for it goes
        /// too, so the next look asks Photos again (a thumbnail from memory passes no lookup that
        /// would write the record anew), and an old length never stays on unchecked.
        case drop(checked: Bool)

        /// The cells on screen read their record again: a length one may show changed or went.
        public var readsAgain: Bool {
            switch self {
            case .keep, .drop(checked: false): false
            case .update(_, let shown): shown
            case .drop(checked: true): true
            }
        }
    }

    /// - Parameters:
    ///   - seconds: The length kept.
    ///   - inMemory: The video's asset is in memory to check the change against.
    ///   - found: What the change said of it; nil when it did not touch it.
    public static func step(kept seconds: Double, inMemory: Bool, found: Found?) -> Step {
        guard inMemory else { return .drop(checked: false) }
        switch found {
        case nil: return .keep
        case .deleted: return .drop(checked: true)
        case .changed(let now):
            guard now != seconds else { return .keep }
            return .update(seconds: now, shown: VideoDuration(seconds: now) != VideoDuration(seconds: seconds))
        }
    }
}
