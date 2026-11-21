import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// One meaning of "sortiert" (decisions Fuchs 18.11.; Fable review P1-05, P1-06):
/// 1. Ignored photos do not count in the ring: they are neither sorted nor open, so they leave
///    "x" and "y" of "x von y sortiert", and the ring can reach 100 %.
/// 2. The list "Sortiert" in the library tab shows the ring's number, and "Unsortiert" the
///    rest of its total. Both come from `OrganizationStatusResolver.ringPart`.
@Suite("Ring and library lists: one meaning of sorted")
struct RingDefinitionTests {
    static let resolver = OrganizationStatusResolver(primaryAreas: [.places, .trips])

    static func sorted(_ id: AssetID, ignored: Bool = false) -> AssetOrganizationState {
        resolver.state(for: id, facts: [.places: AreaFacts(inMatchingExistingAlbum: true), .trips: AreaFacts(organizedByAlbumist: true)],
                       ignored: ignored)
    }
    static func open(_ id: AssetID, ignored: Bool = false) -> AssetOrganizationState {
        resolver.state(for: id, facts: [.places: AreaFacts(proposed: true), .trips: AreaFacts(applicable: false)], ignored: ignored)
    }
    static func home(_ id: AssetID, ignored: Bool = false) -> AssetOrganizationState {
        resolver.state(for: id, facts: [.places: AreaFacts(applicable: false), .trips: AreaFacts(applicable: false)], ignored: ignored)
    }

