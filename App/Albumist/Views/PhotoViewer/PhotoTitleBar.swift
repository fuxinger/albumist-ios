import SwiftUI
import AlbumistCore

/// The photo view's title in the bar (design wave 2, DS-10), as in Photos: the place, below it
/// the day and the time; without a place the day, below it the time (`PhotoTitle`). A Live
/// Photo shows Photos' Live Photo symbol before the line: in the bar, never on the photo (design
/// rule 1).
///
/// For VoiceOver one heading: title and line in one sentence, "Live Photo" at its end. Like the
/// system's bar titles the text grows up to the larger standard sizes and a long press shows it
/// large beyond them (Large Content Viewer); a long place name is shortened on screen only,
/// VoiceOver and the large view say it whole.
struct PhotoTitleBar: View {
    var title: PhotoTitle
    var live: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(verbatim: title.title)
                .font(.headline)
            if title.subtitle != nil || live {
                line
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title.spoken(live: live)))
        .accessibilityAddTraits(.isHeader)
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("viewer.title")
    }

    /// "Heute · 09:05", after the Live Photo symbol for a Live Photo.
    private var line: some View {
        HStack(spacing: 4) {
            if live {
                Image(systemName: "livephoto")
            }
            if let subtitle = title.subtitle {
                Text(verbatim: subtitle)
            }
        }
        .font(.caption)
        .foregroundStyle(.noteText)
    }
}
