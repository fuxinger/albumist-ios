import SwiftUI
import UIKit
import AlbumistCore

/// The photo grid of "Unsortiert" and of a suggestion's photos (design wave 3, DS-21 "Unsortiert
/// nach Tagen wie in Fotos" and DS-06b "Zoom wie überall"): the photos by day, as Photos shows
/// its days, edge to edge with 2 pt between them, three, five or seven in a row.
///
/// - A tap opens a photo large, zooming out of it (the page's `PhotoViewer`); while the page
///   selects ("Auswählen") it ticks the photo, and a finger drawn sideways ticks every photo
///   from the first it touched to the one under it, in the grid's order, across rows and days
///   (or unticks them, when the first was ticked), as in Photos. Near the top or bottom edge the
///   page scrolls on by itself. A vertical swipe scrolls as before. The long press offers what
///   the page offers for the photo (DS-06a), none while selecting.
/// - Two fingers change how many photos a row shows, in steps, and the photo under them stays
///   under them; VoiceOver's zoom and the photo's actions "Vergrößern" and "Verkleinern" do the
///   same without two fingers (Switch Control, Voice Control, a keyboard). The size is
///   remembered, one for both grids, as Photos keeps one zoom for its library.
/// - The page's scroll view lets the grid move it (`photoGridScrolling()`); without that the
///   grid selects and zooms, but neither scrolls by itself nor keeps its place.
///
/// What the gestures decide is the core's (`PhotoGridDrag`, `PhotoGridHitTest`,
/// `PhotoGridAutoScroll`, `PhotoGridZoom`); the days are the page's (`InboxDays`,
/// `PhotoGridSection.sections`).
struct PhotoGrid: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.photoGridScroller) private var scroller
    /// The days shown, in the grid's order, each photo with its place in it.
    var sections: ArraySlice<PhotoGridSection>
    /// Where the photos are, for their long press (`PhotoMenu`).
    var place: PhotoMenu.Place
    var selecting: Bool
    @Binding var selection: Set<AssetID>
    /// The photos' long press offers something (`PhotoMenu.isOffered`).
    var available = true
    /// Nothing opens, ticks or zooms (a suggestion while it is being made).
    var disabled = false
    /// The day's header stays at the top while its photos scroll under it ("Unsortiert"); never
    /// at the accessibility text sizes, where a header can take several lines of the screen.
    var pinsHeaders = false
    /// The page's namespace for the photo view's zoom out of the photo.
    var zoom: Namespace.ID
    /// Each photo's accessibility identifier, for the UI tests.
    var identifier: String
    var open: (AssetID) -> Void
    /// An item of a photo's long press, the page's way.
    var perform: (PhotoMenu.Item, AssetID) -> Void
    /// Photos in a row as the user last pinched (`PhotoGridZoom.columns(stored:)` reads it).
    @AppStorage(PhotoGridMemory.key, store: PhotoGridMemory.defaults) private var storedColumns = PhotoGridZoom.standard
    /// The grid's width, for the side of its photos.
    @State private var width: CGFloat = 0
    @State private var gestures = PhotoGridGestureState()
    @State private var settle = PhotoGridSettle()

    var body: some View {
        let _ = MainThreadWatch.shared.count("photo grid body")
        let columns = PhotoGridZoom.columns(stored: storedColumns)
        let side = CGFloat(PhotoGridZoom.side(width: Double(width), columns: columns))
        // A copy for the animation, which runs apart from the view.
        let settle = self.settle
        let pinned = pinsHeaders && !typeSize.isAccessibilitySize
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CGFloat(PhotoGridZoom.spacing)), count: columns),
                  spacing: CGFloat(PhotoGridZoom.spacing),
                  pinnedViews: pinned ? [.sectionHeaders] : []) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        cell(entry, side: side, columns: columns)
                    }
                } header: {
                    PhotoGridHeader(section: section, pinned: pinned)
                }
            }
        }
        // The scroll view finds a photo by its id (`PhotoGridScroller.show`).
        .scrollTargetLayout()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        // Fingers between two photos are on the grid too.
        .contentShape(Rectangle())
        .gesture(PhotoGridSelectDrag(isEnabled: selecting && !disabled, space: PhotoGridPlace.space) { touch in dragged(touch) })
        .gesture(PhotoGridPinch(isEnabled: !disabled, space: PhotoGridPlace.space) { touch in pinched(touch) })
        .coordinateSpace(.named(PhotoGridPlace.space))
        // After a pinch's step the grid settles from the old size around the fingers, so the
        // step looks like a zoom; not under Reduce Motion (`step(to:)`).
        .keyframeAnimator(initialValue: 1.0, trigger: settle.count) { content, scale in
            content.visualEffect { effect, proxy in
                effect.scaleEffect(CGFloat(scale), anchor: PhotoGridSettle.anchor(of: settle.point, in: proxy.frame(in: .scrollView)))
            }
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(settle.from)
                CubicKeyframe(1.0, duration: 0.3)
            }
        }
    }

    /// One photo: a tap opens it, or ticks it while the grid selects; its long press lifts it
    /// with what the page offers for it (DS-06a), none while selecting.
    private func cell(_ entry: PhotoGridEntry, side: CGFloat, columns: Int) -> some View {
        let id = entry.id
        let isSelected = selection.contains(id)
        // A real button: VoiceOver, Switch Control and the hit-area audit see it as one.
        return Button {
            // The lift that ends a drag or a pinch is no tap: the drag ticked its first photo
            // already, and a pinch opens nothing.
            guard !gestures.endsGesture else { return }
            guard selecting else {
                open(id)
                return
            }
            if isSelected { selection.remove(id) } else { selection.insert(id) }
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    // Sharp at the size shown: after a zoom step the thumbnail asks for its new
                    // side and keeps the image of the old one until that is there (its task
                    // follows the photo and its side). Never `.id(side)`: each step would build
                    // the thumbnails anew, their ground over the old images.
                    if side > 0 {
                        AssetThumbnail(id: id, side: side)
                    }
                }
                .clipped()
                .matchedTransitionSource(id: id, in: zoom)
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        // On the photo, which does not grow with the text: it stops growing
                        // where it would cover a photo of seven in a row.
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Theme.accent : Color.black.opacity(0.25))
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
                .opacity(selecting && !isSelected ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text(Self.spokenDate(entry)))
        .accessibilityAddTraits(selecting && isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        // The pinch without two fingers: VoiceOver's zoom, and the actions for Switch Control,
        // Voice Control and a keyboard, only those that make a step (none while the grid waits).
        .accessibilityZoomAction { action in
            step(zoomingIn: action.direction == .zoomIn, on: id, columns: columns)
        }
        .accessibilityActions {
            if !disabled, PhotoGridZoom.fewer(than: columns) != nil {
                Button("Vergrößern") { step(zoomingIn: true, on: id, columns: columns) }
            }
            if !disabled, PhotoGridZoom.more(than: columns) != nil {
                Button("Verkleinern") { step(zoomingIn: false, on: id, columns: columns) }
            }
        }
        // The long press (DS-06a): the photo larger, and what the page offers for it.
        .photoMenu(id, place: place, side: side, selecting: selecting, available: available) { item in
            perform(item, id)
        }
        // Where it is, for the fingers of the gestures.
        .onGeometryChange(for: PhotoGridPlace.self) { proxy in
            PhotoGridPlace(position: entry.position, frame: proxy.frame(in: .named(PhotoGridPlace.space)))
        } action: { reported in
            gestures.place(id, reported)
        }
        .onDisappear { gestures.forget(id) }
    }

    /// The photo's date and time on the clock where it was taken, as its day's header says it
    /// (its wall clock, read in UTC). The UI tests find the photos by the year in it.
    private static func spokenDate(_ entry: PhotoGridEntry) -> String {
        guard let wall = entry.wallClock else { return String(localized: "Foto") }
        return wall.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .gmt))
    }

    // MARK: Gestures

    private func dragged(_ touch: PhotoGridTouch) {
        switch touch.phase {
        case .began:
            gestures.beginDrag(touch, ids: sections.flatMap { $0.entries.map(\.id) }, selection: $selection, scroller: scroller)
        case .changed:
            gestures.moveDrag(touch)
        case .ended:
            gestures.endDrag()
        }
    }

    private func pinched(_ touch: PhotoGridTouch) {
        switch touch.phase {
        case .began:
            gestures.beginPinch(touch, columns: PhotoGridZoom.columns(stored: storedColumns), scroller: scroller)
        case .changed:
            guard let zoom = gestures.pinch(touch) else { return }
            step(to: zoom.to, from: zoom.from, keeping: zoom.photo, anchor: { side in
                PhotoGridZoom.anchor(fingerY: zoom.fingerY, visibleHeight: zoom.visibleHeight, side: side, pointInPhoto: zoom.pointInPhoto)
            }, around: zoom.point)
        case .ended:
            gestures.endPinch()
        }
    }

    /// One step to `columns` photos in a row from `old`: remembered; `photo` scrolled to where
    /// `anchor` says for the new side (`PhotoGridScroller.show`); each thumbnail keeps its old
    /// image until the new side's is there (`AssetThumbnail`); and the grid settling from the old
    /// size around `point` (the fingers), not under Reduce Motion, where the step is a plain change.
    private func step(to columns: Int, from old: Int, keeping photo: AssetID?, anchor: (Double) -> Double, around point: CGPoint?) {
        guard width > 0, columns != old else { return }
        let oldSide = PhotoGridZoom.side(width: Double(width), columns: old)
        let newSide = PhotoGridZoom.side(width: Double(width), columns: columns)
        storedColumns = columns
        if let photo { scroller?.show(photo, unitY: anchor(newSide)) }
        if let point, !reduceMotion {
            settle = PhotoGridSettle(count: settle.count + 1, from: PhotoGridZoom.settleScale(oldSide: oldSide, newSide: newSide),
                                     point: point)
        }
    }

    /// A step without two fingers (VoiceOver's zoom, "Vergrößern", "Verkleinern") on `photo`:
    /// it stays in the middle of the screen, and the new size is said. Not while the grid waits,
    /// as the pinch.
    private func step(zoomingIn: Bool, on photo: AssetID, columns: Int) {
        guard !disabled, let next = zoomingIn ? PhotoGridZoom.fewer(than: columns) : PhotoGridZoom.more(than: columns) else { return }
        step(to: next, from: columns, keeping: photo, anchor: { _ in 0.5 }, around: nil)
        AccessibilityNotification.Announcement(String(localized: "\(next) \(next.formatted()) Fotos pro Reihe")).post()
    }
}

