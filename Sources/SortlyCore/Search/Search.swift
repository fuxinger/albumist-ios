import Foundation

// Search over the analysed library (prompt §14), fully on the device.
//
// A query is read into clauses ("Hund am Strand 2023" → dog AND beach AND 2023). Each clause
// has one or more alternatives (OR): a word can mean a place and a topic at once ("Essen"),
// and values of one kind are alternatives of each other ("Rom Florenz" = Rome or Florence,
// since a photo has only one city). Every clause is shown to the user as a chip, so the
// interpretation can always be checked (prompt §10). Unknown values never match: an undated
// photo never matches a year, a photo without GPS never matches a place.

/// One condition on an asset.
public indirect enum SearchCriterion: Hashable, Sendable {
    case country(String)                     // ISO code
    case countries(Set<String>)              // a continent or region
    case outsideHome                         // "Ausland": not in the country with the most photos
    case place(String)                       // normalized name of a city, region, island, lake …
    case year(Int)
    case month(Int)
    case monthDay(month: Int, day: Int)
    case weekday(Int)                        // Calendar weekday, 1 = Sunday
    case dateRange(DateInterval)
    case holiday(Holiday, years: Set<Int>)   // empty years: every year
    case mediaKind(MediaKind)
    case subtype(MediaSubtypes)
    case favorite
    case category(String)                    // ImageTaxonomy id, at least "plausible"
    case label(String)                       // Vision identifier, confidence ≥ 0.5
    case documentType(DocumentType)
    case anyDocument
    case screenshotCategory(String)
    case merchant(String)                    // normalized
    case orderNumber
    case invoiceNumber
    case messenger(MessengerApp)
    case trip
    case frequentPlace(SortlyID)
    case group(SortlyID)
    case album(CollectionID)
    case hasLocation(Bool)
    case status(Set<OverallStatus>)
    case text(String)                        // folded word in the recognized text
    case any([SearchCriterion])
    case all([SearchCriterion])

    /// Needs the organization status of every photo (computed only then).
    var usesStatus: Bool {
        switch self {
        case .status: true
        case .any(let list), .all(let list): list.contains { $0.usesStatus }
        default: false
        }
    }
}

/// One recognized piece of the query, for display ("Land: Italien", "Jahr: 2026").
public struct SearchToken: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case country, place, year, month, date, mediaType, category, document, merchant, field, group, album, location, status, text, trip, favorite
        /// A word that was not understood and is left out of the search.
        case ignored
    }
    public var kind: Kind
    public var label: String
    /// The concrete period behind a relative date ("letzte Woche" → "2.–8. Nov. 2026").
    public var detail: String?
    /// What the user typed when it was read as something else ("Itallien" → Italien).
    public var typed: String?
    /// The term excludes photos ("ohne Hund").
    public var negated = false
    /// Photos in the library that match this term alone; `nil` before the search ran.
    public var count: Int?

    public init(kind: Kind, label: String, detail: String? = nil, typed: String? = nil, negated: Bool = false, count: Int? = nil) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.typed = typed
        self.negated = negated
        self.count = count
    }
}

/// A term of the query: alternatives that are OR-ed; clauses are AND-ed.
public struct SearchClause: Hashable, Sendable {
    public var alternatives: [SearchCriterion]
    public var token: SearchToken
    /// Clauses of the same dimension are alternatives of each other ("2023 2024").
    var dimension: String?
    /// How much the user's intent depends on this term. When nothing matches all terms, the
    /// least important ones are left out first (a place outweighs a year, a year a topic).
    var importance: Int
    var negated = false
    /// Position in the query, for showing the chips in the order they were typed.
    var position: Int

    var criterion: SearchCriterion { alternatives.count == 1 ? alternatives[0] : .any(alternatives) }
}

/// A parsed query.
public struct SearchQuery: Hashable, Sendable {
    public var clauses: [SearchClause] = []
    /// Words that were not understood; shown, never silently dropped.
    public var ignored: [String] = []

