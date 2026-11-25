import Foundation
import Testing
@testable import AlbumistCore

/// The long press on a suggestion's card (design wave 2, DS-06a; draft E4 "lang drücken", note:
/// "Auf einer Vorschlags-Karte zeigt es dieselben Punkte wie „…“ im Vorschlag"): the card's own
/// word first, doing what its button does, then what the open suggestion's "…" offers
/// ("Anpassen", the trip's two items), "Nicht jetzt" last. Only what still makes sense: nothing
/// while its album is made, once it is made, or while the list selects.
@Suite("Long press on a suggestion card")
struct SuggestionMenuTests {
    typealias Item = SuggestionMenu.Item

    static func menu(_ action: ProposalCardAction = .create, made: Bool = false, working: Bool = false,
                     waits: Bool = false, selecting: Bool = false, setAside: Bool = false, canReshape: Bool = false,
                     offersNotATrip: Bool = false, canAnswerNotATrip: Bool = true) -> SuggestionMenu {
        SuggestionMenu(SuggestionMenu.Card(action: action, made: made, working: working, waits: waits,
                                           selecting: selecting, setAside: setAside, canReshape: canReshape,
                                           offersNotATrip: offersNotATrip, canAnswerNotATrip: canAnswerNotATrip))
    }

    static func groups(_ menu: SuggestionMenu) -> [[Item]] {
        menu.sections.map { $0.map(\.item) }
    }

    static let toskana = ProposalCardAction.add(albumName: "Toskana", newPhotos: 12)

    // MARK: Each kind of card

    /// A new album ("Anlegen"): the word, "Anpassen" beside it (both decide the album), then
    /// "Nicht jetzt" on its own, every item ready.
    @Test func aNewAlbumOffersAnlegenThenAnpassenThenNichtJetzt() {
        let menu = Self.menu(.create)
        #expect(Self.groups(menu) == [[.action(.create), .adjust], [.notNow]])
        #expect(menu.items == [.action(.create), .adjust, .notNow])
        #expect(menu.entries.allSatisfy { $0.isEnabled })
        #expect(!menu.isEmpty)
    }

    /// The user's own album gets the photos ("Ergänzen …", through the preview): the menu's
    /// word is the card's, with the album it names.
    @Test func addingToTheUsersOwnAlbumStartsWithErgaenzen() {
        let menu = Self.menu(Self.toskana)
        #expect(Self.groups(menu) == [[.action(Self.toskana), .adjust], [.notNow]])
    }

    /// A place only the user can name ("Benennen …"): the word opens the suggestion, as the
    /// card's button does; "Anpassen" stays (its "Titel" is the name).
    @Test func aSuggestionWithoutANameStartsWithBenennen() {
        #expect(Self.groups(Self.menu(.name)) == [[.action(.name), .adjust], [.notNow]])
    }

    /// Personal content, an album that is complete or that the suggestion renames, or Albumist
    /// is unsure ("Ansehen …"): the same items, the word opens the suggestion first.
    @Test func personalContentStartsWithAnsehen() {
        #expect(Self.groups(Self.menu(.look)) == [[.action(.look), .adjust], [.notNow]])
    }

    /// Whatever the card's word, it comes first, exactly as the card shows it.
    @Test(arguments: [ProposalCardAction.create, .add(albumName: "Toskana", newPhotos: 12), .add(albumName: "", newPhotos: 1),
                      .name, .look])
    func theCardsWordComesFirst(_ action: ProposalCardAction) {
        #expect(Self.menu(action).items.first == .action(action))
        #expect(Self.menu(action, canReshape: true, offersNotATrip: true).items.first == .action(action))
    }

    // MARK: Trips

    /// A trip Albumist has not made an album of yet: "Reise teilen oder zusammenlegen" and "Keine
    /// Reise, hier bin ich öfter" in a group of their own, as in the open suggestion's "…".
    @Test func aTripAddsItsTwoItemsInAGroupOfTheirOwn() {
        let menu = Self.menu(.create, canReshape: true, offersNotATrip: true)
        #expect(Self.groups(menu) == [[.action(.create), .adjust], [.reshapeTrip, .notATrip], [.notNow]])
        #expect(menu.entries.allSatisfy { $0.isEnabled })
    }

