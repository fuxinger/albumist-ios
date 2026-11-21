import Foundation
import Testing
@testable import AlbumistCore

/// Small findings of the design review (15.11.2026) whose logic lives in the core.
@Suite("Album covers and world share")
struct AlbumCoverAndWorldShareTests {
    /// N4: the album cover was the photo with the smallest id, a random photo.
    @Test func albumCoverIsTheNewestPhoto() {
        let day: TimeInterval = 86_400
        let dates: [AssetID: Date] = [
            "a-old": Date(timeIntervalSince1970: 1 * day),
            "z-new": Date(timeIntervalSince1970: 9 * day),
            "m-mid": Date(timeIntervalSince1970: 5 * day),
        ]
        #expect(PreviewPicker.newest(["a-old", "z-new", "m-mid", "undated"], dates: dates) == "z-new")
        // Same moment: the id decides, so the cover does not flip between launches.
        let tie: [AssetID: Date] = ["b": Date(timeIntervalSince1970: day), "a": Date(timeIntervalSince1970: day)]
        #expect(PreviewPicker.newest(["b", "a"], dates: tie) == PreviewPicker.newest(["a", "b"], dates: tie))
        // No dates at all still gives a cover; an empty album none.
        #expect(PreviewPicker.newest(["x", "y"], dates: [:]) != nil)
        #expect(PreviewPicker.newest([AssetID](), dates: dates) == nil)
    }

    /// N11: "Int(share * 100) %" showed one country as "0 % der Welt" and ignored the
    /// locale's percent style.
    @Test func worldShareKeepsSmallSharesAndTheLocaleStyle() {
        var atlas = TravelAtlas()
        atlas.countryCodes = ["IT"]
        let one = atlas.worldShare
        let german = one.formatted(TravelAtlas.worldShareStyle.locale(Locale(identifier: "de_DE")))
        let english = one.formatted(TravelAtlas.worldShareStyle.locale(Locale(identifier: "en_US")))
        #expect(german.hasPrefix("0,51"), "\(german)")
        #expect(german.hasSuffix("%"))
        #expect(english == "0.51%", "\(english)")
        atlas.countryCodes = Set((0..<23).map { "C\($0)" })
        let many = atlas.worldShare   // 11.79 %
        #expect(many.formatted(TravelAtlas.worldShareStyle.locale(Locale(identifier: "en_US"))) == "12%")
    }
}
