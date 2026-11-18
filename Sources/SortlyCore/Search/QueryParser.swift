import Foundation

/// Rule-based natural-language query parser (German and English). Deterministic, so the
/// displayed interpretation always matches what is searched.
///
/// Reading order: dates written as numbers ("24.12.2024"), multi-word names from the library
/// ("New York", "Deutsche Bahn"), date expressions ("letzten Sommer", "vor 2 Jahren"), then
/// words and phrases of the lexicon and the library. What is left is looked up in the text on
/// screenshots and documents, split as a German compound ("Hundestrand"), corrected for typos
/// ("Itallien") or, failing all that, reported as not understood.
public struct QueryParser: Sendable {
    public let index: SearchIndex
    public let now: Date

    public init(index: SearchIndex, now: Date = Date()) {
        self.index = index
        self.now = now
    }

    var calendar: Calendar { index.calendar }
    var lexicon: SearchLexicon { .shared }

    struct Word {
        var typed: String
        var key: String
        /// Words typed without a space between them ("302-1234567") share a chunk.
        var chunk: Int
    }

    /// A clause being built.
    struct Draft {
        var alternatives: [SearchCriterion]
        var kind: SearchToken.Kind
        var german: String
        var english: String
        var detailGerman: String?
        var detailEnglish: String?
        var dimension: String?
        var importance: Int
        var position: Int
        var language: SearchLexicon.Language
        var typed: String?
        var chunk: Int?
        /// A holiday that takes the year of the query ("Weihnachten 2024").
        var holiday: Holiday?
        /// The last word of the query the draft was read from, when it was read from words.
        var end: Int?
    }

    public func parse(_ text: String) -> SearchQuery {
        var drafts: [Draft] = []
        var raw = text
        var ignored: [String] = []
        drafts += literalDates(in: &raw, ignored: &ignored)
        let words = Self.tokenize(raw)
        var consumed = [Bool](repeating: false, count: words.count)

        // 1. Multi-word names from the library: "New York", "Deutsche Bahn", "Lake Garda".
        drafts += phrases(words, &consumed, minimumWords: 2, includeLexicon: false)
        // 2. Date expressions.
        drafts += dates(words, &consumed)
        // 3. Lexicon and library words and phrases.
        drafts += phrases(words, &consumed, minimumWords: 1, includeLexicon: true)
        // 4. "seit 2024", "before 2020": a period up to or from the date that follows.
        drafts = periods(drafts, words: words, consumed: &consumed, ignored: &ignored)
        // 5. The rest: text on screenshots, compounds, typos.
        var negations = Set<Int>()
        for (i, word) in words.enumerated() where !consumed[i] {
            if SearchLexicon.negations.contains(word.key) { negations.insert(i); continue }
            if SearchLexicon.stopwords.contains(word.key) || word.key.count < 2 { continue }
            if let found = rest(word, at: i) {
                drafts += found
            } else if word.key.allSatisfy(\.isNumber) && word.key.count < 3 {
                continue   // a stray small number ("vor 2") is no search term
            } else {
                ignored.append(word.typed)
            }
        }
        return assemble(drafts, words: words, negations: negations, ignored: ignored)
    }

    // MARK: Tokens

