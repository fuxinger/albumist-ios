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

/// The long press on a photo of a grid (design wave 2, DS-06a): what that place already offers
/// for one photo, through the same ways: "Ansehen" (the tap), "Zu Album hinzufügen …" (the sheet
/// and the preview), "Ignorieren" or "Nicht mehr ignorieren" (with "Widerrufen"); in a suggestion
/// "Aus Vorschlag entfernen" (asked first, as "Auswählen" does). No "Teilen" (the photo view's).
@Suite("Long press on a photo")
struct PhotoMenuTests {
    typealias Item = PhotoMenu.Item

    /// "Unsortiert": open it, put it in an album, then ignore it, in a group of its own (it
    /// takes the photo out of the list).
    @Test func unsortedOffersAnsehenZuAlbumAndIgnorieren() {
        let menu = PhotoMenu(place: .unsorted)
        #expect(menu.sections == [[.view, .addToAlbum], [.ignore]])
        #expect(menu.items == [.view, .addToAlbum, .ignore])
        #expect(!menu.isEmpty)
    }

    /// An ignored photo ("Ignoriert" in "Unsortiert", a search hit, a photo of an album) offers
    /// the way back instead, as its "Info" does.
    @Test(arguments: [PhotoMenu.Place.unsorted, .album, .search])
    func anIgnoredPhotoOffersTheWayBack(_ place: PhotoMenu.Place) {
        #expect(PhotoMenu(place: place, isIgnored: true).sections == [[.view, .addToAlbum], [.stopIgnoring]])
        #expect(PhotoMenu(place: place, isIgnored: false).sections == [[.view, .addToAlbum], [.ignore]])
    }

    /// A photo of a suggestion: open it, or take it out of this suggestion (it stays in the
    /// library and in other suggestions). Ignoring or adding it elsewhere would not change the
    /// open suggestion; they stay behind "Ansehen" › "Info".
    @Test func aPhotoInASuggestionCanBeTakenOutOfIt() {
        #expect(PhotoMenu(place: .suggestion).sections == [[.view], [.removeFromSuggestion]])
        #expect(PhotoMenu(place: .suggestion, isIgnored: true).sections == [[.view], [.removeFromSuggestion]])
    }

    /// While a grid selects, a press ticks: no menu anywhere.
    @Test(arguments: [PhotoMenu.Place.unsorted, .suggestion, .album, .search])
    func noMenuWhileSelecting(_ place: PhotoMenu.Place) {
        let menu = PhotoMenu(place: place, selecting: true)
        #expect(menu.isEmpty)
        #expect(menu.items.isEmpty)
        #expect(menu.accessibilityItems.isEmpty)
    }

    /// A photo that cannot be opened now (a search hit whose facts are not there, the photos of
    /// a suggestion whose album is being made): no menu either.
    @Test(arguments: [PhotoMenu.Place.unsorted, .suggestion, .album, .search])
    func noMenuWhileThePhotoCannotOpen(_ place: PhotoMenu.Place) {
        #expect(PhotoMenu(place: place, available: false).isEmpty)
        #expect(PhotoMenu(place: place, isIgnored: true, available: false).accessibilityItems.isEmpty)
    }

    /// VoiceOver: every item is an action of the photo too, but "Ansehen", which is the
    /// photo's own (a double tap opens it).
    @Test func voiceOverGetsEveryItemButAnsehen() {
        #expect(PhotoMenu(place: .unsorted).accessibilityItems == [.addToAlbum, .ignore])
        #expect(PhotoMenu(place: .search, isIgnored: true).accessibilityItems == [.addToAlbum, .stopIgnoring])
        #expect(PhotoMenu(place: .suggestion).accessibilityItems == [.removeFromSuggestion])
    }

    /// One way per item, never two items for the same: no share (the photo view's), each item
    /// once.
    @Test(arguments: [PhotoMenu.Place.unsorted, .suggestion, .album, .search])
    func eachItemOnceAndEveryGroupHoldsSomething(_ place: PhotoMenu.Place) {
        for ignored in [false, true] {
            let menu = PhotoMenu(place: place, isIgnored: ignored)
            #expect(Set(menu.items).count == menu.items.count)
            #expect(menu.sections.allSatisfy { !$0.isEmpty })
            #expect(menu.items.first == .view)
            #expect(!(menu.items.contains(.ignore) && menu.items.contains(.stopIgnoring)))
        }
    }

    // MARK: Switched off (review C of design wave 2, M4)

