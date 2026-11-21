import Foundation
import Testing
import AlbumistTestSupport

/// What the open suggestion and the list's cards show and say (review B of design wave 1:
/// findings 5, 6, 7 and 12, and the note on a card's button while the list selects). The views
/// run only on a Mac; these guards read their code.
@Suite("Suggestion page and cards: what they show and say")
struct SuggestionPageWordsTests {
    static let views = "App/Albumist/Views/ProposalViews.swift"
    static let labels = "App/Albumist/Views/Proposal/ProposalCardLabels.swift"

    /// The body of the declarations `path` (outermost first) in `file`, without its comments,
    /// its strings as written.
    static func body(_ path: [String], in file: String) throws -> String {
        let source = try AppSource.read(file)
        let body = try #require(AppSource.body(of: path, in: source), "\(file): no \(path.joined(separator: " › "))")
        return AppSource.code(body, keepStrings: true)
    }

    /// Review B, 5: under a two-line name a card has one line for its status, so the line with
    /// the lock and "Persönlicher Inhalt" comes first and the count below it is what gets cut.
    /// VoiceOver hears the status in words (`ProposalCardText.spokenStatus`), never the lock's
    /// symbol, wherever the line is shown (the cards read "name, status").
    @Test func personalContentIsTheLineThatStays() throws {
        let subtitle = try Self.body(["var styledSubtitle: Text"], in: Self.labels)
        #expect(subtitle.contains(#"let count = Text(verbatim: "\n" + subtitleParts[0])"#), "the count is not on the line below")
        #expect(subtitle.contains(#"shown = Text("\(marked)\(count)")"#), "the lock line is not first")
        #expect(!subtitle.contains(#"Text(verbatim: subtitleParts[0] + "\n")"#), "the count still comes first")
        #expect(subtitle.contains("return shown.accessibilityLabel(Text(verbatim: spokenStatus))"),
                "VoiceOver reads the status line as drawn, with the lock's symbol")
    }

    /// Review B, 6: VoiceOver may read the page's bar before its header (the scroll view is a
    /// container of its own), so each button says what it acts on: its words with the album's
    /// name, as the cards' buttons do. Voice Control knows it by its words too; "Namen
    /// eingeben" names the field it acts on and keeps its words.
    @Test func theBarSaysWhatItActsOn() throws {
        let main = try Self.body(["private func primaryButton("], in: Self.views)
        #expect(main.contains("let named = card.spokenMainAction ?? Text(word)"))
        #expect(main.contains(".accessibilityLabel(spoken)"))
        #expect(main.contains(".accessibilityInputLabels([Text(word), named])"))
        let notNow = try Self.body(["private func notNowButton("], in: Self.views)
        #expect(notNow.contains(".accessibilityLabel(card.spokenNotNow)"))
        #expect(notNow.contains(#".accessibilityInputLabels([Text("Nicht jetzt"), card.spokenNotNow])"#))

        let words = try Self.body(["var spokenMainAction: Text?"], in: Self.labels)
        let named = [
            #"Text("Album für „\(title)“ auswählen")"#,
            #"Text("Album „\(name)“ anlegen")"#,
            #"Text("„\(name)“ um \(missing) \(missing.formatted()) Fotos ergänzen")"#,
            #"Text("Album „\(name)“ so lassen")"#,
            #"Text("Album „\(from)“ umbenennen")"#,
            #"Text("Album „\(name)“ verschieben")"#,
        ]
        for text in named {
            #expect(words.contains(text), "the main button does not say \(text)")
        }
        let squeezed = words.filter { !$0.isWhitespace }
        #expect(squeezed.contains("case.needsName:returnnil"), "\"Namen eingeben\" got other words")
        let notNowWords = try Self.body(["var spokenNotNow: Text"], in: Self.labels)
        #expect(notNowWords.contains(#"Text("Nicht jetzt: „\(title)“")"#))
    }

    /// The bar's spoken words are in the catalog with English, and "1 Foto" or "12 Fotos" by
    /// plural in both languages.
    @Test func theBarsWordsAreInTheCatalog() throws {
        let catalog = try StringCatalogTests.catalog()
        let keys = ["Album für „%@“ auswählen", "Album „%@“ anlegen", "„%@“ um %lld %@ Fotos ergänzen",
                    "Album „%@“ so lassen", "Album „%@“ umbenennen", "Album „%@“ verschieben", "Nicht jetzt: „%@“"]
        for key in keys {
            let entry = try #require(catalog[key], "\(key) is not in the catalog")
            #expect(StringCatalogTests.localization(entry, "en") != nil, "\(key) has no English")
        }
        let count = try #require(catalog["„%@“ um %lld %@ Fotos ergänzen"])
        for language in ["de", "en"] {
            let substitutions = StringCatalogTests.localization(count, language)?["substitutions"] as? [String: [String: Any]]
            #expect(StringCatalogTests.hasPluralForms(substitutions?["photos"]), "\(language): no plural for the count")
        }
    }

    /// Review B, 7: the button styles grow only with their words, not with the height the bar
    /// offers, so "Nicht jetzt" stayed one line high, at the top, beside "1.354 Fotos ergänzen"
    /// on two lines. Each word is measured and both get the taller one's height; both buttons
    /// sit centred on the bar.
    @Test func bothBarButtonsAreAsTallAsTheTaller() throws {
        let place = try Self.body(["struct ActionBarLayout", "func placeSubviews("], in: Self.views)
        #expect(place.components(separatedBy: "y: bounds.midY), anchor: .leading").count == 3, "the buttons are not centred on the bar")
        #expect(!place.contains(".topLeading"))
        let main = try Self.body(["private func primaryButton("], in: Self.views)
        let notNow = try Self.body(["private func notNowButton("], in: Self.views)
        #expect(main.contains("action: { barWords.main = $0 }"))
        #expect(notNow.contains("action: { barWords.notNow = $0 }"))
        for button in [main, notNow] {
            #expect(button.contains(".frame(minHeight: beside ? barWords.tallest : nil)"))
        }
        // Side by side only: stacked at the accessibility sizes, each keeps its own height.
        let bar = try Self.body(["private func actionBar("], in: Self.views)
        #expect(bar.contains("notNowButton(card, beside: true)") && bar.contains("primaryButton(card, beside: true)"))
        #expect(bar.contains("primaryButton(card, beside: false)") && bar.contains("notNowButton(card, beside: false)"))
    }

    /// Review B, 12: back from its own preview, the page closes only when that preview's plan
    /// ran, not when any plan ended meanwhile (one started on another tab).
    @Test func onlyItsOwnPreviewsRunClosesThePage() throws {
        let page = try Self.body(["struct ProposalDetailView", "var body: some View"], in: Self.views)
        #expect(!page.contains("if showsDirect && finished != nil { applied = true }"))
        #expect(page.contains("if showsDirect, let finished, finished.id == directPlan?.plan.id { applied = true }"))
    }

    /// While the list selects, a tap ticks the card and its button is hidden; it is disabled
    /// too, so nothing reaches it (review B, smaller notes).
    @Test func aCardsButtonWaitsWhileTheListSelects() throws {
        let card = try Self.body(["private struct ProposalListCard", "private var cardAction: some View"], in: Self.views)
        #expect(card.contains(".accessibilityHidden(selecting)"))
        #expect(card.contains(".disabled(selecting)"))
    }
}
