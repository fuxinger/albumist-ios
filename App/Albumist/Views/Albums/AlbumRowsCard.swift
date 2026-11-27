import SwiftUI
import AlbumistCore
import AlbumistEngine

/// The rows between the shelf and "Deine Alben" (draft E4), on one card: "Ordner „Reisen“" for
/// each folder Albumist's new albums lie in (with 40 trips a shelf finds nothing), "Verlauf und
/// Rückgängig", and "Ähnliche Alben" while there are any. Plain numbers at the end, as in the
/// rows of Photos; VoiceOver says what they count.
struct AlbumRowsCard: View {
    var rows: [AlbumTabSections.Row]
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.largeCard, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    // Where the words start: after the symbol's column, at the accessibility
                    // sizes at the edge (the symbol stands above them).
                    Divider()
                        .padding(.leading, typeSize.isAccessibilitySize ? Theme.Spacing.l : Theme.Spacing.l + symbolWidth + Theme.Spacing.m)
                }
                link(row)
            }
        }
        .background(Theme.card, in: shape)
        .clipShape(shape)
        // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
    }

    @ViewBuilder
    private func link(_ row: AlbumTabSections.Row) -> some View {
        switch row {
        case .folder(let folder, let albums):
            let title = Text("Ordner „\(folder.title)“")
            PushLink(.folder(folder.id), chevron: false) {
                line(symbol: "folder", title: title, value: Text(albums.formatted()))
            }
            .accessibilityLabel(title)
            .accessibilityValue(Text("\(albums) Alben"))
            .accessibilityIdentifier("albums.folders")
        case .history(let changes, let more, let interrupted):
            let shown = changes.formatted() + (more ? "+" : "")
            PushLink(.history, chevron: false) {
                line(symbol: "clock.arrow.circlepath", title: Text("Verlauf und Rückgängig"),
                     value: interrupted ? Text("Unterbrochen") : changes > 0 ? Text(verbatim: shown) : nil)
            }
            .accessibilityLabel(Text("Verlauf und Rückgängig"))
            .accessibilityValue(interrupted ? Text("Unterbrochen")
                                : more ? Text("Mehr als \(changes) Änderungen") : Text("\(changes) Änderungen"))
            .accessibilityIdentifier("albums.history")
        case .similar(let count):
            PushLink(.similarAlbums, chevron: false) {
                line(symbol: "arrow.triangle.merge", title: Text("Ähnliche Alben"), value: Text(count.formatted()))
            }
            .accessibilityLabel(Text("Ähnliche Alben"))
            .accessibilityValue(Text("\(count) Vorschläge"))
            .accessibilityIdentifier("albums.similar")
        }
    }

    /// One row: the symbol in the accent, the title, the number, a chevron; 52 pt high or more.
    /// The number stands beside the title while both fit on one line, else under it, as in the
    /// value rows of Settings: beside a title that wraps, "Unterbrochen" broke inside the word
    /// from the text size xxLarge on (review A of design wave 1, finding 5). At the accessibility
    /// sizes the symbol and the chevron stand above the words, which get the whole width (as
    /// "Alle Vorschläge" on the start page).
    private func line(symbol: String, title: Text, value: Text?) -> some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        icon(symbol)
                        Spacer(minLength: Theme.Spacing.s)
                        chevron
                    }
                    words(title, value)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.m) {
                        icon(symbol)
                        title
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let value {
                            value
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize()
                        }
                        chevron
                    }
                    HStack(spacing: Theme.Spacing.m) {
                        icon(symbol)
                        words(title, value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        chevron
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    /// The symbol in the accent. Beside the words its column is as wide in every row, so the
    /// titles start in one line; above the words it stands at the edge.
    @ViewBuilder
    private func icon(_ symbol: String) -> some View {
        let image = Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
        if typeSize.isAccessibilitySize {
            image
        } else {
            image.frame(width: symbolWidth)
        }
    }

    /// The title and, under it, the number; both wrap between their words.
    private func words(_ title: Text, _ value: Text?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let value {
                value
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