    /// Whether a photo has a menu at all is known from the grid alone: the app switches the long
    /// press off with it while the grid selects or the photo cannot be opened.
    @Test(arguments: [PhotoMenu.Place.unsorted, .suggestion, .album, .search])
    func aMenuIsOfferedOnlyWhileThePhotoCanBeOpened(_ place: PhotoMenu.Place) {
        for selecting in [false, true] {
            for available in [false, true] {
                let offered = PhotoMenu.isOffered(selecting: selecting, available: available)
                #expect(offered == (!selecting && available))
                #expect(PhotoMenu(place: place, selecting: selecting, available: available).isEmpty == !offered)
            }
        }
    }

    // MARK: Ignored (review C of design wave 2, L6)

    /// A photo the user ignored is ignored also without a state of its own (an album's photo the
    /// analysis has not read yet: ignoring it gives it none), so its menu offers the way back;
    /// a state that says ignored counts as well, and an excluded photo the user also ignored
    /// can be un-ignored.
    @Test func anIgnoredPhotoIsKnownWithOrWithoutAState() {
        let id: AssetID = "a"
        #expect(PhotoMenu.isIgnored(id, ignored: [id], state: nil))
        #expect(!PhotoMenu.isIgnored(id, ignored: [], state: nil))
        #expect(!PhotoMenu.isIgnored(id, ignored: ["b"], state: nil))
        #expect(PhotoMenu.isIgnored(id, ignored: [], state: AssetOrganizationState(assetID: id, isIgnored: true)))
        #expect(PhotoMenu.isIgnored(id, ignored: [], state: AssetOrganizationState(assetID: id, areas: [.trips: .ignored])))
        #expect(!PhotoMenu.isIgnored(id, ignored: [], state: AssetOrganizationState(assetID: id, areas: [.trips: .organized])))
        #expect(PhotoMenu.isIgnored(id, ignored: [id], state: AssetOrganizationState(assetID: id, isExcluded: true)))
        let ignored = PhotoMenu.isIgnored(id, ignored: [id], state: nil)
        #expect(PhotoMenu(place: .album, isIgnored: ignored).items.contains(.stopIgnoring))
    }

    // MARK: The lifted photo (review C of design wave 2, M2)

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

    /// Drawn no larger than the image allows: 70 % of the pixels it fills, per side.
    static func isSharp(_ size: PhotoMenu.PreviewSize, imageWidth: Double, imageHeight: Double, scale: Double) -> Bool {
        size.width * scale * PhotoMenu.sharpShare <= imageWidth + 0.01
            && size.height * scale * PhotoMenu.sharpShare <= imageHeight + 0.01
    }

    /// The photo is lifted from the image its cell already shows, at once: whole, in its own
    /// proportions, as large as that image is sharp (the covers' 70 %), so larger than its 110
    /// pt cell and never a blurry enlargement or an empty surface. A grid's thumbnail of a photo
    /// taken across (440 × 330 px on a 3x screen) lifts to 210 × 157 pt.
    @Test func theLiftedPhotoIsTheCellsImageAsLargeAsItIsSharp() {
        let across = PhotoMenu.liftSize(imageWidth: 440, imageHeight: 330, scale: 3, cellSide: 110)
        #expect(Self.close(across.width, 440 / 2.1) && Self.close(across.height, 330 / 2.1))
        #expect(Self.close(across.aspectRatio, 4.0 / 3.0))
        #expect(Self.isSharp(across, imageWidth: 440, imageHeight: 330, scale: 3))
        let upright = PhotoMenu.liftSize(imageWidth: 330, imageHeight: 440, scale: 3, cellSide: 110)
        #expect(Self.close(upright.width, 330 / 2.1) && Self.close(upright.height, 440 / 2.1))
        #expect(Self.isSharp(upright, imageWidth: 330, imageHeight: 440, scale: 3))
        // A screenshot's thumbnail: tall and narrow, nothing cut.
        let screenshot = PhotoMenu.liftSize(imageWidth: 330, imageHeight: 715, scale: 3, cellSide: 110)
        #expect(Self.close(screenshot.aspectRatio, 330.0 / 715))
        #expect(Self.isSharp(screenshot, imageWidth: 330, imageHeight: 715, scale: 3))
        // The same size in points on a 2x screen, whose grid asks for fewer pixels.
        let twice = PhotoMenu.liftSize(imageWidth: 440.0 * 2 / 3, imageHeight: 220, scale: 2, cellSide: 110)
        #expect(Self.close(twice.width, across.width) && Self.close(twice.height, across.height))
    }

    /// A larger image is lifted as large as fits in 320 × 427 pt (the width of an album's lifted
    /// preview; a photo taken upright, 3:4, fills it); a panorama keeps its width and is low.
    @Test func aLargeImageFillsTheBoundsAtMost() {
        let across = PhotoMenu.liftSize(imageWidth: 1200, imageHeight: 900, scale: 3, cellSide: 110)
        #expect(Self.close(across.width, 320) && Self.close(across.height, 240))
        let upright = PhotoMenu.liftSize(imageWidth: 1800, imageHeight: 2400, scale: 3, cellSide: 110)
        #expect(Self.close(upright.width, 320) && Self.close(upright.height, 426.67))
        let panorama = PhotoMenu.liftSize(imageWidth: 1320, imageHeight: 330, scale: 3, cellSide: 110)
        #expect(Self.close(panorama.width, 320) && Self.close(panorama.height, 80))
    }

