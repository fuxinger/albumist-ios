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

        var membersByTrip: [SortlyID: [AssetFacts]] = [:]
        for fact in facts {
            if let trip = fact.tripID { membersByTrip[trip, default: []].append(fact) }
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
    /// shows trips, and a trip's photos at home would put a place on the exact home). A trip
    /// without one has no place on the map, even before its places are named.
    static func isDrawn(_ fact: AssetFacts, airborne: Set<AssetID>) -> Bool {
        fact.asset.usableLocation != nil && fact.asset.creationDate != nil && !fact.asset.isScreenshotLike && !fact.atHome
            && !airborne.contains(fact.id)
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

    /// A total order on what the map reads of a fact (trip, date, location, home, place, clock),
    /// to pick one of two facts with the same id whatever order they came in. Facts equal in all
    /// of it give the same map, so which of them stays does not matter.
    static func precedes(_ a: AssetFacts, _ b: AssetFacts) -> Bool {
        // In two parts: the standard library compares tuples of up to six elements.
        func when(_ fact: AssetFacts) -> (String, Double, Double, Double) {
            let location = fact.asset.usableLocation
            return (fact.tripID?.rawValue ?? "", fact.asset.creationDate?.timeIntervalSinceReferenceDate ?? .infinity,
                    location?.latitude ?? .infinity, location?.longitude ?? .infinity)
        }
        func what(_ fact: AssetFacts) -> (Int, String, String, String) {
            (fact.atHome ? 1 : 0, fact.place?.isoCountryCode ?? "", fact.place?.locality ?? "", fact.timeZone?.identifier ?? "")
        }
        let (whenA, whenB) = (when(a), when(b))
        if whenA != whenB { return whenA < whenB }
        return what(a) < what(b)
    }
}
