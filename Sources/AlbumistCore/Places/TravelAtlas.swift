import Foundation

/// Personal travel summary for the shareable atlas card. Numbers only, no photos.
public struct TravelAtlas: Hashable, Sendable {
    public struct TripSummary: Hashable, Sendable {
        public var place: String
        public var countryCode: String
        public var start: Date
        public var days: Int
        public var photoCount: Int
        /// The disputed area the trip mostly went to ("Taiwan"), shown in place of a country
        /// (decision Fuchs 18.11.2026); then `countryCode` is empty.
        public var areaName: String? = nil
    }

    /// ISO country codes with at least `minimumPhotosPerCountry` photos.
    public var countryCodes: Set<String> = []
    public var cityCount = 0
    public var tripCount = 0
    public var sinceYear: Int?
    public var longestTripDays: Int?
    /// The longest trip itself, so the atlas can say where it went (Fuchs 15.11.: "Bei der
    /// längsten Reise wäre gerne das Land angezeigt"). The more recent one wins a tie.
    public var longestTrip: TripSummary? {
        trips.max { ($0.days, $0.start) < ($1.days, $1.start) }
    }
    /// Most photographed town outside the home area (by trip photos), if any.
    public var favoriteTripCity: String?
    /// A good photo from the favorite destination for the share image: a real photo the image
    /// analysis has looked at (no screenshot, document, card, video or photo not analysed yet;
    /// `PreviewRank.photo`: the image leaves the device), favorites first, then the largest
    /// one. `nil` when there is none: the image is then shared without a photo.
    public var favoriteTripCover: AssetID?
    /// First photo per country, for the "countries light up in order" animation.
    public var firstVisits: [String: Date] = [:]
    /// All trips, oldest first (main town or country of each trip).
    public var trips: [TripSummary] = []
    /// Set when the atlas covers one calendar year only ("Mein Reisejahr 2025").
    public var year: Int?
    /// In a year atlas: countries visited for the very first time in that year.
    public var newCountryCodes: Set<String> = []

    public var continents: Set<Continent> { Set(countryCodes.compactMap(Continent.forCountryCode)) }
    /// Share of the 195 UN-recognized states (rounded down to whole percent in the UI).
    public var worldShare: Double { min(1, Double(countryCodes.count) / 195) }

    /// How the world share is shown (design review N11): the locale's percent format
    /// ("0,51 %" in German, "0.51%" in English) with two significant digits, so one country
    /// is not "0 %" as with the old whole-number cut-off.
    public static var worldShareStyle: FloatingPointFormatStyle<Double>.Percent {
        .percent.precision(.significantDigits(1...2))
    }
    /// Countries ordered by first visit (unknown dates last, then alphabetically).
    public var countriesByFirstVisit: [String] {
        countryCodes.sorted { a, b in
            switch (firstVisits[a], firstVisits[b]) {
            case let (x?, y?): x == y ? a < b : x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a < b
            }
        }
    }

    /// Emoji flag for an ISO 3166-1 alpha-2 code ("IT" → 🇮🇹).
    public static func flag(_ code: String) -> String {
        let base: UInt32 = 0x1F1E6 - 65
        let scalars = code.uppercased().prefix(2).unicodeScalars.compactMap { Unicode.Scalar(base + $0.value) }
        guard scalars.count == 2 else { return "" }
        return String(String.UnicodeScalarView(scalars))
    }

    public init() {}

    static let disputedPrefix = "disputed-"

    /// A place's country code, or "disputed-<id>" in a disputed area (no code there).
    static func countryKey(of place: PlaceComponents) -> String? {
        place.isoCountryCode ?? place.disputedArea.map { disputedPrefix + $0 }
    }

