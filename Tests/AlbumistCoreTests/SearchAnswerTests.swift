import Testing
@testable import AlbumistCore

/// When the search page searches (design wave 3, H14; review T3 of H14's round 2): its task
/// starts again each time the search tab comes back, and ran the whole search again for the text
/// on the page (a sentence went to Apple Intelligence a second time, "Verstanden als" went away
/// and came back, the pages of hits shown fell back to the first). Now the finished answer for
/// the same text and the same facts stays; a search that did not finish, new facts or a new text
/// search again, and only a new text starts the hits from the first page.
@Suite("Search: coming back to the tab does not search again")
struct SearchAnswerTests {
    /// The page's task starts for `text`: true when it searches.
    private static func starts(_ answer: inout SearchAnswer, _ text: String, facts: Int) -> Bool {
        answer.starts(text, facts: facts)
    }

    /// The answer for `text` is on the page: true when its hits start from the first page.
    private static func shows(_ answer: inout SearchAnswer, _ text: String, facts: Int) -> Bool {
        answer.shows(text, facts: facts)
    }

    /// The search for `text` runs to its end with the facts at revision `facts`.
    private static func answered(_ answer: inout SearchAnswer, _ text: String, facts: Int) {
        _ = answer.starts(text, facts: facts)
        _ = answer.shows(text, facts: facts)
    }

    @Test func backOnTheTabTheFinishedAnswerStays() {
        var answer = SearchAnswer()
        #expect(Self.starts(&answer, "Hunde Italien 2023", facts: 7))
        #expect(answer.searching)
        // The first answer for a text: its hits from the first page.
        #expect(Self.shows(&answer, "Hunde Italien 2023", facts: 7))
        #expect(!answer.searching)
        #expect(answer.text == "Hunde Italien 2023")
        // "Alben", then the search tab again: the task starts again for the same text.
        #expect(!Self.starts(&answer, "Hunde Italien 2023", facts: 7))
        #expect(!answer.searching)
        #expect(answer.text == "Hunde Italien 2023")
    }

    /// Another tab chosen before the answer came: its task was cancelled, so coming back searches.
    @Test func aSearchLeftBeforeItFinishedRunsAgain() {
        var answer = SearchAnswer()
        #expect(Self.starts(&answer, "Italien", facts: 1))
        #expect(Self.starts(&answer, "Italien", facts: 1))
        #expect(Self.shows(&answer, "Italien", facts: 1))
        #expect(!Self.starts(&answer, "Italien", facts: 1))
    }

    /// "Hunde" started and was cut off by deleting its "e": the page holds the answer for "Hund"
    /// but the completions of "Hunde", so "Hund" searches again, and keeps the pages shown.
    @Test func typedBackToTheShownTextWhileANewerSearchRanSearchesAgain() {
        var answer = SearchAnswer()
        Self.answered(&answer, "Hund", facts: 1)
        #expect(Self.starts(&answer, "Hunde", facts: 1))
        #expect(Self.starts(&answer, "Hund", facts: 1))
        #expect(!Self.shows(&answer, "Hund", facts: 1))
        #expect(!answer.searching)
    }

    /// The analysis found more while another tab was looked at: the same text searches again
    /// with the new facts and keeps the pages shown, so the place in the hits stays.
    @Test func newFactsSearchAgainAndKeepThePagesShown() {
        var answer = SearchAnswer()
        Self.answered(&answer, "2023", facts: 3)
        #expect(Self.starts(&answer, "2023", facts: 4))
        #expect(!Self.shows(&answer, "2023", facts: 4))
        #expect(!Self.starts(&answer, "2023", facts: 4))
    }

    @Test func aNewTextStartsFromTheFirstPage() {
        var answer = SearchAnswer()
        Self.answered(&answer, "2023", facts: 3)
        #expect(Self.starts(&answer, "2024", facts: 3))
        #expect(Self.shows(&answer, "2024", facts: 3))
        #expect(answer.text == "2024")
    }

    /// An empty field forgets the answer: the same text typed again searches anew.
    @Test func anEmptyFieldForgetsTheAnswer() {
        var answer = SearchAnswer()
        Self.answered(&answer, "Rom", facts: 2)
        answer.emptied()
        #expect(answer.text.isEmpty)
        #expect(!answer.searching)
        #expect(Self.starts(&answer, "Rom", facts: 2))
        #expect(Self.shows(&answer, "Rom", facts: 2))
    }
}
