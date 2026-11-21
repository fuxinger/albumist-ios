import Foundation

/// A starting point of the empty search with its picture (design wave 3, DS-13): a chip the
/// search knows today, now with a photo of the user's own, as Photos offers its suggestions.
public struct SearchStartingPoint: Hashable, Sendable, Identifiable {
    /// The chip it stands for: a tap searches `suggestion.completion`, as the chip did; its
    /// `count` is what that search finds.
    public var suggestion: SearchSuggestion
    /// The photos its picture tries, best first (`CoverPhoto` shows the first one that is sharp
    /// on the device): ordinary photos only, never a sensitive one, a screenshot or a paper, and
    /// none another starting point tries. Empty only for a kind of nothing but screenshots and
    /// papers ("Screenshots"): its tile shows the calm placeholder with its symbol, as an album
    /// of them shows in the tab "Alben".
    public var coverIDs: [AssetID]

    public var id: String { suggestion.id }
}

/// What the search page offers before anything is typed: the user's places, a trip, the
/// newest year, a topic and a kind such as screenshots, each with a photo of its own.
///
/// - Only what the search already knows: every starting point is a chip of today's search
///   (`SearchIndex.suggestionPool`, the words `featuredSuggestions` and the completions offer),
///   searched with its own words, so a tap finds exactly what the chip finds. No new kind of
///   query, no new index.
/// - Places as Photos names a photo's place (`PhotoTitle.placeName`): the towns with the most
///   photos, never the region or district that holds them all ("Bayern", "Oberbayern").
/// - A trip: the trips Albumist found ("Reisen"); one trip alone has no words of its own.
/// - Kinds: Live Photos and HDR say how the camera took a photo and are most photos of a
///   current iPhone, so they narrow nothing. Papers ("Rechnungen") are no starting point with a
///   picture: their pictures are personal papers (the page keeps them as a word).
/// - The picture, as a big cover takes it (`PreviewPicker.coverCandidates`): ordinary photos,
///   the user's favourites first, then the newest, the one the analysis is surest about before
///   them (a topic); photos not analysed yet after the analysed ones. Never a sensitive one, a
///   screenshot or a paper (a chat or an order is as personal at tile size as the papers the
///   page keeps as words, review G5): a kind of nothing else ("Screenshots") keeps its tile on
///   the calm placeholder with its symbol, as an album of them shows in the tab "Alben".
/// - Each starting point shows a photo of its own: no tile tries a photo another one tries
///   (`CoverPhoto` falls back to a later candidate when the first is not sharp on the device,
///   review G1). One without a photo of its own is left out, so a small library offers fewer,
///   never an empty box or a photo twice.
public enum SearchStartingPoints {
    /// Starting points the page offers at most: one of each kind it takes first (two places, a
    /// trip, the newest year, a topic, a kind), three rows of two tiles on an iPhone.
    public static let limit = 6

    /// The media types that are no starting point (see above).
    static let notAKind: Set<String> = {
        let technical: [SearchCriterion] = [.subtype(.livePhoto), .subtype(.hdr)]
        return Set(SearchLexicon.shared.entries.filter { technical.contains($0.criterion) }.map(\.german))
    }()

    /// Where each kind of starting point stands on the page.
    static let order: [SearchToken.Kind] = [.place, .trip, .year, .category, .mediaType]