/// A day's header: "Samstag, 12. Oktober" with "3 Fotos" at the end of the line; below each
/// other at the accessibility text sizes, wrapped rather than cut. A heading for VoiceOver's
/// rotor. Pinned over the photos it lies on the page's ground, so no text lies on a photo;
/// otherwise it has no ground of its own (a suggestion's page is tinted by its photo).
struct PhotoGridHeader: View {
    var section: PhotoGridSection
    var pinned = false

    var body: some View {
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(verbatim: section.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: section.countText)
                .font(.subheadline)
                .foregroundStyle(.noteText)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pinned ? Theme.background : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Where the grids remember how many photos a row shows (`PhotoGridZoom`): the app's defaults,
/// one size for both grids. A UI run starts at the standard size, so one test's pinch does not
/// change what the next one finds where.
enum PhotoGridMemory {
    static let key = "photoGrid.columns"

    static var defaults: UserDefaults {
        _ = forgetsInUITests
        return .standard
    }

    private static let forgetsInUITests: Bool = {
        if UITestSupport.isRunning { UserDefaults.standard.removeObject(forKey: key) }
        return true
    }()
}

/// The grid settling from the old size after a pinch's step (`PhotoGridZoom.settleScale`)
/// around the fingers (`point`, in the scroll view): each step counts on, which starts it anew.
struct PhotoGridSettle: Sendable {
    var count = 0
    var from = 1.0
    var point = CGPoint.zero

    /// `point` as a unit point of `frame` (the grid, in the same space).
    static func anchor(of point: CGPoint, in frame: CGRect) -> UnitPoint {
        guard frame.width > 0, frame.height > 0 else { return .center }
        return UnitPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }
}

/// Where a photo of the grid is, as it reports it for the gestures: its place in the grid's
/// order and its frame in the grid.
struct PhotoGridPlace: Equatable, Sendable {
    /// The grid's coordinate space, in which the photos' frames and the fingers are read.
    static let space = "photoGrid"
    var position: Int
    var frame: CGRect
}

/// A suggestion's days as the grid's sections, made again only when its page hands over other
/// days (`ProposalPageCache` makes them anew when the suggestion or the facts change), not each
/// time the page draws (at every letter of a name and every tick of a photo).
@MainActor
final class PhotoGridSectionsCache {
    private var days: [PhotoDay] = []
    private var made: [PhotoGridSection] = []
    private var isMade = false

    func sections(for days: [PhotoDay], make: () -> [PhotoGridSection]) -> [PhotoGridSection] {
        if !isMade || !Self.same(days, self.days) {
            made = make()
            self.days = days
            isMade = true
        }
        return made
    }

    /// The same array (its storage), whatever its contents.
    private static func same(_ a: [PhotoDay], _ b: [PhotoDay]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }
}
