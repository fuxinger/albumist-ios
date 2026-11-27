import Foundation
import Testing
import AlbumistTestSupport

/// The photo's info behind "i" (`AssetDetailView`, `PhotoViewerSourceTests`).
extension PhotoViewerSourceTests {
    /// "Aufgenommen" tells the day and the time on the photo's clock, in the app's language and on
    /// the iPhone's 12- or 24-hour setting, as the title above it does (`PhotoTitle.takenAt`): the
    /// design run of 25.11. showed "09:18" in the title and "7:18" in the info for one photo
    /// (the iPhone's zone instead of the photo's).
    @Test func theInfoTellsTheTimeOnThePhotosClock() throws {
        let library = AppSource.code(try AppSource.read("App/Albumist/Views/LibraryView.swift"))
        let info = try #require(AppSource.body(of: "struct AssetDetailView", in: library))
        #expect(info.contains("PhotoTitle.takenAt(date, zone: facts.timeZone, currentZone: .current, words: model.proposalWords,"))
        #expect(info.contains("clock: AppModel.deviceClock())"))
        #expect(!info.contains(".formatted(date:"), "a date on the iPhone's clock in the info")
    }
}
