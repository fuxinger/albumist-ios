import Foundation
import Synchronization
import Testing
@testable import AlbumistEngine
import AlbumistCore
import AlbumistTestSupport

/// Review P4-09: passes over all photos that ran on the main actor when a screen asked, measured
/// on Linux at 50,000 and 100,000 photos (release build, review appendix A): the places of "Dein
/// Zuhause" 322 / 672 ms, the facts by id at the first lookup after every refresh 97 / 267 ms,
/// the atlas of one year 75 / 151 ms, the statuses of a search like "nicht sortiert" 27 / 62 ms.
/// They run off the main actor now: the app makes them in a `Task.detached` closure or gets them
/// made with the facts (`DerivedLibrary`, `DerivedRefresh`); `DerivedRefreshAppTests` checks the
/// app's code for it. What only one screen needs (the places of "Dein Zuhause", the atlas of each
/// year, the name of the detected home) is made only when that screen asks, never at a refresh
/// (second review of P4-09, SHOULD-1). This test keeps the cost of each pass in sight with a limit per pass (the
/// work moved, it did not go away: it still costs battery and delays what waits for it), and
/// checks that the main actor stays free while the app's way of calling each pass runs.
/// Part of the load test (`LoadTests`: ALBUMIST_LOAD_TEST=1, one test after the other, so the
/// times are not taken beside a run of 100,000 photos).
enum MainThreadWork {
    /// The country of each city of `LoadTests.stressLibrary` (same order), with a region.
    static let countries: [(code: String, region: String)] = [
        ("FR", "Île-de-France"), ("ES", "Katalonien"), ("US", "New York"), ("AT", "Wien"), ("NO", "Møre og Romsdal"),
        ("HR", "Split-Dalmatien"), ("PT", "Lissabon"), ("IT", "Toskana"), ("DK", "Hovedstaden"), ("IS", "Höfuðborgarsvæðið"),
        ("IT", "Latium"), ("JP", "Kyōto"), ("GB", "England"), ("DE", "Berlin"), ("IT", "Venetien"),
        ("GR", "Attika"), ("CZ", "Prag"), ("HU", "Budapest"), ("SE", "Stockholm"), ("FI", "Uusimaa"),
        ("IE", "Leinster"), ("GB", "Schottland"), ("ES", "Madrid"), ("ES", "Andalusien"), ("FR", "Provence"),
        ("FR", "Auvergne-Rhône-Alpes"), ("CH", "Genf"), ("CH", "Zürich"), ("BE", "Brüssel"), ("NL", "Nordholland"),
        ("US", "Kalifornien"), ("US", "Kalifornien"), ("US", "Florida"), ("MX", "Mexiko-Stadt"), ("AU", "New South Wales"),
        ("AU", "Victoria"), ("SG", "Singapur"), ("TH", "Bangkok"), ("HK", "Hongkong"), ("JP", "Tokio"),
    ]

    /// The facts of the stress run's library (`LoadTests.stressLibrary`), as the analysis gives
    /// them: every photo with its town, every fifth stay at home in Munich, the others trips;
    /// every tenth photo a screenshot without a place.
    static func facts(_ count: Int) -> [AssetFacts] {
        LoadTests.stressLibrary(count).enumerated().map { index, asset in
            var asset = asset
            let trip = index / 25
            if index % 10 == 9 {
                asset.subtypes = .screenshot
                asset.location = nil
                return AssetFacts(asset: asset)
            }
            let home = trip % 5 == 4
            let city = trip % countries.count
            let place = home
                ? PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München")
                : PlaceComponents(isoCountryCode: countries[city].code, country: countries[city].code,
                                  administrativeArea: countries[city].region, locality: "Stadt \(city)")
            return AssetFacts(asset: asset, place: place, placeSource: .gpsReverseGeocoded, tripID: home ? nil : AlbumistID("trip-\(trip)"))
        }
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// The shortest of three runs of `work`.
    static func fastest<T>(_ work: () -> T) -> (Duration, T) {
        var best: Duration?
        var value: T?
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let made = work()
            let took = ContinuousClock.now - start
            if best == nil || took < best! { best = took }
            value = made
        }
        return (best!, value!)
    }

