import Foundation
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistStore
import AlbumistWorldMap
import AlbumistTestSupport

/// Review P1-07: switched to "Ausgewählte Fotos" and back to "Alle Fotos", every photo
/// Albumist could not see meanwhile was deleted from the store with its analysis, places and
/// text (`removeAssets(notIn:)`, `ON DELETE CASCADE`), and analysed again from the start: hours
/// on a large library. Photos Albumist cannot see right now are kept, set aside, and come back
/// with what was found about them; only full access may delete a photo for good.
@Suite("Selected photos and back")
struct SelectedPhotosTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct World {
        var store: AlbumistStore
        var reader: InMemoryLibraryReader
        var pipeline: AnalysisPipeline
        var analyzer: FakeContentAnalyzer
        var geocoder: FakeGeocoder
    }

    /// The review's library: Munich everyday life, a trip to Rome and one to Basel (217 photos).
    typealias Library = (assets: [AssetSnapshot], home: [AssetID], rome: [AssetID], basel: [AssetID])

    static func library() -> Library {
        libraryWithScreenshots(0).lib
    }

    /// `library()` and `count` screenshots after it.
    static func libraryWithScreenshots(_ count: Int = 4) -> (lib: Library, screenshots: [AssetID]) {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2026-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 1,
                             skipping: [("2026-05-12", "2026-05-19"), ("2026-03-10", "2026-03-15")])
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-19", at: Fixture.Places.rome, perDay: 4, hour: 10)
        let basel = lib.daily(from: "2026-03-10", to: "2026-03-15", at: GeoCoordinate(latitude: 47.5903, longitude: 7.5893), perDay: 3, hour: 11)
        let shots = (0..<count).map { lib.photo(at: Fixture.date("2026-06-0\($0 + 1) 20:00"), nil, subtypes: .screenshot) }
        return ((lib.assets, home, rome, basel), shots)
    }

    static func world(_ assets: [AssetSnapshot], inventory: CollectionInventory = CollectionInventory(),
                      store: AlbumistStore? = nil) throws -> World {
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try store ?? AlbumistStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets, inventory: inventory)
        // Every screenshot reads "Rechnung" and its own number.
        let analyzer = FakeContentAnalyzer(text: { "Rechnung Hotel Nummer\($0.id.rawValue.suffix(3))" })
        let geocoder = FakeGeocoder()
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: analyzer, geocoder: geocoder, map: Self.map,
            conditions: FakeConditions(), settings: settings, calendar: Fixture.calendar, time: ManualTime().source,
            now: { Fixture.date("2026-07-01 12:00") }, earlyGraceOnStop: .seconds(60))
        return World(store: store, reader: reader, pipeline: pipeline, analyzer: analyzer, geocoder: geocoder)
    }

    /// The review's test: 217 photos analysed, then a selection of 10, then all again.
    /// Before: 207 photos analysed again and 207 places looked up again.
    @Test func switchingToSelectedPhotosAndBackKeepsTheAnalysis() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        let first = try await w.pipeline.run()
        #expect(first.isComplete)
        #expect(first.contentAnalyzed == lib.assets.count)
        try await w.store.addOverride(UserOverride(scope: .asset(lib.home[20]), decision: .ignoreAsset))
        let overrides = try await w.store.overrides()
        let placesBefore = try await w.store.places().count
        let looksBefore = w.analyzer.counts.withLock { $0.content }
        let lookupsBefore = w.geocoder.calls.count
        let suggestions = Self.suggestions(try await w.pipeline.latestProposals())
        #expect(!suggestions.isEmpty)

        await w.reader.set(access: .limited)
        await w.reader.set(assets: Array(lib.assets.prefix(10)))
        let limited = try await w.pipeline.run()
        #expect(limited.isComplete)
        #expect(limited.removed == 0, "\(limited.removed) photos deleted from the store under limited access")
        #expect(limited.setAside == lib.assets.count - 10)
        #expect(limited.contentAnalyzed == 0)

        await w.reader.set(access: .full)
        await w.reader.set(assets: lib.assets)
        let back = try await w.pipeline.run()
        #expect(back.isComplete)
        #expect(back.contentAnalyzed == 0, "\(back.contentAnalyzed) of \(lib.assets.count) photos analysed again")
        #expect(back.placesResolved == 0, "\(back.placesResolved) places resolved again")
        #expect(back.newOrChanged == 0)
        #expect(w.analyzer.counts.withLock { $0.content } == looksBefore)
        #expect(w.geocoder.calls.count == lookupsBefore, "\(w.geocoder.calls.count - lookupsBefore) new place lookups")
        #expect(try await w.store.places().count == placesBefore)
        #expect(try await w.store.overrides() == overrides)
        #expect(back.removed == 0)
        #expect(try await w.store.outOfViewCount() == 0)
        #expect(try await w.store.assetCount() == lib.assets.count)
        // The same suggestions as before, with the same photos.
        #expect(Self.suggestions(try await w.pipeline.latestProposals()) == suggestions)
    }

    static func suggestions(_ snapshot: ProposalSnapshot?) -> [String: Set<AssetID>] {
        Dictionary((snapshot?.proposals ?? []).map { ($0.id.rawValue, $0.assetIDs) }, uniquingKeysWith: { a, _ in a })
    }

    /// The trip to Rome, 60 days at home and two screenshots are shared; everything else is
    /// set aside.
    static func selection(_ lib: Library, screenshots: [AssetID]) -> Set<AssetID> {
        Set(lib.rome + lib.home.prefix(60) + screenshots.prefix(2))
    }

    /// Every photo in a plan made from the suggestions (each one as a new album).
    static func plannedAssets(_ w: World) async throws -> (added: Set<AssetID>, removed: Set<AssetID>) {
        let proposals = try await w.pipeline.latestProposals()?.proposals ?? []
        let plan = OrganizationPlanner().makePlan(
            from: proposals.map { ConfirmedProposal(proposal: $0, decision: .createNew(title: nil, folderPath: nil), acceptedOptional: $0.optionalAssetIDs) },
            inventory: try await w.store.loadInventory())
        var added = Set<AssetID>(), removed = Set<AssetID>()
        for step in plan.steps {
            switch step.operation {
            case .addAssets(_, let assets): added.formUnion(assets)
            case .removeAssets(_, let assets): removed.formUnion(assets)
            default: break
            }
        }
        return (added, removed)
    }

    /// While only the selection is shared, nothing of the other photos shows: not in the
    /// photos, results, places, search, suggestions, counts, albums or plans. Nothing is
    /// looked at again for it, and the user's decisions stay.
    @Test func photosOutsideTheSelectionAreNowhereWhileLimited() async throws {
        let (lib, shots) = Self.libraryWithScreenshots()
        let album = CollectionSnapshot(id: "album-rome", title: "Rom", assetIDs: Set(lib.rome.prefix(10) + lib.basel.prefix(3)))
        let w = try Self.world(lib.assets, inventory: CollectionInventory([album]))
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await w.store.searchText("Rechnung").count == shots.count)
        let hiddenIgnored = lib.basel[0], shownIgnored = lib.rome[0]
        for id in [hiddenIgnored, shownIgnored] { try await w.store.addOverride(UserOverride(scope: .asset(id), decision: .ignoreAsset)) }
        let overrides = try await w.store.overrides()
        let reads = w.analyzer.counts.withLock { $0 }

        let selection = Self.selection(lib, screenshots: shots)
        await w.reader.set(selection: selection)
        await w.reader.set(access: .limited)
        let limited = try await w.pipeline.run()
        #expect(limited.isComplete)
        #expect(limited.removed == 0)
        #expect(limited.setAside == lib.assets.count - selection.count)
        #expect(limited.contentAnalyzed == 0 && limited.textRecognized == 0 && limited.placesResolved == 0)
        #expect(w.analyzer.counts.withLock { $0 } == reads)

        #expect(Set(try await w.store.allAssets().map(\.id)) == selection)
        #expect(try await w.store.assetCount() == selection.count)
        #expect(try await w.store.outOfViewCount() == lib.assets.count - selection.count)
        #expect(Set(try await w.store.results(ContentAnalysis.self, kind: "content").keys) == selection)
        #expect(Set(try await w.store.results(TextResult.self, kind: "text").keys).isSubset(of: selection))
        #expect(Set(try await w.store.places().keys).isSubset(of: selection))
        // Search: the two shared screenshots, not the other two.
        #expect(Set(try await w.store.searchText("Rechnung")) == Set(shots.prefix(2)))
        #expect(try await w.store.searchText("Nummer\(shots[3].rawValue.suffix(3))").isEmpty)
        let facts = try await w.pipeline.currentFacts()
        #expect(Set(facts.map(\.id)) == selection)
        let index = SearchIndex(facts: facts)
        #expect(Set(index.search("Rechnung", now: Fixture.date("2026-07-01 12:00")).ids).isSubset(of: selection))
        // Suggestions: only shared photos.
        let snapshot = try #require(try await w.pipeline.latestProposals())
        for proposal in snapshot.proposals + snapshot.dismissed {
            #expect(proposal.assetIDs.union(proposal.optionalAssetIDs).isSubset(of: selection), "\(proposal.title)")
        }
        // Counts: the shared photos, each once; none missing, none sorted or unsorted.
        let derived = DerivedLibraryStatus.derive(
            facts: facts, snapshot: snapshot, settings: await w.pipeline.settings,
            overrides: OverrideSet(try await w.store.overrides()),
            contents: try await w.store.results(ContentAnalysis.self, kind: "content"),
            managed: [], inventory: try await w.store.loadInventory(), scope: .all, calendar: Fixture.calendar)
        #expect(Set(derived.states.keys) == selection)
        #expect(derived.photos == selection.count)
        #expect(derived.analyzed == selection.count)
        #expect(derived.progress.allPhotos == selection.count)
        #expect(derived.progress.ignored == 1)
        // Albums show only the shared photos (like PhotoKit); a plan neither adds nor removes others.
        #expect(try await w.store.loadInventory()[album.id]?.assetIDs == Set(lib.rome.prefix(10)))
        let planned = try await Self.plannedAssets(w)
        #expect(!planned.added.isEmpty)
        #expect(planned.added.isSubset(of: selection))
        #expect(planned.removed.isEmpty)
        // The user's decisions stay, also about photos set aside.
        #expect(try await w.store.overrides() == overrides)
        #expect(try await w.store.ignoredAssets().contains(hiddenIgnored))
    }

    /// A photo deleted in Photos while only the selection was shared cannot be told from one
    /// outside the selection. It goes when full access is back, with its analysis; every other
    /// photo comes back without being looked at again.
    @Test func aPhotoDeletedWhileLimitedIsGoneWithFullAccess() async throws {
        let (lib, shots) = Self.libraryWithScreenshots()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        let reads = w.analyzer.counts.withLock { $0 }
        let lookups = w.geocoder.calls.count
        let selection = Self.selection(lib, screenshots: shots)
        await w.reader.set(selection: selection)
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        // Deleted meanwhile: one photo outside the selection, one inside, one screenshot outside.
        let deleted: Set<AssetID> = [lib.basel[1], lib.rome[2], shots[3]]
        await w.reader.set(assets: lib.assets.filter { !deleted.contains($0.id) })
        let stillLimited = try await w.pipeline.run()
        #expect(stillLimited.removed == 0, "limited access cannot tell deleted from not shared")
        #expect(stillLimited.setAside == 1)

        await w.reader.set(access: .full)
        let back = try await w.pipeline.run()
        #expect(back.isComplete)
        #expect(back.removed == deleted.count)
        #expect(back.newOrChanged == 0)
        #expect(back.contentAnalyzed == 0 && back.textRecognized == 0 && back.placesResolved == 0)
        #expect(w.analyzer.counts.withLock { $0 } == reads)
        #expect(w.geocoder.calls.count == lookups)
        #expect(try await w.store.outOfViewCount() == 0)
        #expect(Set(try await w.store.allAssets().map(\.id)) == Set(lib.assets.map(\.id)).subtracting(deleted))
        for id in deleted {
            #expect(try await w.store.rawResult(kind: "content", asset: id) == nil, "\(id)")
            #expect(try await w.store.recognizedText(for: id) == nil, "\(id)")
        }
        #expect(Set(try await w.store.searchText("Rechnung")) == Set(shots.prefix(3)))
        // The next run reads only what changed again (`readChanges`).
        let wholeReads = await w.reader.wholeReads
        #expect(try await w.pipeline.run().isComplete)
        #expect(await w.reader.wholeReads == wholeReads)
    }

    /// Another selection: photos shared again come back with their analysis, places and text;
    /// a photo edited meanwhile is analysed again, alone.
    @Test func aPhotoSharedAgainInAnotherSelectionKeepsItsAnalysis() async throws {
        let (lib, shots) = Self.libraryWithScreenshots()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        let places = try await w.store.places()
        let first = Set(lib.home.prefix(20))
        await w.reader.set(selection: first)
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        let reads = w.analyzer.counts.withLock { $0 }
        let lookups = w.geocoder.calls.count

        let second = Set(lib.home.prefix(10) + lib.basel + shots)
        await w.reader.set(selection: second)
        let changed = try await w.pipeline.run()
        #expect(changed.isComplete)
        #expect(changed.newOrChanged == 0)
        #expect(changed.setAside == 10)
        #expect(changed.contentAnalyzed == 0 && changed.textRecognized == 0 && changed.placesResolved == 0)
        #expect(w.analyzer.counts.withLock { $0 } == reads)
        #expect(w.geocoder.calls.count == lookups)
        #expect(Set(try await w.store.allAssets().map(\.id)) == second)
        for id in lib.basel { #expect(try await w.store.places()[id] == places[id]) }
        #expect(Set(try await w.store.searchText("Rechnung")) == Set(shots))

        // Edited in Photos while set aside: its new look is analysed, nothing else.
        var assets = await w.reader.assets
        let edited = lib.rome[3]
        let i = try #require(assets.firstIndex { $0.id == edited })
        assets[i].modificationDate = Fixture.date("2026-06-30 09:00")
        await w.reader.set(assets: assets)
        await w.reader.set(selection: second.union([edited]))
        let withEdited = try await w.pipeline.run()
        #expect(withEdited.newOrChanged == 1)
        #expect(withEdited.contentAnalyzed == 1)
    }

    /// The language of album names changed while photos were set aside: their places come
    /// back in the new language, without a lookup.
    @Test func placesSetAsideFollowAnotherLanguage() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await w.store.places()[lib.rome[0]]?.components.country == "Italien")
        await w.reader.set(selection: Set(lib.home))
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        var english = await w.pipeline.settings
        english.titleLanguage = .english
        await w.pipeline.update(settings: english)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await w.store.places(includingOutOfView: true)[lib.rome[0]]?.components.country == "Italy")
        let lookups = w.geocoder.calls.count
        await w.reader.set(access: .full)
        let back = try await w.pipeline.run()
        #expect(back.placesResolved == 0)
        #expect(w.geocoder.calls.count == lookups)
        #expect(try await w.store.places()[lib.rome[0]]?.components.country == "Italy")
    }

    /// Stricter masks of the texts while photos were set aside: their texts are masked too,
    /// and come back masked (privacy rule: such text is never stored).
    @Test func textsSetAsideAreMaskedAgainToo() async throws {
        var builder = LibraryBuilder()
        let shots = (1...2).map { builder.photo(at: Fixture.date("2026-06-0\($0) 20:00"), nil, subtypes: .screenshot) }
        let store = try AlbumistStore(url: nil)
        _ = try await store.upsertAssets(builder.assets)
        let iban = "Bitte überweisen auf DE89.3704.0044.0532.0130.00 danke"
        try await store.saveResult(TextResult(text: TextAnalysis(text: iban, source: .original)), kind: "text",
                                   asset: shots[1], version: AnalysisPipeline.textVersion)
        try await store.indexText(iban, for: shots[1])
        #expect(try await store.setAside(notIn: [shots[0]]) == 1)
        try await store.setValue(2, forKey: AnalysisPipeline.Key.textMaskVersion)
        let w = try Self.world(builder.assets, store: store)
        await w.reader.set(selection: [shots[0]])
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        let masked = try await store.result(TextResult.self, kind: "text", asset: shots[1])?.text?.text
        #expect(masked?.contains("0532") == false)
        #expect(masked?.contains("danke") == true)
        await w.reader.set(access: .full)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await store.searchText("0532").isEmpty)
        #expect(try await store.searchText("danke") == [shots[1]])
        #expect(w.analyzer.counts.withLock { $0.text } == 1, "only the shared screenshot without a text is read")
    }

    // MARK: Second review of the fix: what is bound to ids and to photos set aside

    /// A trip whose id was carried over (its first photo deleted) keeps that id across limited
    /// access and back: decisions, "do not create again" and its album hang on it. Before: the
    /// identity was dropped while all its photos were set aside, and the trip came back with
    /// another id. (Second reviewer's test.)
    @Test func carriedTripIdSurvivesLimitedAndBack() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        func romeTrip() async throws -> AlbumistID? {
            let trips = try await w.store.value([Trip].self, forKey: AnalysisPipeline.Key.trips) ?? []
            return trips.first { Set($0.geotaggedAssetIDs).isSuperset(of: Set(lib.rome.dropFirst(2))) }?.id
        }
        let t0 = try #require(try await romeTrip())
        // First photo of the trip deleted: the trip keeps its id by carry-over.
        await w.reader.set(assets: lib.assets.filter { $0.id != lib.rome[0] })
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await romeTrip() == t0, "carry-over precondition")
        // Limited: only the home photos.
        await w.reader.set(selection: Set(lib.home))
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await romeTrip() == nil, "no trip of photos set aside while limited")
        await w.reader.set(access: .full)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await romeTrip() == t0, "trip id changed after limited and back")
    }

    /// The same for a place the user is often at: its id (its name, "Nicht jetzt", its album)
    /// stays while all its photos are set aside, and it is no suggestion meanwhile.
    @Test func carriedPlaceIdSurvivesLimitedAndBack() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        let key = AnalysisPipeline.Key.frequentPlaces
        func munich() async throws -> FrequentPlace? {
            (try await w.store.value([FrequentPlace].self, forKey: key) ?? []).first { Set($0.assetIDs).isSuperset(of: Set(lib.home.prefix(30))) }
        }
        // An id carried from an earlier analysis (not the one its cell would give it), named.
        var places = try await w.store.value([FrequentPlace].self, forKey: key) ?? []
        let index = try #require(places.firstIndex { Set($0.assetIDs).isSuperset(of: Set(lib.home.prefix(30))) })
        let carried = AlbumistID("frequent-carried")
        places[index].id = carried
        try await w.store.setValue(places, forKey: key)
        var named = await w.pipeline.settings
        named.frequentPlaces.names[carried] = "Büro"
        await w.pipeline.update(settings: named)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await munich()?.id == carried, "carry-over precondition")

        // Limited: no photo of the place is shared.
        await w.reader.set(selection: Set(lib.rome + lib.basel))
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await munich() == nil)
        let shown = try await w.pipeline.latestProposals()?.proposals ?? []
        #expect(!shown.contains { $0.id == carried })
        await w.reader.set(access: .full)
        #expect(try await w.pipeline.run().isComplete)
        let back = try await munich()
        #expect(back?.id == carried, "place id changed after limited and back")
        #expect(back?.userName == "Büro")
    }

    /// A suggestion the user chose and Albumist holds (`HeldSuggestions`, after a change in
    /// "Dein Zuhause") keeps its photos set aside: shown while limited with the shared ones
    /// only, back whole with full access. Before: the photos set aside left it for good.
    @Test func aHeldSuggestionKeepsItsPhotosSetAside() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        let trip = try #require(try await w.pipeline.latestProposals()?.proposals.first { $0.assetIDs.isSuperset(of: Set(lib.rome.dropFirst())) })
        var held = trip
        held.title = "Rom, wie gewählt"
        try await w.store.setValue([held], forKey: AnalysisPipeline.Key.heldSuggestions)
        try await w.store.setValue([held.id: ProposalDecision.createNew(title: nil, folderPath: nil)], forKey: AnalysisPipeline.Key.decisions)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await w.pipeline.heldSuggestions().first?.assetIDs == held.assetIDs, "precondition")

        let selection = Set(lib.home + lib.rome.prefix(10))
        await w.reader.set(selection: selection)
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        let shown = try #require(try await w.pipeline.latestProposals()?.proposals.first { $0.id == held.id })
        #expect(shown.title == held.title)
        #expect(shown.assetIDs == held.assetIDs.intersection(selection))
        #expect(try await w.pipeline.heldSuggestions().first?.assetIDs == held.assetIDs, "photos set aside left the held suggestion")

        await w.reader.set(access: .full)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await w.pipeline.heldSuggestions().first?.assetIDs == held.assetIDs)
        let back = try #require(try await w.pipeline.latestProposals()?.proposals.first { $0.id == held.id })
        #expect(back.assetIDs == held.assetIDs)
    }

    /// Access switched to "Ausgewählte Fotos" while a whole read with full access reads: the
    /// read sees only the selection, and the photos it misses are set aside, not deleted.
    @Test func accessLimitedDuringAWholeReadDeletesNothing() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        let selection = Set(lib.home.prefix(20))
        await w.reader.set(selection: selection)
        await w.reader.expireHistory()
        await w.reader.set(accessDuringNextWholeRead: .limited)
        let run = try await w.pipeline.run()
        #expect(run.removed == 0, "\(run.removed) photos deleted when access became limited during the read")
        #expect(try await w.store.outOfViewCount() == lib.assets.count - selection.count)
        // No mark of the change history with photos set aside: the next run reads the whole
        // library (the mark was taken with full access, before the read).
        #expect(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: AnalysisPipeline.Key.libraryMark) == nil)
        await w.reader.set(access: .full)
        let back = try await w.pipeline.run()
        #expect(back.isComplete)
        #expect(back.contentAnalyzed == 0 && back.placesResolved == 0)
        #expect(try await w.store.outOfViewCount() == 0)
        #expect(try await w.store.assetCount() == lib.assets.count)
    }

    /// Photos set aside while the library's change history has a mark (cannot happen through a
    /// run: a read with limited access removes the mark): the next run with full access reads
    /// the whole library and takes them back, instead of reading only the changes.
    @Test func photosSetAsideAreTakenBackByAWholeRead() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await w.store.value(AnalysisPipeline.LibraryReadMark.self, forKey: AnalysisPipeline.Key.libraryMark) != nil)
        #expect(try await w.store.setAside(notIn: Set(lib.home)) == lib.assets.count - lib.home.count)
        let wholeReads = await w.reader.wholeReads
        let run = try await w.pipeline.run()
        #expect(run.isComplete)
        #expect(await w.reader.wholeReads == wholeReads + 1)
        #expect(try await w.store.outOfViewCount() == 0)
        #expect(run.contentAnalyzed == 0)
    }

    // MARK: Third review: two selections one after the other, held suggestions

    /// Two different selections, each with a part of the trip: the trip keeps its id through
    /// both and back (each carry-over kept only the shared part of the trip before, and the
    /// second selection's part was a trip of its own). Reviewer's test.
    @Test func tripIdAcrossTwoDisjointSelections() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        func rome() async throws -> Trip? {
            (try await w.store.value([Trip].self, forKey: AnalysisPipeline.Key.trips) ?? []).first { !Set($0.geotaggedAssetIDs).isDisjoint(with: Set(lib.rome)) }
        }
        let t0 = try #require(try await rome()).id
        await w.reader.set(access: .limited)
        await w.reader.set(selection: Set(lib.home + lib.rome.prefix(12)))
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await rome()?.id == t0)
        await w.reader.set(selection: Set(lib.home + lib.rome.suffix(20)))
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await rome()?.id == t0, "the second selection's part of the trip got another id")
        await w.reader.set(access: .full)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await rome()?.id == t0, "trip id changed after two selections")
        // With full access the identity is the trip's photos again.
        let identities = try await w.store.value([TripIdentity].self, forKey: AnalysisPipeline.Key.tripIdentities) ?? []
        #expect(Set(identities.first { $0.id == t0 }?.members ?? []) == Set(lib.rome))
    }

    /// The same for a place the user named: two selections of its photos, then all again.
    /// Reviewer's test.
    @Test func placeIdAcrossTwoDisjointSelections() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        let key = AnalysisPipeline.Key.frequentPlaces
        func munich() async throws -> FrequentPlace? {
            (try await w.store.value([FrequentPlace].self, forKey: key) ?? []).first { !Set($0.assetIDs).isDisjoint(with: Set(lib.home)) }
        }
        let m0 = try #require(try await munich()).id
        var named = await w.pipeline.settings
        named.frequentPlaces.names[m0] = "Büro"
        await w.pipeline.update(settings: named)
        await w.reader.set(access: .limited)
        await w.reader.set(selection: Set(lib.home.prefix(60)))
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await munich()?.id == m0)
        await w.reader.set(selection: Set(lib.home.suffix(lib.home.count - 60)))
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await munich()?.id == m0, "the second selection's part of the place got another id")
        #expect(try await munich()?.userName == "Büro")
        await w.reader.set(access: .full)
        #expect(try await w.pipeline.run().isComplete)
        let back = try await munich()
        #expect(back?.id == m0, "place id changed after two selections")
        #expect(back?.userName == "Büro")
        #expect(Set(back?.assetIDs ?? []) == Set(lib.home))
        #expect(try await w.store.value([FrequentPlace].self, forKey: AnalysisPipeline.Key.frequentPlacesOutOfView) == nil)
    }

    /// A held suggestion is not let go while photos are set aside: the suggestions made from the
    /// shared photos may equal it only because the photos that differ are not shared. The user
    /// chose "Rom" with 32 photos; two photos added later would make it 34, so it is held. Only
    /// the 32 shared: made == held, but back with full access the 34 must not take its place.
    @Test func aHeldSuggestionIsNotLetGoWhilePhotosAreSetAside() async throws {
        let lib = Self.library()
        let w = try Self.world(lib.assets)
        #expect(try await w.pipeline.run().isComplete)
        let chosen = try #require(try await w.pipeline.latestProposals()?.proposals.first { $0.assetIDs == Set(lib.rome) })
        try await w.store.setValue([chosen], forKey: AnalysisPipeline.Key.heldSuggestions)
        try await w.store.setValue([chosen.id: ProposalDecision.createNew(title: nil, folderPath: nil)], forKey: AnalysisPipeline.Key.decisions)
        // Two more photos of the trip (synced later).
        let extra = try (1...2).map { n -> AssetSnapshot in
            var photo = try #require(lib.assets.first { $0.id == lib.rome[n] })
            photo.id = AssetID("rome-extra-\(n)")
            photo.creationDate = photo.creationDate?.addingTimeInterval(1_800)
            return photo
        }
        await w.reader.set(assets: lib.assets + extra)
        #expect(try await w.pipeline.run().isComplete)
        func shown() async throws -> AlbumProposal? { try await w.pipeline.latestProposals()?.proposals.first { $0.id == chosen.id } }
        #expect(try await shown()?.assetIDs == chosen.assetIDs, "precondition: held")
        #expect(try await w.pipeline.heldSuggestions().map(\.id) == [chosen.id])

        await w.reader.set(selection: Set(lib.assets.map(\.id)))
        await w.reader.set(access: .limited)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await shown()?.assetIDs == chosen.assetIDs)
        #expect(try await w.pipeline.heldSuggestions().map(\.id) == [chosen.id], "let go while two photos were set aside")
        await w.reader.set(access: .full)
        #expect(try await w.pipeline.run().isComplete)
        #expect(try await shown()?.assetIDs == chosen.assetIDs, "the 34-photo version took the user's choice")
        #expect(try await w.pipeline.heldSuggestions().map(\.id) == [chosen.id])
    }

    /// `HeldSuggestions.apply` with photos set aside: shown with the shared photos only and a
    /// cover among them; with none shared it is not shown at all (also not the version the
    /// suggestions make now), and it is kept whole either way.
    @Test func heldSuggestionShownWithTheSharedPhotosOnly() {
        let all: Set<AssetID> = ["a", "b", "c", "d"]
        var held = AlbumProposal(id: AlbumistID("trip-x"), kind: .trip, title: "Rom, wie gewählt", assetIDs: all)
        held.coverAssetID = "d"
        let decisions: [AlbumistID: ProposalDecision] = [held.id: .createNew(title: nil, folderPath: nil)]
        let fresh = AlbumProposal(id: AlbumistID("trip-x"), kind: .trip, title: "Rom", assetIDs: ["a", "b"])
        var suggestions = Suggestions(open: [fresh])
        let kept = HeldSuggestions.apply([held], decisions: decisions, library: all, inView: ["a", "b"], to: &suggestions)
        #expect(kept == [held])
        let shown = try? #require(suggestions.open.first { $0.id == held.id })
        #expect(shown?.assetIDs == ["a", "b"])
        #expect(shown?.title == held.title)
        #expect(shown?.coverAssetID.map { ["a", "b"].contains($0) } == true, "cover among the shared photos")

        var none = Suggestions(open: [fresh], dismissed: [])
        let stillKept = HeldSuggestions.apply([held], decisions: decisions, library: all, inView: ["x"], to: &none)
        #expect(stillKept == [held])
        #expect(none.open.isEmpty, "no shared photo: not shown")
        var dismissed = Suggestions(open: [], dismissed: [fresh])
        _ = HeldSuggestions.apply([held], decisions: decisions, library: all, inView: [], to: &dismissed)
        #expect(dismissed.open.isEmpty && dismissed.dismissed.isEmpty)
    }
}