    /// - Parameters:
    ///   - facts: the facts the index was made from (for the towns).
    ///   - ranks: `PreviewRank.ranks(of:)` of the facts.
    ///   - dates: the photos' capture dates.
    ///   - english: the app's language: the words of the chips in it (the search understands both).
    public static func make(index: SearchIndex, facts: [AssetFacts], ranks: [AssetID: PreviewRank], dates: [AssetID: Date],
                            english: Bool, now: Date = Date(), limit: Int = limit) -> [SearchStartingPoint] {
        guard index.count > 0, limit > 0 else { return [] }
        var chosen: [SearchStartingPoint] = []
        var shown = Set<AssetID>()
        let favorites = Set(facts.lazy.filter(\.asset.isFavorite).map(\.id))
        // Each candidate costs a search: a few more than there is room for, never all of them.
        for candidate in candidates(index: index, facts: facts).prefix(limit * 3) where chosen.count < limit {
            let words = english ? candidate.english : candidate.german
            let found = index.search(words, now: now)
            guard !found.ids.isEmpty, !found.isRelaxed, !found.tokens.contains(where: { $0.kind == .ignored }) else { continue }
            let pictures = pictures(of: found, besides: shown, ranks: ranks, dates: dates, favorites: favorites)
            if pictures.isEmpty {
                // No photo of its own: left out, unless it is a kind of nothing but screenshots
                // and papers, which shows its symbol (see above).
                guard candidate.kind == .mediaType, !found.ids.contains(where: { Self.isPhoto($0, ranks: ranks) }) else { continue }
            }
            // Every photo it tries is its own (review G1): `CoverPhoto` may show any of them.
            shown.formUnion(pictures)
            chosen.append(SearchStartingPoint(
                suggestion: SearchSuggestion(completion: words, label: words, kind: candidate.kind, count: found.ids.count),
                coverIDs: pictures))
        }
        // Places first, then the trip, the year, topics and kinds; in the order chosen within each.
        func rank(_ point: SearchStartingPoint) -> Int { order.firstIndex(of: point.suggestion.kind) ?? order.count }
        return chosen.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// The chips that may start a search, best first: two places, the trip, the newest year, a
    /// topic and a kind; then more topics, kinds and places for those left out.
    static func candidates(index: SearchIndex, facts: [AssetFacts]) -> [SearchIndex.SuggestionCandidate] {
        let pool = index.suggestionPool.filter(\.startingPoint)
        var towns: [String: Int] = [:]
        for f in facts {
            if let name = PhotoTitle.placeName(f.gpsPlace) { towns[SearchText.key(name), default: 0] += 1 }
        }
        func photos(in town: SearchIndex.SuggestionCandidate) -> Int { town.keys.count == 1 ? towns[town.keys[0]] ?? 0 : 0 }
        let places = pool.filter { $0.kind == .place && photos(in: $0) > 0 }
            .sorted { photos(in: $0) != photos(in: $1) ? photos(in: $0) > photos(in: $1) : $0.german < $1.german }
        let trips = pool.filter { $0.kind == .trip }
        let newestYear = pool.filter { $0.kind == .year }.max { (Int($0.german) ?? 0) < (Int($1.german) ?? 0) }
        // The pool lists the most photos first.
        let topics = pool.filter { $0.kind == .category }
        let kinds = pool.filter { $0.kind == .mediaType && !notAKind.contains($0.german) }

        let first = [places.first, places.dropFirst().first, trips.first, newestYear, topics.first, kinds.first]
        let then = [topics.dropFirst().first, kinds.dropFirst().first]
        return first.compactMap { $0 } + then.compactMap { $0 } + places.dropFirst(2) + topics.dropFirst(2) + kinds.dropFirst(2)
    }

    /// The photos a starting point's picture tries, best first, none that one before it tries
    /// (`shown`): its ordinary photos (`PreviewPicker.coverCandidates`), nothing when it has
    /// none or those before it try them all.
    static func pictures(of found: SearchResult, besides shown: Set<AssetID>, ranks: [AssetID: PreviewRank],
                         dates: [AssetID: Date], favorites: Set<AssetID>) -> [AssetID] {
        let free = shown.isEmpty ? found.ids : found.ids.filter { !shown.contains($0) }
        // The best hit the analysis is surest about (a topic, `SearchResult.top`), when it is an
        // analysed ordinary photo.
        let surest = found.top.first { ranks[$0] == nil && !shown.contains($0) }
        return PreviewPicker.coverCandidates(free, cover: surest, dates: dates, ranks: ranks, favorites: favorites, count: 4)
    }

    /// An ordinary photo, or one not analysed yet: what a picture may be (`PreviewRank`).
    static func isPhoto(_ id: AssetID, ranks: [AssetID: PreviewRank]) -> Bool {
        (ranks[id] ?? .photo) <= .unknown
    }
}
