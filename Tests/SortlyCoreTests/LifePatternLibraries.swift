import Foundation
@testable import SortlyCore
import SortlyTestSupport

/// Photo libraries for the life patterns of "Was zählt alles als Reise?": everyday life in
/// Munich (two photos every evening) plus one way of being away. Built with `LibraryBuilder`,
/// all in UTC like the other trip tests (the time zone cases are in `TripTimeZoneTests`).
enum LifePatterns {
    enum Places {
        static let munich = Fixture.Places.munichHome
        static let augsburg = GeoCoordinate(latitude: 48.3705, longitude: 10.8978)        // 57 km
        static let garmisch = GeoCoordinate(latitude: 47.4921, longitude: 11.0958)        // 80 km
        static let garda = Fixture.Places.gardaLake
        static let hamburg = GeoCoordinate(latitude: 53.5511, longitude: 9.9937)
        static let frankfurt = GeoCoordinate(latitude: 50.1109, longitude: 8.6821)
        static let berlin = GeoCoordinate(latitude: 52.5200, longitude: 13.4050)
        static let paris = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
        static let london = GeoCoordinate(latitude: 51.5074, longitude: -0.1278)
        static let vienna = GeoCoordinate(latitude: 48.2082, longitude: 16.3738)
        static let zurich = GeoCoordinate(latitude: 47.3769, longitude: 8.5417)
        static let milan = GeoCoordinate(latitude: 45.4642, longitude: 9.1900)
        static let shanghai = GeoCoordinate(latitude: 31.2304, longitude: 121.4737)
        static let lisbon = GeoCoordinate(latitude: 38.7223, longitude: -9.1393)
        static let porto = GeoCoordinate(latitude: 41.1579, longitude: -8.6291)
        static let barcelona = GeoCoordinate(latitude: 41.3874, longitude: 2.1686)
        static let valencia = GeoCoordinate(latitude: 39.4699, longitude: -0.3763)
        static let tbilisi = GeoCoordinate(latitude: 41.7151, longitude: 44.8271)
        static let istanbul = GeoCoordinate(latitude: 41.0082, longitude: 28.9784)
        static let athens = GeoCoordinate(latitude: 37.9838, longitude: 23.7275)
        static let split = GeoCoordinate(latitude: 43.5081, longitude: 16.4402)
        static let budapest = GeoCoordinate(latitude: 47.4979, longitude: 19.0402)
        static let prague = GeoCoordinate(latitude: 50.0755, longitude: 14.4378)
        static let copenhagen = GeoCoordinate(latitude: 55.6761, longitude: 12.5683)
        static let edinburgh = GeoCoordinate(latitude: 55.9533, longitude: -3.1883)
        static let marrakesh = GeoCoordinate(latitude: 31.6295, longitude: -7.9811)
        static let bangkok = GeoCoordinate(latitude: 13.7563, longitude: 100.5018)
        static let chiangMai = GeoCoordinate(latitude: 18.7883, longitude: 98.9853)
        static let luangPrabang = GeoCoordinate(latitude: 19.8856, longitude: 102.1347)
        static let hanoi = GeoCoordinate(latitude: 21.0278, longitude: 105.8342)
        static let hoiAn = GeoCoordinate(latitude: 15.8801, longitude: 108.3380)
        static let saigon = GeoCoordinate(latitude: 10.8231, longitude: 106.6297)
        static let siemReap = GeoCoordinate(latitude: 13.3671, longitude: 103.8448)
        static let kualaLumpur = GeoCoordinate(latitude: 3.1390, longitude: 101.6869)
        static let singapore = GeoCoordinate(latitude: 1.3521, longitude: 103.8198)
        static let ubud = GeoCoordinate(latitude: -8.5069, longitude: 115.2625)
        static let yogyakarta = GeoCoordinate(latitude: -7.7956, longitude: 110.3695)
        static let sydney = Fixture.Places.sydney
        static let rome = Fixture.Places.rome
        static let salzburg = GeoCoordinate(latitude: 47.8095, longitude: 13.0550)
        static let innsbruck = GeoCoordinate(latitude: 47.2692, longitude: 11.4041)
        static let tegernsee = Fixture.Places.tegernsee
        static let cagliari = GeoCoordinate(latitude: 39.2238, longitude: 9.1217)
        static let alghero = GeoCoordinate(latitude: 40.5580, longitude: 8.3190)
        static let soelden = GeoCoordinate(latitude: 46.9655, longitude: 11.0076)
        static let newYork = GeoCoordinate(latitude: 40.7128, longitude: -74.0060)
        static let tokyo = GeoCoordinate(latitude: 35.6762, longitude: 139.6503)
    }

