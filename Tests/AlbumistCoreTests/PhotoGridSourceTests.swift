import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// How the app wires the photo grids of design wave 3 (DS-21 "Unsortiert nach Tagen wie in
/// Fotos", DS-06b drag to select and pinch to zoom), read from its sources, as the app does not
/// build on Linux. What the grids decide is tested in the core (`InboxDaysTests`,
/// `PhotoGridGestureTests`); here: both pages share one grid, the days are made off the main
/// thread, the gestures are UIKit's own beside the scroll view and each one is there for
/// VoiceOver too, the loading is calm, and what worked before stays.
@Suite("Photo grids in the app (source)")
struct PhotoGridSourceTests {
    static let grid = "App/Albumist/Views/PhotoGrid/PhotoGrid.swift"
    static let recognizers = "App/Albumist/Views/PhotoGrid/PhotoGridRecognizers.swift"
    static let state = "App/Albumist/Views/PhotoGrid/PhotoGridGestureState.swift"
    static let scrolling = "App/Albumist/Views/PhotoGrid/PhotoGridScrolling.swift"
    static let library = "App/Albumist/Views/LibraryView.swift"
    static let suggestions = "App/Albumist/Views/ProposalViews.swift"
    static let model = "App/Albumist/Model/AppModel+PhotoGrid.swift"
    static let thumbnails = "App/Albumist/Views/AssetThumbnail.swift"

    /// The code of `path` (comments blanked, strings kept).
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    /// The body of a declaration path in the code of `path`.
    static func body(_ declarations: [String], in path: String) throws -> String {
        try #require(AppSource.body(of: declarations, in: try code(path)), "\(declarations) is not in \(path)")
    }

    /// `text` without any white space, so a check does not depend on how a line is broken.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    // MARK: One grid

