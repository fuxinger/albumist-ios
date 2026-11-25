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
    static let loader = "App/Albumist/DesignSystem/CoverLoader.swift"
    /// UI tests 3 and 4 (the page's colour, the icon in "Über"), an extension of `ShowAndHandwritingUITests`.
    static let handwritingUITest = "App/AlbumistUITests/ShowAndHandwritingUITests+Handwriting.swift"
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
        let pixels = try Self.body(["struct CoverTintReader", "private func pixels(at width: CGFloat) -> CGSize"], in: file)
        #expect(pixels.contains("CGSize(width: width.rounded(.up) * displayScale, height: (width / ratio).rounded(.up) * displayScale)"),
                "\(pixels)")
        let shown = try Self.body(["struct CoverTintReader", "private var pixels: CGSize"], in: file)
        #expect(shown.contains("pixels(at: width)"), "\(shown)")
        let cover = try Self.code(Self.cover)
        let request = try #require(AppSource.body(of: "private var request: CoverLoader.Request?", in: cover))
        #expect(request.contains("let points = CGSize(width: width.rounded(.up), height: (width / aspectRatio).rounded(.up))"), "\(request)")
        #expect(request.contains("CGSize(width: points.width * displayScale,"), "\(request)")
        #expect(request.contains("height: points.height * displayScale"), "\(request)")
        #expect(cover.contains("self.aspectRatio = max(aspectRatio, 0.1)"))
        let reader = try Self.body(["struct CoverTintReader", "func body(content: Content)"], in: file)
        #expect(reader.contains("Key(ids: CoverPhoto.candidates(ids), pixels: pixels, sharp: sharp && !hidden)"), "\(reader)")
        #expect(reader.contains("guard !Task.isCancelled, key.pixels.width >= 1 else { return }"), "\(reader)")
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

    /// A colour worked out before comes with its cover, in the cover's own short fade
    /// (`CoverPhoto.fade`), never from one frame to the next: a page opened again after its cover
    /// left the covers' store starts on the neutral ground while its cover comes from Photos and
    /// fades in (verification review X3). Not the slow cross-fade of a colour worked out now (K8),
    /// which stays for a change from one colour to another. Only `seed`, in the pass of the page's
    /// first measure, sets a colour without a fade (V5). Both fades stay with Reduce Motion, as
    /// the cover's: a colour changes, nothing moves.
    @Test func aKnownColourComesWithItsCoversFade() throws {
        let file = try Self.code(Self.ground)
        let follow = try Self.body(["struct CoverTintReader", "private func follow("], in: file)
        let known = try #require(follow.range(of: "case .tint(let known):"), "\(follow)")
        let notYet = try #require(follow.range(of: "case .notYet:"), "\(follow)")
        let taken = follow[known.upperBound..<notYet.lowerBound]
        #expect(taken.contains("withAnimation(tint == nil ? CoverPhoto.fade : PhotoTintGround.arrival) { tint = known }"), "\(follow)")
        let worked = follow[notYet.upperBound...]
        let asked = try #require(worked.range(of: "await PhotoTints.shared.tint(for: key.ids, pixels: key.pixels)"), "\(follow)")
        let faded = try #require(worked.range(of: "withAnimation(PhotoTintGround.arrival) { tint = found }"), "\(follow)")
        #expect(asked.upperBound < faded.lowerBound, "\(follow)")
        // Every colour the reader sets fades in, except the seed's.
        let reader = try Self.body(["struct CoverTintReader"], in: file)
        let seed = try Self.body(["struct CoverTintReader", "private func seed(width: CGFloat)"], in: file)
        #expect(seed.contains("tint = known"), "\(seed)")
        for line in reader.replacingOccurrences(of: seed, with: "").split(separator: "\n") {
            var rest = line[...]
            while let set = rest.range(of: "tint = ") {
                let before = line[..<set.lowerBound]
                #expect(before.contains("withAnimation(") && before.hasSuffix(") { "), "a colour set without a fade: \(line)")
                rest = line[set.upperBound...]
            }
        }
        // The cover's own fade, named once: the cover comes in with it when it took a moment.
        let cover = try Self.code(Self.cover)
        #expect(cover.contains("static let fade = Animation.easeOut(duration: 0.2)"), "the cover's fade is not named")
        let show = try Self.body(["struct CoverPhoto", "private func show("], in: cover)
        #expect(show.contains("withAnimation(Self.fade) { loaded = result }"), "\(show)")
        #expect(!file.contains("accessibilityReduceMotion"), "the page's colour switches with Reduce Motion")
    }

    /// A page opened again is in its colour from its first frame, with no switch from the neutral
    /// ground (verification review V5): as the reader measures the page for the first time, before
    /// the cover tells that it shows a sharp photo, it takes the colour known for the cover kept at
    /// this size, at once (no fade), never for a hidden preview. That colour stays while the cover
    /// is still to tell; a hidden preview or another cover takes it away.
    @Test func aKnownColourIsThereFromThePagesFirstFrame() throws {
        let file = try Self.code(Self.ground)
        let reader = try Self.body(["struct CoverTintReader", "func body(content: Content)"], in: file)
        let measured = try #require(reader.range(of: "action: { new in"), "\(reader)")
        let seeded = try #require(reader.range(of: "if width < 1 { seed(width: new) }"), "not seeded as the page is first measured: \(reader)")
        let kept = try #require(reader.range(of: "width = new"), "\(reader)")
        #expect(measured.upperBound < seeded.lowerBound && seeded.upperBound < kept.lowerBound, "\(reader)")
        let seed = try Self.body(["struct CoverTintReader", "private func seed(width: CGFloat)"], in: file)
        #expect(seed.contains("guard !hidden, tint == nil, width >= 1 else { return }"), "\(seed)")
        #expect(seed.contains("if case .tint(let known?) = PhotoTints.shared.atOnce(for: CoverPhoto.candidates(ids), pixels: pixels(at: width))"),
                "\(seed)")
        #expect(seed.contains("tint = known"), "\(seed)")
        #expect(!seed.contains("withAnimation"), "a known colour fades in: \(seed)")
        // Kept while the cover is still to tell; gone for a hidden preview or another cover.
        let notSharp = try #require(reader.range(of: "guard key.sharp else {"), "\(reader)")
        let stays = try #require(reader.range(of: "if tint != nil, hidden || PhotoTints.shared.atOnce(for: key.ids, pixels: key.pixels) != .tint(tint) {"),
                                 "a seeded colour goes before the cover told: \(reader)")
        #expect(notSharp.upperBound < stays.lowerBound, "\(reader)")
        #expect(reader.contains("Key(ids: CoverPhoto.candidates(ids), pixels: pixels, sharp: sharp && !hidden)"), "\(reader)")
        // The page says whether its preview is hidden, apart from whether a sharp photo shows.
        let page = try Self.code(Self.page)
        let cover = try Self.body(["struct ProposalDetailView", "private func cover("], in: page)
        #expect(cover.contains(".coverTint(of: ids, aspectRatio: ratio, sharp: coverIsPhoto, hidden: card.hidesPreview, into: $tint)"), "\(cover)")
    }

    /// The colour taken before the cover tells is only ever that of the photo `CoverPhoto` shows
    /// at once, without asking Photos: the first candidate's, when its cover is kept at this size
    /// (verification review X4). A later candidate's kept cover shows only after Photos answered
    /// for the ones before it (`CoverLoader.load` tries them in order; only a kept cover comes
    /// without a word from Photos), which it may not do: the cover then stays the calm
    /// placeholder, and the page must not stand in another photo's colour ("never of the
    /// placeholder"). Once the cover told that a sharp photo shows, `follow` takes the colour of
    /// whichever candidate it is.
    @Test func theSeedIsOnlyTheFirstCandidatesColour() throws {
        let file = try Self.code(Self.ground)
        let atOnce = try Self.body(["final class PhotoTints", "func atOnce(for ids: [AssetID], pixels: CGSize) -> Known"], in: file)
        #expect(atOnce.contains("known(for: Array(ids.prefix(1)), pixels: pixels)"), "\(atOnce)")
        let seed = try Self.body(["struct CoverTintReader", "private func seed(width: CGFloat)"], in: file)
        #expect(!seed.contains(".known(for:"), "the seed takes a later candidate's colour: \(seed)")
        let reader = try Self.body(["struct CoverTintReader", "func body(content: Content)"], in: file)
        let notSharp = try #require(reader.range(of: "guard key.sharp else {"), "\(reader)")
        let follows = try #require(reader.range(of: "await follow(key)"), "\(reader)")
        #expect(!reader[notSharp.upperBound..<follows.lowerBound].contains(".known(for:"),
                "a later candidate's colour stays before the cover told: \(reader)")
        let follow = try Self.body(["struct CoverTintReader", "private func follow("], in: file)
        #expect(follow.contains("PhotoTints.shared.known(for: key.ids, pixels: key.pixels)"), "\(follow)")
        // Why the first one: the cover tries the candidates in order, and only a kept cover needs
        // no word from Photos.
        let loader = try Self.code(Self.loader)
        let load = try Self.body(["enum CoverLoader", "static func load("], in: loader)
        #expect(load.contains("for (index, id) in request.ids.enumerated()"), "\(load)")
        // The cache went into files of its own (SwiftLint's file length): read as one text.
        let cache = AppSource.code(try ThumbnailSource.read(), keepStrings: true)
        let fetch = try Self.body(["final class ThumbnailCache", "func cover(for id: AssetID, pixels: CGSize) async -> CoverFetch"], in: cache)
        let kept = try #require(fetch.range(of: "if let kept = cachedCover(for: id, pixels: pixels)"), "\(fetch)")
        let asked = try #require(fetch.range(of: "await lookUpAsset(id)"), "\(fetch)")
        #expect(kept.upperBound < asked.lowerBound, "a kept cover waits for Photos: \(fetch)")
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
        #expect(cover.contains(".coverTint(of: ids, aspectRatio: ratio, sharp: coverIsPhoto, hidden: card.hidesPreview, into: $tint)"), "\(cover)")
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

    /// The app's row in Settings › Über is one element for VoiceOver with the app's name (the icon
    /// is decorative), found by its identifier `settings.about.app` (verification review V10).
    /// UI test 4 finds it by that, whatever type XCTest gives the combined element, and asserts
    /// its name and that it is at least 48 pt high, the icon's side: a row without the icon is a
    /// line of text, lower than that.
    @Test func theAppsRowIsOneElementTheUITestFinds() throws {
        let settings = try Self.code("App/Albumist/Views/SettingsView.swift")
        let icon = try #require(settings.range(of: "AppIconImage(side: typeSize.isAccessibilitySize ? 64 : 48)"))
        let next = try #require(settings[icon.upperBound...].range(of: "NavigationLink(\"Datenschutz\")"), "\(settings)")
        let row = settings[icon.upperBound..<next.lowerBound]
        #expect(row.contains("Text(verbatim: AppInfo.name)"), "\(row)")
        let combined = try #require(row.range(of: ".accessibilityElement(children: .combine)"), "the row is not one element: \(row)")
        let identified = try #require(row.range(of: ".accessibilityIdentifier(\"settings.about.app\")"), "the app's row has no identifier: \(row)")
        #expect(combined.upperBound <= identified.lowerBound, "the identifier is not on the combined element: \(row)")
        let image = try Self.code("App/Albumist/DesignSystem/AppIconImage.swift")
        #expect(image.contains(".accessibilityHidden(true)"), "the icon speaks for itself")
        let test = AppSource.code(try AppSource.read(Self.handwritingUITest), keepStrings: true)
        let body = try Self.body(["extension ShowAndHandwritingUITests", "func test4_SettingsAboutShowsTheAppsIconAndName()"], in: test)
        #expect(body.contains("node.identifier == \"settings.about.app\""), "UI test 4 does not find the row by its identifier: \(body)")
        #expect(body.contains("XCTAssertEqual(row.label, \"Albumist\""), "\(body)")
        #expect(body.contains("XCTAssertGreaterThanOrEqual(row.frame.height, 48"), "UI test 4 does not look at the icon: \(body)")
        #expect(!body.contains(".staticText"), "UI test 4 still needs a static text: \(body)")
    }

    /// UI test 3 knows the page's colour from any other ground (verification review V9): besides
    /// "not the grouped background" it asserts pale in light mode (each channel at least 215)
    /// and deep in dark mode (each at most 80), bounds every tint keeps
    /// (`PhotoTintTests.everyTintIsPaleInLightAndDeepInDark`), so the pale tint shown in dark mode
    /// fails it. It waits up to 25 s for the colour: the reader alone waits up to 6 s for the
    /// cover, and a busy Mac takes longer.
    @Test func theUITestKnowsAPaleOrDeepGround() throws {
        let test = AppSource.code(try AppSource.read(Self.handwritingUITest), keepStrings: true)
        let calm = try Self.body(["extension ShowAndHandwritingUITests", "private static func isCalmGround("], in: test)
        #expect(calm.contains("dark ? colour.allSatisfy { $0 <= 80 } : colour.allSatisfy { $0 >= 215 }"), "\(calm)")
        let wait = try Self.body(["extension ShowAndHandwritingUITests", "private func waitForTint("], in: test)
        #expect(wait.contains("UITestWait.holds(timeout: 25)"), "\(wait)")
        #expect(wait.contains("zip(now, neutral).map { abs($0 - $1) }.reduce(0, +) >= 4"), "not neutral is no longer asked: \(wait)")
        let open = try Self.body(["extension ShowAndHandwritingUITests", "private func openTintedTrip("], in: test)
        let tinted = try #require(open.range(of: "if tinted {"), "\(open)")
        let asked = try #require(open.range(of: "XCTAssertTrue(calm, "), "the colour's bounds are not asserted: \(open)")
        let found = try #require(open.range(of: "return name"), "\(open)")
        #expect(tinted.upperBound < asked.lowerBound && asked.upperBound < found.lowerBound, "\(open)")
        #expect(open.contains("let calm = ground.map { Self.isCalmGround($0, dark: dark) } == true"), "\(open)")
    }
}
