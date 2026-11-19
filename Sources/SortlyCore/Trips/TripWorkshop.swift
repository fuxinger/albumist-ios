import Foundation

extension TripCorrections {
    /// Splits and merges the user made (photos taken out of trips are counted elsewhere).
    public var changeCount: Int { forcedBreaks.count + forcedJoins.count }

    /// "Reise teilen": a new trip starts at `date`. A split always wins over an earlier merge
    /// (`TripDetector` checks breaks first), so nothing else has to change.
    public func splitting(at date: Date) -> TripCorrections {
        var copy = self
        if !copy.forcedBreaks.contains(date) {
            copy.forcedBreaks.append(date)
            copy.forcedBreaks.sort()
        }
        return copy
    }

    /// "Zusammenlegen": everything inside `interval` stays one trip. Splits the user made
    /// inside it earlier are dropped, otherwise they would still cut the merged trip.
    public func merging(_ interval: DateInterval) -> TripCorrections {
        var copy = self
        copy.forcedBreaks.removeAll { $0 > interval.start && $0 <= interval.end }
        copy.forcedJoins.removeAll { interval.start <= $0.start && $0.end <= interval.end }
        copy.forcedJoins.append(interval)
        copy.forcedJoins.sort { $0.start < $1.start }
        return copy
    }

    /// The user's splits and merges at a trip: a split at its start or shortly after its end
    /// (the other side of a split it came from), a merge over it. Oldest first.
    public func changes(around trip: DateInterval, margin: TimeInterval = 7 * 86_400) -> [TripChange] {
        let window = DateInterval(start: trip.start.addingTimeInterval(-margin), end: trip.end.addingTimeInterval(margin))
        let splits = forcedBreaks.filter { window.contains($0) }.map(TripChange.split)
        let merges = forcedJoins.filter { $0.intersects(trip) }.map(TripChange.merge)
        return (splits + merges).sorted { $0.date < $1.date }
    }

    /// "Aufheben": one split or merge is forgotten, the trips around it are detected again.
    public func removing(_ change: TripChange) -> TripCorrections {
        var copy = self
        switch change {
        case .split(let date): copy.forcedBreaks.removeAll { $0 == date }
        case .merge(let interval): copy.forcedJoins.removeAll { $0 == interval }
        }
        return copy
    }

    /// Back to automatic detection; photos the user took out of trips stay out.
    public func withoutSplitsAndMerges() -> TripCorrections {
        TripCorrections(excludedAssets: excludedAssets)
    }
}

/// One change the user made to the trips.
public enum TripChange: Hashable, Sendable {
    /// A new trip starts at this instant.
    case split(Date)
    /// Everything in this span is one trip.
    case merge(DateInterval)

    public var date: Date {
        switch self {
        case .split(let date): date
        case .merge(let interval): interval.start
        }
    }
}

/// "Reise-Werkstatt" (I07): the pure part of splitting a trip at a day and merging two
/// neighbouring trips. The app shows the days and the preview; the corrections are kept in
/// time (not in ids), so they hold for every later analysis.
public enum TripWorkshop {
    /// One calendar day of a trip with its photos, oldest first.
    public struct Day: Hashable, Sendable, Identifiable {
        public var start: Date
        public var assetIDs: [AssetID]
        public var id: Date { start }
        public var count: Int { assetIDs.count }
    }

    /// One side of a split or the merged trip: its time span and how many photos it holds.
    public struct Part: Hashable, Sendable {
        public var start: Date
        public var end: Date
        public var count: Int
    }

    /// The photos of a trip by calendar day.
    public static func days(of members: some Collection<AssetID>, dates: [AssetID: Date], calendar: Calendar) -> [Day] {
        var byDay: [Date: [(AssetID, Date)]] = [:]
        for id in members {
            guard let date = dates[id] else { continue }
            byDay[calendar.startOfDay(for: date), default: []].append((id, date))
        }
        return byDay.keys.sorted().map { day in
            let photos = byDay[day]!.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            return Day(start: day, assetIDs: photos.map(\.0))
        }
    }

    /// The two trips a split makes.
    public struct Split: Hashable, Sendable {
        public var first: Part
        public var second: Part
    }

    /// The two trips a split before `days[index]` makes. Nil when that would leave one side
    /// empty (the first day cannot start a new trip).
    public static func split(_ days: [Day], before index: Int, dates: [AssetID: Date]) -> Split? {
        guard index > 0, index < days.count else { return nil }
        func part(_ slice: ArraySlice<Day>) -> Part? {
            let ids = slice.flatMap(\.assetIDs)
            let times = ids.compactMap { dates[$0] }
            guard let start = times.min(), let end = times.max() else { return nil }
            return Part(start: start, end: end, count: ids.count)
        }
        guard let first = part(days[..<index]), let second = part(days[index...]) else { return nil }
        return Split(first: first, second: second)
    }

