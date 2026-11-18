import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Review finding G1-05 (18.11.2026): a place the user named ("Mein Kleingarten") was found by the
/// search only once its album existed. The app keeps the name as the title of the place's
/// suggestion (`user.titles`); the search index only knew names from the settings, and the app
/// built it without any. Built here like `AppModel.searchIndex()` builds it.
@Suite("Search: places the user named (G1-05)")
struct NamedPlaceSearchTests {
    static let gardenSpot = GeoCoordinate(latitude: 48.1800, longitude: 11.5200)
    let now = Fixture.date("2026-11-18 12:00")

    struct Library {
        var facts: [AssetFacts]
        var suggestions: [AlbumProposal]
        var garden: Set<AssetID>
        var home: Set<AssetID>
        var rome: Set<AssetID>
        var gardenID: SortlyID
        var homeID: SortlyID
    }

    /// Munich every other evening, a garden on the edge of town every Saturday from April to
    /// September, three days in Rome; facts and suggestions as the analysis makes them.
    func library() throws -> Library {
        var lib = LibraryBuilder()
        let home = lib.daily(from: "2026-01-01", to: "2026-10-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2, hour: 19)
        let garden = lib.daily(from: "2026-04-04", to: "2026-09-26", at: Self.gardenSpot, perDay: 3, everyNthDay: 7, hour: 10)
        let rome = lib.daily(from: "2026-05-12", to: "2026-05-14", at: Fixture.Places.rome, perDay: 3, hour: 11)
        let places = FrequentPlaceDetector(calendar: Fixture.calendar).detect(in: lib.assets)
        // As `FactsAssembler` does it: each photo carries the ID of its frequent place.
        var placeOf: [AssetID: SortlyID] = [:]
        for place in places { for id in place.assetIDs { placeOf[id] = place.id } }
        let facts = FixtureGeocoder.facts(for: lib.assets).map { f in
            var f = f
            f.frequentPlaceID = placeOf[f.id]
            return f
        }
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let suggestions = ProposalEngine(settings: settings, calendar: Fixture.calendar)
            .proposals(for: AnalysisSnapshot(facts: facts, frequentPlaces: places))
        let gardenPlace = try #require(suggestions.first { $0.kind == .frequentPlace && $0.assetIDs == Set(garden) })
        let homePlace = try #require(suggestions.first { $0.kind == .frequentPlace && $0.assetIDs == Set(home) })
        // Unnamed: the suggestion asks for a name ("Name fehlt").
        #expect(gardenPlace.requiresUserName)
        return Library(facts: facts, suggestions: suggestions, garden: Set(garden), home: Set(home), rome: Set(rome),
                       gardenID: gardenPlace.id, homeID: homePlace.id)
    }

    /// Like `AppModel.searchIndex()`: the facts, the albums, and the names of places from the
    /// titles typed in the app and the settings.
    func appIndex(_ lib: Library, titles: [SortlyID: String], inventory: CollectionInventory = CollectionInventory(),
                  facts: [AssetFacts]? = nil, settings: FrequentPlaceSettings = FrequentPlaceSettings(),
                  suggestions: [AlbumProposal]? = nil) -> SearchIndex {
        SearchIndex(facts: facts ?? lib.facts, inventory: inventory,
                    namedPlaces: NamedPlace.resolve(titles: titles, settings: settings, suggestions: suggestions ?? lib.suggestions),
                    calendar: Fixture.calendar)
    }

    /// Whether the query reads a term as the place with this ID.
    func mentions(_ query: SearchQuery, _ id: SortlyID) -> Bool {
        func contains(_ criterion: SearchCriterion) -> Bool {
            switch criterion {
            case .frequentPlace(let place): place == id
            case .any(let list), .all(let list): list.contains(where: contains)
            default: false
            }
        }
        return query.clauses.contains { $0.alternatives.contains(where: contains) }
    }

    @Test func theNameFindsThePlaceBeforeItsAlbumExists() throws {
        let lib = try library()
        // Not named yet: the words mean nothing in this library.
        #expect(appIndex(lib, titles: [:]).search("Mein Kleingarten", now: now).ids.isEmpty)

        // Named in the suggestion, no album in Photos.
        let index = appIndex(lib, titles: [lib.gardenID: "Mein Kleingarten"])
        let result = index.search("Mein Kleingarten", now: now)
        #expect(Set(result.ids) == lib.garden)
        #expect(result.ids.count == lib.garden.count)
        #expect(result.tokens.map(\.kind) == [.place])
        #expect(result.tokens.first?.label == "Mein Kleingarten")
        #expect(result.tokens.first?.count == lib.garden.count)
        // Like any place, together with other terms: the garden in May (five Saturdays).
        let may = lib.facts.filter { lib.garden.contains($0.id) && Fixture.calendar.component(.month, from: $0.asset.creationDate!) == 5 }
        #expect(may.count == 15)
        #expect(Set(index.search("Mein Kleingarten Mai", now: now).ids) == Set(may.map(\.id)))
        // Two places: either one, like "Rom Florenz".
        #expect(Set(index.search("Mein Kleingarten Rom", now: now).ids) == lib.garden.union(lib.rome))
        // Offered while typing, like a town or an album.
        let offered = index.suggestions(for: "Klein")
        #expect(offered.filter { $0.label == "Mein Kleingarten" }.count == 1)
        let entry = try #require(offered.first { $0.label == "Mein Kleingarten" })
        #expect(entry.kind == .place)
        #expect(entry.count == lib.garden.count)
        #expect(entry.completion == "Mein Kleingarten")
    }

    @Test func aRenamedPlaceIsFoundByItsNewNameOnly() throws {
        let lib = try library()
        let before = appIndex(lib, titles: [lib.gardenID: "Mein Kleingarten"])
        #expect(Set(before.search("Mein Kleingarten", now: now).ids) == lib.garden)

        let after = appIndex(lib, titles: [lib.gardenID: "Schrebergarten Nord"])
        #expect(Set(after.search("Schrebergarten Nord", now: now).ids) == lib.garden)
        #expect(after.search("Mein Kleingarten", now: now).ids.isEmpty)
        #expect(!mentions(after.parse("Mein Kleingarten", now: now), lib.gardenID))
        #expect(!after.suggestions(for: "Klein").contains { $0.label == "Mein Kleingarten" })
        #expect(after.suggestions(for: "Schreber").contains { $0.label == "Schrebergarten Nord" })
    }

    @Test func aNameTakenBackIsNotFoundAnyMore() throws {
        let lib = try library()
        #expect(Set(appIndex(lib, titles: [lib.gardenID: "Mein Kleingarten"]).search("Mein Kleingarten", now: now).ids) == lib.garden)
        // Removed, or left empty: no name.
        for titles: [SortlyID: String] in [[:], [lib.gardenID: ""], [lib.gardenID: "   "]] {
            let index = appIndex(lib, titles: titles)
            #expect(index.search("Mein Kleingarten", now: now).ids.isEmpty)
            #expect(!mentions(index.parse("Mein Kleingarten", now: now), lib.gardenID))
            #expect(!index.suggestions(for: "Klein").contains { $0.label == "Mein Kleingarten" })
            #expect(NamedPlace.resolve(titles: titles, suggestions: lib.suggestions).isEmpty)
        }
    }

    @Test func theAlbumMadeLaterGivesOneResult() throws {
        let lib = try library()
        let titles = [lib.gardenID: "Mein Kleingarten"]
        let before = appIndex(lib, titles: titles).search("Mein Kleingarten", now: now)
        #expect(Set(before.ids) == lib.garden)

        // "Album anlegen" with the name: the album holds the place's photos, the facts know it.
        let album = CollectionSnapshot(id: "album-garden", title: "Mein Kleingarten", assetIDs: lib.garden)
        let facts = lib.facts.map { f in
            var f = f
            if lib.garden.contains(f.id) { f.albumIDs.insert(album.id) }
            return f
        }
        let index = appIndex(lib, titles: titles, inventory: CollectionInventory([album]), facts: facts)
        let after = index.search("Mein Kleingarten", now: now)
        #expect(after.ids == before.ids)
        #expect(Set(after.ids).count == after.ids.count)
        #expect(after.tokens.count == 1)
        #expect(after.tokens.first?.kind == .place)
        #expect(after.tokens.first?.label == "Mein Kleingarten")
        #expect(after.tokens.first?.count == lib.garden.count)
        let offered = index.suggestions(for: "Klein").filter { $0.label.lowercased() == "mein kleingarten" }
        #expect(offered.count == 1)
        #expect(offered.first?.count == lib.garden.count)
    }

    /// A name with a word that is also a date ("Sommer") stays the place once the album of the
    /// same name exists, as before: not "Haus" in the summer months.
    @Test func aNameWithADateWordStaysThePlaceOnceItsAlbumExists() throws {
        let lib = try library()
        let titles = [lib.gardenID: "Haus Sommer"]
        #expect(Set(appIndex(lib, titles: titles).search("Haus Sommer", now: now).ids) == lib.garden)
        let album = CollectionSnapshot(id: "album-garden", title: "Haus Sommer", assetIDs: lib.garden)
        let facts = lib.facts.map { f in
            var f = f
            if lib.garden.contains(f.id) { f.albumIDs.insert(album.id) }
            return f
        }
        let result = appIndex(lib, titles: titles, inventory: CollectionInventory([album]), facts: facts).search("Haus Sommer", now: now)
        #expect(Set(result.ids) == lib.garden)
        #expect(result.tokens.map(\.kind) == [.place])
    }

    @Test func caseUmlautsAndSharpSDoNotMatter() throws {
        let lib = try library()
        let index = appIndex(lib, titles: [lib.gardenID: "Häuschen bei Großvater"])
        for typed in ["Häuschen bei Großvater", "häuschen bei großvater", "HÄUSCHEN BEI GROSSVATER", "Haeuschen bei Grossvater",
                      "hauschen bei grossvater"] {
            let result = index.search(typed, now: now)
            #expect(Set(result.ids) == lib.garden, "\(typed)")
            #expect(result.tokens.first?.label == "Häuschen bei Großvater", "\(typed)")
        }
        #expect(index.suggestions(for: "häusch").contains { $0.label == "Häuschen bei Großvater" })
        #expect(index.suggestions(for: "HAUSCH").contains { $0.label == "Häuschen bei Großvater" })
    }

    @Test func twoPlacesWithTheSameNameAreOneTerm() throws {
        let lib = try library()
        let index = appIndex(lib, titles: [lib.gardenID: "Unser Garten", lib.homeID: "unser garten"])
        let result = index.search("Unser Garten", now: now)
        #expect(Set(result.ids) == lib.garden.union(lib.home))
        #expect(result.tokens.count == 1)
        let offered = index.suggestions(for: "Unser Gar").filter { $0.label.lowercased() == "unser garten" }
        #expect(offered.count == 1)
        #expect(offered.first?.count == lib.garden.count + lib.home.count)
    }

    /// A place the user said they are often at ("Bist du hier öfter?") gets a place suggestion
    /// whose photos the facts do not mark; renamed under "Anpassen", it is found by that name.
    @Test func aPlaceTheUserIsOftenAtIsFoundByTheNameTheyGaveIt() throws {
        let lib = try library()
        let often = AlbumProposal(id: RecurringPlaces.proposalID(for: SortlyID("answer-rome")), kind: .frequentPlace, title: "Rom",
                                  folderPath: ["Orte"], assetIDs: lib.rome, reliability: .certain, isSensitive: true)
        let index = appIndex(lib, titles: [often.id: "Ferienwohnung Trastevere"], suggestions: lib.suggestions + [often])
        #expect(Set(index.search("Ferienwohnung Trastevere", now: now).ids) == lib.rome)
        #expect(Set(index.search("Rom", now: now).ids) == lib.rome) // the town still finds it
    }

    /// Two places Albumist keeps a name: the title typed in the app wins over a name in the
    /// settings (`FrequentPlaceSettings.names`), which is found on its own.
    @Test func theTypedTitleWinsOverANameInTheSettings() throws {
        let lib = try library()
        var settings = FrequentPlaceSettings()
        settings.names[lib.gardenID] = "Parzelle 12"
        let onlySettings = appIndex(lib, titles: [:], settings: settings)
        #expect(Set(onlySettings.search("Parzelle 12", now: now).ids) == lib.garden)

        let both = appIndex(lib, titles: [lib.gardenID: "Mein Kleingarten"], settings: settings)
        #expect(Set(both.search("Mein Kleingarten", now: now).ids) == lib.garden)
        #expect(!mentions(both.parse("Parzelle 12", now: now), lib.gardenID))
    }

    /// Only places: the title of a trip is no place name, and a name is passed on trimmed.
    @Test func onlyPlacesAreNamedPlaces() throws {
        let lib = try library()
        let trip = AlbumProposal(id: .stable("trip", "rome-2026"), kind: .trip, title: "Rom Mai 2026", assetIDs: lib.rome)
        let resolved = NamedPlace.resolve(titles: [trip.id: "Hochzeitsreise", lib.gardenID: "  Mein Kleingarten "],
                                          suggestions: lib.suggestions + [trip])
        #expect(resolved == [NamedPlace(id: lib.gardenID, name: "Mein Kleingarten", assetIDs: lib.garden)])
    }

    /// A named frequent place without its suggestion right now (a trial year makes none, more than
    /// five unnamed ones are not offered) is still found: its photos carry its ID.
    @Test func aNamedPlaceWithoutItsSuggestionRightNowIsStillFound() throws {
        let lib = try library()
        let index = appIndex(lib, titles: [lib.gardenID: "Mein Kleingarten"], suggestions: [])
        #expect(Set(index.search("Mein Kleingarten", now: now).ids) == lib.garden)
    }
}
