import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// Building the pins of all levels (concept §4.2, "Stecknadeln nach Bedeutung"): every pin at a
/// real place of a trip, never at home, never at a computed middle that could lie in the sea.
@Suite("Map pins: building")
struct MapPinsBuilderTests {
    typealias Place = MapHandmade.Places
    let calendar = MapFixture.calendar

    @Test func pinsStandAtRealTripPlacesNeverInTheSea() throws {
        // Island hopping in Dalmatia: the middle of these places lies in the sea between the islands.
        let places = [
            MapHandmade.place(Place.split, "Split", "HR", photos: 30, covers: ["split-1"]),
            MapHandmade.place(Place.hvar, "Hvar", "HR", photos: 60, covers: ["hvar-1", "hvar-2"]),
            MapHandmade.place(Place.vis, "Vis", "HR", photos: 40, covers: ["vis-1"]),
            MapHandmade.place(Place.komiza, "Komiža", "HR", photos: 25),
        ]
        let croatia = MapHandmade.trip("croatia", "2022-08-01", places)
        let countries = [MapHandmade.country("HR", "2022-08-01", trips: ["croatia"], region: .southernEurope)]
        let pins = MapPins.build(trips: [croatia], countries: countries)
        #expect(pins.count == 1 + 1 + 1 + 4)
        let real = Set(places.map(\.coordinate))
        #expect(pins.allSatisfy { real.contains($0.coordinate) })
        let middle = try #require(GeoMath.centroid(places.map(\.coordinate)))
        #expect(!pins.contains { GeoMath.distance($0.coordinate, middle) < 5_000 })
        // Country, region and trip at the place with the most photos.
        #expect(pins.first { $0.id == "country:HR" }?.coordinate == Place.hvar)
        #expect(pins.first { $0.id == "region:southernEurope" }?.coordinate == Place.hvar)
        #expect(pins.first { $0.id == "trip:croatia" }?.coordinate == Place.hvar)
        // Never at home.
        #expect(!pins.contains { $0.coordinate == MapHandmade.home.coordinate })
    }

    @Test func theHomeCountryWithOnlyEverydayPhotosHasNoPinButCountsInItsRegion() throws {
        let tirol = MapHandmade.trip("tirol", "2023-02-10", [MapHandmade.place(Place.innsbruck, "Innsbruck", "AT", photos: 45)])
        let countries = [
            // 20,000 everyday photos at home, no trip: tinted only.
            MapHandmade.country("DE", "2009-01-01", trips: [], region: .westernEurope, photos: 20_000),
            MapHandmade.country("AT", "2023-02-10", trips: ["tirol"], region: .westernEurope),
        ]
        let pins = MapPins.build(trips: [tirol], countries: countries)
        #expect(!pins.contains { $0.id == "country:DE" })
        #expect(pins.contains { $0.id == "country:AT" && $0.coordinate == Place.innsbruck && $0.count == 1 })
        let region = try #require(pins.first { $0.id == "region:westernEurope" })
        #expect(region.count == 2)
        #expect(region.coordinate == Place.innsbruck)
        #expect(region.level == .worldRegion && region.region == .westernEurope && region.title == nil && region.countryKey == nil)
        // Without any trip abroad there is no pin at all: no country pin, so no region pin either.
        #expect(MapPins.build(trips: [], countries: [countries[0]]).isEmpty)
        // What decides is the trip's photos per country (as `MapCountry.tripIDs` counts them), not
        // a place's key alone.
        let noPhotosThere = MapHandmade.trip("tirol", "2023-02-10", [MapHandmade.place(Place.innsbruck, "Innsbruck", "AT", photos: 45)],
                                             countryPhotos: ["DE": 45])
        #expect(!MapPins.build(trips: [noPhotosThere], countries: countries).contains { $0.level == .country })
    }

