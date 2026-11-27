import MapKit
import SwiftUI
import AlbumistCore
import AlbumistMap

/// The map for laypeople (Fuchs, 26.11.2026: "Das müssen Laien bedienen können"; approved with
/// the clickable draft "Karte für alle"): Apple's map, calm and muted, with the user's countries,
/// trips and places as pins that all answer a tap (`MapTapAction`), a sheet below with one main
/// button, and "Reise abspielen" as a calm film over the region (`TripFilm`).
///
/// Opened from the travel atlas where `MapPrototypeGate` allows it (TestFlight and debug builds
/// for now). The measuring page of wave 0 stays reachable behind "Messwerte" in the menu.
struct WorldMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var data = WorldMapData()
    @State private var position: MapCameraPosition = .automatic
    @State private var groups: [MapPinGroup] = []
    @State private var selection: WorldMapSelection = .home
    @State private var playing: PlayingFilm?
    @State private var size: CGSize = .zero
    @State private var measuring = false
    /// Round buttons grow with the text size (their size at the default text size).
    @ScaledMetric(relativeTo: .body) private var buttonSide: CGFloat = 44

    /// The film being played, with a new identity for each start.
    struct PlayingFilm: Identifiable {
        let id = UUID()
        let trip: MapTrip
        let film: TripFilm
        let clock = FilmClock()
    }

    var body: some View {
        GeometryReader { proxy in
            MapReader { reader in
                map
                    .overlay {
                        if let playing {
                            TripFilmOverlay(layer: .route, playing: playing, photos: data.photos(playing.trip), reader: reader)
                                .id(playing.id)
                        }
                    }
            }
            .onAppear { size = proxy.size }
            .onChange(of: proxy.size) { size = proxy.size }
        }
        .ignoresSafeArea()
        .overlay {
            if let playing {
                TripFilmOverlay(layer: .controls, playing: playing, photos: data.photos(playing.trip)) {
                    stopFilm()
                } onAgain: {
                    play(playing.trip)
                }
                .id(playing.id)
            }
        }
        .overlay(alignment: .top) { if playing == nil { topBar } }
        .overlay { if !data.loaded { ProgressView().accessibilityLabel(Text("Karte wird geladen")) } }
        .sheet(isPresented: sheetShown) {
            WorldMapSheet(data: data, selection: $selection, onTap: perform, onPlay: play)
                // Presented from the sheet: the map below cannot present while the sheet is up.
                .fullScreenCover(isPresented: $measuring) {
                    MapPrototypeView().environment(model)
                }
                .presentationDetents([.fraction(0.42), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.42)))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
                .environment(model)
        }
        .task {
            await data.load(model)
            showAll(animated: false)
        }
    }

    private var sheetShown: Binding<Bool> {
        Binding(get: { data.loaded && playing == nil }, set: { _ in })
    }

    // MARK: The map

    private var map: some View {
        // During the film the camera stays still: the route is drawn on the screen over it.
        Map(position: $position, interactionModes: playing == nil ? .all : []) {
            if playing == nil {
                ForEach(groups) { group in
                    Annotation(GlobePinLabel.name(of: group.pin), coordinate: group.pin.coordinate.clCoordinate, anchor: .center) {
                        WorldMapPin(group: group, data: data) { perform(MapTapAction.action(for: group, pins: data.pinsByID)) }
                    }
                    .annotationTitles(.hidden)
                }
                if let home = data.summary?.home {
                    Annotation("Zuhause", coordinate: home.coordinate.clCoordinate, anchor: .center) {
                        Image(systemName: "house.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                            .accessibilityLabel(Text("Zuhause"))
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { context in
            regroup(context.region)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: buttonSide, height: buttonSide)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Circle())
            .accessibilityLabel(Text("Schließen"))
            .accessibilityIdentifier("worldmap.close")
            Spacer()
            Button {
                selection = .home
                showAll(animated: true)
            } label: {
                Label("Deine Welt", systemImage: "globe.europe.africa").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Capsule())
            .accessibilityIdentifier("worldmap.all")
            Menu {
                Button("Messwerte", systemImage: "gauge.with.dots.needle.50percent") { measuring = true }
                    .accessibilityIdentifier("worldmap.measure")
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: buttonSide, height: buttonSide)
            }
            .background(.regularMaterial, in: Circle())
            .accessibilityLabel(Text("Mehr"))
            .accessibilityIdentifier("worldmap.more")
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.s)
    }

    // MARK: Moving the map

    private func regroup(_ region: MKCoordinateRegion) {
        guard let pins = data.summary?.pins, size.width > 0 else { return }
        let viewport = MapViewport(center: GeoCoordinate(latitude: region.center.latitude, longitude: region.center.longitude),
                                   widthMeters: WorldMapCamera.widthMeters(of: region),
                                   widthPoints: size.width, heightPoints: size.height)
        groups = MapPins.onGlobe(pins, in: viewport)
    }

    private func move(to region: MKCoordinateRegion, seconds: Double = 1.1) {
        if reduceMotion {
            position = .region(region)
        } else {
            withAnimation(.easeInOut(duration: seconds)) { position = .region(region) }
        }
        regroup(region)
    }

    private func showAll(animated: Bool) {
        guard let summary = data.summary else { return }
        let focus = summary.focus ?? WorldMapCamera.focus(on: summary.trips.map(\.geometry.destination), minimumRadiusMeters: 300_000)
        guard let focus else { return }
        let region = WorldMapCamera.region(focus: focus, size: size)
        if animated { move(to: region) } else { position = .region(region); regroup(region) }
    }

    /// What a tap on a pin or a row does.
    private func perform(_ action: MapTapAction) {
        switch action {
        case .zoom(let focus):
            move(to: WorldMapCamera.region(focus: focus, size: size))
        case .showRegion(let region):
            if let focus = WorldMapCamera.focus(on: data.coordinates(ofRegion: region), minimumRadiusMeters: 400_000) {
                move(to: WorldMapCamera.region(focus: focus, size: size))
            }
        case .showCountry(let key):
            selection = .country(key)
            if let focus = WorldMapCamera.focus(on: data.coordinates(ofCountry: key), minimumRadiusMeters: 120_000) {
                move(to: WorldMapCamera.region(focus: focus, size: size))
            }
        case .showTrip(let id):
            selection = .trip(id)
            if let trip = data.trip(id) {
                let film = data.film(trip)
                move(to: WorldMapCamera.region(center: film.center, widthMeters: film.viewWidthMeters, size: size), seconds: 1.3)
            }
        case .showPlace(let id, let index):
            selection = .place(trip: id, placeIndex: index)
            if let trip = data.trip(id), trip.geometry.places.indices.contains(index) {
                move(to: WorldMapCamera.region(center: trip.geometry.places[index].coordinate, widthMeters: 60_000, size: size), seconds: 0.9)
            }
        }
    }

    // MARK: The film

    private func play(_ trip: MapTrip) {
        let film = data.film(trip)
        guard film.kind == .film else { return }
        playing = PlayingFilm(trip: trip, film: film)
        let region = WorldMapCamera.region(center: film.center, widthMeters: film.viewWidthMeters, size: size,
                                           covered: TripFilmOverlay.coveredShare)
        if reduceMotion {
            position = .region(region)
        } else {
            withAnimation(.easeInOut(duration: TripFilm.flyInSeconds)) { position = .region(region) }
        }
    }

    private func stopFilm() {
        playing = nil
        if case .trip(let id) = selection, let trip = data.trip(id) {
            let film = data.film(trip)
            move(to: WorldMapCamera.region(center: film.center, widthMeters: film.viewWidthMeters, size: size), seconds: 0.8)
        }
    }
}

/// One pin on the map: a country or world region as a capsule with its name, a trip or a place
/// as its cover photo with its name below, a group of pins as a round badge with their number.
/// All of them are buttons of at least 44 points.
struct WorldMapPin: View {
    let group: MapPinGroup
    let data: WorldMapData
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: GlobePinLabel.text(for: group.pin, groupSize: group.memberIDs.count)))
            .accessibilityHint(Text(group.memberIDs.count > 1 ? "Zoomt hinein" : "Öffnet die Fotos"))
            .accessibilityIdentifier("worldmap.pin.\(levelName)")
    }

    private var levelName: String {
        if group.memberIDs.count > 1 { return "group" }
        switch group.pin.level {
        case .worldRegion: return "region"
        case .country: return "country"
        case .trip: return "trip"
        case .place: return "place"
        }
    }

    @ViewBuilder private var label: some View {
        let pin = group.pin
        switch pin.level {
        case .worldRegion, .country:
            HStack(spacing: 8) {
                cover(side: 34)
                Text(verbatim: group.memberIDs.count > 1 ? countText : GlobePinLabel.name(of: pin))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.leading, 5).padding(.trailing, 12)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        case .trip, .place:
            VStack(spacing: 3) {
                if group.memberIDs.count > 1 {
                    Text(verbatim: String(group.memberIDs.count))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 46, height: 46)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                } else {
                    cover(side: 46).overlay(Circle().stroke(.white, lineWidth: 3))
                }
                Text(verbatim: GlobePinLabel.name(of: pin))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: 140)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }

    /// "3 Länder" for a group of countries or regions.
    private var countText: String {
        let n = group.memberIDs.count
        return group.pin.level == .worldRegion
            ? String(localized: "\(n) Weltgegenden")
            : String(localized: "\(n) Länder")
    }

    @ViewBuilder private func cover(side: CGFloat) -> some View {
        if let cover = group.pin.cover {
            AssetThumbnail(id: cover, side: side * 2).frame(width: side, height: side).clipShape(Circle())
        } else {
            Image(systemName: group.pin.level == .country ? "flag.fill" : "camera.fill")
                .font(.footnote)
                .foregroundStyle(Theme.onAccent)
                .frame(width: side, height: side)
                .background(Theme.accent, in: Circle())
        }
    }
}
