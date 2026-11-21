import SwiftUI
import AlbumistCore

/// The photo view's title in the bar (design wave 2, DS-10), as in Photos: the place, below it
/// the day and the time; without a place the day, below it the time (`PhotoTitle`). A Live
/// Photo shows Photos' Live Photo symbol before the line: in the bar, never on the photo (design
/// rule 1).
///
/// Where the long form does not fit (a 375-point iPhone between Close, Share and Info), the
/// short one shows ("30.09.2024 · 14:32"); if even that is too long, it is cut at its start, so
/// what goes is never the time (review D, L1).
///
/// For VoiceOver one heading: title and line in one sentence, "Live Photo" at its end. Like the
/// system's bar titles the text grows up to the larger standard sizes and a long press shows it
/// large beyond them (Large Content Viewer); a long place name is shortened on screen only,
/// VoiceOver and the large view say it whole.
struct PhotoTitleBar: View {
    var title: PhotoTitle
    var live: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            lines(title.title, title.subtitle)
            lines(title.shortTitle, title.shortSubtitle)
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title.spoken(live: live)))
        .accessibilityAddTraits(.isHeader)
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("viewer.title")
    }

    /// The title, and the line below it.
    private func lines(_ first: String, _ second: String?) -> some View {
        VStack(spacing: 1) {
            Text(verbatim: first)
                .font(.headline)
                .minimumScaleFactor(0.8)
            if second != nil || live {
                line(second)
            }
        }
        .lineLimit(1)
    }

    /// "Heute · 09:05", after the Live Photo symbol for a Live Photo.
    private func line(_ text: String?) -> some View {
        HStack(spacing: 4) {
            if live {
                Image(systemName: "livephoto")
            }
            if let text {
                Text(verbatim: text)
                    .truncationMode(.head)
            }
        }
        .font(.caption)
        .foregroundStyle(.noteText)
    }
}
