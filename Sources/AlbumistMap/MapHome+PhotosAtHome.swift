import Foundation
import AlbumistCore

// The photos at home that `MapHome.Resolver` works out the homes of the trips from: read from the
// facts once (`PhotosAtHome`), and those that show where a detected home was, in time order
// (`Evidence`).

extension MapHome {
    /// Every photo at home with a usable location (`AssetFacts.atHome`, as the trip detection
    /// marked it), read from the facts once: when, where and in which country. One pass over the
    /// facts, which is most of the work in a large library.
    struct PhotosAtHome {
        private(set) var photos: [Photo] = []
        /// The photos' country codes as the map keeps them (`MapHome.countryCode`), each once.
        private(set) var codes: [String] = []

        init(facts: [AssetFacts]) {
            var known: [String: Int] = [:]
            // Most photos have the country of the photo before them: a code is looked up only
            // when it changes.
            var last: (raw: String, country: Int?)?
            photos.reserveCapacity(facts.count)
            var index = -1
            for f in facts {
                index += 1
                guard f.atHome else { continue }
                let asset = f.asset
                guard let coordinate = asset.usableLocation else { continue }
                var country: Int?
                if let raw = f.gpsPlace?.isoCountryCode {
                    if let last, last.raw == raw {
                        country = last.country
                    } else {
                        if let code = MapHome.countryCode(raw) {
                            if let k = known[code] {
                                country = k
                            } else {
                                country = codes.count
                                known[code] = codes.count
                                codes.append(code)
                            }
                        }
                        last = (raw, country)
                    }
                }
                photos.append(Photo(date: asset.creationDate, coordinate: coordinate, country: country, fact: index))
            }
        }

        /// The country most photos at home within `countryRadiusMeters` of `center` have (ties:
        /// the smaller code); nil when none has one. Asked once per home the user chose and once
        /// for the detected home; the distance is the local flat one, exact enough at 30 km and
        /// free of trigonometry per photo.
        func mostCommonCountry(near center: GeoCoordinate) -> String? {
            let metersPerDegreeLongitude = GeoMath.metersPerDegreeLatitude * cos(center.latitude * .pi / 180)
            let limit = MapHome.countryRadiusMeters * MapHome.countryRadiusMeters
            var counts = [Int](repeating: 0, count: codes.count)
            for photo in photos {
                guard let country = photo.country else { continue }
                let dy = (photo.coordinate.latitude - center.latitude) * GeoMath.metersPerDegreeLatitude
                let dx = MapHome.normalizedLongitude(photo.coordinate.longitude - center.longitude) * metersPerDegreeLongitude
                if dx * dx + dy * dy <= limit { counts[country] += 1 }
            }
            return MapHome.mostCommon(counts, codes: codes)
        }
    }

    /// The photos at home that show where a detected home was: dated, on a date the user left to
    /// the detection (`HomeSettings.home(at:)` is `.detected`), in time order (photos of the same
    /// instant by id, then place, so any order of the facts gives the same windows).
    struct Evidence {
        let dates: [Date]
        let coordinates: [GeoCoordinate]
        /// Per code of `codes`: the positions of its photos, ascending. A window's count of a
        /// country is then two binary searches, however many photos the window holds.
        let positions: [[Int]]
        let codes: [String]

        init(_ atHome: PhotosAtHome, facts: [AssetFacts], settings: HomeSettings) {
            let photos = atHome.photos
            var order: [Entry] = []
            order.reserveCapacity(photos.count)
            for (k, photo) in photos.enumerated() {
                if let date = photo.date { order.append((date, k)) }
            }
            // Small entries sorted by date; the ids are read only for photos of the same instant.
            order.sort { a, b in
                if a.date != b.date { return a.date < b.date }
                let p = photos[a.photo], q = photos[b.photo]
                let pid = facts[p.fact].id.rawValue, qid = facts[q.fact].id.rawValue
                if pid != qid { return pid < qid }
                return (p.coordinate.latitude, p.coordinate.longitude) < (q.coordinate.latitude, q.coordinate.longitude)
            }
            // Nothing set: every date is the detection's.
            if !settings.isAutomatic { order = Self.leftToTheDetection(order, settings: settings) }
            var dates: [Date] = [], coordinates: [GeoCoordinate] = []
            dates.reserveCapacity(order.count)
            coordinates.reserveCapacity(order.count)
            var positions = [[Int]](repeating: [], count: atHome.codes.count)
            for entry in order {
                let photo = photos[entry.photo]
                if let country = photo.country { positions[country].append(dates.count) }
                dates.append(entry.date)
                coordinates.append(photo.coordinate)
            }
            self.dates = dates
            self.coordinates = coordinates
            self.positions = positions
            codes = atHome.codes
        }

