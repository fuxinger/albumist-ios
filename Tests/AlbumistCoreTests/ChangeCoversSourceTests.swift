import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// How the history ("Verlauf und Rückgängig") and the receipt ("Änderungen") show the covers of
/// the changes (design wave 3, DS-15), read from the app's sources as the app does not build on
/// Linux. Which photos each cover tries is decided in the core (`PlanCoversTests`); the receipt's
/// words keep their guard (`ReceiptAlbumRowTests`), its ways back and confirmations theirs
/// (`DeleteQuestionNoteTests`, `FullAccessForChangesTests`). Here: the covers are worked out off
/// the main thread and again when the facts change (the photos' dates and ranks with them, keyed
/// on the facts' revision); each history row and each
/// album of the receipt shows its own, larger than the 44 pt pictures of before and laid out as
/// the tab "Alben" lays out albums; the rows stay what VoiceOver and the UI tests know.
@Suite("Covers of the history and the receipt in the app (source)")
struct ChangeCoversSourceTests {
    static let settings = "App/Albumist/Views/SettingsView.swift"
    static let receipt = "App/Albumist/Views/PlanReceiptView.swift"
    static let covers = "App/Albumist/Views/History/ChangeCoverViews.swift"
    static let model = "App/Albumist/Model/AppModel+History.swift"
    static let review = "App/Albumist/Views/PlanReviewView.swift"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ declarations: [String], in path: String) throws -> String {
        try #require(AppSource.body(of: declarations, in: try code(path)), "\(declarations) is not in \(path)")
    }

    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    // MARK: The history

    /// The history works out the cover of each change it lists off the main thread, again when
    /// the changes or the facts change (the photos' dates and ranks are made from them: a photo
    /// the analysis finds to be a sensitive document leaves its cover at once), and hands each
    /// row its own; the change cut off on its way shows what it sets out to add.
    @Test func theHistoryWorksOutACoverForEachChange() throws {
        let view = Self.squeezed(try Self.body(["struct HistoryView", "var body"], in: Self.settings))
        #expect(view.contains(".task(id:model.changeCoverInputs(model.history,interrupted:model.interruptedPlan)){letmade=awaitmodel.historyCovers(model.history,interrupted:model.interruptedPlan)guard!Task.isCancelledelse{return}covers=made}"))
        #expect(view.contains("InterruptedHistoryRow(plan:interrupted,cover:covers[interrupted.id])"))
        #expect(view.contains("HistoryRow(plan:plan,cover:covers[plan.id])"))
        let inputs = Self.squeezed(try Self.body(["func changeCoverInputs("], in: Self.model))
        #expect(inputs.contains("ChangeCoverInputs(plans:plans.map(\\.id)+(interrupted.map{[$0.id]}??[]),facts:factsVersion)"))
        let history = Self.squeezed(try Self.body(["func historyCovers("], in: Self.model))
        // Before the first facts of a launch every photo would count as an ordinary one: no cover
        // until they say which are sensitive documents.
        #expect(history.hasPrefix("{guard!facts.isEmptyelse{return[:]}"))
        #expect(history.contains("Task.detached(priority:.userInitiated)"))
        #expect(history.contains("covers[plan.id]=PlanCovers.mosaic(of:plan,dates:dates,ranks:ranks)"))
        #expect(history.contains("covers[interrupted.id]=PlanCovers.mosaic(of:interrupted,applied:false,dates:dates,ranks:ranks)"))
    }

    /// What the covers are keyed on is cheap to keep and compare: the changes and the facts'
    /// revision (`AppModel.factsVersion`), never the dictionaries of all dates and ranks, which
    /// SwiftUI would hold on to while the screen is open (a memory warning freed nothing there)
    /// and compare entry by entry once the model made them anew (review G7).
    @Test func theCoversAreKeyedOnTheFactsRevisionNotOnTheirDictionaries() throws {
        let inputs = Self.squeezed(try Self.body(["struct ChangeCoverInputs"], in: Self.model))
        #expect(inputs == "{varplans:[AlbumistID]varfacts:Int}")
        let model = Self.squeezed(try Self.code(Self.model))
        #expect(!model.contains("dates:creationDates,ranks:previewRanks)"), "a task id that holds all dates and ranks")
    }

    /// A row of the history: the change's cover beside when and what it did, "Rückgängig gemacht"
    /// below them (the cover takes the room it had beside them); still the one button that opens
    /// the receipt, under the name the UI tests tap.
    @Test func aHistoryRowShowsTheCoverOfItsChange() throws {
        let row = Self.squeezed(try Self.body(["struct HistoryRow", "var body"], in: Self.settings))
        #expect(row.hasPrefix("{PushLink(.receipt(PlanToken(plan))){AdaptiveStack(spacing:Theme.Spacing.m){ChangeCover(mosaic:cover,symbol:PlanReceipt.Kind(plan).coverSymbol)VStack(alignment:.leading,spacing:2){"))
        #expect(row.contains("ifmodel.undonePlans.contains(plan.id){Label(\"Rückgängiggemacht\",systemImage:\"arrow.uturn.backward\").font(.footnote).foregroundStyle(.noteText)}"))
        #expect(row.contains("}.fixedSize(horizontal:false,vertical:true)}.padding(.vertical,Theme.Spacing.xs)}"))
        #expect(row.hasSuffix(".accessibilityIdentifier(\"history.row\")}"))
    }

    /// The change cut off on its way shows the cover of what it sets out to do beside when and how
    /// far it got, read as one; its buttons stay as they were.
    @Test func theInterruptedChangeShowsItsCover() throws {
        let row = Self.squeezed(try Self.body(["struct InterruptedHistoryRow", "var body"], in: Self.settings))
        #expect(row.contains("AdaptiveStack(spacing:Theme.Spacing.m){ChangeCover(mosaic:cover,symbol:PlanReceipt.Kind(plan).coverSymbol)VStack(alignment:.leading,spacing:2){"))
        #expect(row.contains("}.fixedSize(horizontal:false,vertical:true).accessibilityElement(children:.combine)}"))
        #expect(row.contains("ViewThatFits(in:.horizontal){HStack(spacing:Theme.Spacing.l){buttons}VStack(alignment:.leading,spacing:Theme.Spacing.s){buttons}}"))
    }

    /// A change's cover is laid out as a folder's tile shows its albums, without an empty place:
    /// one album, two side by side, one large and two small, four; a strip across the row at the
    /// accessibility text sizes. With no album to show: "Vorschau ausgeblendet" or the change's
    /// symbol, the symbol only once the cover is worked out. Decoration for VoiceOver.
    @Test func aChangesCoverIsLaidOutAsAFoldersTile() throws {
        let cover = Self.squeezed(try Self.body(["struct ChangeCover:", "var body"], in: Self.covers))
        #expect(cover.contains("iftypeSize.isAccessibilitySize{strip(tiles)}else{square(tiles,side:min(side,ChangeCoverMetrics.largestSide))}"))
        #expect(cover.hasSuffix(".clipShape(RoundedRectangle(cornerRadius:Theme.Radius.tile,style:.continuous)).accessibilityHidden(true)}"))
        let square = Self.squeezed(try Self.body(["struct ChangeCover:", "func square("], in: Self.covers))
        for layout in ["case0:whole(aspectRatio:1).frame(width:side,height:side)",
                       "case1:tile(tiles[0],width:side,height:side)",
                       "case2:HStack(spacing:gap){tile(tiles[0],width:half,height:side)tile(tiles[1],width:half,height:side)}",
                       "case3:HStack(spacing:gap){tile(tiles[0],width:half,height:side)VStack(spacing:gap){tile(tiles[1],width:half,height:half)tile(tiles[2],width:half,height:half)}}",
                       "default:Grid(horizontalSpacing:gap,verticalSpacing:gap){GridRow{tile(tiles[0],width:half,height:half)tile(tiles[1],width:half,height:half)}GridRow{tile(tiles[2],width:half,height:half)tile(tiles[3],width:half,height:half)}}"] {
            #expect(square.contains(layout), "\(layout)")
        }
        let whole = Self.squeezed(try Self.body(["struct ChangeCover:", "func whole("], in: Self.covers))
        #expect(whole.contains("CoverPhoto(ids:[],aspectRatio:aspectRatio,cornerRadius:0,hidesPreview:mosaic?.hidden??false,placeholderSymbol:mosaic==nil?nil:symbol)"))
        let tile = Self.squeezed(try Self.body(["struct ChangeCover:", "func tile("], in: Self.covers))
        #expect(tile.contains("CoverPhoto(ids:ids,aspectRatio:width/max(height,1),cornerRadius:0).frame(width:width,height:height)"))
        let strip = Self.squeezed(try Self.body(["struct ChangeCover:", "func strip("], in: Self.covers))
        #expect(strip.contains("iftiles.isEmpty{whole(aspectRatio:ChangeCoverMetrics.stripAspectRatio)}"))
        #expect(strip.contains("CoverPhoto(ids:tiles[index],aspectRatio:ChangeCoverMetrics.stripAspectRatio/CGFloat(tiles.count),cornerRadius:0)"))
        // The symbols: albums, a removed album, the way back.
        let symbol = Self.squeezed(try Self.body(["extension PlanReceipt.Kind", "var coverSymbol"], in: Self.covers))
        #expect(symbol.contains("case.created:\"rectangle.stack\"case.removed:\"rectangle.stack.badge.minus\"case.undone:\"arrow.uturn.backward\""))
        // Larger than the 44 pt pictures the rows had, growing with the text up to a point.
        let metrics = Self.squeezed(try Self.body(["enum ChangeCoverMetrics"], in: Self.covers))
        #expect(metrics.contains("staticletside:CGFloat=72") && metrics.contains("staticletlargestSide:CGFloat=96"))
        #expect(metrics.contains("staticletgap:CGFloat=2") && metrics.contains("staticletstripAspectRatio:CGFloat=3"))
    }

    // MARK: The receipt

    /// The receipt works out the cover of each album off the main thread, again when the facts
    /// change (`ChangeCoverInputs`), and hands each row its own.
    @Test func theReceiptWorksOutACoverForEachAlbum() throws {
        let view = Self.squeezed(try Self.body(["struct PlanReceiptView", "var body"], in: Self.receipt))
        #expect(view.contains(".task(id:model.changeCoverInputs([plan])){letmade=awaitmodel.receiptCovers(for:plan)guard!Task.isCancelledelse{return}covers=made}"))
        let albums = Self.squeezed(try Self.body(["struct PlanReceiptView", "func albums("], in: Self.receipt))
        #expect(albums.contains("ReceiptAlbumRow(album:album,title:title(album),kind:kind,cover:cover(album))"))
        let cover = Self.squeezed(try Self.body(["struct PlanReceiptView", "func cover("], in: Self.receipt))
        #expect(cover == "{covers.map{$0[album.id]??PlanCovers.Cover(ids:[],hidden:false)}}")
        let model = Self.squeezed(try Self.body(["func receiptCovers("], in: Self.model))
        #expect(model.hasPrefix("{guard!facts.isEmptyelse{returnnil}"))
        #expect(model.contains("Task.detached(priority:.userInitiated){PlanCovers.albums(of:plan,dates:dates,ranks:ranks)}"))
    }

    /// An album of the receipt: a larger cover (72 pt beside the words, a strip at the
    /// accessibility sizes) of the photos the plan added, "Vorschau ausgeblendet" when they are
    /// sensitive documents, the symbol of a removed album as before; what the plan did under the
    /// name, side by side where it fits. One element for VoiceOver.
    @Test func aReceiptAlbumShowsALargerCover() throws {
        let row = Self.squeezed(try Self.body(["private struct ReceiptAlbumRow", "var body"], in: Self.receipt))
        #expect(row.hasPrefix("{AdaptiveStack(spacing:Theme.Spacing.m){coverViewVStack(alignment:.leading,spacing:2){"))
        #expect(row.contains("ViewThatFits(in:.horizontal){HStack(alignment:.firstTextBaseline,spacing:Theme.Spacing.s){badgecounts}VStack(alignment:.leading,spacing:2){badgecounts}}"))
        #expect(row.hasSuffix(".padding(.vertical,Theme.Spacing.xs).accessibilityElement(children:.combine)}"))
        let cover = Self.squeezed(try Self.body(["private struct ReceiptAlbumRow", "private var coverView"], in: Self.receipt))
        #expect(cover.contains("ifalbum.added>0{AlbumRowCover(ids:cover?.ids??[],hidesPreview:cover?.hidden??false,placeholderSymbol:cover==nil?nil:\"rectangle.stack\")}"))
        #expect(cover.contains("else{AlbumRowCover(ids:[],placeholderSymbol:album.change==.deleted?\"rectangle.stack.badge.minus\":\"rectangle.stack\")}"))
        // Not the small picture of before.
        let whole = try Self.body(["private struct ReceiptAlbumRow"], in: Self.receipt)
        #expect(!whole.contains("CoverThumbnail(") && !whole.contains("= 44"))
        let size = Self.squeezed(try Self.body(["struct AlbumRowCover", "var body"], in: Self.covers))
        #expect(size.contains("CoverPhoto(ids:ids,aspectRatio:strip?ChangeCoverMetrics.stripAspectRatio:1,cornerRadius:Theme.Radius.tile,hidesPreview:hidesPreview,placeholderSymbol:placeholderSymbol).frame(width:strip?nil:min(side,ChangeCoverMetrics.largestSide))"))
    }

    // MARK: The preview (DS-15 part 2)

    /// The preview before a run shows each album with the cover its receipt will show: the photos
    /// the plan sets out to add (`applied: false`), worked out off the main thread, keyed as the
    /// receipt's covers (`ChangeCoverInputs`: another plan, new facts), none before the first facts
    /// of a launch; each row finds its own under the receipt's name of the album
    /// (`PlanCovers.key`), never one made for another plan.
    @Test func thePreviewWorksOutTheCoverOfEachAlbum() throws {
        let view = Self.squeezed(try Self.body(["struct PlanReviewView", "var body"], in: Self.review))
        #expect(view.contains(".task(id:model.changeCoverInputs(plan.map{[$0]}??[])){guardletplanelse{return}letmade=awaitmodel.previewCovers(for:plan)guard!Task.isCancelledelse{return}albumCovers=AlbumCovers(plan:plan.id,covers:made)}"))
        let content = Self.squeezed(try Self.body(["struct PlanReviewView", "func planContent("], in: Self.review))
        #expect(content.contains("if!facts.albums.isEmpty{PlanAlbumList(albums:facts.albums,covers:covers(of:plan))}"))
        let mine = Self.squeezed(try Self.body(["struct PlanReviewView", "func covers(of"], in: Self.review))
        #expect(mine == "{guardletalbumCovers,albumCovers.plan==plan.idelse{returnnil}returnalbumCovers.covers}")
        let list = Self.squeezed(try Self.body(["struct PlanAlbumList", "var body"], in: Self.review))
        #expect(list.contains("PlanAlbumRow(album:album,cover:cover(album))"))
        let cover = Self.squeezed(try Self.body(["struct PlanAlbumList", "func cover("], in: Self.review))
        #expect(cover == "{covers.map{$0[PlanCovers.key(of:album.id)]??PlanCovers.Cover(ids:[],hidden:false)}}")
        let model = Self.squeezed(try Self.body(["func previewCovers("], in: Self.model))
        #expect(model.hasPrefix("{guard!facts.isEmptyelse{returnnil}"))
        #expect(model.contains("letdates=creationDates,ranks=previewRanksreturnawaitTask.detached(priority:.userInitiated){PlanCovers.albums(of:plan,applied:false,dates:dates,ranks:ranks)}.value"))
    }

    /// A row of the preview: the album's cover as the receipt shows it (72 pt beside the words, a
    /// strip at the accessibility sizes) instead of the 44 pt picture of its first photo; the
    /// stack's symbol for an album the plan adds no photo to. "Neu" or "Ergänzt" with "N Fotos"
    /// under the folder, side by side where they fit, as in the receipt. One element for
    /// VoiceOver with the words of before, in the order of before.
    @Test func aPreviewRowShowsTheAlbumsCover() throws {
        let row = Self.squeezed(try Self.body(["private struct PlanAlbumRow", "var body"], in: Self.review))
        #expect(row.hasPrefix("{AdaptiveStack(spacing:Theme.Spacing.m){coverViewVStack(alignment:.leading,spacing:2){Text(album.title).font(.body.weight(.medium)).compactLineLimit(2)if!album.folderPath.isEmpty{Text(album.folderPath.joined(separator:\"›\")).font(.footnote).foregroundStyle(.noteText).compactLineLimit(2)}ViewThatFits(in:.horizontal){HStack(alignment:.firstTextBaseline,spacing:Theme.Spacing.s){badgecount}VStack(alignment:.leading,spacing:2){badgecount}}}.frame(maxWidth:.infinity,alignment:.leading)}"))
        #expect(row.hasSuffix(".padding(.vertical,Theme.Spacing.xs).accessibilityElement(children:.combine)}"))
        let cover = Self.squeezed(try Self.body(["private struct PlanAlbumRow", "private var coverView"], in: Self.review))
        #expect(cover.contains("ifalbum.addedCount>0{AlbumRowCover(ids:cover?.ids??[],hidesPreview:cover?.hidden??false,placeholderSymbol:cover==nil?nil:\"rectangle.stack\")}else{AlbumRowCover(ids:[],placeholderSymbol:\"rectangle.stack\")}"))
        // Not the small picture of before.
        let whole = try Self.body(["private struct PlanAlbumRow"], in: Self.review)
        #expect(!whole.contains("CoverThumbnail(") && !whole.contains("= 44"))
        // The words of before.
        let words = Self.squeezed(whole)
        #expect(words.contains("Text(\"Neu\").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)"))
        #expect(words.contains("Text(\"Ergänzt\").font(.caption.weight(.semibold)).foregroundStyle(.noteText)"))
        #expect(words.contains("Text(\"\\(album.addedCount)\\(album.addedCount.formatted())Fotos\").font(.footnote).foregroundStyle(.noteText).monospacedDigit()"))
    }

    /// The names the UI tests use stay (`AlbumistFlowUITests`, `AlbumistLockedUITests`).
    @Test func theNamesTheUITestsUseStay() throws {
        let receipt = try Self.code(Self.receipt)
        for identifier in ["\"receipt.undo\"", "\"receipt.undoRest\"", "\"receipt.retry\""] {
            #expect(receipt.contains(identifier), "\(identifier) is gone")
        }
        #expect(try Self.code(Self.settings).contains(".accessibilityIdentifier(\"history.row\")"))
    }
}
