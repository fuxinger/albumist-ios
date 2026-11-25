import Foundation
import AlbumistCore

/// Home on the map, only ever rounded (concept §8, "auf etwa 10 km gerundet"): the house in the
/// app and the start of each trip's arc. The exact home never leaves this file: everything it
/// returns is the centre of a `gridMeters` grid cell.
///
/// Which home a trip starts from is the user's word first, as everywhere in the app
/// (`HomeSettings.home(at:)` at the trip's start): a chosen home, former ones included ("Bis 2019:
/// Hamburg"), wins over the photos; "Kein Zuhause" means no home and no arc. Where the user said
/// nothing, the photos the trip detection found at home in the months around the trip decide, so
/// a trip before a move starts at the old home and one after it at the new one (concept §8,
/// "Frühere Wohnorte").
public enum MapHome {
    /// Home is kept and shown only as the centre of a cell this wide (concept §8: about 10 km).
    public static let gridMeters = 10_000.0
    /// The farthest `rounded(_:)` moves a point (half a cell's diagonal, see there). Whatever must
    /// keep a distance from the real home keeps this much more from the rounded one
    /// (`MapShare.nearHomeMeters`).
    public static let maximumRoundingMeters = 7_250.0
    /// How far before a trip (or after it) the photos at home tell where home was: the trip
    /// detection's window for the home of a time (`TripDetector.Configuration.homeWindowDays`).
    /// The detection may count several homes at one time; the map takes the one most of these
    /// photos were at, or the newest weeks' after a move (`moveLookback`).
    public static let lookback: TimeInterval = TimeInterval(TripDetector.Configuration().homeWindowDays) * 86_400
    /// The newest weeks of the `lookback`: where the photos at home of these were tells a move in
    /// them (`Resolver.detected(from:to:)`). A trip a month after a move would otherwise start at
    /// the old home, whose photos still fill most of the months before it.
    public static let moveLookback: TimeInterval = 30 * 86_400

    /// Photos at home within this distance of a home tell its country: the trip detection's home
    /// radius, inside which photos count as at home (`TripDetector.Configuration.homeRadiusMeters`).
    static let countryRadiusMeters = TripDetector.Configuration().homeRadiusMeters

    // MARK: Where the house shows

    /// The house shows only in the middle zoom (concept §8: "wenn der Ausschnitt 300 bis 3.000 km
    /// breit ist"): from this view width on ...
    public static let houseMinimumWidthMeters = 300_000.0
    /// ... up to this one. In the world view there is no house; closer than 300 km it is gone, so
    /// it never points to home more closely than its 10 km rounding at a glance.
    public static let houseMaximumWidthMeters = 3_000_000.0

    /// Whether the globe or map shows the house in a view this wide on the ground. A width that is
    /// no number (a broken camera state) shows none: privacy wins.
    public static func showsHouse(atWidth meters: Double) -> Bool {
        meters >= houseMinimumWidthMeters && meters <= houseMaximumWidthMeters
    }

    // MARK: Rounding

    /// The centre of the grid cell `coordinate` lies in: `GeoCell`'s latitude bands of
    /// `gridMeters`, and in each band `GeoCell`'s longitude step widened just enough that a whole
    /// number of cells goes round the Earth (by less than 0.1 % up to 85° latitude).
    ///
    /// Why not `GeoCell`'s own longitude grid: it does not close at the antimeridian. Its last
    /// cell of a band runs past 180°, so its centre could lie at 180.04° (and, written as
    /// -179.96°, fall into another cell: rounding twice would move the point), and the cells cut
    /// off on either side of 180° can be only metres wide, which would give away a home in Fiji or
    /// Chukotka to within metres. Here every cell of a band is equally wide and never narrower
    /// than `GeoCell`'s, so:
    /// - the result's longitude is in [-180, 180) and its latitude in [-90, 90];
    /// - rounding is idempotent: the centre lies in its own cell, so `rounded(rounded(x))` is
    ///   `rounded(x)`, bit for bit;
    /// - the result is at most half a cell's diagonal from the input: about 7.1 km (under 7.13 km
    ///   up to 88° latitude; under 7.25 km nearer the poles, where a cell's meridians converge
    ///   and its wider edge lies farther from its centre).
    ///
    /// A latitude beyond ±90° counts as the pole, any longitude is wrapped. A coordinate that is
    /// not finite (never one of the library's: `GeoCoordinate.isPlausible`) counts as 0° rather
    /// than stopping the app.
    public static func rounded(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        let latitude = coordinate.latitude.isFinite ? min(max(coordinate.latitude, -90), 90) : 0
        let longitude = coordinate.longitude.isFinite ? normalizedLongitude(coordinate.longitude) : 0
        let band = GeoCell(GeoCoordinate(latitude: latitude, longitude: 0), sizeMeters: gridMeters).y
        // The band's middle and longitude step exactly as `GeoCell` works them out.
        let latitudeStep = gridMeters / GeoMath.metersPerDegreeLatitude
        let bandLatitude = (Double(band) + 0.5) * latitudeStep
        let longitudeStep = latitudeStep / max(cos(bandLatitude * .pi / 180), 0.01)
        let cells = max(1, Int((360 / longitudeStep).rounded(.down)))
        let width = 360 / Double(cells)
        let column = min(cells - 1, Int(((longitude + 180) / width).rounded(.down)))
        return GeoCoordinate(latitude: min(max(bandLatitude, -90), 90), longitude: -180 + (Double(column) + 0.5) * width)
    }

