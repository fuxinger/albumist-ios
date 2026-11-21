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

    // MARK: The lifted photo

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }

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
