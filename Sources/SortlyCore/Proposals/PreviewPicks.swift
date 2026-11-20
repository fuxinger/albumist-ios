import Foundation

/// The picks of previews opened straight from a button: "Dein Startpaket", "N Alben anlegen" in
/// a list, "Ergänzen …" and "Anlegen" on a card, "Album anlegen" on a suggestion. A pick is a
/// decision that exists only while its preview is open: the suggestion shows it, it is kept in
/// memory and never written to disk (`stored(_:)`), and it is given back when the preview ends
/// without creating (Fuchs, 14.11.: "Ich hatte aber noch nichts ausgewählt").
///
/// Two previews can pick the same suggestion, also with different choices (one on each tab),
/// and end in any order. A preview plans exactly its own picks (`planned(in:shown:)`): since
/// design wave 1 there is no basket, so a suggestion chosen under "Anpassen", or one left
/// selected by an older version's basket, keeps that choice for its own button and joins no
/// other preview (second review of the suggestion screens, 20.11.: the preview of three ticked
/// suggestions showed a fourth, chosen under "Anpassen" days before).
///
/// The model applies what a call returns (`Change`) to the decisions the suggestions show.
public struct PreviewPicks: Sendable {
    /// One preview's picks. Equal only to itself, whatever it picked: a route carries it to its
    /// preview, and two previews of the same suggestions are two previews.
    public struct Selection: Hashable, Sendable {
        public let id: UUID
        public let picks: [Pick]

