import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Pinch to zoom, the scroll view and the days of "Unsortiert" in the shared grid (`PhotoGridSourceTests`).
extension PhotoGridSourceTests {
    // MARK: Pinch to zoom

    /// Two fingers change the photos in a row by a step (`PhotoGridZoom.Pinch`), UIKit's pinch
    /// beside the scroll view, which stops following the fingers once the pinch begins; the photo
    /// they hold (`PhotoGridHitTest.nearest`) is scrolled to where they are
    /// (`PhotoGridZoom.anchor`); the grid settles from the old size around them, not under
    /// Reduce Motion; the size is remembered, but not from one UI test to the next.
    @Test func pinchToZoomKeepsThePlace() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains(".gesture(PhotoGridPinch(isEnabled:!disabled,space:PhotoGridPlace.space,touchedDown:{gestures.touchedDown()},"
                              + "onTouch:{touchinpinched(touch)}))"), "\(view)")
        let recognizers = try Self.code(Self.recognizers)
        #expect(recognizers.contains("final class PhotoGridPinchRecognizer: UIPinchGestureRecognizer, UIGestureRecognizerDelegate {"))
        let stop = Self.squeezed(try Self.body(["final class PhotoGridPinchRecognizer", "func stopScrolling("], in: Self.recognizers))
        #expect(stop.hasSuffix("scrollPan.isEnabled=falsescrollPan.isEnabled=true}"), "\(stop)")
        let handled = Self.squeezed(try Self.body(["struct PhotoGridPinch", "func handleUIGestureRecognizerAction("], in: Self.recognizers))
        #expect(handled.contains("case.began:recognizer.stopScrolling()"), "\(handled)")
        let state = try Self.code(Self.state)
        #expect(state.contains("PhotoGridHitTest.nearest(x: Double(touch.inGrid.x), y: Double(touch.inGrid.y), in: onScreen)"))
        #expect(state.contains("PhotoGridZoom.Pinch(columns: columns)"))
        let pinched = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func pinched("], in: Self.grid))
        #expect(pinched.contains("PhotoGridZoom.anchor(fingerY:zoom.fingerY,visibleHeight:zoom.visibleHeight,side:side,"
                                 + "pointInPhoto:zoom.pointInPhoto)"), "\(pinched)")
        let step = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func step(to"], in: Self.grid))
        #expect(step.contains("storedColumns=columns"), "\(step)")
        #expect(step.contains("ifletphoto{scroller?.show(photo,unitY:anchor(newSide))}"), "\(step)")
        #expect(step.contains("ifletpoint,!reduceMotion{settle=PhotoGridSettle(count:settle.count+1,"
                              + "from:PhotoGridZoom.settleScale(oldSide:oldSide,newSide:newSide),point:point)}"), "\(step)")
        let shown = Self.squeezed(try Self.body(["final class PhotoGridScroller", "func show("], in: Self.scrolling))
        #expect(shown.contains("anchor=pointposition.scrollTo(id:photo,anchor:point)"), "the modifier's anchor and the step's: \(shown)")
        // Remembered in the app's defaults, one size for both grids; UI runs start at the standard.
        let grid = try Self.code(Self.grid)
        #expect(grid.contains("@AppStorage(PhotoGridMemory.key, store: PhotoGridMemory.defaults) private var storedColumns = PhotoGridZoom.standard"))
        #expect(grid.contains("static let key = \"photoGrid.columns\""))
        #expect(grid.contains("if UITestSupport.isRunning { UserDefaults.standard.removeObject(forKey: key) }"))
    }

    /// After a zoom step lands the page scrolls plainly again (review L6): the scroll view finds
    /// the grid's photos by id only while a step is on its way (the scroll target layout is on
    /// only then, so it follows no photo while the user scrolls), and once the step landed (the
    /// grid settled) no anchor is left and its position names no photo: a photo that goes leaves
    /// nothing behind, and the page keeps its top when its size changes, as before the zoom.
    @Test func afterAZoomStepThePageScrollsPlainlyAgain() throws {
        let shown = Self.squeezed(try Self.body(["final class PhotoGridScroller", "func show("], in: Self.scrolling))
        #expect(shown.contains("findsPhotos=trueanchor=pointposition.scrollTo(id:photo,anchor:point)"), "\(shown)")
        #expect(shown.contains("try?awaitTask.sleep(for:PhotoGridScroller.landing)guardletself,self.steps==stepelse{return}self.land()"),
                "only the last step lands: \(shown)")
        let land = Self.squeezed(try Self.body(["final class PhotoGridScroller", "private func land("], in: Self.scrolling))
        #expect(land == "{anchor=nilfindsPhotos=falseposition=ScrollPosition(idType:AssetID.self)}", "\(land)")
        let scrolling = try Self.code(Self.scrolling)
        #expect(scrolling.contains("static let landing: Duration = .milliseconds(350)"), "after the grid settled (0.3 s)")
    }

    /// The pinch is there without two fingers: VoiceOver's zoom on a photo, and the photo's
    /// actions "Vergrößern" and "Verkleinern" for Switch Control, Voice Control and a keyboard
    /// (only those that make a step, none while the grid waits, as the pinch), each saying the
    /// new size; the words have English.
    @Test func theZoomIsThereWithoutTwoFingers() throws {
        let cell = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.grid))
        #expect(cell.contains(".accessibilityZoomAction{actioninstep(zoomingIn:action.direction==.zoomIn,on:id,columns:columns)}"), "\(cell)")
        #expect(cell.contains(".accessibilityActions{if!disabled,PhotoGridZoom.fewer(than:columns)!=nil{Button(\"Vergrößern\"){"
                              + "step(zoomingIn:true,on:id,columns:columns)}}if!disabled,PhotoGridZoom.more(than:columns)!=nil{"
                              + "Button(\"Verkleinern\"){step(zoomingIn:false,on:id,columns:columns)}}}"), "\(cell)")
        let said = try Self.body(["struct PhotoGrid: View", "private func step(zoomingIn"], in: Self.grid)
        #expect(Self.squeezed(said).hasPrefix("{guard!disabledelse{return}"), "not while the grid waits: \(said)")
        // At the largest or smallest size VoiceOver's zoom stays and says the size it stays at
        // (review L13), rather than nothing.
        #expect(Self.squeezed(said).contains("letnext=(zoomingIn?PhotoGridZoom.fewer(than:columns):PhotoGridZoom.more(than:columns))"
                                             + "??columnsifnext!=columns{step(to:next,from:columns,keeping:photo,anchor:{_in0.5},around:nil)}"),
                "\(said)")
        #expect(said.contains("AccessibilityNotification.Announcement(String(localized: \"\\(next) \\(next.formatted()) Fotos pro Reihe\")).post()"),
                "\(said)")
        let catalog = try StringCatalogTests.catalog()
        func english(_ key: String) -> String? {
            let entry = catalog[key] as? [String: Any]
            let en = (entry?["localizations"] as? [String: Any])?["en"] as? [String: Any]
            return (en?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        #expect(english("Vergrößern") == "Zoom In")
        #expect(english("Verkleinern") == "Zoom Out")
        let perRow = try #require(catalog["%lld %@ Fotos pro Reihe"] as? [String: Any])
        let row = String(data: try JSONSerialization.data(withJSONObject: perRow), encoding: .utf8) ?? ""
        #expect(row.contains("%2$@ photos per row") && row.contains("%2$@ Fotos pro Reihe"), "\(row)")
    }

    // MARK: The scroll view

    /// The page's scroll view lets the grid move it (`photoGridScrolling()`): by offset while a
    /// finger selects near an edge, to a photo after a zoom step; what it reports while it moves
    /// is kept apart from what is drawn, so scrolling draws nothing again. "Unsortiert" has it,
    /// and so has the suggestion's page, right after its cover reaches up under the bars: from
    /// there it reads where the bars end, as the page's own `barBottom` below it does.
    @Test func theScrollViewLetsTheGridMoveIt() throws {
        let host = Self.squeezed(try Self.body(["private struct PhotoGridScrollHost", "func body(content: Content)"], in: Self.scrolling))
        #expect(host.contains(".scrollPosition($scroller.position,anchor:scroller.anchor)"), "\(host)")
        #expect(host.contains(".onScrollGeometryChange(for:ScrollGeometry.self){geometryingeometry}action:{_,geometryinscroller.reported(geometry)}"),
                "\(host)")
        #expect(host.contains(".environment(\\.photoGridScroller,scroller)"), "\(host)")
        // Where the bars end, also on a page whose content reaches up under them (the
        // suggestion's cover): its scroll view has no content inset at the top.
        #expect(host.contains(".onGeometryChange(for:PhotoGridSafeEdges.self){proxyin"
                              + "PhotoGridSafeEdges(top:proxy.safeAreaInsets.top,bottom:proxy.safeAreaInsets.bottom)"
                              + "}action:{edgesinscroller.reported(safeArea:edges)}"), "\(host)")
        let seen = Self.squeezed(try Self.body(["final class PhotoGridScroller", "var seenArea:"], in: Self.scrolling))
        #expect(seen.contains("PhotoGridAutoScroll.seenArea(height:Double(geometry.containerSize.height),"), "\(seen)")
        let scroller = try Self.code(Self.scrolling)
        #expect(scroller.contains("@ObservationIgnored private var geometry: ScrollGeometry?"), "every frame of scrolling observed")
        #expect(scroller.contains("@ObservationIgnored private var safeArea = PhotoGridSafeEdges()"), "the safe area observed")
        let library = Self.squeezed(try Self.body(["struct LibraryView", "var body: some View"], in: Self.library))
        #expect(library.contains("}.photoGridScrolling().background(Theme.background)"), "\(library)")
        let detail = Self.squeezed(try Self.body(["struct ProposalDetailView", "var body: some View"], in: Self.suggestions))
        #expect(detail.contains(".ignoresSafeArea(edges:.top).photoGridScrolling()"), "\(detail)")
    }

    /// A grid that goes while it scrolls by itself (its page went, "Unsortiert" made its days
    /// anew, a suggestion's preview was hidden) ends the drag as a lifted finger does (review Z2):
    /// the clock stops, its page's scroller scrolls by itself no more, and the app's lesson starts
    /// the next run afresh, on any page (`endDrag()` ends the range, `endAutoScroll()` resets them).
    @Test func aGridThatGoesEndsItsRun() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains(".onDisappear{gestures.endDrag()}"), "\(view)")
    }

    // MARK: The days of "Unsortiert"

    /// The days are made off the main thread (`AppModel.inboxDays`, as the areas themselves),
    /// not in a body; they are made again only when the area itself changes (the same array, not
    /// equal contents), and the work is given up when a newer area comes. The grid shows a page
    /// of photos from the top, the last day cut where the page ends (`InboxDays.shown`), so one
    /// page never holds more, whatever one day holds (review L2).
    @Test func theDaysAreMadeOffTheMainThread() throws {
        let made = try Self.body(["func inboxDays("], in: Self.model)
        for part in ["await homeTimeZone()", "Task.detached(priority: .userInitiated)", "InboxDays.make(items, facts: facts, homeZone: homeZone",
                     "Task.isCancelled", "withTaskCancellationHandler", "work.cancel()"] {
            #expect(made.contains(part), "\(part)")
        }
        let library = try Self.code(Self.library)
        #expect(!library.contains("InboxDays.make("), "grouped in the view")
        let view = Self.squeezed(try Self.body(["struct LibraryView", "var body: some View"], in: Self.library))
        #expect(view.contains(".task(id:DaysKey(bucket:bucket,members:members,words:model.proposalWords,today:today)){"
                              + "awaitmakeDays(of:members,in:bucket)}"), "\(view)")
        let key = Self.squeezed(try Self.body(["struct LibraryView", "private static func same<"], in: Self.library))
        #expect(key.contains("pa.baseAddress==pb.baseAddress"), "the same array, not equal contents: \(key)")
        let content = Self.squeezed(try Self.body(["struct LibraryView", "private func content("], in: Self.library))
        #expect(content.contains("letpage=days.shown(forPhotos:shown)grid(days.sections.prefix(page.days),limit:page.photos)"
                                 + "ifpage.photos<days.photoCount{moreComing(after:page.photos)}"), "\(content)")
        #expect(content.contains("}elseifdaysBucket==bucket,!days.sections.isEmpty{"),
                "another area's days under this filter, or none while it has photos: \(content)")
    }

    /// "Heute" and "Gestern" follow midnight (review L11): the day that is today is kept and read
    /// anew when iOS says a significant time changed (midnight, a new time zone, a carrier's
    /// correction) and when the app is back on screen, so a tab left open overnight makes its
    /// days anew. With the day the iPhone's zone (review W10): photos without a zone of their own
    /// are read on its clock, so a new zone makes the days anew also where the day number stays.
    @Test func todayAndYesterdayFollowMidnight() throws {
        let library = try Self.code(Self.library)
        #expect(library.contains("@State private var today = Self.today()"))
        #expect(library.contains("@Environment(\\.scenePhase) private var scenePhase"))
        let view = Self.squeezed(try Self.body(["struct LibraryView", "var body: some View"], in: Self.library))
        #expect(view.contains(".task(id:DaysKey(bucket:bucket,members:members,words:model.proposalWords,today:today))"), "\(view)")
        #expect(view.contains(".onReceive(NotificationCenter.default.publisher(for:UIApplication.significantTimeChangeNotification))"
                              + "{_intoday=Self.today()}"), "\(view)")
        #expect(view.contains(".onChange(of:scenePhase){_,phaseinifphase==.active{today=Self.today()}}"), "\(view)")
        let today = Self.squeezed(try Self.body(["struct LibraryView", "private static func today() -> Today"], in: Self.library))
        #expect(today == "{letzone=TimeZone.currentreturnToday(day:LocalTime.day(LocalTime.wallClock(Date(),in:zone)),"
                + "zone:zone.identifier)}", "\(today)")
        let key = Self.squeezed(try Self.body(["struct LibraryView", "private struct DaysKey"], in: Self.library))
        #expect(key.contains("vartoday:Today") && key.contains("a.today==b.today"), "\(key)")
    }

    /// The tab's own loading is calm (DS-18): words, no spinner, with the identifiers the UI
    /// tests wait for.
    @Test func theLoadingIsCalm() throws {
        let library = try Self.code(Self.library)
        #expect(!library.contains("ProgressView("), "a spinner in the tab")
        let preparing = Self.squeezed(try Self.body(["struct LibraryView", "private var preparing: some View"], in: Self.library))
        #expect(preparing.hasPrefix("{Text(\"Fotoswerdenzusammengestellt…\")"), "\(preparing)")
        #expect(preparing.contains(".accessibilityIdentifier(\"library.preparing\")"))
        let more = Self.squeezed(try Self.body(["struct LibraryView", "private func moreComing("], in: Self.library))
        #expect(more.hasPrefix("{Text(\"WeitereFotoswerdengeladen\")"), "\(more)")
        #expect(more.contains(".onScrollVisibilityChange(threshold:0.1){visibleinifvisible{shown=photos+Self.page}}"), "\(more)")
        #expect(more.contains(".accessibilityIdentifier(\"library.loadingMore\")"))
    }

    /// What worked in the tab stays: the count, the filters, "Auswählen" and "Fertig" with the
    /// bottom bar and no tab bar while selecting, "Widerrufen", the photo view zooming out of its
    /// photo, adding to an album, pull to refresh.
    @Test func whatWorkedStays() throws {
        let view = try Self.body(["struct LibraryView", "var body: some View"], in: Self.library)
        for part in ["Button(selecting ? \"Fertig\" : \"Auswählen\")", "selectionActions", "bucketPicker",
                     ".toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)",
                     ".safeAreaInset(edge: .bottom) { IgnoreUndoBar() }",
                     ".navigationTransition(.zoom(sourceID: start.id, in: zoom))",
                     "AddToAlbumSheet(assets: addingToAlbum ?? [])", ".refreshable { await model.refreshDerived() }",
                     ".onAppear { model.showLibraryBuckets() }", ".onDisappear { model.hideLibraryBuckets() }"] {
            #expect(view.contains(part), "\(part)")
        }
        let content = try Self.body(["struct LibraryView", "private func content("], in: Self.library)
        #expect(content.contains("Text(\"\\(members.count) \\(members.count.formatted()) Fotos und Videos\")"))
    }
}
