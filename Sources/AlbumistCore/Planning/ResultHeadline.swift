import Foundation

/// What the result after a run says first (design 7.1, N-07), counted as in the plan's receipt
/// (`PlanReceipt`: "Zahlen wie im Beleg in allen Fällen"): a count with what it counts, big
/// ("10 neue Alben"), a smaller line below it ("mit 342 Fotos"; no arrow, "176 → 15" read as
/// "176 photos became 15"), where the new albums are only when the run made some, and what
/// "Rückgängig machen" below it does ("Entfernt die 10 neuen Alben. Deine Fotos bleiben.").
/// Photos added only to albums of the user's read "12 Fotos in 3 deiner Alben ergänzt" (draft
/// E3: the photos big, the user's albums in the line below). Photos added to albums Albumist
/// made (a retry fills the albums its first run made) keep the neutral words "1 Album ergänzt"
/// and "mit 5 Fotos": "deiner Alben" only for the user's own (review E of design wave 2).
///
/// What the plan did decides the words (`PlanReceipt.Kind`): a removal from "Alben von
/// Albumist" says what it removed ("1 Album entfernt"). Its result said "0 Fotos einsortiert"
/// and where "Deine neuen Alben" are (N-07). An undo says whether it removed again or brought
/// back what a removal had taken away.
public struct ResultHeadline: Hashable, Sendable {
    /// The big line: a count and what it counts, or no count.
    public enum Lead: Hashable, Sendable {
        /// "10 neue Alben", "1 neues Album".
        case newAlbums(Int)
        /// "12 Fotos" over "in 3 deiner Alben ergänzt" (`Detail.inYourAlbums`): photos went into
        /// albums of the user's own, no album was made. Counts the photos of those albums only.
        case addedPhotos(Int)
        /// "3 Alben ergänzt" over "mit 12 Fotos": photos went into existing albums, no album was
        /// made, and Albumist made some of them (or a retry fills the albums its first run made):
        /// no word about whose albums they are.
        case extendedAlbums(Int)
        /// "342 Fotos einsortiert": photos went in, but into no album that counts as new or
        /// extended (an album found after an interruption, `PlanReceipt.Album.Change.adopted`).
        case sortedPhotos(Int)
        /// "1 Album entfernt" (a removal from "Alben von Albumist").
        case removedAlbums(Int)
        /// "12 Fotos herausgenommen": a removal took Albumist's photos out of an album that
        /// holds photos of the user's too, so the album stays.
        case takenOutPhotos(Int)
        /// "Rückgängig gemacht".
        case undone
        /// Nothing to count ("Fertig"): renamed or moved albums only, or nothing the library
        /// confirmed. Never "0 Fotos einsortiert".
        case plain
    }

    /// The smaller line below the big one.
    public enum Detail: Hashable, Sendable {
        /// "mit 342 Fotos".
        case withPhotos(Int)
        /// "in 3 deiner Alben ergänzt", "in einem deiner Alben ergänzt": below the photos added
        /// to albums of the user's (`Lead.addedPhotos`).
        case inYourAlbums(Int)
        /// New albums and albums of the user's in one run: "2 Alben ergänzt · 342 Fotos
        /// einsortiert" ("mit 342 Fotos" under "10 neue Alben" would count photos of the user's
        /// albums as photos of the new ones).
        case extendedAndSorted(albums: Int, photos: Int)
        /// After a removal: the photos stay in the library.
        case photosStay
        /// An undo that removed what a plan made: "Albumist hat seine Alben und Zuordnungen
        /// wieder entfernt."
        case undoRemoved
        /// An undo that brought back what a removal took away.
        case undoRestored
    }

    /// What "Rückgängig machen" on the result does, said below the button.
    public enum UndoNote: Hashable, Sendable {
        /// "Entfernt die 10 neuen Alben. Deine Fotos bleiben."
        case removesNewAlbums(Int)
        /// "Nimmt die hinzugefügten Fotos wieder aus deinen 3 Alben. Deine Fotos bleiben."
        case takesOutAddedPhotos(albums: Int)
        /// New albums and albums of the user's: both are taken back.
        case removesNewAlbumsAndAddedPhotos
        /// "Legt das Album mit denselben Fotos wieder an." after a removal.
        case bringsBackAlbums(Int)
        /// "Legt die herausgenommenen Fotos wieder zurück."
        case putsBackPhotos
        /// Neither new nor extended albums counted: the general sentence.
        case general
    }

    public var kind: PlanReceipt.Kind
    public var lead: Lead
    public var detail: Detail?
    /// "Du findest sie in Fotos unter Sammlungen › Alben.": only when the run made new albums.
    public var showsWhereNewAlbumsAre: Bool
    /// What "Rückgängig machen" would do; nil for an undo, which is not taken back itself.
    public var undoNote: UndoNote?