    /// Reverse geocoding for the places above (nearest within 40 km).
    static let table: [(GeoCoordinate, PlaceComponents)] = {
        func p(_ c: GeoCoordinate, _ code: String, _ country: String, _ city: String, _ zone: String, region: String? = nil) -> (GeoCoordinate, PlaceComponents) {
            (c, PlaceComponents(isoCountryCode: code, country: country, administrativeArea: region, locality: city, timeZoneIdentifier: zone))
        }
        return [
            p(Places.munich, "DE", "Deutschland", "München", "Europe/Berlin", region: "Bayern"),
            p(Places.augsburg, "DE", "Deutschland", "Augsburg", "Europe/Berlin", region: "Bayern"),
            p(Places.garmisch, "DE", "Deutschland", "Garmisch-Partenkirchen", "Europe/Berlin", region: "Bayern"),
            p(Places.garda, "IT", "Italien", "Malcesine", "Europe/Rome", region: "Venetien"),
            p(Places.hamburg, "DE", "Deutschland", "Hamburg", "Europe/Berlin", region: "Hamburg"),
            p(Places.frankfurt, "DE", "Deutschland", "Frankfurt am Main", "Europe/Berlin", region: "Hessen"),
            p(Places.berlin, "DE", "Deutschland", "Berlin", "Europe/Berlin", region: "Berlin"),
            p(Places.paris, "FR", "Frankreich", "Paris", "Europe/Paris"),
            p(Places.london, "GB", "Vereinigtes Königreich", "London", "Europe/London"),
            p(Places.vienna, "AT", "Österreich", "Wien", "Europe/Vienna"),
            p(Places.zurich, "CH", "Schweiz", "Zürich", "Europe/Zurich"),
            p(Places.milan, "IT", "Italien", "Mailand", "Europe/Rome"),
            p(Places.shanghai, "CN", "China", "Shanghai", "Asia/Shanghai"),
            p(Places.lisbon, "PT", "Portugal", "Lissabon", "Europe/Lisbon"),
            p(Places.porto, "PT", "Portugal", "Porto", "Europe/Lisbon"),
            p(Places.barcelona, "ES", "Spanien", "Barcelona", "Europe/Madrid"),
            p(Places.valencia, "ES", "Spanien", "Valencia", "Europe/Madrid"),
            p(Places.tbilisi, "GE", "Georgien", "Tiflis", "Asia/Tbilisi"),
            p(Places.istanbul, "TR", "Türkei", "Istanbul", "Europe/Istanbul"),
            p(Places.athens, "GR", "Griechenland", "Athen", "Europe/Athens"),
            p(Places.split, "HR", "Kroatien", "Split", "Europe/Zagreb"),
            p(Places.budapest, "HU", "Ungarn", "Budapest", "Europe/Budapest"),
            p(Places.prague, "CZ", "Tschechien", "Prag", "Europe/Prague"),
            p(Places.copenhagen, "DK", "Dänemark", "Kopenhagen", "Europe/Copenhagen"),
            p(Places.edinburgh, "GB", "Vereinigtes Königreich", "Edinburgh", "Europe/London"),
            p(Places.marrakesh, "MA", "Marokko", "Marrakesch", "Africa/Casablanca"),
            p(Places.bangkok, "TH", "Thailand", "Bangkok", "Asia/Bangkok"),
            p(Places.chiangMai, "TH", "Thailand", "Chiang Mai", "Asia/Bangkok"),
            p(Places.luangPrabang, "LA", "Laos", "Luang Prabang", "Asia/Vientiane"),
            p(Places.hanoi, "VN", "Vietnam", "Hanoi", "Asia/Ho_Chi_Minh"),
            p(Places.hoiAn, "VN", "Vietnam", "Hoi An", "Asia/Ho_Chi_Minh"),
            p(Places.saigon, "VN", "Vietnam", "Ho-Chi-Minh-Stadt", "Asia/Ho_Chi_Minh"),
            p(Places.siemReap, "KH", "Kambodscha", "Siem Reap", "Asia/Phnom_Penh"),
            p(Places.kualaLumpur, "MY", "Malaysia", "Kuala Lumpur", "Asia/Kuala_Lumpur"),
            p(Places.singapore, "SG", "Singapur", "Singapur", "Asia/Singapore"),
            p(Places.ubud, "ID", "Indonesien", "Ubud", "Asia/Makassar"),
            p(Places.yogyakarta, "ID", "Indonesien", "Yogyakarta", "Asia/Jakarta"),
            p(Places.sydney, "AU", "Australien", "Sydney", "Australia/Sydney"),
            p(Places.rome, "IT", "Italien", "Rom", "Europe/Rome"),
            p(Places.salzburg, "AT", "Österreich", "Salzburg", "Europe/Vienna", region: "Salzburg"),
            p(Places.innsbruck, "AT", "Österreich", "Innsbruck", "Europe/Vienna", region: "Tirol"),
            p(Places.tegernsee, "DE", "Deutschland", "Tegernsee", "Europe/Berlin", region: "Bayern"),
            p(Places.cagliari, "IT", "Italien", "Cagliari", "Europe/Rome", region: "Sardinien"),
            p(Places.alghero, "IT", "Italien", "Alghero", "Europe/Rome", region: "Sardinien"),
            p(Places.soelden, "AT", "Österreich", "Sölden", "Europe/Vienna", region: "Tirol"),
            p(Places.newYork, "US", "Vereinigte Staaten", "New York", "America/New_York"),
            p(Places.tokyo, "JP", "Japan", "Tokio", "Asia/Tokyo"),
        ]
    }()

