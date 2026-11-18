import Foundation
import SortlyCore

/// "Ignorieren" and "Nicht mehr ignorieren" are seen at once (app-speed, 18.11.2026). UI runs
/// measured 1.2 to 1.3 s from the tap to the note "2 Fotos ignoriert", and about as long for a
/// photo to leave "Ignoriert": the app waited for the store and the whole recount
/// (`AppModel.refreshDerived`) before it showed anything (owner limit: no pause of 1 s or more).
///
/// Now the photo states change on the main actor right away, from what is shown, and the
/// recount follows in the background. This is exact, not a guess: ignoring sets every area of
/// a photo to "ignored" (an excluded photo stays excluded), and the state of an ignored photo
/// once it is no longer ignored is the one the last count made without the ignore
/// (`DerivedLibraryStatus.ifNotIgnored`), or the one it had right before it was ignored. So
/// the recount gives the same states and the same numbers; nothing moves back.
///
/// A tap is remembered until a count includes it (`settle`): a count that began before the tap
/// was stored read the overrides without it and would show the photo where it was. The tap is
/// laid over such a count again, so the photo does not jump back and forth.
public struct IgnoreChange: Sendable {
    /// What the app shows about ignoring: the photo states, the photos ignored, and for each
    /// ignored photo its state once it is no longer ignored.
    public struct Shown: Sendable, Equatable {
        public var states: [AssetID: AssetOrganizationState]
        public var ignored: Set<AssetID>
        public var ifNotIgnored: [AssetID: AssetOrganizationState]

        public init(states: [AssetID: AssetOrganizationState] = [:], ignored: Set<AssetID> = [],
                    ifNotIgnored: [AssetID: AssetOrganizationState] = [:]) {
            self.states = states
            self.ignored = ignored
            self.ifNotIgnored = ifNotIgnored
        }

        /// What a count shows (`DerivedLibraryStatus`).
        public init(_ derived: DerivedLibraryStatus) {
            self.init(states: derived.states, ignored: derived.ignored, ifNotIgnored: derived.ifNotIgnored)
        }
    }

    /// One tap on "Ignorieren", "Widerrufen" or "Nicht mehr ignorieren".
    struct Step: Sendable {
        let id: Int
        let assets: [AssetID]
        let ignore: Bool
        /// Counts with this call number or a later one read the overrides with this tap.
        var includedFrom: Int?
    }

    private var steps: [Step] = []
    private var nextID = 0

    public init() {}

    /// Taps no count includes yet.
    public var pending: Int { steps.count }

    /// The photos of `assets` that are not ignored yet, each once, in order: what the store's
    /// `ignoreAssets` returns for them, and what "Widerrufen" takes back.
    public static func newlyIgnored(_ assets: [AssetID], ignored: Set<AssetID>) -> [AssetID] {
        var seen = ignored
        return assets.filter { seen.insert($0).inserted }
    }

    /// A photo's state once it is ignored: every area "ignored", an excluded photo stays
    /// excluded (`OrganizationStatusResolver.areaStatus`: excluded comes first).
    public static func ignoredState(_ state: AssetOrganizationState) -> AssetOrganizationState {
        guard !state.areas.values.contains(.excluded) else { return state }
        var result = state
        for area in state.areas.keys { result.areas[area] = .ignored }
        return result
    }

    /// Shows one tap at once and remembers it until a count includes it. Returns its number
    /// for `stored` and `failed`.
    @discardableResult
    public mutating func record(_ assets: [AssetID], ignore: Bool, in shown: inout Shown) -> Int {
        let step = Step(id: nextID, assets: assets, ignore: ignore)
        nextID += 1
        Self.apply(step, to: &shown)
        steps.append(step)
        return step.id
    }

    /// The store has the tap: counts that begin with call number `nextCall` or later read it.
    public mutating func stored(_ id: Int, nextCall: Int) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].includedFrom = nextCall
    }

    /// The store did not take the tap: it is no longer laid over counts, so the next count
    /// shows the photos as they really are.
    public mutating func failed(_ id: Int) {
        steps.removeAll { $0.id == id }
    }

    /// A count with call number `call` arrives: the taps it includes are done, the others are
    /// laid over it again, in the order they were made.
    public mutating func settle(_ shown: inout Shown, call: Int) {
        steps.removeAll { step in step.includedFrom.map { call >= $0 } ?? false }
        for step in steps { Self.apply(step, to: &shown) }
    }

    static func apply(_ step: Step, to shown: inout Shown) {
        for id in step.assets {
            if step.ignore {
                // Already ignored: nothing changes (the store adds no second override either).
                guard shown.ignored.insert(id).inserted else { continue }
                guard let state = shown.states[id], !state.areas.values.contains(.excluded) else { continue }
                shown.ifNotIgnored[id] = state
                shown.states[id] = ignoredState(state)
            } else {
                guard shown.ignored.remove(id) != nil else { continue }
                // An excluded photo has no state of its own to go back to: it stays excluded.
                if let state = shown.ifNotIgnored.removeValue(forKey: id) { shown.states[id] = state }
            }
        }
    }
}
