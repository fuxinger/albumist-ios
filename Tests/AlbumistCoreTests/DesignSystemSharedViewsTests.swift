import Testing
import AlbumistTestSupport

/// One view per thing the design system draws. The app's icon was two private views: the
/// purchase sheet read the bundle's icon (light only, a plain tile when iOS did not hand it
/// out), the welcome page the image set with its dark variant (handoff of the frame, 20.11.).
@Suite("Design system: one view per thing")
struct DesignSystemSharedViewsTests {
    static let icon = "App/Albumist/DesignSystem/AppIconImage.swift"

    @Test func theAppIconIsOneViewWithItsDarkVariant() throws {
        let shared = AppSource.code(try AppSource.read(Self.icon), keepStrings: true)
        #expect(shared.contains("struct AppIconImage: View"))
        #expect(shared.contains("Image(\"AppIconImage\")"), "the image set has the dark variant")
        for path in AppSource.swiftFiles(under: "App/Albumist") where !path.hasSuffix("DesignSystem/AppIconImage.swift") {
            let code = AppSource.code(try AppSource.read(path), keepStrings: true)
            #expect(!code.contains("struct AppIconImage"), "\(path) draws the app icon again")
            #expect(!code.contains("CFBundlePrimaryIcon"), "\(path) reads the light icon from the bundle")
        }
    }
}
