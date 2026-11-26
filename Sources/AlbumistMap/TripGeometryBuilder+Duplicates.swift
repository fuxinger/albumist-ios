import Foundation
import AlbumistCore

// A photo listed twice in the facts given to `TripGeometryBuilder.build`: each photo is kept
// once, whatever order its facts come in, so that it counts once in every number.

extension TripGeometryBuilder {
    // MARK: A photo listed twice

    /// `facts` with each photo (asset id) once, in the order they came: a library may list one
    /// twice, maybe in two states of the analysis, and it must count once in every number (concept
    /// §5: a single photo makes no place, no record and no country). Of two facts of one photo the
    /// one `isKept(_:over:)` prefers stays, so the choice never depends on their order. Facts
    /// with no id twice, as a library mostly gives them, come back as they are.
    static func eachPhotoOnce(_ facts: [AssetFacts]) -> [AssetFacts] {
        var seen = Set<AssetID>(minimumCapacity: facts.count)
        guard !facts.allSatisfy({ seen.insert($0.id).inserted }) else { return facts }
        var position: [AssetID: Int] = [:]
        var result: [AssetFacts] = []
        for fact in facts {
            if let p = position[fact.id] {
                if isKept(fact, over: result[p]) { result[p] = fact }
            } else {
                position[fact.id] = result.count
                result.append(fact)
            }
        }
        return result
    }

    /// Whether `build` keeps `a` rather than `b`, two facts of one photo: the one at home when only
    /// one is (privacy first: a photo either calls at home is never drawn), else the one whose
    /// `duplicateKey` comes first. Two facts with equal keys are alike to every step of `build`,
    /// so either gives the same geometry.
    static func isKept(_ a: AssetFacts, over b: AssetFacts) -> Bool {
        if a.atHome != b.atHome { return a.atHome }
        return duplicateKey(a).lexicographicallyPrecedes(duplicateKey(b))
    }

    /// Everything `build` reads of a fact besides its id and whether it is at home, as text in a
    /// fixed order (any fixed order will do): its date, location, whether it is a screenshot, its
    /// clock, its GPS place's names and zone, what makes it a cover and its preview rank.
    static func duplicateKey(_ fact: AssetFacts) -> [String] {
        let asset = fact.asset, place = fact.gpsPlace
        return [asset.creationDate.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "",
                asset.usableLocation.map { "\($0.latitude) \($0.longitude)" } ?? "",
                asset.isScreenshotLike ? "screenshot" : "", fact.timeZone?.identifier ?? "",
                place?.isoCountryCode ?? "", place?.disputedArea ?? "", place?.country ?? "", place?.administrativeArea ?? "",
                place?.subAdministrativeArea ?? "", place?.locality ?? "", place?.areaOfInterest ?? "", place?.timeZoneIdentifier ?? "",
                "\(asset.kind.rawValue) \(asset.isFavorite) \(asset.pixelWidth) \(asset.pixelHeight)", "\(PreviewRank(fact).rawValue)"]
    }
}