    static func tokenize(_ text: String) -> [Word] {
        var words: [Word] = []
        for (chunk, piece) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            for part in String(piece).components(separatedBy: CharacterSet.alphanumerics.inverted) where !part.isEmpty {
                let key = SearchText.fold(part)
                if !key.isEmpty { words.append(Word(typed: part, key: key, chunk: chunk)) }
            }
        }
        return words
    }

    // MARK: Phrases

    /// Longest phrases first; a phrase never spans a word that is already understood.
    private func phrases(_ words: [Word], _ consumed: inout [Bool], minimumWords: Int, includeLexicon: Bool) -> [Draft] {
        var drafts: [Draft] = []
        let longest = max(lexicon.maxWords, index.vocabulary.maxWords, 1)
        for length in stride(from: min(longest, words.count), through: minimumWords, by: -1) where length > 0 {
            for start in 0...(words.count - length) {
                let range = start..<(start + length)
                guard !consumed[range].contains(true) else { continue }
                if length == 1, SearchLexicon.stopwords.contains(words[start].key) || SearchLexicon.negations.contains(words[start].key) { continue }
                let key = words[range].map(\.key).joined(separator: "-")
                let typed = words[range].map(\.typed).joined(separator: " ")
                guard var draft = interpret(key, typed: typed, includeLexicon: includeLexicon, allowLibraryAlbums: includeLexicon, position: start) else { continue }
                if !includeLexicon, draft.kind == .album { continue }
                draft.position = start
                draft.end = range.upperBound - 1
                drafts.append(draft)
                for i in range { consumed[i] = true }
            }
        }
        return drafts
    }

    /// What a word or phrase means, exactly or with a spelling variant (umlauts written as
    /// "ue", plural forms the lexicon does not list).
    func interpret(_ key: String, typed: String, includeLexicon: Bool, allowLibraryAlbums: Bool = true, position: Int) -> Draft? {
        var candidates = [key]
        if let t = SearchText.transliterated(key) { candidates.append(t) }
        if !key.contains("-") {
            for s in SearchText.singulars(key) { candidates.append(s); if let t = SearchText.transliterated(s) { candidates.append(t) } }
        }
        for candidate in candidates {
            if let draft = exact(candidate, typed: typed, includeLexicon: includeLexicon, position: position) { return draft }
        }
        return nil
    }

    /// Everything one key can mean, as a single draft with alternatives.
    func exact(_ key: String, typed: String, includeLexicon: Bool, position: Int) -> Draft? {
        var parts: [Draft] = []
        for name in index.vocabulary.names[key] ?? [] {
            var criterion = name.criterion
            if name.alsoText, !key.contains("-"), index.hasText(key) { criterion = .any([criterion, .text(key)]) }
            parts.append(Draft(alternatives: [criterion], kind: name.kind, german: name.german, english: name.english, dimension: name.dimension,
                               importance: name.importance, position: position, language: .neutral))
        }
        if includeLexicon {
            if let date = dateWord(key, typed: typed, position: position) { parts.append(date) }
            for form in lexicon.lookup(key) {
                let entry = lexicon.entries[form.entry]
                var criterion = entry.criterion
                if entry.alsoText, !key.contains("-"), index.hasText(key) { criterion = .any([criterion, .text(key)]) }
                parts.append(Draft(alternatives: [criterion], kind: entry.kind, german: entry.german, english: entry.english, dimension: entry.dimension,
                                   importance: entry.importance, position: position, language: form.language))
            }
            if parts.isEmpty, let label = index.vocabulary.labels[key] {
                let display = label.replacingOccurrences(of: "_", with: " ").capitalized
                parts.append(Draft(alternatives: [.label(label)], kind: .category, german: display, english: display, importance: 3,
                                   position: position, language: .english))
            }
        }
        guard var first = parts.first else { return nil }
        if parts.count > 1 {
            // One word, several meanings ("Essen" the city and food): any of them.
            first.alternatives = parts.flatMap(\.alternatives)
            first.dimension = Set(parts.map(\.dimension)).count == 1 ? first.dimension : nil
            first.importance = parts.map(\.importance).max() ?? first.importance
            if first.language == .neutral { first.language = parts.first { $0.language != .neutral }?.language ?? .neutral }
            first.holiday = parts.compactMap(\.holiday).first
            first.detailGerman = parts.compactMap(\.detailGerman).first
            first.detailEnglish = parts.compactMap(\.detailEnglish).first
        }
        return first
    }

    // MARK: The rest

    /// A word nothing else claimed.
    private func rest(_ word: Word, at position: Int) -> [Draft]? {
        let key = word.key
        func text(_ term: String, typed: String? = nil) -> Draft {
            Draft(alternatives: [.text(term)], kind: .text, german: "„\(typed ?? word.typed)“", english: "“\(typed ?? word.typed)”",
                  importance: 2, position: position, language: .neutral, typed: nil, chunk: word.chunk)
        }
        // Written on a screenshot or document exactly like this.
        if index.hasTerm(key) { return [text(key)] }
        // German compounds: "Hundestrand" = Hund + Strand, "Hochzeitsfotos" = Hochzeit.
        if let parts = compound(key, position: position) { return parts }
        if index.hasText(key) { return [text(key)] }
        // Typing errors, against the user's vocabulary first, then against the text.
        if var corrected = closest(key, position: position) {
            corrected.typed = word.typed
            return [corrected]
        }
        if let term = index.closestTerm(key) {
            var draft = text(term, typed: term)
            draft.typed = word.typed
            return [draft]
        }
        return nil
    }

    private func compound(_ key: String, position: Int) -> [Draft]? {
        guard key.count >= 7, !key.allSatisfy(\.isNumber) else { return nil }
        let letters = Array(key)
        for cut in stride(from: letters.count - 3, through: 3, by: -1) {
            let head = String(letters[..<cut]), tail = String(letters[cut...])
            let tailIsFiller = SearchLexicon.stopwords.contains(tail)
            let right: Draft? = tailIsFiller ? nil : interpret(tail, typed: tail, includeLexicon: true, position: position)
            if !tailIsFiller && right == nil { continue }
            // Linking letters: "Hochzeit-s-fotos", "Hunde-strand", "Sonne-n-untergang".
            var heads = [head]
            for link in ["s", "es", "n", "en", "e"] where head.hasSuffix(link) && head.count - link.count >= 3 { heads.append(String(head.dropLast(link.count))) }
            for h in heads {
                guard var left = interpret(h, typed: h, includeLexicon: true, position: position) else { continue }
                left.typed = nil
                return tailIsFiller ? [left] : [left, right!]
            }
        }
        return nil
    }

    /// The closest known word within the typing tolerance that has photos.
    private func closest(_ key: String, position: Int) -> Draft? {
        let limit = SearchText.allowedTypos(key)
        guard limit > 0 else { return nil }
        var best: (key: String, distance: Int, photos: Int)?
        func consider(_ candidate: String) {
            guard abs(candidate.count - key.count) <= limit, candidate.first == key.first, !candidate.contains("-") || key.contains("-"),
                  let d = SearchText.isTypo(key, of: candidate) else { return }
            if let best, d > best.distance { return }
            guard let draft = interpret(candidate, typed: candidate, includeLexicon: true, position: position) else { return }
            let photos = draft.alternatives.reduce(0) { $0 + index.count(of: $1) }
            guard photos > 0 else { return }
            if best == nil || d < best!.distance || photos > best!.photos { best = (candidate, d, photos) }
        }
        for candidate in lexicon.forms.keys { consider(candidate) }
        for candidate in index.vocabulary.names.keys { consider(candidate) }
        for candidate in index.vocabulary.labels.keys { consider(candidate) }
        for candidate in Self.dateWords.keys { consider(candidate) }
        guard let best else { return nil }
        return interpret(best.key, typed: best.key, includeLexicon: true, position: position)
    }

    // MARK: Assembly

    private func assemble(_ input: [Draft], words: [Word], negations: Set<Int>, ignored: [String]) -> SearchQuery {
        var drafts = input
        // "Weihnachten 2024": the holiday of that year, Silvester including the night into 2025.
        let years = drafts.filter { $0.dimension == "year" }.flatMap(\.alternatives).compactMap { c -> Int? in
            if case .year(let y) = c { return y } else { return nil }
        }
        if !years.isEmpty, drafts.contains(where: { $0.holiday != nil }) {
            drafts = drafts.filter { $0.dimension != "year" }.map { draft in
                guard let holiday = draft.holiday else { return draft }
                var d = draft
                d.alternatives = [.holiday(holiday, years: Set(years))]
                let suffix = " " + years.sorted().map(String.init).joined(separator: ", ")
                d.german += suffix
                d.english += suffix
                return d
            }
        }
        // Words typed together without spaces stay one text term ("302-1234567").
        var merged: [Draft] = []
        for draft in drafts.sorted(by: { $0.position < $1.position }) {
            if draft.kind == .text, draft.typed == nil, let chunk = draft.chunk, let last = merged.last, last.kind == .text, last.chunk == chunk, last.typed == nil {
                var joined = last
                joined.alternatives = [.all(last.alternatives + draft.alternatives)]
                let typed = words.filter { $0.chunk == chunk }.map(\.typed)
                let original = typed.joined(separator: "-")
                joined.german = "„\(original)“"
                joined.english = "“\(original)”"
                merged[merged.count - 1] = joined
            } else {
                merged.append(draft)
            }
        }
        drafts = merged

        let german = drafts.filter { $0.language == .german }.count
        let english = drafts.filter { $0.language == .english }.count
        let useEnglish = english > german

        func negated(_ position: Int) -> Bool {
            var i = position - 1
            while i >= 0 {
                if negations.contains(i) { return true }
                guard SearchLexicon.stopwords.contains(words[i].key) else { return false }
                i -= 1
            }
            return false
        }

        var clauses: [SearchClause] = []
        for draft in drafts {
            let isNegated = negated(draft.position)
            var label = useEnglish ? draft.english : draft.german
            if isNegated { label = (useEnglish ? "without " : "ohne ") + label }
            let token = SearchToken(kind: draft.kind, label: label,
                                    detail: useEnglish ? draft.detailEnglish : draft.detailGerman, typed: draft.typed, negated: isNegated)
            let clause = SearchClause(alternatives: draft.alternatives, token: token, dimension: draft.dimension, importance: draft.importance,
                                      negated: isNegated, position: draft.position)
            // Values of one kind are alternatives ("Rom Florenz", "2023 2024", "Juli August"),
            // except a place inside another one, which narrows the search ("Bayern München",
            // "Europa Italien").
            if !isNegated, let dimension = draft.dimension,
               let i = clauses.firstIndex(where: { $0.dimension == dimension && !$0.negated }),
               !nested(clauses[i].criterion, clause.criterion, dimension: dimension) {
                clauses[i].alternatives += draft.alternatives
                clauses[i].token.label += (useEnglish ? " or " : " oder ") + token.label
                if let detail = token.detail { clauses[i].token.detail = [clauses[i].token.detail, detail].compactMap { $0 }.joined(separator: ", ") }
                clauses[i].importance = max(clauses[i].importance, draft.importance)
                continue
            }
            clauses.append(clause)
        }
        return SearchQuery(clauses: clauses, ignored: ignored)
    }

    /// Whether the photos of one place lie within those of the other.
    private func nested(_ a: SearchCriterion, _ b: SearchCriterion, dimension: String) -> Bool {
        guard dimension == "place" || dimension == "country" else { return false }
        let x = index.photos(of: a), y = index.photos(of: b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        func within(_ inner: Bitset, _ outer: Bitset) -> Bool {
            var rest = inner
            rest.subtract(outer)
            return rest.isEmpty
        }
        return within(x, y) || within(y, x)
    }
}

