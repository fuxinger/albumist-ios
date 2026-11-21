import Foundation
import Testing
@testable import AlbumistCore

/// DS-17: the sorting show with bigger photos and the album as its real cover. What the scene is
/// made of at each width and text size (`SortingShowLayout`), and which photos it may show of
/// each album (`SortingShowAlbum`): never a sensitive document, never a personal suggestion's
/// photo, and "Vorschau ausgeblendet" for a personal album.
@Suite("Sorting show stage")
struct SortingShowStageTests {
    // MARK: Sizes

    /// The widths the show gets on an iPhone held upright (the screen less 16 pt on each side):
    /// 4.7" and mini (375), 6.1" (402), 6.9" (440), and the iPad's focused column (520).
    static let widths: [Double] = [343, 370, 408, 488]

    @Test func photosAreBiggerThanBeforeAtEveryWidth() {
        for width in Self.widths {
            for largeText in [false, true] {
                let layout = SortingShowLayout(width: width, largeText: largeText)
                // Before: photos of 76 pt and an album of 124 pt at every width.
                #expect(layout.photo >= 100, "width \(width): \(layout.photo)")
                #expect(layout.cover >= 156, "width \(width): \(layout.cover)")
                #expect(layout.photo < layout.cover, "a photo lands in its album, it is not bigger")
            }
        }
    }

    @Test func sizesPerWidth() {
        let small = SortingShowLayout(width: 343, largeText: false)
        #expect(small.cover == 158)
        #expect(small.photo == 101)
        let regular = SortingShowLayout(width: 370, largeText: false)
        #expect(regular.cover == 170)
        #expect(regular.photo == 109)
        let large = SortingShowLayout(width: 408, largeText: false)
        #expect(large.cover == 188)
        #expect(large.photo == 120)
        // The iPad's column: the album stops growing, the photos with it.
        let pad = SortingShowLayout(width: 488, largeText: false)
        #expect(pad.cover == SortingShowLayout.maximumCover)
        #expect(pad.photo == 125)
        #expect(SortingShowLayout(width: 2000, largeText: false) == pad)
    }

    @Test func sizesGrowWithTheWidthAndNeverShrinkBelowTheOldShow() {
        var last: SortingShowLayout?
        for width in stride(from: 0.0, through: 700, by: 7) {
            let layout = SortingShowLayout(width: width, largeText: false)
            #expect(layout.photo >= SortingShowLayout.previousPhoto, "width \(width)")
            #expect(layout.cover >= SortingShowLayout.minimumCover, "width \(width)")
            #expect(layout.cover <= SortingShowLayout.maximumCover, "width \(width)")
            if let last {
                #expect(layout.photo >= last.photo && layout.cover >= last.cover && layout.height >= last.height, "width \(width)")
            }
            last = layout
        }
        // Not measured yet, or negative: the smallest show, not a broken one.
        #expect(SortingShowLayout(width: -10, largeText: false) == SortingShowLayout(width: 0, largeText: false))
        #expect(SortingShowLayout(width: .nan, largeText: false) == SortingShowLayout(width: 0, largeText: false))
    }

    /// At the accessibility sizes (and from xxLarge, where the scene's labels stop growing) the
    /// photos keep their size; the album's name gets more room below its cover, and the scene
    /// grows by that room only. The show then gives way to the counts and the button as before
    /// (`SortingShow.sceneScale`).
    @Test func largeTextKeepsThePhotosAndMakesRoomForTheName() {
        for width in Self.widths {
            let regular = SortingShowLayout(width: width, largeText: false)
            let large = SortingShowLayout(width: width, largeText: true)
            #expect(large.photo == regular.photo)
            #expect(large.cover == regular.cover)
            #expect(large.labelRoom > regular.labelRoom)
            #expect(large.height - regular.height == large.labelRoom - regular.labelRoom)
            #expect(large.coverCenterY == regular.coverCenterY)
        }
    }

    /// Everything stands inside the scene's height, top to bottom: the pile with its loose
    /// photos (turned and scattered), a gap the photos fly through, the album's two layers above
    /// its cover, the cover and its name.
    @Test func thePartsStandInOrderInsideTheScene() {
        for width in Self.widths {
            for largeText in [false, true] {
                let layout = SortingShowLayout(width: width, largeText: largeText)
                let pileBottom = layout.pileCenterY + layout.pileHeight / 2
                #expect(layout.pileCenterY - layout.pileHeight / 2 >= 0)
                // Turned up to 10°, a photo needs 1.16 of its side; the scatter adds to it.
                #expect(layout.pileHeight >= layout.photo * 1.16 + layout.scatter.dy * 2)
                let coverTop = layout.coverCenterY - layout.cover / 2
                #expect(coverTop - layout.layers >= pileBottom + 12, "the album's layers touch the pile at \(width)")
                #expect(layout.coverCenterY + layout.cover / 2 + layout.labelRoom <= layout.height)
                #expect(layout.height < 560, "the scene grew past a screen: \(layout.height)")
            }
        }
    }

