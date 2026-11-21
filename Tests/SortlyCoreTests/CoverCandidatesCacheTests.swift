import Foundation
import Testing
@testable import SortlyCore

/// The cover candidates of the suggestions' cards are kept per suggestion (review A of design
/// wave 1, finding 1: the start page worked them out for every card in each pass of its body, the
/// list too): worked out once while nothing they are made from changes, again when the
/// suggestion's photos, the photos taken out of it, its cover, the favourites asked for or the
/// photos' facts change, and after a memory warning.
@Suite("Cover candidates cache")
@MainActor
struct CoverCandidatesCacheTests {
    static let kyoto = SortlyID("trip.kyoto")
    static let rome = SortlyID("trip.rome")
    static let photos = Set((0..<6).map { AssetID("kyoto.\($0)") })
    static let dates = Dictionary(uniqueKeysWithValues: photos.sorted().enumerated().map {
        ($0.element, Date(timeIntervalSinceReferenceDate: Double($0.offset) * 3_600))
    })
    static let ranks: [AssetID: PreviewRank] = [AssetID("kyoto.5"): .sensitive]

    /// Asks `cache` for Kyoto's candidates and counts how often they are worked out.
    @MainActor
    final class Asker {
        let cache: CoverCandidatesCache
        var made = 0

        init(_ cache: CoverCandidatesCache) { self.cache = cache }

        func ask(_ source: CoverCandidatesCache.Source, of id: SortlyID = kyoto,
                 dates: [AssetID: Date] = CoverCandidatesCacheTests.dates,
                 ranks: [AssetID: PreviewRank] = CoverCandidatesCacheTests.ranks) -> [AssetID] {
            cache.candidates(of: id, from: source, dates: dates, ranks: ranks) {
                made += 1
                return PreviewPicker.coverCandidates(source.photos.subtracting(source.removed), cover: source.cover,
                                                     dates: dates, ranks: ranks, favorites: source.favorites)
            }
        }
    }

    static var source: CoverCandidatesCache.Source { .init(photos: photos) }

    @Test func workedOutOncePerSuggestionWhileNothingChanges() {
        let asker = Asker(CoverCandidatesCache(pressure: MemoryPressure()))
        let first = asker.ask(Self.source)
        #expect(first == ["kyoto.4", "kyoto.3", "kyoto.2", "kyoto.1"], "newest first, never the sensitive one")
        for _ in 0..<5 { #expect(asker.ask(Self.source) == first) }
        #expect(asker.made == 1)
        // Another suggestion has its own.
        _ = asker.ask(Self.source, of: Self.rome)
        _ = asker.ask(Self.source, of: Self.rome)
        #expect(asker.made == 2)
        _ = asker.ask(Self.source)
        #expect(asker.made == 2, "Kyoto's is still kept")
    }

    @Test func workedOutAgainWhenWhatItIsMadeFromChanges() {
        let asker = Asker(CoverCandidatesCache(pressure: MemoryPressure()))
        _ = asker.ask(Self.source)
        var fewer = Self.source
        fewer.photos.remove(AssetID("kyoto.4"))
        #expect(asker.ask(fewer).first == AssetID("kyoto.3"), "a photo left the suggestion")
        var removed = fewer
        removed.removed = [AssetID("kyoto.3")]
        #expect(asker.ask(removed).first == AssetID("kyoto.2"), "the user took a photo out")
        var covered = removed
        covered.cover = AssetID("kyoto.0")
        #expect(asker.ask(covered).first == AssetID("kyoto.0"), "its own cover leads")
        var favorite = covered
        favorite.favorites = [AssetID("kyoto.1")]
        #expect(asker.ask(favorite) == ["kyoto.0", "kyoto.1", "kyoto.2"])
        #expect(asker.made == 5)
        // The same photos in another copy: kept.
        var copy = favorite
        copy.photos = Set(Array(favorite.photos))
        _ = asker.ask(copy)
        #expect(asker.made == 5)
    }

    @Test func workedOutAgainWhenThePhotosFactsChange() {
        let asker = Asker(CoverCandidatesCache(pressure: MemoryPressure()))
        _ = asker.ask(Self.source)
        _ = asker.ask(Self.source, of: Self.rome)
        // The same facts in another copy (a refresh that read the same): kept.
        _ = asker.ask(Self.source, dates: Dictionary(uniqueKeysWithValues: Array(Self.dates)))
        #expect(asker.made == 2)
        var later = Self.dates
        later[AssetID("kyoto.0")] = Date(timeIntervalSinceReferenceDate: 100_000)
        #expect(asker.ask(Self.source, dates: later).first == AssetID("kyoto.0"), "new dates")
        #expect(asker.made == 3)
        _ = asker.ask(Self.source, of: Self.rome, dates: later)
        #expect(asker.made == 4, "every suggestion's are made again")
        var ranks = Self.ranks
        ranks[AssetID("kyoto.0")] = .document
        #expect(asker.ask(Self.source, dates: later, ranks: ranks).first == AssetID("kyoto.4"), "new ranks")
        #expect(asker.made == 5)
    }

    @Test func aMemoryWarningEmptiesIt() {
        let pressure = MemoryPressure()
        let asker = Asker(CoverCandidatesCache(pressure: pressure))
        _ = asker.ask(Self.source)
        #expect(pressure.warning() == ["cover candidates"])
        _ = asker.ask(Self.source)
        #expect(asker.made == 2)
        _ = asker.ask(Self.source)
        #expect(asker.made == 2)
    }

    /// A suggestion without photos to show (all taken out, all sensitive) keeps its empty list
    /// too: its card shows its calm placeholder without asking again.
    @Test func anEmptyListIsKeptToo() {
        let asker = Asker(CoverCandidatesCache(pressure: MemoryPressure()))
        let none = CoverCandidatesCache.Source(photos: [AssetID("kyoto.5")])
        #expect(asker.ask(none).isEmpty)
        #expect(asker.ask(none).isEmpty)
        #expect(asker.made == 1)
    }
}