// MARK: - Dates

extension QueryParser {
    enum Unit { case day, week, month, year, weekend }

    static let lastWords: Set<String> = ["letzte", "letzten", "letzter", "letztes", "letztem", "vergangene", "vergangenen", "vergangener", "vergangenes",
                                         "vorige", "vorigen", "voriger", "voriges", "last", "past", "previous"]
    static let beforeLastWords: Set<String> = ["vorletzte", "vorletzten", "vorletzter", "vorletztes"]
    static let thisWords: Set<String> = ["diese", "diesen", "dieser", "dieses", "diesem", "this", "current", "aktuelle", "aktuellen", "aktuelles", "aktueller"]
    static let englishDateWords: Set<String> = ["last", "past", "previous", "this", "current", "ago", "today", "yesterday", "day", "days", "week", "weeks",
                                                "month", "months", "year", "years", "weekend", "weekends"]

    static let units: [String: Unit] = [
        "tag": .day, "tage": .day, "tagen": .day, "day": .day, "days": .day,
        "woche": .week, "wochen": .week, "week": .week, "weeks": .week,
        "monat": .month, "monate": .month, "monaten": .month, "monats": .month, "month": .month, "months": .month,
        "jahr": .year, "jahre": .year, "jahren": .year, "jahres": .year, "jahrs": .year, "year": .year, "years": .year,
        "wochenende": .weekend, "wochenendes": .weekend, "weekend": .weekend,
    ]