    /// "Unsortiert" and a suggestion's photos are one grid ("Zoom wie überall"): each page hands
    /// it its days, the place of its long press, its selection and its way to open a photo, and
    /// draws no photos of its own.
    @Test func bothPagesShareTheGrid() throws {
        let library = Self.squeezed(try Self.body(["struct LibraryView"], in: Self.library))
        #expect(library.contains("PhotoGrid(sections:days,limit:limit,place:.unsorted,selecting:selecting,selection:$selection,"
                                 + "pinsHeaders:true,zoom:zoom,identifier:\"library.photo\"){idinopen(id,in:days,limit:limit)}"
                                 + "perform:{item,idinperform(item,on:id,in:days,limit:limit)}"), "\(library)")
        let suggestion = Self.squeezed(try Self.body(["struct ProposalPhotosView"], in: Self.suggestions))
        #expect(suggestion.contains("PhotoGrid(sections:sections[...],place:.suggestion,selecting:selecting,selection:$selected,"
                                    + "available:!disabled&&isCurrent,disabled:disabled,zoom:zoom,"
                                    + "identifier:\"proposalPhotos.photo\"){idinopen(id)}perform:{item,idinperform(item,on:id)}"),
                "\(suggestion)")
        for (page, code) in [("LibraryView", library), ("ProposalPhotosView", suggestion)] {
            for own in ["AssetThumbnail(", "LazyVGrid(", ".photoMenu(", "ProgressView("] {
                #expect(!code.contains(own), "\(page) draws its photos itself: \(own)")
            }
        }
        // The pages' photo view opens on the photos shown, in the grid's order (one page at most).
        let open = Self.squeezed(try Self.body(["struct LibraryView", "private func open("], in: Self.library))
        #expect(open.contains("viewing=PhotoViewer.Start(id:id,ids:PhotoGridSection.ids(of:days,below:limit))"), "\(open)")
        // A suggestion's days with each photo's time on its own clock, made again only when they change.
        let sections = Self.squeezed(try Self.body(["struct ProposalPhotosView", "private var sections:"], in: Self.suggestions))
        #expect(sections.contains("grid.sections(for:days)"), "\(sections)")
        #expect(sections.contains("PhotoGridSection.sections(days){facts[$0]?.wallClock(or:.current)}"), "\(sections)")
    }

    /// The days as Photos shows them: a header per day, its photos below it, the header pinned
    /// at the top while its photos scroll under it where the page asks for it (never at the
    /// accessibility sizes, where it can take several lines), a heading for VoiceOver that
    /// wraps instead of being cut. Pinned, it lies on the page's ground, so no text lies on a
    /// photo; otherwise it has no ground of its own (a suggestion's page is tinted by its photo).
    @Test func theGridShowsTheDaysAsPhotosDoes() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains("ForEach(sections){sectioninSection{ForEach(section.entries(below:limit)){entryin"
                              + "cell(entry,side:side,columns:columns)}"
                              + "}header:{header(section,pinned:pinned)}}"), "\(view)")
        #expect(view.contains("letpinned=pinsHeaders&&!typeSize.isAccessibilitySize"), "\(view)")
        #expect(view.contains("pinnedViews:pinned?[.sectionHeaders]:[]"), "\(view)")
        #expect(view.contains("GridItem(.flexible(),spacing:CGFloat(PhotoGridZoom.spacing))"), "\(view)")
        #expect(view.contains("letcolumns=PhotoGridZoom.columns(stored:storedColumns)"), "\(view)")
        #expect(view.contains(".scrollTargetLayout(isEnabled:scroller?.findsPhotos??false)"), "the scroll view finds the photos by id")
        let header = try Self.body(["struct PhotoGridHeader", "var body: some View"], in: Self.grid)
        #expect(header.contains("AdaptiveStack(verticalAlignment: .firstTextBaseline"), "\(header)")
        #expect(header.contains(".accessibilityElement(children: .combine)") && header.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(header.contains(".background(pinned ? Theme.background : Color.clear)"), "a pinned header over the photos")
        #expect(!header.contains(".lineLimit("), "a header is cut at the large text sizes")
        #expect(header.contains("Text(verbatim: section.title)") && header.contains("Text(verbatim: section.countText)"))
        #expect(header.contains(".foregroundStyle(.noteText)"))
    }

    /// A photo is a real button named with its date and time on its own clock (the UI tests find
    /// the photos as buttons with a year in their names), opens or ticks as before, says when it
    /// is ticked, zooms into the photo view out of its tile, and does nothing while the page waits.
    /// The lift that ends a drag or a pinch (UIKit may hand it to the photo's button too) is no
    /// tap: the drag ticked its first photo already, and a pinch opens nothing. Only that lift
    /// (`PhotoGridLift`, review L8): both gestures tell of each finger that touches the grid, and
    /// a tap after it is one of its own, however soon after a drag or a pinch.
    @Test func aPhotoOpensAndTicksAsBefore() throws {
        let cell = try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.grid)
        let tap = Self.squeezed(cell)
        #expect(tap.contains("returnButton{guard!gestures.swallowsTapelse{return}guardselectingelse{open(id)return}"
                             + "ifisSelected{selection.remove(id)}else{selection.insert(id)}}"), "\(tap)")
        let lift = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "var swallowsTap: Bool"], in: Self.state))
        #expect(lift == "{lift.swallowsTap}", "\(lift)")
        let state = try Self.code(Self.state)
        #expect(!state.contains("Date()"), "a time window swallows the taps after the lift too")
        let end = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "func endDrag("], in: Self.state))
        #expect(end.contains("ifdrag!=nil||waiting!=nil{lift.gestureEnded()}"), "\(end)")
        let endPinch = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "func endPinch("], in: Self.state))
        #expect(endPinch.contains("ifzooming!=nil{lift.gestureEnded()}"), "\(endPinch)")
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.components(separatedBy: "touchedDown:{gestures.touchedDown()}").count - 1 == 2, "\(view)")
        for recognizer in ["final class PhotoGridSelectRecognizer", "final class PhotoGridPinchRecognizer"] {
            let touched = Self.squeezed(try Self.body([recognizer, "shouldReceive touch: UITouch"], in: Self.recognizers))
            #expect(touched == "{touchedDown?()returntrue}", "\(recognizer): \(touched)")
        }
        for representable in ["struct PhotoGridSelectDrag", "struct PhotoGridPinch"] {
            let made = try Self.body([representable, "func makeUIGestureRecognizer("], in: Self.recognizers)
            let updated = try Self.body([representable, "func updateUIGestureRecognizer("], in: Self.recognizers)
            #expect(made.contains("recognizer.touchedDown = touchedDown") && updated.contains("recognizer.touchedDown = touchedDown"),
                    "\(representable)")
        }
        for modifier in [".matchedTransitionSource(id: id, in: zoom)", ".buttonStyle(.plain)", ".disabled(disabled)",
                         ".accessibilityLabel(Text(Self.spokenDate(entry)))",
                         ".accessibilityAddTraits(selecting && isSelected ? .isSelected : [])",
                         ".accessibilityIdentifier(identifier)", ".accessibilityHidden(true)"] {
            #expect(cell.contains(modifier), "\(modifier)")
        }
        let spoken = try Self.body(["struct PhotoGrid: View", "private static func spokenDate("], in: Self.grid)
        #expect(spoken.contains("Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .gmt)"), "the photo's own clock")
        #expect(spoken.contains("String(localized: \"Foto\")"))
    }

    /// Each thumbnail is asked for at the side it is shown at (sharp at three, five and seven in
    /// a row), anew when that side changes, and keeps the image of the size before until the new
    /// one is there (`AssetThumbnail`'s task follows the photo and its side, on the same view: no
    /// `.id(side)`, which would build each thumbnail anew with its opaque ground over the old
    /// image); the grid asks Photos for nothing itself, so nothing comes from iCloud.
    @Test func thumbnailsAreAskedForAtTheSizeTheyAreShown() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains("letside=CGFloat(PhotoGridZoom.side(width:Double(width),columns:columns))"), "\(view)")
        let cell = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.grid))
        #expect(cell.contains("ifside>0{AssetThumbnail(id:id,side:side)}"), "\(cell)")
        #expect(!cell.contains(".id(side)"), "each zoom step would build the thumbnails anew: \(cell)")
        let thumbnail = Self.squeezed(try Self.body(["struct AssetThumbnail: View", "var body: some View"], in: Self.thumbnails))
        #expect(thumbnail.contains(".task(id:Slot(id:id,side:side))"), "the thumbnail does not follow its side: \(thumbnail)")
        for path in [Self.grid, Self.recognizers, Self.state, Self.scrolling] {
            let code = try Self.code(path)
            for request in ["requestImage(", "PHImageManager", "PHCachingImageManager", "isNetworkAccessAllowed", "PHAsset"] {
                #expect(!code.contains(request), "\(path): \(request)")
            }
        }
        #expect(try Self.code(Self.thumbnails).contains("options.isNetworkAccessAllowed = false"))
        // No image of the old size of its own on top: the thumbnail keeps it.
        #expect(!(try Self.code(Self.grid)).contains("bridgeSide"), "a second image of the old size in the grid")
    }

    // MARK: Drag to select

    /// A photo that goes (scrolled away, or its page left for another tab or page) keeps what it
    /// reported and counts again once it is back (`PhotoGridOnScreen`): SwiftUI reports its frame
    /// in the grid only when it changes, so the photos of a page shown again report nothing, and
    /// a photo forgotten when it went would not be found by drag and pinch (review L1).
    @Test func aPhotoIsFoundAgainAfterThePageWasAway() throws {
        let cell = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.grid))
        #expect(cell.contains("gestures.place(id,reported)}.onAppear{gestures.appeared(id)}.onDisappear{gestures.disappeared(id)}"),
                "\(cell)")
        #expect(!cell.contains("forget"), "\(cell)")
        let state = try Self.code(Self.state)
        #expect(state.contains("private var photos = PhotoGridOnScreen<AssetID, PhotoGridPlace>()"))
        #expect(!state.contains("places["), "a dictionary of its own that forgets or grows")
    }

    /// A day's header pinned over the photos scrolling under it hides them: each header reports
    /// where it is in the grid (pinned: where it is pinned), kept as the photos are, and a finger
    /// on one is on no photo where a drag begins and where it goes
    /// (`PhotoGridHitTest.position(…covered:)`), so it ticks nothing the user cannot see (review L4).
    @Test func aPinnedHeaderHidesThePhotosUnderIt() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains("}header:{header(section,pinned:pinned)}"), "\(view)")
        let header = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func header("], in: Self.grid))
        #expect(header.contains("PhotoGridHeader(section:section,pinned:pinned).onGeometryChange(for:CGRect.self){proxyin"
                                + "proxy.frame(in:.named(PhotoGridPlace.space))}action:{frameingestures.header(section.id,frame)}"
                                + ".onAppear{gestures.headerAppeared(section.id)}.onDisappear{gestures.headerDisappeared(section.id)}"),
                "\(header)")
        let state = try Self.code(Self.state)
        #expect(state.contains("private var headers = PhotoGridOnScreen<Int, CGRect>()"))
        let hits = state.components(separatedBy: "PhotoGridHitTest.position(").count - 1
        #expect(hits == 2 && state.components(separatedBy: "covered: covered)").count - 1 == hits, "\(hits)")
    }

    /// A running drag follows the photos the grid shows now (review L3): the grid hands them to
    /// its gestures at every body (`PhotoGridShown`, compared by storage, its order made again
    /// only when it changed), and the range follows them by id where the finger goes and while
    /// the page scrolls by itself (`PhotoGridDrag.rebased`): more photos loaded at the bottom
    /// tick on, and when the range cannot be kept the drag ends, its photos ticked as they are.
    @Test func aDragFollowsThePhotosTheGridShowsNow() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains("let_=gestures.show(PhotoGridShown(sections,below:limit))"), "\(view)")
        let dragged = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func dragged("], in: Self.grid))
        #expect(dragged.contains("gestures.beginDrag(touch,selection:$selection,scroller:scroller)"), "\(dragged)")
        let extend = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func extend("], in: Self.state))
        #expect(extend.hasPrefix("{follow()guardvarcurrent=drag,"), "\(extend)")
        let follow = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func follow("], in: Self.state))
        #expect(follow.contains("guardletrange=current.range.rebased(from:current.ids,to:now)else{endDrag()return}"), "\(follow)")
        let step = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func scrollStep("], in: Self.state))
        #expect(step.hasSuffix("returndrag!=nil}"), "a drag that ended stops the clock: \(step)")
    }

    /// Drag to select is UIKit's own pan beside the scroll view, only while the page selects: it
    /// begins only on a mostly sideways start (`PhotoGridDrag.startsSelection`), the scroll
    /// view's pan (and any other pan but the swipe back from the screen's edge, which it waits
    /// for instead, review L7) waits for it to fail, so a vertical swipe scrolls as before; a tap
    /// never begins it, so a tap still ticks one photo.
    @Test func dragToSelectIsUIKitsPanBesideTheScrollView() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains(".gesture(PhotoGridSelectDrag(isEnabled:selecting&&!disabled,space:PhotoGridPlace.space,"
                              + "touchedDown:{gestures.touchedDown()}){touchindragged(touch)})"),
                "\(view)")
        let recognizers = try Self.code(Self.recognizers)
        #expect(recognizers.contains("final class PhotoGridSelectRecognizer: UIPanGestureRecognizer, UIGestureRecognizerDelegate {"))
        let begins = Self.squeezed(try Self.body(["final class PhotoGridSelectRecognizer", "func gestureRecognizerShouldBegin("],
                                                 in: Self.recognizers))
        #expect(begins.contains("PhotoGridDrag.startsSelection(dx:Double(moved.x),dy:Double(moved.y))"), "\(begins)")
        let waits = Self.squeezed(try Self.body(["final class PhotoGridSelectRecognizer", "shouldBeRequiredToFailBy"], in: Self.recognizers))
        #expect(waits == "{otherGestureRecognizer!==self&&otherGestureRecognizerisUIPanGestureRecognizer"
                         + "&&!(otherGestureRecognizerisUIScreenEdgePanGestureRecognizer)}", "\(waits)")
        // The swipe back from the screen's edge is never taken: the pan waits for it (review L7).
        let edge = Self.squeezed(try Self.body(["final class PhotoGridSelectRecognizer", "shouldRequireFailureOf"], in: Self.recognizers))
        #expect(edge == "{otherGestureRecognizerisUIScreenEdgePanGestureRecognizer}", "\(edge)")
        let made = Self.squeezed(try Self.body(["struct PhotoGridSelectDrag", "func makeUIGestureRecognizer("], in: Self.recognizers))
        #expect(made.contains("recognizer.maximumNumberOfTouches=1") && made.contains("recognizer.delegate=recognizer"), "\(made)")
        // The range is the core's, from where the finger touched, given back as it shrinks.
        let state = try Self.code(Self.state)
        #expect(state.contains("PhotoGridDrag(anchor: anchor, anchorWasSelected: base.contains(ids[anchor]))"))
        #expect(state.contains("PhotoGridDrag.apply(change, mode: current.range.mode, to: &selected, base: current.base, ids: current.ids)"))
        #expect(state.contains("let touched = CGPoint(x: touch.inGrid.x - touch.moved.x, y: touch.inGrid.y - touch.moved.y)"))
        let moved = Self.squeezed(try Self.body(["struct PhotoGridSelectDrag", "func handleUIGestureRecognizerAction("], in: Self.recognizers))
        #expect(moved.contains("moved:recognizer.translation(in:nil)"), "\(moved)")
    }

    /// Near the top or bottom edge the page scrolls on by itself, frame by frame with the
    /// screen, faster the closer the finger is to the edge (`PhotoGridAutoScroll`), and the range
    /// follows the photos that come under the still finger; it stops when the finger leaves the
    /// edge or lifts, and the frame clock is let go.
    @Test func nearAnEdgeThePageScrollsOnByItself() throws {
        let state = try Self.code(Self.state)
        // In the part the user sees: below the bars, also where the cover reaches up under them.
        let speed = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func edgeSpeed("], in: Self.state))
        #expect(speed.contains("letarea=scroller.seenArea"), "\(speed)")
        #expect(state.contains("PhotoGridAutoScroll.speed(y: Double(current.inScrollView.y), top: area.lowerBound, bottom: area.upperBound)"))
        #expect(state.contains("scroller.scroll(by: PhotoGridAutoScroll.step(speed: speed, seconds: seconds))"))
        #expect(state.contains("extend(to: CGPoint(x: current.inGrid.x, y: current.inGrid.y + CGFloat(scroller.offset - current.offset)))"))
        let end = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "func endDrag("], in: Self.state))
        #expect(end.hasPrefix("{ticker.stop()drag?.scroller?.endAutoScroll()"), "\(end)")
        #expect(end.hasSuffix("drag=nilwaiting=nil}"), "\(end)")
        let ticker = try Self.code(Self.state)
        #expect(ticker.contains("CADisplayLink(target: self, selector: #selector(step(_:)))"))
        let stop = Self.squeezed(try Self.body(["final class PhotoGridTicker", "func stop("], in: Self.state))
        #expect(stop.hasPrefix("{link?.invalidate()link=nil"), "\(stop)")
        // A tick of a grid that went stops the clock (the clock holds its target).
        #expect(state.contains("self?.scrollStep(seconds) ?? false"))
        let scroll = Self.squeezed(try Self.body(["final class PhotoGridScroller", "func scroll(by"], in: Self.scrolling))
        #expect(scroll.contains("guardletwanted=target.next(by:step,offset:offset,range:top...bottom)else{return}"), "\(scroll)")
        // What `scrollTo(y:)` takes is learned from the scroll view, not assumed (review L5).
        #expect(scroll.contains("lety=Self.calibration.y(for:wanted,insetTop:insetTop)"
                                + "Self.calibration.asked(y,from:offset,insetTop:insetTop,range:top...bottom)"
                                + "position.scrollTo(y:CGFloat(y))"), "\(scroll)")
        let reported = Self.squeezed(try Self.body(["final class PhotoGridScroller", "func reported(_ geometry"], in: Self.scrolling))
        #expect(reported.contains("Self.calibration.reported(offset)"), "\(reported)")
        let ended = Self.squeezed(try Self.body(["final class PhotoGridScroller", "func endAutoScroll("], in: Self.scrolling))
        #expect(ended == "{target.reset()Self.calibration.reset()}", "\(ended)")
        #expect(try Self.code(Self.scrolling).contains("private static var calibration = PhotoGridAutoScroll.Calibration()"))
    }

    // MARK: Pinch to zoom

    /// Two fingers change the photos in a row by a step (`PhotoGridZoom.Pinch`), UIKit's pinch
    /// beside the scroll view, which stops following the fingers once the pinch begins; the photo
    /// they hold (`PhotoGridHitTest.nearest`) is scrolled to where they are
    /// (`PhotoGridZoom.anchor`); the grid settles from the old size around them, not under
    /// Reduce Motion; the size is remembered, but not from one UI test to the next.
    @Test func pinchToZoomKeepsThePlace() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains(".gesture(PhotoGridPinch(isEnabled:!disabled,space:PhotoGridPlace.space,touchedDown:{gestures.touchedDown()})"
                              + "{touchinpinched(touch)})"), "\(view)")
        let recognizers = try Self.code(Self.recognizers)
        #expect(recognizers.contains("final class PhotoGridPinchRecognizer: UIPinchGestureRecognizer, UIGestureRecognizerDelegate {"))
        let stop = Self.squeezed(try Self.body(["final class PhotoGridPinchRecognizer", "func stopScrolling("], in: Self.recognizers))
        #expect(stop.hasSuffix("scrollPan.isEnabled=falsescrollPan.isEnabled=true}"), "\(stop)")
        let handled = Self.squeezed(try Self.body(["struct PhotoGridPinch", "func handleUIGestureRecognizerAction("], in: Self.recognizers))
        #expect(handled.contains("case.began:recognizer.stopScrolling()"), "\(handled)")
        let state = try Self.code(Self.state)
        #expect(state.contains("PhotoGridHitTest.nearest(x: Double(touch.inGrid.x), y: Double(touch.inGrid.y), in: all)"))
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
        #expect(Self.squeezed(said).hasPrefix("{guard!disabled,letnext=zoomingIn?PhotoGridZoom.fewer(than:columns):"
                                              + "PhotoGridZoom.more(than:columns)else{return}"), "not while the grid waits: \(said)")
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
        #expect(view.contains(".task(id:DaysKey(bucket:bucket,members:members,words:model.proposalWords,today:Self.today())){"
                              + "awaitmakeDays(of:members,in:bucket)}"), "\(view)")
        let key = Self.squeezed(try Self.body(["struct LibraryView", "private static func same<"], in: Self.library))
        #expect(key.contains("pa.baseAddress==pb.baseAddress"), "the same array, not equal contents: \(key)")
        let content = Self.squeezed(try Self.body(["struct LibraryView", "private func content("], in: Self.library))
        #expect(content.contains("letpage=days.shown(forPhotos:shown)grid(days.sections.prefix(page.days),limit:page.photos)"
                                 + "ifpage.photos<days.photoCount{moreComing(after:page.photos)}"), "\(content)")
        #expect(content.contains("}elseifdaysBucket==bucket,!days.sections.isEmpty{"),
                "another area's days under this filter, or none while it has photos: \(content)")
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
