import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// DS-11 as the App uses it: the calm colour of the cover on screen as the ground of a
/// suggestion's page, and nowhere else new. What the colour is and that it keeps every text
/// readable is core (`PhotoTintTests`); the App does not build on Linux, so these tests read its
/// code (`AppSource`). How it looks on photos, light and dark, is a device check.
@Suite("Photo tint in the App (DS-11)")
struct PhotoTintSourceTests {
    static let ground = "App/Albumist/DesignSystem/PhotoTintGround.swift"
    static let page = "App/Albumist/Views/ProposalViews.swift"
    static let theme = "App/Albumist/DesignSystem/Theme.swift"
    static let cover = "App/Albumist/DesignSystem/CoverPhoto.swift"
    static let accent = "App/Albumist/Resources/Assets.xcassets/AccentColor.colorset/Contents.json"
    static let mark = "// Design W3 H13: photo tint"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ path: [String], in file: String) throws -> String {
        try #require(AppSource.body(of: path, in: file), "\(path) is not there")
    }

    /// The colours the core checks a tint against are the App's own: `Theme.noteText` and the
    /// accent of the asset catalogue, light and dark (a changed grey or accent would otherwise
    /// pass the contrast check with the old values).
    @Test func theCoreChecksAgainstTheAppsOwnColours() throws {
        let theme = try Self.code(Self.theme)
        let note = try #require(theme.firstMatch(of: /noteText = adaptive\(light: \(([\d.]+), ([\d.]+), ([\d.]+)\), dark: \(([\d.]+), ([\d.]+), ([\d.]+)\)/),
                                "Theme.noteText is not where it was")
        let light = SRGB(red: Double(note.output.1)!, green: Double(note.output.2)!, blue: Double(note.output.3)!)
        let dark = SRGB(red: Double(note.output.4)!, green: Double(note.output.5)!, blue: Double(note.output.6)!)
        #expect(light == ThemeColors.noteTextLight)
        #expect(dark == ThemeColors.noteTextDark)
        #expect(theme.contains("static let background = Color(uiColor: .systemGroupedBackground)"))
        #expect(theme.contains("static let card = Color(uiColor: .secondarySystemGroupedBackground)"))

        let data = try #require(try AppSource.read(Self.accent).data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try #require(json["colors"] as? [[String: Any]])
        func components(_ entry: [String: Any]) throws -> SRGB {
            let color = try #require(entry["color"] as? [String: Any])
            let parts = try #require(color["components"] as? [String: String])
            return SRGB(red: Double(parts["red"] ?? "") ?? -1, green: Double(parts["green"] ?? "") ?? -1,
                        blue: Double(parts["blue"] ?? "") ?? -1)
        }
        func appearances(_ entry: [String: Any]) -> Set<String> {
            Set((entry["appearances"] as? [[String: String]] ?? []).compactMap { $0["value"] })
        }
        let plain = try #require(colors.first { appearances($0).isEmpty })
        let night = try #require(colors.first { appearances($0) == ["dark"] })
        #expect(try components(plain) == ThemeColors.accentLight)
        #expect(try components(night) == ThemeColors.accentDark)
    }

    /// A flat colour from the tint, light or dark; the grouped background without one, and always
    /// with Increase Contrast. No gradient, no glow.
    @Test func theGroundIsFlatAndIncreaseContrastWins() throws {
        let file = try Self.code(Self.ground)
        let color = try Self.body(["enum PhotoTintGround", "static func color("], in: file)
        #expect(color.contains("guard let tint else { return Theme.background }"), "\(color)")
        #expect(color.contains("if traits.accessibilityContrast == .high { return .systemGroupedBackground }"), "\(color)")
        #expect(color.contains("traits.userInterfaceStyle == .dark ? dark : light"), "\(color)")
        #expect(!file.contains("Gradient("), "a gradient in the photo's ground")
        #expect(!file.contains(".blur(") && !file.contains(".shadow("), "a glow in the photo's ground")
    }

    /// Worked out once per photo from the cover already in memory: nothing is asked of Photos (no
    /// iCloud either), the pixels are read off the main thread, the result is kept per photo.
    @Test func theTintComesFromTheCoverInMemory() throws {
        let file = try Self.code(Self.ground)
        let tint = try Self.body(["final class PhotoTints", "func tint(for ids: [AssetID], pixels: CGSize)"], in: file)
        #expect(tint.contains("ThumbnailCache.shared.cachedCover(for: id, pixels: pixels)"), "\(tint)")
        #expect(tint.contains("Task.detached(priority: .utility)"), "\(tint)")
        #expect(tint.contains("if let known = tints[id] { return known }"), "\(tint)")
        #expect(tint.contains("if plain.contains(id) { return nil }"), "\(tint)")
        for request in ["image(for:", "cover(for:", "largeImage(", "requestImage(", "isNetworkAccessAllowed"] {
            #expect(!file.contains(request), "the tint asks Photos: \(request)")
        }
        let sample = try Self.body(["final class PhotoTints", "nonisolated static func sample("], in: file)
        #expect(sample.contains("PhotoTint.from(rgba: bytes, width: side, height: side)"), "\(sample)")
        #expect(sample.contains("CGColorSpace.sRGB"), "\(sample)")
    }

    /// The reader asks for the cover at exactly the pixels `CoverPhoto` keeps it at (its width in
    /// whole points, the height from the aspect ratio, times the screen's scale): a changed
    /// formula there would find no cover here, and the page would quietly lose its colour.
    @Test func theReaderLooksAtTheSizeTheCoverIsKeptAt() throws {
        let file = try Self.code(Self.ground)
        let pixels = try Self.body(["struct CoverTintReader", "private var pixels: CGSize"], in: file)
        #expect(pixels.contains("CGSize(width: width.rounded(.up) * displayScale, height: (width / ratio).rounded(.up) * displayScale)"),
                "\(pixels)")
        let cover = try Self.code(Self.cover)
        let request = try #require(AppSource.body(of: "private var request: CoverLoader.Request?", in: cover))
        #expect(request.contains("let points = CGSize(width: width.rounded(.up), height: (width / aspectRatio).rounded(.up))"), "\(request)")
        #expect(request.contains("CGSize(width: points.width * displayScale,"), "\(request)")
        #expect(request.contains("height: points.height * displayScale"), "\(request)")
        #expect(cover.contains("self.aspectRatio = max(aspectRatio, 0.1)"))
        let reader = try Self.body(["struct CoverTintReader", "func body(content: Content)"], in: file)
        #expect(reader.contains("Key(ids: CoverPhoto.candidates(ids), pixels: pixels, sharp: sharp)"), "\(reader)")
        #expect(reader.contains("guard width >= 1 else { return }"), "\(reader)")
        let follow = try Self.body(["struct CoverTintReader", "private func follow("], in: file)
        #expect(follow.contains("PhotoTints.shared.known(for: key.ids, pixels: key.pixels)"), "\(follow)")
    }

    /// The page's colour follows the cover on screen (second review, K5): it goes when the cover
    /// stops being a sharp photo or its preview becomes hidden (photos taken out with
    /// "Auswählen", "Vorschau ausgeblendet"), and a colour worked out before is used only for the
    /// cover kept at this size, the first of the candidates kept there, as `CoverPhoto` shows the
    /// first sharp one, from the same candidates.
    @Test func theColourFollowsTheCoverOnScreen() throws {
        let file = try Self.code(Self.ground)
        let reader = try Self.body(["struct CoverTintReader", "func body(content: Content)"], in: file)
        #expect(reader.contains("guard key.sharp else {"), "\(reader)")
        #expect(reader.contains("withAnimation(PhotoTintGround.arrival) { tint = nil }"), "\(reader)")
        #expect(reader.contains("CoverPhoto.candidates(ids)"), "\(reader)")
        #expect(!file.contains("ids.prefix(CoverLoader.attempts)"), "the reader tries other candidates than the cover")
        let cover = try Self.code(Self.cover)
        let candidates = try Self.body(["struct CoverPhoto", "private var candidates: [AssetID]"], in: cover)
        #expect(candidates.contains("Self.candidates(ids)"), "\(candidates)")
        let shared = try Self.body(["struct CoverPhoto", "static func candidates(_ ids: [AssetID])"], in: cover)
        #expect(shared.contains("ids.lazy.filter { !$0.rawValue.isEmpty }.prefix(CoverLoader.attempts)"), "\(shared)")
        // A remembered colour only for the cover kept at this size.
        for name in ["func known(for ids: [AssetID], pixels: CGSize)", "func tint(for ids: [AssetID], pixels: CGSize)"] {
            let lookUp = try Self.body(["final class PhotoTints", name], in: file)
            let kept = try #require(lookUp.range(of: "ThumbnailCache.shared.cachedCover(for: id, pixels: pixels)"), "\(lookUp)")
            let remembered = try #require(lookUp.range(of: "tints[id]"), "\(lookUp)")
            #expect(kept.upperBound < remembered.lowerBound, "a remembered colour before the cover kept at this size: \(lookUp)")
        }
    }

    /// A colour worked out before shows with its cover, without the slow fade: a page opened
    /// again starts in its colour, not on grey that turns into it. Only a colour worked out now
    /// fades in (second review, K8).
    @Test func aKnownColourShowsAtOnce() throws {
        let file = try Self.code(Self.ground)
        let follow = try Self.body(["struct CoverTintReader", "private func follow("], in: file)
        let known = try #require(follow.range(of: "case .tint(let known):"), "\(follow)")
        let notYet = try #require(follow.range(of: "case .notYet:"), "\(follow)")
        #expect(follow[known.upperBound..<notYet.lowerBound].contains("if tint == nil { tint = known }"), "\(follow)")
        let worked = follow[notYet.upperBound...]
        let asked = try #require(worked.range(of: "await PhotoTints.shared.tint(for: key.ids, pixels: key.pixels)"), "\(follow)")
        let faded = try #require(worked.range(of: "withAnimation(PhotoTintGround.arrival) { tint = found }"), "\(follow)")
        #expect(asked.upperBound < faded.lowerBound, "\(follow)")
    }

    /// The one new place (DS-11): the ground of a suggestion's page, under its cover, header,
    /// photos and the bar with its fade, from its cover once a sharp photo shows (never from
    /// "Vorschau ausgeblendet"). No card, list or other page takes it.
    @Test func onlyTheSuggestionsPageTakesTheColour() throws {
        let page = try Self.code(Self.page)
        let body = try Self.body(["struct ProposalDetailView", "var body: some View"], in: page)
        #expect(body.contains(".background(ground.ignoresSafeArea())"), "\(body)")
        #expect(!body.contains(".background(Theme.background.ignoresSafeArea())"), "\(body)")
        let ground = try Self.body(["struct ProposalDetailView", "private var ground: Color"], in: page)
        #expect(ground.contains("PhotoTintGround.color(tint)"), "\(ground)")
        let bar = try Self.body(["struct ProposalDetailView", "private func actionBar("], in: page)
        #expect(bar.contains(".background(ground.ignoresSafeArea(edges: .bottom))"), "\(bar)")
        #expect(bar.contains("LinearGradient(colors: [ground.opacity(0), ground]"), "\(bar)")
        #expect(!bar.contains("Theme.background"), "the bar stands on another ground than the page: \(bar)")
        let cover = try Self.body(["struct ProposalDetailView", "private func cover("], in: page)
        #expect(cover.contains(".coverTint(of: ids, aspectRatio: ratio, sharp: coverIsPhoto && !card.hidesPreview, into: $tint)"), "\(cover)")
        #expect(cover.contains("aspectRatio: ratio, cornerRadius: 0, hidesPreview: card.hidesPreview"), "\(cover)")
        // Nowhere else: not on a card, a list or another page.
        for path in AppSource.swiftFiles(under: "App/Albumist") where !path.hasSuffix("ProposalViews.swift") && !path.hasSuffix("PhotoTintGround.swift") {
            let code = try Self.code(path)
            #expect(!code.contains("PhotoTintGround") && !code.contains(".coverTint("), "\(path) takes the photo's colour")
        }
        let raw = try AppSource.read(Self.page)
        #expect(raw.components(separatedBy: Self.mark).count - 1 == 6, "the marked lines of DS-11 changed")
    }

    /// The Glass Stack (DS-11, "Das Glass-Stack-Symbol kommt in der App nicht vor"): the app's
    /// icon where the app speaks of itself, the welcome page, the purchase sheet and, quietly,
    /// Settings › Über with its name; never on content (no card, list, photo or page of the
    /// user's things), and always the one drawing (`AppIconImage`, its glass only as the icon).
    @Test func theGlassStackStandsWhereTheAppSpeaksOfItself() throws {
        var places: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") where !path.hasSuffix("DesignSystem/AppIconImage.swift") {
            if try Self.code(path).contains("AppIconImage(") { places.append(URL(fileURLWithPath: path).lastPathComponent) }
        }
        #expect(places.sorted() == ["OnboardingView.swift", "SettingsView.swift", "UnlockSheet.swift"], "\(places)")
        let settings = try Self.code("App/Albumist/Views/SettingsView.swift")
        let icon = try #require(settings.range(of: "AppIconImage(side: typeSize.isAccessibilitySize ? 64 : 48)"))
        let about = try #require(settings.range(of: "Text(\"Über\")"))
        let section = try #require(settings[..<icon.lowerBound].range(of: "Section {", options: .backwards))
        // In the section headed "Über", its first row, with the app's name beside it.
        #expect(!settings[section.upperBound..<icon.lowerBound].contains("Section"), "the icon is not in the section „Über“")
        #expect(settings[icon.upperBound..<about.lowerBound].contains("Text(verbatim: AppInfo.name)"))
        #expect(!settings[icon.upperBound..<about.lowerBound].contains("Section {"), "the icon is not in the section „Über“")
    }
}