    static let numbers: [String: Int] = [
        "ein": 1, "eine": 1, "einem": 1, "einer": 1, "einen": 1, "eins": 1, "one": 1, "a": 1, "an": 1,
        "zwei": 2, "two": 2, "drei": 3, "three": 3, "vier": 4, "four": 4, "funf": 5, "five": 5, "sechs": 6, "six": 6,
        "sieben": 7, "seven": 7, "acht": 8, "eight": 8, "neun": 9, "nine": 9, "zehn": 10, "ten": 10, "elf": 11, "eleven": 11,
        "zwolf": 12, "twelve": 12, "zwanzig": 20, "twenty": 20,
    ]

    enum DateWord {
        case month(Int), season(SearchSeason), holiday(Holiday), weekday(Int), weekend
    }

    /// Single words that name a time, with their language.
    static let dateWords: [String: (DateWord, SearchLexicon.Language)] = {
        var table: [String: (DateWord, SearchLexicon.Language)] = [:]
        func add(_ forms: String, _ word: DateWord, _ language: SearchLexicon.Language) {
            for f in forms.split(separator: "|") { table[SearchText.key(String(f))] = (word, language) }
        }
        let germanMonths = ["januar|jänner|jan", "februar|feber|feb", "märz|maerz", "april|apr", "mai", "juni|jun", "juli|jul",
                            "august|aug", "september|sept|sep", "oktober|okt", "november|nov", "dezember|dez"]
        let englishMonths = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october|oct", "november", "december|dec"]
        for m in 0..<12 {
            add(germanMonths[m], .month(m + 1), .german)
            add(englishMonths[m], .month(m + 1), .english)
        }
        // "april", "august", "september", "november" are the same in both languages.
        for shared in ["april", "august", "september", "november", "apr", "aug", "sep", "sept", "nov"] { table[shared]?.1 = .neutral }
        add("frühling|frühjahr|fruehling|fruehjahr", .season(SearchSeason.spring), .german)
        add("spring", .season(SearchSeason.spring), .english)
        add("sommer|sommers", .season(SearchSeason.summer), .german)
        add("summer", .season(SearchSeason.summer), .english)
        add("herbst|herbstes", .season(SearchSeason.autumn), .german)
        add("autumn|fall", .season(SearchSeason.autumn), .english)
        add("winter|winters", .season(SearchSeason.winter), .neutral)
        add("heiligabend|heiliger abend", .holiday(.christmasEve), .german)
        add("christmas eve|xmas eve", .holiday(.christmasEve), .english)
        add("weihnachten|weihnacht|weihnachtsfest|weihnachtsfeiertage|weihnachtsfotos|weihnachtszeit", .holiday(.christmas), .german)
        add("christmas|xmas|x-mas|christmas day", .holiday(.christmas), .english)
        add("silvester|sylvester|silvesterparty|silvesterabend|jahreswechsel", .holiday(.newYearsEve), .german)
        add("new years eve|new year s eve|new year eve|nye", .holiday(.newYearsEve), .english)
        add("neujahr|neujahrstag", .holiday(.newYearsDay), .german)
        add("new years day|new year s day|new year", .holiday(.newYearsDay), .english)
        add("ostern|osterfest|ostersonntag|ostermontag|karfreitag|osterwochenende", .holiday(.easter), .german)
        add("easter|easter sunday|easter monday|good friday|easter weekend", .holiday(.easter), .english)
        add("pfingsten|pfingstsonntag|pfingstmontag", .holiday(.pentecost), .german)
        add("pentecost|whitsun|whitsunday", .holiday(.pentecost), .english)
        add("karneval|fasching|fastnacht|fasnacht|fasnet|rosenmontag|weiberfastnacht", .holiday(.carnival), .german)
        add("carnival|mardi gras", .holiday(.carnival), .english)
        add("halloween", .holiday(.halloween), .neutral)
        add("valentinstag", .holiday(.valentinesDay), .german)
        add("valentines day|valentine s day|valentines|valentine", .holiday(.valentinesDay), .english)
        add("nikolaus|nikolaustag", .holiday(.stNicholas), .german)
        add("st nicholas|saint nicholas|st nicholas day", .holiday(.stNicholas), .english)
        add("thanksgiving", .holiday(.thanksgiving), .neutral)
        let germanDays = ["sonntag|sonntags|sonntagen", "montag|montags|montagen", "dienstag|dienstags", "mittwoch|mittwochs", "donnerstag|donnerstags",
                          "freitag|freitags", "samstag|samstags|sonnabend|samstagen"]
        let englishDays = ["sunday|sundays", "monday|mondays", "tuesday|tuesdays", "wednesday|wednesdays", "thursday|thursdays", "friday|fridays", "saturday|saturdays"]
        for d in 0..<7 {
            add(germanDays[d], .weekday(d + 1), .german)
            add(englishDays[d], .weekday(d + 1), .english)
        }
        add("wochenende|wochenenden|wochenendes", .weekend, .german)
        add("weekend|weekends", .weekend, .english)
        return table
    }()