    /// `longitude` wrapped into [-180, 180); values already in it stay exactly as they are.
    static func normalizedLongitude(_ longitude: Double) -> Double {
        guard longitude < -180 || longitude >= 180 else { return longitude }
        let turned = (longitude + 180).truncatingRemainder(dividingBy: 360)
        let wrapped = (turned < 0 ? turned + 360 : turned) - 180
        // `turned + 360` can round up to 360 for a tiny negative remainder.
        return wrapped >= 180 ? wrapped - 360 : wrapped
    }

    // MARK: The home of each trip

    /// The home of each trip's time, rounded: where its arc starts and what tells "abroad" for
    /// the favourite country. By `settings.home(at: trip.start)`:
    /// - a chosen home (current or former): its centre; its country from the place the user
    ///   chose, else from the photos at home near it;
    /// - "Kein Zuhause": no entry;
    /// - left to the detection: `detected` (Albumist's home at the end of the library) when the
    ///   trip starts on or after the move there (`since`); else where the photos at home of the
    ///   `lookback` before the trip's start were (`GeoMath.dayPoint` of them in time order: the
    ///   place of most of them, a real photo location), or of its newest `moveLookback` alone
    ///   when those were more than `countryRadiusMeters` away from that (a move in those weeks);
    ///   none there: those of the `lookback` after its end. Only photos on dates the user also
    ///   left to the detection count, so a former home the user entered never leaks into the
    ///   months after it. With no photo at home in either window, `detected` when it already held
    ///   at the trip's start (`since` nil or not later); otherwise no entry. The country: the most
    ///   common one among the photos used (ties: the smaller code); for `detected`, among the
    ///   photos at home near it.
    ///
    /// Photos at home are the trip detection's (`AssetFacts.atHome`, with a usable location and a
    /// date). Linear: they are sorted once and each trip's windows are found by binary search;
    /// `dayPoint` looks at a sample of at most `GeoMath.daySample` photos per trip. A trip id
    /// given twice gets the home of its earliest entry.
    public static func homes(for trips: [Trip], facts: [AssetFacts], settings: HomeSettings, detected: DetectedHome?) -> [AlbumistID: RoundedHome] {
        var resolver = Resolver(facts: facts, settings: settings, detected: detected)
        var result: [AlbumistID: RoundedHome] = [:]
        var seen = Set<AlbumistID>()
        for trip in trips.sorted(by: { ($0.id.rawValue, $0.start, $0.end) < ($1.id.rawValue, $1.start, $1.end) }) {
            guard seen.insert(trip.id).inserted else { continue }
            let home: RoundedHome?
            switch settings.home(at: trip.start) {
            case .none: home = nil
            case .chosen(let place): home = resolver.chosen(place)
            case .detected: home = resolver.detected(from: trip.start, to: trip.end)
            }
            if let home { result[trip.id] = home }
        }
        return result
    }

    /// Today's home, rounded: the house in the app. By `settings.home(at: now)`: a chosen home;
    /// none for "Kein Zuhause"; left to the detection: `detected` (country from the photos at
    /// home near it), else where the photos at home of the `lookback` up to the newest of them
    /// (not after `now`) were, else none.
    public static func current(facts: [AssetFacts], settings: HomeSettings, detected: DetectedHome?, now: Date) -> RoundedHome? {
        var resolver = Resolver(facts: facts, settings: settings, detected: detected)
        switch settings.home(at: now) {
        case .none: return nil
        case .chosen(let place): return resolver.chosen(place)
        case .detected: return resolver.detectedHome() ?? resolver.newest(upTo: now)
        }
    }

    // MARK: Working it out