    public var isEmpty: Bool { clauses.isEmpty }
    public var usesStatus: Bool { clauses.contains { $0.criterion.usesStatus } }

    /// Chips in query order; words that were not understood come last.
    public var tokens: [SearchToken] {
        clauses.sorted { $0.position < $1.position }.map(\.token) + ignored.map { SearchToken(kind: .ignored, label: $0) }
    }
}

/// What the search found.
public struct SearchResult: Hashable, Sendable {
    /// Every hit, newest first. "Als Album anlegen" and the count use all of them.
    public var ids: [AssetID] = []
    /// The best few hits when the result is large and the match quality differs (a dog the
    /// classifier is sure about, a favourite), shown above the full grid.
    public var top: [AssetID] = []
    /// Understood terms with their photo counts, then words that were not understood.
    public var tokens: [SearchToken] = []
    /// Terms left out because no photo matched all terms together.
    public var dropped: [SearchToken] = []
    /// Words still being typed that a completion beside the result continues ("Ital" →
    /// Italien): not in `tokens`, never reported as not recognised (`beside(_:for:)`).
    public var typing: [String] = []

    public var isRelaxed: Bool { !dropped.isEmpty }
    public init() {}
}

/// An autocomplete entry built from the user's own library.
public struct SearchSuggestion: Hashable, Sendable, Identifiable {
    /// The whole search text after choosing this suggestion.
    public var completion: String
    public var label: String
    public var kind: SearchToken.Kind
    public var count: Int
    public var id: String { completion }
}

/// What the search page says when a search finds no photos (`SearchResult.emptyState`).
public enum SearchEmptyState: Hashable, Sendable {
    /// No word of the query was understood: "Suchbegriff nicht erkannt".
    case notRecognized
    /// A term without a single photo in the library: "Keine Fotos", with its name.
    case noPhotos(SearchToken)
    /// Every term finds photos, only not together.
    case noMatch
}

extension SearchResult {
    /// The result as the page shows it beside the completions for the same text
    /// (`SearchIndex.suggestions(for:)`). The words a completion would replace are still being
    /// typed: "Ital" is on its way to Italien, which the completion above already shows with its
    /// photos. Such a word is neither a chip "nicht erkannt" nor a reason for "Suchbegriff nicht
    /// erkannt": one answer for one word (review P3-13 / G3-06). A word nothing continues, or
    /// one typed to its end (a space closes the completions), is reported as before.
    public func beside(_ completions: [SearchSuggestion], for text: String) -> SearchResult {
        var shown = self
        for completion in completions {
            // A completion is the text before the words it replaces, then its label.
            let kept = completion.completion.dropLast(completion.label.count)
            guard text.hasPrefix(kept) else { continue }
            for word in QueryParser.tokenize(String(text.dropFirst(kept.count))) where !shown.typing.contains(word.typed) {
                shown.typing.append(word.typed)
                // The words being typed end the query, so the last such chip is theirs.
                if let chip = shown.tokens.lastIndex(where: { $0.kind == .ignored && $0.label == word.typed }) {
                    shown.tokens.remove(at: chip)
                }
            }
        }
        return shown
    }

    /// What the page says when the search found nothing; nil when it found photos, and while
    /// the only words not understood are still being typed: the completions above them are the
    /// answer then (`beside(_:for:)`).
    public var emptyState: SearchEmptyState? {
        guard ids.isEmpty else { return nil }
        let understood = tokens.filter { $0.kind != .ignored }
        if understood.isEmpty { return tokens.isEmpty && !typing.isEmpty ? nil : .notRecognized }
        if let missing = understood.first(where: { $0.count == 0 }) { return .noPhotos(missing) }
        return .noMatch
    }
}

/// Evaluates parsed queries against a `SearchIndex`.
public struct SearchEngine: Sendable {
    public init() {}

    /// Number of hits above which the best ones are shown separately.
    static let topThreshold = 12
    static let topCount = 6

