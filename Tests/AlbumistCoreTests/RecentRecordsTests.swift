import Testing
@testable import AlbumistCore

/// The records behind a video's length on its thumbnail and the photo view's waiting thumbnail
/// (design wave 3, DS-16, DS-18) keep what was looked at last (review F, F14): past their limit
/// the older half goes, not all of them. Emptied whole, a fast scroll through a large library
/// lost them several times: a photo whose thumbnail was still in memory then opened on a black
/// page, and a video's thumbnail lost its length.
@Suite("Recent records: past the limit the older half goes")
struct RecentRecordsTests {
    static func filled(limit: Int, _ keys: [String]) -> RecentRecords<Int> {
        var records = RecentRecords<Int>(limit: limit)
        for (index, key) in keys.enumerated() { records[key] = index }
        return records
    }

    /// Up to the limit everything stays; one more lets the older half go, the newer half and the
    /// new record stay.
    @Test func pastTheLimitTheOlderHalfGoes() {
        var records = Self.filled(limit: 4, ["a", "b", "c", "d"])
        #expect(records.count == 4)
        #expect(records["a"] == 0)
        records["e"] = 4
        #expect(records.count == 3)
        #expect(records["a"] == nil && records["b"] == nil)
        #expect(records["c"] == 2 && records["d"] == 3 && records["e"] == 4)
    }

    /// A record set again counts as the latest: it stays when the older half goes.
    @Test func aRecordSetAgainIsRecent() {
        var records = Self.filled(limit: 4, ["a", "b", "c", "d"])
        records["a"] = 10
        records["e"] = 4
        #expect(records["a"] == 10 && records["d"] == 3 && records["e"] == 4)
        #expect(records["b"] == nil && records["c"] == nil)
    }

    /// A record changed at the limit lets nothing go: the count does not grow.
    @Test func aChangedRecordLetsNothingGo() {
        var records = Self.filled(limit: 2, ["a", "b"])
        records["b"] = 7
        #expect(records.count == 2)
        #expect(records["a"] == 0 && records["b"] == 7)
    }

    /// Records go one by one (nil) or all at once (a memory warning).
    @Test func recordsCanGo() {
        var records = Self.filled(limit: 10, ["a", "b", "c"])
        records["b"] = nil
        #expect(records.count == 2 && records["b"] == nil)
        records.removeAll()
        #expect(records.count == 0 && records["a"] == nil)
    }

    /// A long scroll through a large library: the newest half is always there.
    @Test func aLongScrollKeepsTheNewestHalf() {
        var records = RecentRecords<Int>(limit: 1000)
        for index in 0..<10_000 { records["\(index)"] = index }
        #expect(records.count <= 1000)
        #expect(records.count >= 500)
        for index in 9500..<10_000 { #expect(records["\(index)"] == index) }
    }
}
