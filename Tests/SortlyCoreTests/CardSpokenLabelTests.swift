import Testing
import SortlyTestSupport

/// A suggestion's card says its button the same way on the start page and in the list:
/// „Toskana“ ergänzen names the album that gets the photos (the start page named the card's
/// title instead). A ticked card says so on its body, where VoiceOver starts, not only on the
/// tick (handoff of the suggestion screens, round 2, 20.11.).
@Suite("Suggestion cards speak alike")
struct CardSpokenLabelTests {
    @Test func theStartPageUsesTheListsWords() throws {
        let start = AppSource.code(try AppSource.read("App/Sortly/Views/Start/StartSections.swift"), keepStrings: true)
        // While its album is made or its preview prepared, the list's words for that
        // ("Album wird angelegt", "Wird vorbereitet"; review A of design wave 1, 7).
        #expect(start.contains(".accessibilityLabel(working ? workingLabel : text.spokenAction)"))
        #expect(start.contains(".accessibilityInputLabels(text.actionInputLabels)"))
        #expect(start.contains(".accessibilityLabel(text.spokenMade)"))
        #expect(!start.contains("“ ergänzen\")"), "a second wording of the card's button")
    }

    @Test func aTickedCardSaysSoOnItsBody() throws {
        let card = AppSource.code(try AppSource.read("App/Sortly/DesignSystem/PhotoCard.swift"))
        #expect(card.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        let list = AppSource.code(try AppSource.read("App/Sortly/Views/ProposalViews.swift"))
        #expect(list.contains(".selected(selecting && isSelected)"))
    }
}