    /// A single word or phrase that names a time ("Juli", "Sommer", "Weihnachten", "Samstag").
    func dateWord(_ key: String, typed: String, position: Int) -> Draft? {
        guard let (word, language) = Self.dateWords[key].map({ ($0.0, $0.1) }) else { return nil }
        func draft(_ alternatives: [SearchCriterion], _ german: String, _ english: String, _ dimension: String) -> Draft {
            Draft(alternatives: alternatives, kind: .date, german: german, english: english, dimension: dimension, importance: 4,
                  position: position, language: language)
        }
        switch word {
        case .month(let m):
            return draft([.month(m)], SearchDateFormat.month(m, english: false), SearchDateFormat.month(m, english: true), "month")
        case .season(let s):
            return draft(s.months.map { .month($0) }, s.german, s.english, "month")
        case .holiday(let h):
            var d = draft([.holiday(h, years: [])], h.german, h.english, "holiday")
            d.holiday = h
            return d
        case .weekday(let w):
            return draft([.weekday(w)], SearchDateFormat.weekday(w, english: false), SearchDateFormat.weekday(w, english: true), "weekday")
        case .weekend:
            return draft([.weekday(7), .weekday(1)], "Wochenende", "Weekend", "weekday")
        }
    }

    /// Relative and calendar expressions over several words.
    private func dates(_ words: [Word], _ consumed: inout [Bool]) -> [Draft] {
        var drafts: [Draft] = []
        var i = 0
        func free(_ j: Int) -> Bool { j >= 0 && j < words.count && !consumed[j] }
        func key(_ j: Int) -> String? { free(j) ? words[j].key : nil }
        func number(_ j: Int) -> Int? {
            guard let k = key(j) else { return nil }
            if let n = Int(k), (1...400).contains(n), k.count <= 3 { return n }
            return Self.numbers[k]
        }
        func phrase(_ range: ClosedRange<Int>) -> String {
            let text = words[range].map(\.typed).joined(separator: " ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        func language(_ range: ClosedRange<Int>) -> SearchLexicon.Language {
            words[range].contains { Self.englishDateWords.contains($0.key) } ? .english : .german
        }
        func add(_ interval: DateInterval?, _ range: ClosedRange<Int>, label: String? = nil, labelEnglish: String? = nil) {
            guard let interval else { return }
            let typed = phrase(range)
            let german = SearchDateFormat.interval(interval, english: false, calendar: calendar)
            let english = SearchDateFormat.interval(interval, english: true, calendar: calendar)
            var draft = Draft(alternatives: [.dateRange(interval)], kind: .date, german: label ?? typed, english: labelEnglish ?? label ?? typed,
                              dimension: "date", importance: 4, position: range.lowerBound, language: language(range))
            if (label ?? typed) != german { draft.detailGerman = german }
            if (labelEnglish ?? label ?? typed) != english { draft.detailEnglish = english }
            draft.end = range.upperBound
            drafts.append(draft)
            for j in range { consumed[j] = true }
        }

        while i < words.count {
            guard let k = key(i) else { i += 1; continue }
            let today = calendar.startOfDay(for: now)
            switch k {
            case "heute", "today":
                add(calendar.dateInterval(of: .day, for: now), i...i); i += 1; continue
            case "gestern", "yesterday":
                add(calendar.date(byAdding: .day, value: -1, to: today).flatMap { calendar.dateInterval(of: .day, for: $0) }, i...i); i += 1; continue
            case "vorgestern":
                add(calendar.date(byAdding: .day, value: -2, to: today).flatMap { calendar.dateInterval(of: .day, for: $0) }, i...i); i += 1; continue
            default: break
            }
            if k == "day", key(i + 1) == "before", key(i + 2) == "yesterday" {
                add(calendar.date(byAdding: .day, value: -2, to: today).flatMap { calendar.dateInterval(of: .day, for: $0) }, i...(i + 2)); i += 3; continue
            }
            // "vor 2 Jahren", "vor einer Woche"
            if k == "vor", let n = number(i + 1), let unitKey = key(i + 2), let unit = Self.units[unitKey] {
                add(period(unit, offset: -n), i...(i + 2)); i += 3; continue
            }
            // "2 years ago", "a week ago"
            if let n = number(i), let unitKey = key(i + 1), let unit = Self.units[unitKey], key(i + 2) == "ago" {
                add(period(unit, offset: -n), i...(i + 2)); i += 3; continue
            }
            if Self.lastWords.contains(k) || Self.thisWords.contains(k) || Self.beforeLastWords.contains(k) {
                let offset = Self.thisWords.contains(k) ? 0 : (Self.beforeLastWords.contains(k) ? -2 : -1)
                // "letzten 3 Tage", "last 7 days", "in den letzten 2 Wochen"
                if offset == -1, let n = number(i + 1), let unitKey = key(i + 2), let unit = Self.units[unitKey], unit != .weekend {
                    add(recent(unit, count: n), i...(i + 2)); i += 3; continue
                }
                if let unitKey = key(i + 1), let unit = Self.units[unitKey] {
                    add(period(unit, offset: offset), i...(i + 1)); i += 2; continue
                }
                if let next = key(i + 1), let word = Self.dateWords[next]?.0 {
                    let range = i...(i + 1)
                    switch word {
                    case .season(let season):
                        var interval: DateInterval?
                        if offset == 0 {
                            interval = season.current(at: now, calendar: calendar)
                        } else if let last = season.last(before: now, calendar: calendar) {
                            let lastYear = calendar.component(.year, from: last.start)
                            interval = offset == -2 ? season.occurrence(year: lastYear - 1, calendar: calendar) : last
                        }
                        var name: String?
                        if let interval {
                            let year = calendar.component(.year, from: interval.start)
                            name = season == .winter ? "\(year)/\(String((year + 1) % 100).leftPadded(2))" : String(year)
                        }
                        add(interval, range, label: name.map { "\(season.german) \($0)" }, labelEnglish: name.map { "\(season.english) \($0)" })
                        i += 2; continue
                    case .month(let m):
                        add(monthOccurrence(m, offset: offset), range); i += 2; continue
                    case .holiday(let h):
                        let year = calendar.component(.year, from: now)
                        var candidates = ((year - 3)...year).compactMap { h.window(year: $0, calendar: calendar) }
                        candidates = offset == 0 ? candidates.filter { calendar.component(.year, from: $0.start) == year } : candidates.filter { $0.end <= now }
                        let pick = offset == -2 ? candidates.dropLast().last : candidates.last
                        add(pick, range, label: pick.map { "\(h.german) \(calendar.component(.year, from: $0.start))" },
                            labelEnglish: pick.map { "\(h.english) \(calendar.component(.year, from: $0.start))" })
                        i += 2; continue
                    case .weekday(let w):
                        add(weekdayOccurrence(w, offset: offset), range); i += 2; continue
                    case .weekend:
                        add(period(.weekend, offset: offset), range); i += 2; continue
                    }
                }
            }
            // "24. Dezember", "December 24"
            if let entry = Self.dateWords[k], case .month(let m) = entry.0 {
                let wordLanguage = entry.1
                let dayBefore = number(i - 1).flatMap { (1...31).contains($0) && words[i - 1].key.allSatisfy(\.isNumber) ? $0 : nil }
                let dayAfter = number(i + 1).flatMap { (1...31).contains($0) && words[i + 1].key.allSatisfy(\.isNumber) ? $0 : nil }
                if let d = dayBefore ?? dayAfter {
                    let range = dayBefore != nil ? (i - 1)...i : i...(i + 1)
                    let german = "\(d). \(SearchDateFormat.month(m, english: false))"
                    let english = "\(SearchDateFormat.month(m, english: true)) \(d)"
                    drafts.append(Draft(alternatives: [.monthDay(month: m, day: d)], kind: .date, german: german, english: english, dimension: "monthDay",
                                        importance: 4, position: range.lowerBound, language: wordLanguage, end: range.upperBound))
                    for j in range { consumed[j] = true }
                    i = range.upperBound + 1; continue
                }
            }
            // A year.
            if k.count == 4, let y = Int(k), (1900...2100).contains(y) {
                drafts.append(Draft(alternatives: [.year(y)], kind: .year, german: k, english: k, dimension: "year", importance: 4,
                                    position: i, language: .neutral, end: i))
                consumed[i] = true
                i += 1; continue
            }
            i += 1
        }
        return drafts
    }

    /// The calendar day, week, month, year or weekend `offset` units from now.
    func period(_ unit: Unit, offset: Int) -> DateInterval? {
        switch unit {
        case .day: return calendar.date(byAdding: .day, value: offset, to: now).flatMap { calendar.dateInterval(of: .day, for: $0) }
        case .week: return calendar.date(byAdding: .weekOfYear, value: offset, to: now).flatMap { calendar.dateInterval(of: .weekOfYear, for: $0) }
        case .month: return calendar.date(byAdding: .month, value: offset, to: now).flatMap { calendar.dateInterval(of: .month, for: $0) }
        case .year: return calendar.date(byAdding: .year, value: offset, to: now).flatMap { calendar.dateInterval(of: .year, for: $0) }
        case .weekend:
            // Saturday and Sunday of that week.
            guard let week = calendar.date(byAdding: .weekOfYear, value: offset, to: now).flatMap({ calendar.dateInterval(of: .weekOfYear, for: $0) }) else { return nil }
            var day = week.start
            while day < week.end {
                if calendar.component(.weekday, from: day) == 7, let end = calendar.date(byAdding: .day, value: 2, to: day) { return DateInterval(start: day, end: end) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = next
            }
            return nil
        }
    }

    /// The last `count` days (including today), weeks, months or years up to now.
    func recent(_ unit: Unit, count: Int) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        let start: Date? = switch unit {
        case .day: calendar.date(byAdding: .day, value: -(count - 1), to: today)
        case .week: calendar.date(byAdding: .weekOfYear, value: -count, to: end)
        case .month: calendar.date(byAdding: .month, value: -count, to: end)
        case .year: calendar.date(byAdding: .year, value: -count, to: end)
        case .weekend: nil
        }
        return start.map { DateInterval(start: $0, end: end) }
    }

    /// "letzten Juli": the most recent July before this month; "diesen Juli": this year's.
    func monthOccurrence(_ month: Int, offset: Int) -> DateInterval? {
        let year = calendar.component(.year, from: now), current = calendar.component(.month, from: now)
        var y = offset == 0 ? year : (month < current ? year : year - 1)
        if offset == -2 { y -= 1 }
        return calendar.date(from: DateComponents(year: y, month: month, day: 1)).flatMap { calendar.dateInterval(of: .month, for: $0) }
    }

    /// "letzten Samstag": the most recent one before today; "diesen Samstag": in this week.
    func weekdayOccurrence(_ weekday: Int, offset: Int) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        if offset == 0 {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            var day = week.start
            while day < week.end {
                if calendar.component(.weekday, from: day) == weekday { return calendar.dateInterval(of: .day, for: day) }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? week.end
            }
            return nil
        }
        var back = offset == -2 ? 2 : 1
        var day = today
        while back > 0 {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = previous
            if calendar.component(.weekday, from: day) == weekday { back -= 1 }
        }
        return calendar.dateInterval(of: .day, for: day)
    }

