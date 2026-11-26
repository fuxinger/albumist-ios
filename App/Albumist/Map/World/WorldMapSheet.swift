import SwiftUI
import AlbumistCore
import AlbumistMap

/// The sheet under the map for laypeople: the trips, or the chosen country, trip or place, each
/// with one main button. Rows and photos are buttons; the close button goes back to the trips.
struct WorldMapSheet: View {
    @Environment(AppModel.self) private var model
    let data: WorldMapData
    @Binding var selection: WorldMapSelection
    let onTap: (MapTapAction) -> Void
    let onPlay: (MapTrip) -> Void
    @State private var story: WorldPhotoStory?
    /// Round buttons grow with the text size (their size at the default text size).
    @ScaledMetric(relativeTo: .body) private var buttonSide: CGFloat = 44
    @State private var viewing: PhotoViewer.Start?
    @State private var countryPhotos: CountryCode?

    struct CountryCode: Identifiable { let id: String }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                switch selection {
                case .home: home
                case .country(let key): country(key)
                case .trip(let id): if let trip = data.trip(id) { tripView(trip) } else { home }
                case .place(let id, let index): if let trip = data.trip(id) { placeView(trip, index) } else { home }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .fullScreenCover(item: $story) { story in
            PhotoStoryView(story: story)
        }
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
        }
        .sheet(item: $countryPhotos) { code in
            NavigationRoot {
                CountryPhotosView(code: code.id, year: nil)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Fertig") { countryPhotos = nil }
                        }
                    }
            }
            .environment(model)
        }
    }

    // MARK: Parts

    private func header(_ title: String, _ subtitle: String?, closable: Bool) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.noteText) }
            }
            Spacer(minLength: 0)
            if closable {
                Button {
                    selection = .home
                } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).frame(width: buttonSide, height: buttonSide)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Schließen"))
                .accessibilityIdentifier("worldmap.sheet.close")
            }
        }
    }

    private func mainButton(_ title: LocalizedStringKey, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).font(.headline).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityIdentifier(identifier)
    }

    private func tripRow(_ trip: MapTrip) -> some View {
        Button {
            onTap(.showTrip(trip.id))
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Group {
                    if let cover = data.photos(trip).all.first ?? trip.geometry.places.first?.coverCandidates.first {
                        AssetThumbnail(id: cover, side: 112)
                    } else {
                        Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: trip.title).font(.body.weight(.semibold)).lineLimit(2)
                    Text(verbatim: WorldMapText.when(trip.geometry)).font(.subheadline).foregroundStyle(.noteText)
                }
                Spacer(minLength: 0)
                if data.film(trip).kind == .film {
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                        .accessibilityLabel(Text("Reise abspielen möglich"))
                }
            }
            .padding(Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("worldmap.trip")
    }

    private func grid(_ ids: [AssetID], all: [AssetID]) -> some View {
        let shown = Array(ids.prefix(9))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.element) { offset, id in
                Button {
                    viewing = PhotoViewer.Start(id: id, ids: all)
                } label: {
                    AssetThumbnail(id: id, side: 240)
                        .aspectRatio(1, contentMode: .fill)
                        .overlay {
                            if offset == shown.count - 1 && ids.count > shown.count {
                                ZStack {
                                    Color.black.opacity(0.45)
                                    Text(verbatim: "+\(ids.count - shown.count + 1)").font(.title3.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                        }
                        .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Foto öffnen"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    // MARK: Screens

    @ViewBuilder private var home: some View {
        let trips = data.trips
        let countries = Set(trips.flatMap { $0.geometry.countryPhotos.keys }).count
        let subtitle = [String(localized: "\(countries) Länder"), String(localized: "\(trips.count) Reisen")].joined(separator: ", ")
        header(String(localized: "Deine Reisen"), trips.isEmpty ? nil : subtitle, closable: false)
        if trips.isEmpty && data.loaded {
            ContentUnavailableView("Noch keine Reisen", systemImage: "map",
                                   description: Text("Sobald Albumist Reisen in deinen Fotos findet, stehen sie hier und auf der Karte."))
        }
        LazyVStack(spacing: Theme.Spacing.s) {
            ForEach(trips) { tripRow($0) }
        }
    }

    @ViewBuilder private func country(_ key: String) -> some View {
        let trips = data.trips(inCountry: key)
        let name = WorldMapText.countryName(key)
        let photos = trips.reduce(0) { $0 + ($1.geometry.countryPhotos[key] ?? 0) }
        header(name, [String(localized: "\(trips.count) Reisen"), String(localized: "\(photos) Fotos")].joined(separator: " · "), closable: true)
        mainButton("Alle Fotos ansehen", systemImage: "photo.on.rectangle", identifier: "worldmap.country.photos") {
            countryPhotos = CountryCode(id: key)
        }
        ForEach(trips) { tripRow($0) }
    }

    @ViewBuilder private func tripView(_ trip: MapTrip) -> some View {
        let film = data.film(trip)
        let photos = data.photos(trip)
        header(trip.title, [WorldMapText.when(trip.geometry), String(localized: "\(trip.geometry.photoCount) Fotos")].joined(separator: " · "), closable: true)
        switch film.kind {
        case .film:
            mainButton("Reise abspielen", systemImage: "play.fill", identifier: "worldmap.play") { onPlay(trip) }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(Array(film.stations.enumerated()), id: \.offset) { _, station in
                    stationRow(trip, station)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        case .flyTo, .photoStory:
            mainButton("Fotos ansehen", systemImage: "photo.on.rectangle", identifier: "worldmap.story") {
                story = WorldPhotoStory(trip: trip, photos: photos, places: Array(trip.geometry.places.indices))
            }
            Text(verbatim: hint(trip, film)).font(.subheadline).foregroundStyle(.noteText)
        }
        grid(photos.all, all: photos.all)
    }

    private func stationRow(_ trip: MapTrip, _ station: TripFilmStation) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Circle().fill(Color.orange).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.orange.opacity(0.3), lineWidth: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: WorldMapText.placeName(trip, station.mainPlaceIndex)).font(.body)
                if let others = TripFilmOverlay.others(trip, station) {
                    Text(verbatim: others).font(.footnote).foregroundStyle(.noteText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func hint(_ trip: MapTrip, _ film: TripFilm) -> String {
        if film.kind == .flyTo {
            let names = film.stations.map { WorldMapText.placeName(trip, $0.mainPlaceIndex) }
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return String(localized: "Diese Reise hat zwei Stationen: \(unique.formatted(.list(type: .and))). Ein Film lohnt sich erst ab drei.")
        }
        return String(localized: "Alles an einem Ort, deshalb siehst du die Fotos als Geschichte statt als Film.")
    }

    @ViewBuilder private func placeView(_ trip: MapTrip, _ index: Int) -> some View {
        let photos = data.photos(trip)
        let own = photos.photos(ofPlaces: [index])
        let count = trip.geometry.places.indices.contains(index) ? trip.geometry.places[index].photoCount : own.count
        let subtitle = [WorldMapText.when(trip.geometry), String(localized: "\(count) Fotos")].joined(separator: " · ")
        header(WorldMapText.placeName(trip, index), subtitle, closable: true)
        mainButton("Fotos ansehen", systemImage: "photo.on.rectangle", identifier: "worldmap.story") {
            story = WorldPhotoStory(trip: trip, photos: photos, places: [index])
        }
        if trip.geometry.places.count > 1 {
            Button {
                onTap(.showTrip(trip.id))
            } label: {
                Text("Zur ganzen Reise „\(trip.title)“").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("worldmap.place.trip")
        }
        grid(own, all: own)
    }
}