    /// The instant a split before `day` is stored as: the start of that calendar day.
    public static func splitInstant(before day: Day) -> Date { day.start }

    /// The time span that keeps two trips together: from the first photo of the earlier one
    /// to the last photo of the later one (the trips' own spans as a fallback).
    public static func mergeInterval(_ a: DateInterval, _ b: DateInterval,
                                     members: some Collection<AssetID>, dates: [AssetID: Date]) -> DateInterval {
        let times = members.compactMap { dates[$0] }
        let start = ([a.start, b.start] + times).min()!
        let end = ([a.end, b.end] + times).max()!
        return DateInterval(start: start, end: end)
    }

    /// The trips right before and after `trip` (by time) that are close enough to be one
    /// journey with a pause: at most `maxGap` between the end of one and the start of the other.
    public static func neighbours(of trip: DateInterval, among others: [DateInterval],
                                  maxGap: TimeInterval = 14 * 86_400) -> (before: Int?, after: Int?) {
        var before: Int?
        var after: Int?
        for (index, other) in others.enumerated() where other != trip {
            if other.end <= trip.start, trip.start.timeIntervalSince(other.end) <= maxGap {
                if before.map({ others[$0].end < other.end }) ?? true { before = index }
            } else if other.start >= trip.end, other.start.timeIntervalSince(trip.end) <= maxGap {
                if after.map({ others[$0].start > other.start }) ?? true { after = index }
            }
        }
        return (before, after)
    }

    /// What a split, a merge, "Aufheben" and "Reisen wieder automatisch erkennen" wait for. A
    /// change is applied by an analysis, so none is taken while one runs (it read the changes
    /// before) or while albums are made (a check follows them); each change starts a check
    /// itself, so right after one the next waits. The screens grey these controls and say why
    /// next to them until it ends (UI run 44375768011: right after a split the merge row was
    /// off, looked tappable and said nothing).
    public enum Wait: Hashable, Sendable {
        /// A check works out the trips again: the one a change starts, or one for new photos.
        /// Soon done.
        case tripsAgain
        /// The first analysis, or one that goes on after an interruption: until it is done,
        /// which can take a while.
        case analysis
        /// Albumist makes albums in Photos.
        case creatingAlbums
    }

    /// Nil when a change can be made now. `check`: the running analysis is a short check
    /// (`shortCheck`), not the first or a resumed one, one with work of its own or the refinement.
    /// `settling`: no run is going, but the end of one, or a refresh with the trips it made, is
    /// still going (`TripChangeLedger.settling`): soon done, whatever the run was ("Gleich
    /// wieder möglich"; second review of 194971b, S2: the end of a first analysis said "Danach
    /// wieder möglich" for the seconds after its card said it ended).
    public static func wait(creatingAlbums: Bool, analysing: Bool, settling: Bool = false, check: Bool) -> Wait? {
        if creatingAlbums { return .creatingAlbums }
        if analysing { return check ? .tripsAgain : .analysis }
        return settling ? .tripsAgain : nil
    }

    /// `check` for `wait` and `afterChange`: the run in progress is a short check, the one a
    /// change starts after a complete analysis or one for a few new photos. Not a check with work
    /// of its own (`newWork`: labels after "Themen" or "Dokumente" were turned on, many new
    /// photos), and not the overnight refinement, which runs without a kind of its own and keeps
    /// the last run's (review of b240899: both said "Gleich wieder möglich").
    public static func shortCheck(kind isCheck: Bool, newWork: Bool, refinement: Bool) -> Bool {
        isCheck && !newWork && !refinement
    }

    /// What the workshop does once a change is stored and its run asked for.
    public enum AfterChange: Hashable, Sendable {
        /// A short check applies it: the sheet waits for its end and then says what changed.
        case waitHere
        /// A longer run applies it, or none started yet (one waits for a change in "Dein
        /// Zuhause" or for "Analyse neu aufbauen"): the sheet says the change is saved and is
        /// applied once the analysis is done, and can be closed.
        case savedForLater
    }

    /// A change during a Pause starts the run that goes on with the paused analysis (decision
    /// 18.11.2026, "Analyse läuft dann weiter"), which can take tens of minutes; the sheet
    /// waited for it with no way to close (review of 163d656). It waits only where the note
    /// under the controls would say "Gleich wieder möglich".
    public static func afterChange(running: Bool, check: Bool) -> AfterChange {
        wait(creatingAlbums: false, analysing: running, check: check) == .tripsAgain ? .waitHere : .savedForLater
    }
}

