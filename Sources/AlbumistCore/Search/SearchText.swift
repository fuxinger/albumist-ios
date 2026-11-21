import Foundation

/// Text normalization shared by the query parser and the search index, so that a word typed
/// in any spelling meets the same key as the stored name: case, accents and width are
/// folded, "ß" becomes "ss" ("Straße" = "Strasse"), and multi-word names are joined with
/// "-" exactly like `PlaceKey.normalize`.
enum SearchText {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// One word, folded: "München" → "munchen", "Größe" → "grosse".
    static func fold(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posix)
            .replacingOccurrences(of: "ß", with: "ss")
    }

    /// Folded words of a text, split at everything that is not a letter or digit.
    static func words(_ text: String) -> [String] {
        fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Key of a name or phrase: folded words joined by "-" ("New York" → "new-york").
    static func key(_ text: String) -> String {
        words(text).joined(separator: "-")
    }

    /// German umlauts typed without the dots: "Muenchen", "Koeln", "Zuerich". Folding turns
    /// "München" into "munchen", so "ue" → "u" meets it. Only used as a second try after an
    /// exact lookup failed, because real words contain these pairs too ("Israel", "Feuer").
    static func transliterated(_ key: String) -> String? {
        guard key.contains("ae") || key.contains("oe") || key.contains("ue") else { return nil }
        return key.replacingOccurrences(of: "ae", with: "a")
            .replacingOccurrences(of: "oe", with: "o")
            .replacingOccurrences(of: "ue", with: "u")
    }

    /// Singular candidates for a plural the lexicon does not list: "Rosen" → "rose",
    /// "Palmen" → "palme", "trees" → "tree", "boxes" → "box", "puppies" → "puppy".
    /// Stems stay at four letters or more, so short words never collapse into others
    /// ("Bären" must not become "Bar").
    static func singulars(_ word: String) -> [String] {
        var result: [String] = []
        if word.hasSuffix("ies"), word.count >= 6 { result.append(String(word.dropLast(3)) + "y") }
        for suffix in ["es", "en", "s", "n", "e", "er"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 {
            result.append(String(word.dropLast(suffix.count)))
        }
        return result
    }

    /// How many typing errors a word of this length may contain and still be recognized:
    /// none up to four letters ("Rom" must not become "Rot"), one up to seven, two above.
    static func allowedTypos(_ word: String) -> Int {
        switch word.count {
        case ..<5: 0
        case ..<8: 1
        default: 2
        }
    }

    /// Damerau–Levenshtein distance (optimal string alignment) with an early exit once the
    /// distance exceeds `limit`. A swapped pair of letters ("Sonnenuntergnag") counts once.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        if abs(s.count - t.count) > limit { return limit + 1 }
        if s.isEmpty || t.isEmpty { return max(s.count, t.count) }
        var previous2 = [Int](repeating: 0, count: t.count + 1)
        var previous = Array(0...t.count)
        var current = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[t.count]
    }

    /// A typo match: within the allowed distance and with the same first letter. Typing
    /// errors in the first letter are rare, and requiring it keeps "Rose" from meeting
    /// "Hose" and makes the scan over the vocabulary cheap.
    static func isTypo(_ typed: String, of candidate: String) -> Int? {
        let limit = allowedTypos(typed)
        guard limit > 0, candidate.count >= 4, typed.first == candidate.first, typed != candidate else { return nil }
        let d = distance(typed, candidate, limit: limit)
        return d <= limit ? d : nil
    }
}

/// A fixed-size set of asset positions in the search index. All criteria of a query are
/// evaluated into bitsets, so AND, OR, NOT and the "nothing matched all terms" fallback are
/// word-wide operations instead of passes over the facts.
struct Bitset: Hashable, Sendable {
    private(set) var words: [UInt64]
    let count: Int

    init(count: Int, filled: Bool = false) {
        self.count = count
        words = [UInt64](repeating: filled ? ~0 : 0, count: (count + 63) / 64)
        if filled { clearTail() }
    }

    init<S: Sequence>(count: Int, positions: S) where S.Element == Int32 {
        self.init(count: count)
        for p in positions { insert(Int(p)) }
    }

    private mutating func clearTail() {
        let extra = words.count * 64 - count
        if extra > 0, !words.isEmpty { words[words.count - 1] &= ~UInt64(0) >> UInt64(extra) }
    }

    mutating func insert(_ position: Int) {
        words[position >> 6] |= 1 << UInt64(position & 63)
    }

    func contains(_ position: Int) -> Bool {
        words[position >> 6] & (1 << UInt64(position & 63)) != 0
    }

    /// Sets every position in `range` (used for date ranges: the index is sorted by date).
    mutating func insert(range: Range<Int>) {
        for p in range { insert(p) }
    }

    mutating func formUnion(_ other: Bitset) {
        for i in words.indices { words[i] |= other.words[i] }
    }

    mutating func formIntersection(_ other: Bitset) {
        for i in words.indices { words[i] &= other.words[i] }
    }

    mutating func subtract(_ other: Bitset) {
        for i in words.indices { words[i] &= ~other.words[i] }
    }

    func inverted() -> Bitset {
        var copy = self
        for i in copy.words.indices { copy.words[i] = ~copy.words[i] }
        copy.clearTail()
        return copy
    }

    var isEmpty: Bool { words.allSatisfy { $0 == 0 } }
    var cardinality: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Set positions in ascending order.
    var positions: [Int] {
        var result: [Int] = []
        result.reserveCapacity(cardinality)
        for (w, word) in words.enumerated() where word != 0 {
            var bits = word
            while bits != 0 {
                let bit = bits.trailingZeroBitCount
                result.append(w << 6 | bit)
                bits &= bits - 1
            }
        }
        return result
    }
}
