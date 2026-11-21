import Foundation

/// A place the user gave a name, for the search: it finds the place's photos by that name
/// before the place's album exists, and once an album is made with the name, place and album
/// are one term (review G1-05). The name stays on the iPhone: only the search index in memory
/// reads it, and Apple's geocoder only ever gets coordinates.
public struct NamedPlace: Hashable, Sendable {
    /// The ID of the place's suggestion; for a frequent place also its `FrequentPlace.id`, which
    /// its photos carry as `AssetFacts.frequentPlaceID`.
    public var id: AlbumistID
    public var name: String
    /// The photos of the place's suggestion. The search takes them when no photo carries the ID:
    /// a place the user said they are often at ("Bist du hier öfter?") is known by these alone,
    /// a frequent place by its photos, also while it has no suggestion.
    public var assetIDs: Set<AssetID>

    public init(id: AlbumistID, name: String, assetIDs: Set<AssetID> = []) {
        self.id = id
        self.name = name
        self.assetIDs = assetIDs
    }

    /// The places the user named, from both places Albumist keeps such a name: the title typed in
    /// a suggestion (`titles`, by suggestion ID: the app's `user.titles`, which the suggestion
    /// shows) and a name in the settings (`FrequentPlaceSettings.names`). The typed title wins; a
    /// blank one is no name. Places only: the suggestions of frequent places and of places the
    /// user is often at, and named frequent places without a suggestion right now (a trial year
    /// makes none, more than five unnamed places are not offered), which the search finds by their
    /// photos. Sorted by ID: other names, another result.
    public static func resolve(titles: [AlbumistID: String], settings: FrequentPlaceSettings = FrequentPlaceSettings(),
                               suggestions: [AlbumProposal]) -> [NamedPlace] {
        func given(_ id: AlbumistID) -> String? {
            for text in [titles[id], settings.names[id]] {
                if let name = text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
            }
            return nil
        }
        var places: [AlbumistID: NamedPlace] = [:]
        var others = Set<AlbumistID>()
        for suggestion in suggestions {
            guard suggestion.kind == .frequentPlace else {
                others.insert(suggestion.id)
                continue
            }
            guard let name = given(suggestion.id) else { continue }
            if var place = places[suggestion.id] {
                // Two suggestions with one ID are one place.
                place.assetIDs.formUnion(suggestion.assetIDs)
                places[suggestion.id] = place
            } else {
                places[suggestion.id] = NamedPlace(id: suggestion.id, name: name, assetIDs: suggestion.assetIDs)
            }
        }
        for id in Set(titles.keys).union(settings.names.keys) where places[id] == nil && !others.contains(id) {
            if let name = given(id) { places[id] = NamedPlace(id: id, name: name) }
        }
        return places.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}