    /// The photos at home and the homes worked out from them, shared by all trips. The photos are
    /// read only when a home needs them (a chosen home with its country named needs none).
    struct Resolver {
        let facts: [AssetFacts]
        let settings: HomeSettings
        let detected: DetectedHome?
        private(set) lazy var atHome = PhotosAtHome(facts: facts)
        private(set) lazy var evidence = Evidence(atHome, facts: facts, settings: settings)
        /// Per chosen home, worked out once however many trips start from it.
        private var chosenHomes: [HomePlace: RoundedHome?] = [:]
        private var detectedResult: RoundedHome??

        init(facts: [AssetFacts], settings: HomeSettings, detected: DetectedHome?) {
            self.facts = facts
            self.settings = settings
            self.detected = detected
        }

        /// A home the user chose: its centre, rounded. No entry for a centre the library could
        /// not have (`GeoCoordinate.isPlausible`).
        mutating func chosen(_ place: HomePlace) -> RoundedHome? {
            if let known = chosenHomes[place] { return known }
            var home: RoundedHome?
            if place.center.isPlausible {
                let country = MapHome.countryCode(place.components?.isoCountryCode) ?? atHome.mostCommonCountry(near: place.center)
                home = RoundedHome(coordinate: MapHome.rounded(place.center), countryCode: country)
            }
            chosenHomes[place] = home
            return home
        }

        /// `detected`, rounded, with the country of the photos at home near it.
        mutating func detectedHome() -> RoundedHome? {
            if let known = detectedResult { return known }
            var home: RoundedHome?
            if let detected, detected.center.isPlausible {
                home = RoundedHome(coordinate: MapHome.rounded(detected.center), countryCode: atHome.mostCommonCountry(near: detected.center))
            }
            detectedResult = .some(home)
            return home
        }

        /// The detected home of a trip from `start` to `end`.
        mutating func detected(from start: Date, to end: Date) -> RoundedHome? {
            // After the move to today's home, as the detection dates it: that home.
            if let since = detected?.since, since <= start, let home = detectedHome() { return home }
            let before = evidence.window(from: start.addingTimeInterval(-MapHome.lookback), before: start)
            if !before.isEmpty, let months = evidence.home(in: before) {
                // A move in the newest weeks: those tell the home, not the months mostly before it.
                let recent = evidence.window(from: start.addingTimeInterval(-MapHome.moveLookback), before: start)
                if recent.lowerBound > before.lowerBound, let weeks = evidence.home(in: recent),
                   GeoMath.distance(weeks.coordinate, months.coordinate) > MapHome.countryRadiusMeters {
                    return weeks
                }
                return months
            }
            let window = before.isEmpty ? evidence.window(after: end, through: end.addingTimeInterval(MapHome.lookback)) : before
            if let home = evidence.home(in: window) { return home }
            guard let detected, detected.since.map({ $0 <= start }) ?? true else { return nil }
            return detectedHome()
        }

        /// Where the photos at home of the `lookback` up to the newest of them (not after `now`) were.
        mutating func newest(upTo now: Date) -> RoundedHome? {
            let end = evidence.window(from: .distantPast, through: now).upperBound
            guard end > 0 else { return nil }
            let newest = evidence.dates[end - 1]
            return evidence.home(in: evidence.window(from: newest.addingTimeInterval(-MapHome.lookback), through: newest))
        }
    }

    /// The photos `GeoMath.dayPoint` compares when given the whole window, picked without copying
    /// the window (a busy library's 120 days hold thousands of photos at home): all up to
    /// `GeoMath.daySample`, otherwise the middle photo of each of `daySample` equal parts (as
    /// `GeoMath.daySampleIndices`). Given these, `dayPoint` takes them all and finds the same point.
    static func daySample(_ window: Range<Int>) -> [Int] {
        let count = window.count
        guard count > GeoMath.daySample else { return Array(window) }
        return (0..<GeoMath.daySample).map { window.lowerBound + ((2 * $0 + 1) * count) / (2 * GeoMath.daySample) }
    }

    /// The code with the highest count (ties: the smaller code); nil when every count is 0.
    static func mostCommon(_ counts: [Int], codes: [String]) -> String? {
        var best: Int?
        for k in counts.indices where counts[k] > 0 {
            if let b = best, counts[k] < counts[b] || (counts[k] == counts[b] && codes[k] > codes[b]) { continue }
            best = k
        }
        return best.map { codes[$0] }
    }

    /// A country code as the map keeps it: upper case; nil for none or an empty one.
    static func countryCode(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return code.uppercased()
    }
}