/// Whether the trips on screen include the user's trip changes (`AppModel`), counted in changes.
///
/// "No analysis runs" is not the same as "the trips shown include the change": a run shows as
/// ended before its end has refreshed the overview (`refreshDerived`, seconds with a large
/// library), and a run that started before the change was stored (a change in Photos, a retry, a
/// pass of the overnight refinement) read the trips from before. Taking the one for the other,
/// the workshop said "Die Vorschläge sind schon angepasst" over the old trips, and the trip
/// controls were free while the old trips were shown. The sheet may be swiped away while it
/// waits (owner decision 19.11.2026), so the user was back at those trips at once: a merge made
/// on one of them spans it and drops the split just made (`TripCorrections.merging`), and the old
/// state came back.
///
/// Each change counts once when stored; a run reads the count at its start; its end, when it made
/// suggestions, writes what it read; a refresh of the overview shows what was written when it read
/// the store, once it assigns its result. Runs are told apart by `AppModel.analysisGeneration`.
public struct TripChangeLedger: Sendable, Equatable {
    public enum State: Hashable, Sendable {
        /// The trips shown include every change stored.
        case applied
        /// A run, or the end of one, is going: the trips shown are about to change.
        case waiting
        /// Stored, and no run that read it is going (one ended without suggestions, paused, or
        /// read the trips from before): it is made by the run that comes, as the workshop says
        /// ("Gespeichert … sobald die Analyse fertig ist").
        case savedForLater
    }

    /// Changes stored so far in this launch.
    public private(set) var stored = 0
    /// The newest change in suggestions a run has written to the store.
    public private(set) var written = 0
    /// The newest change in the suggestions on screen.
    public private(set) var shown = 0
    /// Runs going: the changes stored when each started.
    private var reading: [Int: Int] = [:]
    /// Runs that ended and whose end has not refreshed the overview yet.
    private var ending: Set<Int> = []

    public init() {}

    /// A split, a merge, "Aufheben" or the reset in the settings is stored (before its run starts).
    public mutating func changeStored() { stored += 1 }

    /// Run `run` starts: it reads the changes stored until now.
    public mutating func runStarted(_ run: Int) { reading[run] = stored }

    /// Run `run` ended (before it shows as ended). `madeSuggestions`: it made the suggestions from
    /// the trips it worked out (its report has the suggestions step); a run that threw, was
    /// stopped or paused before them made nothing.
    public mutating func runEnded(_ run: Int, madeSuggestions: Bool) {
        guard let read = reading.removeValue(forKey: run) else { return }
        if madeSuggestions { written = max(written, read) }
        ending.insert(run)
    }

    /// The end of run `run` has refreshed the overview (or will not: cut off).
    public mutating func runSettled(_ run: Int) {
        reading[run] = nil
        ending.remove(run)
    }

    /// Refreshes of the overview going (`LatestCall` numbers): what each read when it began.
    /// Only those that read changes not shown yet are kept.
    private var refreshes: [Int: Int] = [:]

    /// Refresh `call` begins reading the store: it will show what was written until now. Ended
    /// by `refreshEnded` on every way out (`defer`), also when a newer call replaced it or it
    /// threw.
    public mutating func refreshBegan(_ call: Int) {
        oneMoreComing = false
        if written > shown { refreshes[call] = written }
    }

    /// Refresh `call` assigned its result (it was the newest). A refresh that read earlier and
    /// lands later never takes it back.
    public mutating func refreshShown(_ call: Int) {
        if let read = refreshes[call] { shown = max(shown, read) }
    }

    /// A failed refresh with changes left to show: one more refresh comes, and the controls wait
    /// for it (third review of 194971b, SHOULD-1).
    private var oneMoreComing = false

    /// Refresh `call` threw (called in its `catch`, before `refreshEnded`). Whether to ask for
    /// exactly one more: only for the newest call (a newer one shows what it read), only while
    /// changes are written but not shown, and not for the one more itself (`retry`), so a store
    /// that keeps throwing is not asked for ever. Before, the change read "Gespeichert … sobald
    /// die Analyse fertig ist" with the controls free over the old trips, and no analysis was
    /// coming.
    public mutating func refreshFailed(_ call: Int, newest: Bool, retry: Bool) -> Bool {
        guard newest, !retry, written > shown else { return false }
        oneMoreComing = true
        return true
    }

    /// A refresh could not start (no store or pipeline): the one more asked for by
    /// `refreshFailed` is not coming, so the controls must not wait for it.
    public mutating func refreshCouldNotStart() {
        oneMoreComing = false
    }

    /// Refresh `call` is over, shown or not.
    public mutating func refreshEnded(_ call: Int) {
        if refreshes[call] != nil { refreshes[call] = nil }
    }

    /// A run, the end of one, or a refresh that read changes not shown yet is going: the trips
    /// shown are about to change, so the trip controls wait (`TripWorkshop.wait`). The end's own
    /// refresh can be replaced by a newer one (pull to refresh, an ignore tap, a settings save)
    /// that lands after the end is settled (second review of 194971b, M1).
    public var settling: Bool {
        !reading.isEmpty || !ending.isEmpty || oneMoreComing || refreshes.values.contains { $0 > shown }
    }

    public var state: State {
        if shown >= stored { return .applied }
        return settling ? .waiting : .savedForLater
    }
}