    /// The longest the main actor was not free while `work` ran the way the app runs it
    /// (`Task.detached` from the main actor, awaited there): a task on the main actor wakes every
    /// millisecond and notes the longest gap.
    @MainActor
    static func mainActorStall<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> (stall: Duration, took: Duration) {
        let running = Locked(true)
        let longest = Locked(Duration.zero)
        let ticker = Task { @MainActor in
            var last = ContinuousClock.now
            while running.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(1))
                let now = ContinuousClock.now
                longest.withLock { $0 = max($0, now - last) }
                last = now
            }
        }
        // Let the ticker start before the work does.
        try? await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        _ = await Task.detached(priority: .userInitiated) { work() }.value
        let took = ContinuousClock.now - start
        running.withLock { $0 = false }
        await ticker.value
        return (longest.withLock { $0 }, took)
    }

    /// The longest gap of the same ticker while a detached task only sleeps for `span`: what the
    /// machine's own load (other jobs on the Mac, the scheduler of a 3-core VM) costs the main
    /// actor without any of the app's work. Core tests hard (macOS) in UI run 45931544058: the
    /// main actor stood 59.8 ms while `DerivedLibrary.yearAtlases` ran at 50,000 photos, on a Mac
    /// on which the whole load test took 20 % longer than two hours before (138 s for 100,000
    /// photos instead of 113 s), with no change to the code.
    @MainActor
    static func baselineStall(for span: Duration) async -> Duration {
        let seconds = ms(span) / 1000
        return await mainActorStall { Thread.sleep(forTimeInterval: seconds) }.stall
    }

    /// The part of `stall` that the work itself caused: what is over the `baseline` of the
    /// ticker without the work (the smaller of two windows right after it), never below zero. Work
    /// on the main actor shows as a stall as long as that work (a pass of 60 ms and more over all
    /// photos), the machine's load as a gap the baseline has too.
    static func ownStall(_ stall: Duration, baseline: Duration) -> Duration {
        max(.zero, stall - baseline)
    }

}