    public static func compute(facts: [AssetFacts], minimumPhotosPerCountry: Int = 3, calendar: Calendar = .current) -> TravelAtlas {
        var atlas = TravelAtlas()
        var perCountry: [String: Int] = [:]
        var cities = Set<String>()
        var tripCities: [String: Int] = [:]
        var tripSpans: [AlbumistID: (Date, Date)] = [:]
        var tripPlaces: [AlbumistID: [String: Int]] = [:]
        /// Per trip: photos by country code, or by "disputed-<id>" for a disputed area.
        var tripCountries: [AlbumistID: [String: Int]] = [:]
        var areaNames: [String: String] = [:]
        var tripPhotos: [AlbumistID: Int] = [:]
        var firstDate: Date?
        var firstVisit: [String: Date] = [:]

        for f in facts {
            // A disputed area (decision Fuchs 18.11.2026) is no country of the atlas, but its
            // towns and trips count like any other (second review of 752ba07).
            guard let place = f.place, let key = Self.countryKey(of: place) else { continue }
            let code = place.isoCountryCode
            if let code { perCountry[code, default: 0] += 1 }
            if code == nil, let name = place.country { areaNames[key] = name }
            if let city = place.locality { cities.insert(key + "|" + city) }
            if let date = f.asset.creationDate {
                firstDate = min(firstDate ?? date, date)
                if let code { firstVisit[code] = min(firstVisit[code] ?? date, date) }
                if let trip = f.tripID {
                    let span = tripSpans[trip] ?? (date, date)
                    tripSpans[trip] = (min(span.0, date), max(span.1, date))
                }
            }
            if f.tripID != nil, let city = place.locality { tripCities[city, default: 0] += 1 }
            if let trip = f.tripID {
                tripPhotos[trip, default: 0] += 1
                tripCountries[trip, default: [:]][key, default: 0] += 1
                tripPlaces[trip, default: [:]][place.locality ?? place.country ?? key, default: 0] += 1
            }
        }

        atlas.countryCodes = Set(perCountry.filter { $0.value >= minimumPhotosPerCountry }.keys)
        atlas.firstVisits = firstVisit.filter { atlas.countryCodes.contains($0.key) }
        atlas.cityCount = cities.count
        atlas.tripCount = tripSpans.count
        atlas.sinceYear = firstDate.map { calendar.component(.year, from: $0) }
        atlas.longestTripDays = tripSpans.values.map { span in
            (calendar.dateComponents([.day], from: calendar.startOfDay(for: span.0), to: calendar.startOfDay(for: span.1)).day ?? 0) + 1
        }.max()
        func top(_ counts: [String: Int]?) -> String? { counts?.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
        atlas.trips = tripSpans.compactMap { id, span -> TripSummary? in
            guard let place = top(tripPlaces[id]), let key = top(tripCountries[id]) else { return nil }
            let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: span.0), to: calendar.startOfDay(for: span.1)).day ?? 0) + 1
            let disputed = key.hasPrefix(Self.disputedPrefix)
            return TripSummary(place: place, countryCode: disputed ? "" : key, start: span.0, days: days, photoCount: tripPhotos[id] ?? 0,
                               areaName: disputed ? areaNames[key] : nil)
        }
        .sorted { $0.start < $1.start }
        atlas.favoriteTripCity = tripCities.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        if let city = atlas.favoriteTripCity {
            func rank(_ a: AssetSnapshot) -> (Int, Int, String) {
                (a.isFavorite ? 1 : 0, a.pixelWidth * a.pixelHeight, a.id.rawValue)
            }
            atlas.favoriteTripCover = facts
                .lazy
                .filter { $0.tripID != nil && $0.place?.locality == city && $0.asset.kind == .image && PreviewRank($0) == .photo }
                .map(\.asset)
                .max { rank($0) < rank($1) }?
                .id
        }
        return atlas
    }

    /// Atlas for one calendar year, with the countries that were new in that year.
    public static func compute(facts: [AssetFacts], year: Int?, minimumPhotosPerCountry: Int = 3, calendar: Calendar = .current) -> TravelAtlas {
        guard let year else { return compute(facts: facts, minimumPhotosPerCountry: minimumPhotosPerCountry, calendar: calendar) }
        let inYear = facts.filter { f in f.asset.creationDate.map { calendar.component(.year, from: $0) == year } ?? false }
        var atlas = compute(facts: inYear, minimumPhotosPerCountry: minimumPhotosPerCountry, calendar: calendar)
        atlas.year = year
        let allTime = compute(facts: facts, minimumPhotosPerCountry: minimumPhotosPerCountry, calendar: calendar)
        atlas.newCountryCodes = atlas.countryCodes.filter { code in
            allTime.firstVisits[code].map { calendar.component(.year, from: $0) == year } ?? false
        }
        return atlas
    }

    /// Years with photos from at least one country or disputed area, newest first (for the
    /// year picker).
    public static func years(facts: [AssetFacts], minimumPhotosPerCountry: Int = 3, calendar: Calendar = .current) -> [Int] {
        var counts: [Int: [String: Int]] = [:]
        for f in facts {
            guard let code = f.place.flatMap(countryKey), let date = f.asset.creationDate else { continue }
            counts[calendar.component(.year, from: date), default: [:]][code, default: 0] += 1
        }
        return counts.filter { $0.value.values.contains { $0 >= minimumPhotosPerCountry } }.keys.sorted(by: >)
    }
}
