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
/// changed, so the badge and VoiceOver's words follow without the cell being made anew, once the
/// change was walked (some seconds after it, after the photo library watcher's pause). A record
/// that cannot be checked goes, and a cell on screen that shows its length asks Photos again
/// (review X1, `reading`).
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
        /// would write the record anew), and an old length never stays on unchecked: a cell on
        /// screen that shows it asks Photos again (review X1).
        case drop(checked: Bool)

        /// The cells on screen read their record again: a length one may show changed or went,
        /// also unchecked (review X1).
        public var readsAgain: Bool {
            switch self {
            case .keep: false
            case .update(_, let shown): shown
            case .drop: true
            }
        }
    }

    /// What a cell on screen does when the cells read their lengths again (`Step.readsAgain`).
    public enum Reading: Equatable, Sendable {
        /// The thumbnails know its video's length: shown, the new one or the same.
        case show(VideoDuration)
        /// Nothing: the thumbnails know no length and the cell shows none.
        case keep
        /// The cell shows a length the thumbnails no longer know (its record went unchecked, or a
        /// memory warning took it): it keeps it and asks Photos again, then shows what Photos said
        /// (`afterAsking`, review X1).
        case askAgain
    }

    /// Only a length the thumbnails know replaces what a cell shows (review X2): knowing none is
    /// not "no video", as the records of unchanged videos go too (a memory warning, a record
    /// dropped unchecked); a cell that shows a length then asks Photos again (review X1).
    /// - Parameters:
    ///   - shown: The length the cell shows (its badge, VoiceOver's words); nil when it shows none.
    ///   - known: The length the thumbnails know of its photo now; nil when they know none.
    public static func reading(shown: VideoDuration?, known: VideoDuration?) -> Reading {
        if let known { return .show(known) }
        return shown == nil ? .keep : .askAgain
    }

    /// What Photos said of a video a cell on screen asked about again (`Reading.askAgain`).
    public enum Answer: Equatable, Sendable {
        /// The video, as long as this now, in seconds (a trimmed video's new length).
        case length(seconds: Double)
        /// Photos no longer knows it (deleted), or it is no video: no length.
        case noLength
        /// Photos did not answer in time: nothing is known.
        case noAnswer
    }

    /// The length the cell shows once Photos answered: the new one; none when the video went;
    /// what it showed when Photos did not answer (it asks again after the next change).
    public static func afterAsking(shown: VideoDuration?, answer: Answer) -> VideoDuration? {
        switch answer {
        case .length(let seconds): VideoDuration(seconds: seconds)
        case .noLength: nil
        case .noAnswer: shown
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

/// Changes in Photos waiting for one walk over the kept records of videos' lengths (review V11
/// of design wave 3). An iCloud sync tells many changes in a row; each one walked up to 20,000
/// records on the main actor and asked Photos about every kept video, and two walks in flight
/// could end in the wrong order, an older length over a newer one. Now the changes wait in the
/// order Photos told them, and one walk at a time takes all that waited: from the photo library
/// watcher's debounced task, or at once when many wait (a long sync restarts the watcher's pause
/// with each change), so neither the waiting changes nor one walk grow without end. Without a
/// kept record there is nothing to correct: the changes go unwalked (a record made later is read
/// from Photos as it is then).
public struct ChangeBacklog<Change> {
    /// The most changes that wait for the watcher's pause: with this many the walk starts at once.
    public let limit: Int
    private var waiting: [Change] = []
    /// A walk runs: the changes that come meanwhile wait for the next one.
    public private(set) var isWalking = false
    /// The watcher asked for a walk while one ran: the next one follows it at once.
    private var askedMeanwhile = false

    public init(limit: Int) {
        self.limit = max(limit, 1)
    }

    /// How many changes wait.
    public var count: Int { waiting.count }

    /// A change came, after the ones before it. True when so many wait that the walk should
    /// start now, not after the watcher's pause.
    public mutating func arrived(_ change: Change) -> Bool {
        waiting.append(change)
        return !isWalking && waiting.count >= limit
    }

    /// The changes to walk now, in the order they came, all at once: nil while a walk runs (they
    /// wait for it to end) or when none waits. Without kept records they go unwalked.
    public mutating func take(recordsKept: Bool) -> [Change]? {
        guard !isWalking else {
            askedMeanwhile = true
            return nil
        }
        guard recordsKept, !waiting.isEmpty else {
            waiting.removeAll()
            return nil
        }
        isWalking = true
        defer { waiting.removeAll() }
        return waiting
    }

    /// The walk ended. True when the next one should start now: changes came meanwhile, and the
    /// watcher asked for them meanwhile or as many came as the limit.
    public mutating func walked() -> Bool {
        isWalking = false
        defer { askedMeanwhile = false }
        return !waiting.isEmpty && (askedMeanwhile || waiting.count >= limit)
    }
}

extension ChangeBacklog: Sendable where Change: Sendable {}
