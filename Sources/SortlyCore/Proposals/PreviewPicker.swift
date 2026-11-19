import Foundation

/// How well a photo suits being shown for a suggestion or album: its preview photos, its cover
/// and the glow behind them, the list rows, the sorting show and the atlas share card. Nothing
/// is ever left out of an album or suggestion because of it; it only decides what is shown for
/// one (owner's iPhone, build 36: "Häufiger Ort in Zwiesel" showed a bank card with a readable
/// card number among its eight preview photos).
/// When in doubt a picture is hidden: privacy wins over a full preview (second review).
public enum PreviewRank: Int, Comparable, Sendable {
    /// An ordinary photo or video the image analysis has looked at.
    case photo
    /// Not looked at by the image analysis yet (or it could not read it): nothing says whether
    /// it is a card. Shown only when there are too few analysed ordinary photos, and never in
    /// the shared atlas image.
    case unknown
    /// A screenshot, or a picture the analysis took for a document whose text explains it as a
    /// harmless one (a letter, a ticket, a receipt): shown only when there are too few photos.
    case document
    /// A sensitive document: a bank card or statement, an ID or a medical paper, or a picture
    /// the image analysis took for a document that its text does not explain. Never shown as a
    /// preview, cover or in the sorting show; with too few other photos fewer tiles are shown.
    case sensitive

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// From what the analysis stored:
    /// - sensitive: document facts that say financial, ID or medical; a stored text with a
    ///   masked card number or IBAN, or with a financial or card word (`AssetFacts.
    ///   textLooksSensitive`: "Visa Debit" on a card whose number is on the back or was not
    ///   read); a picture the image analysis took for a document (no screenshot) without any
    ///   document facts: its text is not read yet, unreadable (glare, an angle), or names no
    ///   document type (an ID or medical paper, whose text is not stored);
    ///   any picture whose read text is empty without document facts (third review: an ID or
    ///   medical screenshot read by an older version was stored so), and a screenshot whose
    ///   text is not read yet or never (text reading off) and that nothing else explains.
    /// - document: screenshots, and documents their text explains.
    /// - unknown: not looked at by the image analysis yet.
    /// Cheap: no text is read here, so a whole library is ranked in no noticeable time.
    public init(_ facts: AssetFacts) {
        let explained = facts.document != nil || !facts.textCategories.isEmpty
        if (facts.document?.sensitivity ?? .normal) >= .financial || facts.textLooksSensitive {
            self = .sensitive
        } else if facts.document == nil && facts.recognizedText?.isEmpty == true {
            self = .sensitive
        } else if !explained && facts.asset.isScreenshotLike && facts.recognizedText == nil {
            self = .sensitive
        } else if !explained && facts.looksLikeDocument && !facts.asset.isScreenshotLike {
            self = .sensitive
        } else if facts.asset.isScreenshotLike || facts.looksLikeDocument || facts.document != nil
                    || !facts.textCategories.isEmpty {
            self = .document
        } else if !facts.contentKnown {
            self = .unknown
        } else {
            self = .photo
        }
    }

    /// The ranks a preview takes from, best first: sensitive documents never.
    static let shown: [PreviewRank] = [.photo, .unknown, .document]

    /// The rank of every photo of `facts` that is not an ordinary photo. A photo missing from
    /// the result ranks `.photo`, so most analysed libraries keep this small.
    public static func ranks(of facts: some Sequence<AssetFacts>) -> [AssetID: PreviewRank] {
        var ranks: [AssetID: PreviewRank] = [:]
        for f in facts {
            let rank = PreviewRank(f)
            if rank != .photo { ranks[f.id] = rank }
        }
        return ranks
    }
}

/// Picks the photos a suggestion shows as its preview: spread evenly over its time span
/// (a trip shows its first day, its middle and its last evening, not eight photos from one
/// morning), oldest first, and always including the cover photo.
///
/// Every pick takes the photos' `PreviewRank` (empty: all are ordinary photos): ordinary
/// photos first, documents and screenshots only for what is left, sensitive documents never.
/// A suggestion whose other photos are too few shows fewer tiles; its photo count stays.
public enum PreviewPicker {
    /// Photos taken less than this apart are one moment: a burst or a quick series of the same
    /// view fills one tile of the preview, not half of them.
    public static let momentGap: TimeInterval = 60

    /// All members in time order (undated last, ties by id so the order never jumps).
    public static func chronological(_ ids: some Collection<AssetID>, dates: [AssetID: Date]) -> [AssetID] {
        ids.sorted { a, b in
            switch (dates[a], dates[b]) {
            case let (x?, y?): x == y ? a < b : x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a < b
            }
        }
    }

