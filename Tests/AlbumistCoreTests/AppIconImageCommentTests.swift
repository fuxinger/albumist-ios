import Foundation
import Testing
import AlbumistTestSupport

/// `AppIconImage` says where it appears, so whoever changes it knows every place it changes:
/// the welcome page, the purchase sheet and Settings › Über (design wave 3, H14). Read from the
/// App's code (`AppSource`): every place that draws the icon is named in the comment.
@Suite("The app icon's comment names every place it appears")
struct AppIconImageCommentTests {
    static let icon = "App/Albumist/DesignSystem/AppIconImage.swift"
    /// The files that draw the icon and how the comment names their place.
    static let places = [
        "OnboardingView.swift": "welcome page",
        "UnlockSheet.swift": "purchase sheet",
        "SettingsView.swift": "Settings › Über",
    ]

    @Test func theCommentNamesEveryPlace() throws {
        let raw = try AppSource.read(Self.icon)
        let lines = raw.components(separatedBy: "\n")
        let declaration = try #require(lines.firstIndex { $0.hasPrefix("struct AppIconImage: View") })
        let comment = lines[..<declaration].reversed().prefix { $0.hasPrefix("///") }.reversed()
            .map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        var drawn: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") where path != Self.icon {
            if AppSource.code(try AppSource.read(path)).contains("AppIconImage(") {
                drawn.append(URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        #expect(drawn.sorted() == Self.places.keys.sorted(), "a place without its name in the comment: \(drawn)")
        for file in drawn {
            let place = try #require(Self.places[file], "\(file) draws the icon")
            #expect(comment.contains(place), "the comment does not name the \(place) (\(file)): \(comment)")
        }
    }
}
