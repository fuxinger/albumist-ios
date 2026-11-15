import Foundation
import Testing
@testable import SortlyCore

/// Settings and decisions stored by an earlier version stay readable after an update adds
/// fields (plugin review 15.11., K3: the app would not start after the next build).
@Suite("Stored values from earlier versions")
struct StoredDefaultsTests {
    /// A settings type as a later version has it: `count`, `nested.label` and `extra` are new.
    struct Later: Codable, Equatable {
        enum Scope: Codable, Equatable { case all, year(Int) }
        struct Nested: Codable, Equatable {
            var level = 1
            var label = "neu"
        }
        var scope: Scope = .all
        var count = 7
        var nested = Nested()
        var categories: Set<String> = ["a", "b", "c"]
        var names: [String: String] = [:]
        var extra: Nested = Nested(level: 9, label: "extra")
    }

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    let decoder = JSONDecoder()

    func decode(_ json: String) throws -> Later {
        try StoredDefaults.decode(Later.self, from: Data(json.utf8), defaults: Later(), encoder: encoder, decoder: decoder)
    }

    @Test func missingFieldsComeFromTheDefaultsAtEveryDepth() throws {
        // Written by the earlier version: no `count`, no `nested.label`, no `extra`.
        let value = try decode(#"{"scope": {"year": {"_0": 2025}}, "nested": {"level": 4}, "categories": ["a"], "names": {"x": "Zuhause"}}"#)
        #expect(value.scope == .year(2025))
        #expect(value.count == 7)
        #expect(value.nested == .init(level: 4, label: "neu"))
        #expect(value.extra == .init(level: 9, label: "extra"))
        // What the user chose stays whole: a new category does not switch itself on.
        #expect(value.categories == ["a"])
        #expect(value.names == ["x": "Zuhause"])
        // Synthesized decoding alone fails on the same data (why this exists).
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Later.self, from: Data(#"{"scope": {"all": {}}}"#.utf8))
        }
    }

    @Test func anEnumCaseIsKeptWholeAndNeverMixedWithTheDefaultCase() throws {
        var later = Later()
        later.scope = .year(2024)
        let defaults = Later()
        // Stored `year` against the default `all`: the stored case wins as it is.
        let merged = StoredDefaults.merge(["year": ["_0": 2024]], over: ["all": [String: Any]()])
        #expect((merged as? [String: Any])?.keys.sorted() == ["year"])
        let value = try StoredDefaults.decode(Later.self, from: Data(#"{"scope": {"year": {"_0": 2024}}}"#.utf8),
                                              defaults: defaults, encoder: encoder, decoder: decoder)
        #expect(value.scope == later.scope)
    }

    @Test func fieldsThatNoLongerExistAreIgnored() throws {
        let value = try decode(#"{"count": 3, "removedLongAgo": true, "nested": {"level": 2, "label": "x", "old": 1}}"#)
        #expect(value.count == 3)
        #expect(value.nested == .init(level: 2, label: "x"))
    }

    @Test func aValueOfThisVersionReadsExactlyAsWritten() throws {
        var settings = OrganizationSettings()
        settings.trips.minPhotos = 25
        settings.places.includesCities = true
        settings.privacy.allowOnlineGeocoding = false
        settings.imageCategories.disabledCategories = ["Essen"]
        settings.rootFolderTitle = "Meine Alben"
        let data = try encoder.encode(settings)
        let read = try StoredDefaults.decode(OrganizationSettings.self, from: data, defaults: OrganizationSettings(), encoder: encoder, decoder: decoder)
        #expect(read == settings)
    }

    @Test func realSettingsFromAnEarlierVersionKeepEveryChoice() throws {
        var settings = OrganizationSettings()
        settings.trips.minPhotos = 25
        settings.trips.folderPerYear = false
        settings.places.includesCities = true
        settings.privacy.allowOnlineGeocoding = false
        settings.people.advanced.minGroupSize = 5
        settings.enabledAreas.remove(.screenshots)
        // As an earlier version stored it: some fields at several depths did not exist yet.
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any])
        json["messenger"] = nil
        var trips = try #require(json["trips"] as? [String: Any])
        trips["includeDayTrips"] = nil
        var advanced = try #require(trips["advanced"] as? [String: Any])
        advanced.removeValue(forKey: try #require(advanced.keys.sorted().first))
        trips["advanced"] = advanced
        json["trips"] = trips
        var people = try #require(json["people"] as? [String: Any])
        var grouper = try #require(people["advanced"] as? [String: Any])
        grouper["distanceThreshold"] = nil
        people["advanced"] = grouper
        json["people"] = people
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try decoder.decode(OrganizationSettings.self, from: old) }

        let read = try StoredDefaults.decode(OrganizationSettings.self, from: old, defaults: OrganizationSettings(), encoder: encoder, decoder: decoder)
        #expect(read == settings)
    }
}
