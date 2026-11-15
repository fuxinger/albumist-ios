import Foundation

/// Names from the user's own library the parser recognizes: places, countries, merchants,
/// albums, named people and pets, named frequent places and every Vision label that occurs.
public struct SearchVocabulary: Sendable {
    struct Name: Sendable {
        var criterion: SearchCriterion
        var kind: SearchToken.Kind
        var german: String
        var english: String
        var dimension: String?
        var importance: Int
        var alsoText = false
    }

    /// Folded key ("new-york") → what it can mean.
    var names: [String: [Name]] = [:]
    /// Vision identifiers that occur in the library, by key ("palm-tree" → "palm_tree"), so
    /// any label the classifier knows can be searched in English.
    var labels: [String: String] = [:]
    var maxWords = 1

    mutating func add(_ key: String, _ name: Name) {
        guard !key.isEmpty else { return }
        names[key, default: []].append(name)
        maxWords = max(maxWords, key.split(separator: "-").count)
    }
}

/// Everything the search needs, prepared once per library state: photos in date order
/// (newest first), calendar fields, posting lists per place, label, document type and so on,
/// and a term index over the recognized text. A search then only combines bitsets, which
/// keeps it far below 100 ms for 50,000 photos.
public struct SearchIndex: Sendable {
    public let calendar: Calendar
    public let count: Int
    let ids: [AssetID]
    /// Seconds since the reference date, descending; undated photos come last.
    let dates: [Double]
    let datedCount: Int
    let years: [Int16]
    let months: [UInt8]
    let days: [UInt8]
    let weekdays: [UInt8]
    let yearRange: ClosedRange<Int>?
    let favorites: Bitset
    let located: Bitset
    let postings: [Key: [Int32]]
    /// Categories at "likely" or better, for ranking.
    let strongCategories: [String: [Int32]]
    /// Sorted folded words of the recognized text and the photos they occur in.
    let terms: [String]
    let termPostings: [[Int32]]
    /// The country with the most photos ("Ausland" means anywhere else).
    let homeCountry: String?
    let vocabulary: SearchVocabulary
    /// Autocomplete candidates with their photo counts.
    private(set) var suggestionPool: [SuggestionCandidate] = []

    enum Key: Hashable, Sendable {
        case country(String), place(String), category(String), label(String), document(DocumentType), anyDocument, screenshot(String)
        case merchant(String), orderNumber, invoiceNumber, messenger(MessengerApp), trip, frequent(SortlyID), group(SortlyID)
        case album(CollectionID), kind(MediaKind), subtype(UInt32)
    }

    struct SuggestionCandidate: Sendable {
        var keys: [String]          // folded forms the typed prefix is compared with
        var englishKeys: Set<String>
        var german: String
        var english: String
        var kind: SearchToken.Kind
        var count: Int
    }

