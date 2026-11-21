import Foundation
import Testing
@testable import AlbumistUITestLogic

/// The accessibility test's side check (`SideShelfCheck`): text in a card that peeks in from the
/// side of a shelf passes, any other text that runs off the side fails as before. The frames are
/// those of UI run 44852630315 (accessibility, test4, "landscape albums", small iPhone 375 × 667):
/// the third album of "Von Albumist" peeks in at x 366, its "Neu", name and count ran off the side.
@Suite("Accessibility side check")
struct SideShelfCheckTests {
    let screen = CGRect(x: 0, y: 0, width: 375, height: 667)
    /// The app's window, the page's vertical scroll view and the shelf's sideways one.
    var window: SideShelfCheck.Ancestor { .init(frame: screen, isScrollView: false) }
    var page: SideShelfCheck.Ancestor { .init(frame: screen, isScrollView: true) }
    var shelf: SideShelfCheck.Ancestor { .init(frame: CGRect(x: 0, y: 208, width: 375, height: 220), isScrollView: true) }
    /// The shelf's content, as wide as its three cards and more.
    var content: SideShelfCheck.Ancestor { .init(frame: CGRect(x: 16, y: 208, width: 700, height: 220), isScrollView: false) }
    /// The third album, 163 pt wide, at x 366: nine points of it on screen.
    let third = CGRect(x: 366, y: 210, width: 163, height: 210)

    func inThird(_ text: CGRect) -> CGRect? {
        SideShelfCheck.peekingCard(of: text, ancestors: [window, page, shelf, content,
                                                         .init(frame: third, isScrollView: false)], screen: screen)
    }

    @Test func textOfTheCardPeekingInPasses() {
        // "Neu", "Geiranger, Juli 2021", "14 Fotos" of the run.
        #expect(inThird(CGRect(x: 374, y: 218, width: 42, height: 22)) == third)
        #expect(inThird(CGRect(x: 366, y: 380, width: 142, height: 18)) == third)
        #expect(inThird(CGRect(x: 366, y: 400, width: 52, height: 16)) == third)
    }

    /// The outermost element of the card is the card: the badge on its photo and the text under
    /// it name the same card, so the audit's finding on the badge is matched to it.
    @Test func theCardIsTheOutermostElementThatHoldsTheText() {
        let body = CGRect(x: 366, y: 210, width: 163, height: 160)
        let card = SideShelfCheck.peekingCard(of: CGRect(x: 374, y: 218, width: 42, height: 22),
                                              ancestors: [window, page, shelf, content, .init(frame: third, isScrollView: false),
                                                          .init(frame: body, isScrollView: false)], screen: screen)
        #expect(card == third)
    }

    @Test func aShelfScrolledOnPeeksOnTheLeftToo() {
        let first = CGRect(x: -120, y: 210, width: 163, height: 203)
        let card = SideShelfCheck.peekingCard(of: CGRect(x: -120, y: 380, width: 142, height: 18),
                                              ancestors: [window, page, shelf, .init(frame: first, isScrollView: false)], screen: screen)
        #expect(card == first)
    }

    /// Text on screen is not the side check's business at all.
    @Test func textOnScreenIsNotRunningOff() {
        #expect(!SideShelfCheck.runsOffSide(CGRect(x: 16, y: 380, width: 142, height: 18), screen: screen))
        #expect(!SideShelfCheck.runsOffSide(CGRect(x: 0, y: 0, width: 375.5, height: 18), screen: screen))
        #expect(SideShelfCheck.runsOffSide(CGRect(x: 366, y: 380, width: 142, height: 18), screen: screen))
        #expect(SideShelfCheck.runsOffSide(CGRect(x: -3, y: 380, width: 142, height: 18), screen: screen))
        #expect(inThird(CGRect(x: 200, y: 380, width: 100, height: 18)) == nil)
    }

    /// A line wider than its card runs off the side by a layout fault: it fails as before.
    @Test func textWiderThanItsCardStillFails() {
        let card = CGRect(x: 200, y: 210, width: 163, height: 203)
        #expect(SideShelfCheck.peekingCard(of: CGRect(x: 210, y: 380, width: 180, height: 18),
                                           ancestors: [window, page, shelf, .init(frame: card, isScrollView: false)],
                                           screen: screen) == nil)
    }

    /// A row as wide as the screen is not a card: its text running off the side is a fault.
    @Test func textOfARowAsWideAsTheScreenStillFails() {
        let row = CGRect(x: 0, y: 90, width: 375, height: 44)
        #expect(SideShelfCheck.peekingCard(of: CGRect(x: 300, y: 100, width: 200, height: 20),
                                           ancestors: [window, page, .init(frame: row, isScrollView: false)], screen: screen) == nil)
    }

    /// A card that runs off the side of the page itself (no shelf of its own around it) is pushed
    /// off by its neighbours: a fault, not a peek.
    @Test func aCardCutByThePageItselfStillFails() {
        let card = CGRect(x: 300, y: 100, width: 163, height: 200)
        #expect(SideShelfCheck.peekingCard(of: CGRect(x: 310, y: 250, width: 120, height: 18),
                                           ancestors: [window, page, .init(frame: card, isScrollView: false)], screen: screen) == nil)
    }

    /// A card that does not run off the same side as its text holds no peek.
    @Test func theCardMustRunOffTheSameSide() {
        let card = CGRect(x: -40, y: 210, width: 163, height: 203)
        #expect(SideShelfCheck.peekingCard(of: CGRect(x: -30, y: 380, width: 142, height: 18),
                                           ancestors: [window, page, shelf, .init(frame: card, isScrollView: false)],
                                           screen: screen) == card)
        // The text runs off the right, the card holds it only on the left: not held, so no card.
        #expect(SideShelfCheck.peekingCard(of: CGRect(x: 100, y: 380, width: 300, height: 18),
                                           ancestors: [window, page, shelf, .init(frame: card, isScrollView: false)],
                                           screen: screen) == nil)
    }

    /// A card as wide as the screen never fits once scrolled in: no peek.
    @Test func aCardWiderThanTheScreenStillFails() {
        let card = CGRect(x: 16, y: 210, width: 400, height: 203)
        #expect(SideShelfCheck.peekingCard(of: CGRect(x: 300, y: 380, width: 100, height: 18),
                                           ancestors: [window, page, shelf, .init(frame: card, isScrollView: false)],
                                           screen: screen) == nil)
    }

    /// The audit names an element by its frame only: it matches a card noted in the tree when
    /// it runs off the side and lies in that card.
    @Test func theAuditsFindingMatchesTheCardItLiesIn() {
        let cards = [third]
        #expect(SideShelfCheck.inPeekingCard(CGRect(x: 374, y: 218, width: 42, height: 22), cards: cards, screen: screen))
        // On screen: the audit's finding counts as before.
        #expect(!SideShelfCheck.inPeekingCard(CGRect(x: 24, y: 218, width: 42, height: 22), cards: cards, screen: screen))
        // Off the side but in no card noted: counts as before.
        #expect(!SideShelfCheck.inPeekingCard(CGRect(x: 374, y: 600, width: 42, height: 22), cards: cards, screen: screen))
        #expect(!SideShelfCheck.inPeekingCard(CGRect(x: 374, y: 218, width: 42, height: 22), cards: [], screen: screen))
    }
}
