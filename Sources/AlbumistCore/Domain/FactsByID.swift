import Foundation

/// The facts by photo id, for the photo view and the search hits (`AppModel.factsByID`): each
/// id's place in the facts, made off the main thread with them (`DerivedLibrary`). Review P4-09:
/// a dictionary of all facts was made on the main thread at the first lookup after every refresh
/// (97 ms at 50,000 photos, 267 ms at 100,000). Review P4-06: that dictionary was a second copy
/// of every fact (600 bytes each); this holds the facts themselves (the same storage as the
/// model's) and an index per photo. The first photo with an id wins, as in the dictionary.
public struct FactsByID: Sendable {
    public let facts: [AssetFacts]
    private let positions: [AssetID: Int]

    public init() {
        facts = []
        positions = [:]
    }

    public init(_ facts: [AssetFacts]) {
        var positions: [AssetID: Int] = [:]
        positions.reserveCapacity(facts.count)
        for (index, f) in facts.enumerated() where positions[f.id] == nil {
            positions[f.id] = index
        }
        self.facts = facts
        self.positions = positions
    }

    public subscript(id: AssetID) -> AssetFacts? {
        positions[id].map { facts[$0] }
    }

    /// Photos with facts (each id once).
    public var count: Int { positions.count }
}
