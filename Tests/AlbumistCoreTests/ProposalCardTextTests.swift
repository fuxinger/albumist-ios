import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// What a suggestion's card says (design wave 1, E1, E6 "Karten-Arten", E7; decisions "Punkt 2"
/// and "Punkt 3" of 16.11.2026): the album's exact name, one status sentence with the album's
/// name, one action. Every kind in German and English, one and many photos, long names.
@Suite("Proposal card text")
struct ProposalCardTextTests {
    static func ids(_ prefix: String, _ count: Int) -> Set<AssetID> {
        Set((0..<count).map { AssetID("\(prefix)\($0)") })
    }

    static func trip(_ count: Int = 16, title: String = "Kyoto, Oktober 2024", reliability: Reliability = .certain,
                     sensitive: Bool = false, folder: [String] = ["Reisen"]) -> AlbumProposal {
        AlbumProposal(id: AlbumistID("trip-kyoto"), kind: .trip, title: title, folderPath: folder,
                      assetIDs: ids("k", count), reliability: reliability, isSensitive: sensitive)
    }

    static func candidate(_ album: CollectionID, _ title: String, proposal: Int, albumCount: Int, shared: Int,
                          relation: AlbumRelation = .partOfProposal) -> MatchCandidate {
        MatchCandidate(albumID: album, albumTitle: title,
                       metrics: OverlapMetrics(proposalCount: proposal, albumCount: albumCount, intersection: shared),
                       relation: relation, nameSimilarity: 0, score: 0.9, isEditable: true)
    }

    static func match(_ proposal: AlbumProposal, _ status: MatchStatus, best: MatchCandidate? = nil,
                      alternatives: [MatchCandidate] = []) -> MatchResult {
        MatchResult(proposalID: proposal.id, status: status, best: best, alternatives: alternatives, sameNameAlbums: [], reasons: [])
    }

    /// "Florenz, Mai 2023" for the user's album "Toskana", which holds 4 of its 16 photos.
    /// A suggestion, what the match found for it, and the albums it was matched against.
    struct Matched {
        var proposal: AlbumProposal
        var match: MatchResult
        var inventory: CollectionInventory
    }

    static func florence() -> Matched {
        let proposal = AlbumProposal(id: AlbumistID("trip-florenz"), kind: .trip, title: "Florenz, Mai 2023", folderPath: ["Reisen"],
                                     assetIDs: ids("f", 16), reliability: .certain)
        let inAlbum = Set((0..<4).map { AssetID("f\($0)") }).union(ids("other", 30))
        let album = CollectionSnapshot(id: "toskana", title: "Toskana", assetIDs: inAlbum)
        let m = match(proposal, .extendable, best: candidate("toskana", "Toskana", proposal: 16, albumCount: 34, shared: 4))
        return Matched(proposal: proposal, match: m, inventory: CollectionInventory([album]))
    }

    static func card(_ proposal: AlbumProposal, decision: ProposalDecision? = nil, userTitle: String? = nil,
                     match: MatchResult? = nil, inventory: CollectionInventory = CollectionInventory(),
                     removed: Set<AssetID> = [], hidesPreview: Bool = false, root: String = "",
                     words: ProposalWords = .german) -> ProposalCardText {
        ProposalCardText(proposal: proposal, decision: decision, userTitle: userTitle, match: match, inventory: inventory,
                         removed: removed, hidesPreview: hidesPreview, rootFolderTitle: root, words: words)
    }

    // MARK: New album ("Anlegen")

    @Test func aNewAlbumSaysItsCountAndNeuesAlbum() {
        let card = Self.card(Self.trip())
        #expect(card.title == "Kyoto, Oktober 2024")
        #expect(card.subtitle == "16 Fotos · Neues Album")
        #expect(card.action == .create)
        #expect(!card.needsLook)
        #expect(card.status == .newAlbum)
        #expect(card.photoCount == 16)
        #expect(!card.isPersonal)
        #expect(card.accessibilityLabel == "Kyoto, Oktober 2024, 16 Fotos, Neues Album")
        let english = Self.card(Self.trip(), words: .english)
        #expect(english.subtitle == "16 photos · New album")
        #expect(english.title == "Kyoto, Oktober 2024", "an album's name is never translated")
    }