    /// Only one of the two: its group holds that one.
    @Test func aTripWithOnlyOneOfItsItems() {
        #expect(Self.groups(Self.menu(.create, canReshape: true)) == [[.action(.create), .adjust], [.reshapeTrip], [.notNow]])
        #expect(Self.groups(Self.menu(.look, offersNotATrip: true)) == [[.action(.look), .adjust], [.notATrip], [.notNow]])
    }

    /// While "Dein Zuhause" changes, the analysis runs or albums are made, "Keine Reise" waits,
    /// as in the open suggestion (`AppModel.canChangeHome`); everything else stays ready.
    @Test func keineReiseWaitsWhileTheSuggestionsCannotChange() {
        let menu = Self.menu(.create, canReshape: true, offersNotATrip: true, canAnswerNotATrip: false)
        #expect(Self.groups(menu) == [[.action(.create), .adjust], [.reshapeTrip, .notATrip], [.notNow]])
        #expect(menu.isEnabled(.notATrip) == false)
        #expect(menu.isEnabled(.reshapeTrip) == true)
        #expect(menu.isEnabled(.action(.create)) == true)
        #expect(menu.isEnabled(.notNow) == true)
    }

    /// Not offered (the question card asks it, or the place is not known): not in the menu,
    /// whatever `canAnswerNotATrip` says.
    @Test func keineReiseOnlyWhereTheSuggestionOffersIt() {
        #expect(!Self.menu(.create, offersNotATrip: false, canAnswerNotATrip: false).items.contains(.notATrip))
        #expect(Self.menu(.create, offersNotATrip: false).isEnabled(.notATrip) == nil)
    }

    // MARK: States

    /// Set aside with "Nicht jetzt": no second "Nicht jetzt". Its word stays ready: making it
    /// from there is how it comes back (`AppModel.createNow` lifts the set-aside).
    @Test func aSuggestionSetAsideHasNoNichtJetzt() {
        let menu = Self.menu(.create, setAside: true)
        #expect(Self.groups(menu) == [[.action(.create), .adjust]])
        #expect(menu.isEnabled(.action(.create)) == true)
        let trip = Self.menu(.create, setAside: true, canReshape: true, offersNotATrip: true)
        #expect(Self.groups(trip) == [[.action(.create), .adjust], [.reshapeTrip, .notATrip]])
    }

    /// Its album is being made, or its preview prepared: nothing of it may change now, so the
    /// long press offers nothing (the card shows its work).
    @Test func aWorkingCardOffersNothing() {
        #expect(Self.menu(.create, working: true).isEmpty)
        #expect(Self.menu(Self.toskana, working: true, canReshape: true, offersNotATrip: true).isEmpty)
        #expect(Self.menu(.create, working: true).items.isEmpty)
    }

    /// "✓ Angelegt": the suggestion is an album now ("Widerrufen" is on its banner), nothing of
    /// the suggestion is left to choose.
    @Test func aMadeCardOffersNothing() {
        #expect(Self.menu(.create, made: true).isEmpty)
        #expect(Self.menu(.create, made: true, setAside: true, canReshape: true, offersNotATrip: true).isEmpty)
    }

    /// While the list selects, a press ticks: no menu, as in Photos' selection.
    @Test func noMenuWhileTheListSelects() {
        #expect(Self.menu(.create, selecting: true).isEmpty)
        #expect(Self.menu(.look, selecting: true, canReshape: true, offersNotATrip: true).isEmpty)
    }

    /// Another card's album is being made, or its preview prepared (one at a time): the word
    /// waits, as the card's button does; the rest changes nothing that is being made.
    @Test func whileAnotherCardWorksOnlyTheWordWaits() {
        let menu = Self.menu(.create, waits: true, canReshape: true, offersNotATrip: true)
        #expect(Self.groups(menu) == [[.action(.create), .adjust], [.reshapeTrip, .notATrip], [.notNow]])
        #expect(menu.isEnabled(.action(.create)) == false)
        #expect(menu.entries.filter(\.isEnabled).map(\.item) == [.adjust, .reshapeTrip, .notATrip, .notNow])
    }

