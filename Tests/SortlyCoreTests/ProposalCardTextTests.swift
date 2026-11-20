import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

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
        AlbumProposal(id: SortlyID("trip-kyoto"), kind: .trip, title: title, folderPath: folder,
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
    static func florence() -> (AlbumProposal, MatchResult, CollectionInventory) {
        let proposal = AlbumProposal(id: SortlyID("trip-florenz"), kind: .trip, title: "Florenz, Mai 2023", folderPath: ["Reisen"],
                                     assetIDs: ids("f", 16), reliability: .certain)
        let inAlbum = Set((0..<4).map { AssetID("f\($0)") }).union(ids("other", 30))
        let album = CollectionSnapshot(id: "toskana", title: "Toskana", assetIDs: inAlbum)
        let m = match(proposal, .extendable, best: candidate("toskana", "Toskana", proposal: 16, albumCount: 34, shared: 4))
        return (proposal, m, CollectionInventory([album]))
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
    func countsAreSingularPluralAndGrouped(_ example: (count: Int, german: String, english: String)) {
        #expect(Self.card(Self.trip(example.count)).subtitle == example.german)
        #expect(Self.card(Self.trip(example.count), words: .english).subtitle == example.english)
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
        let (proposal, _, _) = Self.florence()
        let m = Self.match(proposal, .extendable, best: Self.candidate("long", album, proposal: 16, albumCount: 20, shared: 4))
        let inventory = CollectionInventory([CollectionSnapshot(id: "long", title: album, assetIDs: Set((0..<4).map { AssetID("f\($0)") }))])
        #expect(Self.card(proposal, match: m, inventory: inventory).subtitle == "Kommt in dein Album „\(album)“ · +12 Fotos")
    }

    // MARK: The user's own album ("Ergänzen …")

    @Test func addingToTheUsersAlbumNamesItAndTheNewPhotos() {
        let (proposal, m, inventory) = Self.florence()
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
        let (proposal, m, _) = Self.florence()
        let inAlbum = Set((0..<15).map { AssetID("f\($0)") })
        let inventory = CollectionInventory([CollectionSnapshot(id: "toskana", title: "Toskana", assetIDs: inAlbum)])
        #expect(Self.card(proposal, match: m, inventory: inventory).subtitle == "Kommt in dein Album „Toskana“ · +1 Foto")
        #expect(Self.card(proposal, match: m, inventory: inventory, words: .english).subtitle == "Goes into your album “Toskana” · +1 photo")
    }

    /// Photos taken out of the suggestion do not go into the album.
    @Test func removedPhotosAreNotAdded() {
        let (proposal, m, inventory) = Self.florence()
        let card = Self.card(proposal, match: m, inventory: inventory, removed: ["f10", "f11", "f0"])
        #expect(card.action == .add(albumName: "Toskana", newPhotos: 10))
        #expect(card.photoCount == 13)
    }

    /// The album list does not have the album (limited access, an iCloud sync): the match's name
    /// and numbers.
    @Test func anAlbumOutOfReachIsNamedFromTheMatch() {
        let (proposal, m, _) = Self.florence()
        let card = Self.card(proposal, match: m)
        #expect(card.action == .add(albumName: "Toskana", newPhotos: 12))
    }

    /// The user picked the album under "Anpassen" for a suggestion Albumist would have made a new album of.
    @Test func theUsersChoiceOfAnAlbumIsWhatTheCardSays() {
        let (proposal, _, inventory) = Self.florence()
        let possible = Self.match(proposal, .possibleMatch, best: Self.candidate("toskana", "Toskana", proposal: 16, albumCount: 34, shared: 4))
        #expect(Self.card(proposal, match: possible, inventory: inventory).action == .look)
        let chosen = Self.card(proposal, decision: .extendExisting("toskana"), match: possible, inventory: inventory)
        #expect(chosen.action == .add(albumName: "Toskana", newPhotos: 12))
        #expect(chosen.subtitle == "Kommt in dein Album „Toskana“ · +12 Fotos")
    }

    // MARK: Nothing to do

    @Test func anAlbumThatHoldsEverythingSaysSo() {
        let proposal = AlbumProposal(id: SortlyID("island"), kind: .trip, title: "Island, Juli 2023", folderPath: ["Reisen"],
                                     assetIDs: Self.ids("i", 20), reliability: .certain)
        let inventory = CollectionInventory([CollectionSnapshot(id: "island", title: "Island", assetIDs: Self.ids("i", 20))])
        let m = Self.match(proposal, .alreadyComplete, best: Self.candidate("island", "Island", proposal: 20, albumCount: 20, shared: 20, relation: .equivalent))
        let card = Self.card(proposal, match: m, inventory: inventory)
        #expect(card.subtitle == "Schon in deinem Album „Island“")
        #expect(card.action == .look)
        #expect(!card.needsLook)
        #expect(Self.card(proposal, match: m, inventory: inventory, words: .english).subtitle == "Already in your album “Island”")
        // "Ergänzen" with nothing missing changes nothing either.
        let extended = Self.card(proposal, decision: .extendExisting("island"), match: m, inventory: inventory)
        #expect(extended.status == .alreadyIn(album: "Island"))
    }

    // MARK: A place without a name ("Benennen …")

    static func lindau() -> AlbumProposal {
        AlbumProposal(id: SortlyID("place-lindau"), kind: .frequentPlace, title: "Häufiger Ort in Lindau", folderPath: ["Orte"],
                      assetIDs: ids("l", 38), reliability: .likely, isSensitive: true, requiresUserName: true)
    }

    @Test func aPlaceWithoutANameAsksForOne() {
        let card = Self.card(Self.lindau())
        #expect(card.title == "Häufiger Ort in Lindau")
        #expect(card.subtitle == "Name fehlt · 38 Fotos")
        #expect(card.subtitleParts.first == "Name fehlt")
        #expect(card.action == .name)
        #expect(card.status == .nameMissing)
        #expect(!card.needsLook)
        #expect(card.outcome == .needsName(folderPath: ["Orte"]))
        #expect(Self.card(Self.lindau(), words: .english).subtitle == "Name missing · 38 photos")
        // A blank name is no name.
        #expect(Self.card(Self.lindau(), userTitle: "   ").action == .name)
    }

    /// Named, the place is a new album with the user's name; it is personal, so it is looked at.
    @Test func aNamedPlaceIsPersonal() {
        let card = Self.card(Self.lindau(), userTitle: "Bei Oma")
        #expect(card.title == "Bei Oma")
        #expect(card.subtitle == "38 Fotos · Persönlicher Inhalt")
        #expect(card.action == .look)
        #expect(card.isPersonal)
        #expect(card.outcome == .newAlbum(title: "Bei Oma", folderPath: ["Orte"]))
    }

    // MARK: Personal content ("Ansehen …")

    static func contracts() -> AlbumProposal {
        AlbumProposal(id: SortlyID("document-contract"), kind: .documentCategory("contract"), title: "Verträge", folderPath: ["Dokumente"],
                      assetIDs: ids("d", 9), reliability: .plausible, isSensitive: true)
    }

    /// E6: "Verträge", "9 Fotos", the lock with "Persönlicher Inhalt", "Ansehen …"; no
    /// "Möglich": the personal content is the reason to look.
    @Test func personalContentIsLookedAtWithItsPreviewHidden() {
        let card = Self.card(Self.contracts(), hidesPreview: true)
        #expect(card.title == "Verträge")
        #expect(card.subtitle == "9 Fotos · Persönlicher Inhalt")
        #expect(card.action == .look)
        #expect(card.status == .personal)
        #expect(!card.needsLook)
        #expect(card.isPersonal && card.hidesPreview)
        #expect(card.accessibilityLabel == "Verträge, 9 Fotos, Persönlicher Inhalt, Vorschau ausgeblendet")
        let english = Self.card(Self.contracts(), hidesPreview: true, words: .english)
        #expect(english.subtitle == "9 photos · Personal content")
        #expect(english.accessibilityLabel == "Verträge, 9 photos, Personal content, Preview hidden")
    }

    /// Every photo a sensitive document, though the suggestion is not marked personal (a
    /// screenshot category of bank cards): personal too.
    @Test func aHiddenPreviewIsPersonal() {
        let proposal = AlbumProposal(id: SortlyID("screens"), kind: .screenshotCategory("banking"), title: "Banking",
                                     folderPath: ["Screenshots"], assetIDs: Self.ids("s", 5), reliability: .likely)
        let card = Self.card(proposal, hidesPreview: true)
        #expect(card.action == .look)
        #expect(card.status == .personal)
    }

    // MARK: Albumist is unsure ("Bitte kurz ansehen")

    @Test(arguments: [(Reliability.plausible, "Möglich", "Possible"), (.uncertain, "Unsicher", "Uncertain")])
    func anUnsureSuggestionSaysHowSureAndAsksForALook(_ example: (reliability: Reliability, german: String, english: String)) {
        let proposal = AlbumProposal(id: SortlyID("beach"), kind: .imageCategory("beach"), title: "Strand", folderPath: ["Themen"],
                                     assetIDs: Self.ids("b", 16), reliability: example.reliability)
        let card = Self.card(proposal)
        #expect(card.subtitle == "16 Fotos · \(example.german) · Bitte kurz ansehen")
        #expect(card.action == .look)
        #expect(card.needsLook)
        #expect(card.status == .pleaseLook(example.reliability))
        #expect(Self.card(proposal, words: .english).subtitle == "16 photos · \(example.english) · Please take a look")
        // Created by the user's choice in the suggestion: no second look.
        let chosen = Self.card(proposal, decision: .createNew(title: nil, folderPath: nil))
        #expect(chosen.subtitle == "16 Fotos · Neues Album")
        #expect(chosen.action == .create)
    }

    /// "Sicher" and "Wahrscheinlich" are never said: only when the user should check (Punkt 3).
    @Test func sureSuggestionsDoNotSayHowSure() {
        for reliability in [Reliability.certain, .likely] {
            let card = Self.card(Self.trip(reliability: reliability))
            #expect(!card.needsLook)
            for word in ["Sicher", "Wahrscheinlich", "Möglich", "Unsicher", "Bitte"] {
                #expect(!(card.subtitle ?? "").contains(word))
            }
        }
    }

    /// A similar album of the user only possibly fits: Albumist would make a new album and leave
    /// it alone; the user looks first (review 16.11., as for the starter set).
    @Test func aPossibleMatchAsksForALook() {
        let (proposal, _, inventory) = Self.florence()
        let m = Self.match(proposal, .possibleMatch, best: Self.candidate("toskana", "Toskana", proposal: 16, albumCount: 34, shared: 4))
        let card = Self.card(proposal, match: m, inventory: inventory)
        #expect(card.subtitle == "16 Fotos · Bitte kurz ansehen")
        #expect(card.action == .look)
        #expect(card.needsLook)
        #expect(card.status == .pleaseLook(nil))
        #expect(card.title == "Florenz, Mai 2023")
    }

    @Test func severalAlbumsLetTheUserChoose() {
        let (proposal, _, inventory) = Self.florence()
        let m = Self.match(proposal, .multipleMatches,
                           best: Self.candidate("toskana", "Toskana", proposal: 16, albumCount: 34, shared: 4),
                           alternatives: [Self.candidate("italien", "Italien", proposal: 16, albumCount: 40, shared: 4)])
        let card = Self.card(proposal, match: m, inventory: inventory)
        #expect(card.outcome == .chooseAlbum)
        #expect(card.subtitle == "16 Fotos · Bitte kurz ansehen")
        #expect(card.action == .look)
        #expect(card.needsLook)
    }

    /// "Nicht jetzt" puts a suggestion aside; its card still says what creating it would do.
    @Test func aSuggestionPutAsideShowsWhatItWouldDo() {
        let card = Self.card(Self.trip(), decision: .reject)
        #expect(card.subtitle == "16 Fotos · Neues Album")
        #expect(card.action == .create)
    }

    // MARK: Folders

    @Test func theNewAlbumGoesIntoTheRootFolderAndItsArea() {
        #expect(Self.card(Self.trip()).outcome == .newAlbum(title: "Kyoto, Oktober 2024", folderPath: ["Reisen"]))
        #expect(Self.card(Self.trip(), root: " Albumist ").outcome == .newAlbum(title: "Kyoto, Oktober 2024", folderPath: ["Albumist", "Reisen"]))
        #expect(Self.card(Self.trip(), decision: .createNew(title: nil, folderPath: ["Japan"])).outcome
                == .newAlbum(title: "Kyoto, Oktober 2024", folderPath: ["Japan"]))
    }

    // MARK: The language

    @Test func theAppsLocalizationPicksTheLanguage() {
        #expect(ProposalWords(localization: "de").language == .german)
        #expect(ProposalWords(localization: "de-AT").language == .german)
        #expect(ProposalWords(localization: nil).language == .german)
        #expect(ProposalWords(localization: "en").language == .english)
        #expect(ProposalWords(localization: "en-GB").language == .english)
        #expect(ProposalWords(localization: "fr").language == .english)
        #expect(ProposalWords(localization: "de", region: "").locale.identifier == "de_DE")
        #expect(ProposalWords(localization: "en", region: "GB").locale.identifier == "en_GB")
        #expect(ProposalWords(localization: "de-AT", region: "AT").locale.identifier == "de_AT")
    }

    // MARK: The catalog's words

    /// Pairs of the core's German and English word for catalog keys that the app shows too.
    static func catalogPairs() -> [(german: String, english: String)] {
        let de = ProposalWords.german, en = ProposalWords.english
        var pairs = [(de.newAlbum, en.newAlbum), (de.nameMissing, en.nameMissing), (de.previewHidden, en.previewHidden),
                     (de.noDate, en.noDate), (de.personal, en.personal), (de.pleaseLook, en.pleaseLook)]
        for reliability in Reliability.allCases {
            pairs.append((de.reliability(reliability), en.reliability(reliability)))
        }
        return pairs
    }

    /// The words the catalog has too are the catalog's in both languages, so a card says what
    /// the rest of the app says ("Neues Album" / "New album").
    @Test func wordsAreTheCatalogs() throws {
        let catalog = try StringCatalogTests.catalog()
        let required: Set<String> = ["Neues Album", "Name fehlt", "Vorschau ausgeblendet", "Ohne Datum",
                                     "Sicher", "Wahrscheinlich", "Möglich", "Unsicher"]
        for (german, english) in Self.catalogPairs() {
            guard let entry = catalog[german] else {
                #expect(!required.contains(german), "\(german) is not in the catalog")
                continue
            }
            let value = (StringCatalogTests.localization(entry, "en")?["stringUnit"] as? [String: Any])?["value"] as? String
            #expect(value == english, "\(german): the catalog says \(value ?? "nothing"), the card \(english)")
        }
    }

    /// The counts read like the catalog's plural forms of "%lld %@ Fotos" and "+%lld %@ Fotos".
    @Test func countsAreTheCatalogsPluralForms() throws {
        let catalog = try StringCatalogTests.catalog()
        func form(_ key: String, _ language: String, _ n: Int, shown: String) throws -> String {
            let entry = try #require(catalog[key], "\(key) is missing")
            let subs = try #require(StringCatalogTests.localization(entry, language)?["substitutions"] as? [String: [String: Any]])
            let plural = try #require((subs.values.first?["variations"] as? [String: Any])?["plural"] as? [String: Any])
            let unit = try #require((plural[n == 1 ? "one" : "other"] as? [String: Any])?["stringUnit"] as? [String: Any])
            return try #require(unit["value"] as? String).replacingOccurrences(of: "%2$@", with: shown)
        }
        for words in [ProposalWords.german, .english] {
            let language = words.language.rawValue
            for n in [0, 1, 2, 16, 999, 1_000, 1_354, 120_000] {
                #expect(words.photos(n) == (try form("%lld %@ Fotos", language, n, shown: words.number(n))))
                #expect(words.addedPhotos(n) == (try form("+%lld %@ Fotos", language, n, shown: words.number(n))))
            }
        }
    }

    /// The words that went away (CatalogWordingTests) do not come back through the core either.
    @Test func noWordThatIsGone() {
        var texts: [String] = []
        for words in [ProposalWords.german, .english] {
            texts += [words.newAlbum, words.nameMissing, words.personal, words.pleaseLook, words.previewHidden,
                      words.addsTo(album: "A"), words.alreadyIn(album: "A"), words.newAlbum(in: ["A"]), words.newAlbum(in: []),
                      words.severalAlbums, words.notInPhotosYet, words.notAddedYet, words.alreadyInPhotos, words.noDate]
        }
        for text in texts {
            for (pattern, instead) in CatalogWordingTests.forbiddenGerman + CatalogWordingTests.forbiddenEnglish
            where CatalogWordingTests.matches(text, pattern) {
                Issue.record("„\(text)“: \(instead)")
            }
            for word in ["Bilder", "Medien", "Mediathek", "Noch nicht sortiert", "Merken"] {
                #expect(!text.contains(word), "„\(text)“ says \(word)")
            }
        }
    }
}
