import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// How the app shows the starting points of the empty search (design wave 3, DS-13), read from
/// its sources as the app does not build on Linux. Which starting points and which photos is
/// decided in the core (`SearchStartingPointsTests`); here: the page shows them as photo tiles
/// once there are any and keeps its words before, a tap searches the tile's words as the chip
/// did, the tile is one element for VoiceOver with its name and count, the picture is a
/// `CoverPhoto` (sharp from the device or a calm placeholder), and the work runs off the main
/// thread on the search's own index.
@Suite("Search starting points in the app (source)")
struct SearchStartingPointsSourceTests {
    static let search = "App/Albumist/Views/SearchView.swift"
    static let tiles = "App/Albumist/Views/Search/SearchStartingPointsView.swift"
    static let model = "App/Albumist/Model/AppModel+Search.swift"

    /// The code of `path` (comments blanked, strings kept).
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ declarations: [String], in path: String) throws -> String {
        try #require(AppSource.body(of: declarations, in: try code(path)), "\(declarations) is not in \(path)")
    }

    /// `text` without any white space, so a check does not depend on how a line is broken.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    @Test func thePageShowsTheTilesOnceThereAreAnyAndItsWordsBefore() throws {
        let page = Self.squeezed(try Self.body(["struct SearchView", "private var startingPoints"], in: Self.search))
        // The tiles, a tap searches the chip's words.
        #expect(page.contains("if!starts.isEmpty{SearchStartingPointGrid(points:starts){suggestioninquery=suggestion.completion}}"))
        // Beside the tiles only papers stay words; before them the library's chips or the examples.
        #expect(page.contains("letwords=starts.isEmpty?featured:featured.filter{$0.kind==.document}"))
        #expect(page.contains("ifstarts.isEmpty&&featured.isEmpty{FlowLayout(spacing:Theme.Spacing.s){ForEach(examples.map"))
        #expect(page.contains("}elseif!words.isEmpty{FlowLayout(spacing:Theme.Spacing.s){ForEach(words){suggestionin"))
        #expect(page.contains("Button{query=suggestion.completion}"))
        // Every starting point keeps the identifier the UI tests tap.
        #expect(page.components(separatedBy: ".accessibilityIdentifier(\"search.example\")").count - 1 == 2)
    }

    /// The tiles follow every change of the facts (`AppModel.factsVersion`), also one of a
    /// photo's rank or date alone: the text step makes a photo a sensitive document without
    /// changing any count, and its tile must not keep showing it (review G2). A task cancelled
    /// meanwhile starts no more work and keeps nothing; both lists are shown together.
    @Test func theStartingPointsFollowEveryChangeOfTheFacts() throws {
        let view = Self.squeezed(try Self.code(Self.search))
        #expect(view.contains(".task(id:model.factsVersion){letwords=awaitmodel.featuredSearches()guard!Task.isCancelledelse{return}"
                              + "letmade=awaitmodel.searchStartingPoints()guard!Task.isCancelledelse{return}featured=wordsstarts=made}"))
        #expect(!view.contains("StartingPointsInputs"), "keyed on counts, which a change of rank leaves as they are")
        #expect(!view.contains("model.facts.count"))
        // The revision is observed, so a screen keyed on it works its part out again; only the
        // model counts it.
        let model = Self.squeezed(AppSource.code(try AppSource.read("App/Albumist/Model/AppModel.swift")))
        #expect(model.contains("private(set)varfactsVersion=0"))
        #expect(!model.contains("@ObservationIgnoredprivatevarfactsVersion"))
    }

    /// The revision counts every new value of the facts (review M6): the tiles, the covers of the
    /// history, the receipt and the preview, and the trip's timeline are made again only when it
    /// moves, so without the count in the facts' `didSet` none of them would be made again. It
    /// only grows: set back, it could come to a value a screen keyed on it had already seen.
    @Test func theFactsRevisionCountsEveryNewValueOfTheFacts() throws {
        let model = AppSource.code(try AppSource.read("App/Albumist/Model/AppModel.swift"))
        let facts = try #require(AppSource.body(of: "var facts: [AssetFacts] = []", in: model))
        let didSet = try #require(AppSource.body(of: "didSet", in: facts))
        #expect(Self.squeezed(didSet).contains("factsVersion&+=1"), "a new value of the facts leaves the revision as it was")
        // Assignments, not comparisons: only its start value.
        let sets = Self.squeezed(model).components(separatedBy: "factsVersion=").dropFirst().filter { !$0.hasPrefix("=") }
        #expect(sets.count == 1 && sets.first?.hasPrefix("0") == true, "the revision is set elsewhere than at its start")
    }

    /// The work is one search per starting point on the search's own index, off the main thread.
    @Test func theModelMakesThemOffTheMainThreadFromTheSearchIndex() throws {
        let model = Self.squeezed(try Self.body(["func searchStartingPoints()"], in: Self.model))
        #expect(model.contains("letindex=awaitsearchIndex()"))
        #expect(model.contains("letfacts=facts,ranks=previewRanks,dates=creationDates"))
        #expect(model.contains("returnawaitTask.detached(priority:.userInitiated){SearchStartingPoints.make(index:index,facts:facts,ranks:ranks,dates:dates,english:english)}.value"))
        // The chips' language (`featuredSearches`).
        #expect(model.contains("letenglish=!(Bundle.main.preferredLocalizations.first?.hasPrefix(\"de\")??true)"))
    }

    /// One element for VoiceOver: the name, the count as its value, a button; the picture a
    /// `CoverPhoto` with the album tile's corners and the chip's symbol on its calm placeholder,
    /// a wide strip at the accessibility sizes; the count in the note grey; no text on the photo.
    @Test func aTileIsOneButtonWithNameCountAndASharpPicture() throws {
        let tile = Self.squeezed(try Self.body(["struct SearchStartingPointTile", "var body"], in: Self.tiles))
        // The tile's action is main-actor isolated: the button calls it from its own closure (as
        // `AlbumUndoMenuItem` does), which compiles however SwiftUI types the button's action;
        // handed over as the action itself it would rely on that type.
        #expect(tile.contains("Button{action()}label:{"))
        #expect(!tile.contains("Button(action:action)"))
        #expect(tile.contains("CoverPhoto(ids:point.coverIDs,aspectRatio:typeSize.isAccessibilitySize?3:1,cornerRadius:Theme.Radius.photoTile,placeholderSymbol:SearchView.symbol(suggestion.kind))"))
        #expect(!tile.contains("hidesPreview"), "a starting point never needs \"Vorschau ausgeblendet\": its pictures may all be shown")
        #expect(!tile.contains(".overlay"), "no text on the photo")
        #expect(tile.contains("Text(\"\\(suggestion.count)\\(suggestion.count.formatted())Fotos\").font(.footnote).foregroundStyle(.noteText)"))
        #expect(tile.contains("Text(verbatim:suggestion.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).compactLineLimit(2)"))
        #expect(tile.contains(".buttonStyle(.plain).accessibilityElement(children:.ignore).accessibilityLabel(Text(verbatim:suggestion.label))"
                              + ".accessibilityValue(Text(\"\\(suggestion.count)\\(suggestion.count.formatted())Fotos\"))"
                              + ".accessibilityAddTraits(.isButton).accessibilityIdentifier(\"search.example\")"))
    }

    /// The albums tab's grid: two columns on the smallest iPhone, one at the accessibility sizes;
    /// the page's margins, none of its own. `AlbumGrid` is generic over its content, so its
    /// narrowest column is read through a concrete type: `AlbumGrid.minimumColumn` leaves the
    /// content type open and does not compile ("generic parameter 'Content' could not be
    /// inferred").
    @Test func theGridIsTheAlbumsTabsGrid() throws {
        let grid = Self.squeezed(try Self.body(["struct SearchStartingPointGrid", "var body"], in: Self.tiles))
        #expect(grid.contains("typeSize.isAccessibilitySize?[GridItem(.flexible(),alignment:.top)]:[GridItem(.adaptive(minimum:AlbumGrid<EmptyView>.minimumColumn,maximum:260),spacing:Theme.Spacing.l,alignment:.top)]"))
        #expect(!Self.squeezed(try Self.code(Self.tiles)).contains("AlbumGrid.minimumColumn"),
                "the generic AlbumGrid's column width without a content type does not compile")
        #expect(grid.contains("LazyVGrid(columns:columns,alignment:.leading,spacing:20)"))
        #expect(grid.contains("SearchStartingPointTile(point:point){choose(point.suggestion)}"))
        #expect(!grid.contains(".padding("))
    }
}
