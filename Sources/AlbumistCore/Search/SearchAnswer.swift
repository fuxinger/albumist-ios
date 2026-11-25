import Foundation

/// When the search page searches (design wave 3, H14; review T3 of H14's round 2). A view's
/// `.task` ends when the view goes and starts again when it comes back, and a tab's page goes
/// when another tab is chosen: each return to the search tab ran the whole search again for the
/// text on the page. A sentence went to Apple Intelligence a second time, the line "Verstanden
/// als" went away and came back, and the pages of hits shown fell back to the first, under the
/// place the user had scrolled to. Now the page asks this record first:
/// - the finished answer on the page was made for this text, and nothing a search reads changed
///   since: nothing is searched, the hits and the pages shown stay;
/// - a search that did not finish (another tab was chosen, the text changed meanwhile), a change
///   of what a search reads, or a new text: searched again; only a new text shows the hits from
///   the first page.
/// What a search reads has one revision (`AppModel.searchRevision`, review Q1 of H14's round 3):
/// the photos' facts and states (an ignored photo leaves "Unsortiert"), the albums, the names of
/// places, the home, the part of the library and the settings its statuses are read with, and the
/// day ("heute", "letzte Woche"). The page asks as its task starts, so a change is searched when
/// the search tab is chosen again, never while the page stays open: during an analysis the facts
/// change often, and a search of their own would ask Apple Intelligence again and again and move
/// the hits under the user's finger.
public struct SearchAnswer: Sendable, Equatable {
    /// The text the answer on the page was made for; empty while the field is empty and before
    /// the first answer.
    public private(set) var text = ""
    /// A search runs, or was left before it finished: the page does not show the finished
    /// answer for the text in the field.
    public private(set) var searching = false
    /// The revision of what a search reads the answer on the page was made with.
    private var revision: Int?

    public init() {}

    /// The page's task starts for `text` (not empty), with what a search reads at revision
    /// `revision`. True: search; false: the page shows the finished answer for both, and nothing
    /// is asked again.
    public mutating func starts(_ text: String, revision: Int) -> Bool {
        guard searching || text != self.text || revision != self.revision else { return false }
        searching = true
        return true
    }

    /// The answer for `text`, searched with what a search reads at revision `revision`, is on
    /// the page. True when it belongs to another text than the answer before: its hits start
    /// from the first page; the same text (a new revision, or typed back) keeps the pages shown.
    public mutating func shows(_ text: String, revision: Int) -> Bool {
        let newText = text != self.text
        self.text = text
        self.revision = revision
        searching = false
        return newText
    }

    /// The field is empty: no answer on the page, and none searching.
    public mutating func emptied() {
        self = SearchAnswer()
    }
}