        public static func == (a: Selection, b: Selection) -> Bool { a.id == b.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// What a preview chose for one suggestion.
    public struct Pick: Hashable, Sendable {
        public let proposal: SortlyID
        public let chosen: ProposalDecision

        public init(_ proposal: SortlyID, _ chosen: ProposalDecision) {
            self.proposal = proposal
            self.chosen = chosen
        }
    }

    /// What a suggestion shows after a call; nil is undecided.
    public struct Change: Hashable, Sendable {
        public let proposal: SortlyID
        public let decision: ProposalDecision?
    }

    /// A pick of an open preview. It is live while it is the suggestion's preview-only state;
    /// a decision settled otherwise (chosen on purpose, applied, set back by a recheck) ends
    /// that (`unmark`), and the pick then plans what the user chose.
    private struct Entry: Sendable {
        let selection: UUID
        let chosen: ProposalDecision
        var live: Bool
    }

    /// Per suggestion with live picks: what it held before the first of them (nil: undecided).
    /// Written to disk in place of the picks (`stored`).
    private var marks: [SortlyID: ProposalDecision?] = [:]
    /// The picks of the open previews per suggestion, the latest last; the suggestion shows
    /// the latest live one.
    private var open: [SortlyID: [Entry]] = [:]

    public init() {}

    /// Picks `picks` for a new preview; the suggestions show them now (the returned changes).
    public mutating func select(_ picks: [Pick], shown: [SortlyID: ProposalDecision]) -> (Selection, [Change]) {
        let selection = Selection(id: UUID(), picks: picks)
        var changes: [Change] = []
        for pick in picks {
            let id = pick.proposal
            // The first live pick remembers what was there; a later one finds it remembered.
            if marks[id] == nil { marks[id] = .some(shown[id]) }
            open[id, default: []].append(Entry(selection: selection.id, chosen: pick.chosen, live: true))
            changes.append(Change(proposal: id, decision: pick.chosen))
        }
        return (selection, changes)
    }

    /// Gives back the picks of `selection` (all, or those of the suggestions in `only`): the
    /// preview ended without creating, or "Die ersten N jetzt anlegen" left them out. A
    /// suggestion that still shows the pick shows the latest live pick of another preview
    /// still open for it, or, with none left, what was there before them all; the mark goes
    /// with the last of them. A suggestion settled otherwise meanwhile (chosen on purpose,
    /// applied, set back by a recheck) keeps what it shows. Picks given back plan nothing more.
    public mutating func giveBack(_ selection: Selection, only: Set<SortlyID>? = nil,
                                  shown: [SortlyID: ProposalDecision]) -> [Change] {
        var changes: [Change] = []
        for pick in selection.picks.reversed() where only?.contains(pick.proposal) ?? true {
            let id = pick.proposal
            guard var entries = open[id],
                  let index = entries.lastIndex(where: { $0.selection == selection.id }) else { continue }
            let entry = entries.remove(at: index)
            open[id] = entries.isEmpty ? nil : entries
            guard entry.live, let before = marks[id] else { continue }
            let live = entries.filter(\.live)
            if shown[id] == entry.chosen {
                let now = live.last?.chosen ?? before
                if now != shown[id] { changes.append(Change(proposal: id, decision: now)) }
            }
            if live.isEmpty { marks[id] = nil }
        }
        return changes
    }

    /// The suggestion's decision was settled otherwise: chosen on purpose, applied, set back by
    /// a recheck. Its mark goes, so nothing gives back over it; the picks of previews still
    /// open for it plan what it shows from now on.
    public mutating func unmark(_ id: SortlyID) {
        marks[id] = nil
        guard var entries = open[id] else { return }
        for index in entries.indices { entries[index].live = false }
        open[id] = entries
    }

    /// What the preview of `selection` plans, per suggestion: its own live pick; after the
    /// suggestion was settled on purpose meanwhile, what the user chose then, if that makes or
    /// changes an album (not what a later preview picks for it now). Picks given back, applied
    /// or set back plan nothing.
    public func planned(in selection: Selection, shown: [SortlyID: ProposalDecision]) -> [SortlyID: ProposalDecision] {
        var result: [SortlyID: ProposalDecision] = [:]
        for pick in selection.picks {
            let id = pick.proposal
            guard let entry = open[id]?.last(where: { $0.selection == selection.id }) else { continue }
            let decision: ProposalDecision?
            if entry.live {
                decision = entry.chosen
            } else if let before = marks[id] {
                // A later preview picks it now: what the user chose is what that one remembers.
                decision = before
            } else {
                decision = shown[id]
            }
            guard let decision, decision.isAccepted else { continue }
            result[id] = decision
        }
        return result
    }

    /// The decisions as they may be written to disk: a suggestion with live picks is written
    /// with what was there before them.
    public func stored(_ shown: [SortlyID: ProposalDecision]) -> [SortlyID: ProposalDecision] {
        var result = shown
        for (id, before) in marks { result[id] = before }
        return result
    }

    /// A completed undo gives a suggestion back what it had before the plan
    /// (`InterruptedPlanUndo.selectionToRestore`); returns what it shows now. `earlier` and
    /// `shownBefore` are the picks and the decision from when the undo started.
    ///
    /// Only previews still open get their picks back: one that ended meanwhile gave its pick
    /// back already, and nothing would give it back again (second review of the preview
    /// picks). Previews opened meanwhile keep theirs, the latest last; they give back what the
    /// suggestion had before the plan, not the empty state its results left for a moment.
    public mutating func restore(_ id: SortlyID, shownBefore: ProposalDecision?, from earlier: PreviewPicks) -> ProposalDecision? {
        let now = open[id] ?? []
        let stillOpen = Set(now.map(\.selection))
        let then = earlier.open[id] ?? []
        let known = Set(then.map(\.selection))
        let entries = then.filter { stillOpen.contains($0.selection) } + now.filter { !known.contains($0.selection) }
        open[id] = entries.isEmpty ? nil : entries
        // What the suggestion had before the picks live then, or, with none, what it showed.
        let base: ProposalDecision? = if let mark = earlier.marks[id] { mark } else { shownBefore }
        guard let latest = entries.last(where: \.live) else {
            marks[id] = nil
            return base
        }
        marks[id] = .some(base)
        return latest.chosen
    }
}
