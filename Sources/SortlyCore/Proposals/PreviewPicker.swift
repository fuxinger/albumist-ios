import Foundation

/// Picks the photos a suggestion shows as its preview: spread evenly over its time span
/// (a trip shows its first day, its middle and its last evening, not eight photos from one
/// morning), oldest first, and always including the cover photo.
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

    public static func pick(_ ids: some Collection<AssetID>, dates: [AssetID: Date], cover: AssetID?, count: Int) -> [AssetID] {
        let ordered = chronological(ids, dates: dates)
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
}
