import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// "Reise abspielen" for laypeople (Fuchs, 26.11.2026): places under 25 km are one station, the
/// film only from 3 different stations, a region-wide still view.
@Suite("Trip film")
struct TripFilmTests {
    typealias F = PlaybackFixture
    static let florenz = F.at(43.7696, 11.2558), fiesole = F.at(43.8066, 11.2936), sanGimignano = F.at(43.4677, 11.0431)
    static let siena = F.at(43.3188, 11.3308), pisa = F.at(43.7228, 10.4017)
    static let riva = F.at(45.8858, 10.8413), malcesine = F.at(45.7640, 10.8088), verona = F.at(45.4384, 10.9916)
    static let wien = F.at(48.2082, 16.3738), schoenbrunn = F.at(48.1845, 16.3122)

    /// A point `km` kilometres east of `origin` (on its latitude).
    static func east(of origin: GeoCoordinate, km: Double) -> GeoCoordinate {
        F.at(origin.latitude, origin.longitude + km * 1_000 / (GeoMath.metersPerDegreeLatitude * cos(origin.latitude * .pi / 180)))
    }

    static func film(_ points: [GeoCoordinate]) -> TripFilm {
        TripFilm(geometry: F.geometry(points.enumerated().map { ($0.element, $0.offset) }))
    }

    @Test("Places 4 km apart are one station with all their photos")
    func closePlacesMerge() {
        let film = Self.film([Self.florenz, Self.fiesole])
        #expect(film.stations.count == 1)
        #expect(film.stations[0].placeIndices == [0, 1])
        #expect(film.stations[0].photoCount == 20)
        #expect(film.kind == .photoStory)
    }

    @Test("24 km is one station, 26 km are two")
    func twentyFiveKilometres() {
        let origin = F.at(47, 11)
        #expect(Self.film([origin, Self.east(of: origin, km: 24)]).stations.count == 1)
        #expect(Self.film([origin, Self.east(of: origin, km: 26)]).stations.count == 2)
    }

    @Test("Toskana: Fiesole joins Florenz, four stations, a film")
    func tuscany() {
        let film = Self.film([Self.florenz, Self.fiesole, Self.sanGimignano, Self.siena, Self.pisa])
        #expect(film.stations.map(\.placeIndices) == [[0, 1], [2], [3], [4]])
        #expect(film.kind == .film)
    }

    @Test("Gardasee: Riva and Malcesine are one station, Verona the second: fly there, no film")
    func gardaLake() {
        let film = Self.film([Self.riva, Self.malcesine, Self.verona])
        #expect(film.stations.count == 2)
        #expect(film.kind == .flyTo)
    }

    @Test("A city trip is a photo story")
    func cityTrip() {
        #expect(Self.film([Self.wien, Self.schoenbrunn]).kind == .photoStory)
        #expect(Self.film([Self.wien]).kind == .photoStory)
    }

    @Test("There and back counts the start once: two different stations, no film")
    func thereAndBack() {
        let a = F.at(47, 11)
        let film = Self.film([a, Self.east(of: a, km: 100), a])
        #expect(film.stations.count == 3)
        #expect(TripFilm.differentStations(film.stations) == 2)
        #expect(film.kind == .flyTo)
    }

    @Test("Only places visited one after another merge; a station never swallows a far later place")
    func onlyNeighboursMerge() {
        let a = F.at(47, 11)
        // 0, 15, 30, 45, 60 km: the middle of the first station moves on as places join it.
        let film = Self.film((0..<5).map { Self.east(of: a, km: Double($0) * 15) })
        #expect(film.stations.map(\.placeIndices) == [[0, 1, 2], [3, 4]])
        #expect(film.kind == .flyTo)
    }

    @Test("The view shows a region, never a town")
    func regionScale() {
        let tuscany = Self.film([Self.florenz, Self.sanGimignano, Self.siena])
        #expect(tuscany.viewWidthMeters >= TripFilm.minimumViewMeters)
        let norway = Self.film([F.at(59.9139, 10.7522), F.at(62.1008, 7.2059), F.at(60.3913, 5.3221)])
        #expect(norway.viewWidthMeters > TripFilm.minimumViewMeters)
        for station in norway.stations {
            #expect(GeoMath.distance(norway.center, station.coordinate) <= norway.viewWidthMeters / 2)
        }
    }

    @Test("A station is named after its place with the most photos")
    func stationName() {
        var geometry = F.geometry([(Self.fiesole, 0), (Self.florenz, 0)])
        geometry.places[1].photoCount = 40
        #expect(TripFilm(geometry: geometry).stations[0].mainPlaceIndex == 1)
    }

