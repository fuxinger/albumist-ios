import Foundation

/// When the search page searches (design wave 3, H14; review T3 of H14's round 2). A view's
/// `.task` ends when the view goes and starts again when it comes back, and a tab's page goes
/// when another tab is chosen: each return to the search tab ran the whole search again for the
/// text on the page. A sentence went to Apple Intelligence a second time, the line "Verstanden
/// als" went away and came back, and the pages of hits shown fell back to the first, under the
/// place the user had scrolled to. Now the page asks this record first:
/// - the finished answer on the page was made for this text from these facts: nothing is
///   searched, the hits and the pages shown stay;
/// - a search that did not finish (another tab was chosen, the text changed meanwhile), new
///   facts or a new text: searched again; only a new text shows the hits from the first page.
/// The facts are the photos' facts at their revision (`AppModel.factsVersion`: places, contents,
/// texts and albums of every photo). A renamed album, a place's name typed, the home and the
/// sorting state have no counter of their own and come with the next text.
public struct SearchAnswer: Sendable, Equatable {
    /// The text the answer on the page was made for; empty while the field is empty and before
    /// the first answer.
    public private(set) var text = ""
    /// A search runs, or was left before it finished: the page does not show the finished
    /// answer for the text in the field.
    public private(set) var searching = false
    /// The revision of the facts the answer on the page was made from.
    private var facts: Int?

    public init() {}

    /// The page's task starts for `text` (not empty) with the facts at revision `facts`. True:
    /// search; false: the page shows the finished answer for both, and nothing is asked again.
    public mutating func starts(_ text: String, facts: Int) -> Bool {
        guard searching || text != self.text || facts != self.facts else { return false }
        searching = true
        return true
    }

    /// The answer for `text`, searched with the facts at revision `facts`, is on the page. True
    /// when it belongs to another text than the answer before: its hits start from the first
    /// page; the same text (new facts, or typed back) keeps the pages shown.
    public mutating func shows(_ text: String, facts: Int) -> Bool {
        let newText = text != self.text
        self.text = text
        self.facts = facts
        searching = false
        return newText
    }

    /// The field is empty: no answer on the page, and none searching.
    public mutating func emptied() {
        self = SearchAnswer()
    }
}
