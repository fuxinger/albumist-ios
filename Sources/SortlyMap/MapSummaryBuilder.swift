import Foundation
import SortlyCore

/// What the map summary is worked out from: what the analysis stored, nothing else. No location
/// access, no network: the map is made from the photos already on the iPhone.
public struct MapInput: Sendable {
    /// All facts of the library (as the overview has them).
    public var facts: [AssetFacts]
    /// The stored trips, with their remembered ids.
    public var trips: [Trip]
    /// The trips' names as the app shows them ("Island, Ringstraße"); a trip missing here is named
    /// by its destination, else its main country's code.
    public var tripTitles: [SortlyID: String]
    /// "Dein Zuhause" as the user set it, and what the analysis found by itself.
    public var homeSettings: HomeSettings
    public var detectedHome: DetectedHome?
    /// Altitude per photo in metres, once the analysis stores it; empty until then (no
    /// "Höchstes Foto").
    public var altitudes: [AssetID: Double]
    /// The device's calendar. Only its time zone counts: it dates a photo whose own clock is not
    /// known (`AssetFacts.timeZone`) and tells "this year" of `now`. Every year on the map is the
    /// Gregorian year of a local day (`LocalDay`), as the app's albums count them, so a Japanese
    /// or Buddhist calendar on the device changes no year.
    public var calendar: Calendar
    public var now: Date
    /// The analysis is still running: numbers say "bisher" and never go down (`holdingHighs`).
    public var analysisRunning: Bool

    public init(facts: [AssetFacts], trips: [Trip], tripTitles: [SortlyID: String] = [:], homeSettings: HomeSettings = HomeSettings(),
                detectedHome: DetectedHome? = nil, altitudes: [AssetID: Double] = [:], calendar: Calendar = .sortlyDefault, now: Date = Date(),
                analysisRunning: Bool = false) {
        self.facts = facts
        self.trips = trips
        self.tripTitles = tripTitles
        self.homeSettings = homeSettings
        self.detectedHome = detectedHome
        self.altitudes = altitudes
        self.calendar = calendar
        self.now = now
        self.analysisRunning = analysisRunning
    }
}

extension MapSummary {
    /// Works out everything the map shows (concept §9: once per analysis state, a few hundred
    /// elements instead of every photo). `previous`: the summary shown so far; while the analysis
    /// runs no number goes below it (concept §5, "Zahlen springen nicht zurück").
    ///
    /// Each step is about linear in the photos, so 50,000 photos take a fraction of a second
    /// (`MapSummaryLoadTests`).
    public static func build(_ input: MapInput, previous: MapSummary? = nil) -> MapSummary {
        let zone = input.calendar.timeZone
        // A photo listed twice counts once, everywhere: one photo three times would make a place.
        let facts = uniqueFacts(input.facts)
        // Photos taken in flight count for nothing: no place, no country, no record.
        let airborne = AirborneFilter.airborne(facts.map(\.asset), altitudes: input.altitudes)

        // Today's home exactly, in memory only: a trip's photo nearer to it than the house's
        // rounding is drawn as little as one taken at home (a visit to the flat before moving in
        // would otherwise put a pin on it, as exact as the house is not).
        let homeToday = exactHomeToday(input)
        var membersByTrip: [SortlyID: [AssetFacts]] = [:]
        for fact in facts {
            guard let trip = fact.tripID else { continue }
            var member = fact
            if !member.atHome, let homeToday, let location = member.asset.usableLocation,
               GeoMath.distance(location, homeToday) <= MapHome.maximumRoundingMeters {
                member.atHome = true
            }
            membersByTrip[trip, default: []].append(member)
        }
        let homes = MapHome.homes(for: input.trips, facts: facts, settings: input.homeSettings, detected: input.detectedHome)

        var trips: [MapTrip] = []
        trips.reserveCapacity(input.trips.count)
        var seen = Set<SortlyID>()
        for trip in input.trips.sorted(by: { ($0.start, $0.id.rawValue, $0.end) < ($1.start, $1.id.rawValue, $1.end) }) {
            // A trip stored twice is shown once; one whose photos are all gone (deleted since the
            // analysis) or none of whose photos is drawn (`isDrawn`) has nowhere to be shown.
            guard seen.insert(trip.id).inserted, let members = membersByTrip[trip.id],
                  members.contains(where: { isDrawn($0, airborne: airborne) }) else { continue }
            let geometry = TripGeometry.build(trip: trip, facts: members, airborne: airborne, altitudes: input.altitudes, timeZone: zone)
            let home = homes[trip.id]
            let title = input.tripTitles[trip.id] ?? geometry.destinationName ?? geometry.mainCountryKey ?? ""
            trips.append(MapTrip(geometry: geometry, title: title, stats: TripStats.compute(geometry, home: home), home: home))
        }

        let tripStarts = Dictionary(trips.map { ($0.id, $0.geometry.start) }, uniquingKeysWith: { first, _ in first })
        // A country lists only the trips the map shows: a photo of a trip that is not stored (or
        // has nothing to draw) still counts for the country, but "Neues Land" and the country's
        // pin never point to a trip that is not there.
        let countries = MapCountries.compute(facts: facts, airborne: airborne, tripStarts: tripStarts, timeZone: zone).map { country in
            var country = country
            country.tripIDs = country.tripIDs.filter { tripStarts[$0] != nil }
            return country
        }
        let cities = MapCountries.cityCount(facts: facts, airborne: airborne)
        var numbers = WorldNumbers.compute(trips: trips, countries: countries, cities: cities, timeZone: zone, now: input.now,
                                           analysisRunning: input.analysisRunning)
        if input.analysisRunning { numbers = numbers.holdingHighs(over: previous?.numbers, trips: trips, countries: countries) }

        return MapSummary(
            computedAt: input.now,
            home: MapHome.current(facts: facts, settings: input.homeSettings, detected: input.detectedHome, now: input.now),
            trips: trips,
            countries: countries,
            arcs: MapArcs.build(trips: trips),
            pins: MapPins.build(trips: trips, countries: countries),
            numbers: numbers,
            years: MapYears.compute(trips: trips, countries: countries, through: numbers.year),
            focus: MapPins.focus(on: trips.map(\.geometry.destination))
        )
    }

