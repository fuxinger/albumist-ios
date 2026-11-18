import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// "Mit Beispielfotos ausprobieren" (K6, option 1): offered only for an empty or nearly empty
/// library, and "Beispielfotos wieder entfernen" deletes only Albumist's own sample photos and
/// the albums it made of nothing but them.
@Suite("Sample photos")
struct SampleLibraryTests {
    let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    func album(_ id: String, _ title: String, _ assets: Set<AssetID>) -> ConfirmedProposal {
        ConfirmedProposal(proposal: AlbumProposal(id: SortlyID(id), kind: .trip, title: title, folderPath: ["Reisen"], assetIDs: assets),
                          decision: .createNew(title: nil, folderPath: nil))
    }

    // MARK: When they are offered

    @Test func offeredOnlyForAnEmptyOrNearlyEmptyLibrary() {
        #expect(SampleLibrary.isOffered(photos: 0, access: .full, samplesPresent: false))
        #expect(SampleLibrary.isOffered(photos: 6, access: .full, samplesPresent: false))
        #expect(SampleLibrary.isOffered(photos: SampleLibrary.nearlyEmptyLimit - 1, access: .full, samplesPresent: false))
        // A normal library never sees the offer.
        #expect(!SampleLibrary.isOffered(photos: SampleLibrary.nearlyEmptyLimit, access: .full, samplesPresent: false))
        #expect(!SampleLibrary.isOffered(photos: 5_683, access: .full, samplesPresent: false))
        // Not twice, and not with a selection of photos (albums need full access).
        #expect(!SampleLibrary.isOffered(photos: 0, access: .full, samplesPresent: true))
        #expect(!SampleLibrary.isOffered(photos: 0, access: .limited, samplesPresent: false))
        #expect(!SampleLibrary.isOffered(photos: 0, access: .denied, samplesPresent: false))
    }

    @Test func specsAreFixedWithDateAndPlace() {
        let specs = SampleLibrary.specs()
        #expect(specs == SampleLibrary.specs())
        #expect(specs.count == 78)
        #expect(Set(specs.map(\.filename)).count == specs.count)
        #expect(specs.allSatisfy { $0.location.latitude != 0 })
        #expect(Set(specs.map(\.scene)) == Set(SampleLibrary.Scene.allCases))
    }

    // MARK: Removal

    /// The user's own photos and albums next to the sample photos and Albumist's sample albums.
    @Test func removalDeletesOnlyTheSamplePhotosAndAlbumsMadeOfThem() async throws {
        let mine: Set<AssetID> = ["mine-1", "mine-2"]
        let samples: Set<AssetID> = Set((1...20).map { AssetID("s-\($0)") })
        let library = InMemoryPhotoLibrary(assets: mine.union(samples), collections: [
            CollectionSnapshot(id: "family", title: "Familie", assetIDs: mine),
            // The user's own album with sample photos only: Albumist did not make it.
            CollectionSnapshot(id: "own", title: "Test", assetIDs: ["s-1"]),
        ])
        let executor = ChangeExecutor(library: library, store: InMemoryPlanStore())
        // Plan 1: two albums of sample photos. Plan 2: an album with a sample and a user photo.
        let first = try await executor.execute(confirmed(planner.makePlan(from: [
            album("rom", "Rom", Set((1...10).map { AssetID("s-\($0)") })),
            album("lis", "Lissabon", Set((11...20).map { AssetID("s-\($0)") })),
        ], inventory: try await library.currentInventory())))
        let second = try await executor.execute(confirmed(planner.makePlan(from: [album("mix", "Gemischt", ["s-3", "mine-1"])],
                                                                                inventory: try await library.currentInventory())))
        let inventory = try await library.currentInventory()
        let tracker = ManagedAlbumTracker()
        let states = tracker.record(second, into: tracker.record(first, into: [], inventory: inventory), inventory: inventory)
        let id = { (title: String) in inventory.albums.first { $0.title == title }!.id }
        let reisen = try #require(inventory.collections.values.first { $0.title == "Reisen" && $0.kind == .folder }).id

        let removal = SampleLibrary.removal(sampleIDs: samples, libraryAssets: await library.assets, managedAlbums: states,
                                            inventory: inventory, history: [second, first])
        #expect(removal.assets == samples.sorted())
        #expect(Set(removal.albums) == [id("Rom"), id("Lissabon")])
        // "Reisen" still holds "Gemischt": it stays.
        #expect(!removal.albums.contains(reisen))
        #expect(removal.plansToGiveBack == [first.id])
        // The change itself kept "Lissabon" (P2-05): plan 1 still has an album in Photos and
        // keeps its count; it is given back only once both are gone.
        #expect(SampleLibrary.plansToGiveBack(history: [second, first], gone: [id("Rom")]).isEmpty)
        #expect(SampleLibrary.plansToGiveBack(history: [second, first], gone: [id("Rom"), id("Lissabon")]) == [first.id])
        #expect(!removal.assets.contains { mine.contains($0) })
        #expect(!removal.albums.contains("family") && !removal.albums.contains("own") && !removal.albums.contains(id("Gemischt")))

        // Carried out: the user's photos and albums are all still there.
        try await library.deleteCollections(removal.albums)
        let after = try await library.currentInventory()
        #expect(after["family"]?.assetIDs == mine)
        #expect(after["own"] != nil)
        #expect(after[id("Gemischt")] != nil)
        #expect(after[id("Rom")] == nil && after[id("Lissabon")] == nil)
    }