    public init(facts: [AssetFacts], inventory: CollectionInventory = CollectionInventory(), groups: [ObservationGroup] = [],
                frequentPlaces: [FrequentPlace] = [], calendar: Calendar = .sortlyDefault) {
        self.calendar = calendar
        // Newest first, like the photo grid; equal dates by id so the order is stable.
        let sorted = facts.sorted {
            let a = $0.asset.creationDate ?? .distantPast, b = $1.asset.creationDate ?? .distantPast
            return a != b ? a > b : $0.id > $1.id
        }
        count = sorted.count
        ids = sorted.map(\.id)

        // Calendar fields once per day instead of once per photo: Calendar is slow and
        // photos come in bursts.
        var dates = [Double](repeating: .nan, count: sorted.count)
        var years = [Int16](repeating: 0, count: sorted.count), months = [UInt8](repeating: 0, count: sorted.count)
        var days = [UInt8](repeating: 0, count: sorted.count), weekdays = [UInt8](repeating: 0, count: sorted.count)
        var currentDay: DateInterval?
        var fields: (Int16, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        var datedCount = 0
        for (i, f) in sorted.enumerated() {
            guard let date = f.asset.creationDate else { continue }
            datedCount = i + 1
            dates[i] = date.timeIntervalSinceReferenceDate
            if currentDay?.contains(date) != true || currentDay?.end == date {
                currentDay = calendar.dateInterval(of: .day, for: date)
                let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
                fields = (Int16(c.year ?? 0), UInt8(c.month ?? 0), UInt8(c.day ?? 0), UInt8(c.weekday ?? 0))
            }
            (years[i], months[i], days[i], weekdays[i]) = fields
        }
        self.dates = dates
        self.datedCount = datedCount
        self.years = years
        self.months = months
        self.days = days
        self.weekdays = weekdays
        let presentYears = years.filter { $0 > 0 }
        yearRange = presentYears.min().map { Int($0)...Int(presentYears.max()!) }

        var postings: [Key: [Int32]] = [:]
        var strong: [String: [Int32]] = [:]
        var favorites = Bitset(count: sorted.count), located = Bitset(count: sorted.count)
        var vocabulary = SearchVocabulary()
        var placeNames: [String: String] = [:]              // key → display name as stored
        var countryNames: [String: [String: Int]] = [:]     // code → display name → photos
        var merchantNames: [String: String] = [:]
        var termSets: [String: [Int32]] = [:]
        for (i, f) in sorted.enumerated() {
            let p = Int32(i)
            func post(_ key: Key) { postings[key, default: []].append(p) }
            post(.kind(f.asset.kind))
            var bits = f.asset.subtypes.rawValue
            while bits != 0 {
                let bit = bits & (~bits + 1)
                post(.subtype(bit))
                bits &= bits - 1
            }
            if f.asset.isFavorite { favorites.insert(i) }
            if f.asset.usableLocation != nil { located.insert(i) }
            if let place = f.gpsPlace {
                if let code = place.isoCountryCode {
                    post(.country(code))
                    if let name = place.country { countryNames[code, default: [:]][name, default: 0] += 1 }
                }
                var seen = Set<String>()
                for name in [place.locality, place.subLocality, place.administrativeArea, place.subAdministrativeArea,
                             place.inlandWater, place.ocean, place.areaOfInterest].compactMap({ $0 }) {
                    let key = SearchText.key(name)
                    guard !key.isEmpty, seen.insert(key).inserted else { continue }
                    post(.place(key))
                    if placeNames[key] == nil { placeNames[key] = name }
                }
            }
            // A category also counts for its parents ("vehicle.car" is a "vehicle").
            var categories = Set<String>(), sure = Set<String>()
            for (id, reliability) in f.categories where reliability >= .plausible {
                var parts = id.split(separator: ".").map(String.init)
                while !parts.isEmpty {
                    let key = parts.joined(separator: ".")
                    categories.insert(key)
                    if reliability >= .likely { sure.insert(key) }
                    parts.removeLast()
                }
            }
            for c in categories { post(.category(c)) }
            for c in sure { strong[c, default: []].append(p) }
            for label in f.keywords { post(.label(label)) }
            if let document = f.document {
                post(.anyDocument)
                post(.document(document.type))
                if let merchant = document.merchant {
                    let key = SearchText.key(merchant)
                    post(.merchant(key))
                    if merchantNames[key] == nil { merchantNames[key] = merchant }
                }
                if document.orderNumber != nil { post(.orderNumber) }
                if document.invoiceNumber != nil { post(.invoiceNumber) }
            }
            for category in f.textCategories { post(.screenshot(category)) }
            if let messenger = f.messenger, messenger.app != .unknown { post(.messenger(messenger.app)) }
            if f.tripID != nil { post(.trip) }
            if let frequent = f.frequentPlaceID { post(.frequent(frequent)) }
            for group in f.groupIDs { post(.group(group)) }
            for album in f.albumIDs { post(.album(album)) }
            if let text = f.recognizedText, !text.isEmpty {
                for term in Set(SearchText.words(text)) where term.count >= 2 { termSets[term, default: []].append(p) }
            }
        }
        self.favorites = favorites
        self.located = located
        self.postings = postings
        strongCategories = strong
        terms = termSets.keys.sorted()
        termPostings = terms.map { termSets[$0]! }
        homeCountry = countryNames.max { a, b in
            (postings[.country(a.key)]?.count ?? 0, b.key) < (postings[.country(b.key)]?.count ?? 0, a.key)
        }?.key

        // MARK: Vocabulary
        func photos(_ key: Key) -> Int { postings[key]?.count ?? 0 }
        let lexicon = SearchLexicon.shared

        // Places, with exonyms in both directions: "Munich" finds München, "Rom" finds Rome
        // when the phone geocoded in English, and mixed-language libraries meet in one name.
        var aliases: [String: Set<String>] = [:]
        for key in placeNames.keys { aliases[key, default: []].insert(key) }
        for group in Exonyms.groups {
            let present = group.filter { placeNames[$0] != nil }
            guard !present.isEmpty else { continue }
            for member in group { aliases[member, default: []].formUnion(present) }
        }
        // "Garmisch" for "Garmisch-Partenkirchen", "Frankfurt" for "Frankfurt am Main".
        for (key, _) in placeNames {
            let parts = key.split(separator: "-").map(String.init)
            guard parts.count > 1, let first = parts.first, first.count >= 4, !SearchLexicon.stopwords.contains(first),
                  placeNames[first] == nil, lexicon.lookup(first).isEmpty else { continue }
            aliases[first, default: []].insert(key)
        }
        for (alias, targets) in aliases {
            let ordered = targets.sorted { photos(.place($0)) > photos(.place($1)) }
            let display = placeNames[alias] ?? placeNames[ordered[0]] ?? alias
            vocabulary.add(alias, .init(criterion: ordered.count == 1 ? .place(ordered[0]) : .any(ordered.map { .place($0) }),
                                        kind: .place, german: display, english: display, dimension: "place", importance: 6))
        }

        // Countries: the names in the library, all German and English country names, aliases.
        for (code, names) in countryNames {
            let display = names.max { $0.value < $1.value }!.key
            for name in names.keys {
                vocabulary.add(SearchText.key(name), .init(criterion: .country(code), kind: .country, german: display, english: display,
                                                           dimension: "country", importance: 6))
            }
        }
        for (key, code) in CountryNames.all where vocabulary.names[key]?.contains(where: { $0.criterion == .country(code) }) != true {
            let library = countryNames[code]?.max { $0.value < $1.value }?.key
            vocabulary.add(key, .init(criterion: .country(code), kind: .country, german: library ?? CountryNames.name(code, english: false),
                                      english: library ?? CountryNames.name(code, english: true), dimension: "country", importance: 6))
        }

        for (key, name) in merchantNames {
            let display = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            vocabulary.add(key, .init(criterion: .merchant(key), kind: .merchant, german: display, english: display, dimension: "merchant",
                                      importance: 4, alsoText: true))
        }
        // "DB" for Deutsche Bahn.
        let rail = ["deutsche-bahn", "db-fernverkehr", "db-regio"].filter { merchantNames[$0] != nil }
        if !rail.isEmpty {
            vocabulary.add("db", .init(criterion: .any(rail.map { .merchant($0) }), kind: .merchant, german: "Deutsche Bahn", english: "Deutsche Bahn",
                                       dimension: "merchant", importance: 4, alsoText: true))
        }
        for album in inventory.albums where !album.title.isEmpty {
            vocabulary.add(SearchText.key(album.title), .init(criterion: .album(album.id), kind: .album, german: album.title, english: album.title, importance: 4))
        }
        for group in groups where group.isConfirmed {
            guard let name = group.confirmedName, !name.isEmpty else { continue }
            vocabulary.add(SearchText.key(name), .init(criterion: .group(group.id), kind: .group, german: name, english: name, importance: 5))
        }
        for place in frequentPlaces {
            guard let name = place.userName, !name.isEmpty else { continue }
            vocabulary.add(SearchText.key(name), .init(criterion: .frequentPlace(place.id), kind: .place, german: name, english: name,
                                                       dimension: "place", importance: 6))
        }
        for case .label(let label) in postings.keys {
            vocabulary.labels[SearchText.key(label.replacingOccurrences(of: "_", with: " "))] = label
        }
        self.vocabulary = vocabulary
        suggestionPool = buildSuggestionPool(placeNames: placeNames, countryNames: countryNames, merchantNames: merchantNames, inventory: inventory)
    }

    // MARK: Text

    /// Range of terms that start with `prefix`.
    func termRange(prefix: String) -> Range<Int> {
        var low = 0, high = terms.count
        while low < high {
            let mid = (low + high) / 2
            if terms[mid] < prefix { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < terms.count, terms[end].hasPrefix(prefix) { end += 1 }
        return low..<end
    }

    func hasTerm(_ word: String) -> Bool {
        let range = termRange(prefix: word)
        return !range.isEmpty && terms[range.lowerBound] == word
    }

    /// Whether the recognized text contains the word as a word, a word start or, for longer
    /// words, inside a compound ("Rechnung" in "Stromrechnung").
    func textHits(_ word: String) -> (all: Bitset, strong: Bitset) {
        var all = Bitset(count: count), strong = Bitset(count: count)
        guard word.count >= 2 else { return (all, strong) }
        for i in termRange(prefix: word) {
            for p in termPostings[i] { all.insert(Int(p)) }
            if terms[i] == word { for p in termPostings[i] { strong.insert(Int(p)) } }
        }
        if word.count >= 5 {
            for (i, term) in terms.enumerated() where term.count > word.count && !term.hasPrefix(word) && term.contains(word) {
                for p in termPostings[i] { all.insert(Int(p)) }
            }
        }
        return (all, strong)
    }

    func hasText(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        if !termRange(prefix: word).isEmpty { return true }
        return word.count >= 5 && terms.contains { $0.count > word.count && $0.contains(word) }
    }

    /// The closest word of the recognized text within the typing tolerance.
    func closestTerm(_ word: String) -> String? {
        let limit = SearchText.allowedTypos(word)
        guard limit > 0 else { return nil }
        var best: (term: String, distance: Int, photos: Int)?
        for (i, term) in terms.enumerated() where abs(term.count - word.count) <= limit && term.first == word.first {
            guard let d = SearchText.isTypo(word, of: term) else { continue }
            if best == nil || d < best!.distance || (d == best!.distance && termPostings[i].count > best!.photos) {
                best = (term, d, termPostings[i].count)
            }
        }
        return best?.term
    }

    // MARK: Evaluation

    struct Evaluator {
        let index: SearchIndex
        let statuses: [AssetID: OverallStatus]

        func bits(_ key: SearchIndex.Key) -> Bitset {
            Bitset(count: index.count, positions: index.postings[key] ?? [])
        }

        func scan(_ test: (Int) -> Bool) -> Bitset {
            var b = Bitset(count: index.count)
            for i in 0..<index.datedCount where test(i) { b.insert(i) }
            return b
        }

        /// Positions of photos taken within `interval` (the index is sorted newest first).
        func range(_ interval: DateInterval) -> Range<Int> {
            let start = interval.start.timeIntervalSinceReferenceDate, end = interval.end.timeIntervalSinceReferenceDate
            func firstIndex(before value: Double) -> Int {   // first position with date < value
                var low = 0, high = index.datedCount
                while low < high {
                    let mid = (low + high) / 2
                    if index.dates[mid] >= value { low = mid + 1 } else { high = mid }
                }
                return low
            }
            let from = firstIndex(before: end), to = firstIndex(before: start)
            return from..<max(from, to)
        }

        func clause(_ clause: SearchClause) -> (all: Bitset, strong: Bitset) {
            union(clause.alternatives.map(evaluate))
        }


        func union(_ parts: [(all: Bitset, strong: Bitset)]) -> (all: Bitset, strong: Bitset) {
            var all = Bitset(count: index.count), strong = Bitset(count: index.count)
            for p in parts { all.formUnion(p.all); strong.formUnion(p.strong) }
            return (all, strong)
        }

        func evaluate(_ criterion: SearchCriterion) -> (all: Bitset, strong: Bitset) {
            func same(_ b: Bitset) -> (all: Bitset, strong: Bitset) { (b, b) }
            switch criterion {
            case .country(let code): return same(bits(.country(code)))
            case .countries(let codes): return union(codes.map { same(bits(.country($0))) })
            case .outsideHome:
                var abroad = index.located
                if let home = index.homeCountry { abroad.subtract(bits(.country(home))) } else { abroad = Bitset(count: index.count) }
                // Photos with GPS but no country yet are not known to be abroad.
                var withCountry = Bitset(count: index.count)
                for (key, list) in index.postings { if case .country = key { for p in list { withCountry.insert(Int(p)) } } }
                abroad.formIntersection(withCountry)
                return same(abroad)
            case .place(let key): return same(bits(.place(key)))
            case .year(let y): return same(scan { Int(index.years[$0]) == y })
            case .month(let m): return same(scan { Int(index.months[$0]) == m })
            case .monthDay(let m, let d): return same(scan { Int(index.months[$0]) == m && Int(index.days[$0]) == d })
            case .weekday(let w): return same(scan { Int(index.weekdays[$0]) == w })
            case .dateRange(let interval):
                var b = Bitset(count: index.count)
                b.insert(range: range(interval))
                return same(b)
            case .holiday(let holiday, let years):
                var b = Bitset(count: index.count)
                let span = years.isEmpty ? (index.yearRange.map { Array(($0.lowerBound - 1)...$0.upperBound) } ?? []) : years.sorted()
                for y in span {
                    if let window = holiday.window(year: y, calendar: index.calendar) { b.insert(range: range(window)) }
                }
                for label in holiday.labels {
                    for p in index.postings[.label(label)] ?? [] where years.isEmpty || years.contains(Int(index.years[Int(p)])) {
                        b.insert(Int(p))
                    }
                }
                return same(b)
            case .mediaKind(let kind): return same(bits(.kind(kind)))
            case .subtype(let subtypes):
                var b = Bitset(count: index.count, filled: true)
                var raw = subtypes.rawValue
                while raw != 0 {
                    let bit = raw & (~raw + 1)
                    b.formIntersection(bits(.subtype(bit)))
                    raw &= raw - 1
                }
                return same(b)
            case .favorite: return same(index.favorites)
            case .category(let id):
                return (bits(.category(id)), Bitset(count: index.count, positions: index.strongCategories[id] ?? []))
            case .label(let id):
                // Labels carry no confidence in the facts; they never count as "sure".
                return (bits(.label(id)), Bitset(count: index.count))
            case .documentType(let type): return same(bits(.document(type)))
            case .anyDocument: return same(bits(.anyDocument))
            case .screenshotCategory(let category): return same(bits(.screenshot(category)))
            case .merchant(let key): return same(bits(.merchant(key)))
            case .orderNumber: return same(bits(.orderNumber))
            case .invoiceNumber: return same(bits(.invoiceNumber))
            case .messenger(let app): return same(bits(.messenger(app)))
            case .trip: return same(bits(.trip))
            case .frequentPlace(let id): return same(bits(.frequent(id)))
            case .group(let id): return same(bits(.group(id)))
            case .album(let id): return same(bits(.album(id)))
            case .hasLocation(let value): return same(value ? index.located : index.located.inverted())
            case .status(let wanted):
                var b = Bitset(count: index.count)
                for (i, id) in index.ids.enumerated() where statuses[id].map(wanted.contains) == true { b.insert(i) }
                return same(b)
            case .text(let word): return index.textHits(word)
            case .any(let list): return union(list.map(evaluate))
            case .all(let list):
                var all = Bitset(count: index.count, filled: true), strong = Bitset(count: index.count, filled: true)
                for part in list.map(evaluate) { all.formIntersection(part.all); strong.formIntersection(part.strong) }
                return (all, strong)
            }
        }
    }

    /// Photos matching a criterion alone (counts for suggestions and chips).
    func count(of criterion: SearchCriterion) -> Int {
        photos(of: criterion).cardinality
    }

    func photos(of criterion: SearchCriterion) -> Bitset {
        Evaluator(index: self, statuses: [:]).evaluate(criterion).all
    }

    // MARK: Search

    /// Parses and runs a query. `statuses` is only needed for "nicht sortiert"; see
    /// `SearchQuery.usesStatus`.
    public func search(_ text: String, now: Date = Date(), statuses: [AssetID: OverallStatus] = [:]) -> SearchResult {
        SearchEngine().run(parse(text, now: now), in: self, statuses: statuses)
    }

    public func parse(_ text: String, now: Date = Date()) -> SearchQuery {
        QueryParser(index: self, now: now).parse(text)
    }

    // MARK: Suggestions

    private func buildSuggestionPool(placeNames: [String: String], countryNames: [String: [String: Int]], merchantNames: [String: String],
                                     inventory: CollectionInventory) -> [SuggestionCandidate] {
        var pool: [SuggestionCandidate] = []
        for (key, name) in placeNames {
            let n = postings[.place(key)]?.count ?? 0
            if n > 0 { pool.append(.init(keys: [key], englishKeys: [], german: name, english: name, kind: .place, count: n)) }
        }
        for (code, names) in countryNames {
            let display = names.max { $0.value < $1.value }!.key
            let keys = Set(names.keys.map(SearchText.key) + [SearchText.key(CountryNames.name(code, english: false)), SearchText.key(CountryNames.name(code, english: true))])
            let n = postings[.country(code)]?.count ?? 0
            if n > 0 { pool.append(.init(keys: keys.sorted(), englishKeys: [], german: display, english: display, kind: .country, count: n)) }
        }
        for (key, name) in merchantNames {
            let n = postings[.merchant(key)]?.count ?? 0
            let display = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            if n > 0 { pool.append(.init(keys: [key], englishKeys: [], german: display, english: display, kind: .merchant, count: n)) }
        }
        for album in inventory.albums where !album.title.isEmpty {
            let n = postings[.album(album.id)]?.count ?? 0
            if n > 0 { pool.append(.init(keys: [SearchText.key(album.title)], englishKeys: [], german: album.title, english: album.title, kind: .album, count: n)) }
        }
        // Topics, documents and media types that occur, under all their forms.
        let lexicon = SearchLexicon.shared
        var formsByEntry: [Int: [(String, SearchLexicon.Language)]] = [:]
        for (key, forms) in lexicon.forms { for f in forms { formsByEntry[f.entry, default: []].append((key, f.language)) } }
        let evaluator = Evaluator(index: self, statuses: [:])
        for (i, entry) in lexicon.entries.enumerated() where entry.suggest && entry.kind != .status && entry.kind != .field {
            let n = evaluator.evaluate(entry.criterion).all.cardinality
            guard n > 0, let forms = formsByEntry[i] else { continue }
            pool.append(.init(keys: forms.map(\.0).sorted(), englishKeys: Set(forms.filter { $0.1 == .english }.map(\.0)),
                              german: entry.german, english: entry.english, kind: entry.kind, count: n))
        }
        if let years = yearRange {
            for y in years {
                let n = evaluator.evaluate(.year(y)).all.cardinality
                if n > 0 { pool.append(.init(keys: [String(y)], englishKeys: [], german: String(y), english: String(y), kind: .year, count: n)) }
            }
        }
        return pool.sorted { $0.count != $1.count ? $0.count > $1.count : $0.german < $1.german }
    }

    /// Completions for the word being typed, from the user's own library, most photos first.
    /// Nothing is offered once the word is complete, so the results stay in view.
    public func suggestions(for text: String, limit: Int = 6) -> [SearchSuggestion] {
        guard let last = text.split(whereSeparator: \.isWhitespace).last, text.last?.isWhitespace != true else { return [] }
        let prefix = SearchText.key(String(last))
        guard prefix.count >= 2 else { return [] }
        let head = String(text.dropLast(last.count))
        var seen = Set<String>()
        var result: [SearchSuggestion] = []
        for candidate in suggestionPool {
            let matching = candidate.keys.filter { key in
                key.hasPrefix(prefix) || key.split(separator: "-").contains { $0.hasPrefix(prefix) }
            }
            guard !matching.isEmpty, !candidate.keys.contains(prefix) else { continue }
            let english = matching.allSatisfy(candidate.englishKeys.contains)
            let label = english ? candidate.english : candidate.german
            guard seen.insert(label.lowercased()).inserted else { continue }
            result.append(SearchSuggestion(completion: head + label, label: label, kind: candidate.kind, count: candidate.count))
            if result.count == limit { break }
        }
        return result
    }

    /// Starting points for an empty search field: the user's most photographed places and
    /// topics, the newest year, and screenshots and videos when there are any.
    public func featuredSuggestions(limit: Int = 6) -> [SearchSuggestion] {
        func take(_ kinds: Set<SearchToken.Kind>, _ n: Int) -> [SearchSuggestion] {
            suggestionPool.filter { kinds.contains($0.kind) }.prefix(n)
                .map { SearchSuggestion(completion: $0.german, label: $0.german, kind: $0.kind, count: $0.count) }
        }
        var result = take([.place], 2) + take([.category], 2)
        if let year = yearRange?.upperBound, count(of: .year(year)) > 0 {
            result.append(SearchSuggestion(completion: String(year), label: String(year), kind: .year, count: count(of: .year(year))))
        }
        result += take([.mediaType], 2) + take([.document], 1)
        return Array(result.prefix(limit))
    }
}

/// Country names in German and English for every ISO region, from the system, so any
/// country can be searched even when the library has no photos there yet.
enum CountryNames {
    static let all: [String: String] = {
        var table: [String: String] = [:]
        let german = Locale(identifier: "de_DE"), english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions where region.identifier.count == 2 && region.identifier.allSatisfy(\.isLetter) {
            let code = region.identifier
            for locale in [german, english] {
                if let name = locale.localizedString(forRegionCode: code) {
                    let key = SearchText.key(name)
                    if !key.isEmpty, table[key] == nil { table[key] = code }
                }
            }
        }
        return table
    }()

    static func name(_ code: String, english: Bool) -> String {
        Locale(identifier: english ? "en_US" : "de_DE").localizedString(forRegionCode: code) ?? code
    }
}

/// Place names in other languages. Photos are geocoded in the phone's language, people type
/// in theirs: each group lists one place's names, folded.
enum Exonyms {
    static let groups: [[String]] = [
        ["munchen", "munich", "monaco-di-baviera"], ["koln", "cologne"], ["nurnberg", "nuremberg"], ["wien", "vienna"], ["rom", "rome", "roma"],
        ["mailand", "milan", "milano"], ["venedig", "venice", "venezia"], ["florenz", "florence", "firenze"], ["neapel", "naples", "napoli"],
        ["turin", "torino"], ["genua", "genoa", "genova"], ["padua", "padova"], ["lissabon", "lisbon", "lisboa"], ["prag", "prague", "praha"],
        ["warschau", "warsaw", "warszawa"], ["krakau", "krakow", "cracow"], ["kopenhagen", "copenhagen", "kobenhavn"],
        ["brussel", "brussels", "bruxelles", "brussel"], ["athen", "athens", "athina"], ["moskau", "moscow", "moskva"], ["genf", "geneva", "geneve"],
        ["luttich", "liege"], ["antwerpen", "antwerp"], ["den-haag", "the-hague"], ["belgrad", "belgrade", "beograd"], ["bukarest", "bucharest"],
        ["sevilla", "seville"], ["saragossa", "zaragoza"], ["peking", "beijing"], ["kapstadt", "cape-town"], ["mexiko-stadt", "mexico-city"],
        ["kairo", "cairo"], ["bayern", "bavaria"], ["toskana", "tuscany", "toscana"], ["sizilien", "sicily", "sicilia"],
        ["sardinien", "sardinia", "sardegna"], ["korsika", "corsica", "corse"], ["kreta", "crete"], ["zypern", "cyprus"], ["mallorca", "majorca"],
        ["teneriffa", "tenerife"], ["kanaren", "kanarische-inseln", "canary-islands", "islas-canarias"],
        ["balearen", "balearische-inseln", "balearic-islands", "islas-baleares", "illes-balears"], ["gardasee", "lake-garda", "lago-di-garda"],
        ["bodensee", "lake-constance"], ["comer-see", "comersee", "lake-como", "lago-di-como"], ["genfersee", "genfer-see", "lake-geneva", "lac-leman"],
        ["schwarzwald", "black-forest"], ["lombardei", "lombardy", "lombardia"], ["venetien", "veneto"], ["latium", "lazio"],
        ["kampanien", "campania"], ["apulien", "apulia", "puglia"], ["sudtirol", "south-tyrol", "alto-adige", "trentino-sudtirol", "trentino-alto-adige"],
        ["tirol", "tyrol"], ["katalonien", "catalonia", "catalunya", "cataluna"], ["andalusien", "andalusia", "andalucia"],
        ["bretagne", "brittany"], ["normandie", "normandy"], ["kalifornien", "california"], ["new-york", "nyc", "new-york-city"],
        ["niedersachsen", "lower-saxony"], ["nordrhein-westfalen", "north-rhine-westphalia", "nrw"], ["hessen", "hesse"], ["sachsen", "saxony"],
        ["thuringen", "thuringia"], ["rheinland-pfalz", "rhineland-palatinate"], ["steiermark", "styria"], ["karnten", "carinthia"],
        ["oberbayern", "upper-bavaria"], ["nordsee", "north-sea"], ["ostsee", "baltic-sea"], ["mittelmeer", "mediterranean", "mediterranean-sea"],
        ["adria", "adriatic", "adriatisches-meer", "adriatic-sea"], ["atlantik", "atlantic", "atlantic-ocean", "atlantischer-ozean"],
        ["pazifik", "pacific", "pacific-ocean", "pazifischer-ozean"], ["dolomiten", "dolomites", "dolomiti"], ["alpen", "alps"],
    ]
}
