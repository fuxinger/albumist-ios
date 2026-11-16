import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Re-review of "Dein Zuhause" (16.11.): the home places taken from the photos around each
/// chosen home stay linear. Measured in a release build on about 50,000 photos with three homes:
/// 0.03 s (3.0 s before), the search index 0.8 s (4.8 s before). The test counts instead of
/// timing, on a smaller library: a timed test on CI slows the other timed tests running beside it.
@Suite("Re-review: Dein Zuhause timing")
struct ReReviewHomeTimingTests {
    static let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
    static let cologne = GeoCoordinate(latitude: 50.9375, longitude: 6.9603)
    static let vienna = GeoCoordinate(latitude: 48.2082, longitude: 16.3738)

    static func library() -> [AssetFacts] {
        let table: [(GeoCoordinate, PlaceComponents)] = [
            (Fixture.Places.munichHome, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", subAdministrativeArea: "Oberbayern", locality: "München")),
            (hamburg, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Hamburg", locality: "Hamburg")),
            (cologne, PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Nordrhein-Westfalen", subAdministrativeArea: "Köln", locality: "Köln")),
            (vienna, PlaceComponents(isoCountryCode: "AT", country: "Österreich", administrativeArea: "Wien", locality: "Wien")),
            (Fixture.Places.rome, PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", subAdministrativeArea: "Rom", locality: "Rom")),
            (Fixture.Places.gardaLake, PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Venetien", subAdministrativeArea: "Verona", locality: "Malcesine")),
        ]
        var lib = LibraryBuilder()
        lib.daily(from: "2010-01-01", to: "2014-12-31", at: cologne, perDay: 1, hour: 19)
        lib.daily(from: "2015-01-01", to: "2018-12-31", at: hamburg, perDay: 1, hour: 19)
        lib.daily(from: "2019-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 1, hour: 19)
        for year in 2010...2026 {
            lib.daily(from: "\(year)-05-10", to: "\(year)-05-17", at: Fixture.Places.rome, perDay: 8, hour: 10)
            lib.daily(from: "\(year)-08-01", to: "\(year)-08-10", at: Fixture.Places.gardaLake, perDay: 6, hour: 10)
            lib.daily(from: "\(year)-10-01", to: "\(year)-10-04", at: vienna, perDay: 6, hour: 10)
        }
        return lib.assets.map { a in
            let c = a.usableLocation!
            let nearest = table.min { GeoMath.distance(c, $0.0) < GeoMath.distance(c, $1.0) }!
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
    }

    /// Three chosen homes: the places' keys are worked out once per distinct place of the
    /// library (six here), not once per photo and home; per home only the distance is measured.
    @Test func homePlacesAreWorkedOutOncePerPlace() throws {
        let facts = Self.library()
        #expect(facts.count > 7_000)
        let now = Fixture.date("2026-11-16")
        let chosen = HomeSettings()
            .choosing(HomePlace(center: Fixture.Places.munichHome, components: nil), from: nil, date: now)
            .addingFormer(FormerHome(place: HomePlace(center: Self.hamburg, components: nil), until: Fixture.date("2019-01-01")), date: now)
            .addingFormer(FormerHome(place: HomePlace(center: Self.cologne, components: nil), until: Fixture.date("2015-01-01")), date: now)
        let profile = LibraryProfile(facts: facts, trips: [])
        let context = HomeContext(settings: chosen, profile: profile, facts: facts)
        #expect(context.placeKeyLookups == Set(facts.compactMap(\.gpsPlace)).count)
        #expect(context.placeKeyLookups == 6)
        #expect(HomeContext(settings: HomeSettings(), profile: profile, facts: facts).placeKeyLookups == 0)
        let munich = try #require(chosen.confirmed)
        #expect(context.isHome(PlaceKey(level: .locality, path: "de/bayern/oberbayern/munchen"), at: now))
        #expect(context.chosenKeys[munich.id]?.contains(PlaceKey(level: .country, path: "de")) == true)
        #expect(context.chosenKeys[munich.id]?.contains(PlaceKey(level: .country, path: "it")) == false)
        // The same answer as working out every photo's keys for every home.
        let slow = Set(facts.filter { $0.asset.usableLocation.map { GeoMath.distance($0, munich.center) <= 30_000 } ?? false }
            .compactMap(\.gpsPlace).flatMap { place in PlaceKeyTable.levels.compactMap { place.key(at: $0) } })
        #expect(context.chosenKeys[munich.id] == slow)
    }
}

/// Re-review: "Ändern" right after a move. The detection still shows the old town for up to
/// 120 days; the user picks the new one under "Ändern". It holds from the start of the stay
/// there ("Seit wann wohnst du dort?", proposed by `HomeCandidates.stayStart`), so the years in
/// the old town stay as they were.
@Suite("Re-review: Ändern after a move")
struct ReReviewChangeAfterAMoveTests {
    static let berlin = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)

    @Test func pickingTheNewTownUnderAendernKeepsThePastAsItWas() throws {
        var lib = LibraryBuilder()
        let munich = lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        lib.daily(from: "2026-09-01", to: "2026-11-15", at: Self.berlin, perDay: 2, hour: 19)
        let detector = TripDetector(calendar: Fixture.calendar)
        let automatic = detector.analyse(in: lib.assets)
        let detected = try #require(automatic.detectedHome)
        // The premise: the detection still shows Munich.
        #expect(GeoMath.distance(detected.center, Fixture.Places.munichHome) < 30_000)
        let now = Fixture.date("2026-11-16")
        let since = try #require(HomeCandidates.stayStart(near: Self.berlin, assets: lib.assets, calendar: Fixture.calendar))
        #expect(since == Fixture.date("2026-09-01"))
        let picked = detector.analyse(in: lib.assets, home: HomeSettings().choosing(HomePlace(center: Self.berlin, components: nil), from: since, date: now))
        let munichOnTrips = Set(picked.trips.flatMap(\.geotaggedAssetIDs)).intersection(munich).count
        #expect(munichOnTrips == 0)
    }

    /// Munich was confirmed earlier ("Stimmt" in 2025); after the move the user picks Berlin
    /// under "Ändern" with the proposed date. The confirmed years in Munich stay everyday life:
    /// before the date the detection decides, as for every confirmation.
    @Test func confirmedEarlierThenPickedTheNewTownKeepsTheConfirmedYears() throws {
        var lib = LibraryBuilder()
        let munich = lib.daily(from: "2019-01-01", to: "2026-08-31", at: Fixture.Places.munichHome, perDay: 2, hour: 19)
        lib.daily(from: "2026-09-01", to: "2026-11-15", at: Self.berlin, perDay: 2, hour: 19)
        let detector = TripDetector(calendar: Fixture.calendar)
        let confirmed = HomeSettings().confirming(HomePlace(center: Fixture.Places.munichHome, components: nil), date: Fixture.date("2025-03-01"))
        let since = try #require(HomeCandidates.stayStart(near: Self.berlin, assets: lib.assets, calendar: Fixture.calendar))
        let picked = confirmed.choosing(HomePlace(center: Self.berlin, components: nil), from: since, date: Fixture.date("2026-11-16"))
        #expect(picked.home(at: Fixture.date("2025-06-01")) == .detected)
        #expect(picked.home(at: Fixture.date("2026-10-01")) == .chosen(HomePlace(center: Self.berlin, components: nil)))
        let analysis = detector.analyse(in: lib.assets, home: picked)
        #expect(Set(analysis.trips.flatMap(\.geotaggedAssetIDs)).isDisjoint(with: munich))
        #expect(analysis.trips.isEmpty)
    }

    /// "Seit wann wohnst du dort?" is proposed from the photos: the first day of the latest stay
    /// near the place. Trips do not end a stay; a stretch of four weeks elsewhere does.
    @Test func theStayStartsAfterTheLastLongStretchElsewhere() throws {
        var lib = LibraryBuilder()
        let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
        lib.daily(from: "2015-01-01", to: "2018-12-31", at: hamburg, perDay: 1, hour: 19)
        lib.daily(from: "2019-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 1, hour: 19,
                  skipping: [("2024-05-10", "2024-05-24"), ("2025-08-01", "2025-08-20")])
        lib.daily(from: "2024-05-10", to: "2024-05-24", at: Fixture.Places.rome, perDay: 5, hour: 10)
        lib.daily(from: "2025-08-01", to: "2025-08-20", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        #expect(HomeCandidates.stayStart(near: Fixture.Places.munichHome, assets: lib.assets, calendar: Fixture.calendar) == Fixture.date("2019-01-01"))
        #expect(HomeCandidates.stayStart(near: hamburg, assets: lib.assets, calendar: Fixture.calendar) == Fixture.date("2015-01-01"))
        #expect(HomeCandidates.stayStart(near: Fixture.Places.sydney, assets: lib.assets, calendar: Fixture.calendar) == nil)
    }
}
