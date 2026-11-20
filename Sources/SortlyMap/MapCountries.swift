import Foundation
import SortlyCore

/// The visited countries of "Deine Welt" and the towns counted beside them (concept §5, "Länder"
/// and "Städte": as the travel atlas counts them today, `TravelAtlas.compute`). Two differences
/// to the atlas: a place counts only when it comes from GPS (`AssetFacts.gpsPlace`, never a place
/// guessed from the picture), and photos taken in flight (`AirborneFilter`) count for nothing
/// (concept §5: "Flugzeugfotos zählen nicht").
public enum MapCountries {
    /// The countries with at least `minimumPhotos` photos, first visit order (then code).
    ///
    /// - A photo counts for the ISO code of its GPS place. A disputed area has no code (decision
    ///   18.11.2026), so its photos make no country; a code always wins over an area, as in the
    ///   atlas (`TravelAtlas.countryKey`).
    /// - A photo listed twice (the same asset id) counts once, so a duplicated single photo can
    ///   never reach the minimum (concept §5: one wrong photo makes no country).
    /// - `firstVisit` is the earliest dated photo there. A country whose photos all lack a date is
    ///   left out: it has no first visit, so it could get no year on its stamp, no place in the
    ///   time travel and no ordinal for "Neues Land". (The atlas counts it, sorted last; PhotoKit
    ///   almost always dates a photo, so this is a damaged library, where showing less is safer
    ///   than showing a made-up year.)
    /// - `tripIDs`: the trips (`AssetFacts.tripID`) with at least one counted photo there, ordered
    ///   by their start in `tripStarts`, then id; a trip missing from `tripStarts` comes last.
    public static func compute(facts: [AssetFacts], airborne: Set<AssetID>, tripStarts: [SortlyID: Date],
                               minimumPhotos: Int = MapSummary.minimumPhotosPerCountry) -> [MapCountry] {
        struct Tally {
            var photos = Set<AssetID>()
            var firstVisit: Date?
            var trips = Set<SortlyID>()

            mutating func add(_ fact: AssetFacts) {
                photos.insert(fact.id)
                if let date = fact.asset.creationDate { firstVisit = min(firstVisit ?? date, date) }
                if let trip = fact.tripID { trips.insert(trip) }
            }
        }
        var tallies: [String: Tally] = [:]
        for fact in facts {
            guard let code = isoCode(fact.gpsPlace?.isoCountryCode), !airborne.contains(fact.id) else { continue }
            tallies[code, default: Tally()].add(fact)
        }
        let countries = tallies.compactMap { code, tally -> MapCountry? in
            guard tally.photos.count >= minimumPhotos, let firstVisit = tally.firstVisit else { return nil }
            let trips = tally.trips.sorted { a, b in
                (tripStarts[a] ?? .distantFuture, a.rawValue) < (tripStarts[b] ?? .distantFuture, b.rawValue)
            }
            return MapCountry(code: code, firstVisit: firstVisit, photoCount: tally.photos.count, tripIDs: trips,
                              isState: WorldStates.isState(code), continent: Continent.forCountryCode(code),
                              region: WorldRegion.of(countryCode: code))
        }
        return inFirstVisitOrder(countries)
    }

    /// Distinct towns, as the atlas counts them: a town is its country key and its name, so
    /// "Frankfurt" in Germany and in the US are two, and towns in a disputed area count (keyed by
    /// the area, decision 18.11.2026 and the second review of 752ba07). GPS places only, photos
    /// in flight left out.
    public static func cityCount(facts: [AssetFacts], airborne: Set<AssetID>) -> Int {
        struct Town: Hashable {
            var country: String
            var name: String
        }
        var towns = Set<Town>()
        for fact in facts {
            guard let place = fact.gpsPlace, let town = place.locality, !town.isEmpty, let country = countryKey(of: place),
                  !airborne.contains(fact.id) else { continue }
            towns.insert(Town(country: country, name: town))
        }
        return towns.count
    }

    /// `countries` by first visit, then code: the order of the passport's stamps, of "Neu: …" and
    /// of the ordinals of "Neues Land". A total order, whatever order they come in.
    static func inFirstVisitOrder(_ countries: [MapCountry]) -> [MapCountry] {
        countries.sorted { ($0.firstVisit, $0.code) < ($1.firstVisit, $1.code) }
    }

    /// The prefix of a disputed area's key, as the atlas writes it (`TravelAtlas.disputedPrefix`).
    static let disputedPrefix = "disputed-"

    /// A place's country code, or "disputed-<id>" in a disputed area (no code there), as the
    /// atlas keys it (`TravelAtlas.countryKey`).
    static func countryKey(of place: PlaceComponents) -> String? {
        if let code = isoCode(place.isoCountryCode) { return code }
        guard let area = place.disputedArea, !area.isEmpty else { return nil }
        return disputedPrefix + area
    }

    /// An ISO code in upper case (a place made through `PlaceComponents.init` already has it so,
    /// a decoded one may not), or `nil` for no code, an empty one or a disputed area's key.
    static func isoCode(_ code: String?) -> String? {
        guard let code, !code.isEmpty, !code.hasPrefix(disputedPrefix) else { return nil }
        return code.utf8.contains(where: { (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) ? code.uppercased() : code
    }
}