    @Test(arguments: [(1, "1 Foto · Neues Album", "1 photo · New album"),
                      (2, "2 Fotos · Neues Album", "2 photos · New album"),
                      (999, "999 Fotos · Neues Album", "999 photos · New album"),
                      (1_000, "1.000 Fotos · Neues Album", "1,000 photos · New album"),
                      (1_354, "1.354 Fotos · Neues Album", "1,354 photos · New album")])
    func countsAreSingularPluralAndGrouped(_ count: Int, _ german: String, _ english: String) {
        #expect(Self.card(Self.trip(count)).subtitle == german)
        #expect(Self.card(Self.trip(count), words: .english).subtitle == english)
    }

    /// Photos taken out of the suggestion are not counted (`AppModel.members(of:)`).
    @Test func removedPhotosAreNotCounted() {
        let card = Self.card(Self.trip(), removed: ["k0", "k1", "k2", "not-in-it"])
        #expect(card.photoCount == 13)
        #expect(card.subtitle == "13 Fotos · Neues Album")
    }

    /// An album without photos is no album to create at once.
    @Test func withEveryPhotoTakenOutNothingIsCreatedAtOnce() {
        let card = Self.card(Self.trip(2), removed: ["k0", "k1"])
        #expect(card.subtitle == "0 Fotos · Neues Album")
        #expect(card.action == .look)
    }

    // MARK: The title is the album's name in Photos

