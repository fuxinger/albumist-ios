import Foundation

/// What the start page "Vorschläge" shows under its ring card, top to bottom (design wave 1,
/// drafts E1, E6 and E7). Decided here and tested on Linux; the app only draws it. The screen
/// itself (introduction, "Kein Zugriff", the main tabs) is `StartScreen`.
///
/// - The photo mosaic of the first analysis (`ScanShowRule` in the engine), then one big part:
///   - while the first analysis has not gone through: "Schon gefunden", the newest trips found
///     so far as big cards (decision 9A);
///   - after it, until the first album is made: "Dein Startpaket" (with at least three albums;
///     never beside an interrupted plan, whose "Rest anlegen" is the page's filled button then);
///   - later: "Neue Reisen", trips that ended after the last album was made (every trip while
///     none was made).
/// - Then the rows ("Reisen · Alle 41"): trips first, the entry to "Deine Welt" right under
///   them, then "Länder und Orte" and the other areas in the app's order. A row holds at most
///   `rowLimit` cards; "Alle 41" opens the whole list of the area.
/// - Nothing open after the first analysis: one calm card that says why instead of empty rows
///   ("Alles erledigt", "Wird neu berechnet", "Noch keine Vorschläge").
/// - Last, whenever there are suggestions: "Alle Vorschläge", the way to every one of them.
///
/// Open on this page is what `isOpen` says: also a suggestion chosen and waiting (a preview's
/// pick, "Anpassen"), so a card never leaves its row because a preview or "Anlegen" picked it.
/// Nothing moves under the user's finger (`StartVisit`): a card made here keeps its place and
/// says "Angelegt" once its album is in Photos, the big cards stay while they exist, and "Dein
/// Startpaket" stays for the visit it was shown in, with what is left of it.
public struct StartPage: Equatable, Sendable {
    public enum Section: Hashable, Sendable, Identifiable {
        /// The photo mosaic of the first analysis.
        case mosaic
        /// "Schon gefunden": trips found while the first analysis runs (9A).
        case earlyTrips([SortlyID])
        /// "Dein Startpaket", with the suggestions it holds now (its button: "3 Alben anlegen").
        case starterSet([SortlyID])
        /// "Neue Reisen".
        case newTrips([SortlyID])
        /// One area's row, e.g. "Reisen · Alle 41".
        case row(Row)
        /// The entry to "Deine Welt" (`AtlasTeaser`), right under the trips.
        case atlas
        /// Every suggestion is decided: "Alles erledigt" instead of empty rows.
        case caughtUp
        /// Nothing open while the suggestions are made anew (a recount, "Analyse neu aufbauen",
        /// a change in "Dein Zuhause"): "Wird neu berechnet", never "Alles erledigt".
        case rebuilding
        /// No suggestion at all: "Noch keine Vorschläge". `analysing`: a run goes on that may
        /// still find some.
        case noSuggestionsYet(analysing: Bool)
        /// The page's last row, whenever there are suggestions: "Alle Vorschläge".
        case allSuggestions(AllSuggestions)

        public var id: String {
            switch self {
            case .mosaic: "mosaic"
            case .earlyTrips: "earlyTrips"
            case .starterSet: "starterSet"
            case .newTrips: "newTrips"
            case .row(let row): "row." + row.area.rawValue
            case .atlas: "atlas"
            case .caughtUp: "caughtUp"
            case .rebuilding: "rebuilding"
            case .noSuggestionsYet: "noSuggestionsYet"
            case .allSuggestions: "allSuggestions"
            }
        }
    }

    /// "Alle Vorschläge" at the end of the page, with what the area list said before design
    /// wave 1: how many there are, how many of them are in the user's albums already, and that
    /// they are being made anew.
    public struct AllSuggestions: Hashable, Sendable {
        /// Every suggestion, also those decided, complete or set aside with "Nicht jetzt" (the
        /// list shows them all).
        public var total: Int
        /// Suggestions whose album is one of the user's already ("12 davon in deinen Alben").
        public var inYourAlbums: Int
        /// The suggestions are being made anew: "Wird neu berechnet".
        public var rebuilding: Bool

        public init(total: Int, inYourAlbums: Int, rebuilding: Bool) {
            self.total = total
            self.inYourAlbums = inYourAlbums
            self.rebuilding = rebuilding
        }
    }

    /// One area's row of cards.
    public struct Row: Hashable, Sendable {
        public var area: OrganizationArea
        /// The cards in the app's order (`inDisplayOrder`), at most `StartPage.rowLimit`.
        public var cards: [SortlyID]
        /// The open suggestions of the area ("Alle 41"); the cards made in this visit do not
        /// count.
        public var openCount: Int