    public init(kind: PlanReceipt.Kind, lead: Lead, detail: Detail?, showsWhereNewAlbumsAre: Bool, undoNote: UndoNote?) {
        self.kind = kind
        self.lead = lead
        self.detail = detail
        self.showsWhereNewAlbumsAre = showsWhereNewAlbumsAre
        self.undoNote = undoNote
    }

    /// The words for a plan that ran, from its receipt (built with the same plan). `albumistAlbums`:
    /// the albums Albumist made (its records): photos added to them are not said to be in the
    /// user's albums.
    public init(_ receipt: PlanReceipt, plan: ChangePlan, albumistAlbums: Set<CollectionID> = []) {
        let kind = PlanReceipt.Kind(plan)
        let created = receipt.albumsCreated
        let extended = receipt.albumsExtended
        let photos = receipt.photosAdded
        let deleted = receipt.containersDeleted
        let takenOut = receipt.membershipsRemoved
        switch kind {
        case .created:
            if created > 0 {
                let detail: Detail? = extended > 0 ? .extendedAndSorted(albums: extended, photos: photos)
                    : photos > 0 ? .withPhotos(photos) : nil
                self.init(kind: kind, lead: .newAlbums(created), detail: detail, showsWhereNewAlbumsAre: true,
                          undoNote: extended > 0 ? .removesNewAlbumsAndAddedPhotos : .removesNewAlbums(created))
            } else if extended > 0 {
                // The albums the line names: an album counts as extended only with photos the
                // library confirmed in it. The big number counts their photos, not those of an
                // album found after an interruption.
                let named = Set(receipt.albums.lazy.filter { $0.change == .extended && $0.added > 0 }.map(\.id))
                let added = Self.photos(addedTo: named, in: plan)
                // "deiner Alben" only when each is the user's own: none Albumist made, and no
                // retry (it fills the albums of its first run).
                let albumists = Set(albumistAlbums.map(\.rawValue))
                if plan.retries == nil && named.isDisjoint(with: albumists) {
                    self.init(kind: kind, lead: .addedPhotos(added), detail: .inYourAlbums(named.count),
                              showsWhereNewAlbumsAre: false, undoNote: .takesOutAddedPhotos(albums: named.count))
                } else {
                    self.init(kind: kind, lead: .extendedAlbums(named.count), detail: .withPhotos(added),
                              showsWhereNewAlbumsAre: false, undoNote: .general)
                }
            } else if photos > 0 {
                self.init(kind: kind, lead: .sortedPhotos(photos), detail: nil, showsWhereNewAlbumsAre: false, undoNote: .general)
            } else {
                self.init(kind: kind, lead: .plain, detail: nil, showsWhereNewAlbumsAre: false, undoNote: .general)
            }
        case .removed:
            if deleted > 0 {
                self.init(kind: kind, lead: .removedAlbums(deleted), detail: .photosStay, showsWhereNewAlbumsAre: false,
                          undoNote: .bringsBackAlbums(deleted))
            } else if takenOut > 0 {
                self.init(kind: kind, lead: .takenOutPhotos(takenOut), detail: .photosStay, showsWhereNewAlbumsAre: false,
                          undoNote: .putsBackPhotos)
            } else {
                self.init(kind: kind, lead: .plain, detail: nil, showsWhereNewAlbumsAre: false, undoNote: .putsBackPhotos)
            }
        case .undone:
            // An undo of a removal makes the album again and puts its photos back; an undo of
            // anything else removes. Nothing confirmed: no sentence that claims either.
            let removed = deleted + takenOut > 0
            let restored = created + photos > 0
            let detail: Detail? = removed ? .undoRemoved : restored ? .undoRestored : nil
            self.init(kind: kind, lead: .undone, detail: detail, showsWhereNewAlbumsAre: false, undoNote: nil)
        }
    }

    /// The words for a plan that ran. `inventory` only names albums, the counts come from the
    /// plan's journal.
    public init(plan: ChangePlan, inventory: CollectionInventory = CollectionInventory(), albumistAlbums: Set<CollectionID> = []) {
        self.init(PlanReceipt(plan: plan, inventory: inventory), plan: plan, albumistAlbums: albumistAlbums)
    }

    /// Distinct photos the library confirmed `plan` put into the albums `albums` (receipt ids,
    /// `PlanReceipt.Album.id`).
    static func photos(addedTo albums: Set<String>, in plan: ChangePlan) -> Int {
        var photos = Set<AssetID>()
        for step in plan.steps {
            guard case .addAssets(let ref, _) = step.operation, albums.contains(ResultCoverStack.id(of: ref)) else { continue }
            photos.formUnion(plan.confirmedMedia(of: step))
        }
        return photos.count
    }
}