    /// In every state that shows a menu the card's word is first and "Nicht jetzt", where it is
    /// offered, last; every group holds something.
    @Test func theWordIsFirstAndNichtJetztLastInEveryState() {
        for waits in [false, true] {
            for setAside in [false, true] {
                for canReshape in [false, true] {
                    for offers in [false, true] {
                        let menu = Self.menu(.create, waits: waits, setAside: setAside, canReshape: canReshape,
                                             offersNotATrip: offers, canAnswerNotATrip: !waits)
                        #expect(menu.items.first == .action(.create))
                        #expect(menu.items.contains(.notNow) == !setAside)
                        if !setAside { #expect(menu.items.last == .notNow) }
                        #expect(menu.sections.allSatisfy { !$0.isEmpty })
                        #expect(Set(menu.entries.map(\.id)).count == menu.entries.count, "each item once")
                    }
                }
            }
        }
    }

    /// What the menu does not offer is neither ready nor waiting (review C of design wave 2, L6).
    @Test func anItemTheMenuDoesNotOfferHasNoState() {
        #expect(Self.menu(.create).isEnabled(.reshapeTrip) == nil)
        #expect(Self.menu(.create, setAside: true).isEnabled(.notNow) == nil)
        #expect(Self.menu(.create, made: true).isEnabled(.action(.create)) == nil)
        #expect(Self.menu(.create).isEnabled(.action(.look)) == nil, "another word than the card's")
    }

    /// Set aside while another card works: no "Nicht jetzt", the word waits, "Anpassen" is ready.
    @Test func setAsideWhileAnotherCardWorks() {
        let menu = Self.menu(.create, waits: true, setAside: true)
        #expect(Self.groups(menu) == [[.action(.create), .adjust]])
        #expect(menu.isEnabled(.action(.create)) == false)
        #expect(menu.isEnabled(.adjust) == true)
    }

    /// Made while the list selects, or working too: still nothing.
    @Test func madeWhileTheListSelects() {
        #expect(Self.menu(.create, made: true, selecting: true).isEmpty)
        #expect(Self.menu(.look, made: true, working: true, selecting: true, canReshape: true).isEmpty)
    }

    // MARK: Switched off, and for assistive technologies (review C of design wave 2, M4, L1, L3)

    /// Whether a card has a menu at all is known from the card alone, before anything else is
    /// read: the app switches the long press off with it (no lift, no empty menu, no actions).
    @Test func aMenuIsOfferedOnlyWhileTheCardCanChange() {
        #expect(SuggestionMenu.isOffered(made: false, working: false, selecting: false))
        for made in [false, true] {
            for working in [false, true] {
                for selecting in [false, true] {
                    for waits in [false, true] {
                        let offered = SuggestionMenu.isOffered(made: made, working: working, selecting: selecting)
                        let menu = Self.menu(.create, made: made, working: working, waits: waits, selecting: selecting,
                                             canReshape: true, offersNotATrip: true)
                        #expect(menu.isEmpty == !offered, "made \(made), working \(working), selecting \(selecting)")
                        #expect(offered == (!made && !working && !selecting))
                    }
                }
            }
        }
    }

    /// VoiceOver, Voice Control and Switch Control get the items as actions of the card's body,
    /// but not the card's word (it is the card's own button, as a photo leaves out "Ansehen")
    /// and nothing that waits (it could not be done).
    @Test func assistiveTechnologiesGetWhatCanBeDoneBesideTheButton() {
        #expect(Self.menu(.create).accessibilityItems == [.adjust, .notNow])
        #expect(Self.menu(Self.toskana, canReshape: true, offersNotATrip: true).accessibilityItems
                == [.adjust, .reshapeTrip, .notATrip, .notNow])
        #expect(Self.menu(.create, canReshape: true, offersNotATrip: true, canAnswerNotATrip: false).accessibilityItems
                == [.adjust, .reshapeTrip, .notNow], "„Keine Reise“ waits")
        #expect(Self.menu(.create, waits: true).accessibilityItems == [.adjust, .notNow])
        #expect(Self.menu(.look, setAside: true).accessibilityItems == [.adjust])
        #expect(Self.menu(.create, made: true).accessibilityItems.isEmpty)
        #expect(Self.menu(.create, selecting: true).accessibilityItems.isEmpty)
    }

    // MARK: Read only what the menu shows (review C of design wave 2, M5)

    /// Nothing is read for a card without a menu, and whether "Keine Reise" can be answered (the
    /// state of the analysis and of the plans) only where it is offered; otherwise the menu is
    /// the card's menu.
    @Test func onlyWhatTheMenuShowsIsRead() {
        var reads: [String] = []
        func menu(made: Bool = false, working: Bool = false, waits: Bool = false, selecting: Bool = false,
                  setAside: Bool = false, canReshape: Bool = true, offers: Bool, canAnswer: Bool = true) -> SuggestionMenu {
            SuggestionMenu(action: .create, made: made, working: working, waits: waits, selecting: selecting,
                           setAside: { reads.append("setAside"); return setAside },
                           canReshape: { reads.append("canReshape"); return canReshape },
                           offersNotATrip: { reads.append("offers"); return offers },
                           canAnswerNotATrip: { reads.append("canAnswer"); return canAnswer })
        }
        #expect(menu(made: true, offers: true).isEmpty)
        #expect(menu(working: true, offers: true).isEmpty)
        #expect(menu(selecting: true, offers: true).isEmpty)
        #expect(reads.isEmpty, "read for a card without a menu: \(reads)")
        _ = menu(offers: false)
        #expect(reads.sorted() == ["canReshape", "offers", "setAside"], "\(reads)")
        reads = []
        _ = menu(offers: true)
        #expect(reads.sorted() == ["canAnswer", "canReshape", "offers", "setAside"], "\(reads)")
        for waits in [false, true] {
            for setAside in [false, true] {
                for canReshape in [false, true] {
                    for offers in [false, true] {
                        for canAnswer in [false, true] {
                            let lazy = menu(waits: waits, setAside: setAside, canReshape: canReshape, offers: offers,
                                            canAnswer: canAnswer)
                            #expect(lazy == Self.menu(.create, waits: waits, setAside: setAside, canReshape: canReshape,
                                                      offersNotATrip: offers, canAnswerNotATrip: canAnswer))
                        }
                    }
                }
            }
        }
    }

    // MARK: The suggestion as it is now (review C of design wave 2, H1)

    static func kyoto(_ photos: [AssetID], id: String = "kyoto") -> AlbumProposal {
        AlbumProposal(id: AlbumistID(id), kind: .trip, title: "Kyoto", assetIDs: Set(photos))
    }

    /// A menu stays open while the analysis goes on: an item acts on the suggestion as the
    /// analysis has it at the tap, found by its id, with its photos now.
    @Test func anItemActsOnTheSuggestionAsItIsNow() {
        let drawn = Self.kyoto(["a", "b"])
        let now = Self.kyoto(["a", "b", "c"])
        let other = Self.kyoto(["x"], id: "rome")
        #expect(SuggestionMenu.current(drawn, in: [other, now]) == now)
        #expect(SuggestionMenu.current(drawn, in: [drawn]) == drawn)
    }

    /// One the analysis no longer has (made anew, split, merged) is acted on no more.
    @Test func aSuggestionThatWentIsNotActedOn() {
        let drawn = Self.kyoto(["a", "b"])
        #expect(SuggestionMenu.current(drawn, in: []) == nil)
        #expect(SuggestionMenu.current(drawn, in: [Self.kyoto(["a", "b"], id: "kyoto-2")]) == nil,
                "the same photos under another id are another suggestion")
    }
}