extension LoadTests {
    /// See `MainThreadWork`.
    @MainActor
    @Test(arguments: [50_000, 100_000])
    func passesOverAllPhotosHaveTheirLimitsAndLeaveTheMainActorFree(photos: Int) async throws {
        let facts = MainThreadWork.facts(photos)
        let settings = OrganizationSettings()
        let resolver = OrganizationStatusResolver(primaryAreas: settings.primaryAreas)
        let states = DerivedLibraryStatus.derive(facts: facts, snapshot: nil, settings: settings, overrides: OverrideSet(),
                                                 contents: [:], managed: [], inventory: CollectionInventory(), scope: .all).states
        #expect(states.count == facts.count)
        let munich = Fixture.Places.munichHome
        var lines: [String] = []
        func note(_ name: String, _ took: Duration, before: Duration? = nil, where place: String = "off the main actor") {
            let was = before.map { String(format: ", on the main actor before %.1f ms", MainThreadWork.ms($0)) } ?? ""
            lines.append(String(format: "MAIN_WORK %d %@: %.1f ms %@%@", photos, name, MainThreadWork.ms(took), place, was))
        }

        // The places of "Dein Zuhause" (made when the screen asks, `AppModel.homeCandidates`).
        let (candidatesTook, candidates) = MainThreadWork.fastest { HomeCandidates.make(facts: facts) }
        #expect(candidates.count > 10)
        note("HomeCandidates.make", candidatesTook)
        // The start of the stay at a place picked as home (`AppModel.homeStayStart`).
        let (stayTook, stay) = MainThreadWork.fastest { HomeCandidates.stayStart(near: munich, assets: facts.lazy.map { $0.asset }) }
        #expect(stay != nil)
        note("HomeCandidates.stayStart", stayTook)
        // The name of the detected home (`AppModel.detectedHomePlace`, when "Dein Zuhause" or the
        // settings ask: `DerivedLibrary.namedHome`).
        let (nameTook, name) = MainThreadWork.fastest { DerivedLibrary.namedHome(at: munich, facts: facts) }
        #expect(name?.components?.locality == "München")
        note("DerivedLibrary.namedHome", nameTook)
        // The facts by id (`DerivedLibrary.factsByID`); before: a dictionary of all facts.
        let (dictionaryTook, dictionary) = MainThreadWork.fastest { Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let (byIDTook, byID) = MainThreadWork.fastest { FactsByID(facts) }
        #expect(byID.count == dictionary.count)
        note("FactsByID", byIDTook, before: dictionaryTook)
        // What is left on the main actor: looking photos up (a photo view, a page of search hits).
        let ids = facts.prefix(1_000).map(\.id)
        let (lookupTook, found) = MainThreadWork.fastest { ids.reduce(0) { $0 + (byID[$1] == nil ? 0 : 1) } }
        #expect(found == ids.count)
        note("FactsByID 1,000 lookups", lookupTook, where: "on the main actor")
        // The atlas of every year (`DerivedLibrary.yearAtlases`, when the atlas's year picker asks:
        // `AppModel.travelAtlas(year:)`); before: one year on the main actor when it was chosen,
        // the atlas of all years made again inside.
        let allYears = TravelAtlas.compute(facts: facts, year: nil)
        let year = try #require(TravelAtlas.years(facts: facts).first)
        let (oneYearTook, oneYear) = MainThreadWork.fastest { TravelAtlas.compute(facts: facts, year: year) }
        let (yearsTook, atlases) = MainThreadWork.fastest { DerivedLibrary.yearAtlases(of: facts, allYears: allYears) }
        #expect(atlases?[year] == oneYear)
        #expect((atlases?.count ?? 0) >= 10)
        note("DerivedLibrary.yearAtlases (\(atlases?.count ?? 0) years)", yearsTook, before: oneYearTook)
        // The facts read compared with those on screen, at every refresh with as many photos
        // (`derivedLibrary(shown:)`, off the main thread; delta review, N2). Another copy: two
        // arrays of the same storage are equal at once.
        let other = MainThreadWork.facts(photos)
        let (compareTook, equal) = MainThreadWork.fastest { facts == other }
        #expect(equal)
        note("[AssetFacts] == (unchanged facts)", compareTook)
        // The statuses of a search like "nicht sortiert" (`AppModel.plainSearch`).
        let (statusesTook, statuses) = MainThreadWork.fastest {
            LibraryStatus.searchStatuses(facts: facts, states: states, resolver: resolver, scope: .all)
        }
        #expect(statuses.count >= facts.count * 8 / 10)
        note("LibraryStatus.searchStatuses", statusesTook)

        // The main actor stays free while each runs the way the app runs it.
        let passes: [(String, @Sendable () -> Int)] = [
            ("HomeCandidates.make", { HomeCandidates.make(facts: facts).count }),
            ("FactsByID", { FactsByID(facts).count }),
            ("DerivedLibrary.yearAtlases", { DerivedLibrary.yearAtlases(of: facts, allYears: allYears)?.count ?? 0 }),
            ("DerivedLibrary.namedHome", { DerivedLibrary.namedHome(at: munich, facts: facts)?.components == nil ? 0 : 1 }),
            ("LibraryStatus.searchStatuses", { LibraryStatus.searchStatuses(facts: facts, states: states, resolver: resolver, scope: .all).count }),
            ("HomeCandidates.stayStart", { HomeCandidates.stayStart(near: munich, assets: facts.lazy.map { $0.asset }) == nil ? 0 : 1 }),
        ]
        var stalls: [(String, Duration, Duration)] = []
        for (name, pass) in passes {
            let (stall, took) = await MainThreadWork.mainActorStall(pass)
            // The machine's own load, on the same ticker for as long as the pass took, in two
            // windows right after it: only what is over the smaller of the two counts (the
            // smaller, so a spike in one window cannot hide work on the main actor).
            let first = await MainThreadWork.baselineStall(for: took)
            let second = await MainThreadWork.baselineStall(for: took)
            let baseline = min(first, second)
            let own = MainThreadWork.ownStall(stall, baseline: baseline)
            stalls.append((name, own, took))
            lines.append(String(format: "MAIN_STALL %d %@: main actor free but for %.1f ms while it ran %.1f ms (%.1f ms without the work, %.1f ms its own)",
                                photos, name, MainThreadWork.ms(stall), MainThreadWork.ms(took), MainThreadWork.ms(baseline), MainThreadWork.ms(own)))
        }
        for line in lines { print(line) }

        // Limits per pass (debug build, as the load step of ci.yml runs it; measured on Linux
        // with 4 cores, see docs/TEST_PLAN.md): about three times the measurement, so a pass that
        // grows by more than that is red. At 100,000 photos the double.
        let scale = photos / 50_000
        // measured 844-1,165 / 2,175-2,721 ms
        #expect(TimingLimit.holds(candidatesTook, under: .milliseconds(3_500) * scale, "HomeCandidates.make"),
                "HomeCandidates.make took \(candidatesTook)")
        // measured 126-193 / 388-396 ms
        #expect(TimingLimit.holds(stayTook, under: .milliseconds(600) * scale, "HomeCandidates.stayStart"),
                "HomeCandidates.stayStart took \(stayTook)")
        // measured 243-274 / 475-554 ms
        #expect(TimingLimit.holds(nameTook, under: .milliseconds(800) * scale, "DerivedLibrary.namedHome"),
                "DerivedLibrary.namedHome took \(nameTook)")
        #expect(TimingLimit.holds(byIDTook, under: .milliseconds(200) * scale, "FactsByID"), "FactsByID took \(byIDTook)") // measured 40-54 / 89-96 ms
        #expect(TimingLimit.holds(lookupTook, under: .milliseconds(5), "1,000 lookups"), "1,000 lookups took \(lookupTook)") // measured 0.5-0.8 ms
        // measured 277-349 / 482-716 ms
        #expect(TimingLimit.holds(yearsTook, under: .milliseconds(1_000) * scale, "DerivedLibrary.yearAtlases"),
                "DerivedLibrary.yearAtlases took \(yearsTook)")
        // measured 149 / 226 ms
        #expect(TimingLimit.holds(compareTook, under: .milliseconds(500) * scale, "comparing the facts"),
                "comparing the facts took \(compareTook)")
        // measured 320-377 / 722-1,011 ms
        #expect(TimingLimit.holds(statusesTook, under: .milliseconds(1_200) * scale, "LibraryStatus.searchStatuses"),
                "LibraryStatus.searchStatuses took \(statusesTook)")
        // The main actor: never held for anything near a pass (Apple counts a hang from 250 ms;
        // under 100 ms one seldom notices). Measured 1.4 to 12 ms, the ticker's own rhythm. The
        // limit is on the work's own stall (`ownStall`): over what the ticker shows without the
        // work on the same machine, so a busy Mac is not read as work on the main actor.
        for (name, stall, took) in stalls {
            #expect(TimingLimit.holds(stall, under: .milliseconds(50), "main actor stall while \(name) ran"),
                    "the main actor stood \(stall) longer than without the work while \(name) ran \(took)")
        }
    }
}
