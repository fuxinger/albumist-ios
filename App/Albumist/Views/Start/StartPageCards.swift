import SwiftUI
import AlbumistCore
import AlbumistEngine

// The start page's cards beside the suggestions' own (`StartSections`): "Dein Startpaket", the calm card
// when nothing is open, and the row "Alle Vorschläge" at the end.

/// "Dein Startpaket" (draft E1): the photos of its best albums, what it is, and the one filled
/// button of the page. Its preview shows every album before anything is made.
struct StarterSetCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    @Environment(\.colorSchemeContrast) private var contrast
    var set: [AlbumProposal]
    var onStart: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.largeCard, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // One cover per album, best first; tiles whose photo is not sharp try the ones after.
            StarterSetMosaic(ids: set.compactMap { model.proposalCoverIDs(for: $0).first })
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.top, Theme.Spacing.m)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Dein Startpaket")
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Die \(set.count) besten Alben aus deiner Mediathek. Du siehst vorher genau, was passiert.")
                    .font(.subheadline)
                    .foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onStart) {
                    if purchases.isUnlocked {
                        Text("\(set.count) Alben anlegen")
                    } else {
                        Text("\(set.count) Alben kostenlos anlegen")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, Theme.Spacing.s)
                .accessibilityIdentifier("starterSet.create")
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.m)
            .padding(.bottom, Theme.Spacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: shape)
        // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("startPage.starterSet")
    }
}

/// Nothing is open: one calm card that says why instead of empty rows ("Alles erledigt", "Wird
/// neu berechnet", "Noch keine Vorschläge"). Read as one element; the way to every suggestion is
/// "Alle Vorschläge" at the end of the page.
struct StartQuietCard: View {
    var title: Text
    var symbol: String
    var text: Text

    var body: some View {
        Card {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.headline)
            text
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Alle Vorschläge" at the end of the page (second review of the start page): the way to every
/// suggestion, also those of an area without an open one, a single one and those set aside with
/// "Nicht jetzt"; with their number and what the area list said before ("12 davon in deinen
/// Alben", "Wird neu berechnet"). A row like the system's lists: the symbol, the words, the
/// number at the end, the chevron; at the accessibility text sizes the words go below.
struct StartAllSuggestionsRow: View {
    var all: StartPage.AllSuggestions
    var onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        Button(action: onOpen) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        HStack {
                            IconTile(systemName: "rectangle.stack", tint: Theme.accent)
                            Spacer(minLength: Theme.Spacing.s)
                            count
                            chevron
                        }
                        words
                    }
                } else {
                    HStack(spacing: Theme.Spacing.m) {
                        IconTile(systemName: "rectangle.stack", tint: Theme.accent)
                        words
                        Spacer(minLength: Theme.Spacing.s)
                        count
                        chevron
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(RingCardRowButtonStyle())
        .background(Theme.card, in: shape)
        .clipShape(shape)
        // White on light grey is only 1.1:1; with Increase Contrast the row gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("startPage.allSuggestions")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Alle Vorschläge")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
            Group {
                if all.rebuilding {
                    Text("Wird neu berechnet")
                } else if all.inYourAlbums > 0 {
                    // The area list's words before design wave 1.
                    Text("\(all.inYourAlbums) davon in deinen Alben")
                }
            }
            .font(.footnote)
            .foregroundStyle(.noteText)
            .monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var count: some View {
        Text(all.total.formatted())
            .font(.body)
            .foregroundStyle(.noteText)
            .monospacedDigit()
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
