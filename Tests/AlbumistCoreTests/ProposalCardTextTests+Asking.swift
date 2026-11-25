import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Cards that ask for a name or a look, folders, the language and the catalog's words (`ProposalCardTextTests`).
extension ProposalCardTextTests {
    // MARK: A place without a name ("Benennen …")

    static func lindau() -> AlbumProposal {
        AlbumProposal(id: AlbumistID("place-lindau"), kind: .frequentPlace, title: "Häufiger Ort in Lindau", folderPath: ["Orte"],
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
        AlbumProposal(id: AlbumistID("document-contract"), kind: .documentCategory("contract"), title: "Verträge", folderPath: ["Dokumente"],
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

    /// What VoiceOver says after a card's name (`PhotoCard` reads "name, status"): the status
    /// line in words, "Persönlicher Inhalt" without the name of the lock drawn before it, and
    /// "Vorschau ausgeblendet", which only the cover shows (review B of design wave 1, 5).
    @Test func theStatusIsSpokenInWords() {
        let personal = Self.card(Self.contracts(), hidesPreview: true)
        #expect(personal.spokenStatus == "9 Fotos, Persönlicher Inhalt, Vorschau ausgeblendet")
        #expect(personal.accessibilityLabel == "Verträge, " + personal.spokenStatus)
        let english = Self.card(Self.contracts(), hidesPreview: true, words: .english)
        #expect(english.spokenStatus == "9 photos, Personal content, Preview hidden")
        let trip = Self.card(Self.trip())
        #expect(trip.spokenStatus == "16 Fotos, Neues Album")
        #expect(trip.accessibilityLabel == "Kyoto, Oktober 2024, " + trip.spokenStatus)
    }

    /// Every photo a sensitive document, though the suggestion is not marked personal (a
    /// screenshot category of bank cards): personal too.
    @Test func aHiddenPreviewIsPersonal() {
        let proposal = AlbumProposal(id: AlbumistID("screens"), kind: .screenshotCategory("banking"), title: "Banking",
                                     folderPath: ["Screenshots"], assetIDs: Self.ids("s", 5), reliability: .likely)
        let card = Self.card(proposal, hidesPreview: true)
        #expect(card.action == .look)
        #expect(card.status == .personal)
    }

    // MARK: Albumist is unsure ("Bitte kurz ansehen")

    @Test(arguments: [(Reliability.plausible, "Möglich", "Possible"), (.uncertain, "Unsicher", "Uncertain")])
    func anUnsureSuggestionSaysHowSureAndAsksForALook(_ reliability: Reliability, _ german: String, _ english: String) {
        let proposal = AlbumProposal(id: AlbumistID("beach"), kind: .imageCategory("beach"), title: "Strand", folderPath: ["Themen"],
                                     assetIDs: Self.ids("b", 16), reliability: reliability)
        let card = Self.card(proposal)
        #expect(card.subtitle == "16 Fotos · \(german) · Bitte kurz ansehen")
        #expect(card.action == .look)
        #expect(card.needsLook)
        #expect(card.status == .pleaseLook(reliability))
        #expect(Self.card(proposal, words: .english).subtitle == "16 photos · \(english) · Please take a look")
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
        let florence = Self.florence()
        let proposal = florence.proposal, inventory = florence.inventory
        let m = Self.match(proposal, .possibleMatch, best: Self.candidate("toskana", "Toskana", proposal: 16, albumCount: 34, shared: 4))
        let card = Self.card(proposal, match: m, inventory: inventory)
        #expect(card.subtitle == "16 Fotos · Bitte kurz ansehen")
        #expect(card.action == .look)
        #expect(card.needsLook)
        #expect(card.status == .pleaseLook(nil))
        #expect(card.title == "Florenz, Mai 2023")
    }

    @Test func severalAlbumsLetTheUserChoose() {
        let florence = Self.florence()
        let proposal = florence.proposal, inventory = florence.inventory
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
                      words.severalAlbums, words.notInPhotosYet, words.notAddedYet, words.alreadyInPhotos, words.noDate,
                      words.renames(album: "A"), words.renames(album: ""), words.moves(album: "A"), words.moves(album: ""),
                      words.renamed(album: "A", to: "B"), words.renamed(album: "", to: "B"), words.moved(album: "A", to: ["B"]),
                      words.moved(album: "A", to: []), words.moved(album: "", to: ["B"]), words.notChangedYet]
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