    /// The library tab's lists for these states, as `AppModel` makes them.
    static func lists(_ states: [AssetOrganizationState], resolver: OrganizationStatusResolver = resolver) -> LibraryBuckets {
        let facts = states.enumerated().map { i, s in
            AssetFacts(asset: AssetSnapshot(id: s.assetID, creationDate: Date(timeIntervalSinceReferenceDate: Double(i) * 3_600)))
        }
        let byID = Dictionary(states.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
        return LibraryBuckets.make(facts: facts, states: byID, resolver: resolver)!
    }

    @Test func ringWithIgnoredPhotosReachesOneHundredPercent() {
        // Three sorted, two open: 60 %.
        let before = Self.resolver.progress([Self.sorted("s1"), Self.sorted("s2"), Self.sorted("s3"), Self.open("o1"), Self.open("o2")])
        #expect(before.fully == 3 && before.total == 5)
        // Both open photos ignored: nothing is left to do, the ring is full.
        let after = Self.resolver.progress([Self.sorted("s1"), Self.sorted("s2"), Self.sorted("s3"),
                                            Self.open("o1", ignored: true), Self.open("o2", ignored: true)])
        #expect(after.fully == 3 && after.total == 3, "\(after.fully) von \(after.total)")
        #expect(after.fullyShare == 1)
        #expect(after.ignored == 2)
        #expect(after.allPhotos == 5)
    }

    @Test func ignoredPhotosAreNeitherSortedNorOpen() {
        let ignoredSorted = Self.sorted("a", ignored: true)
        let ignoredOpen = Self.open("b", ignored: true)
        let ignoredHome = Self.home("c", ignored: true)
        let p = Self.resolver.progress([ignoredSorted, ignoredOpen, ignoredHome])
        #expect(p.total == 0 && p.fully == 0 && p.partially == 0 && p.unorganized == 0 && p.pending == 0)
        #expect(p.ignored == 3 && p.outsideMainAreas == 0 && p.allPhotos == 3)
        for state in [ignoredSorted, ignoredOpen, ignoredHome] {
            #expect(Self.resolver.buckets(state) == [.all, .ignored])
        }
        let lists = Self.lists([ignoredSorted, ignoredOpen, ignoredHome])
        #expect(lists[.organized].isEmpty && lists[.unorganized].isEmpty && lists[.ignored].count == 3)
    }

    /// Ignoring a photo that is open, or that the ring does not count, never makes the ring
    /// smaller (Fable: 64 % became 53 % after ignoring ten photos from home), and ignoring
    /// any photo never makes "von y" larger.
    @Test func ignoringNeverLowersTheRing() {
        let states = [Self.sorted("s1"), Self.sorted("s2"), Self.open("o1"), Self.open("o2"), Self.home("h1"), Self.home("h2")]
        let before = Self.resolver.progress(states)
        let open: [AssetID] = ["o1", "o2", "h1", "h2"]
        for id in open {
            let after = Self.resolver.progress(states.map { $0.assetID == id ? Self.resolver.state(ignoring: $0) : $0 })
            #expect(after.fullyShare >= before.fullyShare, "\(id): \(after.fully) von \(after.total)")
            #expect(after.total <= before.total, "\(id)")
        }
        for id in states.map(\.assetID) {
            let after = Self.resolver.progress(states.map { $0.assetID == id ? Self.resolver.state(ignoring: $0) : $0 })
            #expect(after.total <= before.total, "\(id)")
        }
    }

    /// A photo that no main area applies to (taken at home) is not in "Sortiert": the ring does
    /// not count it. Fable: the ring said "32 von 50", the list "Sortiert" 199.
    @Test func photosTheRingDoesNotCountAreOnlyInAll() {
        let lists = Self.lists([Self.sorted("s"), Self.open("o"), Self.home("h1"), Self.home("h2")])
        let p = Self.resolver.progress([Self.sorted("s"), Self.open("o"), Self.home("h1"), Self.home("h2")])
        #expect(lists[.organized].map(\.id) == ["s"])
        #expect(lists[.organized].count == p.fully)
        #expect(lists[.all].count == 4)
        #expect(Self.resolver.buckets(Self.home("h1")) == [.all])
    }

    /// Unignoring puts the photo back where it was: in the ring and in its list.
    @Test func unignoringPutsThePhotoBack() {
        let states = [Self.sorted("s"), Self.open("o"), Self.home("h")]
        let before = Self.resolver.progress(states)
        let beforeLists = Self.lists(states)
        for id in states.map(\.assetID) {
            let ignored = states.map { $0.assetID == id ? Self.resolver.state(ignoring: $0) : $0 }
            #expect(Self.lists(ignored)[.ignored].map(\.id) == [id])
            // "Nicht mehr ignorieren": the state without the ignore, as the next count gives it.
            let back = ignored.map { $0.assetID == id ? states.first { $0.assetID == id }! : $0 }
            #expect(Self.resolver.progress(back) == before)
            #expect(Self.lists(back) == beforeLists)
        }
    }

    /// The ring never says "100 %" while a photo is open (second review 18.11.: 199 of 200
    /// rounded to "100 %"), and says it once everything counted is sorted.
    @Test func ringSaysOneHundredPercentOnlyWhenEverythingIsSorted() {
        let format = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))
        func shown(_ fully: Int, of total: Int) -> String {
            var p = OrganizationStatusResolver.Progress()
            p.fully = fully
            p.total = total
            return OrganizationStatusResolver.Progress.shownShare(p.fullyShare).formatted(format)
        }
        #expect(shown(199, of: 200) == "99%")
        #expect(shown(1_999, of: 2_000) == "99%")
        #expect(shown(99_999, of: 100_000) == "99%")
        #expect(shown(200, of: 200) == "100%")
        #expect(shown(1, of: 3) == "33%")
        #expect(shown(0, of: 0) == "0%")
        for total in 1...400 {
            for fully in 0..<total {
                #expect(OrganizationStatusResolver.Progress.shownShare(Double(fully) / Double(total)) < 1, "\(fully) von \(total)")
            }
        }
    }

    // MARK: - Many small libraries

    static let areas: [OrganizationArea] = [.places, .trips, .screenshots, .chronology, .imageCategories]

    /// A random small library: random main areas, and per photo random facts in every area,
    /// some photos ignored or excluded.
    static func randomLibrary(_ g: inout SplitMix) -> (OrganizationStatusResolver, [AssetOrganizationState]) {
        func flip(_ percent: UInt64) -> Bool { g.next() % 100 < percent }
        var primary = Set(areas.filter { _ in flip(50) })
        if primary.isEmpty { primary = [areas[Int(g.next() % UInt64(areas.count))]] }
        let resolver = OrganizationStatusResolver(primaryAreas: primary)
        let count = Int(g.next() % 40)
        var states: [AssetOrganizationState] = []
        for i in 0..<count {
            var facts: [OrganizationArea: AreaFacts] = [:]
            for area in areas where flip(85) {
                facts[area] = AreaFacts(applicable: flip(70), analyzed: flip(80), analysisImpossible: flip(10),
                                        inMatchingExistingAlbum: flip(35), organizedByAlbumist: flip(15), proposed: flip(30),
                                        pendingInPlan: flip(5), uncertain: flip(10))
            }
            states.append(resolver.state(for: AssetID("p\(i)"), facts: facts, ignored: flip(15), excluded: flip(3)))
        }
        return (resolver, states)
    }

    /// For 600 random small libraries: "Sortiert" holds exactly the ring's sorted photos,
    /// "Unsortiert" the rest of its total, "Ignoriert" the ignored ones, and every photo is
    /// counted once.
    @Test func listSortedShowsTheRingsNumberForManyLibraries() {
        var g = SplitMix(seed: 1811)
        var sawIgnored = false, sawOutside = false, sawFull = false
        for round in 0..<600 {
            let (resolver, states) = Self.randomLibrary(&g)
            let p = resolver.progress(states)
            let lists = Self.lists(states, resolver: resolver)
            let label = "library \(round): ring \(p.fully) von \(p.total)"
            #expect(lists[.organized].count == p.fully, "\(label), Sortiert \(lists[.organized].count)")
            #expect(lists[.unorganized].count == p.total - p.fully, "\(label), Unsortiert \(lists[.unorganized].count)")
            #expect(lists[.ignored].count == p.ignored, "\(label), Ignoriert \(lists[.ignored].count)")
            #expect(p.total == p.fully + p.partially + p.unorganized + p.pending, "\(label)")
            #expect(p.allPhotos == states.count, "\(label)")
            // Every sorted photo of the ring is in the list, not only as many.
            let sortedIDs = Set(states.filter { resolver.ringPart($0) == .sorted }.map(\.assetID))
            #expect(Set(lists[.organized].map(\.id)) == sortedIDs, "\(label)")
            // An ignored photo is in neither part of the ring.
            for state in states where resolver.overall(state) == .ignored {
                #expect(!resolver.ringPart(state).isCounted, "\(label): \(state.assetID)")
            }
            // Once everything counted is sorted, the ring is full.
            if p.total > 0 && p.fully == p.total { #expect(p.fullyShare == 1); sawFull = true }
            sawIgnored = sawIgnored || p.ignored > 0
            sawOutside = sawOutside || p.outsideMainAreas > 0
        }
        #expect(sawIgnored && sawOutside && sawFull)
    }

    /// The ring counts only the chosen part of the library ("Nur 2026"); a photo outside it is
    /// neither in "Sortiert" nor in "Unsortiert", but stays in "Ignoriert" when ignored, so
    /// it can be brought back.
    @Test func photosOutsideTheChosenPartAreOnlyInAll() {
        #expect(Self.resolver.buckets(Self.sorted("s"), inScope: false) == [.all])
        #expect(Self.resolver.buckets(Self.open("o"), inScope: false) == [.all, .suggestions])
        #expect(Self.resolver.buckets(Self.open("i", ignored: true), inScope: false) == [.all, .ignored])
        #expect(Self.resolver.ringPart(Self.sorted("s"), inScope: false) == .outsideScope)
    }

    // MARK: - No main area counts (finding N-01)

    /// With no main area counted, the overview says "Kein Bereich zählt als sortiert"
    /// (`SortedCountCard.noMainAreaChosen`): there is nothing to sort towards. The library's lists
    /// and the photo info said "Nicht sortiert" for every photo, the ignored ones too (finding
    /// N-01). Now no photo is counted: each is outside the main areas, ignored or excluded, so
    /// ring total (0) + outside main areas + ignored + excluded is every photo.
    /// - `[]`: none chosen ("Zählt als sortiert" empty).
    /// - `[.trips]`: chosen but turned off, so the states have no entry for it (`LibraryStatus`
    ///   gives a state only the areas that are on).
    @Test(arguments: [Set<OrganizationArea>(), [.trips]])
    func withNoCountedAreaNoPhotoIsUnsorted(primary: Set<OrganizationArea>) {
        let resolver = OrganizationStatusResolver(primaryAreas: primary)
        // "Länder und Orte" and "Bildschirmfotos" are on, neither counts.
        func state(_ id: AssetID, _ places: AreaFacts, ignored: Bool = false, excluded: Bool = false) -> AssetOrganizationState {
            resolver.state(for: id, facts: [.places: places, .screenshots: AreaFacts(applicable: false)],
                           ignored: ignored, excluded: excluded)
        }
        let notCounted = [
            state("open", AreaFacts(proposed: true)), state("inAlbum", AreaFacts(inMatchingExistingAlbum: true)),
            state("analysing", AreaFacts(analyzed: false)), state("plain", AreaFacts()),
            // Every area turned off: the state has no area at all.
            resolver.state(for: "bare", facts: [:]),
        ]
        let ignored = [state("ignored", AreaFacts(proposed: true), ignored: true),
                       resolver.state(for: "bareIgnored", facts: [:], ignored: true)]
        let excluded = [state("excluded", AreaFacts(), excluded: true),
                        state("both", AreaFacts(), ignored: true, excluded: true),
                        resolver.state(for: "bareExcluded", facts: [:], ignored: true, excluded: true)]
        let all = notCounted + ignored + excluded

        // Per photo (the photo info: `ringPart` first, then `overall`).
        for s in notCounted {
            #expect(resolver.ringPart(s) == .outsideMainAreas, "\(s.assetID): \(resolver.ringPart(s))")
            #expect(resolver.isOutsideMainAreas(s), "\(s.assetID)")
            #expect(resolver.overall(s) == .fullyOrganized, "\(s.assetID): nothing open, like a photo no main area fits")
            #expect(resolver.buckets(s) == [.all], "\(s.assetID): \(resolver.buckets(s))")
        }
        for s in ignored {
            #expect(resolver.ringPart(s) == .ignored, "\(s.assetID): \(resolver.ringPart(s))")
            #expect(resolver.overall(s) == .ignored, "\(s.assetID): the photo info offers \"Nicht mehr ignorieren\"")
            #expect(!resolver.isOutsideMainAreas(s), "\(s.assetID)")
            #expect(resolver.buckets(s) == [.all, .ignored], "\(s.assetID): \(resolver.buckets(s))")
        }
        for s in excluded {
            #expect(resolver.ringPart(s) == .excluded, "\(s.assetID): \(resolver.ringPart(s))")
            #expect(resolver.overall(s) == .excluded, "\(s.assetID)")
            #expect(resolver.buckets(s) == [.all, .excluded], "\(s.assetID): \(resolver.buckets(s))")
        }
        // Outside the chosen year: ignored and excluded keep their lists, the rest is only in "Alle".
        #expect(resolver.ringPart(notCounted[0], inScope: false) == .outsideScope)
        #expect(resolver.ringPart(ignored[0], inScope: false) == .ignored)
        #expect(resolver.ringPart(excluded[0], inScope: false) == .excluded)

        // The ring: nothing counted, every photo in exactly one group.
        let p = resolver.progress(all)
        #expect(p.total == 0 && p.fully == 0 && p.partially == 0 && p.unorganized == 0 && p.pending == 0, "\(p)")
        #expect(p.outsideMainAreas == notCounted.count && p.ignored == ignored.count && p.excluded == excluded.count, "\(p)")
        #expect(p.total + p.outsideMainAreas + p.ignored + p.excluded == all.count)
        #expect(p.allPhotos == all.count)

        // The lists agree with the ring and the card: nothing in "Nicht sortiert" or "Sortiert".
        let lists = Self.lists(all, resolver: resolver)
        #expect(lists[.unorganized].isEmpty, "\(lists[.unorganized].map(\.id))")
        #expect(lists[.organized].isEmpty, "\(lists[.organized].map(\.id))")
        #expect(lists[.suggestions].isEmpty, "a suggestion of an area that does not count is no open task here")
        #expect(Set(lists[.ignored].map(\.id)) == Set(ignored.map(\.assetID)))
        #expect(Set(lists[.excluded].map(\.id)) == Set(excluded.map(\.assetID)))
        #expect(lists[.all].count == all.count)
    }

    /// The new fields read as `false` from a state encoded without them, and round-trip.
    @Test func stateDecodesWithoutTheNewFields() throws {
        let resolver = OrganizationStatusResolver(primaryAreas: [.places])
        let ignored = resolver.state(for: "i", facts: [.places: AreaFacts(proposed: true)], ignored: true)
        let data = try JSONEncoder().encode(ignored)
        #expect(try JSONDecoder().decode(AssetOrganizationState.self, from: data) == ignored)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["isIgnored"] as? Bool == true)
        object["isIgnored"] = nil
        object["isExcluded"] = nil
        let old = try JSONDecoder().decode(AssetOrganizationState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.isIgnored && !old.isExcluded)
        #expect(old.areas == ignored.areas && old.assetID == ignored.assetID)
        #expect(resolver.overall(old) == .ignored, "its areas still say it")
    }

    /// Random small libraries in which no main area counts (none chosen, or the chosen ones
    /// absent from the states because they are off): no photo is counted, the lists "Sortiert"
    /// and "Nicht sortiert" stay empty, and every photo is outside the main areas, ignored or
    /// excluded.
    @Test func withNoCountedAreaTheGroupsStillAddUpForManyLibraries() {
        var g = SplitMix(seed: 2011)
        for round in 0..<300 {
            let (counting, states) = Self.randomLibrary(&g)
            // The same photos with the main areas removed from their states (turned off), or
            // with none chosen.
            let resolver: OrganizationStatusResolver
            let shown: [AssetOrganizationState]
            if round % 2 == 0 {
                resolver = OrganizationStatusResolver(primaryAreas: [])
                shown = states
            } else {
                resolver = counting
                shown = states.map { s in
                    var s = s
                    for area in counting.primaryAreas { s.areas[area] = nil }
                    return s
                }
            }
            let p = resolver.progress(shown)
            let lists = Self.lists(shown, resolver: resolver)
            let label = "library \(round): \(p)"
            #expect(p.total == 0, "\(label)")
            #expect(p.outsideMainAreas + p.ignored + p.excluded == shown.count, "\(label)")
            #expect(lists[.organized].isEmpty && lists[.unorganized].isEmpty, "\(label)")
            #expect(lists[.ignored].count == p.ignored && lists[.excluded].count == p.excluded, "\(label)")
            // Ignored and excluded photos keep their status (the counting resolver sees the same).
            for (s, original) in zip(shown, states) {
                let before = counting.overall(original)
                if before == .ignored || before == .excluded {
                    #expect(resolver.overall(s) == before, "\(label): \(s.assetID)")
                }
            }
        }
    }
}

extension OrganizationStatusResolver {
    /// The state of a photo once it is ignored (every area "ignored"), as the next count gives it.
    func state(ignoring s: AssetOrganizationState) -> AssetOrganizationState {
        var result = s
        for area in s.areas.keys where s.areas[area] != .excluded { result.areas[area] = .ignored }
        return result
    }
}