    /// Where the screen is lower than the scene, the pile gives way first (second review, K6):
    /// its loose photos lie closer together up and down and the gap the photos fly through
    /// narrows, down to `minimumFlightGap`; only what is still missing then is scaled away with
    /// the whole scene (`SortingShow.sceneScale`). The photos and the album keep their size in the
    /// scene, so on screen they are bigger than with the whole scene scaled. With room enough,
    /// or not measured yet, the scene is as it was.
    @Test func aLowScreenSqueezesThePileBeforeTheSceneScales() {
        for width in Self.widths {
            for largeText in [false, true] {
                let full = SortingShowLayout(width: width, largeText: largeText)
                #expect(SortingShowLayout(width: width, largeText: largeText, room: nil) == full)
                #expect(SortingShowLayout(width: width, largeText: largeText, room: full.height) == full)
                #expect(SortingShowLayout(width: width, largeText: largeText, room: 2000) == full)
                let most = full.scatter.dy * 2 + SortingShowLayout.flightGap - SortingShowLayout.minimumFlightGap
                var last = full
                for room in stride(from: full.height - 1, through: 100, by: -3) {
                    let low = SortingShowLayout(width: width, largeText: largeText, room: room)
                    let what = "width \(width), large \(largeText), room \(room)"
                    #expect(low.photo == full.photo && low.cover == full.cover && low.layers == full.layers, "\(what)")
                    #expect(low.labelRoom == full.labelRoom && low.spacing == full.spacing && low.scatter.dx == full.scatter.dx, "\(what)")
                    #expect(low.height <= last.height, "\(what): \(low.height) after \(last.height)")
                    if room >= full.height - most {
                        #expect(abs(low.height - room) <= 2, "\(what): \(low.height)")
                    } else {
                        #expect(abs(low.height - (full.height - most)) <= 2, "\(what): \(low.height)")
                    }
                    // Still a pile above a gap above the album, every photo inside it.
                    let pileBottom = low.pileCenterY + low.pileHeight / 2
                    #expect(low.pileCenterY - low.pileHeight / 2 >= 0, "\(what)")
                    #expect(low.coverCenterY - low.cover / 2 - low.layers >= pileBottom + SortingShowLayout.minimumFlightGap, "\(what)")
                    #expect(low.pileHeight >= low.photo * 1.16 + low.scatter.dy * 2, "\(what)")
                    for index in 0..<6 {
                        #expect(abs(low.loose(index).y) <= low.scatter.dy + 0.001, "\(what), photo \(index)")
                        #expect(low.loose(index).x == full.loose(index).x && low.loose(index).angle == full.loose(index).angle, "\(what)")
                    }
                    #expect(low.coverCenterY + low.cover / 2 + low.labelRoom <= low.height, "\(what)")
                    // On screen at least as big as with the whole scene scaled.
                    #expect(low.photo * min(1, room / low.height) >= full.photo * min(1, room / full.height) - 0.001, "\(what)")
                    last = low
                }
            }
        }
        // The 4.7" iPhone: about 313 pt for the scene (554 pt between its bars, less the padding,
        // the counts and the button), 431 pt needed. Before DS-17 its photos showed at about
        // 66 pt; the whole scene scaled would show them at about 73 pt, with the pile giving way
        // at more than 80.
        let full = SortingShowLayout(width: 343, largeText: false)
        #expect(full.height == 431)
        #expect(full.photo * 313 / full.height < 74)
        let small = SortingShowLayout(width: 343, largeText: false, room: 313)
        #expect(small.photo * min(1, 313 / small.height) > 80, "\(small.height)")
    }

    /// The pile's loose photos stay inside the width at every size: scattered by at most
    /// `scatter.dx` to each side.
    @Test func thePileStaysInsideTheWidth() {
        for width in Self.widths {
            let layout = SortingShowLayout(width: width, largeText: false)
            #expect(layout.scatter.dx + layout.photo * 0.58 <= width / 2, "width \(width)")
            #expect(layout.scatter.dx > 0 && layout.scatter.dy > 0)
        }
    }

    /// The albums move as one strip: the neighbours peek in at the edges, smaller, and never
    /// overlap the album in the centre.
    @Test func theNeighboursPeekInWithoutTouchingTheAlbum() {
        for width in Self.widths {
            let layout = SortingShowLayout(width: width, largeText: false)
            let neighbourHalf = layout.cover * SortingShowLayout.neighbourScale / 2
            #expect(layout.spacing - neighbourHalf - layout.cover / 2 >= 16, "width \(width)")
            // At least a little of each neighbour is on the screen (the show stands 16 pt from the edge).
            #expect(layout.spacing - neighbourHalf < width / 2 + 16 - 20, "width \(width)")
        }
    }