    public func run(_ query: SearchQuery, in index: SearchIndex, statuses: [AssetID: OverallStatus] = [:]) -> SearchResult {
        var result = SearchResult()
        guard !query.isEmpty else {
            result.tokens = query.tokens
            return result
        }
        let evaluator = SearchIndex.Evaluator(index: index, statuses: statuses)
        let ordered = query.clauses.sorted { $0.position < $1.position }
        // Each clause once: (all hits, hits the analysis is sure about).
        let sets = ordered.map { clause -> (all: Bitset, strong: Bitset) in
            var value = evaluator.clause(clause)
            if clause.negated { value = (value.all.inverted(), value.all.inverted()) }
            return value
        }
        var tokens = zip(ordered, sets).map { clause, set -> SearchToken in
            var token = clause.token
            token.negated = clause.negated
            token.count = set.all.cardinality
            return token
        }

        var chosen = Array(ordered.indices)
        var hits = Self.intersection(sets.map(\.all), of: chosen, count: index.count)
        if hits.isEmpty, ordered.count > 1 {
            // Nothing matches all terms: keep the most important terms that still find
            // photos and say which ones were left out (never an unexplained empty page).
            if let best = Self.bestSubset(ordered, sets: sets.map(\.all), count: index.count) {
                chosen = best
                hits = Self.intersection(sets.map(\.all), of: chosen, count: index.count)
                result.dropped = ordered.indices.filter { !chosen.contains($0) }.map { tokens[$0] }
            }
        }
        result.ids = hits.positions.map { index.ids[$0] }

        // Top hits: score by how sure each chosen term is, plus favourites; newest first on ties.
        // Only when the analysis is surer about some hits than others (topics, text): for a
        // place or a date every hit fits equally well and the grid by date says it best.
        let graded = chosen.contains { !ordered[$0].negated && sets[$0].strong != sets[$0].all }
        if result.ids.count > Self.topThreshold, graded {
            let positions = hits.positions
            var scores = [Int](repeating: 0, count: positions.count)
            for c in chosen where !ordered[c].negated {
                let strong = sets[c].strong
                for (i, p) in positions.enumerated() where strong.contains(p) { scores[i] += 2 }
            }
            for (i, p) in positions.enumerated() where index.favorites.contains(p) { scores[i] += 1 }
            let best = scores.max() ?? 0, worst = scores.min() ?? 0
            if best > worst {
                let ranked = positions.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : positions[$0] < positions[$1] }
                result.top = ranked.prefix(Self.topCount).map { index.ids[positions[$0]] }
            }
        }
        tokens.append(contentsOf: query.ignored.map { SearchToken(kind: .ignored, label: $0) })
        result.tokens = tokens
        return result
    }

    static func intersection(_ sets: [Bitset], of chosen: [Int], count: Int) -> Bitset {
        var hits = Bitset(count: count, filled: true)
        for c in chosen { hits.formIntersection(sets[c]) }
        return hits
    }

    /// The largest set of terms that still finds photos, preferring important terms.
    static func bestSubset(_ clauses: [SearchClause], sets: [Bitset], count: Int) -> [Int]? {
        let n = clauses.count
        // Beyond 8 terms the search over subsets would grow too large; drop one at a time.
        guard n <= 8 else {
            var kept = Array(0..<n)
            while kept.count > 1 {
                let weakest = kept.min { clauses[$0].importance < clauses[$1].importance }!
                kept.removeAll { $0 == weakest }
                if !intersection(sets, of: kept, count: count).isEmpty { return kept }
            }
            return nil
        }
        for size in stride(from: n - 1, through: 1, by: -1) {
            var best: (subset: [Int], weight: Int, hits: Int)?
            for mask in 1..<(1 << n) where mask.nonzeroBitCount == size {
                let subset = (0..<n).filter { mask & (1 << $0) != 0 }
                let hits = intersection(sets, of: subset, count: count).cardinality
                guard hits > 0 else { continue }
                let weight = subset.reduce(0) { $0 + clauses[$1].importance }
                if best == nil || weight > best!.weight || (weight == best!.weight && hits > best!.hits) {
                    best = (subset, weight, hits)
                }
            }
            if let best { return best.subset }
        }
        return nil
    }
}