    /// Only the sample albums in Albumist's folder: the folder goes too, after its albums.
    @Test func emptyFolderOfSampleAlbumsGoesAfterThem() async throws {
        let samples: Set<AssetID> = Set((1...10).map { AssetID("s-\($0)") })
        let library = InMemoryPhotoLibrary(assets: samples)
        let plan = try await ChangeExecutor(library: library, store: InMemoryPlanStore())
            .execute(confirmed(planner.makePlan(from: [album("rom", "Rom", samples)], inventory: CollectionInventory())))
        let inventory = try await library.currentInventory()
        let states = ManagedAlbumTracker().record(plan, into: [], inventory: inventory)
        let removal = SampleLibrary.removal(sampleIDs: samples, libraryAssets: nil, managedAlbums: states, inventory: inventory, history: [plan])
        let folder = try #require(inventory.collections.values.first { $0.kind == .folder }).id
        #expect(removal.albums.last == folder)
        #expect(removal.albums.count == 2)
    }

    /// Sample photos the user already deleted in Photos are not asked about again; an album
    /// the user put an own photo into stays.
    @Test func removalAfterTheUserChangedThings() {
        let samples: Set<AssetID> = ["s-1", "s-2", "s-3"]
        let state = ManagedAlbumState(albumID: "rom", sourceID: SortlyID("p"), lastKnownTitle: "Rom", lastKnownParentID: nil,
                                      lastKnownMembers: samples, addedBySortly: samples, createdBySortly: true)
        let inventory = CollectionInventory([CollectionSnapshot(id: "rom", title: "Rom", assetIDs: ["s-1", "mine"])])
        let removal = SampleLibrary.removal(sampleIDs: samples, libraryAssets: ["s-1", "mine"], managedAlbums: [state],
                                            inventory: inventory, history: [])
        #expect(removal.assets == ["s-1"])
        #expect(removal.albums.isEmpty)
        // Nothing written down: nothing to delete.
        #expect(SampleLibrary.removal(sampleIDs: [], libraryAssets: ["mine"], managedAlbums: [state], inventory: inventory, history: []).isEmpty)
    }
}

/// Review of 3022ca8: a cut-off add, removal only with full access and no plan in progress,
/// and folders checked again against what Photos has inside them right then.
@Suite("Sample photos: review fixes")
struct SampleLibraryReviewTests {
    @Test func cutOffAddKeepsTheOfferAwayAndRemovesWhatWasWrittenDown() {
        var record = SampleLibrary.Record()
        #expect(!record.hasSamples)
        record.begin()
        // The app ends before the first chunk is written down: no second offer (no duplicates).
        #expect(record.hasSamples)
        #expect(!SampleLibrary.isOffered(photos: 3, access: .full, samplesPresent: record.hasSamples))
        record.record(["s1", "s2"])
        // Removal: what is gone is forgotten; with nothing left the offer may come back.
        var partly = record
        partly.keepOnly(["s2"])
        #expect(partly.ids == ["s2"] && partly.hasSamples)
        record.keepOnly([])
        #expect(record == SampleLibrary.Record())
        #expect(SampleLibrary.isOffered(photos: 3, access: .full, samplesPresent: record.hasSamples))
    }

    @Test func removalNeedsFullAccessAndNoPlanInProgress() {
        #expect(SampleLibrary.removalBlock(access: .full, planRunning: false, planInterrupted: false) == nil)
        #expect(SampleLibrary.removalBlock(access: .limited, planRunning: false, planInterrupted: false) == .needsFullAccess)
        #expect(SampleLibrary.removalBlock(access: .denied, planRunning: false, planInterrupted: false) == .needsFullAccess)
        #expect(SampleLibrary.removalBlock(access: .full, planRunning: true, planInterrupted: false) == .planInProgress)
        #expect(SampleLibrary.removalBlock(access: .full, planRunning: false, planInterrupted: true) == .planInProgress)
    }