    /// How a date written as numbers reads.
    enum Literal {
        case date(SearchCriterion, german: String, english: String)
        /// A date that does not exist ("29.2.2025", "31.4.") or that can be read two ways
        /// ("3/4/2025"): shown as not understood, never read as its year alone.
        case notUnderstood
    }

    /// Dates written as numbers: "24.12.2024", "24.12.", "2024-12-24", "12/24/2024", "2019–2021",
    /// and a winter over two years ("Winter 2025/26", as Albumist itself names it).
    /// They are cut out of the text so the numbers are not read again.
    private func literalDates(in text: inout String, ignored: inout [String]) -> [Draft] {
        var drafts: [Draft] = []
        let patterns: [(String, ([Int], [String]) -> Literal?)] = [
            // Before the year range, so "Winter 2025-2026" is one winter, not two years.
            (#"(?i)\bwinters?\s+(\d{4}|\d{2})\s*[/\-–]\s*(\d{4}|\d{2})\b"#, { g, typed in self.winter(g, typed) }),
            (#"\b((?:19|20)\d{2})\s*(?:-|–|bis|to|until)\s*((?:19|20)\d{2})\b"#, { g, _ in
                guard g[0] < g[1], g[1] - g[0] <= 50 else { return nil }
                let years = Array(g[0]...g[1])
                return .date(.any(years.map { .year($0) }), german: "\(g[0])–\(g[1])", english: "\(g[0])–\(g[1])")
            }),
            (#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, { g, _ in self.day(year: g[0], month: g[1], day: g[2]) }),
            (#"\b(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})\b"#, { g, _ in self.day(year: g[2] < 100 ? 2000 + g[2] : g[2], month: g[1], day: g[0]) }),
            // "12/24/2025" (US) and "24/12/2025" (UK): only when the order is plain.
            (#"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#, { g, _ in
                if g[0] == g[1] || g[1] > 12 { return self.day(year: g[2], month: g[0], day: g[1]) }
                if g[0] > 12 { return self.day(year: g[2], month: g[1], day: g[0]) }
                return .notUnderstood
            }),
            (#"\b(\d{1,2})\.(\d{1,2})\.(?!\d)"#, { g, _ in
                // The 29th of February exists, in leap years.
                guard case .date = self.day(year: 2000, month: g[1], day: g[0]) else { return .notUnderstood }
                return .date(.monthDay(month: g[1], day: g[0]), german: "\(g[0]).\(g[1]).", english: "\(g[1])/\(g[0])")
            }),
        ]
        var notUnderstood: [(position: Int, typed: String)] = []
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: text) else { continue }
                let typed = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
                let groups = typed.compactMap { Int($0) }
                guard groups.count == match.numberOfRanges - 1, let literal = make(groups, typed) else { continue }
                let position = Self.tokenize(String(text[..<whole.lowerBound])).count
                switch literal {
                case .notUnderstood:
                    notUnderstood.append((position, String(text[whole])))
                case .date(let criterion, let german, let english):
                    var alternatives = [criterion], dimension = "date"
                    if case .any(let years) = criterion { alternatives = years; dimension = "year" }
                    if case .monthDay = criterion { dimension = "monthDay" }
                    drafts.append(Draft(alternatives: alternatives, kind: .date, german: german, english: english, dimension: dimension, importance: 4,
                                        position: position, language: .neutral))
                }
                text.replaceSubrange(whole, with: String(repeating: " ", count: text[whole].count))
            }
        }
        ignored += notUnderstood.sorted { $0.position < $1.position }.map(\.typed)
        return drafts
    }

    /// "Winter 2025/26": December 2025 to February 2026. Two years that are not one winter
    /// ("Winter 2025/27") are not understood.
    private func winter(_ g: [Int], _ typed: [String]) -> Literal {
        let first = typed[0].count == 2 ? 2000 + g[0] : g[0]
        let second = typed[1].count == 2 ? first / 100 * 100 + g[1] + (g[1] < first % 100 ? 100 : 0) : g[1]
        guard second == first + 1, let interval = SearchSeason.winter.occurrence(year: first, calendar: calendar) else { return .notUnderstood }
        let name = "\(first)/\(String(format: "%02d", second % 100))"
        return .date(.dateRange(interval), german: "\(SearchSeason.winter.german) \(name)", english: "\(SearchSeason.winter.english) \(name)")
    }

    /// One calendar day, or not understood when the day does not exist ("29.2.2025").
    private func day(year: Int, month: Int, day: Int) -> Literal {
        guard (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month,
              let interval = calendar.dateInterval(of: .day, for: date) else { return .notUnderstood }
        return .date(.dateRange(interval), german: SearchDateFormat.day(date, english: false, calendar: calendar),
                     english: SearchDateFormat.day(date, english: true, calendar: calendar))
    }

    // MARK: Periods

    enum Bound { case from, after, before, through }

    /// Words that make the date after them a period open to one side.
    /// "from" is not one of them: "photos from 2024" are photos taken in 2024.
    static let periodWords: [String: (Bound, SearchLexicon.Language)] = [
        "seit": (.from, .german), "ab": (.from, .german), "nach": (.after, .german), "vor": (.before, .german), "bis": (.through, .german),
        "since": (.from, .english), "after": (.after, .english), "before": (.before, .english), "until": (.through, .english), "till": (.through, .english),
    ]
    /// "seit dem 24.12.2024", "bis zum 3.5.2025".
    static let periodArticles: Set<String> = ["dem", "den", "zum", "the"]

    /// "seit 2024", "vor Mai 2025", "bis zum 24.12.2024", "after last year": the date after the
    /// word becomes a period open to one side. Before a date that is no single period
    /// ("seit Weihnachten", "nach Mai") the word is shown as not understood, never dropped
    /// without a word so that the search would quietly show the date itself.
    private func periods(_ input: [Draft], words: [Word], consumed: inout [Bool], ignored: inout [String]) -> [Draft] {
        var drafts = input
        func isDate(_ d: Draft) -> Bool { d.kind == .date || d.kind == .year }
        func single(_ d: Draft) -> SearchCriterion? { d.alternatives.count == 1 ? d.alternatives[0] : nil }
        for (i, word) in words.enumerated() where !consumed[i] {
            guard let (bound, language) = Self.periodWords[word.key] else { continue }
            var next = i + 1
            if next < words.count, !consumed[next], Self.periodArticles.contains(words[next].key) { next += 1 }
            guard let first = drafts.firstIndex(where: { $0.position == next && isDate($0) }) else { continue }
            var used = [first]
            var interval: DateInterval?
            switch single(drafts[first]) {
            case .year(let y):
                interval = calendar.date(from: DateComponents(year: y, month: 1, day: 1)).flatMap { calendar.dateInterval(of: .year, for: $0) }
            case .dateRange(let range):
                interval = range
            case .month(let m):
                // "seit Mai 2025": the month of that year. A month alone is no single period.
                if let after = drafts[first].end.map({ $0 + 1 }), let y = drafts.firstIndex(where: { $0.position == after && isDate($0) }),
                   case .year(let year) = single(drafts[y]) {
                    used.append(y)
                    interval = calendar.date(from: DateComponents(year: year, month: m, day: 1)).flatMap { calendar.dateInterval(of: .month, for: $0) }
                }
            default:
                break
            }
            for j in i..<next { consumed[j] = true }
            guard let interval else {
                ignored.append(word.typed)
                continue
            }
            let period: DateInterval = switch bound {
            case .from: DateInterval(start: interval.start, end: .distantFuture)
            case .after: DateInterval(start: interval.end, end: .distantFuture)
            case .before: DateInterval(start: .distantPast, end: interval.start)
            case .through: DateInterval(start: .distantPast, end: interval.end)
            }
            // What the user typed, with the date as the search read it when it was written as numbers.
            let last = used.compactMap { drafts[$0].end }.max()
            var typed = words[i..<next].map(\.typed)
            if let last { typed += words[next...last].map(\.typed) } else { typed.append(language == .english ? drafts[first].english : drafts[first].german) }
            let text = typed.joined(separator: " ")
            let label = text.prefix(1).uppercased() + text.dropFirst()
            let open = bound == .from || bound == .after
            let shown = open ? period.start : period.end.addingTimeInterval(-1)
            let detailGerman = (open ? "ab " : "bis ") + SearchDateFormat.day(shown, english: false, calendar: calendar)
            let detailEnglish = (open ? "from " : "until ") + SearchDateFormat.day(shown, english: true, calendar: calendar)
            var draft = Draft(alternatives: [.dateRange(period)], kind: .date, german: label, english: label, dimension: "date", importance: 4,
                              position: i, language: language, end: last)
            draft.detailGerman = detailGerman
            draft.detailEnglish = detailEnglish
            for index in used.sorted(by: >) { drafts.remove(at: index) }
            drafts.append(draft)
        }
        return drafts
    }
}

private extension String {
    func leftPadded(_ length: Int) -> String { count >= length ? self : String(repeating: "0", count: length - count) + self }
}