    // MARK: Which photos

    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 5)

    private func plan(_ proposals: [AlbumProposal]) -> ChangePlan {
        planner.makePlan(from: proposals.map { ConfirmedProposal(proposal: $0, decision: .createNew(title: nil, folderPath: nil)) },
                         inventory: CollectionInventory([]))
    }

    private func cast(_ plan: ChangePlan, covers: [AlbumistID: AssetID] = [:], personal: Set<AlbumistID> = [],
                      ranks: [AssetID: PreviewRank] = [:], dates: [AssetID: Date] = [:],
                      favorites: Set<AssetID> = []) -> [SortingShowAlbum] {
        SortingShowAlbum.cast(plan.filledAlbums(inventory: CollectionInventory([]), ranks: ranks), plan: plan,
                              cardCovers: covers, personal: personal, ranks: ranks, dates: dates, favorites: favorites)
    }

    @Test func everyAlbumInPlanOrderWithItsPhotos() {
        let rome = AlbumProposal(id: AlbumistID("rome"), kind: .trip, title: "Rom", assetIDs: ids("r", 0..<12))
        let lake = AlbumProposal(id: AlbumistID("lake"), kind: .trip, title: "Gardasee", assetIDs: ids("g", 0..<3))
        let plan = plan([rome, lake])
        let albums = cast(plan)
        let filled = plan.filledAlbums(inventory: CollectionInventory([]))
        #expect(Set(albums.map(\.title)) == ["Rom", "Gardasee"])
        #expect(albums.map(\.title) == filled.map(\.title))
        #expect(albums.map(\.assets) == filled.map(\.assets))
        #expect(albums.first { $0.title == "Rom" }.map { Set($0.assets) } == ids("r", 0..<12))
        #expect(albums.map(\.lastStep) == filled.map(\.lastStep))
        #expect(albums.map(\.id) == filled.map(\.lastStep))
        // What flies is what the show let fly before (`FilledAlbum.shown`).
        #expect(albums.map(\.flying) == filled.map(\.shown))
        #expect(albums.allSatisfy { !$0.hidesPreview })
        #expect(albums.allSatisfy { $0.cover.count <= SortingShowAlbum.coverCandidates && !$0.cover.isEmpty })
    }

    /// The album's cover is the cover its suggestion's card showed, the one the result's stack
    /// lays down too; then its favourites and newest photos, as Photos shows an album.
    @Test func theCoverIsTheCardsCoverFirst() {
        let rome = AlbumProposal(id: AlbumistID("rome"), kind: .trip, title: "Rom", assetIDs: ids("r", 0..<12))
        let plan = plan([rome])
        let card = AssetID("r-7")
        let dates = Dictionary(uniqueKeysWithValues: (0..<12).map { (AssetID("r-\($0)"), Date(timeIntervalSince1970: Double($0) * 1000)) })
        let withCard = cast(plan, covers: [rome.id: card], dates: dates)
        #expect(withCard.first?.cover.first == card)
        // Without a card's cover: a favourite, then the newest.
        let withoutCard = cast(plan, dates: dates, favorites: [AssetID("r-2")])
        #expect(withoutCard.first?.cover == [AssetID("r-2"), AssetID("r-11"), AssetID("r-10"), AssetID("r-9")])
        // A card's cover the album does not hold (taken out meanwhile) is not used.
        let elsewhere = cast(plan, covers: [rome.id: AssetID("x-1")], dates: dates)
        #expect(elsewhere.first?.cover.contains(AssetID("x-1")) == false)
    }

    /// A personal suggestion (sensitive, its card hides the preview, or one the analysis does not
    /// know: `ResultCoverStack.personalSources`): its album shows "Vorschau ausgeblendet", none of
    /// its photos flies or lies on the pile, also not in another album of the plan.
    @Test func aPersonalAlbumShowsNoPhoto() {
        let doctor = AlbumProposal(id: AlbumistID("doc"), kind: .trip, title: "Arzt", assetIDs: ids("d", 0..<4))
        let country = AlbumProposal(id: AlbumistID("it"), kind: .placeCollection(.country), title: "Italien",
                                    assetIDs: ids("d", 0..<4).union(ids("i", 0..<4)))
        let plan = plan([doctor, country])
        let albums = cast(plan, covers: [doctor.id: AssetID("d-0"), country.id: AssetID("d-1")], personal: [doctor.id])
        let hidden = albums.first { $0.title == "Arzt" }
        #expect(hidden?.hidesPreview == true)
        #expect(hidden?.flying.isEmpty == true)
        #expect(hidden?.cover.isEmpty == true)
        #expect(hidden?.assets.count == 4, "the show still counts its photos")
        let italy = albums.first { $0.title == "Italien" }
        #expect(italy?.hidesPreview == false)
        #expect(italy.map { Set($0.flying).isDisjoint(with: ids("d", 0..<4)) } == true, "\(String(describing: italy?.flying))")
        #expect(italy.map { Set($0.cover).isDisjoint(with: ids("d", 0..<4)) } == true, "\(String(describing: italy?.cover))")
        #expect(italy?.cover.isEmpty == false)
    }

    /// Sensitive documents never show (`PreviewRank.sensitive`), neither flying nor as a cover;
    /// an album of only those shows "Vorschau ausgeblendet", as its suggestion's card did.
    @Test func sensitiveDocumentsNeverShow() {
        let cards = AlbumProposal(id: AlbumistID("cards"), kind: .trip, title: "Karten", assetIDs: ids("k", 0..<3))
        let mixed = AlbumProposal(id: AlbumistID("mixed"), kind: .trip, title: "Gemischt", assetIDs: ids("m", 0..<4))
        var ranks: [AssetID: PreviewRank] = [:]
        for id in ids("k", 0..<3) { ranks[id] = .sensitive }
        ranks[AssetID("m-0")] = .sensitive
        ranks[AssetID("m-1")] = .document
        let albums = cast(plan([cards, mixed]), covers: [mixed.id: AssetID("m-0")], ranks: ranks)
        let onlySensitive = albums.first { $0.title == "Karten" }
        #expect(onlySensitive?.hidesPreview == true)
        #expect(onlySensitive?.flying.isEmpty == true && onlySensitive?.cover.isEmpty == true)
        let other = albums.first { $0.title == "Gemischt" }
        #expect(other?.hidesPreview == false)
        #expect(other?.flying.contains(AssetID("m-0")) == false)
        #expect(other?.cover.contains(AssetID("m-0")) == false, "a card's cover that is a sensitive document")
        // A big cover is a photo (design rule 9): no screenshot or other document.
        #expect(other?.cover.contains(AssetID("m-1")) == false)
        #expect(other.map { Set($0.cover) } == [AssetID("m-2"), AssetID("m-3")])
    }

    /// The same photo in two albums (a country holds its trips) does not lead both covers when
    /// the second album has another photo.
    @Test func twoAlbumsDoNotLeadWithTheSamePhoto() {
        let trip = AlbumProposal(id: AlbumistID("t"), kind: .trip, title: "Rom", assetIDs: ids("r", 0..<3))
        let country = AlbumProposal(id: AlbumistID("it"), kind: .placeCollection(.country), title: "Italien",
                                    assetIDs: ids("r", 0..<3).union(ids("i", 0..<2)))
        let shared = AssetID("r-1")
        // The first album in plan order leads with the card's cover; the second one with another
        // of its photos, the shared one kept as a later candidate.
        let albums = cast(plan([trip, country]), covers: [trip.id: shared, country.id: shared])
        #expect(albums.count == 2)
        #expect(albums.first?.cover.first == shared)
        #expect(albums.last?.cover.first != shared)
        #expect(albums.last?.cover.contains(shared) == true, "kept as a later candidate")
        // With nothing else to show, the same photo may lead both.
        let same = AlbumProposal(id: AlbumistID("s"), kind: .placeCollection(.country), title: "Latium", assetIDs: ids("r", 1..<2))
        let both = cast(plan([trip, same]), covers: [trip.id: shared, same.id: shared])
        #expect(both.first { $0.title == "Latium" }?.cover == [shared])
        let rome = both.first { $0.title == "Rom" }
        #expect(rome?.cover.first == (both.first?.title == "Rom" ? shared : AssetID("r-0")))
    }

    @Test func emptyPlansAndStepsOutOfRange() {
        let empty = ChangePlan(id: AlbumistID("leer"), createdAt: Date(), confirmedAt: nil, status: .draft, baseline: [:],
                               baselineCollectionIDs: [], steps: [], conflicts: [], notes: [], resolvedKeys: [:])
        #expect(SortingShowAlbum.cast([], plan: empty).isEmpty)
        let stray = FilledAlbum(lastStep: 99, title: "Weg", assets: [AssetID("a")], shown: [AssetID("a")])
        let albums = SortingShowAlbum.cast([stray], plan: empty)
        #expect(albums.map(\.flying) == [[AssetID("a")]])
        #expect(albums.map(\.hidesPreview) == [false])
    }
}