    @Test func folderGoesOnlyWhileEverythingInsideItGoes() {
        // "Reisen" holds two sample albums; "Albumist" holds "Reisen".
        let folders = ["reisen": ["rom", "lis"], "albumist": ["reisen"]]
        #expect(SampleLibrary.foldersSafeToDelete(folders, deletingAlbums: ["rom", "lis"]) == ["reisen", "albumist"])
        // The user put an own album into "Reisen" after the list was read: neither folder goes.
        let now = ["reisen": ["rom", "lis", "mine"], "albumist": ["reisen"]]
        #expect(SampleLibrary.foldersSafeToDelete(now, deletingAlbums: ["rom", "lis"]).isEmpty)
        // A second folder next to it keeps "Albumist".
        let side = ["reisen": ["rom"], "albumist": ["reisen", "familie"]]
        #expect(SampleLibrary.foldersSafeToDelete(side, deletingAlbums: ["rom"]) == ["reisen"])
    }

    // MARK: Checked again inside the deletion (review P2-05)

    func seen(_ spec: SampleLibrary.Spec, name: String? = nil, plus seconds: TimeInterval = 0) -> SampleLibrary.Seen {
        SampleLibrary.Seen(filename: name ?? spec.filename, created: spec.date.addingTimeInterval(seconds))
    }

    @Test func aPhotoIsASamplePhotoOnlyWithItsNameAndItsDate() {
        let specs = SampleLibrary.specs()
        for spec in specs {
            #expect(SampleLibrary.isSample(seen(spec)))
        }
        let first = specs[0], second = specs[1]
        // The right name with another date (the user changed it, or a photo of their own
        // happens to carry the name), the date of another sample photo, no date at all.
        #expect(!SampleLibrary.isSample(seen(first, plus: 3600)))
        #expect(!SampleLibrary.isSample(SampleLibrary.Seen(filename: first.filename, created: second.date)))
        #expect(!SampleLibrary.isSample(SampleLibrary.Seen(filename: first.filename, created: nil)))
        // The right date with another name, a name only like a sample photo's, no name.
        #expect(!SampleLibrary.isSample(seen(first, name: "IMG_0001.HEIC")))
        #expect(!SampleLibrary.isSample(seen(first, name: "Albumist-Beispiel-999.jpg")))
        #expect(!SampleLibrary.isSample(seen(first, name: "albumist-beispiel-001.jpg")))
        #expect(!SampleLibrary.isSample(SampleLibrary.Seen(filename: nil, created: first.date)))
        // Photos keeps the date to the second: a fraction of a second off is still the photo.
        #expect(SampleLibrary.isSample(seen(first, plus: 0.4)))
    }

    @Test func aForeignIdInTheRecordNeverDeletesThePhotoNorItsAlbumNorTheFolder() {
        let specs = SampleLibrary.specs()
        // "own" is the user's photo whose id got into the record by mistake.
        let photos = ["s1": seen(specs[0]), "s2": seen(specs[1]),
                      "own": SampleLibrary.Seen(filename: "IMG_4711.HEIC", created: specs[2].date)]
        let albums: [String: Set<String>] = ["rom": ["s1", "s2"], "lis": ["s2", "own"]]
        let folders = ["reisen": ["rom", "lis"], "albumist": ["reisen"], "andere": ["rom"]]
        let checked = SampleLibrary.checkedDeletion(photos: photos, albums: albums, folders: folders)
        #expect(checked.assets == ["s1", "s2"])
        #expect(checked.kept == ["own"])
        // "lis" holds the photo that stays, so it stays, and so do the folders above it.
        #expect(checked.collections == ["rom", "andere"])
    }

    @Test func everythingThatIsSurelyASampleGoesInOneChange() {
        let specs = SampleLibrary.specs()
        let photos = Dictionary(uniqueKeysWithValues: specs.prefix(4).map { ("id\($0.index)", seen($0)) })
        let checked = SampleLibrary.checkedDeletion(photos: photos, albums: ["rom": ["id1", "id2"], "lis": ["id3"]],
                                                    folders: ["reisen": ["rom", "lis"], "albumist": ["reisen"]])
        #expect(checked.assets == Set(photos.keys))
        #expect(checked.kept.isEmpty)
        #expect(checked.collections == ["rom", "lis", "reisen", "albumist"])
        // Nothing found in Photos (an empty or emptied library): nothing goes.
        let none = SampleLibrary.checkedDeletion(photos: [:], albums: [:], folders: [:])
        #expect(none.assets.isEmpty && none.collections.isEmpty && none.kept.isEmpty)
    }
}
