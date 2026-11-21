import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// How "Reise anpassen" draws the trip as a timeline (design wave 3, DS-14), read from the app's
/// sources as the app does not build on Linux. What each day shows is decided in the core
/// (`TripTimelineTests`); the split, the merges, the undo and the waiting keep their own guards
/// (`TripWorkshopTests`, `TripChangeLedgerTests`). Here: the days come from the same days the
/// split takes, made off the main thread (review G6), every day after the first chooses where the
/// second trip begins as before (the UI tests' identifiers stay), the neighbours are sections of
/// their own at the ends, each part under its own heading (review G3), the photos are larger and
/// never a sensitive one, and the new words are in the catalog.
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

    static let model = "App/Albumist/Model/AppModel+TripTimeline.swift"

    /// The trip reads in the order of time, each part a section under its own heading (review
    /// G3): the trip before it ("Reise davor"), its days ("An einem Tag teilen", or "Diese Reise"
    /// for a trip of one day, which cannot be split) with the hint under them, the trip after it
    /// ("Reise danach"). What merging is for stands under the first merge row shown, with why it
    /// waits (review G4); the days between the trips are said in the merge rows.
    @Test func theTripReadsInTheOrderOfTimeEachPartUnderItsOwnHeading() throws {
        let body = Self.squeezed(try Self.body(["struct TripWorkshopView", "var body"], in: Self.workshop))
        #expect(body.contains("header(timeline?.days.count??days.count)changesSection(saysWhy:!mergeShown)iflettimeline{ifletbefore=around.before{neighbourSection(before,side:.before,gap:timeline.quietDaysFromBefore,explains:true)}daysSection(timeline)ifletafter=around.after{neighbourSection(after,side:.after,gap:timeline.quietDaysToAfter,explains:around.before==nil)}}"))
        #expect(!body.contains("timelineSection(") && !body.contains("splitSection(") && !body.contains("mergeSection("))
        // The days: their heading and the hint belong to them.
        let days = Self.squeezed(try Self.body(["func daysSection("], in: Self.workshop))
        #expect(days.contains("}header:{iftimeline.days.count>1{Text(\"AneinemTagteilen\")}else{Text(\"DieseReise\")}}footer:{iftimeline.days.count>1{Text(\"TippeaufdenTag,andemdiezweiteReisebeginnt.\")}}"))
        #expect(!days.contains("mergeButton(") && !days.contains("neighbour") && !days.contains("Pause"))
        // A neighbour: a heading of its own; under the first one shown why it waits and what it is for.
        let neighbour = Self.squeezed(try Self.body(["func neighbourSection("], in: Self.workshop))
        #expect(neighbour.contains("Section{mergeButton(other,side:side,gap:gap)}header:{ifside==.before{Text(\"Reisedavor\")}else{Text(\"Reisedanach\")}}footer:{ifexplains{VStack(alignment:.leading,spacing:Theme.Spacing.s){TripChangeWaitNote()Text(\"FüreineReisemitPause,zumBeispieleinWochenendezuHausezwischenzweiStationen.\")}}}"))
        let view = try Self.code(Self.workshop)
        #expect(view.components(separatedBy: "Für eine Reise mit Pause").count - 1 == 1, "what merging is for is said twice")
        // The days between the trips, in the merge row ("Island · 120 Fotos · 3 Tage dazwischen").
        let button = Self.squeezed(try Self.body(["func mergeButton("], in: Self.workshop))
        #expect(button.contains("letdetail:Textifletgap,gap>0{letbetween=Text(\"\\(gap)\\(gap.formatted())Tagedazwischen\")detail=Text(\"\\(title(other))·\\(photos)·\\(between)\")}else{detail=Text(\"\\(title(other))·\\(photos)\")}"))
        // Days without photos between two days, on the line.
        #expect(days.contains("TripTimelineGapRow(text:Text(\"\\(entry.quietDaysBefore)\\(entry.quietDaysBefore.formatted())TageohneFotos\"),line:lines.gap)"))
    }

    /// The timeline is made off the main thread, once for the trip, its neighbours and the facts
    /// (review G6: the body worked out every day, the trip's span and each neighbour's at every
    /// tap): from the days the split takes, in the same calendar. The split acts on the days
    /// shown; a day chosen on a timeline made anew is let go.
    @Test func theTimelineIsMadeOffTheMainThreadNotInTheBody() throws {
        let view = Self.squeezed(try Self.code(Self.workshop))
        for work in ["TripTimeline.days(", "TripTimeline.span(", "TripTimeline.content(", "TripTimeline.quietDays(", "funcquietDays("] {
            #expect(!view.contains(work), "\(work) in the sheet")
        }
        #expect(view.contains(".task(id:TimelineInputs(trip:proposal.id,photos:proposal.assetIDs.count,before:around.before?.id,after:around.after?.id,facts:model.factsVersion)){letmade=awaitmodel.tripTimeline(of:proposal,before:around.before,after:around.after)guard!Task.isCancelledelse{return}ifmade.days.map(\\.id)!=timeline?.days.map(\\.id){splitIndex=nil}timeline=made}"))
        let inputs = Self.squeezed(try Self.body(["struct TripWorkshopView", "private struct TimelineInputs"], in: Self.workshop))
        #expect(inputs == "{vartrip:AlbumistIDvarphotos:Intvarbefore:AlbumistID?varafter:AlbumistID?varfacts:Int}")
        #expect(view.contains("@Stateprivatevartimeline:TripTimeline.Content?"))
        // The split takes the days shown.
        #expect(view.contains("letindex=splitIndex,letentries=timeline?.days,letpreview=TripWorkshop.split(entries.map(\\.day),before:index,dates:model.creationDates){splitBar(preview,day:entries[index].day)"))
        let model = Self.squeezed(try Self.body(["func tripTimeline("], in: Self.model))
        #expect(model.contains("letfacts=factsByID,ranks=previewRanks,dates=creationDates,calendar=Calendar.current"))
        #expect(model.contains("returnawaitTask.detached(priority:.userInitiated){TripTimeline.content(of:photos,before:earlier,after:later,facts:facts,ranks:ranks,dates:dates,calendar:calendar)}.value"))
    }

    /// Every day after the first is the button that chooses it as the start of the second trip,
    /// as before (identifier, hint, selected trait); the first says "Beginn der Reise".
    @Test func everyDayAfterTheFirstChoosesWhereTheSecondTripBegins() throws {
        let row = Self.squeezed(try Self.body(["func dayRow("], in: Self.workshop))
        #expect(row.contains("ifentry.canStartNewTrip{Button{withAnimation(.smooth(duration:0.25)){splitIndex=splitIndex==index?nil:index}}label:{TripTimelineDayRow(entry:entry,note:selected?String(localized:\"NeueReiseabhier\"):nil,selected:selected,above:lines.above,below:lines.below)}.buttonStyle(.plain).accessibilityIdentifier(\"workshop.day\").accessibilityHint(Text(\"NeueReiseabdiesemTag\")).accessibilityAddTraits(selected?.isSelected:[])"))
        #expect(row.contains("TripTimelineDayRow(entry:entry,note:String(localized:\"BeginnderReise\"),selected:false,above:lines.above,below:lines.below)"))
        // The line breaks where the second trip begins, also over days without photos before it
        // (review G8): the core's rule (`TripTimeline.lines`), not one of the sheet's own.
        let days = Self.squeezed(try Self.body(["func daysSection("], in: Self.workshop))
        #expect(days.contains("letlines=TripTimeline.lines(entries,at:index,cut:splitIndex)"))
        #expect(days.contains("dayRow(entry,index:index,lines:lines)"))
        let view = try Self.code(Self.workshop)
        #expect(!view.contains("func lineAbove(") && !view.contains("func lineBelow("))
    }

    /// A neighbour's merge row shows its cover (never a sensitive photo, "Vorschau ausgeblendet"
    /// for one of nothing else), dimmed while it waits; at the accessibility sizes a strip above.
    /// The size of the covers of the history and the receipt, which grows with the text up to the
    /// same point (review G8: 64 pt without a cap).
    @Test func aNeighboursMergeRowShowsItsCover() throws {
        let button = Self.squeezed(try Self.body(["func mergeButton("], in: Self.workshop))
        #expect(button.contains("coverIDs:model.proposalCoverIDs(for:other),hidesPreview:model.previewHidden(for:other))"))
        let label = Self.squeezed(try Self.body(["struct MergeRowLabel", "var body"], in: Self.workshop))
        #expect(label.contains("AdaptiveStack(horizontalAlignment:.leading,verticalAlignment:.top,spacing:Theme.Spacing.m)"))
        #expect(label.contains("AlbumRowCover(ids:coverIDs,hidesPreview:hidesPreview,placeholderSymbol:\"airplane\").opacity(isEnabled?1:0.5)"))
        let view = try Self.code(Self.workshop)
        #expect(!view.contains("neighbourCover") && !view.contains("coverSide"), "a cover size of the sheet's own")
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
        // Every row of the timeline is laid out so; the neighbours are rows of their own sections.
        let section = try Self.body(["func daysSection("], in: Self.workshop)
        let rows = section.components(separatedBy: "TripTimelineGapRow(").count - 1
        #expect(rows == 1)
        #expect(section.components(separatedBy: ".tripTimelineRow()").count - 1 == rows)
        let day = try Self.body(["func dayRow("], in: Self.workshop)
        #expect(day.components(separatedBy: ".tripTimelineRow()").count - 1 == 2)
        #expect(!(try Self.body(["func neighbourSection("], in: Self.workshop)).contains(".tripTimelineRow()"))
        // A day, a chosen day, a gap: no ring for a neighbour any more.
        let marks = Self.squeezed(try Self.body(["struct TripTimelineGutter"], in: Self.timeline))
        #expect(marks.contains("enumMark{caseday,cut,none}") && marks.contains("typealiasLine=TripTimeline.Stroke"))
        let gap = Self.squeezed(try Self.body(["struct TripTimelineGapRow", "var body"], in: Self.timeline))
        #expect(gap.contains("TripTimelineRow(mark:.none,markY:nil,above:line,below:line)"))
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

    /// The new words, with English and their one and many forms, the number shown with a
    /// thousands separator (`%lld %@`: the integer picks the form, the text shows it).
    @Test(arguments: [("%lld %@ Tage ohne Fotos", "%2$@ Tag ohne Fotos", "%2$@ Tage ohne Fotos", "%2$@ day without photos", "%2$@ days without photos"),
                      ("%lld %@ Tage dazwischen", "%2$@ Tag dazwischen", "%2$@ Tage dazwischen", "%2$@ day in between", "%2$@ days in between")])
    func theNewWordsAreInTheCatalog(key: String, germanOne: String, germanOther: String, englishOne: String, englishOther: String) throws {
        let catalog = try StringCatalogTests.catalog()
        let entry = try #require(catalog[key], "\(key) is not in the catalog")
        func days(_ language: String) -> [String: Any]? {
            let localization = StringCatalogTests.localization(entry, language)
            #expect((localization?["stringUnit"] as? [String: Any])?["value"] as? String == "%#@days@", "\(language)")
            return (localization?["substitutions"] as? [String: Any])?["days"] as? [String: Any]
        }
        func plural(_ language: String, _ form: String) -> String? {
            let substitution = days(language)
            #expect(substitution?["argNum"] as? Int == 1 && substitution?["formatSpecifier"] as? String == "lld", "\(language)")
            let variations = (substitution?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            return ((variations?[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(plural("de", "one") == germanOne)
        #expect(plural("de", "other") == germanOther)
        #expect(plural("en", "one") == englishOne)
        #expect(plural("en", "other") == englishOther)
        // The ungrouped keys of before are gone.
        #expect(catalog[key.replacingOccurrences(of: "%lld %@", with: "%lld")] == nil)
    }
}