    /// The card's name is the name the plan gives the album, built as `AppModel.buildPlan` does
    /// (the user's name for a new album without one of its own, then the planner).
    @Test(arguments: [nil, "Kirschblüten in Kyoto", "  Kyoto mit Oma  "])
    func theTitleIsTheNameThePlanGivesTheAlbum(_ userTitle: String?) throws {
        let proposal = Self.trip()
        for root in ["", "Albumist"] {
            let card = Self.card(proposal, userTitle: userTitle, root: root)
            var decision = ProposalDecision.recommended(for: proposal, match: nil, userTitle: userTitle)
            if case .createNew(nil, let path) = decision, let title = userTitle.flatMap(UserTitle.stored) {
                decision = .createNew(title: title, folderPath: path)
            }
            let plan = OrganizationPlanner(rootFolderTitle: root)
                .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: CollectionInventory())
            let created = plan.steps.compactMap { step -> String? in
                if case .createAlbum(_, let title, _) = step.operation { return title }
                return nil
            }
            let folders = plan.steps.compactMap { step -> String? in
                if case .createFolder(_, let title, _) = step.operation { return title }
                return nil
            }
            #expect(created == [card.title])
            guard case .newAlbum(let title, let path) = card.outcome else {
                Issue.record("not a new album: \(card.outcome)")
                continue
            }
            #expect(title == card.title)
            #expect(path == folders, "the folder the plan makes")
        }
    }

    /// A name chosen under "Anpassen" ("Neues Album wählen") wins over the stored one, as in the plan.
    @Test func theNameChosenForTheNewAlbumWins() {
        let card = Self.card(Self.trip(), decision: .createNew(title: "Japan 2024", folderPath: nil), userTitle: "Kyoto")
        #expect(card.title == "Japan 2024")
        #expect(card.action == .create)
    }

    /// Long names stay whole: the card wraps them (2 lines), the core never shortens them; over
    /// Photos' limit they are cut exactly where the planner cuts them.
    @Test func longNamesStayWholeUpToThePlannersLimit() {
        let long = Self.card(Self.trip(48, title: "Vereinigte Staaten, August 2023"))
        #expect(long.title == "Vereinigte Staaten, August 2023")
        #expect(long.subtitle == "48 Fotos · Neues Album")
        let tooLong = String(repeating: "Sehr lange Reise ", count: 10)
        let card = Self.card(Self.trip(title: tooLong))
        #expect(card.title == AlbumTitle.sanitize(tooLong))
        #expect(card.title.count <= AlbumTitle.maxLength)
        let album = String(repeating: "Toskana und Umbrien ", count: 4).trimmingCharacters(in: .whitespaces)
        let proposal = Self.florence().proposal
        let m = Self.match(proposal, .extendable, best: Self.candidate("long", album, proposal: 16, albumCount: 20, shared: 4))
        let inventory = CollectionInventory([CollectionSnapshot(id: "long", title: album, assetIDs: Set((0..<4).map { AssetID("f\($0)") }))])
        #expect(Self.card(proposal, match: m, inventory: inventory).subtitle == "Kommt in dein Album „\(album)“ · +12 Fotos")
    }

    // MARK: The user's own album ("Ergänzen …")

    @Test func addingToTheUsersAlbumNamesItAndTheNewPhotos() {
        let florence = Self.florence()
        let proposal = florence.proposal, m = florence.match, inventory = florence.inventory
        let card = Self.card(proposal, match: m, inventory: inventory)
        #expect(card.title == "Florenz, Mai 2023")
        #expect(card.subtitle == "Kommt in dein Album „Toskana“ · +12 Fotos")
        #expect(card.action == .add(albumName: "Toskana", newPhotos: 12))
        #expect(card.status == .addsTo(album: "Toskana", newPhotos: 12))
        #expect(!card.needsLook)
        #expect(card.outcome == .addsTo(album: "toskana", title: "Toskana", newPhotos: 12))
        #expect(card.accessibilityLabel == "Florenz, Mai 2023, Kommt in dein Album „Toskana“, +12 Fotos")
        let english = Self.card(proposal, match: m, inventory: inventory, words: .english)
        #expect(english.subtitle == "Goes into your album “Toskana” · +12 photos")
    }

    @Test func oneNewPhotoIsSingular() {
        let florence = Self.florence()
        let proposal = florence.proposal, m = florence.match
        let inAlbum = Set((0..<15).map { AssetID("f\($0)") })
        let inventory = CollectionInventory([CollectionSnapshot(id: "toskana", title: "Toskana", assetIDs: inAlbum)])
        #expect(Self.card(proposal, match: m, inventory: inventory).subtitle == "Kommt in dein Album „Toskana“ · +1 Foto")
        #expect(Self.card(proposal, match: m, inventory: inventory, words: .english).subtitle == "Goes into your album “Toskana” · +1 photo")
    }

    /// Photos taken out of the suggestion do not go into the album.
    @Test func removedPhotosAreNotAdded() {
        let florence = Self.florence()
        let proposal = florence.proposal, m = florence.match, inventory = florence.inventory
        let card = Self.card(proposal, match: m, inventory: inventory, removed: ["f10", "f11", "f0"])
        #expect(card.action == .add(albumName: "Toskana", newPhotos: 10))
        #expect(card.photoCount == 13)
    }

    /// The album list does not have the album (limited access, an iCloud sync): the match's name
    /// and numbers.
    @Test func anAlbumOutOfReachIsNamedFromTheMatch() {
        let florence = Self.florence()
        let proposal = florence.proposal, m = florence.match
        let card = Self.card(proposal, match: m)
        #expect(card.action == .add(albumName: "Toskana", newPhotos: 12))
    }

    /// The user picked the album under "Anpassen" for a suggestion Albumist would have made a new album of.
    @Test func theUsersChoiceOfAnAlbumIsWhatTheCardSays() {
        let florence = Self.florence()
        let proposal = florence.proposal, inventory = florence.inventory
        let possible = Self.match(proposal, .possibleMatch, best: Self.candidate("toskana", "Toskana", proposal: 16, albumCount: 34, shared: 4))
        #expect(Self.card(proposal, match: possible, inventory: inventory).action == .look)
        let chosen = Self.card(proposal, decision: .extendExisting("toskana"), match: possible, inventory: inventory)
        #expect(chosen.action == .add(albumName: "Toskana", newPhotos: 12))
        #expect(chosen.subtitle == "Kommt in dein Album „Toskana“ · +12 Fotos")
    }

    // MARK: Nothing to do

    @Test func anAlbumThatHoldsEverythingSaysSo() {
        let proposal = AlbumProposal(id: AlbumistID("island"), kind: .trip, title: "Island, Juli 2023", folderPath: ["Reisen"],
                                     assetIDs: Self.ids("i", 20), reliability: .certain)
        let inventory = CollectionInventory([CollectionSnapshot(id: "island", title: "Island", assetIDs: Self.ids("i", 20))])
        let m = Self.match(proposal, .alreadyComplete,
                           best: Self.candidate("island", "Island", proposal: 20, albumCount: 20, shared: 20, relation: .equivalent))
        let card = Self.card(proposal, match: m, inventory: inventory)
        #expect(card.subtitle == "Schon in deinem Album „Island“")
        #expect(card.action == .look)
        #expect(!card.needsLook)
        #expect(Self.card(proposal, match: m, inventory: inventory, words: .english).subtitle == "Already in your album “Island”")
        // "Ergänzen" with nothing missing changes nothing either.
        let extended = Self.card(proposal, decision: .extendExisting("island"), match: m, inventory: inventory)
        #expect(extended.status == .alreadyIn(album: "Island"))
    }
}
