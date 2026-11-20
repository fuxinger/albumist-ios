import Foundation
import SortlyCore

extension MapPins {
    /// Every pin of the map, all levels at once ("Stecknadeln nach Bedeutung", concept §4.2); the
    /// app picks the level by the view's width. Ordered by level, then `count` descending, then id.
    ///
    /// Every pin stands at a real place of a trip: never at home, and never at a computed middle
    /// that could lie in the sea (an island trip in Croatia, a country of islands).
    /// - `.trip`: one per trip, at its destination ("trip:<id>").
    /// - `.place`: one per place of a trip ("place:<trip id>:<index>").
    /// - `.country`: one per visited country (`countries`) with trip photos there, at the trip
    ///   place with the most photos in it, across all trips ("country:<code>"). A country without
    ///   trip photos gets none: it is only tinted, as a pin would stand on everyday photos at home.
    ///   Nor does a country whose trip photos make no place (fewer than
    ///   `TripGeometry.minimumPhotosPerPlace` photos of one day at one spot): a pin anywhere else
    ///   could stand in another country, and like a record, a pin needs a real place (concept §5).
    /// - `.worldRegion`: one per region with a country pin, at the trip place with the most photos
    ///   in the region ("bei der Reise mit den meisten Fotos dieser Gegend"), its badge counting
    ///   all visited countries of the region, those without trips too ("region:<raw value>").
    ///
    /// Places tie by more photos, then the earlier trip, then the smaller trip id, then the lower
    /// index. `years` are the years of the pin's trips as the time travel counts them (each
    /// trip's first local day, `MapYears.compute`), oldest first, so the time travel shows a
    /// place in the year of its trip.
    public static func build(trips: [MapTrip], countries: [MapCountry]) -> [MapPin] {
        let trips = MapArcs.byLeadership(trips)
        var startYears: [String: Int] = [:]
        for trip in trips { startYears[trip.id.rawValue] = trip.geometry.firstDay.year }

        var pins: [MapPin] = []
        for trip in trips {
            let year = startYears[trip.id.rawValue].map { [$0] } ?? []
            if let pin = PinBuilding.tripPin(trip, years: year) { pins.append(pin) }
            pins += PinBuilding.placePins(trip, years: year)
        }

        let visited = PinBuilding.onceEach(countries)
        let codes = Set(visited.map(\.code))
        // The best trip place per visited country, and the best one with a photo for the pin.
        var best: [String: PinAnchor] = [:]
        var bestWithCover: [String: PinAnchor] = [:]
        for trip in trips {
            for (index, place) in trip.geometry.places.enumerated() {
                guard let code = place.countryKey, codes.contains(code), (trip.geometry.countryPhotos[code] ?? 0) > 0,
                      place.coordinate.isPlausible else { continue }
                let anchor = PinAnchor(trip: trip, index: index, place: place)
                if best[code].map(anchor.ranks(before:)) ?? true { best[code] = anchor }
                if anchor.cover != nil, bestWithCover[code].map(anchor.ranks(before:)) ?? true { bestWithCover[code] = anchor }
            }
        }
        func years(of countries: [MapCountry]) -> [Int] {
            Array(Set(countries.flatMap { $0.tripIDs.compactMap { startYears[$0.rawValue] } })).sorted()
        }

        var byRegion: [WorldRegion: [MapCountry]] = [:]
        for country in visited {
            if let region = country.region { byRegion[region, default: []].append(country) }
            guard let anchor = best[country.code] else { continue }
            pins.append(MapPin(id: "country:\(country.code)", level: .country, coordinate: anchor.coordinate, countryKey: country.code,
                               region: country.region, count: country.tripIDs.count, cover: bestWithCover[country.code]?.cover,
                               years: years(of: [country])))
        }
        for region in WorldRegion.allCases {
            let members = byRegion[region] ?? []
            guard let anchor = PinBuilding.first(members.compactMap { best[$0.code] }) else { continue }
            let cover = PinBuilding.first(members.compactMap { bestWithCover[$0.code] })?.cover
            pins.append(MapPin(id: "region:\(region.rawValue)", level: .worldRegion, coordinate: anchor.coordinate, region: region,
                               count: members.count, cover: cover, years: years(of: members)))
        }
        // Level, then `count` descending, then id. Sorted on small keys rather than whole pins:
        // tens of thousands of places.
        return pins.indices
            .map { (level: pins[$0].level, count: pins[$0].count, id: pins[$0].id, index: $0) }
            .sorted { a, b in
                if a.level != b.level { return a.level < b.level }
                if a.count != b.count { return a.count > b.count }
                return a.id < b.id
            }
            .map { pins[$0.index] }
    }
}

