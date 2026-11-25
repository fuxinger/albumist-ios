import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Design W1, tabs 6B: the tab "Unsortiert" shows only the filters "Unsortiert", "Unsicher" and
/// "Ignoriert", "Unsortiert" first. "Vorschläge" is a tab of its own now; "Sortiert" and "Alle"
/// are gone from the tab. No photo the user has to act on may get lost with them.
@Suite("Unsorted tab")
struct UnsortedTabTests {
    static let resolver = LibraryBucketsTests.resolver

    @Test func threeFiltersUnsortedFirst() {
        #expect(LibraryBuckets.unsortedTabFilters == [.unorganized, .uncertain, .ignored])
        #expect(LibraryBuckets.unsortedTabFilters.first == .unorganized, "the tab opens on „Unsortiert“")
        for gone in [InboxBucket.suggestions, .organized, .all, .excluded] {
            #expect(!LibraryBuckets.unsortedTabFilters.contains(gone), "\(gone)")
        }
    }

    /// The filter "Vorschläge" is gone: every photo with an open suggestion that the ring counts
    /// is in "Unsortiert", so it is still there (and its suggestion is on the tab "Vorschläge").
    @Test func aPhotoWithASuggestionStaysInUnsorted() throws {
        let facts = SearchPerformanceTests.library(count: 3_000)
        let states = LibraryBucketsTests.states(for: facts)
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: states, resolver: Self.resolver))
        let unsorted = Set(buckets[.unorganized].map(\.id))
        let withSuggestion = buckets[.suggestions].map(\.id)
        #expect(!withSuggestion.isEmpty)
        #expect(withSuggestion.allSatisfy(unsorted.contains), "\(withSuggestion.filter { !unsorted.contains($0) }.prefix(5))")

        // "Nur 2026": a photo outside the counted year is in neither list, as on the ring.
        let year = Calendar.albumistDefault.component(.year, from: try #require(facts.compactMap(\.asset.creationDate).max()))
        let inScope: (AssetFacts) -> Bool = { $0.asset.creationDate.map { Calendar.albumistDefault.component(.year, from: $0) == year } ?? false }
        let scoped = try #require(LibraryBuckets.make(facts: facts, states: states, resolver: Self.resolver, inScope: inScope))
        let scopedUnsorted = Set(scoped[.unorganized].map(\.id))
        let counted = Set(facts.filter(inScope).map(\.id))
        let countedWithSuggestion = scoped[.suggestions].map(\.id).filter(counted.contains)
        #expect(!countedWithSuggestion.isEmpty)
        #expect(countedWithSuggestion.allSatisfy(scopedUnsorted.contains))
        #expect(scopedUnsorted.isSubset(of: counted))
    }

    /// "Unsortiert" holds what the ring counts as open (unsorted, partly sorted, still being
    /// read): the tab and the start page's ring say the same number.
    @Test func unsortedIsWhatTheRingCountsOpen() throws {
        let facts = SearchPerformanceTests.library(count: 3_000)
        let states = LibraryBucketsTests.states(for: facts)
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: states, resolver: Self.resolver))
        let ring = Self.resolver.progress(facts.compactMap { states[$0.id] })
        #expect(buckets[.unorganized].count == ring.unorganized + ring.partially + ring.pending)
        #expect(buckets[.unorganized].count > 0)
    }

    /// An ignored photo is in "Ignoriert" only, where "Nicht mehr ignorieren" brings it back;
    /// "Ignoriert" holds nothing else.
    @Test func ignoredPhotosAreFoundInIgnored() throws {
        let facts = SearchPerformanceTests.library(count: 3_000)
        let states = LibraryBucketsTests.states(for: facts)
        let buckets = try #require(LibraryBuckets.make(facts: facts, states: states, resolver: Self.resolver))
        let ignored = Set(facts.map(\.id).filter { id in states[id].map { Self.resolver.ringPart($0) == .ignored } ?? false })
        #expect(!ignored.isEmpty)
        #expect(Set(buckets[.ignored].map(\.id)) == ignored)
        #expect(buckets[.unorganized].allSatisfy { !ignored.contains($0.id) })
        #expect(buckets[.uncertain].allSatisfy { !ignored.contains($0.id) })
    }

    /// The tab itself (the app does not build on Linux, so this reads its code): its filters are
    /// the list above, in chips and in the menu at the largest text sizes, and it is called
    /// "Unsortiert". Suggestions are no list of this tab any more.
    @Test func theTabShowsOnlyItsFilters() throws {
        let file = try AppSource.read("App/Albumist/Views/LibraryView.swift")
        let code = AppSource.code(file)
        let picker = try #require(AppSource.body(of: "private var bucketPicker", in: file))
        #expect(AppSource.code(picker).components(separatedBy: "ForEach(LibraryBuckets.unsortedTabFilters").count - 1 == 2,
                "chips and menu show the tab's filters")
        #expect(picker.contains(".accessibilityIdentifier(\"library.filter\")"), "UI tests find the filters by identifier")
        #expect(!code.contains(".suggestions"), "the filter „Vorschläge“ is gone")
        #expect(!code.contains("proposalList"), "the tab lists no suggestions")
        #expect(!code.contains("static let buckets"), "no second list of filters")
        let view = try #require(AppSource.body(of: ["struct LibraryView", "var body: some View"], in: file))
        #expect(view.contains(".navigationTitle(\"Unsortiert\")"))
        #expect(!file.contains("\"Mediathek\""), "the tab is no longer called „Mediathek“")
        #expect(code.contains("@State private var bucket: InboxBucket = .unorganized"), "the tab opens on „Unsortiert“")
    }

    /// The tab bar (design W1 6B): "Vorschläge · Unsortiert · Alben · Suche". "Vorschläge" has a
    /// cards symbol, never sparkles (no AI promise in the frame).
    @Test func theTabsAreNamedAsDecided() throws {
        let root = try AppSource.read("App/Albumist/Views/RootView.swift")
        let code = AppSource.code(root, keepStrings: true)
        let names = ["Tab(\"Vorschläge\"", "Tab(\"Unsortiert\"", "Tab(\"Alben\"",
                     "Tab(\"Suchen\", systemImage: \"magnifyingglass\", value: MainTab.search, role: Self.searchRole)"]
        let places = try names.map { name in try #require(code.range(of: name), "\(name)").lowerBound }
        #expect(places == places.sorted(), "the tabs keep the decided order")
        #expect(!code.contains("Tab(\"Übersicht\"") && !code.contains("Tab(\"Mediathek\""))
        #expect(!code.contains("sparkles"), "no sparkles in the tab bar")
    }
}
