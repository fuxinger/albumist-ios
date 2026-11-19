import Foundation
import Testing
@testable import SortlyEngine
@testable import SortlyCore
import SortlyStore
import SortlyWorldMap
import SortlyTestSupport

/// The sorted ring on a library like the owner's (device test 15.11.: "811 von 5.683 sortiert"
/// on Build 27, "141 von 5.737" and later 157 after "Analyse neu aufbauen" on a newer build).
///
/// Cause, shown by this library: since the curation of the suggestions (012a5a1, first in
/// Build 28) a country seen on one trip only has no suggestion of its own (the trip stands for
/// it), and "Deutschland" none at all (home is no album). The status read only the open
/// suggestions, so "Länder und Orte" counted those photos as unsorted although the user's own
/// trip album held them: on this library Build 27 counted 520 photos as fully sorted, the code
/// before this fix 0. Now the trip album counts for the country, home does not count for
/// "Länder und Orte", and photos without any album on purpose do not count as unsorted.
///
/// Counted the way `AppModel.refreshDerived` counts, after the real analysis.
@Suite("Sorted count with the user's own albums")
struct SortedCountTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()

    struct Spot { var name: String; var at: GeoCoordinate; var place: PlaceComponents }
    static func spot(_ name: String, _ lat: Double, _ lon: Double, _ code: String, _ country: String, _ region: String, _ town: String) -> Spot {
        Spot(name: name, at: GeoCoordinate(latitude: lat, longitude: lon),
             place: PlaceComponents(isoCountryCode: code, country: country, administrativeArea: region, locality: town))
    }
    static let home = spot("home", 48.1371, 11.5754, "DE", "Deutschland", "Bayern", "München")
    static let parents = spot("Augsburg", 48.3705, 10.8978, "DE", "Deutschland", "Bayern", "Augsburg")
    static let salzburg = spot("Salzburg", 47.8095, 13.0550, "AT", "Österreich", "Salzburg", "Salzburg")
    /// A trip after the last analysis (`World.later`).
    static let lisbon = spot("Lissabon", 38.7223, -9.1393, "PT", "Portugal", "Lissabon", "Lissabon")
    /// Trips with the album the user made by hand before Albumist (nil: none).
    static let trips: [(spot: Spot, from: String, to: String, album: String?)] = [
        (spot("Island", 64.1466, -21.9426, "IS", "Island", "Höfuðborgarsvæðið", "Reykjavík"), "2023-07-10", "2023-07-16", "Island 2023"),
        (spot("Marokko", 31.6295, -7.9811, "MA", "Marokko", "Marrakesch-Safi", "Marrakesch"), "2025-05-03", "2025-05-09", "Marokko"),
        (spot("Kroatien", 43.5081, 16.4402, "HR", "Kroatien", "Split-Dalmatien", "Split"), "2025-08-02", "2025-08-08", "Kroatien Sommer"),
        (spot("Wien", 48.2082, 16.3738, "AT", "Österreich", "Wien", "Wien"), "2024-12-28", "2025-01-01", "Silvester in Wien"),
        (spot("Rom", 41.8986, 12.4769, "IT", "Italien", "Latium", "Rom"), "2024-04-09", "2024-04-12", "Rom 2024"),
        (spot("Florenz", 43.7696, 11.2558, "IT", "Italien", "Toskana", "Florenz"), "2023-10-01", "2023-10-05", "Toskana"),
        (spot("Neapel", 40.8518, 14.2681, "IT", "Italien", "Kampanien", "Neapel"), "2025-10-10", "2025-10-14", nil),
        (spot("Paris", 48.8566, 2.3522, "FR", "Frankreich", "Île-de-France", "Paris"), "2023-05-18", "2023-05-21", nil),
        (spot("Hamburg", 53.5511, 9.9937, "DE", "Deutschland", "Hamburg", "Hamburg"), "2025-06-21", "2025-06-22", "Hamburg"),
    ]
    /// Fully sorted on this library with the code of Build 27 (c8af6a7), measured 15.11.
    static let build27Fully = 520

    struct World {
        var store: SortlyStore
        var reader: InMemoryLibraryReader
        var library: InMemoryPhotoLibrary
        var pipeline: AnalysisPipeline
        var settings: OrganizationSettings
        var groups: [String: [AssetID]]
        /// The whole library once the photos of the trip to Lisbon (5.–7.11.2026) arrived.
        var later: [AssetSnapshot]
        func ids(_ name: String) -> [AssetID] { groups[name] ?? [] }
    }

    /// - Parameters:
    ///   - visible: with limited access, the photos the user picked (PhotoKit shows albums with
    ///     these photos only).
    ///   - moroccoOwn: how many Morocco photos the user's own album holds.
    ///   - now: the pipeline's clock (the real time when nil).
    func world(empty: Bool = false, access: LibraryAccess = .full, visible: ((AssetID) -> Bool)? = nil,
               moroccoOwn: Int? = nil, now: Date? = nil) async throws -> World {
        var lib = LibraryBuilder()
        var groups: [String: [AssetID]] = [:]
        if !empty {
            let skipping = Self.trips.map { ($0.from, $0.to) }
            groups["home"] = lib.daily(from: "2023-01-01", to: "2026-10-31", at: Self.home.at, perDay: 1, skipping: skipping)
            for t in Self.trips {
                groups[t.spot.name] = lib.daily(from: t.from, to: t.to, at: t.spot.at, perDay: 20, hour: 9)
            }
            // The parents in Augsburg, a Saturday every few weeks: routine visits, no trips.
            var visits: [AssetID] = []
            for month in 1...10 {
                let day = String(format: "2024-%02d-13", month)
                visits += lib.daily(from: day, to: day, at: Self.parents.at, perDay: 6, hour: 14)
            }
            groups["Augsburg"] = visits
            // One afternoon in Salzburg: six photos, a trip too small for an album.
            groups["Salzburg"] = lib.daily(from: "2026-03-14", to: "2026-03-14", at: Self.salzburg.at, perDay: 6, hour: 13)
        }
        if !empty {
            // Back from Lisbon after the last analysis: these photos arrive later.
            groups["Lissabon"] = lib.daily(from: "2026-11-05", to: "2026-11-07", at: Self.lisbon.at, perDay: 20, hour: 9)
        }
        let lisbon = Set(groups["Lissabon"] ?? []), later = lib.assets
        var albums: [CollectionSnapshot] = []
        for t in Self.trips {
            guard let title = t.album else { continue }
            var members = groups[t.spot.name] ?? []
            if t.spot.name == "Marokko", let moroccoOwn { members = Array(members.prefix(moroccoOwn)) }
            albums.append(CollectionSnapshot(id: CollectionID("own-\(t.spot.name)"), title: title, assetIDs: Set(members)))
        }
        if !empty {
            albums.append(CollectionSnapshot(id: "own-eltern", title: "Bei den Eltern", assetIDs: Set(groups["Augsburg"] ?? [])))
            albums.append(CollectionSnapshot(id: "own-familie", title: "Familie", assetIDs: Set((groups["home"] ?? []).prefix(150))))
            // Favourites: a smart album never counts as sorting.
            albums.append(CollectionSnapshot(id: "smart-fav", title: "Favoriten", kind: .smartAlbum, capabilities: [],
                                             assetIDs: Set((groups["Paris"] ?? []).prefix(60))))
        }
        var assets = lib.assets.filter { !lisbon.contains($0.id) }
        if let visible {
            assets = assets.filter { visible($0.id) }
            albums = albums.map { album in
                var album = album
                album.assetIDs = album.assetIDs.filter(visible)
                return album
            }
        }
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: assets, inventory: CollectionInventory(albums), access: access)
        let answers = [Self.home, Self.parents, Self.salzburg, Self.lisbon] + Self.trips.map(\.spot)
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(),
            geocoder: FakeGeocoder(answers: answers.map { ($0.at, $0.place) }), map: Self.map,
            conditions: FakeConditions(pauseAfterChecks: nil), settings: settings, calendar: Fixture.calendar,
            time: ManualTime().source, batchSize: 50, now: { now ?? Date() }
        )
        let library = InMemoryPhotoLibrary(assets: Set(assets.map(\.id)), collections: albums)
        return World(store: store, reader: reader, library: library, pipeline: pipeline, settings: settings, groups: groups, later: later)
    }

    struct Ring {
        var progress: OrganizationStatusResolver.Progress
        var states: [AssetID: AssetOrganizationState]
        var reasons: LibraryStatus.Reasons
        var resolver: OrganizationStatusResolver

        func overall(_ ids: [AssetID]) -> Set<String> {
            Set(ids.compactMap { id in states[id].map { resolver.isOutsideMainAreas($0) ? "outside" : "\(resolver.overall($0))" } })
        }
        func fully(_ ids: [AssetID]) -> Bool { overall(ids) == ["fullyOrganized"] }
    }

    /// What `AppModel.refreshDerived` computes: facts, suggestions, overrides, Albumist's albums.
    func ring(_ w: World) async throws -> Ring {
        let snapshot = try await w.pipeline.latestProposals()
        let facts = try await w.pipeline.currentFacts()
        let contents = try await w.store.results(ContentAnalysis.self, kind: "content")
        let analyzed = Set(contents.filter { $0.value.failedAttempts == nil }.keys)
        let byAlbumist = LibraryStatus.organizedBySortly(try await w.store.managedAlbums(), inventory: try await w.store.loadInventory(),
                                                         snapshot: snapshot)
        let computed = LibraryStatus.computeWithReasons(
            facts: facts, snapshot: snapshot, settings: w.settings, overrides: OverrideSet(try await w.store.overrides()),
            contentAnalyzed: analyzed, organizedBySortly: byAlbumist, calendar: Fixture.calendar)
        let resolver = OrganizationStatusResolver(primaryAreas: w.settings.primaryAreas)
        return Ring(progress: resolver.progress(computed.states.values), states: computed.states, reasons: computed.reasons, resolver: resolver)
    }

    /// The first run on the realistic library: every group as the product intends.
    func expectIntended(_ r: Ring, _ w: World, sourceLocation: SourceLocation = #_sourceLocation) {
        for name in ["Island", "Marokko", "Kroatien", "Wien", "Hamburg", "Augsburg"] {
            #expect(r.fully(w.ids(name)), "\(name): \(r.overall(w.ids(name)))", sourceLocation: sourceLocation)
        }
        // Italy has three trips: the trip albums are parts of Italy, "Italien" is still to make.
        for name in ["Rom", "Florenz"] {
            #expect(r.overall(w.ids(name)) == ["partiallyOrganized"], "\(name): \(r.overall(w.ids(name)))", sourceLocation: sourceLocation)
        }
        for name in ["Neapel", "Paris"] {
            #expect(r.overall(w.ids(name)) == ["unorganized"], "\(name): \(r.overall(w.ids(name)))", sourceLocation: sourceLocation)
        }
        // Home and a trip too small for an album are not counted.
        #expect(r.overall(w.ids("home")) == ["outside"], sourceLocation: sourceLocation)
        #expect(r.overall(w.ids("Salzburg")) == ["outside"], sourceLocation: sourceLocation)
        #expect(r.progress.fully >= Self.build27Fully, "fully \(r.progress.fully)", sourceLocation: sourceLocation)
        #expect(r.progress.total == r.progress.fully + r.progress.partially + r.progress.unorganized + r.progress.pending,
                sourceLocation: sourceLocation)
    }

    // MARK: - Cases

    @Test func ownTripAlbumsCountForTheirCountryAndHomeIsNotCounted() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let r = try await ring(w)
        expectIntended(r, w)
        let snapshot = try #require(try await w.pipeline.latestProposals())
        // The country of a trip went with the trip, and the trip stands for it.
        #expect(!snapshot.proposals.contains { $0.title == "Island" && $0.kind == .placeCollection(.country) })
        #expect(snapshot.standIns.contains { $0.area == .places && $0.reason == .partOfTrip })
        // Routine visits have the album of the place visited.
        #expect(snapshot.standIns.contains { $0.area == .trips && $0.reason == .routineVisit })
        // The reasons add up to what the ring shows.
        #expect(r.reasons.ownAlbum > 0 && r.reasons.standInAlbum > 0)
        #expect(r.reasons.home == w.ids("home").count)
        #expect(r.reasons.noAlbum >= w.ids("Salzburg").count)
        print("sorted count: \(r.progress.fully) of \(r.progress.total), partly \(r.progress.partially), outside \(r.progress.outsideMainAreas); \(r.reasons.line)")
    }

    /// "Analyse neu aufbauen": nothing is counted from the cleared tables, and the count after
    /// the rebuild is the count before it, photo by photo.
    @Test func rebuildGivesTheSameCount() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let before = try await ring(w)
        try await w.store.resetAnalysis(includingDecisions: false)
        _ = try await w.pipeline.run()
        let after = try await ring(w)
        expectIntended(after, w)
        #expect(after.progress == before.progress)
        #expect(after.states == before.states)
    }

    @Test func secondRunGivesTheSameCount() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let first = try await ring(w)
        _ = try await w.pipeline.run()
        let second = try await ring(w)
        #expect(second.states == first.states)
        expectIntended(second, w)
    }

    /// Accept a suggestion, then take it back: the photos Albumist sorted count, and after the
    /// undo everything is as before, never less.
    @Test func acceptThenUndo() async throws {
        let w = try await world()
        _ = try await w.pipeline.run()
        let before = try await ring(w)
        let snapshot = try #require(try await w.pipeline.latestProposals())
        let paris = try #require(snapshot.proposals.first { $0.kind == .trip && $0.assetIDs == Set(w.ids("Paris")) })
        let planner = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50)
        var plan = planner.makePlan(from: [ConfirmedProposal(proposal: paris, decision: .createNew(title: nil, folderPath: nil))],
                                    inventory: try await w.library.currentInventory(), overrides: OverrideSet())
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let executed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(plan)
        #expect(executed.status == .completed)
        try await record(executed, w)

        let accepted = try await ring(w)
        // Paris is sorted for both areas: the trip album also stands for France.
        #expect(accepted.fully(w.ids("Paris")), "\(accepted.overall(w.ids("Paris")))")
        #expect(accepted.progress.fully == before.progress.fully + w.ids("Paris").count)
        #expect(accepted.reasons.byAlbumist >= w.ids("Paris").count)

        var undo = UndoPlanner().undoPlan(for: executed, current: try await w.library.currentInventory())
        undo.confirmedAt = Date()
        undo.status = .confirmed
        let undone = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(undo)
        #expect(undone.status == .completed)
        try await record(undone, w)
        let back = try await ring(w)
        #expect(back.progress == before.progress)
        #expect(back.states == before.states)
        _ = try await w.pipeline.run()
        #expect(try await ring(w).progress == before.progress)
    }

    /// "Nicht jetzt" on a suggestion whose album the user already has: the photos stay sorted.
    /// And "Albumists Fotos herausnehmen" on an own album Albumist extended: the user's own
    /// photos in it stay sorted, only the photos Albumist added no longer count.
    @Test func dismissedSuggestionsKeepTheirOwnAlbum() async throws {
        let w = try await world(moroccoOwn: 100)
        _ = try await w.pipeline.run()
        let snapshot = try #require(try await w.pipeline.latestProposals())
        let croatia = try #require(snapshot.proposals.first { $0.kind == .trip && $0.assetIDs == Set(w.ids("Kroatien")) })
        try await w.store.addOverride(UserOverride(scope: .source(croatia.id), decision: .rejectProposal))

        // Morocco: the own album holds 100 of 140 photos; Albumist adds the other 40.
        let morocco = try #require(snapshot.proposals.first { $0.kind == .trip && $0.assetIDs == Set(w.ids("Marokko")) })
        #expect(snapshot.matches[morocco.id]?.status == .extendable)
        var plan = OrganizationPlanner(rootFolderTitle: "", chunkSize: 50).makePlan(
            from: [ConfirmedProposal(proposal: morocco, decision: .extendExisting("own-Marokko"))],
            inventory: try await w.library.currentInventory(), overrides: OverrideSet())
        plan.confirmedAt = Date()
        plan.status = .confirmed
        let executed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(plan)
        try await record(executed, w)
        #expect(try await ring(w).fully(w.ids("Marokko")))

        // "Albumists Fotos herausnehmen", then the suggestion is not offered again (forgetProposal).
        let state = try #require(try await w.store.managedAlbums().first { $0.albumID == "own-Marokko" })
        var removal = ManagedAlbumTracker().removalPlan(for: state, current: try await w.library.currentInventory())
        removal.confirmedAt = Date()
        removal.status = .confirmed
        let removed = try await ChangeExecutor(library: w.library, store: InMemoryPlanStore()).execute(removal)
        try await record(removed, w)
        for source in state.allSourceIDs { try await w.store.addOverride(UserOverride(scope: .source(source), decision: .rejectProposal)) }
        _ = try await w.pipeline.run()

        let next = try #require(try await w.pipeline.latestProposals())
        #expect(!next.proposals.contains { $0.id == croatia.id || $0.id == morocco.id })
        #expect(next.dismissed.contains { $0.id == croatia.id } && next.dismissed.contains { $0.id == morocco.id })
        let r = try await ring(w)
        #expect(r.fully(w.ids("Kroatien")), "\(r.overall(w.ids("Kroatien")))")
        let own = Array(w.ids("Marokko").prefix(100)), added = Array(w.ids("Marokko").dropFirst(100))
        #expect(r.fully(own), "\(r.overall(own))")
        #expect(r.overall(added) == ["unorganized"], "\(r.overall(added))")
        #expect(r.reasons.dismissedAlbum > 0)
    }

    @Test func emptyLibrary() async throws {
        let w = try await world(empty: true)
        _ = try await w.pipeline.run()
        let r = try await ring(w)
        #expect(r.progress == OrganizationStatusResolver.Progress())
        #expect(r.reasons == LibraryStatus.Reasons())
    }

    /// Limited access: only the photos the user picked are seen, and own albums show only those.
    @Test func limitedAccess() async throws {
        let picked: @Sendable (AssetID) -> Bool = { id in (Int(id.rawValue.suffix(6)) ?? 0) % 3 != 0 }
        let w = try await world(access: .limited, visible: picked)
        _ = try await w.pipeline.run()
        let r = try await ring(w)
        let seen = { (name: String) in w.ids(name).filter(picked) }
        for name in ["Island", "Marokko", "Kroatien", "Wien", "Hamburg"] {
            #expect(r.fully(seen(name)), "\(name): \(r.overall(seen(name)))")
        }
        #expect(r.overall(seen("home")) == ["outside"])
        #expect(r.progress.allPhotos == r.states.count)
        #expect(r.states.keys.allSatisfy(picked))
    }

    /// 100,000 photos: the status with stand-ins, dismissed suggestions and home stays fast.
    @Test func hugeLibraryStaysFast() {
        var facts: [AssetFacts] = []
        facts.reserveCapacity(100_000)
        var proposals: [AlbumProposal] = [], dismissed: [AlbumProposal] = [], standIns: [StandIn] = []
        var matches: [SortlyID: MatchResult] = [:]
        let germany = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", locality: "München")
        for i in 0..<70_000 {
            let asset = AssetSnapshot(id: AssetID("h\(i)"), kind: .image, creationDate: Date(timeIntervalSince1970: Double(i) * 1_000),
                                      location: Fixture.Places.munichHome)
            facts.append(AssetFacts(asset: asset, place: germany, placeSource: .gpsReverseGeocoded, atHome: true))
        }
        for t in 0..<300 {
            let trip = SortlyID("t\(t)")
            var ids: Set<AssetID> = []
            for i in 0..<100 {
                let id = AssetID("t\(t)-\(i)")
                ids.insert(id)
                let asset = AssetSnapshot(id: id, kind: .image, creationDate: Date(timeIntervalSince1970: Double(t * 100 + i) * 1_000),
                                          location: Fixture.Places.rome)
                facts.append(AssetFacts(asset: asset, place: PlaceComponents(isoCountryCode: "IT", country: "Italien"),
                                        placeSource: .gpsReverseGeocoded, tripID: trip, albumIDs: t % 2 == 0 ? [CollectionID("own-\(t)")] : []))
            }
            let p = AlbumProposal(id: trip, kind: .trip, title: "Reise \(t)", assetIDs: ids)
            if t % 10 == 0 { dismissed.append(p) } else { proposals.append(p) }
            standIns.append(StandIn(area: .places, suggestion: trip, dropped: nil, assetIDs: ids, reason: .placeOfTrip))
            matches[trip] = MatchResult(proposalID: trip, status: .alreadyComplete,
                                        best: MatchCandidate(albumID: CollectionID("own-\(t)"), albumTitle: "Reise \(t)",
                                                             metrics: OverlapMetrics(proposalCount: 100, albumCount: 100, intersection: 100),
                                                             relation: .equivalent, nameSimilarity: 1, score: 1, isEditable: true),
                                        alternatives: [], sameNameAlbums: [], reasons: [])
        }
        let snapshot = ProposalSnapshot(generatedAt: Date(), scope: .all, proposals: proposals, matches: matches,
                                        dismissed: dismissed, standIns: standIns)
        var settings = OrganizationSettings()
        settings.primaryAreas = [.places, .trips]
        var suggestionReads = 0
        let computed = LibraryStatus.computeWithReasons(facts: facts, snapshot: snapshot, settings: settings, contentAnalyzed: [],
                                                        suggestionReads: &suggestionReads)
        let p = OrganizationStatusResolver(primaryAreas: settings.primaryAreas).progress(computed.states.values)
        #expect(p.total == 30_000 && p.outsideMainAreas == 70_000)
        #expect(p.fully == 15_000) // every second trip has its own album
        #expect(computed.reasons.home == 70_000)
        // Counted, not timed (review P5-14 b: the old limit of 20 s wall clock failed at 40 and
        // 51 s on a machine running three times as many threads as it has cores, 19.11.). Each
        // suggestion's photos are gone through once: 600 reads for 100,000 photos. Asking the
        // suggestions for each photo instead reads them tens of millions of times.
        #expect(suggestionReads <= proposals.count + dismissed.count + standIns.count, "\(suggestionReads) suggestion reads")
    }

    /// A snapshot stored before dismissed suggestions and stand-ins were kept still loads.
    @Test func olderSnapshotStillLoads() throws {
        let snapshot = ProposalSnapshot(generatedAt: Date(timeIntervalSince1970: 0), scope: .all,
                                        proposals: [AlbumProposal(id: SortlyID("p"), kind: .trip, title: "Rom", assetIDs: ["1"])], matches: [:])
        let data = try JSONEncoder().encode(snapshot)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["dismissed"] = nil
        object["standIns"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ProposalSnapshot.self, from: old)
        #expect(decoded == snapshot)
    }

    /// Back from a trip, while the analysis reads the new photos and before it has made their
    /// suggestions: the photos count as unsorted (the total grows by them). They do not leave
    /// the ring as photos without an album on purpose, which is only for photos the suggestions
    /// already knew.
    @Test func newPhotosAfterATripStayUnsorted() async throws {
        let w = try await world(now: Fixture.date("2026-11-01"))
        _ = try await w.pipeline.run()
        let before = try await ring(w)
        let known = try #require(try await w.pipeline.latestProposals())
        await w.reader.set(assets: w.later)
        _ = try await w.pipeline.run()
        try await w.store.setValue(known, forKey: AnalysisPipeline.Key.proposals)
        let back = try await ring(w)
        let lisbon = w.ids("Lissabon")
        #expect(back.overall(lisbon) == ["unorganized"], "\(back.overall(lisbon))")
        #expect(back.progress.total == before.progress.total + lisbon.count)
        #expect(back.progress.fully == before.progress.fully)
        // With the new suggestions, Lisbon is a trip to sort.
        _ = try await w.pipeline.run()
        #expect(try await ring(w).overall(lisbon) == ["unorganized"])
        #expect(try await w.pipeline.latestProposals()?.proposals.contains { $0.kind == .trip && $0.assetIDs == Set(lisbon) } == true)
    }

    /// The fitting album of a suggestion: also when several albums fit; never a smart album.
    @Test func multipleMatchesCountWhenTheBestAlbumFits() {
        func result(_ status: MatchStatus, editable: Bool = true) -> MatchResult {
            MatchResult(proposalID: SortlyID("p"), status: status,
                        best: MatchCandidate(albumID: "a", albumTitle: "Island 2023", metrics: OverlapMetrics(proposalCount: 10, albumCount: 10, intersection: 9),
                                             relation: .partOfProposal, nameSimilarity: 0.5, score: 0.9, isEditable: editable),
                        alternatives: [], sameNameAlbums: [], reasons: [])
        }
        #expect(LibraryStatus.fittingAlbums(result(.multipleMatches), kind: .trip) == ["a"])
        // Only a possible match: Albumist makes its own album, the photos are not sorted yet (review 16.11.).
        #expect(LibraryStatus.fittingAlbums(result(.possibleMatch), kind: .trip).isEmpty)
        #expect(LibraryStatus.fittingAlbums(result(.notEditable, editable: false), kind: .trip).isEmpty)
        #expect(LibraryStatus.fittingAlbums(result(.nameConflict), kind: .trip).isEmpty)
    }

    /// Review 16.11. (A1, A4): an album that only possibly fits, or that holds the trip among
    /// thousands of other photos, does not make the trip count as sorted in the ring.
    @Test func possibleMatchAndCatchAllAlbumDoNotCountAsSorted() throws {
        let trip = (0..<40).map { AssetID("pm-\($0)") }
        let proposal = AlbumProposal(id: SortlyID("pm"), kind: .trip, title: "Island", assetIDs: Set(trip))
        var settings = OrganizationSettings()
        settings.primaryAreas = [.trips]
        for album in [
            // 24 of 40 trip photos and 16 others: possible match.
            CollectionSnapshot(id: "sommer", title: "Sommer", assetIDs: Set(trip.prefix(24)).union((0..<16).map { AssetID("x-\($0)") })),
            // The whole trip among 2,000 other photos: not the trip's album.
            CollectionSnapshot(id: "export", title: "Export", assetIDs: Set(trip).union((0..<2000).map { AssetID("y-\($0)") })),
        ] {
            let inventory = CollectionInventory([album])
            let match = try #require(AlbumMatcher().match([proposal], against: inventory)[proposal.id])
            #expect([.possibleMatch, .newAlbumRequired].contains(match.status))
            let facts = trip.map { id in
                AssetFacts(asset: AssetSnapshot(id: id, kind: .image, creationDate: Fixture.date("2023-07-12"), location: Self.trips[0].spot.at),
                           place: Self.trips[0].spot.place, placeSource: .gpsReverseGeocoded, tripID: SortlyID("t"),
                           albumIDs: album.assetIDs.contains(id) ? [album.id] : [])
            }
            let snapshot = ProposalSnapshot(generatedAt: Fixture.date("2026-11-01"), scope: .all, proposals: [proposal],
                                            matches: [proposal.id: match])
            let states = LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings, contentAnalyzed: Set(trip))
            #expect(trip.allSatisfy { states[$0]?.areas[.trips] != .preExisting }, "\(album.title): \(match.status)")
        }
    }

    /// A trip split by hand into two albums of the same size: both fit equally well, and both
    /// halves count as sorted, not only the photos of the album the matcher happens to list first.
    /// A smaller album, a smart album and a part of a place do not count.
    @Test func everyAlbumThatFitsAsWellAsTheBestCounts() throws {
        let trip = (0..<40).map { AssetID("is-\($0)") }
        let proposal = AlbumProposal(id: SortlyID("island"), kind: .trip, title: "Island", assetIDs: Set(trip))
        let inventory = CollectionInventory([
            CollectionSnapshot(id: "own-1", title: "Island", assetIDs: Set(trip.prefix(20))),
            CollectionSnapshot(id: "own-2", title: "Island", assetIDs: Set(trip.suffix(20))),
            CollectionSnapshot(id: "own-3", title: "Island", assetIDs: Set(trip.prefix(16))),
            CollectionSnapshot(id: "smart", title: "Island", kind: .smartAlbum, capabilities: [], assetIDs: Set(trip.suffix(20))),
        ])
        let match = try #require(AlbumMatcher().match([proposal], against: inventory)[proposal.id])
        #expect(match.status == .multipleMatches)
        #expect(LibraryStatus.fittingAlbums(match, kind: .trip) == ["own-1", "own-2"])

        let facts = trip.map { id in
            AssetFacts(asset: AssetSnapshot(id: id, kind: .image, creationDate: Fixture.date("2023-07-12"), location: Self.trips[0].spot.at),
                       place: Self.trips[0].spot.place, placeSource: .gpsReverseGeocoded, tripID: SortlyID("t"),
                       albumIDs: Set(inventory.albums.filter { $0.assetIDs.contains(id) }.map(\.id)))
        }
        var settings = OrganizationSettings()
        settings.primaryAreas = [.trips]
        let snapshot = ProposalSnapshot(generatedAt: Fixture.date("2026-11-01"), scope: .all, proposals: [proposal],
                                        matches: [proposal.id: match])
        let states = LibraryStatus.compute(facts: facts, snapshot: snapshot, settings: settings, contentAnalyzed: Set(trip))
        #expect(trip.allSatisfy { states[$0]?.areas[.trips] == .preExisting })

        // A place: "Rom" holds half of Italien but is a part of it, not its album.
        let italy = AlbumProposal(id: SortlyID("it"), kind: .placeCollection(.country), title: "Italien", assetIDs: Set(trip))
        let parts = AlbumMatcher().match([italy], against: CollectionInventory([
            CollectionSnapshot(id: "it-1", title: "Italien", assetIDs: Set(trip.prefix(20))),
            CollectionSnapshot(id: "it-2", title: "Italien", assetIDs: Set(trip.suffix(20))),
            CollectionSnapshot(id: "rom", title: "Rom", assetIDs: Set(trip.prefix(20))),
        ]))
        let italyMatch = try #require(parts[italy.id])
        #expect(italyMatch.status == .multipleMatches)
        #expect(LibraryStatus.fittingAlbums(italyMatch, kind: italy.kind) == ["it-1", "it-2"])
    }

    /// What the app does after a plan ran: Albumist's albums recorded, the analysis sees the
    /// albums, the suggestions matched again.
    func record(_ executed: ChangePlan, _ w: World) async throws {
        let after = try await w.library.currentInventory()
        try await w.store.saveManagedAlbums(ManagedAlbumTracker().record(executed, into: try await w.store.managedAlbums(), inventory: after))
        try await w.store.saveInventory(after)
        await w.reader.set(inventory: after)
        _ = try await w.pipeline.rematch()
    }
}
