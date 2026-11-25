import Foundation
import Testing
import AlbumistCore

/// The switch "Apples Karte verwenden" (map concept 2.0 §8, decision Fuchs 20.11.2026).
@Suite("Map settings")
struct MapSettingsTests {
    @Test func appleMapIsOnByDefault() {
        #expect(PrivacySettings().useAppleMaps)
        #expect(OrganizationSettings().privacy.useAppleMaps)
    }

    /// Settings stored by a build without the switch read as on (the default), and the user's
    /// other privacy choices stay as they were.
    @Test func settingsStoredBeforeTheSwitchReadAsOn() throws {
        var old = OrganizationSettings()
        old.privacy.allowOnlineGeocoding = false
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        var privacy = try #require(json["privacy"] as? [String: Any])
        privacy.removeValue(forKey: "useAppleMaps")
        json["privacy"] = privacy
        let data = try JSONSerialization.data(withJSONObject: json)
        let read = try StoredDefaults.decode(OrganizationSettings.self, from: data, defaults: OrganizationSettings(), encoder: encoder, decoder: decoder)
        #expect(read.privacy.useAppleMaps)
        #expect(!read.privacy.allowOnlineGeocoding)
    }

    @Test func aSwitchedOffAppleMapStaysOff() throws {
        var settings = OrganizationSettings()
        settings.privacy.useAppleMaps = false
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let read = try StoredDefaults.decode(OrganizationSettings.self, from: encoder.encode(settings), defaults: OrganizationSettings(),
                                             encoder: encoder, decoder: decoder)
        #expect(!read.privacy.useAppleMaps)
    }
}