    /// A photo the map draws (as `TripGeometry.build` takes them): a usable location and a date,
    /// not taken in flight, no screenshot, and not taken at home (`AssetFacts.atHome`: the map
    /// shows trips, and a trip's photos at home would put a place on the exact home; `build`
    /// also marks so a trip's photos within `MapHome.maximumRoundingMeters` of today's home). A
    /// trip without one has no place on the map, even before its places are named.
    static func isDrawn(_ fact: AssetFacts, airborne: Set<AssetID>) -> Bool {
        fact.asset.usableLocation != nil && fact.asset.creationDate != nil && !fact.asset.isScreenshotLike && !fact.atHome
            && !airborne.contains(fact.id)
    }

    /// Today's home exactly, as the house is worked out before rounding (`MapHome.current`): the
    /// home the user chose, else the detected one; none for "Kein Zuhause" or one the library
    /// could not have. Only ever in memory.
    static func exactHomeToday(_ input: MapInput) -> GeoCoordinate? {
        let center: GeoCoordinate?
        switch input.homeSettings.home(at: input.now) {
        case .none: center = nil
        case .chosen(let place): center = place.center
        case .detected: center = input.detectedHome?.center
        }
        return center.flatMap { $0.isPlausible ? $0 : nil }
    }

    /// `facts` with every asset id once, at the place where the id first comes. Of facts sharing
    /// an id (a library or a test listing one photo twice) the one first in `precedes` order
    /// stays, so the same facts in any order keep the same one.
    static func uniqueFacts(_ facts: [AssetFacts]) -> [AssetFacts] {
        var kept: [AssetID: Int] = [:]
        kept.reserveCapacity(facts.count)
        var result: [AssetFacts] = []
        result.reserveCapacity(facts.count)
        for fact in facts {
            if let index = kept[fact.id] {
                if precedes(fact, result[index]) { result[index] = fact }
            } else {
                kept[fact.id] = result.count
                result.append(fact)
            }
        }
        return result
    }

    /// A total order on facts sharing an id (two states of the analysis), to pick one whatever
    /// order they came in:
    /// - one taken at home first: if any copy says so, the photo is never drawn (privacy first,
    ///   as `TripGeometry.build` picks);
    /// - then the one most careful about showing it (`PreviewRank`: a sensitive document, then a
    ///   document, then an analysed photo, then one not analysed yet), so a copy the analysis
    ///   took for a bank card never loses to its twin not looked at yet, and an analysed photo
    ///   wins over its not yet analysed twin;
    /// - then trip, date, location, place and clock;
    /// - then everything else the map reads of it: what the trip geometry reads
    ///   (`TripGeometryBuilder.duplicateKey`), the location's stated accuracy and where the place
    ///   came from;
    /// - last, the whole fact as text, so facts that tie on all of it are equal.
    static func precedes(_ a: AssetFacts, _ b: AssetFacts) -> Bool {
        if a.atHome != b.atHome { return a.atHome }
        let (showA, showB) = (showingOrder(PreviewRank(a)), showingOrder(PreviewRank(b)))
        if showA != showB { return showA < showB }
        // In two parts: the standard library compares tuples of up to six elements.
        func when(_ fact: AssetFacts) -> (String, Double, Double, Double) {
            let location = fact.asset.usableLocation
            return (fact.tripID?.rawValue ?? "", fact.asset.creationDate?.timeIntervalSinceReferenceDate ?? .infinity,
                    location?.latitude ?? .infinity, location?.longitude ?? .infinity)
        }
        func what(_ fact: AssetFacts) -> (String, String, String) {
            (fact.place?.isoCountryCode ?? "", fact.place?.locality ?? "", fact.timeZone?.identifier ?? "")
        }
        let (whenA, whenB) = (when(a), when(b))
        if whenA != whenB { return whenA < whenB }
        let (whatA, whatB) = (what(a), what(b))
        if whatA != whatB { return whatA < whatB }
        let (keyA, keyB) = (TripGeometryBuilder.duplicateKey(a), TripGeometryBuilder.duplicateKey(b))
        if keyA != keyB { return keyA.lexicographicallyPrecedes(keyB) }
        func rest(_ fact: AssetFacts) -> (Double, String) {
            (fact.asset.locationAccuracy ?? -1, fact.placeSource?.rawValue ?? "")
        }
        let (restA, restB) = (rest(a), rest(b))
        if restA != restB { return restA < restB }
        return String(describing: a) < String(describing: b)
    }

    /// `PreviewRank` from the most careful about showing a photo to the least.
    static func showingOrder(_ rank: PreviewRank) -> Int {
        switch rank {
        case .sensitive: 0
        case .document: 1
        case .photo: 2
        case .unknown: 3
        }
    }
}
