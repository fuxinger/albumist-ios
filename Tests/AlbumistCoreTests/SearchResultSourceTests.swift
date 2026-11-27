import Foundation
import Testing
import AlbumistTestSupport

/// Photo cells as VoiceOver hears them outside the day grids (design wave 3): a search result
/// and an album's photo say the photo's date and time on the clock where it was taken, as the
/// grids (`PhotoGrid.spokenDate`) and the photo view's title do (decision of 19.11.2026,
/// "Ortszeit am Aufnahmeort wie Apple Fotos"). Before, they told the iPhone's clock: a photo
/// taken in Rome at 09:18 was 7:18 on a Mac set to UTC, another time than its own title. One
/// function names them (`AssetThumbnail.spokenDate`). The App does not build on Linux, so the
/// test reads its code (`AppSource`).
@Suite("Search results and album photos on the photo's own clock")
struct SearchResultSourceTests {
    static let thumbnail = "App/Albumist/Views/AssetThumbnail.swift"

    /// A result and an album's photo are named by the photo's clock; without a date "Foto", as
    /// before.
    @Test func aResultSaysThePhotosOwnClock() throws {
        let cells = [("App/Albumist/Views/SearchView.swift", ["struct SearchView", "private func thumbnail("],
                      ".accessibilityLabel(Text(AssetThumbnail.spokenDate(hit?.asset.creationDate, facts: hit)))"),
                     ("App/Albumist/Views/AlbumsView.swift", ["private func tile("],
                      ".accessibilityLabel(Text(AssetThumbnail.spokenDate(model.creationDates[photo], facts: model.factsByID[photo])))")]
        for (path, place, label) in cells {
            let code = AppSource.code(try AppSource.read(path), keepStrings: true)
            let cell = try #require(AppSource.body(of: place, in: code), "\(path): no photo cell")
            #expect(cell.contains(label), "\(path): \(cell)")
            #expect(!code.contains("creationDate?.formatted(") && !code.contains("creationDates[photo]?.formatted("),
                    "\(path): a photo cell tells the iPhone's clock")
        }
        let code = AppSource.code(try AppSource.read(Self.thumbnail), keepStrings: true)
        let spoken = try #require(AppSource.body(of: ["extension AssetThumbnail", "static func spokenDate("], in: code),
                                  "no spokenDate beside the thumbnail")
        for part in ["guard let date else { return String(localized: \"Foto\") }",
                     "InboxDays.clock(of: facts, homeZone: nil, currentZone: .current)",
                     "LocalTime.wallClock(date, in: zone)",
                     "Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .gmt)"] {
            #expect(spoken.contains(part), "\(part): \(spoken)")
        }
    }
}
