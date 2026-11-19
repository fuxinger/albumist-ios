import SwiftUI
import SortlyCore
import SortlyEngine

/// Opened from the travel atlas: every photo taken in one country, newest year first,
/// with the places photographed most and, if Albumist has one, the album suggestion.
struct CountryPhotosView: View {
    @Environment(AppModel.self) private var model
    var code: String
    /// The year chosen in the atlas; nil = all years.
    var year: Int?
    /// A tap opens the photo large, its details behind "i" (design review W12).
    @State private var viewing: PhotoViewer.Start?
    /// The photo zooms out of its thumbnail and back into it.
    @Namespace private var zoom

    var body: some View {
        let country = model.countryPhotos(code, year: year)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header(country)
                if let proposal = model.countryProposal(for: country) {
                    PushLink(.proposal(ProposalRef(proposal)), chevron: false) {
                        suggestion(proposal)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(country.years) { group in
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        HStack(alignment: .firstTextBaseline) {
                            if let value = group.year {
                                Text(verbatim: String(value)).font(.title3.weight(.bold))
                            } else {
                                Text("Ohne Datum").font(.title3.weight(.bold))
                            }
                            Spacer()
                            Text("\(group.photos.count) Fotos").font(.subheadline).foregroundStyle(Theme.secondaryText).monospacedDigit() // on the photo wash
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        grid(group.photos, all: country.years.flatMap { $0.photos.map(\.id) })
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(alignment: .top) {
            // The country's own colours, taken from its newest photo that suits a cover.
            ZStack(alignment: .top) {
                Theme.background
                PhotoGlow(id: country.cover)
                    .frame(height: 440)
            }
            .ignoresSafeArea()
        }
        .navigationTitle(AtlasStyle.countryName(code))
        .overlay {
            if country.years.isEmpty {
                ContentUnavailableView("Keine Fotos", systemImage: "photo.on.rectangle",
                                       description: Text("Für dieses Land gibt es gerade keine Fotos."))
            }
        }
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
                .navigationTransition(.zoom(sourceID: start.id, in: zoom))
        }
        // "Widerrufen" stays in reach after the viewer closed (design review D4).
        .safeAreaInset(edge: .bottom) { IgnoreUndoBar() }
        .animation(.snappy, value: model.lastIgnored)
    }

    private func header(_ country: CountryPhotos) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text(TravelAtlas.flag(code)).font(.system(size: 44)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary(country)).font(.headline)
                if !country.topPlaces.isEmpty {
                    Text(country.topPlaces.formatted(.list(type: .and)))
                        .font(.subheadline).foregroundStyle(Theme.secondaryText) // sits on the photo wash
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, Theme.Spacing.s)
        .accessibilityElement(children: .combine)
    }

    private func summary(_ country: CountryPhotos) -> String {
        var parts = [String(localized: "\(country.photoCount) Fotos")]
        if country.tripCount > 0 { parts.append(String(localized: "\(country.tripCount) Reisen")) }
        if year == nil, let first = country.firstVisit {
            parts.append(String(localized: "seit \(String(Calendar.current.component(.year, from: first)))"))
        }
        return parts.joined(separator: " · ")
    }

    private func suggestion(_ proposal: AlbumProposal) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(systemName: "rectangle.stack.badge.plus", tint: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Album „\(model.userTitles[proposal.id] ?? proposal.title)“ anlegen").font(.body.weight(.medium))
                Text("Vorschlag mit \(proposal.assetIDs.count) Fotos").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.l)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(Rectangle())
    }

    private func grid(_ photos: [AssetFacts], all: [AssetID]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(photos, id: \.id) { facts in
                Button {
                    viewing = PhotoViewer.Start(id: facts.id, ids: all)
                } label: {
                    AssetThumbnail(id: facts.id, side: 110)
                        .aspectRatio(1, contentMode: .fill)
                        .matchedTransitionSource(id: facts.id, in: zoom)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(facts.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}
