import Foundation
import AlbumistCore

// Counting the photos of `TripGeometryBuilder` cheaply, as one trip may hold tens of thousands:
// the numbers of their zones, how often each name comes and the best covers of a place.

extension TripGeometryBuilder {
    // MARK: Counting many photos

    /// Numbers the distinct zone identifiers of many photos, which mostly come in runs (the
    /// photos of one place): one dictionary lookup per run, not per photo.
    struct ZoneNumbers {
        private(set) var identifiers: [String] = []
        private var numbers: [String: Int] = [:]
        private var last = (identifier: "", number: -1)

        mutating func number(_ identifier: String) -> Int {
            if identifier == last.identifier { return last.number }
            let number = numbers[identifier] ?? identifiers.count
            if number == identifiers.count {
                identifiers.append(identifier)
                numbers[identifier] = number
            }
            last = (identifier, number)
            return number
        }
    }

    /// Counts the names of many photos (a town, a country), which mostly come in runs: the
    /// photos of a place in time order mostly name one town, so a run costs one dictionary
    /// update, not one per photo. An empty name is none.
    struct NameCounter {
        private var settled: [String: Int] = [:]
        private var name = ""
        private var run = 0

        mutating func add(_ name: String) {
            if name == self.name {
                run += 1
                return
            }
            if run > 0 && !self.name.isEmpty { settled[self.name, default: 0] += run }
            self.name = name
            run = 1
        }

        /// Each name with how often it came.
        var counts: [String: Int] {
            var counts = settled
            if run > 0 && !name.isEmpty { counts[name, default: 0] += run }
            return counts
        }

        /// The most common name and how often it came, ties to the alphabetically first (so the
        /// dictionary's order never decides); nil without any.
        var top: (name: String, count: Int)? {
            counts.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { ($0.key, $0.value) }
        }
    }

    /// The best `limit` covers of many (`Cover.ranks(before:)`) in one pass, an id that comes
    /// twice taken once at its better rank: what sorting them all and taking the first `limit`
    /// ids gives, at a comparison or two per photo.
    struct CoverPicker {
        let limit: Int
        /// The best so far, best first.
        private(set) var kept: [Cover] = []

        init(limit: Int) {
            self.limit = limit
        }

        mutating func add(_ cover: Cover) {
            guard limit > 0 else { return }
            // Not before the last of a full list: it never gets in.
            if kept.count == limit, let last = kept.last, !cover.ranks(before: last) { return }
            if let same = kept.firstIndex(where: { $0.id == cover.id }) {
                guard cover.ranks(before: kept[same]) else { return }
                kept.remove(at: same)
            } else if kept.count == limit {
                kept.removeLast()
            }
            kept.insert(cover, at: kept.firstIndex { cover.ranks(before: $0) } ?? kept.count)
        }

        var ids: [AssetID] { kept.map { $0.id } }
    }
}
