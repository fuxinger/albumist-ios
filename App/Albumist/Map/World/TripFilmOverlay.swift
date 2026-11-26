import MapKit
import SwiftUI
import AlbumistCore
import AlbumistMap

/// "Reise abspielen" over the still map (`TripFilm`): after the camera has flown in, the line
/// grows from station to station, each station's dot and name stay, and a card shows the photos
/// of the station the dot has reached. Pause and close below; at the end "Nochmal" and "Fertig".
///
/// The map does not move during the film, so the stations are placed on the screen with the
/// map's own projection (`MapProxy.convert`) at each frame and drawn in a `Canvas`.
struct TripFilmOverlay: View {
    /// The share of the screen the card and the buttons cover at the bottom.
    static let coveredShare = 0.36

    let playing: WorldMapView.PlayingFilm
    let photos: TripPhotos
    let reader: MapProxy
    let onClose: () -> Void
    let onAgain: () -> Void
    @State private var played = 0.0
    /// Round buttons grow with the text size (their size at the default text size).
    @ScaledMetric(relativeTo: .body) private var buttonSide: CGFloat = 56
    @State private var runningSince: Date? = .now
    @Environment(\.scenePhase) private var scenePhase

    private var film: TripFilm { playing.film }
    private var trip: MapTrip { playing.trip }

    var body: some View {
        TimelineView(.animation(paused: runningSince == nil)) { context in
            let frame = film.frame(at: time(at: context.date))
            ZStack(alignment: .bottom) {
                route(frame)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(spacing: Theme.Spacing.m) {
                    card(frame)
                    controls(frame)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.l)
            }
            .overlay(alignment: .top) { titleBar(frame) }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { pause() }
        }
    }

    // MARK: Time

    private func time(at date: Date) -> Double {
        played + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    private func pause() {
        guard let since = runningSince else { return }
        played += Date.now.timeIntervalSince(since)
        runningSince = nil
    }

    private func resume() {
        if runningSince == nil { runningSince = .now }
    }

    // MARK: Drawing

    private func route(_ frame: TripFilmFrame) -> some View {
        Canvas { context, _ in
            if case .flyingIn = frame.phase { return }
            let reached = frame.reachedStations
            let points = film.stations.map { reader.convert($0.coordinate.clCoordinate, to: .local) }
            guard points.allSatisfy({ $0 != nil }) else { return }
            let screen = points.compactMap { $0 }
            let line = GraphicsContext.Shading.color(.orange)
            // Full legs up to the last reached station, then the growing one.
            for i in 1..<max(reached, 1) where i < screen.count {
                context.stroke(Self.curve(screen[i - 1], screen[i], upTo: 1).path, with: line, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            var dot: CGPoint? = reached > 0 ? screen[min(reached, screen.count) - 1] : nil
            if case let .travelling(to, progress) = frame.phase, to > 0, to < screen.count {
                let eased = progress * progress * (3 - 2 * progress)
                let grown = Self.curve(screen[to - 1], screen[to], upTo: eased)
                context.stroke(grown.path, with: line, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                dot = grown.end
            }
            for i in 0..<min(reached, screen.count) {
                let p = screen[i]
                context.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(.white))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: line)
                let name = WorldMapText.placeName(trip, film.stations[i].mainPlaceIndex)
                let flip = p.x > context.clipBoundingRect.width - 130
                let text = Text(verbatim: name).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                context.draw(text, at: CGPoint(x: flip ? p.x - 13 : p.x + 13, y: p.y), anchor: flip ? .trailing : .leading)
            }
            if let dot {
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 9, y: dot.y - 9, width: 18, height: 18)), with: .color(.white))
                context.stroke(Path(ellipseIn: CGRect(x: dot.x - 7, y: dot.y - 7, width: 14, height: 14)), with: line, lineWidth: 4)
            }
        }
    }

    /// A gentle curve from `a` to `b` (bent to the left of the way), drawn up to `share` of it.
    static func curve(_ a: CGPoint, _ b: CGPoint, upTo share: Double) -> (path: Path, end: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 0.001)
        let bend = min(60, length * 0.22)
        let control = CGPoint(x: (a.x + b.x) / 2 - dy / length * bend, y: (a.y + b.y) / 2 + dx / length * bend)
        func point(_ t: Double) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x, y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
        }
        var path = Path()
        path.move(to: a)
        let steps = 24
        let end = min(max(share, 0), 1)
        for step in 1...steps { path.addLine(to: point(end * Double(step) / Double(steps))) }
        return (path, point(end))
    }

    // MARK: Card and buttons

    private func titleBar(_ frame: TripFilmFrame) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: trip.title).font(.headline)
            Text(verbatim: WorldMapText.when(trip.geometry)).font(.subheadline).foregroundStyle(.noteText)
            HStack(spacing: 5) {
                ForEach(film.stations.indices, id: \.self) { i in
                    Circle().fill(i < frame.reachedStations ? Color.orange : Color(uiColor: .tertiaryLabel)).frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func card(_ frame: TripFilmFrame) -> some View {
        switch frame.phase {
        case .atStation(let index, _):
            stationCard(index).id(index).transition(.move(edge: .bottom).combined(with: .opacity))
        case .finished:
            endCard
        case .flyingIn, .travelling:
            EmptyView()
        }
    }

    private func stationCard(_ index: Int) -> some View {
        let station = film.stations[index]
        let ids = Array(photos.photos(ofPlaces: station.placeIndices).prefix(3))
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(verbatim: WorldMapText.placeName(trip, station.mainPlaceIndex)).font(.title3.weight(.bold))
            Text(verbatim: [Self.others(trip, station), String(localized: "\(station.photoCount) Fotos")].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.noteText)
            if !ids.isEmpty {
                HStack(spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        AssetThumbnail(id: id, side: 300)
                            .frame(maxWidth: .infinity)
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("worldmap.film.station")
    }

    private var endCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Das war \(trip.title)").font(.title3.weight(.bold))
            HStack(spacing: Theme.Spacing.s) {
                Button("Nochmal", action: onAgain)
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("worldmap.film.again")
                Button("Fertig", action: onClose)
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("worldmap.film.done")
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func controls(_ frame: TripFilmFrame) -> some View {
        HStack(spacing: Theme.Spacing.l) {
            if frame.phase != .finished {
                Button {
                    if runningSince == nil { resume() } else { pause() }
                } label: {
                    Image(systemName: runningSince == nil ? "play.fill" : "pause.fill").font(.title3).frame(width: buttonSide, height: buttonSide)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Circle())
                .accessibilityLabel(runningSince == nil ? Text("Weiter") : Text("Anhalten"))
                .accessibilityIdentifier("worldmap.film.pause")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: buttonSide, height: buttonSide)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Circle())
            .accessibilityLabel(Text("Schließen"))
            .accessibilityIdentifier("worldmap.film.close")
        }
    }

    /// "mit Fiesole, Settignano": the station's other places, if it has any with a name.
    static func others(_ trip: MapTrip, _ station: TripFilmStation) -> String? {
        let main = WorldMapText.placeName(trip, station.mainPlaceIndex)
        var names: [String] = []
        for index in station.placeIndices where index != station.mainPlaceIndex {
            let name = WorldMapText.placeName(trip, index)
            if name != main && name != trip.title && !names.contains(name) { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        return String(localized: "mit \(names.formatted(.list(type: .and)))")
    }
}