    @Test("Places the route leaves out still count; places off the map are skipped")
    func placesOffRoute() {
        var geometry = F.geometry([(Self.florenz, 0), (Self.siena, 1), (Self.pisa, 2)])
        geometry.route.removeLast()
        geometry.places.append(TripPlace(coordinate: F.at(.nan, 0), name: "kaputt", countryKey: nil, photoCount: 5, days: [], coverCandidates: []))
        let film = TripFilm(geometry: geometry)
        #expect(film.stations.map(\.placeIndices) == [[0], [1], [2]])
    }

    @Test("The film runs in order: fly in, then each station reached, then the end")
    func timeline() {
        let film = Self.film([Self.florenz, Self.sanGimignano, Self.siena, Self.pisa])
        #expect(film.frame(at: 0).phase == .flyingIn(progress: 0))
        #expect(film.frame(at: TripFilm.flyInSeconds).phase == .atStation(0, progress: 0))
        #expect(film.frame(at: film.duration).phase == .finished)
        var reached = 0
        for step in 0...600 {
            let frame = film.frame(at: film.duration * Double(step) / 600)
            #expect(frame.reachedStations >= reached)
            reached = frame.reachedStations
        }
        #expect(reached == 4)
        if case .travelling(let to, let progress) = film.frame(at: (film.timeline[1].legStart + film.timeline[1].arrival) / 2).phase {
            #expect(to == 1)
            #expect(abs(progress - 0.5) < 1e-9)
        } else {
            Issue.record("expected travelling to station 1")
        }
    }

    @Test("A long trip plays in at most a minute")
    func longTrip() {
        let a = F.at(40, 0)
        let film = Self.film((0..<40).map { Self.east(of: a, km: Double($0) * 60) })
        #expect(film.stations.count == 40)
        #expect(film.duration <= TripFilm.maximumSeconds + 1e-9)
        #expect(film.duration > TripFilm.maximumSeconds - 1e-6)
    }

    @Test("A trip without places has no film")
    func empty() {
        let film = Self.film([])
        #expect(film.stations.isEmpty)
        #expect(film.kind == .photoStory)
        #expect(film.frame(at: 1).phase == .finished)
    }
}

@Suite("Map tap action")
struct MapTapActionTests {
    static let trip = AlbumistID("t1")

    static func pin(_ id: String, _ level: MapPinLevel, _ lat: Double, _ lon: Double, country: String? = nil, region: WorldRegion? = nil,
                    trip: AlbumistID? = nil, place: Int? = nil) -> MapPin {
        MapPin(id: id, level: level, coordinate: GeoCoordinate(latitude: lat, longitude: lon), countryKey: country, region: region, tripID: trip,
               placeIndex: place, count: 1)
    }

    @Test("Every pin kind does something")
    func everyKind() {
        #expect(MapTapAction.action(for: Self.pin("r", .worldRegion, 45, 10, region: .southernEurope)) == .showRegion(.southernEurope))
        #expect(MapTapAction.action(for: Self.pin("c", .country, 45, 10, country: "IT")) == .showCountry("IT"))
        #expect(MapTapAction.action(for: Self.pin("t", .trip, 45, 10, trip: Self.trip)) == .showTrip(Self.trip))
        #expect(MapTapAction.action(for: Self.pin("p", .place, 45, 10, trip: Self.trip, place: 3)) == .showPlace(trip: Self.trip, placeIndex: 3))
        #expect(MapTapAction.action(for: Self.pin("p", .place, 45, 10, trip: Self.trip)) == .showTrip(Self.trip))
    }

    @Test("A pin missing its data zooms in on itself instead of doing nothing")
    func missingData() {
        for level in MapPinLevel.allCases {
            guard case .zoom(let focus) = MapTapAction.action(for: Self.pin("x", level, 45, 10)) else {
                Issue.record("\(level) should zoom"); continue
            }
            #expect(GeoMath.distance(focus.center, GeoCoordinate(latitude: 45, longitude: 10)) < 1)
            #expect(focus.radiusMeters == MapTapAction.minimumZoomRadiusMeters)
        }
    }

    @Test("A group zooms in so that all its pins are in view")
    func groupZooms() {
        let a = Self.pin("a", .place, 43.77, 11.26, trip: Self.trip, place: 0)
        let b = Self.pin("b", .place, 43.32, 11.33, trip: Self.trip, place: 1)
        let group = MapPinGroup(pin: a, memberIDs: ["a", "b"])
        guard case .zoom(let focus) = MapTapAction.action(for: group, pins: ["a": a, "b": b]) else {
            Issue.record("expected zoom"); return
        }
        for p in [a, b] { #expect(GeoMath.distance(focus.center, p.coordinate) < focus.radiusMeters) }
        // A group of one opens its pin.
        #expect(MapTapAction.action(for: MapPinGroup(pin: a, memberIDs: ["a"]), pins: ["a": a]) == .showPlace(trip: Self.trip, placeIndex: 0))
    }
}