    /// An album's cover photo: its newest photo, as Photos shows albums by default (design
    /// review N4: the smallest id was a random photo). Photos without a date only when none
    /// has one; equal dates fall back to the id, so the cover does not change between runs.
    /// The newest of the best-suited photos (`ranks`): `nil` when every photo is a sensitive
    /// document.
    public static func newest(_ ids: some Collection<AssetID>, dates: [AssetID: Date],
                              ranks: [AssetID: PreviewRank] = [:]) -> AssetID? {
        bestSuited(ids, ranks: ranks).max { a, b in
            switch (dates[a], dates[b]) {
            case let (x?, y?): x == y ? a > b : x < y
            case (nil, .some): true
            case (.some, nil): false
            case (nil, nil): a > b
            }
        }
    }

    /// The cover a suggestion shows (its row in the lists, the glow behind its photos, one of
    /// its preview photos): its own cover (`AlbumProposal.coverAssetID`) when that is one of
    /// its best-suited photos, otherwise its own stable choice among those, so suggestions keep
    /// covers of their own. Never a sensitive document; `nil` when every photo is one.
    public static func cover(_ ids: some Collection<AssetID>, preferred: AssetID?, proposal: SortlyID,
                             ranks: [AssetID: PreviewRank]) -> AssetID? {
        if let preferred, ids.contains(preferred) {
            switch ranks[preferred] ?? .photo {
            case .photo: return preferred
            // Not analysed yet, and no analysed ordinary photo to prefer (before the image
            // analysis, every photo): its own cover, without going through all of them twice.
            case .unknown where !ids.contains(where: { ranks[$0] == nil }): return preferred
            default: break
            }
        }
        let suited = bestSuited(ids, ranks: ranks)
        if let preferred, suited.contains(preferred) { return preferred }
        return AlbumProposal.cover(for: proposal, from: Set(suited))
    }

    /// The preview of a suggestion: `count` of `ids` spread evenly over their time (one per
    /// moment), oldest first, with `cover` when it may be shown. Ordinary photos fill it first,
    /// documents and screenshots only the tiles that are left, sensitive documents never: with
    /// too few other photos it has fewer than `count` tiles.
    public static func pick(_ ids: some Collection<AssetID>, dates: [AssetID: Date], cover: AssetID?, count: Int,
                            ranks: [AssetID: PreviewRank] = [:]) -> [AssetID] {
        var ordered = chronological(ids, dates: dates)
        if !ranks.isEmpty { ordered.removeAll { ranks[$0] == .sensitive } }
        guard count > 0, ordered.count > count else { return ordered }
        if ranks.isEmpty { return spread(ordered, dates: dates, cover: cover, count: count) }
        // Analysed ordinary photos first; then photos not analysed yet, then documents, each
        // spread over the tiles the better ones left.
        var chosen: [AssetID] = []
        for rank in PreviewRank.shown {
            let members = ordered.filter { ranks[$0] ?? .photo == rank }
            let left = count - chosen.count
            if members.count >= left {
                let spreadOut = spread(members, dates: dates, cover: cover, count: left)
                return chosen.isEmpty ? spreadOut : chronological(chosen + spreadOut, dates: dates)
            }
            chosen += members
        }
        return chronological(chosen, dates: dates)
    }

    /// `count` of `ordered` (oldest first) spread evenly over their time, with `cover` when it
    /// is one of them.
    static func spread(_ ordered: [AssetID], dates: [AssetID: Date], cover: AssetID?, count: Int) -> [AssetID] {
        guard count > 0, ordered.count > count else { return ordered }
        // One candidate per moment (its middle photo) when there are enough moments; otherwise
        // every photo, so a small suggestion still fills its preview.
        var moments: [[Int]] = []
        for index in ordered.indices {
            if let previous = moments.last?.last, let a = dates[ordered[previous]], let b = dates[ordered[index]],
               b.timeIntervalSince(a) < momentGap {
                moments[moments.count - 1].append(index)
            } else {
                moments.append([index])
            }
        }
        let candidates = moments.count >= count ? moments.map { $0[$0.count / 2] } : Array(ordered.indices)
        var indices = count == 1 ? [candidates[0]] : (0..<count).map { candidates[$0 * (candidates.count - 1) / (count - 1)] }
        if let cover, let coverIndex = ordered.firstIndex(of: cover), !indices.contains(coverIndex) {
            // The closest pick makes room for the cover; first and last stay when possible.
            let replace = indices.indices.min { abs(indices[$0] - coverIndex) < abs(indices[$1] - coverIndex) } ?? 0
            indices[replace] = coverIndex
            indices.sort()
        }
        return indices.map { ordered[$0] }
    }

