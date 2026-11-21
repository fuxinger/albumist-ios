import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// How "Reise anpassen" draws the trip as a timeline (design wave 3, DS-14), read from the app's
/// sources as the app does not build on Linux. What each day shows is decided in the core
/// (`TripTimelineTests`); the split, the merges, the undo and the waiting keep their own guards
/// (`TripWorkshopTests`, `TripChangeLedgerTests`). Here: the days come from the same days the
/// split takes, every day after the first chooses where the second trip begins as before (the
/// UI tests' identifiers stay), the neighbours sit at the ends of the line with their merge rows,
/// the photos are larger and never a sensitive one, and the new words are in the catalog.
@Suite("Trip timeline in the app (source)")
struct TripTimelineSourceTests {
    static let workshop = "App/Albumist/Views/TripWorkshopView.swift"
    static let timeline = "App/Albumist/Views/Trips/TripTimelineViews.swift"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ declarations: [String], in path: String) throws -> String {
        try #require(AppSource.body(of: declarations, in: try code(path)), "\(declarations) is not in \(path)")
    }

    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The timeline takes the days the split takes, in the same calendar, and shows the trip
    /// before at the top and the trip after at the bottom, the days between them.
    @Test func theTimelineShowsTheDaysTheSplitTakesWithTheNeighboursAtItsEnds() throws {
        let view = Self.squeezed(try Self.code(Self.workshop))
        #expect(view.contains("TripWorkshop.days(of:proposal.assetIDs,dates:model.creationDates,calendar:.current)"))
        let section = Self.squeezed(try Self.body(["func timelineSection("], in: Self.workshop))
        #expect(section.contains("letentries=TripTimeline.days(days,facts:model.factsByID,ranks:model.previewRanks,dates:dates,calendar:.current)"))
        let before = try #require(section.range(of: "neighbourNode(before,side:.before)"))
        let daysAt = try #require(section.range(of: "ForEach(Array(entries.enumerated()),id:\\.element.id)"))
        let after = try #require(section.range(of: "neighbourNode(after,side:.after)"))
        #expect(before.lowerBound < daysAt.lowerBound && daysAt.lowerBound < after.lowerBound)
        // Days without photos between days and between the trips.
        #expect(section.contains("TripTimelineGapRow(text:Text(\"\\(entry.quietDaysBefore)TageohneFotos\"))"))
        #expect(section.components(separatedBy: "TripTimelineGapRow(text:Text(\"\\(gap)Tagedazwischen\"))").count - 1 == 2)
        // The body shows it where the split and merge sections were.
        let body = Self.squeezed(try Self.body(["struct TripWorkshopView", "var body"], in: Self.workshop))
        #expect(body.contains("header(days)changesSection(saysWhy:!mergeShown)timelineSection(days,around:around)"))
        #expect(!body.contains("splitSection(") && !body.contains("mergeSection("))
    }

    /// Every day after the first is the button that chooses it as the start of the second trip,
    /// as before (identifier, hint, selected trait); the first says "Beginn der Reise".
    @Test func everyDayAfterTheFirstChoosesWhereTheSecondTripBegins() throws {
        let row = Self.squeezed(try Self.body(["func dayRow("], in: Self.workshop))
        #expect(row.contains("ifentry.canStartNewTrip{Button{withAnimation(.smooth(duration:0.25)){splitIndex=splitIndex==index?nil:index}}label:{TripTimelineDayRow(entry:entry,note:selected?String(localized:\"NeueReiseabhier\"):nil,selected:selected,above:above,below:below)}.buttonStyle(.plain).accessibilityIdentifier(\"workshop.day\").accessibilityHint(Text(\"NeueReiseabdiesemTag\")).accessibilityAddTraits(selected?.isSelected:[])"))
        #expect(row.contains("TripTimelineDayRow(entry:entry,note:String(localized:\"BeginnderReise\"),selected:false,above:above,below:below)"))
        // The line breaks where the second trip begins.
        let above = Self.squeezed(try Self.body(["func lineAbove("], in: Self.workshop))
        #expect(above.hasPrefix("{ifsplitIndex==index{returnnil}"))
        let below = Self.squeezed(try Self.body(["func lineBelow("], in: Self.workshop))
        #expect(below.contains("returnsplitIndex==index+1?nil:.solid"))
    }

    /// A neighbour's merge row shows its cover (never a sensitive photo, "Vorschau ausgeblendet"
    /// for one of nothing else), dimmed while it waits; at the accessibility sizes a strip above.
    @Test func aNeighboursMergeRowShowsItsCover() throws {
        let button = Self.squeezed(try Self.body(["func mergeButton("], in: Self.workshop))
        #expect(button.contains("coverIDs:model.proposalCoverIDs(for:other),hidesPreview:model.previewHidden(for:other),coverSide:neighbourCover"))
        let label = Self.squeezed(try Self.body(["struct MergeRowLabel", "var body"], in: Self.workshop))
        #expect(label.contains("AdaptiveStack(horizontalAlignment:.leading,verticalAlignment:.top,spacing:Theme.Spacing.m)"))
        #expect(label.contains("CoverPhoto(ids:coverIDs,aspectRatio:typeSize.isAccessibilitySize?3:1,cornerRadius:Theme.Radius.tile,hidesPreview:hidesPreview,placeholderSymbol:\"airplane\").frame(width:typeSize.isAccessibilitySize?nil:coverSide).opacity(isEnabled?1:0.5)"))
    }

    /// A day: date, place, count and note as one element; up to three larger photos below it
    /// (the same size every day), never text on them; "Vorschau ausgeblendet" for a day of only
    /// sensitive documents.
    @Test func aDayShowsItsDatePlaceAndLargerPhotos() throws {
        let day = Self.squeezed(try Self.body(["struct TripTimelineDayRow", "var body"], in: Self.timeline))
        #expect(day.contains("Text(entry.day.start.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline)"))
        #expect(day.contains(".foregroundStyle(selected?AnyShapeStyle(Theme.accent):AnyShapeStyle(.noteText))}.fixedSize(horizontal:false,vertical:true).accessibilityElement(children:.combine)"))
        let detail = Self.squeezed(try Self.body(["struct TripTimelineDayRow", "private var detail"], in: Self.timeline))
        #expect(detail.contains("entry.places.formatted(.list(type:.and))"))
        let pictures = Self.squeezed(try Self.body(["struct TripTimelineDayRow", "private var pictures"], in: Self.timeline))
        #expect(pictures.contains("ifentry.hidesPreview{CoverPhoto(ids:[],aspectRatio:3,cornerRadius:Theme.Radius.tile,hidesPreview:true)}"))
        #expect(pictures.contains("count:TripTimeline.photosPerDay)"))
        #expect(pictures.contains("ForEach(entry.photos,id:\\.self){idinAssetThumbnail(id:id,side:140).aspectRatio(1,contentMode:.fill)"))
        #expect(pictures.contains(".accessibilityHidden(true)"))
        #expect(!pictures.contains(".overlay"), "no text on a photo")
    }

    /// The line is decoration (hidden from VoiceOver), in the full accent with Increase Contrast,
    /// and runs on from row to row (no separators, no insets above and below).
    @Test func theLineIsDecorationAndRunsOnFromRowToRow() throws {
        let gutter = Self.squeezed(try Self.body(["struct TripTimelineGutter", "var body"], in: Self.timeline))
        #expect(gutter.hasSuffix(".accessibilityHidden(true)}"))
        let color = Self.squeezed(try Self.body(["struct TripTimelineGutter", "private var lineColor"], in: Self.timeline))
        #expect(color.contains("contrast==.increased?Theme.accent:"))
        let rowModifier = Self.squeezed(try Self.body(["func tripTimelineRow()"], in: Self.timeline))
        #expect(rowModifier == "{listRowInsets(EdgeInsets(top:0,leading:Theme.Spacing.l,bottom:0,trailing:Theme.Spacing.l)).listRowSeparator(.hidden)}")
        let row = Self.squeezed(try Self.body(["struct TripTimelineRow", "var body"], in: Self.timeline))
        #expect(row.contains(".frame(maxWidth:.infinity,minHeight:44,alignment:.leading)"))
        // Every row of the timeline is laid out so.
        let section = try Self.body(["func timelineSection("], in: Self.workshop)
        let rows = section.components(separatedBy: "TripTimelineGapRow(").count - 1
        #expect(section.components(separatedBy: ".tripTimelineRow()").count - 1 == rows)
        for declaration in ["func dayRow(", "func neighbourNode("] {
            let body = try Self.body([declaration], in: Self.workshop)
            #expect(body.contains(".tripTimelineRow()"), "\(declaration)")
        }
    }

    /// The identifiers the UI tests use stay (`AlbumistFlowUITests`: split at "5. August", merge
    /// with the other part, "Rückgängig machen", the notes while the changes wait).
    @Test func theUITestsIdentifiersStay() throws {
        let view = try Self.code(Self.workshop)
        for identifier in ["\"workshop.day\"", "\"workshop.split\"", "\"workshop.done\"", "\"workshop.undoChange\"",
                           "\"workshop.merge.before\"", "\"workshop.merge.after\"", "\"workshop.busyNote\"", "\"workshop.split.busyNote\""] {
            #expect(view.contains(identifier), "\(identifier) is gone")
        }
    }

    /// The new words, with English and their one and many forms.
    @Test(arguments: [("%lld Tage ohne Fotos", "%lld Tag ohne Fotos", "%lld day without photos", "%lld days without photos"),
                      ("%lld Tage dazwischen", "%lld Tag dazwischen", "%lld day in between", "%lld days in between")])
    func theNewWordsAreInTheCatalog(key: String, germanOne: String, englishOne: String, englishOther: String) throws {
        let catalog = try StringCatalogTests.catalog()
        let entry = try #require(catalog[key], "\(key) is not in the catalog")
        func plural(_ language: String, _ form: String) -> String? {
            let localization = StringCatalogTests.localization(entry, language)
            let variations = (localization?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            return ((variations?[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(plural("de", "one") == germanOne)
        #expect(plural("de", "other") == key)
        #expect(plural("en", "one") == englishOne)
        #expect(plural("en", "other") == englishOther)
    }
}
