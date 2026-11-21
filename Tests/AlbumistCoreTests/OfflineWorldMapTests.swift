import Foundation
import Testing
@testable import AlbumistCore
import AlbumistWorldMap

@Suite("Offline world map")
struct OfflineWorldMapTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    func at(_ lat: Double, _ lon: Double) -> OfflineWorldMap.Match { Self.map.lookup(GeoCoordinate(latitude: lat, longitude: lon)) }

    @Test func loadsAllCountries() {
        #expect(Self.map.countryCount > 240)
        #expect(Self.map.country(code: "DE")?.nameDE == "Deutschland")
        #expect(Self.map.country(code: "IT")?.nameEN == "Italy")
    }

    @Test func outlinesAreDrawableAndSimplified() throws {
        let italy = try #require(Self.map.country(code: "IT"))
        let full = Self.map.outline(of: italy)
        let coarse = Self.map.outline(of: italy, minimumStepDegrees: 0.5)
        #expect(!full.isEmpty)
        #expect(!coarse.isEmpty)
        let fullPoints = full.reduce(0) { $0 + $1.count }, coarsePoints = coarse.reduce(0) { $0 + $1.count }
        #expect(coarsePoints < fullPoints / 5)
        // All points lie in Italy's rough bounding box.
        for ring in full { for p in ring { #expect((35.0...48.0).contains(p.latitude) && (6.0...19.0).contains(p.longitude)) } }
    }

    @Test(arguments: [
        (48.1371, 11.5754, "DE", "Bayern"),      // Munich
        (41.8986, 12.4769, "IT", "Latium"),      // Rome
        (52.5200, 13.4050, "DE", "Berlin"),
        (40.4168, -3.7038, "ES", "Madrid"),
        (43.7696, 11.2558, "IT", "Toskana"),     // Florence
        (48.8566, 2.3522, "FR", "Île-de-France"),
        (51.5074, -0.1278, "GB", "England"),
        (-33.8688, 151.2093, "AU", "New South Wales"),
        (35.6762, 139.6503, "JP", "Tokio"),
        (40.7128, -74.0060, "US", "New York"),
    ])
    func interiorPointsAreCertain(lat: Double, lon: Double, code: String, regionDE: String) {
        let m = at(lat, lon)
        #expect(m.country?.isoCode == code)
        #expect(m.countryIsCertain)
        #expect(m.region?.nameDE == regionDE)
    }

    @Test(arguments: [
        (47.5903, 7.5893),   // Basel Dreiländereck: CH / DE / FR within metres
        (47.6603, 9.1758),   // Konstanz / Kreuzlingen
        (47.7958, 13.0450),  // Salzburg near the German border? (~6 km) – not ambiguous
    ])
    func bordersNeedOnlineConfirmation(lat: Double, lon: Double) {
        let m = at(lat, lon)
        if lat == 47.7958 {
            #expect(m.country?.isoCode == "AT")
        } else {
            #expect(!m.countryIsCertain)
            #expect(m.countryCandidates.count >= 2)
        }
    }

    @Test func beachJustOffTheSimplifiedCoastStillCounts() {
        // Rimini beach, a few hundred metres out into the Adriatic.
        let m = at(44.0700, 12.5900)
        #expect(m.country?.isoCode == "IT")
        #expect(m.countryIsCertain)
    }

    @Test func openSeaIsUnknown() {
        let m = at(38.0, -40.0) // mid Atlantic
        #expect(m.country == nil)
        #expect(m.components(language: .german) == nil)
    }

    @Test func tinyStatesAreKept() {
        #expect(at(41.9029, 12.4534).country?.isoCode == "VA") // St. Peter's Square
        #expect(at(43.7384, 7.4246).country?.isoCode == "MC")
    }

    @Test func componentsUseTitleLanguage() {
        let de = at(48.1371, 11.5754).components(language: .german)
        let en = at(48.1371, 11.5754).components(language: .english)
        #expect(de?.country == "Deutschland")
        #expect(en?.country == "Germany")
        #expect(de?.isoCountryCode == "DE")
        #expect(de?.key(at: .country) == en?.key(at: .country))
    }

    @Test func regionWithinGivenCountry() {
        // Online geocoder decided "CH" for a Basel point: the region comes from the same map.
        let r = Self.map.region(GeoCoordinate(latitude: 47.5560, longitude: 7.5900), inCountryCode: "CH")
        #expect(r?.region.nameEN.contains("Basel") == true)
    }

    /// 500 lookups stay cheap. Counted, not timed (review of bundle-i, 19.11.2026): the old
    /// limit of 2 s wall clock failed at 2.09 s in a full parallel run (0.6 s alone). Measured
    /// on the map of 19.11.: 2,991 regions looked at, 1,234 rings and 1,008,420 points decoded.
    /// The limits leave about 30 %; reading every ring of a region near the point (no ring
    /// boxes) or every region (no region boxes) decodes many times more.
    @Test func lookupIsFast() {
        var work = OfflineWorldMap.LookupWork()
        for i in 0..<500 {
            _ = Self.map.lookup(GeoCoordinate(latitude: 35 + Double(i % 25), longitude: -5 + Double(i % 30)), work: &work)
        }
        #expect(work.regions <= 4_000, "\(work)")
        #expect(work.rings <= 1_600, "\(work)")
        #expect(work.points <= 1_300_000, "\(work)")
        #expect(work.points >= 500_000, "the count must see the decoding: \(work)")
    }

    @Test func rejectsGarbage() {
        #expect(throws: OfflineWorldMap.FormatError.badMagic) { try OfflineWorldMap(data: Data("nope-nope".utf8)) }
        #expect(throws: OfflineWorldMap.FormatError.truncated) { try OfflineWorldMap(data: Data("SWM1".utf8) + Data([1, 0, 0, 0, 1])) }
    }
}
