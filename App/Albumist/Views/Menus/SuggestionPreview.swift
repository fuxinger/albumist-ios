import SwiftUI
import AlbumistCore

/// A suggestion large, as the long press lifts its card (design wave 2, DS-06a; like an album's
/// lifted preview, draft E4): its cover across, the album's name and the card's status line
/// below on the card's ground. "Vorschau ausgeblendet" wherever the card hides its photos (every
/// one a sensitive document): a lifted card never shows a photo its card does not show. Gets
/// everything handed in: the system draws it apart from the screen.
///
/// At the accessibility text sizes the cover is a wide strip and the texts wrap as far as they
/// need, so the whole name is in view (draft E7).
struct SuggestionPreview: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The card's cover candidates (`AppModel.proposalCoverIDs`).
    var covers: [AssetID]
    var hidesPreview: Bool
    /// The album's name, as the card shows it.
    var title: String
    /// The card's status line (`ProposalCardText.styledSubtitle`).
    var line: Text
    /// The symbol of the calm placeholder when no photo is sharp enough.
    var placeholderSymbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            texts
        }
        .frame(width: 320)
        .background(Theme.card)
    }

    /// Only from the device, sharp or the calm placeholder (`CoverPhoto`).
    private var cover: some View {
        CoverPhoto(ids: hidesPreview ? [] : covers, aspectRatio: typeSize.isAccessibilitySize ? 3 : 1.28,
                   cornerRadius: 0, hidesPreview: hidesPreview, placeholderSymbol: placeholderSymbol)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            line
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, 14)
    }
}