        public init(area: OrganizationArea, cards: [SortlyID], openCount: Int) {
            self.area = area
            self.cards = cards
            self.openCount = openCount
        }

        /// "Alle 41" leads to the area's list as soon as there is more than one suggestion.
        public var showsAll: Bool { openCount > 1 }
    }

    public struct Input: Sendable {
        /// Every suggestion the model holds.
        public var proposals: [AlbumProposal]
        /// The ones open on this page (`StartPage.isOpen`).
        public var open: Set<SortlyID>
        /// The areas the app offers and the user turned on, in the app's order.
        public var areas: [OrganizationArea]
        /// The first analysis went through once.
        public var analysedOnce: Bool
        /// The photo mosaic of the first analysis is shown (`ScanShowRule`).
        public var showsMosaic: Bool
        /// The albums "Dein Startpaket" would hold now, best first (`AppModel.starterSet(limit:)`,
        /// with `StartPage.starterSetLimit`).
        public var starterSet: [SortlyID]
        /// How many albums "Dein Startpaket" may hold now (`StartPage.starterSetLimit`): the free
        /// albums left, so the set kept for the visit never offers more than are free.
        public var starterSetLimit: Int
        /// No album made and none chosen yet.
        public var nothingMadeYet: Bool
        /// The card for an empty library is shown: it explains the empty page itself.
        public var libraryHint: Bool
        /// The suggestions are being made anew: a recount, "Analyse neu aufbauen", a change in
        /// "Dein Zuhause".
        public var rebuilding: Bool
        /// An analysis runs that may bring suggestions (not a quick check for new photos, not
        /// the overnight refinement).
        public var analysing: Bool
        /// A plan was interrupted and its card offers "Rest anlegen".
        public var interruptedPlan: Bool
        /// Suggestions whose album is one of the user's already (`AlbumMatcher.sortingAlbums`).
        public var inYourAlbums: Int
        public var visit: StartVisit

        public init(proposals: [AlbumProposal], open: Set<SortlyID>, areas: [OrganizationArea], analysedOnce: Bool,
                    showsMosaic: Bool = false, starterSet: [SortlyID] = [], starterSetLimit: Int = StartPage.starterSetMaximum,
                    nothingMadeYet: Bool = true,
                    libraryHint: Bool = false, rebuilding: Bool = false, analysing: Bool = false,
                    interruptedPlan: Bool = false, inYourAlbums: Int = 0, visit: StartVisit = StartVisit()) {
            self.proposals = proposals
            self.open = open
            self.areas = areas
            self.analysedOnce = analysedOnce
            self.showsMosaic = showsMosaic
            self.starterSet = starterSet
            self.starterSetLimit = starterSetLimit
            self.nothingMadeYet = nothingMadeYet
            self.libraryHint = libraryHint
            self.rebuilding = rebuilding
            self.analysing = analysing
            self.interruptedPlan = interruptedPlan
            self.inYourAlbums = inYourAlbums
            self.visit = visit
        }
    }

    public var sections: [Section]
    /// Cards on the page that were made from it in this visit: they say "Angelegt".
    public var made: Set<SortlyID>
    /// Cards made in this visit that the page now sees done (no longer open): `StartVisit.saw`
    /// lets go of them, so "Widerrufen" brings "Anlegen" back.
    public var seenDone: Set<SortlyID>

    public init(sections: [Section], made: Set<SortlyID> = [], seenDone: Set<SortlyID> = []) {
        self.sections = sections
        self.made = made
        self.seenDone = seenDone
    }

    /// Whether a suggestion is open on the start page: it has no decision, or one the user or a
    /// preview accepted that still changes something in Photos (a pick for a preview or for
    /// "Anlegen", a choice under "Anpassen", a pick in the old basket of Build 40), and its
    /// album is not complete in Photos already. Set aside with "Nicht jetzt" or kept as it is,
    /// it is not. (`AppModel.openProposals`, without the accepted ones, is the analysis' list.)
    public static func isOpen(decision: ProposalDecision?, complete: Bool) -> Bool {
        if complete { return false }
        switch decision {
        case nil, .undecided?: return true
        case .reject?: return false
        case let chosen?: return !chosen.isKeepExisting
        }
    }

    /// At most this many cards in a row; "Alle 41" shows the rest.
    public static let rowLimit = 10
    /// At most this many big cards ("Schon gefunden", "Neue Reisen").
    public static let bigLimit = 2
    /// "Dein Startpaket" needs at least this many albums.
    public static let starterSetMinimum = 3
    /// "Dein Startpaket" holds up to this many albums.
    public static let starterSetMaximum = 10