    @Test func aTripThroughTwoCountriesGivesEachItsPinAtItsOwnPlace() {
        let places = [
            MapHandmade.place(MapFixture.Places.reykjavik, "Reykjavík", "IS", photos: 50),
            MapHandmade.place(MapFixture.Places.vik, "Vík", "IS", photos: 20),
            MapHandmade.place(Place.nuuk, "Nuuk", "GL", photos: 30),
            MapHandmade.place(Place.ilulissat, "Ilulissat", "GL", photos: 35),
        ]
        let north = MapHandmade.trip("north", "2023-06-14", places)
        let countries = [
            MapHandmade.country("IS", "2023-06-14", trips: ["north"], region: .northernEurope),
            MapHandmade.country("GL", "2023-06-16", trips: ["north"], region: .northernAmerica, isState: false),
        ]
        let pins = MapPins.build(trips: [north], countries: countries)
        #expect(pins.first { $0.id == "country:IS" }?.coordinate == MapFixture.Places.reykjavik)
        #expect(pins.first { $0.id == "country:GL" }?.coordinate == Place.ilulissat)
        #expect(pins.first { $0.id == "region:northernEurope" }?.coordinate == MapFixture.Places.reykjavik)
        #expect(pins.first { $0.id == "region:northernAmerica" }?.coordinate == Place.ilulissat)
        #expect(pins.filter { $0.level == .country }.allSatisfy { $0.count == 1 && $0.years == [2023] })
        // One trip, one trip pin: at its destination, the place with the most photos.
        #expect(pins.filter { $0.level == .trip }.map(\.coordinate) == [MapFixture.Places.reykjavik])
        #expect(pins.filter { $0.level == .place }.count == 4)
    }

