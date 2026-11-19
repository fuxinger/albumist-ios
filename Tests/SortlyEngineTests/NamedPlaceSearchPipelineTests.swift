import Foundation
import Testing
@testable import SortlyEngine
import SortlyCore
import SortlyStore
import SortlyTestSupport

/// Review finding G1-05 through the analysis, the way the app runs it: the facts and suggestions
/// of a real run, the name typed in the suggestion of a frequent place (kept as its title, like
/// `AppModel.setUserTitle`), "Album anlegen" with that name, and the next run. The search finds
/// the place by its name before the album exists, and after it once, without a second result.
@Suite("Search: a named place through the analysis (G1-05)")
struct NamedPlaceSearchPipelineTests {
    let now = Fixture.date("2026-11-18 12:00")

    func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    @Test func theNameFindsThePlaceBeforeAndAfterItsAlbum() async throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2, hour: 19)
        let garden = Set(lib.daily(from: "2026-04-04", to: "2026-09-26", at: GeoCoordinate(latitude: 48.1800, longitude: 11.5200),
                                   perDay: 3, everyNthDay: 7, hour: 10))
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let store = try SortlyStore(url: nil)
        let reader = InMemoryLibraryReader(assets: lib.assets)
        let library = InMemoryPhotoLibrary(assets: Set(lib.assets.map(\.id)))
        let pipeline = AnalysisPipeline(
            store: store, reader: reader, analyzer: FakeContentAnalyzer(labels: { _ in [] }, text: { _ in "" }),
            geocoder: FakeGeocoder(), map: PipelineTests.map, conditions: FakeConditions(), settings: settings,
            calendar: Fixture.calendar, time: ManualTime().source
        )
        _ = try await pipeline.run()
        let first = try #require(try await pipeline.latestProposals())
        let place = try #require(first.proposals.first { $0.kind == .frequentPlace && $0.assetIDs == garden })
        #expect(place.requiresUserName)
        let titles = [place.id: "Mein Kleingarten"]

        /// Like `AppModel.searchIndex()`.
        func appIndex() async throws -> SearchIndex {
            let suggestions = try await pipeline.latestProposals()?.proposals ?? []
            return SearchIndex(facts: try await pipeline.currentFacts(), inventory: try await store.loadInventory(),
                               namedPlaces: NamedPlace.resolve(titles: titles, settings: settings.frequentPlaces, suggestions: suggestions),
                               calendar: Fixture.calendar)
        }

        let before = try await appIndex().search("Mein Kleingarten", now: now)
        #expect(Set(before.ids) == garden)
        #expect(before.tokens.map(\.kind) == [.place])

        // "Album anlegen" in the suggestion: the album gets the name typed there.
        let decision = ProposalDecision.recommended(for: place, match: first.matches[place.id], userTitle: titles[place.id])
        #expect(decision == .createNew(title: "Mein Kleingarten", folderPath: nil))
        let plan = OrganizationPlanner(rootFolderTitle: settings.rootFolderTitle)
            .makePlan(from: [ConfirmedProposal(proposal: place, decision: decision)], inventory: try await library.currentInventory(),
                      overrides: OverrideSet())
        let executed = try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed(plan))
        #expect(executed.status == .completed)
        await reader.set(inventory: try await library.currentInventory())
        _ = try await pipeline.run()
        #expect(try await store.loadInventory().albums.contains { $0.title == "Mein Kleingarten" && $0.assetIDs == garden })

        let index = try await appIndex()
        let after = index.search("Mein Kleingarten", now: now)
        #expect(after.ids == before.ids)
        #expect(Set(after.ids).count == after.ids.count)
        #expect(after.tokens.count == 1)
        #expect(index.suggestions(for: "Klein").filter { $0.label == "Mein Kleingarten" }.count == 1)
    }
}