    /// How many albums "Dein Startpaket" may hold: ten, or the free albums left before the
    /// purchase (none left: no starter set, "Anlegen" on a card opens the purchase sheet).
    public static func starterSetLimit(unlocked: Bool, freeAlbumsLeft: Int) -> Int {
        unlocked ? starterSetMaximum : max(0, min(starterSetMaximum, freeAlbumsLeft))
    }

    /// The big cards, if a section shows them.
    public var bigCards: [SortlyID] {
        for section in sections {
            switch section {
            case .earlyTrips(let ids), .newTrips(let ids): return ids
            default: continue
            }
        }
        return []
    }

    /// The suggestions of "Dein Startpaket", if the page shows it.
    public var starterSet: [SortlyID]? {
        for case .starterSet(let ids) in sections { return ids }
        return nil
    }

    public var showsStarterSet: Bool { starterSet != nil }

    public static func make(_ input: Input) -> StartPage {
        let visit = input.visit
        let areas = Set(input.areas)
        // Made from a card here: once no longer open, or right away when its run said so (the
        // pick is cleared before the suggestions are matched again).
        let made = Set(visit.created.filter { !input.open.contains($0) || visit.awaitingDone.contains($0) })
        let shown = input.proposals
            .filter { (input.open.contains($0.id) || made.contains($0.id)) && areas.contains($0.kind.area) }
            .inDisplayOrder()
        var sections: [Section] = []
        if input.showsMosaic { sections.append(.mosaic) }

        // The one big part. Trips come newest first (`inDisplayOrder`).
        let trips = shown.filter { $0.kind.area == .trips }
        var big: [SortlyID] = []
        let starter = starterSet(input, made: made)
        if !input.analysedOnce {
            big = pick(trips.map(\.id), keeping: visit.highlighted)
            if !big.isEmpty { sections.append(.earlyTrips(big)) }
        } else if !starter.isEmpty {
            sections.append(.starterSet(starter))
        } else {
            let fresh = trips.filter { trip in
                guard let since = visit.lastMade else { return true }
                guard let end = trip.dateRange?.end else { return false }
                return end > since
            }
            big = pick(fresh.map(\.id), keeping: visit.highlighted)
            if !big.isEmpty { sections.append(.newTrips(big)) }
        }

        // The rows: trips, then "Deine Welt", then places and the other areas.
        let bigSet = Set(big)
        var openCounts: [OrganizationArea: Int] = [:]
        for proposal in input.proposals where input.open.contains(proposal.id) && !made.contains(proposal.id) {
            openCounts[proposal.kind.area, default: 0] += 1
        }
        var cardsByArea: [OrganizationArea: [SortlyID]] = [:]
        for proposal in shown where !bigSet.contains(proposal.id) {
            if cardsByArea[proposal.kind.area, default: []].count < rowLimit {
                cardsByArea[proposal.kind.area, default: []].append(proposal.id)
            }
        }
        func row(_ area: OrganizationArea) -> Section? {
            guard let cards = cardsByArea[area], !cards.isEmpty else { return nil }
            return .row(Row(area: area, cards: cards, openCount: openCounts[area] ?? 0))
        }
        let others = input.areas.filter { $0 != .trips }
        let rest = others.filter { $0 == .places } + others.filter { $0 != .places }
        let otherRows = rest.compactMap(row)
        let tripsRow = areas.contains(.trips) ? row(.trips) : nil

        // Nothing open: why, in one calm card. "Alles erledigt" only when every suggestion is
        // decided and none can come meanwhile.
        let nothingOpen = big.isEmpty && tripsRow == nil && otherRows.isEmpty && starter.isEmpty
        if nothingOpen, input.analysedOnce, !input.libraryHint {
            if input.rebuilding {
                sections.append(.rebuilding)
            } else if input.proposals.isEmpty {
                sections.append(.noSuggestionsYet(analysing: input.analysing))
            } else if !input.analysing {
                sections.append(.caughtUp)
            }
        }
        if let tripsRow { sections.append(tripsRow) }
        sections.append(.atlas)
        sections += otherRows
        if !input.proposals.isEmpty {
            sections.append(.allSuggestions(AllSuggestions(total: input.proposals.count, inYourAlbums: input.inYourAlbums,
                                                           rebuilding: input.rebuilding)))
        }
        return StartPage(sections: sections, made: made.intersection(shown.map(\.id)),
                         seenDone: visit.awaitingDone.subtracting(input.open))
    }

