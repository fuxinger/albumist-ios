import Foundation
import Testing
@testable import AlbumistCore

/// Design wave 1: the big covers of the photo cards try a short list of photos, best first, and
/// show the first one that is sharp on the device (`CoverPhoto` in the app). The order comes from
/// `PreviewPicker.coverCandidates`: the suggestion's own cover, then favourites, then the newest
/// ordinary photos; photos not analysed yet only after them; never a sensitive document, and
/// never a screenshot or another document (a big cover is a photo).
@Suite("Cover candidates of the photo cards")
struct CoverCandidatesTests {
    /// p00 is the newest, p39 the oldest: ids and dates run in opposite directions.
    let ids: [AssetID] = (0..<40).map { AssetID(String(format: "p%02d", $0)) }
    var dates: [AssetID: Date] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Date(timeIntervalSince1970: Double(1000 - $0) * 3600)) })
    }

    @Test func theCoverFirstThenTheNewestPhotos() {
        let candidates = PreviewPicker.coverCandidates(Set(ids), cover: "p17", dates: dates, ranks: [:])
        #expect(candidates == ["p17", "p00", "p01", "p02"])
    }

    @Test func withoutACoverTheNewestPhotoLeadsAsInAnAlbum() {
        let candidates = PreviewPicker.coverCandidates(ids, cover: nil, dates: dates, ranks: [:], count: 3)
        #expect(candidates == ["p00", "p01", "p02"])
        // The same photo `newest` takes for an album's cover.
        #expect(candidates.first == PreviewPicker.newest(ids, dates: dates))
    }

    @Test func favouritesComeRightAfterTheCover() {
        let candidates = PreviewPicker.coverCandidates(ids, cover: "p17", dates: dates, ranks: [:], favorites: ["p30", "p20"])
        #expect(candidates == ["p17", "p20", "p30", "p00"])
        // A favourite cover is not listed twice.
        #expect(PreviewPicker.coverCandidates(ids, cover: "p20", dates: dates, ranks: [:], favorites: ["p20"]) == ["p20", "p00", "p01", "p02"])
    }

    @Test func neverASensitiveDocumentAScreenshotOrADocument() {
        let ranks: [AssetID: PreviewRank] = ["p00": .sensitive, "p01": .document, "p02": .document, "p03": .sensitive]
        let candidates = PreviewPicker.coverCandidates(ids, cover: nil, dates: dates, ranks: ranks)
        #expect(candidates == ["p04", "p05", "p06", "p07"])
        // Not even as the suggestion's own cover, nor as a favourite.
        let withCover = PreviewPicker.coverCandidates(ids, cover: "p01", dates: dates, ranks: ranks, favorites: ["p00", "p02"])
        #expect(withCover == ["p04", "p05", "p06", "p07"])
    }

    @Test func aSuggestionOfOnlyScreenshotsAndDocumentsHasNoCandidates() {
        let few: [AssetID] = ["p00", "p01", "p02"]
        let ranks: [AssetID: PreviewRank] = ["p00": .document, "p01": .document, "p02": .sensitive]
        #expect(PreviewPicker.coverCandidates(few, cover: "p00", dates: dates, ranks: ranks).isEmpty)
    }

    @Test func photosNotAnalysedYetOnlyAfterTheAnalysedOnes() {
        var ranks: [AssetID: PreviewRank] = [:]
        for id in ids where id != "p30" && id != "p35" { ranks[id] = .unknown }
        // Two analysed photos lead, then the newest photos not analysed yet.
        #expect(PreviewPicker.coverCandidates(ids, cover: nil, dates: dates, ranks: ranks) == ["p30", "p35", "p00", "p01"])
        // A cover not analysed yet leads the photos not analysed yet, not the analysed ones.
        #expect(PreviewPicker.coverCandidates(ids, cover: "p10", dates: dates, ranks: ranks) == ["p30", "p35", "p10", "p00"])
    }

    @Test func beforeTheImageAnalysisEveryPhotoCanBeTheCover() {
        // During the first analysis no photo is analysed yet: the trip cards still get photos (9A).
        let ranks = Dictionary(uniqueKeysWithValues: ids.map { ($0, PreviewRank.unknown) })
        #expect(PreviewPicker.coverCandidates(ids, cover: "p12", dates: dates, ranks: ranks) == ["p12", "p00", "p01", "p02"])
    }

    @Test func aCoverThatIsNotAMemberIsLeftOut() {
        let candidates = PreviewPicker.coverCandidates(["p05", "p06"], cover: "p01", dates: dates, ranks: [:])
        #expect(candidates == ["p05", "p06"])
    }

    @Test func stableWhateverTheOrderAndForEqualDates() {
        var sameTime = dates
        // Newer than every other photo.
        let moment = Date(timeIntervalSince1970: 9_000_000)
        for id in ["p03", "p01", "p02"] as [AssetID] { sameTime[id] = moment }
        sameTime["p00"] = nil
        let forward = PreviewPicker.coverCandidates(ids, cover: nil, dates: sameTime, ranks: [:], count: 5)
        let backward = PreviewPicker.coverCandidates(Array(ids.reversed()), cover: nil, dates: sameTime, ranks: [:], count: 5)
        let shuffled = PreviewPicker.coverCandidates(Set(ids), cover: nil, dates: sameTime, ranks: [:], count: 5)
        #expect(forward == backward)
        #expect(forward == shuffled)
        // The three photos of the same moment by id, the undated one last of all.
        let all = PreviewPicker.coverCandidates(ids, cover: nil, dates: sameTime, ranks: [:], count: 40)
        #expect(Array(all.prefix(3)) == ["p01", "p02", "p03"])
        #expect(all.last == "p00")
        #expect(all.count == 40)
    }

    @Test func emptyNoneAskedAndDuplicates() {
        #expect(PreviewPicker.coverCandidates([AssetID](), cover: nil, dates: dates, ranks: [:]).isEmpty)
        #expect(PreviewPicker.coverCandidates(ids, cover: "p01", dates: dates, ranks: [:], count: 0).isEmpty)
        #expect(PreviewPicker.coverCandidates(["p02", "p02", "p01"], cover: nil, dates: dates, ranks: [:]) == ["p01", "p02"])
        #expect(PreviewPicker.coverCandidates(["p07"], cover: "p07", dates: dates, ranks: [:]) == ["p07"])
    }

    @Test func aSuggestionOfThousandsOfPhotos() {
        let many = (0..<3000).map { AssetID(String(format: "m%04d", $0)) }
        let manyDates = Dictionary(uniqueKeysWithValues: many.enumerated().map { ($1, Date(timeIntervalSince1970: Double($0) * 60)) })
        var ranks: [AssetID: PreviewRank] = [:]
        // The newest ten are screenshots: the candidates are the newest ordinary photos.
        for id in many.suffix(10) { ranks[id] = .document }
        let candidates = PreviewPicker.coverCandidates(Set(many), cover: "m0100", dates: manyDates, ranks: ranks)
        #expect(candidates == ["m0100", "m2989", "m2988", "m2987"])
    }
}