    static func facts(for assets: [AssetSnapshot]) -> [AssetFacts] {
        assets.map { a in
            guard let loc = a.usableLocation,
                  let nearest = table.min(by: { GeoMath.distance(loc, $0.0) < GeoMath.distance(loc, $1.0) }),
                  GeoMath.distance(loc, nearest.0) < 40_000 else { return AssetFacts(asset: a) }
            return AssetFacts(asset: a, place: nearest.1, placeSource: .gpsReverseGeocoded)
        }
    }

    // MARK: Dates

    static func day(_ string: String, plus days: Int = 0) -> Date {
        Fixture.calendar.date(byAdding: .day, value: days, to: Fixture.date(string))!
    }

    static func ymd(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Fixture.utc
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func weekday(_ date: Date) -> Int { Fixture.calendar.component(.weekday, from: date) } // 1 = Sunday

    /// A stay: `days` days from `start` at `place`, `perDay` photos from `hour` on.
    struct Stay {
        var start: String
        var days: Int
        var place: GeoCoordinate
        var perDay: Int
        var hour: Int = 10
        var last: String { LifePatterns.ymd(LifePatterns.day(start, plus: days - 1)) }
    }

    /// Everyday life in Munich (two photos every evening) from `from` to `to`, except on the
    /// days of `stays`, plus the stays. Returns the photos of each stay.
    static func life(from: String = "2024-01-01", to: String = "2025-12-31", stays: [Stay], into lib: inout LibraryBuilder) -> [[AssetID]] {
        lib.daily(from: from, to: to, at: Places.munich, perDay: 2, hour: 19, skipping: stays.map { ($0.start, $0.last) })
        return stays.map { lib.daily(from: $0.start, to: $0.last, at: $0.place, perDay: $0.perDay, hour: $0.hour) }
    }

    /// Stays every `cycle` days (cycling through the list) from `first` until `until`.
    static func every(_ cycle: [Int], from first: String, until: String, days: Int, place: GeoCoordinate, perDay: Int, hour: Int = 10) -> [Stay] {
        var result: [Stay] = []
        var start = day(first)
        var index = 0
        while start <= day(until) {
            result.append(Stay(start: ymd(start), days: days, place: place, perDay: perDay, hour: hour))
            start = Fixture.calendar.date(byAdding: .day, value: cycle[index % cycle.count], to: start)!
            index += 1
        }
        return result
    }

    // MARK: The patterns

    struct Library {
        var assets: [AssetSnapshot]
        /// The photos of every stay away, oldest first.
        var stays: [[AssetID]]
    }

    /// Commutes to Augsburg (57 km) on workdays and photographs there rarely: one photo at noon
    /// on every third workday. With `photographsAtWork`, two photos every workday.
    static func commuter(photographsAtWork: Bool = false) -> Library {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2025-12-31", at: Places.munich, perDay: 2, hour: 19)
        var work: [[AssetID]] = []
        var date = day("2024-01-01")
        var workday = 0
        while date <= day("2025-12-31") {
            if (2...6).contains(weekday(date)) {
                if photographsAtWork || workday % 3 == 0 {
                    let count = photographsAtWork ? 2 : 1
                    work.append((0..<count).map { lib.photo(at: date.addingTimeInterval(12 * 3_600 + Double($0) * 1_800), Places.augsburg) })
                }
                workday += 1
            }
            date = day(ymd(date), plus: 1)
        }
        return Library(assets: lib.assets, stays: work)
    }

    /// A weekend place in Garmisch-Partenkirchen, every second weekend (Saturday and Sunday,
    /// six photos a day).
    static func weekendHome() -> Library {
        var lib = LibraryBuilder()
        let stays = every([14], from: "2024-01-06", until: "2025-12-27", days: 2, place: Places.garmisch, perDay: 6)
        return Library(assets: [], stays: life(stays: stays, into: &lib)).with(lib)
    }

    /// A holiday flat at Lake Garda, four days (Thursday to Sunday) once a month.
    static func holidayFlat() -> Library {
        var lib = LibraryBuilder()
        var stays: [Stay] = []
        for month in 0..<24 {
            // The first Thursday of each month.
            var start = Fixture.calendar.date(byAdding: .month, value: month, to: day("2024-01-01"))!
            while weekday(start) != 5 { start = day(ymd(start), plus: 1) }
            stays.append(Stay(start: ymd(start), days: 4, place: Places.garda, perDay: 5))
        }
        return Library(assets: [], stays: life(stays: stays, into: &lib)).with(lib)
    }

    /// Family in Hamburg, visited every three to six weeks for a long weekend.
    static func family() -> Library {
        var lib = LibraryBuilder()
        let stays = every([21, 35, 28, 42, 28], from: "2024-01-12", until: "2025-12-20", days: 3, place: Places.hamburg, perDay: 8)
        return Library(assets: [], stays: life(stays: stays, into: &lib)).with(lib)
    }

    /// Lived in Hamburg until June 2024, then moved to Munich; visits Hamburg every two months.
    static func movingHouse() -> Library {
        var lib = LibraryBuilder()
        lib.daily(from: "2023-01-01", to: "2024-06-30", at: Places.hamburg, perDay: 2, hour: 19)
        let visits = every([61], from: "2024-08-16", until: "2025-12-31", days: 3, place: Places.hamburg, perDay: 8)
        return Library(assets: [], stays: life(from: "2024-07-01", stays: visits, into: &lib)).with(lib)
    }

    /// Four months in Lisbon (September to December 2024) with two weekends in Porto.
    /// `christmasAtHome`: home from 20 December to 6 January, back in Lisbon until the end of January.
    static func semester(christmasAtHome: Bool = false) -> Library {
        var lib = LibraryBuilder()
        let porto = [Stay(start: "2024-10-12", days: 2, place: Places.porto, perDay: 6, hour: 17),
                     Stay(start: "2024-11-16", days: 2, place: Places.porto, perDay: 6, hour: 17)]
        var lisbon: [Stay]
        if christmasAtHome {
            lisbon = [Stay(start: "2024-09-01", days: 41, place: Places.lisbon, perDay: 3, hour: 17),
                      Stay(start: "2024-10-14", days: 33, place: Places.lisbon, perDay: 3, hour: 17),
                      Stay(start: "2024-11-18", days: 32, place: Places.lisbon, perDay: 3, hour: 17),
                      Stay(start: "2025-01-07", days: 25, place: Places.lisbon, perDay: 3, hour: 17)]
        } else {
            lisbon = [Stay(start: "2024-09-01", days: 41, place: Places.lisbon, perDay: 3, hour: 17),
                      Stay(start: "2024-10-14", days: 33, place: Places.lisbon, perDay: 3, hour: 17),
                      Stay(start: "2024-11-18", days: 44, place: Places.lisbon, perDay: 3, hour: 17)]
        }
        let stays = (lisbon + porto).sorted { $0.start < $1.start }
        return Library(assets: [], stays: life(stays: stays, into: &lib)).with(lib)
    }

    /// Six months away (October 2024 to March 2025): four months through South-East Asia
    /// (one to three weeks per place), then two months of Work & Travel in Sydney.
    static func longJourney() -> Library {
        var lib = LibraryBuilder()
        let route: [(GeoCoordinate, Int)] = [
            (Places.bangkok, 10), (Places.chiangMai, 12), (Places.luangPrabang, 9), (Places.hanoi, 10), (Places.hoiAn, 12),
            (Places.saigon, 9), (Places.siemReap, 10), (Places.kualaLumpur, 10), (Places.singapore, 9), (Places.yogyakarta, 12),
            (Places.ubud, 18), (Places.sydney, 61),
        ]
        var stays: [Stay] = []
        var start = day("2024-10-01")
        for (place, days) in route {
            stays.append(Stay(start: ymd(start), days: days, place: place, perDay: 4, hour: 17))
            start = day(ymd(start), plus: days)
        }
        return Library(assets: [], stays: life(stays: stays, into: &lib)).with(lib)
    }

    /// Business trips with many photos: one or two days in seven cities and a three-week fair
    /// in Shanghai in 2024, then Frankfurt every two months in 2025.
    static func businessTrips() -> Library {
        var lib = LibraryBuilder()
        var stays = [
            Stay(start: "2024-02-06", days: 2, place: Places.hamburg, perDay: 25, hour: 8),
            Stay(start: "2024-03-12", days: 2, place: Places.berlin, perDay: 25, hour: 8),
            Stay(start: "2024-04-16", days: 2, place: Places.paris, perDay: 25, hour: 8),
            Stay(start: "2024-05-14", days: 1, place: Places.london, perDay: 25, hour: 8),
            Stay(start: "2024-06-11", days: 2, place: Places.vienna, perDay: 25, hour: 8),
            Stay(start: "2024-09-17", days: 2, place: Places.zurich, perDay: 25, hour: 8),
            Stay(start: "2024-10-15", days: 2, place: Places.milan, perDay: 25, hour: 8),
            Stay(start: "2024-11-04", days: 22, place: Places.shanghai, perDay: 30, hour: 8),
        ]
        stays += every([56, 63], from: "2025-01-14", until: "2025-12-31", days: 2, place: Places.frankfurt, perDay: 25, hour: 8)
        return Library(assets: [], stays: life(stays: stays, into: &lib)).with(lib)
    }

    static let nomadCities: [(GeoCoordinate, String)] = [
        (Places.lisbon, "Lissabon"), (Places.marrakesh, "Marrakesch"), (Places.valencia, "Valencia"), (Places.barcelona, "Barcelona"),
        (Places.split, "Split"), (Places.athens, "Athen"), (Places.istanbul, "Istanbul"), (Places.tbilisi, "Tiflis"),
        (Places.budapest, "Budapest"), (Places.prague, "Prag"), (Places.copenhagen, "Kopenhagen"), (Places.edinburgh, "Edinburgh"),
    ]

    /// Lived in Munich in 2024, then a digital nomad in 2025: a new city every month, never back.
    static func digitalNomad() -> Library {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2024-12-31", at: Places.munich, perDay: 2, hour: 19)
        var stays: [[AssetID]] = []
        for (month, city) in nomadCities.enumerated() {
            let start = Fixture.calendar.date(byAdding: .month, value: month, to: day("2025-01-01"))!
            let end = Fixture.calendar.date(byAdding: .day, value: -1, to: Fixture.calendar.date(byAdding: .month, value: 1, to: start)!)!
            stays.append(lib.daily(from: ymd(start), to: ymd(end), at: city.0, perDay: 3, hour: 17))
        }
        return Library(assets: lib.assets, stays: stays)
    }

    static let sparseTrips: [(GeoCoordinate, Int, Int, Int, Int, Int)] = [   // place, year, month, day, days, photos
        (Places.paris, 2018, 10, 5, 3, 12),
        (Places.barcelona, 2019, 6, 20, 5, 14),
        (Places.newYork, 2019, 11, 2, 6, 16),
        (Places.rome, 2020, 5, 20, 4, 12),
        (Places.vienna, 2021, 2, 21, 2, 10),
        (Places.split, 2021, 8, 1, 22, 44),       // three weeks on the Croatian coast
        (Places.rome, 2022, 4, 14, 4, 12),
        (Places.lisbon, 2022, 9, 3, 3, 11),
        (Places.copenhagen, 2023, 5, 18, 3, 10),
        (Places.rome, 2023, 9, 20, 5, 15),
        (Places.tokyo, 2024, 10, 8, 6, 16),
    ]

    /// Mostly photographs while travelling: a few photos at home per year, eleven trips,
    /// one of them three weeks long, Rome three times in four years.
    static func mostlyWhileTravelling() -> Library {
        var lib = LibraryBuilder()
        let cal = Fixture.calendar
        func date(_ y: Int, _ m: Int, _ d: Int, plusDays: Int = 0, hour: Int) -> Date {
            cal.date(byAdding: .day, value: plusDays, to: cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!)!
        }
        for i in 0..<45 {
            _ = lib.photo(at: date(2018 + i % 7, 1 + (i * 5) % 12, 1 + (i * 7) % 27, hour: 10 + i % 9), Places.munich, jitterMeters: 3_000)
        }
        var stays: [[AssetID]] = []
        for (place, y, m, d, days, photos) in sparseTrips {
            stays.append((0..<photos).map { i in lib.photo(at: date(y, m, d, plusDays: i % days, hour: 9 + i % 10), place, jitterMeters: 2_000) })
        }
        return Library(assets: lib.assets, stays: stays)
    }

    static let all: [(String, @Sendable () -> Library)] = [
        ("commuter", { commuter() }), ("commuterPhotographing", { commuter(photographsAtWork: true) }),
        ("weekendHome", weekendHome), ("holidayFlat", holidayFlat), ("family", family), ("movingHouse", movingHouse),
        ("semester", { semester() }), ("semesterChristmas", { semester(christmasAtHome: true) }), ("longJourney", longJourney),
        ("businessTrips", businessTrips), ("digitalNomad", digitalNomad), ("mostlyWhileTravelling", mostlyWhileTravelling),
    ]
}

private extension LifePatterns.Library {
    func with(_ lib: LibraryBuilder) -> LifePatterns.Library {
        LifePatterns.Library(assets: lib.assets, stays: stays)
    }
}