    /// A photo whose cell shows only a small preview (the original in iCloud): lifted as large as
    /// its cell shows it, never smaller and never blown up beyond that.
    @Test func aSmallPreviewIsLiftedAsLargeAsItsCell() {
        let small = PhotoMenu.liftSize(imageWidth: 120, imageHeight: 90, scale: 3, cellSide: 110)
        #expect(Self.close(small.height, 110) && Self.close(small.width, 110 * 4.0 / 3))
        let tall = PhotoMenu.liftSize(imageWidth: 90, imageHeight: 120, scale: 3, cellSide: 140)
        #expect(Self.close(tall.width, 140) && Self.close(tall.height, 140 * 4.0 / 3))
    }

    /// Without the cell's image (a memory warning took it, it is asked for again): a square of the
    /// cell's size, the photo as its cell shows it. Far beyond any camera (a strip of a few
    /// pixels), held at 6:1 or 1:4 so the preview is never a line.
    @Test func anUnknownOrExtremeImageStaysAPhoto() {
        for (w, h, scale) in [(0.0, 0.0, 3.0), (0, 330, 3), (440, 0, 3), (-1, 10, 3), (440, 330, 0)] {
            let size = PhotoMenu.liftSize(imageWidth: w, imageHeight: h, scale: scale, cellSide: 110)
            #expect(Self.close(size.width, 110) && Self.close(size.height, 110), "\(w)×\(h) at \(scale)")
        }
        let strip = PhotoMenu.liftSize(imageWidth: 3000, imageHeight: 10, scale: 3, cellSide: 110)
        #expect(Self.close(strip.aspectRatio, 6))
        #expect(strip.width <= 320.01)
        let tower = PhotoMenu.liftSize(imageWidth: 10, imageHeight: 3000, scale: 3, cellSide: 110)
        #expect(Self.close(tower.aspectRatio, 0.25))
        #expect(Self.close(tower.height, 426.67))
    }

    /// The photo larger and whole, in its own proportions, as large as fits in 320 × 427 pt
    /// (the width of an album's lifted preview; a photo taken upright, 3:4, fills it).
    @Test func theLiftedPhotoIsWholeInItsOwnProportions() {
        let across = PhotoMenu.previewSize(pixelWidth: 4032, pixelHeight: 3024)
        #expect(Self.close(across.width, 320) && Self.close(across.height, 240))
        #expect(Self.close(across.aspectRatio, 4.0 / 3.0))
        let upright = PhotoMenu.previewSize(pixelWidth: 3024, pixelHeight: 4032)
        #expect(Self.close(upright.width, 320) && Self.close(upright.height, 426.67))
        // A screenshot is narrower: its height is what limits it, nothing is cut.
        let screenshot = PhotoMenu.previewSize(pixelWidth: 1179, pixelHeight: 2556)
        #expect(Self.close(screenshot.height, 426.67))
        #expect(Self.close(screenshot.width, 426.67 * 1179 / 2556))
        // A panorama keeps its width and is low.
        let panorama = PhotoMenu.previewSize(pixelWidth: 12_000, pixelHeight: 3_000)
        #expect(Self.close(panorama.width, 320) && Self.close(panorama.height, 80))
        let square = PhotoMenu.previewSize(pixelWidth: 2_000, pixelHeight: 2_000)
        #expect(Self.close(square.width, 320) && Self.close(square.height, 320))
    }

    /// Without its size (not read yet, a broken record), 4:3; far beyond any camera (a strip of
    /// a few pixels), held at 6:1 or 1:4 so the preview is never a line.
    @Test func anUnknownOrExtremeSizeStaysAPhoto() {
        for (w, h) in [(0, 0), (0, 3_000), (4_000, 0), (-1, 10)] {
            let size = PhotoMenu.previewSize(pixelWidth: w, pixelHeight: h)
            #expect(Self.close(size.width, 320) && Self.close(size.height, 240), "\(w)×\(h)")
        }
        let strip = PhotoMenu.previewSize(pixelWidth: 10_000, pixelHeight: 10)
        #expect(Self.close(strip.aspectRatio, 6))
        let tower = PhotoMenu.previewSize(pixelWidth: 10, pixelHeight: 10_000)
        #expect(Self.close(tower.aspectRatio, 0.25))
        #expect(Self.close(tower.height, 426.67))
    }
}
