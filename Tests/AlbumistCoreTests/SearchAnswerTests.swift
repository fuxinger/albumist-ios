import Testing
@testable import AlbumistCore

/// When the search page searches (design wave 3, H14; reviews T3 and Q1 of H14's rounds 2 and 3):
/// its task starts again each time the search tab comes back, and ran the whole search again for
/// the text on the page (a sentence went to Apple Intelligence a second time, "Verstanden als"
/// went away and came back, the pages of hits shown fell back to the first). Now the finished
/// answer for the same text and the same revision of what a search reads stays; a search that did
/// not finish, a change of anything a search reads (`AppModel.searchRevision`: the facts, an
/// ignored photo, an album, a place's name, the home, the part of the library, the day) or a new
/// text search again as the tab is chosen again, and only a new text starts the hits from the
/// first page.
@Suite("Search: coming back to the tab searches again only after a change")
struct SearchAnswerTests {
    /// The page's task starts for `text`: true when it searches.
    private static func starts(_ answer: inout SearchAnswer, _ text: String, revision: Int) -> Bool {
        answer.starts(text, revision: revision)
    }

    /// The answer for `text` is on the page: true when its hits start from the first page.
    private static func shows(_ answer: inout SearchAnswer, _ text: String, revision: Int) -> Bool {
        answer.shows(text, revision: revision)
    }

    /// The search for `text` runs to its end with what a search reads at revision `revision`.
    private static func answered(_ answer: inout SearchAnswer, _ text: String, revision: Int) {
        _ = answer.starts(text, revision: revision)
        _ = answer.shows(text, revision: revision)
    }

    @Test func backOnTheTabTheFinishedAnswerStays() {
        var answer = SearchAnswer()
        #expect(Self.starts(&answer, "Hunde Italien 2023", revision: 7))
        #expect(answer.searching)
        // The first answer for a text: its hits from the first page.
        #expect(Self.shows(&answer, "Hunde Italien 2023", revision: 7))
        #expect(!answer.searching)
        #expect(answer.text == "Hunde Italien 2023")
        // "Alben", then the search tab again: the task starts again for the same text.
        #expect(!Self.starts(&answer, "Hunde Italien 2023", revision: 7))
        #expect(!answer.searching)
        #expect(answer.text == "Hunde Italien 2023")
    }

    /// Nothing a search reads changed since the answer (review Q1 of H14's round 3): however often
    /// the tab is chosen again, nothing is searched (no second question to Apple Intelligence,
    /// "Verstanden als" and the pages shown stay). A new revision searches once, and its answer
    /// stays in turn.
    @Test func theSameRevisionKeepsTheAnswer() {
        var answer = SearchAnswer()
        Self.answered(&answer, "Grillen bei Oma letzten Sommer", revision: 9)
        for _ in 0..<3 {
            #expect(!Self.starts(&answer, "Grillen bei Oma letzten Sommer", revision: 9))
            #expect(!answer.searching)
            #expect(answer.text == "Grillen bei Oma letzten Sommer")
        }
        #expect(Self.starts(&answer, "Grillen bei Oma letzten Sommer", revision: 12))
        #expect(!Self.shows(&answer, "Grillen bei Oma letzten Sommer", revision: 12))
        #expect(!Self.starts(&answer, "Grillen bei Oma letzten Sommer", revision: 12))
    }

    /// The review's case (Q1): "Unsortiert" found 412 photos; in the tab "Unsortiert" the user
    /// ignores 30 screenshots, which raises the revision (the photos' states are read by a search
    /// for "Unsortiert"). Back on the search tab it searches again, so its count and "Als Album
    /// anlegen" no longer take the ignored ones, and keeps the pages shown. Before, only new facts
    /// counted, and the 412 stayed until the text changed.
    @Test func anIgnoredPhotoIsANewRevisionAndSearchesAgain() {
        var answer = SearchAnswer()
        Self.answered(&answer, "Unsortiert", revision: 40)
        // Thirty taps on "Ignorieren", each one a new revision.
        let ignored = 40 + 30
        #expect(Self.starts(&answer, "Unsortiert", revision: ignored))
        #expect(answer.searching)
        #expect(!Self.shows(&answer, "Unsortiert", revision: ignored))
        #expect(!Self.starts(&answer, "Unsortiert", revision: ignored))
    }

    /// Another tab chosen before the answer came: its task was cancelled, so coming back searches.
    @Test func aSearchLeftBeforeItFinishedRunsAgain() {
        var answer = SearchAnswer()
        #expect(Self.starts(&answer, "Italien", revision: 1))
        #expect(Self.starts(&answer, "Italien", revision: 1))
        #expect(Self.shows(&answer, "Italien", revision: 1))
        #expect(!Self.starts(&answer, "Italien", revision: 1))
    }

    /// "Hunde" started and was cut off by deleting its "e": the page holds the answer for "Hund"
    /// but the completions of "Hunde", so "Hund" searches again, and keeps the pages shown.
    @Test func typedBackToTheShownTextWhileANewerSearchRanSearchesAgain() {
        var answer = SearchAnswer()
        Self.answered(&answer, "Hund", revision: 1)
        #expect(Self.starts(&answer, "Hunde", revision: 1))
        #expect(Self.starts(&answer, "Hund", revision: 1))
        #expect(!Self.shows(&answer, "Hund", revision: 1))
        #expect(!answer.searching)
    }

    /// The analysis found more while another tab was looked at: the same text searches again
    /// with the new facts and keeps the pages shown, so the place in the hits stays.
    @Test func newFactsSearchAgainAndKeepThePagesShown() {
        var answer = SearchAnswer()
        Self.answered(&answer, "2023", revision: 3)
        #expect(Self.starts(&answer, "2023", revision: 4))
        #expect(!Self.shows(&answer, "2023", revision: 4))
        #expect(!Self.starts(&answer, "2023", revision: 4))
    }

    @Test func aNewTextStartsFromTheFirstPage() {
        var answer = SearchAnswer()
        Self.answered(&answer, "2023", revision: 3)
        #expect(Self.starts(&answer, "2024", revision: 3))
        #expect(Self.shows(&answer, "2024", revision: 3))
        #expect(answer.text == "2024")
    }

    /// An empty field forgets the answer: the same text typed again searches anew.
    @Test func anEmptyFieldForgetsTheAnswer() {
        var answer = SearchAnswer()
        Self.answered(&answer, "Rom", revision: 2)
        answer.emptied()
        #expect(answer.text.isEmpty)
        #expect(!answer.searching)
        #expect(Self.starts(&answer, "Rom", revision: 2))
        #expect(Self.shows(&answer, "Rom", revision: 2))
    }
}
