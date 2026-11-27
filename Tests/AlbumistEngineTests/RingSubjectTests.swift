import Foundation
import Testing
import AlbumistCore
import AlbumistEngine

/// The ring's second line on the start page (overview draft B, 19.11.): "Reisefotos sortiert"
/// while only "Reisen" and "Länder und Orte" count, "Fotos sortiert" as soon as another area
/// counts too, with the year of "Nur 2026"; the word "Hauptbereiche" leaves the page.
@Suite("Ring subject")
struct RingSubjectTests {
    @Test func theStandardCountsTravelPhotos() {
        let settings = OrganizationSettings()
        #expect(SortedCountCard.countedAreas(settings) == [.places, .trips])
        #expect(SortedCountCard.subject(settings: settings, scope: .all) == .travelPhotos(year: nil))
        #expect(SortedCountCard.subject(settings: settings, scope: .year(2026)) == .travelPhotos(year: 2026))
        #expect(SortedCountCard.subject(settings: settings, scope: .all).isTravel)
    }

    /// One of the two alone is still travel photos.
    @Test func oneOfTheTwoAloneIsStillTravel() {
        var settings = OrganizationSettings()
        settings.enabledAreas.remove(.places)
        #expect(SortedCountCard.subject(settings: settings, scope: .all) == .travelPhotos(year: nil))
        settings = OrganizationSettings()
        settings.primaryAreas = [.places]
        #expect(SortedCountCard.subject(settings: settings, scope: .all) == .travelPhotos(year: nil))
    }

    /// Another area that counts (and is on) makes it "Fotos"; one that is off does not.
    @Test func anotherAreaThatCountsSaysPhotos() {
        var settings = OrganizationSettings()
        settings.primaryAreas.insert(.imageCategories)
        settings.enabledAreas.insert(.imageCategories)
        #expect(SortedCountCard.subject(settings: settings, scope: .all) == .photos(year: nil))
        #expect(SortedCountCard.subject(settings: settings, scope: .year(2025)) == .photos(year: 2025))
        #expect(!SortedCountCard.subject(settings: settings, scope: .all).isTravel)
        settings.enabledAreas.remove(.imageCategories)
        #expect(SortedCountCard.subject(settings: settings, scope: .all) == .travelPhotos(year: nil))
    }
}