    @Test func idsAreStable() {
        let rome = MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80),
                                                           MapHandmade.place(Place.ciampino, nil, "IT", photos: 20)])
        let italy = MapHandmade.country("IT", "2019-05-02", trips: ["rome"], region: .southernEurope)
        let pins = MapPins.build(trips: [rome], countries: [italy])
        #expect(pins.map(\.id) == ["region:southernEurope", "country:IT", "trip:rome", "place:rome:0", "place:rome:1"])
        // An unrelated trip adds its own pins and changes none of these.
        let tokyo = MapHandmade.trip("tokyo", "2023-03-02", [MapHandmade.place(MapFixture.Places.tokyo, "Tokio", "JP", photos: 500)])
        let japan = MapHandmade.country("JP", "2023-03-02", trips: ["tokyo"], region: .easternAsia)
        let more = MapPins.build(trips: [tokyo, rome], countries: [japan, italy])
        #expect(more.count == pins.count + 4)
        for pin in pins {
            #expect(more.first { $0.id == pin.id } == pin)
        }
        #expect(MapPins.build(trips: [rome], countries: [italy]) == pins)
    }

    @Test func pinsAreOrderedByLevelThenCountThenID() {
        let rome = MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80),
                                                           MapHandmade.place(Place.ciampino, nil, "IT", photos: 20)])
        let lisbon = MapHandmade.trip("lisbon", "2022-10-02", [MapHandmade.place(MapFixture.Places.lisbon, "Lissabon", "PT", photos: 30),
                                                               MapHandmade.place(MapFixture.Places.porto, "Porto", "PT", photos: 30)])
        let countries = [MapHandmade.country("PT", "2022-10-02", trips: ["lisbon"], region: .southernEurope),
                         MapHandmade.country("IT", "2019-05-02", trips: ["rome"], region: .southernEurope)]
        let pins = MapPins.build(trips: [lisbon, rome], countries: countries)
        #expect(pins.map(\.id) == [
            "region:southernEurope",
            "country:IT", "country:PT",
            "trip:rome", "trip:lisbon",
            "place:rome:0", "place:lisbon:0", "place:lisbon:1", "place:rome:1",
        ])
        #expect(pins.map(\.count) == [2, 1, 1, 100, 60, 80, 30, 30, 20])
    }

    @Test func disputedAreasNeverMakeACountryPin() {
        let kashmir = MapHandmade.trip("kashmir", "2012-07-01", [MapHandmade.place(MapFixture.at(34.0837, 74.7973), "Srinagar", "disputed-kashmir", photos: 40)])
        // Even if a disputed key came in as a country, it makes no country pin and no region badge.
        let countries = [MapHandmade.country("disputed-kashmir", "2012-07-01", trips: ["kashmir"], region: .southernAsia)]
        let pins = MapPins.build(trips: [kashmir], countries: countries)
        #expect(!pins.contains { $0.level == .country || $0.level == .worldRegion })
        // The trip and its place keep the key: the app says "nicht sicher" there.
        #expect(pins.map(\.id) == ["trip:kashmir", "place:kashmir:0"])
        #expect(pins.allSatisfy { $0.countryKey == "disputed-kashmir" })
    }

    @Test func coversComeFromTheDestinationElseFromAnotherPlace() {
        let rome = MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80, covers: ["rome-1", "rome-2"]),
                                                           MapHandmade.place(Place.ciampino, nil, "IT", photos: 20, covers: ["ciampino-1"])])
        // The destination (Lisbon, most photos) has no candidate: the trip's photo comes from its
        // place with the most photos that has one (Sintra), as does the country's.
        let portugal = MapHandmade.trip("portugal", "2022-10-02", [
            MapHandmade.place(MapFixture.Places.lisbon, "Lissabon", "PT", photos: 50),
            MapHandmade.place(MapFixture.Places.porto, "Porto", "PT", photos: 30, covers: ["porto-1"]),
            MapHandmade.place(MapFixture.at(38.8029, -9.3817), "Sintra", "PT", photos: 40, covers: ["sintra-1"]),
        ])
        let bare = MapHandmade.trip("bare", "2023-01-02", [MapHandmade.place(MapFixture.Places.tokyo, "Tokio", "JP", photos: 30)])
        let countries = [MapHandmade.country("IT", "2019-05-02", trips: ["rome"], region: .southernEurope),
                         MapHandmade.country("PT", "2022-10-02", trips: ["portugal"], region: .southernEurope),
                         MapHandmade.country("JP", "2023-01-02", trips: ["bare"], region: .easternAsia)]
        let pins = MapPins.build(trips: [rome, portugal, bare], countries: countries)
        func cover(_ id: String) -> AssetID? { pins.first { $0.id == id }?.cover }
        #expect(cover("trip:rome") == "rome-1")
        #expect(cover("place:rome:0") == "rome-1")
        #expect(cover("place:rome:1") == "ciampino-1")
        #expect(cover("trip:portugal") == "sintra-1")
        #expect(cover("place:portugal:0") == nil)
        #expect(cover("country:PT") == "sintra-1")
        #expect(pins.first { $0.id == "country:PT" }?.coordinate == MapFixture.Places.lisbon)
        #expect(cover("region:southernEurope") == "rome-1")
        #expect(cover("trip:bare") == nil && cover("country:JP") == nil)
    }

    @Test func countsAndYearsComeFromTheTrips() throws {
        let rome = MapHandmade.trip("rome", "2019-04-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 80)])
        let florence = MapHandmade.trip("florence", "2019-09-12", [MapHandmade.place(MapFixture.Places.florence, "Florenz", "IT", photos: 50)])
        // Started on New Year's Eve at 23:30 UTC at Ciampino: 00:30 on 1 January in Rome, so a
        // trip of 2023 (its first local day), wherever the iPhone is.
        let newYear = MapHandmade.trip("new-year", "2022-12-31 23:30", [MapHandmade.place(Place.ciampino, nil, "IT", photos: 30)],
                                       timeZone: "Europe/Rome")
        let countries = [MapHandmade.country("IT", "2019-04-02", trips: ["rome", "florence", "new-year"], region: .southernEurope),
                         MapHandmade.country("PT", "2015-03-01", trips: [], region: .southernEurope)]
        let pins = MapPins.build(trips: [newYear, florence, rome], countries: countries)
        let italy = try #require(pins.first { $0.id == "country:IT" })
        #expect(italy.count == 3)
        #expect(italy.years == [2019, 2023])
        let region = try #require(pins.first { $0.id == "region:southernEurope" })
        #expect(region.count == 2)
        #expect(region.years == [2019, 2023])
        #expect(pins.first { $0.id == "trip:new-year" }?.years == [2023])
        #expect(pins.first { $0.id == "place:new-year:0" }?.years == [2023])
        #expect(pins.first { $0.id == "trip:rome" }?.years == [2019])
        // On a clock still in 2022 (its first local day on New Year's Eve) it is a trip of 2022.
        let oldYear = MapHandmade.trip("new-year", "2022-12-31 23:30", [MapHandmade.place(Place.ciampino, nil, "IT", photos: 30)])
        let utc = MapPins.build(trips: [oldYear, florence, rome], countries: countries)
        #expect(utc.first { $0.id == "country:IT" }?.years == [2019, 2022])
        // Trip and place pins carry what the app shows on them.
        let trip = try #require(pins.first { $0.id == "trip:rome" })
        #expect(trip.title == "Rom" && trip.countryKey == "IT" && trip.tripID == AlbumistID("rome") && trip.placeIndex == 0 && trip.count == 80)
        let place = try #require(pins.first { $0.id == "place:florence:0" })
        #expect(place.title == "Florenz" && place.countryKey == "IT" && place.tripID == AlbumistID("florence") && place.placeIndex == 0 && place.count == 50)
    }

    @Test func equallyPhotographedPlacesTieByTheEarlierTripThenTheLowerIndex() {
        let later = MapHandmade.trip("later", "2021-05-02", [MapHandmade.place(MapFixture.Places.florence, "Florenz", "IT", photos: 40)])
        let earlier = MapHandmade.trip("earlier", "2019-05-02", [MapHandmade.place(Place.ciampino, nil, "IT", photos: 40),
                                                                 MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 40)])
        let italy = MapHandmade.country("IT", "2019-05-02", trips: ["earlier", "later"], region: .southernEurope)
        let pins = MapPins.build(trips: [later, earlier], countries: [italy])
        #expect(pins.first { $0.id == "country:IT" }?.coordinate == Place.ciampino)
        #expect(pins.first { $0.id == "region:southernEurope" }?.coordinate == Place.ciampino)
    }

    @Test func aCountryWhoseTripPhotosMakeNoPlaceGetsNoPin() {
        // Through Liechtenstein on the way to Tirol: 4 photos there, never 3 of one day at one spot.
        let alps = MapHandmade.trip("alps", "2022-08-01", [MapHandmade.place(Place.innsbruck, "Innsbruck", "AT", photos: 40)],
                                    otherPhotos: 4, countryPhotos: ["AT": 40, "LI": 4])
        let countries = [MapHandmade.country("AT", "2022-08-01", trips: ["alps"], region: .westernEurope),
                         MapHandmade.country("LI", "2022-08-01", trips: ["alps"], region: .westernEurope)]
        let pins = MapPins.build(trips: [alps], countries: countries)
        #expect(pins.contains { $0.id == "country:AT" })
        #expect(!pins.contains { $0.id == "country:LI" })
        #expect(pins.first { $0.id == "region:westernEurope" }?.count == 2)
    }

    @Test func sameInputInAnyOrderGivesTheSamePins() {
        let trips = [
            MapHandmade.trip("rome", "2019-05-02", [MapHandmade.place(MapFixture.Places.rome, "Rom", "IT", photos: 40),
                                                    MapHandmade.place(Place.ciampino, nil, "IT", photos: 40)]),
            MapHandmade.trip("florence", "2019-05-02", [MapHandmade.place(MapFixture.Places.florence, "Florenz", "IT", photos: 40)]),
            MapHandmade.trip("north", "2023-06-14", [MapHandmade.place(MapFixture.Places.reykjavik, "Reykjavík", "IS", photos: 50),
                                                     MapHandmade.place(Place.nuuk, "Nuuk", "GL", photos: 50)]),
            MapHandmade.trip("lisbon", "2022-10-02", [MapHandmade.place(MapFixture.Places.lisbon, "Lissabon", "PT", photos: 30)]),
        ]
        let countries = [MapHandmade.country("IT", "2019-05-02", trips: ["rome", "florence"], region: .southernEurope),
                         MapHandmade.country("IS", "2023-06-14", trips: ["north"], region: .northernEurope),
                         MapHandmade.country("GL", "2023-06-15", trips: ["north"], region: .northernAmerica, isState: false),
                         MapHandmade.country("PT", "2022-10-02", trips: ["lisbon"], region: .southernEurope),
                         MapHandmade.country("DE", "2009-01-01", trips: [], region: .westernEurope)]
        let pins = MapPins.build(trips: trips, countries: countries)
        for seed in 1...5 as ClosedRange<UInt64> {
            let again = MapPins.build(trips: MapHandmade.shuffled(trips, seed: seed), countries: MapHandmade.shuffled(countries, seed: seed + 10))
            #expect(again == pins)
        }
        // A trip given twice is pinned once; a country given twice (the summary never has one)
        // counts as its copy with the earliest first visit, whichever comes first.
        #expect(MapPins.build(trips: trips + trips, countries: countries) == pins)
        let stale = MapHandmade.country("IS", "2024-01-01", trips: [], region: .northernEurope)
        #expect(MapPins.build(trips: trips, countries: [stale] + countries) == pins)
        #expect(MapPins.build(trips: trips, countries: countries + [stale]) == pins)
    }

    @Test func aTripWithoutPlacesHasItsPinAtItsMedoidOnly() throws {
        // Two photos a day on a hike: no place, the destination is the medoid of its photos.
        let walk = MapHandmade.trip("walk", "2022-05-01", [], medoid: MapFixture.Places.porto, otherPhotos: 12, countryPhotos: ["PT": 12])
        let portugal = MapHandmade.country("PT", "2022-05-01", trips: ["walk"], region: .southernEurope)
        let pins = MapPins.build(trips: [walk], countries: [portugal])
        let pin = try #require(pins.first)
        #expect(pins.count == 1)
        #expect(pin.id == "trip:walk" && pin.coordinate == MapFixture.Places.porto && pin.placeIndex == nil && pin.count == 12 && pin.cover == nil)
        #expect(MapPins.build(trips: [], countries: []).isEmpty)
    }

    @Test func thousandsOfDayTripsStayFast() {
        // 5,000 trips with 20,000 places: one pass over the places and one sort.
        let (trips, countries) = MapHandmade.dayTrips(5_000)
        var pins: [MapPin] = []
        let took = ContinuousClock().measure { pins = MapPins.build(trips: trips, countries: countries) }
        #expect(pins.filter { $0.level == .trip }.count == 5_000)
        #expect(pins.filter { $0.level == .place }.count == 20_000)
        #expect(pins.filter { $0.level == .country }.count == 12)
        #expect(pins.filter { $0.level == .worldRegion }.count == 3)
        #expect(took < .seconds(2), "5,000 trips took \(took)")
    }

    @Test func aPlaceThatIsNoCoordinateMakesNoPin() {
        var broken = MapHandmade.trip("broken", "2022-05-01", [MapHandmade.place(MapFixture.Places.lisbon, "Lissabon", "PT", photos: 30),
                                                               MapHandmade.place(MapFixture.Places.porto, "Porto", "PT", photos: 20)])
        broken.geometry.places[1].coordinate = GeoCoordinate(latitude: .nan, longitude: -8.6)
        let pins = MapPins.build(trips: [broken], countries: [MapHandmade.country("PT", "2022-05-01", trips: ["broken"], region: .southernEurope)])
        #expect(pins.map(\.id) == ["region:southernEurope", "country:PT", "trip:broken", "place:broken:0"])
        broken.geometry.destination = GeoCoordinate(latitude: 0, longitude: 0)
        #expect(!MapPins.build(trips: [broken], countries: []).contains { $0.level == .trip })
    }
}
