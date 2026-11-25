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
        // A suggestion's days with each photo's time on its own clock, made again only when they
        // change, or what the times are read from (its facts, the iPhone's clock; review L12).
        let sections = Self.squeezed(try Self.body(["struct ProposalPhotosView", "private var sections:"], in: Self.suggestions))
        #expect(sections.contains("grid.sections(for:days,facts:model.factsVersion,zone:.current)"), "\(sections)")
        #expect(sections.contains("PhotoGridSection.sections(days){facts[$0]?.wallClock(or:.current)}"), "\(sections)")
        let cache = Self.squeezed(try Self.body(["final class PhotoGridSectionsCache", "func sections("], in: Self.grid))
        #expect(cache.contains("if!isMade||!Self.same(days,self.days)||facts!=self.facts||zone!=self.zone{"), "\(cache)")
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
    /// a tap after it is one of its own, however soon after a drag or a pinch; so is an
    /// activation without a touch half a second or more after the gesture's end (VoiceOver's
    /// double tap, review W3), read on the screen's monotonic clock.
    @Test func aPhotoOpensAndTicksAsBefore() throws {
        let cell = try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.grid)
        let tap = Self.squeezed(cell)
        #expect(tap.contains("returnButton{guard!gestures.swallowsTapelse{return}guardselectingelse{open(id)return}"
                             + "ifisSelected{selection.remove(id)}else{selection.insert(id)}}"), "\(tap)")
        let lift = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "var swallowsTap: Bool"], in: Self.state))
        #expect(lift == "{lift.swallowsTap(at:CACurrentMediaTime())}", "\(lift)")
        let state = try Self.code(Self.state)
        #expect(!state.contains("Date()"), "the wall clock can jump")
        let end = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "func endDrag("], in: Self.state))
        #expect(end.contains("ifdrag!=nil||waiting!=nil{lift.gestureEnded(at:CACurrentMediaTime())}"), "\(end)")
        let endPinch = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "func endPinch("], in: Self.state))
        #expect(endPinch.contains("ifzooming!=nil{lift.gestureEnded(at:CACurrentMediaTime())}"), "\(endPinch)")
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
                         ".accessibilityIdentifier(identifier)"] {
            #expect(cell.contains(modifier), "\(modifier)")
        }
        // The tick on the photo is hidden from VoiceOver, which hears the photo's selected trait.
        let tick = try Self.body(["struct PhotoGrid: View", "private func tick("], in: Self.grid)
        #expect(cell.contains(".overlay(alignment: .bottomTrailing) { tick(isSelected) }"), "\(cell)")
        #expect(tick.contains(".accessibilityHidden(true)"), "\(tick)")
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
        #expect(AppSource.code(try ThumbnailSource.read(), keepStrings: true).contains("options.isNetworkAccessAllowed = false"))
        // No image of the old size of its own on top: the thumbnail keeps it.
        #expect(!(try Self.code(Self.grid)).contains("bridgeSide"), "a second image of the old size in the grid")
    }

    // MARK: Drag to select

    /// Whether a photo is on screen is read from the frames themselves (`PhotoGridOnScreen`,
    /// review W1): each photo and each day's header reports where it is in the grid, a frame that
    /// scrolling does not move, and nothing listens to SwiftUI's word that a cell appeared or
    /// went, whose order ("Auswählen" and "Fertig" rebuild every cell on screen) and pairing (a
    /// swipe back that is called off) SwiftUI does not promise. Each body hands over how the grid
    /// lays its photos out, so the frames of another layout are dropped; the gestures count what
    /// lies in the part of the grid the scroll view shows and is still at its place in the grid's
    /// order, so the photos of a page shown again are found with what they reported (review L1).
    @Test func aPhotoIsFoundAgainAfterThePageWasAway() throws {
        let cell = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func cell("], in: Self.grid))
        #expect(cell.hasSuffix(".onGeometryChange(for:PhotoGridPlace.self){proxyinPhotoGridPlace(position:entry.position,"
                               + "frame:proxy.frame(in:.named(PhotoGridPlace.space)))}action:{reportedingestures.place(id,reported)}}"),
                "\(cell)")
        let header = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func header("], in: Self.grid))
        for code in [cell, header] {
            #expect(!code.contains(".onAppear") && !code.contains(".onDisappear") && !code.contains("forget"), "\(code)")
        }
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains("let_:Void=gestures.show(PhotoGridShown(sections,below:limit),"
                              + "layout:PhotoGridLayout(columns:columns,width:Double(width)),pinsHeaders:pinned)"), "\(view)")
        let state = try Self.code(Self.state)
        #expect(state.contains("private var photos = PhotoGridOnScreen<AssetID, PhotoGridPlace>()"))
        for gone in ["func appeared(", "func disappeared(", "func headerAppeared(", "func headerDisappeared(", "places["] {
            #expect(!state.contains(gone), "\(gone)")
        }
        let show = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "func show("], in: Self.state))
        #expect(show.contains("photos.laidOut(layout)headers.laidOut(layout)"), "\(show)")
        // What lies in the part of the grid the scroll view shows, still at its place in the order.
        let cells = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func cells("], in: Self.state))
        #expect(cells.contains("photos.onScreen(seen?.visible,frame:{GridRect($0.frame)},where:{id,placein"), "\(cells)")
        #expect(cells.contains("place.position>=0&&place.position<ids.count&&ids[place.position]==id"), "\(cells)")
        let seen = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func seen("], in: Self.state))
        #expect(seen.contains("PhotoGridHitTest.visiblePart(gridY:Double(inGrid.y),scrollViewY:Double(inScrollView.y),"
                              + "height:scroller.height)"), "\(seen)")
        let height = Self.squeezed(try Self.body(["final class PhotoGridScroller", "var height:"], in: Self.scrolling))
        #expect(height == "{geometry.map{Double($0.containerSize.height)}}", "\(height)")
        // Where a drag begins, where it goes and where it scrolls on by itself, and the photo a
        // pinch holds: on screen, in each case where the finger is.
        let start = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func start("], in: Self.state))
        #expect(start.contains("letseen=self.seen(at:touch.inGrid,touch.inScrollView,in:pending.scroller)"), "\(start)")
        let extend = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func extend("], in: Self.state))
        #expect(extend.contains("letseen=self.seen(at:point,current.inScrollView,in:current.scroller)"), "\(extend)")
        let pinch = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "func beginPinch("], in: Self.state))
        #expect(pinch.contains("letonScreen=cells(in:ids,seen(at:touch.inGrid,touch.inScrollView,in:scroller))"), "\(pinch)")
        #expect(pinch.contains("PhotoGridHitTest.nearest(x:Double(touch.inGrid.x),y:Double(touch.inGrid.y),in:onScreen)"), "\(pinch)")
    }

    /// A day's header pinned over the photos scrolling under it hides them: each header reports
    /// where it is in the grid (pinned: where it is pinned), kept as the photos' frames are, and a
    /// finger on one is on no photo where a drag begins (`PhotoGridHitTest.position(…covered:)`),
    /// so it ticks nothing the user cannot see (review L4); a running drag goes on with the first
    /// row below it, while the page scrolls up under the finger (review W2). Only where the grid
    /// pins its headers, and only one at the top of what the user sees, where SwiftUI pins it: a
    /// header in its own place lies over no photo, and one reported before the days moved is not
    /// there any more.
    @Test func aPinnedHeaderHidesThePhotosUnderIt() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains("}header:{header(section,pinned:pinned)}"), "\(view)")
        let header = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func header("], in: Self.grid))
        #expect(header == "{PhotoGridHeader(section:section,pinned:pinned).onGeometryChange(for:CGRect.self){proxyin"
                          + "proxy.frame(in:.named(PhotoGridPlace.space))}action:{frameingestures.header(section.id,frame)}}",
                "\(header)")
        let state = try Self.code(Self.state)
        #expect(state.contains("private var headers = PhotoGridOnScreen<Int, CGRect>()"))
        let covered = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func covered("], in: Self.state))
        #expect(covered.hasPrefix("{guardpinsHeaderselse{return[]}"), "\(covered)")
        #expect(covered.contains("headers.onScreen(seen?.visible,frame:{GridRect($0)})"), "\(covered)")
        #expect(covered.contains("header.minY<=seen.barsEnd+header.height"), "\(covered)")
        let seen = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func seen("], in: Self.state))
        #expect(seen.contains("barsEnd:visible.lowerBound+(scroller.seenArea?.lowerBound??0)"), "\(seen)")
        let hits = state.components(separatedBy: "PhotoGridHitTest.position(").count - 1
        #expect(hits == 2 && state.components(separatedBy: "covered: covered").count - 1 == hits, "\(hits)")
        let start = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func start("], in: Self.state))
        #expect(start.contains("in:onScreen,covered:covered)}"), "a drag that begins on a header waits: \(start)")
        let extend = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func extend("], in: Self.state))
        #expect(extend.contains("covered:covered,onCovered:.rowBelow)"), "a running drag goes on below it: \(extend)")
    }

    /// A running drag follows the photos the grid shows now (review L3): the grid hands them to
    /// its gestures at every body (`PhotoGridShown`, compared by storage, its order made again
    /// only when it changed), and the range follows them by id where the finger goes and while
    /// the page scrolls by itself (`PhotoGridDrag.rebased`): more photos loaded at the bottom
    /// tick on, and when the range cannot be kept the drag ends, its photos ticked as they are.
    @Test func aDragFollowsThePhotosTheGridShowsNow() throws {
        let view = Self.squeezed(try Self.body(["struct PhotoGrid: View", "var body: some View"], in: Self.grid))
        #expect(view.contains("let_:Void=gestures.show(PhotoGridShown(sections,below:limit),"), "\(view)")
        let dragged = Self.squeezed(try Self.body(["struct PhotoGrid: View", "private func dragged("], in: Self.grid))
        #expect(dragged.contains("gestures.beginDrag(touch,selection:$selection,scroller:scroller)"), "\(dragged)")
        let extend = Self.squeezed(try Self.body(["final class PhotoGridGestureState", "private func extend("], in: Self.state))
        #expect(extend.hasPrefix("{follow()guardvarcurrent=dragelse{return}"), "\(extend)")
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
                              + "touchedDown:{gestures.touchedDown()},onTouch:{touchindragged(touch)}))"),
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
        // What `scrollTo(y:)` takes is learned from the scroll view, not assumed (review L5), and
        // checked in each run: while a probe waits for its answer, a frame asks nothing (review W4).
        #expect(scroll.hasPrefix("{guardletgeometry,Self.calibration.mayAsk()else{return}scrollsByItself=true"), "\(scroll)")
        #expect(scroll.contains("lety=Self.calibration.y(for:wanted,insetTop:insetTop)"
                                + "Self.calibration.asked(y,from:offset,insetTop:insetTop,range:top...bottom)"
                                + "position.scrollTo(y:CGFloat(y))"), "\(scroll)")
        // The lesson is the app's: only the scroll view that scrolls by itself answers its steps.
        let reported = Self.squeezed(try Self.body(["final class PhotoGridScroller", "func reported(_ geometry"], in: Self.scrolling))
        #expect(reported.hasSuffix("ifscrollsByItself{Self.calibration.reported(offset)}}"), "\(reported)")
        let ended = Self.squeezed(try Self.body(["final class PhotoGridScroller", "func endAutoScroll("], in: Self.scrolling))
        #expect(ended == "{scrollsByItself=falsetarget.reset()Self.calibration.reset()}", "\(ended)")
        #expect(try Self.code(Self.scrolling).contains("private static var calibration = PhotoGridAutoScroll.Calibration()"))
    }

    /// Scrolling by itself steps with the screen, up to 120 times a second on a ProMotion iPhone
    /// (review L13): the frame clock asks for it, and the app's Info.plist lets an iPhone give a
    /// display link more than 60 Hz (`CADisableMinimumFrameDurationOnPhone`, only that key).
    @Test func scrollingByItselfStepsWithTheScreen() throws {
        let start = Self.squeezed(try Self.body(["final class PhotoGridTicker", "func start("], in: Self.state))
        #expect(start.contains("link.preferredFrameRateRange=CAFrameRateRange(minimum:60,maximum:120,preferred:120)"), "\(start)")
        let project = try AppSource.read("App/project.yml")
        let info = try #require(project.range(of: "      path: Albumist/Resources/Info.plist\n"), "the app's Info.plist")
        let settings = try #require(project.range(of: "    settings:", range: info.upperBound..<project.endIndex))
        #expect(project[info.upperBound..<settings.lowerBound].contains("        CADisableMinimumFrameDurationOnPhone: true\n"))
    }
}