    /// The first `count` of `ids`, in their order, that suit a showcase best: analysed ordinary
    /// photos, then photos not analysed yet, then documents and screenshots when there are too
    /// few; never sensitive documents. For a cover taken from a list (a planned album, a day of
    /// a trip) and the sorting show.
    public static func firstSuited(_ ids: some Sequence<AssetID>, count: Int, ranks: [AssetID: PreviewRank]) -> [AssetID] {
        guard count > 0 else { return [] }
        // Per rank of `PreviewRank.shown`: photos, not analysed yet, documents.
        var found: [[AssetID]] = [[], [], []]
        for id in ids {
            let rank = ranks[id] ?? .photo
            guard let tier = PreviewRank.shown.firstIndex(of: rank) else { continue }
            if found[tier].count < count { found[tier].append(id) }
            if tier == 0 && found[0].count == count { return found[0] }
        }
        return Array(found.joined().prefix(count))
    }

    /// `count` photos spread evenly over `items` in their order (the scan show's mosaic over the
    /// whole library): from each of `count` stretches its first ordinary photo (the last one
    /// from the last stretch), or else its first photo not analysed yet, then document or
    /// screenshot; a stretch of only sensitive documents is left out. Looks at no more than
    /// `stretchLimit` items of a stretch, not at the whole library. Without ranks exactly as
    /// before: every `count`-th item, first and last included.
    public static func evenly<C: RandomAccessCollection>(_ items: C, count: Int, ranks: [AssetID: PreviewRank],
                                                          id: (C.Element) -> AssetID) -> [AssetID] where C.Index == Int {
        guard count > 0, !items.isEmpty else { return [] }
        let n = items.count
        guard n > count else { return items.map(id).filter { ranks[$0] != .sensitive } }
        let starts = count == 1 ? [items.startIndex]
            : (0..<count).map { items.startIndex + $0 * (n - 1) / (count - 1) }
        // The first ordinary photo among `candidates`, else the first of the best rank there
        // (not analysed yet, then documents); never sensitive. At most `stretchLimit` items of
        // a stretch are looked at: before the image analysis no photo is known, and the mosaic
        // must not go through the whole library on every look.
        func choose(_ candidates: some Sequence<Int>) -> Int? {
            var best: (index: Int, rank: PreviewRank)?
            for index in candidates.prefix(stretchLimit) {
                let rank = ranks[id(items[index])] ?? .photo
                if rank == .photo { return index }
                if rank != .sensitive, best.map({ rank < $0.rank }) ?? true { best = (index, rank) }
            }
            return best?.index
        }
        var picked: [AssetID] = []
        // Nothing before this index may be picked again.
        var floor = items.startIndex
        for k in starts.indices {
            // The last stretch is looked at from the end back, so it still offers a photo when
            // the newest item is a document.
            let chosen = k == starts.count - 1 && count > 1
                ? choose((floor..<items.endIndex).reversed())
                : choose(max(starts[k], floor)..<(k + 1 < starts.count ? starts[k + 1] : items.endIndex))
            if let chosen {
                picked.append(id(items[chosen]))
                floor = chosen + 1
            }
        }
        return picked
    }

    /// How many items of one stretch `evenly` looks at, at most.
    static let stretchLimit = 256

    /// The number on the last tile of a preview ("+5"): the photos it does not show plus the
    /// one under the number. `total` counts every photo of the suggestion, also those a preview
    /// leaves out, so the number stays right when it shows fewer tiles. `nil`: nothing more.
    public static func moreCount(total: Int, shown: Int) -> Int? {
        guard shown > 0, total > shown else { return nil }
        return total - shown + 1
    }

    /// The photos of the best rank among `ids`: analysed ordinary photos when there are any,
    /// otherwise photos not analysed yet, then documents and screenshots; never sensitive ones.
    static func bestSuited(_ ids: some Collection<AssetID>, ranks: [AssetID: PreviewRank]) -> [AssetID] {
        guard !ranks.isEmpty else { return Array(ids) }
        var best = PreviewRank.sensitive
        var suited: [AssetID] = []
        for id in ids {
            let rank = ranks[id] ?? .photo
            guard rank < .sensitive, rank <= best else { continue }
            if rank < best {
                best = rank
                suited.removeAll()
            }
            suited.append(id)
        }
        return suited
    }
}