/// A trip place as a candidate for a country's or a region's pin.
private struct PinAnchor: Sendable {
    var photoCount: Int
    var start: Date
    var tripID: String
    var index: Int
    var coordinate: GeoCoordinate
    var cover: AssetID?

    init(trip: MapTrip, index: Int, place: TripPlace) {
        photoCount = place.photoCount
        start = trip.geometry.start
        tripID = trip.id.rawValue
        self.index = index
        coordinate = place.coordinate
        cover = place.coverCandidates.first
    }

    /// More photos first, then the earlier trip, then the smaller trip id, then the lower index.
    func ranks(before other: PinAnchor) -> Bool {
        if photoCount != other.photoCount { return photoCount > other.photoCount }
        if start != other.start { return start < other.start }
        if tripID != other.tripID { return tripID < other.tripID }
        return index < other.index
    }
}

private enum PinBuilding {
    static func tripPin(_ trip: MapTrip, years: [Int]) -> MapPin? {
        let geometry = trip.geometry
        guard geometry.destination.isPlausible else { return nil }
        let destination = geometry.destinationIndex.flatMap { geometry.places.indices.contains($0) ? $0 : nil }
        let cover = destination.flatMap { geometry.places[$0].coverCandidates.first } ?? anyCover(geometry)
        return MapPin(id: "trip:\(trip.id.rawValue)", level: .trip, coordinate: geometry.destination, title: trip.title,
                      countryKey: geometry.mainCountryKey, tripID: trip.id, placeIndex: destination, count: geometry.photoCount,
                      cover: cover, years: years)
    }

    static func placePins(_ trip: MapTrip, years: [Int]) -> [MapPin] {
        trip.geometry.places.enumerated().compactMap { index, place in
            guard place.coordinate.isPlausible else { return nil }
            return MapPin(id: "place:\(trip.id.rawValue):\(index)", level: .place, coordinate: place.coordinate, title: place.name,
                          countryKey: place.countryKey, tripID: trip.id, placeIndex: index, count: place.photoCount,
                          cover: place.coverCandidates.first, years: years)
        }
    }

    /// A trip's photo when its destination has none: the first candidate of its place with the
    /// most photos that has one (a tie: the lower index).
    static func anyCover(_ geometry: TripGeometry) -> AssetID? {
        var best: (photoCount: Int, cover: AssetID)?
        for place in geometry.places {
            guard let cover = place.coverCandidates.first else { continue }
            if best.map({ place.photoCount > $0.photoCount }) ?? true { best = (place.photoCount, cover) }
        }
        return best?.cover
    }

    /// `countries` by code, a repeated code (the summary never has one) kept once: its earliest
    /// first visit. Never a disputed area, which is no country (decision 18.11.2026), even if one
    /// came in: it would get a pin and count in a region's badge.
    static func onceEach(_ countries: [MapCountry]) -> [MapCountry] {
        let ordered = countries
            .filter { !$0.code.hasPrefix(disputedPrefix) }
            .sorted { ($0.code, $0.firstVisit, $1.photoCount) < ($1.code, $1.firstVisit, $0.photoCount) }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.code).inserted }
    }

    /// How a disputed area's key begins (`TripPlace.countryKey`, as the atlas keys it).
    static let disputedPrefix = "disputed-"

    static func first(_ anchors: [PinAnchor]) -> PinAnchor? {
        anchors.min { $0.ranks(before: $1) }
    }
}
