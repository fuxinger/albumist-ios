import Foundation
import Testing
@testable import AlbumistCore

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
    /// analysis has not read yet: ignoring it gives it none, `IgnoreChange`), so its menu offers
    /// the way back. With a state, the state decides, as the photo's "Info" says it
    /// (`OrganizationStatusResolver.overall`): an excluded photo is shown as excluded, also when
    /// the user ignored it too.
    @Test func anIgnoredPhotoIsKnownWithOrWithoutAState() {
        let id: AssetID = "a"
        #expect(PhotoMenu.isIgnored(id, ignored: [id], state: nil))
        #expect(!PhotoMenu.isIgnored(id, ignored: [], state: nil))
        #expect(!PhotoMenu.isIgnored(id, ignored: ["b"], state: nil))
        let ignored = PhotoMenu.isIgnored(id, ignored: [id], state: nil)
        #expect(PhotoMenu(place: .album, isIgnored: ignored).items.contains(.stopIgnoring))

        let resolver = OrganizationStatusResolver(primaryAreas: [.places, .trips])
        let states = [
            AssetOrganizationState(assetID: id, isIgnored: true),
            AssetOrganizationState(assetID: id, areas: [.trips: .ignored]),
            AssetOrganizationState(assetID: id, areas: [.trips: .organized]),
            AssetOrganizationState(assetID: id, areas: [.trips: .unorganized, .places: .ignored]),
            AssetOrganizationState(assetID: id, areas: [.trips: .excluded], isExcluded: true),
            AssetOrganizationState(assetID: id, areas: [.trips: .excluded, .places: .ignored]),
            AssetOrganizationState(assetID: id),
        ]
        for state in states {
            let info = resolver.overall(state) == .ignored
            for set in [Set<AssetID>(), [id]] {
                #expect(PhotoMenu.isIgnored(id, ignored: set, state: state) == info, "\(state), ignored \(set)")
            }
        }
        #expect(PhotoMenu.isIgnored(id, ignored: [], state: states[0]))
        #expect(!PhotoMenu.isIgnored(id, ignored: [id], state: states[4]), "excluded comes first, as in the Info")
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
}
