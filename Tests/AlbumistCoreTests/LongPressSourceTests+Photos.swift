import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The long press of photos (`LongPressSourceTests`).
extension LongPressSourceTests {
    /// A page whose photos are not the shared grid's: where its cell is (a declaration path in
    /// `path`), the long press it adds, the side its photos are shown at, and its photo's name.
    struct GridOfItsOwn {
        var path: String
        var declaration: [String]
        var call: String
        var side: Int
        var photo: String
        /// Extensions of the type in the same file (parts moved out of the struct's body for
        /// SwiftLint): no second side there either.
        var extensions: [String] = []
    }

    /// A page that shows photos: its type, the function that does a menu item, and how a tap on
    /// a photo opens it.
    struct PageWithPhotos {
        var path: String
        var type: String
        var perform: String
        var tap: String
    }

    // MARK: Photos

    /// Every grid of photos has the long press, at its place, off while it selects; the
    /// country's photos (the map's) are not touched here.
    @Test func everyPhotoGridHasTheLongPress() throws {
        // "Unsortiert" and a suggestion's photos are one grid (`PhotoGrid`, design wave 3,
        // DS-06b): its photo has the long press at the page's place, off while it selects, and
        // lifts the image the photo asked for, at the side it is shown at (three, five or seven
        // in a row), never at a second side.
        let shared = try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.photoGrid)
        #expect(shared.contains(".photoMenu(id, place: place, side: side, gridWidth: width, selecting: selecting, available: available)"),
                "\(shared)")
        #expect(shared.contains("AssetThumbnail(id: id, side: side)"), "\(shared)")
        let gridCode = try Self.code(Self.photoGrid)
        #expect(gridCode.components(separatedBy: "AssetThumbnail(").count - 1 == 1, "a second thumbnail in the grid")
        #expect(Self.count(#"AssetThumbnail\(id: id, side: \d"#, in: gridCode) == 0, "a side in numbers")
        let library = Self.squeezed(try Self.body(["struct LibraryView"], in: Self.library))
        #expect(library.contains("place:.unsorted,selecting:selecting,"), "\(library)")
        let suggestion = Self.squeezed(try Self.body(["struct ProposalPhotosView"], in: Self.suggestions))
        #expect(suggestion.contains("place:.suggestion,selecting:selecting,") && suggestion.contains("available:!disabled&&isCurrent,"),
                "\(suggestion)")
        for (path, type) in [(Self.library, "struct LibraryView"), (Self.library, "extension LibraryView"),
                             (Self.suggestions, "struct ProposalPhotosView")] {
            let page = try Self.body([type], in: path)
            #expect(!page.contains("AssetThumbnail(") && !page.contains(".photoMenu("), "\(path): photos of its own")
        }
        let grids = [
            GridOfItsOwn(path: Self.albums, declaration: ["struct AlbumScreen", "private func tile("],
                         call: ".photoMenu(photo, place: .album, side: Self.photoSide)", side: 110, photo: "photo"),
            GridOfItsOwn(path: Self.search, declaration: ["struct SearchView", "private func thumbnail("],
                         call: ".photoMenu(id, place: .search, side: Self.photoSide, available: hit != nil)", side: 110, photo: "id",
                         extensions: ["extension SearchView"]),
        ]
        for grid in grids {
            let cell = try Self.body(grid.declaration, in: grid.path)
            #expect(cell.contains(grid.call), "\(grid.path): \(cell)")
            // The lifted photo is the image the cell asked for: the same side (review C of design
            // wave 2, M2).
            let type = try Self.body([grid.declaration[0]], in: grid.path)
            #expect(type.contains("private static let photoSide: CGFloat = \(grid.side)"), "\(grid.path)")
            #expect(type.contains("AssetThumbnail(id: \(grid.photo), side: Self.photoSide)"), "\(grid.path)")
            #expect(!type.contains("AssetThumbnail(id: \(grid.photo), side: \(grid.side))"), "\(grid.path): a second side")
            for declaration in grid.extensions {
                let parts = try Self.body([declaration], in: grid.path)
                #expect(!parts.contains("AssetThumbnail(id: \(grid.photo), side: \(grid.side))"), "\(declaration): a second side")
            }
        }
        let country = try Self.code("App/Albumist/Views/CountryPhotosView.swift")
        #expect(!country.contains(".photoMenu("), "the map's files are not this strand's")
    }

    /// One mechanism for every photo: Apple's long press with the photo lifted larger, the same
    /// items as VoiceOver's actions of the photo, "Ansehen" left out there (the photo's own). The
    /// lifted photo is the image its cell shows, at once, as large as it is sharp (review C of
    /// design wave 2, M2): from the thumbnails' memory, never a cover (no placeholder where the
    /// cell shows a photo, no lift counted as a cover), worked out in its own body (M5).
    @Test func thePhotosLongPressLiftsThePhotoAndGivesVoiceOverTheItems() throws {
        let press = try Self.body(["private struct PhotoLongPress", "func body(content: Content)"], in: Self.photoMenu)
        // With a menu now: the menu, the photo lifted, the same items as the photo's actions.
        // Without one (the grid selects, the photo cannot open), none of them at all:
        // `aPhotoWithoutAMenuHasNoContextMenuAtAll` (review C2 of design wave 2, N1).
        let squeezedPress = Self.squeezed(press)
        #expect(squeezedPress.contains("ifoffered{content.contextMenu{items(forVoiceOver:false)}"
                                       + "preview:{PhotoPreview(id:id,side:side,gridWidth:gridWidth)}"
                                       + ".accessibilityActions{items(forVoiceOver:true)}}"), "\(squeezedPress)")
        let offered = Self.squeezed(try Self.body(["private struct PhotoLongPress", "private var offered: Bool"], in: Self.photoMenu))
        #expect(offered == "{PhotoMenu.isOffered(selecting:selecting,available:available)}", "\(offered)")
        let items = try Self.body(["struct PhotoMenuItems", "var body: some View"], in: Self.photoMenu)
        #expect(items.contains("menu.accessibilityItems"))
        #expect(!(try Self.body(["struct PhotoMenuItems"], in: Self.photoMenu)).contains("@Environment("),
                "the items read nothing from the environment: the long press hands the model in")
        let handed = Self.squeezed(try Self.body(["private struct PhotoLongPress", "private func items("], in: Self.photoMenu))
        #expect(handed.contains("PhotoMenuItems(model:model,"), "\(handed)")
        #expect(items.contains("PhotoMenu(place: place"))
        #expect(!(try Self.body(["private struct PhotoLongPress"], in: Self.photoMenu)).contains("factsByID"),
                "every cell tied to the facts")
        let lifted = try Self.body(["struct PhotoPreview"], in: Self.photoMenu)
        // In a zooming grid the sharpest image kept in memory: the cell's, one of the grid's other
        // sizes, or the one a grid showed last; at least as large as at three in a row (review
        // L9). Album and search lift their cell's own thumbnail, as before.
        let sharpest = Self.squeezed(try Self.body(["struct PhotoPreview", "private var sharpestInMemory"], in: Self.photoMenu))
        #expect(sharpest.contains("guardletgridWidthelse{returncache.cachedThumbnail(for:id,side:side)}"),
                "album and search as before: \(sharpest)")
        #expect(sharpest.contains("letsides:[CGFloat]=[side]+PhotoGridZoom.sides(width:Double(gridWidth)).map{CGFloat($0)}"),
                "\(sharpest)")
        #expect(sharpest.contains("varimages=sides.compactMap{cache.cachedThumbnail(for:id,side:$0)}"
                                  + "ifletlast=cache.thumbnailInMemory(for:id){images.append(last)}"), "\(sharpest)")
        #expect(sharpest.contains("returnPhotoGridZoom.sharpestKept(pixels).map{images[$0]}"), "\(sharpest)")
        #expect(Self.squeezed(lifted).contains("letlifted=gridWidth.map{CGFloat(PhotoGridZoom.liftSide(cell:Double(side),"
                                               + "gridWidth:Double($0)))}??side"), "the floor of a zooming grid: \(lifted)")
        #expect(Self.squeezed(lifted).contains("scale:Double(displayScale),cellSide:Double(lifted))"), "\(lifted)")
        #expect(Self.squeezed(lifted).contains(".frame(width:lifted,height:lifted)"), "\(lifted)")
        for request in ["image(for:", "requestImage(", "PHImageManager", "largeImage("] {
            #expect(!lifted.contains(request), "the lift asks Photos itself: \(request)")
        }
        #expect(lifted.contains("PhotoMenu.liftSize(imageWidth:"))
        #expect(lifted.contains("@Environment(\\.displayScale)"))
        #expect(lifted.contains("AssetThumbnail(id: id, side: side)"), "gone from memory: as large as its cell, asked for again")
        #expect(!lifted.contains("CoverPhoto"), "a placeholder where the cell shows a photo, a lift counted as a cover")
        #expect(!lifted.contains("@Environment(AppModel"), "the system draws the lifted photo apart: everything handed in")
        // Sharp by the covers' rule, the same 70 % (`ThumbnailRequest.sharpShare`).
        let thumbnails = AppSource.code(try ThumbnailSource.read(), keepStrings: true)
        #expect(thumbnails.contains("static let sharpShare: CGFloat = \(PhotoMenu.sharpShare)"))
    }

    /// A photo without a menu now (the grid selects, the photo cannot open) gets no context menu
    /// and no actions at all, not a menu closure that returns nothing beside a preview of its
    /// own: whether such a menu still lifts the photo is not documented (UIKit shows a preview
    /// without actions), and a lift would take the press that ticks a photo (review C2 of design
    /// wave 2, N1). The switch rebuilds the photo's cell, unseen: not animated (the pages toggle
    /// "Auswählen" in `withAnimation`, which would cross-fade every photo on screen), and the
    /// rebuilt thumbnail shows its photo at once (`aThumbnailStartsWithTheImageInMemory`).
    @Test func aPhotoWithoutAMenuHasNoContextMenuAtAll() throws {
        let press = Self.squeezed(try Self.body(["private struct PhotoLongPress", "func body(content: Content)"], in: Self.photoMenu))
        // One branch with all of the long press, the other the photo as it is.
        let withMenu = try #require(press.range(of: "{Group{ifoffered{"), "\(press)")
        let without = try #require(press.range(of: "}else{content}}"), "\(press)")
        #expect(withMenu.upperBound <= without.lowerBound, "\(press)")
        for modifier in [".contextMenu{", ".accessibilityActions{"] {
            let found = press.ranges(of: modifier)
            #expect(found.count == 1, "\(modifier) \(found.count) times: \(press)")
            #expect(found.allSatisfy { withMenu.upperBound <= $0.lowerBound && $0.upperBound <= without.lowerBound },
                    "\(modifier) outside the branch with a menu: \(press)")
        }
        #expect(!press.contains("{ifoffered{items("), "a menu switched off by a closure that returns nothing: \(press)")
        // Not animated, whichever page toggles it and however it does.
        #expect(press.hasSuffix("}else{content}}.transaction(value:offered){$0.animation=nil}}"), "\(press)")
    }

    /// A thumbnail made anew starts with the image the thumbnails' memory holds for it, so a cell
    /// that is rebuilt (a photo's long press is switched on or off as "Auswählen" toggles; review
    /// C2 of design wave 2, N1) shows its photo from its first frame, not its grey ground until
    /// its task has read the memory again. Only from memory: its initializer asks Photos nothing
    /// (the task asks, as before), and every caller keeps the labels it has.
    @Test func aThumbnailStartsWithTheImageInMemory() throws {
        let made = try Self.body(["struct AssetThumbnail", "init(id: AssetID, side: CGFloat = 80, anchor: Alignment = .center)"],
                                 in: Self.thumbnails)
        let seeded = Self.squeezed(made)
        #expect(seeded.contains("letkept=ThumbnailCache.shared.cachedThumbnail(for:id,side:side)"), "\(seeded)")
        #expect(seeded.contains("_image=State(initialValue:kept)"), "\(seeded)")
        #expect(seeded.contains("_loadedID=State(initialValue:kept==nil?nil:id)"), "\(seeded)")
        for request in ["image(for:", "await", "Task", "requestImage(", "lookUp", "cover(for:", "largeImage(", "asset("] {
            #expect(!made.contains(request), "the initializer asks Photos: \(request)")
        }
        // What is not in memory the task asks for, as before; the shown image is the photo's own.
        // The task follows the side too (design wave 3, H11): a cell drawn at another size (a
        // grid zoomed to other columns) asks for its photo at that size.
        let shown = try Self.body(["struct AssetThumbnail", "var body: some View"], in: Self.thumbnails)
        #expect(shown.contains(".task(id: Slot(id: id, side: side)) {") && shown.contains("await ThumbnailCache.shared.image(for: id, side: side)"))
        #expect(shown.contains("if let image, loadedID == id {"))
        // Every caller keeps working: `id:`, then `side:` and `anchor:` where it gives them.
        var callers = 0
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            for arguments in AppSource.calls(of: "AssetThumbnail(", in: try AppSource.read(path)) {
                callers += 1
                let labels = Self.labels(arguments)
                let order = labels.compactMap { ["id", "side", "anchor"].firstIndex(of: $0) }
                #expect(labels.first == "id" && order.count == labels.count && order == order.sorted() && Set(order).count == order.count,
                        "\(path): AssetThumbnail(\(arguments))")
            }
        }
        #expect(callers >= 10, "\(callers) callers")
    }

    /// Each photo item goes the place's way: "Ansehen" as the tap opens it, "Zu Album
    /// hinzufügen …" the sheet that leads to the preview, ignoring as everywhere (with
    /// "Widerrufen" on the screen), taking a photo out of a suggestion asked first.
    @Test func thePhotosMenuGoesTheWaysThatExist() throws {
        let items = try Self.code(Self.photoMenu)
        #expect(items.contains("model.ignore([id])") && items.contains("model.unignore([id])"))
        #expect(items.contains("Label(\"Zu Album hinzufügen …\""))
        #expect(items.contains("Button(role: .destructive) { perform(.removeFromSuggestion) }"))
        for bypass in ["removeFromProposal(", "manualPlan(", "execute(", "ShareLink", "Teilen"] {
            #expect(!items.contains(bypass), "\(bypass) in the photo's menu")
        }
        // The tap and "Ansehen" open the photo the same way; "Zu Album hinzufügen …" the sheet.
        let places = [
            PageWithPhotos(path: Self.library, type: "struct LibraryView", perform: "private func perform(", tap: "open(id)"),
            PageWithPhotos(path: Self.search, type: "struct SearchView", perform: "private func perform(", tap: "open(id, from: key)"),
            PageWithPhotos(path: Self.albums, type: "struct AlbumScreen", perform: "private func perform(", tap: "open(photo, ids: ids)"),
        ]
        for place in places {
            let type = try Self.body([place.type], in: place.path)
            let perform = try Self.body([place.type, place.perform], in: place.path)
            #expect(perform.contains("case .view: \(place.tap)"), "\(place.path): \(perform)")
            #expect(perform.contains("case .addToAlbum: addingToAlbum = [id]")
                    || perform.contains("case .addToAlbum: addingToAlbum = [photo]"), "\(place.path): \(perform)")
            #expect(type.components(separatedBy: place.tap).count - 1 >= 2, "\(place.path): the tap opens it the same way")
            #expect(type.contains("AddToAlbumSheet(assets: addingToAlbum ?? [])"), "\(place.path)")
            #expect(type.contains("IgnoreUndoBar()"), "\(place.path): „Widerrufen“ after „Ignorieren“")
        }
        // A suggestion's photo: asked first, on the suggestion's scroll view beside the question
        // for several (not from the middle of all its days; review C of design wave 2, M1), then
        // taken out as "Auswählen" takes several out.
        let photos = try Self.body(["struct ProposalPhotosView"], in: Self.suggestions)
        #expect(!photos.contains(".confirmationDialog("), "asked from the middle of all its days")
        #expect(photos.contains("case .removeFromSuggestion: askToRemove(id)"))
        #expect(photos.contains("case .view: open(id)"))
        let detail = Self.squeezed(try Self.body(["struct ProposalDetailView", "var body: some View"], in: Self.suggestions))
        #expect(detail.contains("}askToRemove:{idinremovingPhoto=id}"), "\(detail)")
        let several = try #require(detail.range(of: ".confirmationDialog(\"FotosausdiesemVorschlagentfernen?\""))
        let one = try #require(detail.range(of: ".photoRemovalQuestion($removingPhoto){idinguardisCurrentelse{return}"
                                                + "Task{awaitmodel.removeFromProposal([id],proposal:proposal)}}"), "\(detail)")
        #expect(several.lowerBound < one.lowerBound)
        let question = try Self.code(Self.photoQuestion)
        #expect(question.contains(".confirmationDialog(\"Foto aus diesem Vorschlag entfernen?\""))
        #expect(question.contains("Button(\"Entfernen\", role: .destructive) { remove(id) }"))
        #expect(question.contains("Text(\"Es kommt nicht in dieses Album. In deiner Mediathek und in anderen Vorschlägen bleibt es.\")"))
    }

    /// A suggestion that went while its page is open (made from its card, split, merged, made
    /// anew) still shows its photos as it was opened, but none can be taken out of it any more:
    /// its photos' long press offers nothing, "Auswählen" and "N aus Vorschlag entfernen" wait
    /// as the page's other buttons do, and both questions take nothing out once answered, as
    /// the override would be kept for a suggestion no one has (review C2 of design wave 2, N4).
    @Test func nothingIsTakenOutOfASuggestionThatWent() throws {
        let photos = try Self.body(["struct ProposalPhotosView"], in: Self.suggestions)
        #expect(photos.contains("    var isCurrent: Bool\n"), "\(photos)")
        let grid = try Self.body(["struct ProposalPhotosView", "var body: some View"], in: Self.suggestions)
        #expect(grid.contains("available: !disabled && isCurrent,"), "\(grid)")
        let cell = try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.photoGrid)
        #expect(cell.contains("available: available)"), "\(cell)")
        let detail = Self.squeezed(try Self.body(["struct ProposalDetailView", "var body: some View"], in: Self.suggestions))
        #expect(detail.contains("ProposalPhotosView(days:days,selecting:selecting,selected:$selected,hidden:photosHidden,"
                                + "disabled:busy,isCurrent:isCurrent)"), "\(detail)")
        // Both questions: for the photos ticked with "Auswählen", and for one photo's long press.
        let several = try #require(detail.range(of: "Button(\"Entfernen\",role:.destructive){"), "\(detail)")
        #expect(detail[several.upperBound...].hasPrefix("guardisCurrentelse{return}letchosen=selected"), "\(detail)")
        // The selection ends as the photos leave the page, before the suggestion is matched
        // again: the selection's bar stayed over 5 s while that ran (UI run 45567033486).
        #expect(detail[several.upperBound...].hasPrefix("guardisCurrentelse{return}letchosen=selected"
                                                        + "withAnimation(.snappy){selected=[]selecting=false}"
                                                        + "Task{awaitmodel.removeFromProposal(chosen,proposal:proposal)}}"), "\(detail)")
        let one = try #require(detail.range(of: ".photoRemovalQuestion($removingPhoto){idin"), "\(detail)")
        #expect(detail[one.upperBound...].hasPrefix("guardisCurrentelse{return}Task{"), "\(detail)")
        // Their buttons wait, as "Nicht jetzt" and the main button do (only "Fertig" stays).
        #expect(detail.contains(".disabled(!selecting&&(busy||!isCurrent||days.isEmpty||photosHidden))"), "\(detail)")
        #expect(detail.contains(".disabled(selected.isEmpty||!isCurrent)"), "\(detail)")
        // One rule of the page for what went: the same id with the same photos.
        let current = Self.squeezed(try Self.body(["struct ProposalDetailView", "private var isCurrent: Bool"], in: Self.suggestions))
        #expect(current == "{model.proposals.contains{$0.id==proposal.id&&$0.assetIDs==proposal.assetIDs}}", "\(current)")
    }

    /// A photo the user ignored offers "Nicht mehr ignorieren" also without a state of its own
    /// (an album's photo the analysis has not read yet: "Ignorieren" gives it none): the model
    /// reads the photos the user ignored (`PhotoMenu.isIgnored`), and keeps them observed, so the
    /// menu follows a tap at once (review C of design wave 2, L6).
    @Test func anIgnoredPhotoWithoutAStateOffersTheWayBack() throws {
        let ignored = Self.squeezed(try Self.body(["func isIgnored(_ id: AssetID) -> Bool"], in: Self.model))
        #expect(ignored == "{PhotoMenu.isIgnored(id,ignored:ignoredIDs,state:states[id])}", "\(ignored)")
        let model = try AppSource.read("App/Albumist/Model/AppModel.swift")
        #expect(model.contains("    private(set) var ignoredIDs: Set<AssetID> = [] // Design W2 H7"))
        #expect(!model.contains("@ObservationIgnored private var ignoredIDs"), "the menu would not follow a tap")
    }
}
