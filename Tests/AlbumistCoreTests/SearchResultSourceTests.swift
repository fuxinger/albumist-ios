import Foundation
import Testing
import AlbumistTestSupport

/// The search's results as VoiceOver hears them (design wave 3): each photo's date and time on
/// the clock where it was taken, as the grids (`PhotoGrid.spokenDate`) and the photo view's
/// title say it (decision of 19.11.2026, "Ortszeit am Aufnahmeort wie Apple Fotos"). Before, a
/// result told the iPhone's clock: a photo taken in Rome at 09:18 was 7:18 on a Mac set to UTC,
/// another time than its own title. The App does not build on Linux, so the test reads its code
/// (`AppSource`).
@Suite("Search results on the photo's own clock")
struct SearchResultSourceTests {
    static let search = "App/Albumist/Views/SearchView.swift"

    /// A result names its photo by the photo's clock; before Albumist knows the photo (its cell
    /// waits) it is "Foto", as before.
    @Test func aResultSaysThePhotosOwnClock() throws {
        let code = AppSource.code(try AppSource.read(Self.search), keepStrings: true)
        let cell = try #require(AppSource.body(of: ["struct SearchView", "private func thumbnail("], in: code), "no result cell")
        #expect(cell.contains(".accessibilityLabel(Text(Self.spokenDate(hit)))"), "\(cell)")
        #expect(!code.contains("creationDate?.formatted("), "a result tells the iPhone's clock")
        let spoken = try #require(AppSource.body(of: ["extension SearchView", "private static func spokenDate("], in: code),
                                  "no spokenDate beside the page's parts")
        for part in ["guard let facts, let date = facts.asset.creationDate else { return String(localized: \"Foto\") }",
                     "InboxDays.clock(of: facts, homeZone: nil, currentZone: .current)",
                     "LocalTime.wallClock(date, in: zone)",
                     "Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .gmt)"] {
            #expect(spoken.contains(part), "\(part): \(spoken)")
        }
    }
}
