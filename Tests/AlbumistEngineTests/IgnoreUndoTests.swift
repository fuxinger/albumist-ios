import Foundation
import Testing
import AlbumistStore
import AlbumistCore
import AlbumistEngine
import AlbumistTestSupport

/// Design review D4 (15.11.2026): "Ignorieren" could not be taken back. The welcome screen
/// promises "…kannst alles rückgängig machen", so ignoring has a way back: "Widerrufen"
/// right after the action and "Nicht mehr ignorieren" in the "Ignoriert" area.
@Suite("Ignore and its way back")
struct IgnoreUndoTests {
    func store() throws -> AlbumistStore { try AlbumistStore(url: nil) }

    @Test func ignoringTwiceKeepsOneOverrideAndReportsOnlyNewPhotos() async throws {
        let s = try store()
        #expect(try await s.ignoreAssets(["a", "b"]) == ["a", "b"])
        // "a" again plus a new one: only "c" is new; "a" keeps its single override.
        #expect(try await s.ignoreAssets(["a", "c", "c"]) == ["c"])
        #expect(try await s.overrides().count == 3)
        #expect(try await s.ignoredAssets() == ["a", "b", "c"])
    }

    @Test func widerrufenRestoresOnlyWhatTheLastActionIgnored() async throws {
        let s = try store()
        try await s.ignoreAssets(["earlier"])
        let added = try await s.ignoreAssets(["earlier", "now-1", "now-2"])
        #expect(added == ["now-1", "now-2"])
        // "Widerrufen" passes exactly what the action added.
        #expect(try await s.unignoreAssets(added) == 2)
        #expect(try await s.ignoredAssets() == ["earlier"])
    }

    @Test func unignoreRemovesDuplicatesAndKeepsOtherDecisions() async throws {
        let s = try store()
        // Older versions wrote one override per tap, so a photo could be ignored twice.
        try await s.addOverride(UserOverride(scope: .asset("a"), decision: .ignoreAsset))
        try await s.addOverride(UserOverride(scope: .asset("a"), decision: .ignoreAsset))
        let neverAdd = UserOverride(scope: .assetInAlbum("a", "album"), decision: .neverAdd)
        let excluded = UserOverride(scope: .asset("a"), decision: .excludeFromAnalysis)
        let rejected = UserOverride(scope: .source(AlbumistID("p")), decision: .rejectProposal)
        for o in [neverAdd, excluded, rejected] { try await s.addOverride(o) }

        #expect(try await s.unignoreAssets(["a", "never-ignored"]) == 1)
        #expect(try await s.ignoredAssets().isEmpty)
        let left = Set(try await s.overrides().map(\.id))
        #expect(left == [neverAdd.id, excluded.id, rejected.id])
        // Nothing to do is no error.
        #expect(try await s.unignoreAssets([]) == 0)
        #expect(try await s.unignoreAssets(["a"]) == 0)
    }

    @Test func unignoredPhotoIsNoLongerShownAsIgnored() async throws {
        let s = try store()
        let asset = AssetSnapshot(id: "home", creationDate: Fixture.date("2026-03-01 10:00"), location: Fixture.Places.munichHome)
        let facts = [AssetFacts(asset: asset, place: PlaceComponents(isoCountryCode: "DE", country: "Deutschland", locality: "München"),
                                placeSource: .gpsReverseGeocoded)]
        var settings = OrganizationSettings()
        settings.primaryAreas = [.places]
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        func overall() async throws -> OverallStatus? {
            let states = LibraryStatus.compute(facts: facts, snapshot: nil, settings: settings,
                                               overrides: OverrideSet(try await s.overrides()), contentAnalyzed: ["home"])
            return states["home"].map(resolver.overall)
        }
        let before = try await overall()
        try await s.ignoreAssets(["home"])
        #expect(try await overall() == .ignored)
        try await s.unignoreAssets(["home"])
        #expect(try await overall() == before)
        #expect(before != .ignored)
    }

    @Test func ignoredAssetNamesOnlyIgnoreDecisions() {
        #expect(UserOverride(scope: .asset("a"), decision: .ignoreAsset).ignoredAsset == "a")
        #expect(UserOverride(scope: .asset("a"), decision: .excludeFromAnalysis).ignoredAsset == nil)
        #expect(UserOverride(scope: .assetInAlbum("a", "c"), decision: .neverAdd).ignoredAsset == nil)
    }
}