        /// The entries (in time order) on dates the user left to the detection. The settings'
        /// answer changes only at the edges of the user's periods (a former home's `from` and
        /// `until`, the current home's `confirmedFrom`; the mode itself, "Kein Zuhause" for one,
        /// holds for all time), so it is asked once per run of photos between two edges rather
        /// than for each photo.
        static func leftToTheDetection(_ entries: [Entry], settings: HomeSettings) -> [Entry] {
            var edges: [Date] = settings.former.compactMap(\.from) + settings.former.map(\.until)
            if let confirmedFrom = settings.confirmedFrom { edges.append(confirmedFrom) }
            edges.sort()
            var result: [Entry] = []
            var next = 0
            var isDetected = false
            var asked = false
            for entry in entries {
                if !asked || (next < edges.count && entry.date >= edges[next]) {
                    while next < edges.count, edges[next] <= entry.date { next += 1 }
                    if case .detected = settings.home(at: entry.date) { isDetected = true } else { isDetected = false }
                    asked = true
                }
                if isDetected { result.append(entry) }
            }
            return result
        }

        /// Photos from `lower` (included) to `upper` (not included).
        func window(from lower: Date, before upper: Date) -> Range<Int> {
            let a = Self.firstIndex(in: dates) { $0 >= lower }
            return a..<max(a, Self.firstIndex(in: dates) { $0 >= upper })
        }

        /// Photos after `lower` (not included) up to `upper` (included).
        func window(after lower: Date, through upper: Date) -> Range<Int> {
            let a = Self.firstIndex(in: dates) { $0 > lower }
            return a..<max(a, Self.firstIndex(in: dates) { $0 > upper })
        }

        /// Photos from `lower` up to `upper`, both included.
        func window(from lower: Date, through upper: Date) -> Range<Int> {
            let a = Self.firstIndex(in: dates) { $0 >= lower }
            return a..<max(a, Self.firstIndex(in: dates) { $0 > upper })
        }

        /// Where the window's photos were, rounded, with their most common country; nil for an
        /// empty window.
        func home(in window: Range<Int>) -> RoundedHome? {
            guard let point = GeoMath.dayPoint(MapHome.daySample(window).map { coordinates[$0] }) else { return nil }
            return RoundedHome(coordinate: MapHome.rounded(point), countryCode: mostCommonCountry(in: window))
        }

        /// The country most of the window's photos have (ties: the smaller code); nil when none has one.
        func mostCommonCountry(in window: Range<Int>) -> String? {
            let counts = positions.map { Self.firstIndex(in: $0) { $0 >= window.upperBound } - Self.firstIndex(in: $0) { $0 >= window.lowerBound } }
            return MapHome.mostCommon(counts, codes: codes)
        }

        /// The first index whose element satisfies `isAtOrAfter`, which must be false for a
        /// prefix of `elements` and true for the rest; `elements.count` when none does.
        static func firstIndex<T>(in elements: [T], where isAtOrAfter: (T) -> Bool) -> Int {
            var low = 0, high = elements.count
            while low < high {
                let mid = (low + high) / 2
                if isAtOrAfter(elements[mid]) { high = mid } else { low = mid + 1 }
            }
            return low
        }
    }
}

extension MapHome.PhotosAtHome {
    /// One photo at home: when, where and in which country.
    struct Photo {
        var date: Date?
        var coordinate: GeoCoordinate
        /// Into `codes`; nil without a country from GPS (`AssetFacts.gpsPlace`).
        var country: Int?
        /// Into the facts, for the order of photos taken at the same instant.
        var fact: Int
    }
}

extension MapHome.Evidence {
    /// A dated photo at home: its date, and where it is in `PhotosAtHome.photos`.
    typealias Entry = (date: Date, photo: Int)
}
