import Foundation

/// What the start page "Vorschläge" shows under its ring card, top to bottom (design wave 1,
/// drafts E1, E6 and E7). Decided here and tested on Linux; the app only draws it. The screen
/// itself (introduction, "Kein Zugriff", the main tabs) is `StartScreen`.
///
/// - The photo mosaic of the first analysis (`ScanShowRule` in the engine), then one big part:
///   - while the first analysis has not gone through: "Schon gefunden", the newest trips found
///     so far as big cards (decision 9A);
///   - after it, until the first album is made: "Dein Startpaket" (with at least three albums);
///   - later: "Neue Reisen", trips that ended after the last album was made (every trip while
///     none was made).
/// - Then the rows ("Reisen · Alle 41"): trips first, the entry to "Deine Welt" right under
///   them, then "Länder und Orte" and the other areas in the app's order. A row holds at most
///   `rowLimit` cards; "Alle 41" opens the whole list of the area.
/// - Nothing open after the first analysis: one calm card instead of empty rows.
///
/// Nothing moves under the user's finger (`StartVisit`): a card made here keeps its place and
/// says "Angelegt", the big cards stay while they exist, and "Dein Startpaket" stays for the
/// visit it was shown in.
public struct StartPage: Equatable, Sendable {
    public enum Section: Hashable, Sendable, Identifiable {
        /// The photo mosaic of the first analysis.
        case mosaic
        /// "Schon gefunden": trips found while the first analysis runs (9A).
        case earlyTrips([SortlyID])
        /// "Dein Startpaket".
        case starterSet
        /// "Neue Reisen".
        case newTrips([SortlyID])
        /// One area's row, e.g. "Reisen · Alle 41".
        case row(Row)
        /// The entry to "Deine Welt" (`AtlasTeaser`), right under the trips.
        case atlas
        /// Nothing is open: "Alles erledigt" instead of empty rows.
        case caughtUp

        public var id: String {
            switch self {
            case .mosaic: "mosaic"
            case .earlyTrips: "earlyTrips"
            case .starterSet: "starterSet"
            case .newTrips: "newTrips"
            case .row(let row): "row." + row.area.rawValue
            case .atlas: "atlas"
            case .caughtUp: "caughtUp"
            }
        }
    }

    /// One area's row of cards.
    public struct Row: Hashable, Sendable {
        public var area: OrganizationArea
        /// The cards in the app's order (`inDisplayOrder`), at most `StartPage.rowLimit`.
        public var cards: [SortlyID]
        /// The open suggestions of the area ("Alle 41"); the cards made in this visit are not
        /// open any more and do not count.
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
        /// The ones still open (no decision, not complete in Photos already).
        public var open: Set<SortlyID>
        /// The areas the app offers and the user turned on, in the app's order.
        public var areas: [OrganizationArea]
        /// The first analysis went through once.
        public var analysedOnce: Bool
        /// The photo mosaic of the first analysis is shown (`ScanShowRule`).
        public var showsMosaic: Bool
        /// How many albums "Dein Startpaket" would hold now (`AppModel.starterSet(limit:)`, with
        /// `StartPage.starterSetLimit`).
        public var starterSetSize: Int
        /// No album made and none chosen yet.
        public var nothingMadeYet: Bool
        /// The card for an empty library is shown: it explains the empty page itself.
        public var libraryHint: Bool
        public var visit: StartVisit

        public init(proposals: [AlbumProposal], open: Set<SortlyID>, areas: [OrganizationArea], analysedOnce: Bool,
                    showsMosaic: Bool = false, starterSetSize: Int = 0, nothingMadeYet: Bool = true,
                    libraryHint: Bool = false, visit: StartVisit = StartVisit()) {
            self.proposals = proposals
            self.open = open
            self.areas = areas
            self.analysedOnce = analysedOnce
            self.showsMosaic = showsMosaic
            self.starterSetSize = starterSetSize
            self.nothingMadeYet = nothingMadeYet
            self.libraryHint = libraryHint
            self.visit = visit
        }
    }

    public var sections: [Section]
    /// Cards on the page that were made from it in this visit: they say "Angelegt".
    public var made: Set<SortlyID>

    public init(sections: [Section], made: Set<SortlyID> = []) {
        self.sections = sections
        self.made = made
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

    public var showsStarterSet: Bool { sections.contains(.starterSet) }

    public static func make(_ input: Input) -> StartPage {
        let visit = input.visit
        let areas = Set(input.areas)
        let made = Set(visit.created).subtracting(input.open)
        let shown = input.proposals
            .filter { (input.open.contains($0.id) || made.contains($0.id)) && areas.contains($0.kind.area) }
            .inDisplayOrder()
        var sections: [Section] = []
        if input.showsMosaic { sections.append(.mosaic) }

        // The one big part. Trips come newest first (`inDisplayOrder`).
        let trips = shown.filter { $0.kind.area == .trips }
        var big: [SortlyID] = []
        if !input.analysedOnce {
            big = pick(trips.map(\.id), keeping: visit.highlighted)
            if !big.isEmpty { sections.append(.earlyTrips(big)) }
        } else if input.starterSetSize >= starterSetMinimum, input.nothingMadeYet || visit.showedStarterSet {
            sections.append(.starterSet)
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
        for proposal in input.proposals where input.open.contains(proposal.id) {
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

        let nothingOpen = big.isEmpty && tripsRow == nil && otherRows.isEmpty && !sections.contains(.starterSet)
        if nothingOpen, input.analysedOnce, !input.libraryHint {
            sections.append(.caughtUp)
        }
        if let tripsRow { sections.append(tripsRow) }
        sections.append(.atlas)
        sections += otherRows
        return StartPage(sections: sections, made: made.intersection(shown.map(\.id)))
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
/// begun afresh each time the page appears (back from a list, another tab, the app opened again).
public struct StartVisit: Equatable, Sendable {
    /// When the last album was made before this visit; nil while none was made. "Neue Reisen"
    /// are the trips that ended after it.
    public var lastMade: Date?
    /// Cards whose "Anlegen" was tapped in this visit: they keep their place and say "Angelegt"
    /// once made (and "Anlegen" again after "Widerrufen").
    public var created: [SortlyID]
    /// The big cards shown in this visit: they stay while they exist.
    public var highlighted: [SortlyID]
    /// "Dein Startpaket" was shown in this visit: it stays when a card's "Anlegen" makes the
    /// first album, and goes the next time the page appears.
    public var showedStarterSet: Bool

    public init(lastMade: Date? = nil) {
        self.lastMade = lastMade
        self.created = []
        self.highlighted = []
        self.showedStarterSet = false
    }

    /// "Anlegen" on a card.
    public mutating func create(_ id: SortlyID) {
        if !created.contains(id) { created.append(id) }
    }

    /// Remembers what the page shows now (after it is drawn).
    public mutating func saw(_ page: StartPage) {
        if !page.bigCards.isEmpty { highlighted = page.bigCards }
        if page.showsStarterSet { showedStarterSet = true }
    }
}
