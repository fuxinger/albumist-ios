import Foundation

/// The pages a full-screen photo viewer builds at once (review 18.11. P4-11): the photos
/// around the one shown, not every photo of the list (the library hands over 3,000 and, after
/// scrolling on, 6,000 or 9,000). The window moves on while the user swipes, so every photo
/// can still be reached; it is rebuilt only near its edge, so the pages next to the photo
/// shown stay as they are while the user swipes inside it.
public struct PageWindow: Hashable, Sendable {
    /// Positions in the list of photos, `lowerBound..<upperBound`.
    public private(set) var range: Range<Int>
    /// Pages before and after the photo shown.
    public static let radius = 50
    /// The window moves on once fewer pages than this are left before its edge.
    public static let margin = 10

    /// The window centred on `index` (clamped to the list), cut off at both ends of the list.
    public init(around index: Int, count: Int) {
        guard count > 0 else {
            range = 0..<0
            return
        }
        let index = min(max(index, 0), count - 1)
        range = max(index - Self.radius, 0)..<min(index + Self.radius + 1, count)
    }

    /// The window once the photo at `index` shows: the same while it is more than `margin`
    /// pages inside (or the window reaches the end of the list on that side), otherwise
    /// centred on it again.
    public func following(_ index: Int, count: Int) -> PageWindow {
        guard range.contains(index), range.upperBound <= count else { return PageWindow(around: index, count: count) }
        let nearStart = index - range.lowerBound < Self.margin && range.lowerBound > 0
        let nearEnd = range.upperBound - 1 - index < Self.margin && range.upperBound < count
        return nearStart || nearEnd ? PageWindow(around: index, count: count) : self
    }
}
