import SwiftUI
import AlbumistCore

// "Reise anpassen" as a timeline (design wave 3, DS-14): the pieces the sheet draws its days and
// the days without photos with. What each day shows and how the line runs is worked out in the
// core (`TripTimeline`); `TripWorkshopView` decides what a tap does. The neighbouring trips are
// sections of their own (review G3), not on the line.

/// The sizes the timeline's rows share.
enum TripTimelineMetrics {
    /// Above and below the words of a day.
    static let verticalPadding: CGFloat = 12
    /// Between the photos of a day.
    static let photoSpacing: CGFloat = 4
}

/// The line down the left of the timeline and its mark: a dot for a day, scissors where the new
/// trip begins. Solid between the days of the trip, dotted over days without photos; none
/// between the two trips a split makes (`TripTimeline.lines`). With Increase Contrast the line is
/// in the full accent. Decorative: the rows say what it shows.
struct TripTimelineGutter: View {
    enum Mark { case day, cut, none }
    typealias Line = TripTimeline.Stroke

    var mark: Mark
    /// The mark's centre from the top of the row; nil: the middle.
    var markY: CGFloat?
    var above: Line?
    var below: Line?

    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .headline) private var dot: CGFloat = 11

    var body: some View {
        GeometryReader { proxy in
            let x = proxy.size.width / 2
            let y = min(markY ?? proxy.size.height / 2, proxy.size.height)
            ZStack(alignment: .topLeading) {
                if let above { segment(above, from: 0, to: y, x: x) }
                if let below { segment(below, from: y, to: proxy.size.height, x: x) }
                markView
                    .position(x: x, y: y)
            }
        }
        .accessibilityHidden(true)
    }

    private var lineColor: Color {
        contrast == .increased ? Theme.accent : Theme.accent.opacity(0.4)
    }

    private func segment(_ line: Line, from top: CGFloat, to bottom: CGFloat, x: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: bottom))
        }
        // Round dots for the dotted line: a dash of almost nothing with round ends.
        .stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: line == .dotted ? [0.5, 6] : []))
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case .day:
            Circle()
                .fill(Theme.accent)
                .frame(width: dot, height: dot)
        case .cut:
            Image(systemName: "scissors")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        case .none:
            EmptyView()
        }
    }
}

/// A row of the timeline: the gutter on the left, the content beside it, at least 44 pt high so
/// the line runs on from row to row (the rows have no insets above and below).
struct TripTimelineRow<Content: View>: View {
    var mark: TripTimelineGutter.Mark
    /// The mark's centre from the top of the row; nil: the middle.
    var markY: CGFloat?
    var above: TripTimelineGutter.Line?
    var below: TripTimelineGutter.Line?
    @ViewBuilder var content: Content

    /// The gutter grows with the text up to a point, so the words keep their room.
    @ScaledMetric(relativeTo: .body) private var gutter: CGFloat = 20

    var body: some View {
        let width = min(gutter, 36)
        content
            .padding(.leading, width + Theme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(alignment: .leading) {
                TripTimelineGutter(mark: mark, markY: markY, above: above, below: below)
                    .frame(width: width)
            }
            .contentShape(Rectangle())
    }
}

/// One day of the trip on the timeline: its date, where it was and how many photos, with "Beginn
/// der Reise" or "Neue Reise ab hier" (`note`), and up to three larger photos spread over the day
/// (no text on them); "Vorschau ausgeblendet" for a day of nothing but sensitive documents. For
/// VoiceOver one element: date, place, count and note.
struct TripTimelineDayRow: View {
    var entry: TripTimeline.Day
    var note: String?
    /// The new trip begins with this day: scissors on the line, the words in the accent.
    var selected: Bool
    var above: TripTimelineGutter.Line?
    var below: TripTimelineGutter.Line?

    /// The date's line, for the mark beside it.
    @ScaledMetric(relativeTo: .headline) private var dateLine: CGFloat = 22

    var body: some View {
        TripTimelineRow(mark: selected ? .cut : .day, markY: TripTimelineMetrics.verticalPadding + dateLine / 2,
                        above: above, below: below) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.day.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    detail
                        .font(selected ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.noteText))
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                pictures
                    .padding(.top, Theme.Spacing.xs)
            }
            .padding(.vertical, TripTimelineMetrics.verticalPadding)
        }
    }

    /// "Reykjavík und Selfoss · 4 Fotos · Neue Reise ab hier".
    private var detail: Text {
        let count = Text("\(entry.day.count) \(entry.day.count.formatted()) Fotos")
        let place = entry.places.isEmpty ? count : Text("\(entry.places.formatted(.list(type: .and))) · \(count)")
        guard let note else { return place }
        return Text("\(place) · \(note)")
    }

    @ViewBuilder private var pictures: some View {
        if entry.hidesPreview {
            CoverPhoto(ids: [], aspectRatio: 3, cornerRadius: Theme.Radius.tile, hidesPreview: true)
        } else if !entry.photos.isEmpty {
            // Three columns whatever the day holds, so the photos of every day are the same size.
            let columns = Array(repeating: GridItem(.flexible(), spacing: TripTimelineMetrics.photoSpacing),
                                count: TripTimeline.photosPerDay)
            LazyVGrid(columns: columns, alignment: .leading, spacing: TripTimelineMetrics.photoSpacing) {
                ForEach(entry.photos, id: \.self) { id in
                    AssetThumbnail(id: id, side: 140)
                        .aspectRatio(1, contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Days without photos between two days of the trip on the timeline ("1 Tag ohne Fotos"), on a
/// dotted line; on none where the second trip of a split begins after them.
struct TripTimelineGapRow: View {
    var text: Text
    /// The line through it (`TripTimeline.Lines.gap`).
    var line: TripTimelineGutter.Line?

    var body: some View {
        TripTimelineRow(mark: .none, markY: nil, above: line, below: line) {
            text
                .font(.footnote)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Theme.Spacing.s)
        }
    }
}

extension View {
    /// A row of the timeline in the list: no separators, no insets above and below, so the line
    /// runs on from row to row.
    func tripTimelineRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.l, bottom: 0, trailing: Theme.Spacing.l))
            .listRowSeparator(.hidden)
    }
}
