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
    /// The device's calendar: the years of the time travel and "this year".
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
        // Photos taken in flight count for nothing: no place, no country, no record.
        let airborne = AirborneFilter.airborne(input.facts.map(\.asset), altitudes: input.altitudes)

        var membersByTrip: [SortlyID: [AssetFacts]] = [:]
        for fact in input.facts {
            if let trip = fact.tripID { membersByTrip[trip, default: []].append(fact) }
        }
        let homes = MapHome.homes(for: input.trips, facts: input.facts, settings: input.homeSettings, detected: input.detectedHome)

        var trips: [MapTrip] = []
        trips.reserveCapacity(input.trips.count)
        var seen = Set<SortlyID>()
        for trip in input.trips.sorted(by: { ($0.start, $0.id.rawValue, $0.end) < ($1.start, $1.id.rawValue, $1.end) }) {
            // A trip stored twice is shown once; one whose photos are all gone (deleted since the
            // analysis) or none of whose photos is drawn (`isDrawn`) has nowhere to be shown.
            guard seen.insert(trip.id).inserted, let members = membersByTrip[trip.id],
                  members.contains(where: { isDrawn($0, airborne: airborne) }) else { continue }
            let geometry = TripGeometry.build(trip: trip, facts: members, airborne: airborne, altitudes: input.altitudes,
                                              timeZone: input.calendar.timeZone)
            let home = homes[trip.id]
            let title = input.tripTitles[trip.id] ?? geometry.destinationName ?? geometry.mainCountryKey ?? ""
            trips.append(MapTrip(geometry: geometry, title: title, stats: TripStats.compute(geometry, home: home), home: home))
        }

        let tripStarts = Dictionary(trips.map { ($0.id, $0.geometry.start) }, uniquingKeysWith: { first, _ in first })
        let countries = MapCountries.compute(facts: input.facts, airborne: airborne, tripStarts: tripStarts, calendar: input.calendar)
        let cities = MapCountries.cityCount(facts: input.facts, airborne: airborne)
        var numbers = WorldNumbers.compute(trips: trips, countries: countries, cities: cities, calendar: input.calendar, now: input.now,
                                           analysisRunning: input.analysisRunning)
        if input.analysisRunning { numbers = numbers.holdingHighs(over: previous?.numbers) }

        return MapSummary(
            computedAt: input.now,
            home: MapHome.current(facts: input.facts, settings: input.homeSettings, detected: input.detectedHome, now: input.now),
            trips: trips,
            countries: countries,
            arcs: MapArcs.build(trips: trips, calendar: input.calendar),
            pins: MapPins.build(trips: trips, countries: countries, calendar: input.calendar),
            numbers: numbers,
            years: MapYears.compute(trips: trips, countries: countries, calendar: input.calendar, through: numbers.year),
            focus: MapPins.focus(on: trips.map(\.geometry.destination))
        )
    }

    /// A photo the map draws (as `TripGeometry.build` takes them): a usable location and a date,
    /// not taken in flight, no screenshot. A trip without one has no place on the map, even
    /// before its places are named.
    static func isDrawn(_ fact: AssetFacts, airborne: Set<AssetID>) -> Bool {
        fact.asset.usableLocation != nil && fact.asset.creationDate != nil && !fact.asset.isScreenshotLike && !airborne.contains(fact.id)
    }
}
