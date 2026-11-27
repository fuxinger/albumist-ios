import Foundation

/// What the start page keeps while it is on screen, so nothing moves under the user's finger:
/// begun afresh each time the page is back on top (back from a list once the swipe has ended,
/// another tab, the app opened again from the background).
public struct StartVisit: Equatable, Sendable {
    /// When the last album was made before this visit; nil while none was made. "Neue Reisen"
    /// are the trips that ended after it.
    public var lastMade: Date?
    /// Cards whose "Anlegen" was tapped in this visit: they keep their place, say "Angelegt"
    /// once made, and "Anlegen" again after "Widerrufen".
    public var created: [AlbumistID]
    /// Made from a card in this visit, and not yet seen done by the page: the run clears the
    /// pick before the suggestions are matched again, and a run with gaps leaves the album
    /// short of photos. Their cards say "Angelegt" meanwhile, never "Anlegen" again, until the
    /// plan that made them is taken back (`undone`).
    public var awaitingDone: Set<AlbumistID>
    /// The plan that made each card of `awaitingDone`, where it is known.
    public var madeBy: [AlbumistID: AlbumistID]
    /// The big cards shown in this visit: they stay while they exist.
    public var highlighted: [AlbumistID]
    /// "Dein Startpaket" as first shown in this visit: it stays, with what is left of it, when
    /// a card's "Anlegen" makes one of its albums or the first album, and goes the next time
    /// the page appears.
    public var shownStarterSet: [AlbumistID]?

    public init(lastMade: Date? = nil) {
        self.lastMade = lastMade
        self.created = []
        self.awaitingDone = []
        self.madeBy = [:]
        self.highlighted = []
        self.shownStarterSet = nil
    }

    /// "Anlegen" on a card: it keeps its place from now on.
    public mutating func create(_ id: AlbumistID) {
        if !created.contains(id) { created.append(id) }
    }

    /// The album of a card's "Anlegen" is in Photos, made by `plan` (nil when unknown).
    public mutating func made(_ id: AlbumistID, by plan: AlbumistID?) {
        create(id)
        awaitingDone.insert(id)
        madeBy[id] = plan
    }

    /// The banner "„Name“ angelegt" for suggestion `id`, made by `plan`: a card whose "Anlegen"
    /// was tapped in this visit says "Angelegt", also when its album was made only after the
    /// purchase sheet (`AppModel.continueQuickCreate`, review A of design wave 1). A banner for a
    /// suggestion made elsewhere changes nothing.
    public mutating func announced(_ id: AlbumistID, by plan: AlbumistID) {
        guard created.contains(id) else { return }
        made(id, by: plan)
    }

    /// Plans taken back ("Widerrufen", the history): their cards say "Anlegen" again.
    public mutating func undone(_ plans: Set<AlbumistID>) {
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
