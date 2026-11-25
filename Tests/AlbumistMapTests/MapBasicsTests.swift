import Foundation
import Testing
import AlbumistCore
@testable import AlbumistMap

/// Small rules every part of the map shares: the Earth comparison, rounded distances, small
/// home countries on share images.
@Suite("Map basics")
struct MapBasicsTests {
    @Test func earthComparisonFollowsTheConcept() {
        #expect(EarthComparison(meters: 0) == .none)
        #expect(EarthComparison(meters: -5) == .none)
        #expect(EarthComparison(meters: .nan) == .none)
        #expect(EarthComparison(meters: 9_000_000) == .none)
        #expect(EarthComparison(meters: 10_100_000) == .quarter)
        #expect(EarthComparison(meters: 20_100_000) == .half)
        #expect(EarthComparison(meters: 40_075_000) == .aroundTheEarth(times: 1.0))
        // The drafts' 88,800 km: "2,2-mal um die Erde" (2.216, rounded down).
        #expect(EarthComparison(meters: 88_800_000) == .aroundTheEarth(times: 2.2))
        // Just below 3 times stays 2.9, never shows more than was travelled.
        #expect(EarthComparison(meters: 120_200_000) == .aroundTheEarth(times: 2.9))
        #expect(EarthComparison(meters: 384_400_000) == .toTheMoon(times: 1.0))
        #expect(EarthComparison(meters: 500_000_000) == .toTheMoon(times: 1.3))
    }

    @Test func distancesAreRoundedToHundredKilometres() {
        #expect(MapDistance.aboutKilometers(99_999) == nil)
        #expect(MapDistance.aboutKilometers(100_000) == 100)
        #expect(MapDistance.aboutKilometers(149_999) == 100)
        #expect(MapDistance.aboutKilometers(150_000) == 200)
        #expect(MapDistance.aboutKilometers(2_640_000) == 2_600)
        #expect(MapDistance.roundedKilometers(49_999) == 0)
        #expect(MapDistance.roundedKilometers(50_000) == 100)
        #expect(MapDistance.roundedKilometers(88_812_345) == 88_800)
        #expect(MapDistance.roundedKilometers(.infinity) == 0)
    }

    @Test func smallOrUnknownHomeCountriesGetNoShareArcs() {
        let geometry = CountryGeometry(squareKilometers: ["DE": 357_000, "LU": 2_586, "BE": 30_689],
                                       centers: ["DE": GeoCoordinate(latitude: 51.0, longitude: 10.4), "LU": GeoCoordinate(latitude: 49.8, longitude: 6.1),
                                                 "BE": GeoCoordinate(latitude: 50.6, longitude: 4.6)])
        #expect(geometry.shareOrigin(countryCode: "DE") == GeoCoordinate(latitude: 51.0, longitude: 10.4))
        #expect(geometry.shareOrigin(countryCode: "de") == GeoCoordinate(latitude: 51.0, longitude: 10.4))
        #expect(geometry.shareOrigin(countryCode: "LU") == nil)
        #expect(geometry.shareOrigin(countryCode: "XX") == nil)
        #expect(geometry.shareOrigin(countryCode: nil) == nil)
        #expect(!geometry.isSmall("BE"))
        #expect(geometry.isSmall("LU"))
        #expect(geometry.isSmall("XX"))
    }
}