    /// "Dein Startpaket": once shown in this visit, the same with what of it is still open
    /// (an album of it made from its card leaves it; nothing joins); otherwise, after the first
    /// analysis and before anything was made or chosen, the model's with at least
    /// `starterSetMinimum` albums. Never more than are free now (`Input.starterSetLimit`, best
    /// first: an album made from another card uses one, review A of design wave 1), and never
    /// beside an interrupted plan: its "Rest anlegen" is the page's one filled button then.
    static func starterSet(_ input: Input, made: Set<SortlyID>) -> [SortlyID] {
        guard input.analysedOnce, !input.interruptedPlan else { return [] }
        let limit = max(0, input.starterSetLimit)
        if let shown = input.visit.shownStarterSet {
            return Array(shown.filter { input.open.contains($0) && !made.contains($0) }.prefix(limit))
        }
        let offered = Array(input.starterSet.prefix(limit))
        guard input.nothingMadeYet, offered.count >= starterSetMinimum else { return [] }
        return offered
    }

    /// The big cards: those shown big before first (in their order, while they are still
    /// candidates), then the newest others up to `bigLimit`.
    static func pick(_ candidates: [SortlyID], keeping kept: [SortlyID]) -> [SortlyID] {
        let available = Set(candidates)
        var picked = kept.filter { available.contains($0) }.prefix(bigLimit).map { $0 }
        for id in candidates where picked.count < bigLimit && !picked.contains(id) {
            picked.append(id)
        }
        return picked
    }
}

/// What the start page keeps while it is on screen, so nothing moves under the user's finger:
/// begun afresh each time the page is back on top (back from a list once the swipe has ended,
/// another tab, the app opened again from the background).
public struct StartVisit: Equatable, Sendable {
    /// When the last album was made before this visit; nil while none was made. "Neue Reisen"
    /// are the trips that ended after it.
    public var lastMade: Date?
    /// Cards whose "Anlegen" was tapped in this visit: they keep their place, say "Angelegt"
    /// once made, and "Anlegen" again after "Widerrufen".
    public var created: [SortlyID]
    /// Made from a card in this visit, and not yet seen done by the page: the run clears the
    /// pick before the suggestions are matched again, and a run with gaps leaves the album
    /// short of photos. Their cards say "Angelegt" meanwhile, never "Anlegen" again, until the
    /// plan that made them is taken back (`undone`).
    public var awaitingDone: Set<SortlyID>
    /// The plan that made each card of `awaitingDone`, where it is known.
    public var madeBy: [SortlyID: SortlyID]
    /// The big cards shown in this visit: they stay while they exist.
    public var highlighted: [SortlyID]
    /// "Dein Startpaket" as first shown in this visit: it stays, with what is left of it, when
    /// a card's "Anlegen" makes one of its albums or the first album, and goes the next time
    /// the page appears.
    public var shownStarterSet: [SortlyID]?

    public init(lastMade: Date? = nil) {
        self.lastMade = lastMade
        self.created = []
        self.awaitingDone = []
        self.madeBy = [:]
        self.highlighted = []
        self.shownStarterSet = nil
    }

    /// "Anlegen" on a card: it keeps its place from now on.
    public mutating func create(_ id: SortlyID) {
        if !created.contains(id) { created.append(id) }
    }

    /// The album of a card's "Anlegen" is in Photos, made by `plan` (nil when unknown).
    public mutating func made(_ id: SortlyID, by plan: SortlyID?) {
        create(id)
        awaitingDone.insert(id)
        madeBy[id] = plan
    }

    /// The banner "„Name“ angelegt" for suggestion `id`, made by `plan`: a card whose "Anlegen"
    /// was tapped in this visit says "Angelegt", also when its album was made only after the
    /// purchase sheet (`AppModel.continueQuickCreate`, review A of design wave 1). A banner for a
    /// suggestion made elsewhere changes nothing.
    public mutating func announced(_ id: SortlyID, by plan: SortlyID) {
        guard created.contains(id) else { return }
        made(id, by: plan)
    }

    /// Plans taken back ("Widerrufen", the history): their cards say "Anlegen" again.
    public mutating func undone(_ plans: Set<SortlyID>) {
        let taken = madeBy.filter { plans.contains($0.value) }.keys
        for id in taken {
            awaitingDone.remove(id)
            madeBy[id] = nil
        }
    }

    /// Remembers what the page shows now (after it is drawn).
    public mutating func saw(_ page: StartPage) {
        if !page.bigCards.isEmpty { highlighted = page.bigCards }
        if shownStarterSet == nil, let set = page.starterSet { shownStarterSet = set }
        for id in page.seenDone {
            awaitingDone.remove(id)
            madeBy[id] = nil
        }
    }
}
