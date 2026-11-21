import Foundation
import Testing
import AlbumistTestSupport

/// The mosaic's "+N" and the sorting show's skip button fit at the largest text (review 18.11.2026, P3-18):
/// - The mosaic of a suggestion showed "+…" instead of "+24" (`ui-a11y-xxxl-suggestion-detail`):
///   the count grew with the text until it no longer fitted its tile. Like a badge on a photo,
///   it now stops growing at the first accessibility size, keeps to one line and shrinks a little
///   rather than being cut; VoiceOver reads the full count in the label of the mosaic's button.
/// - In the sorting show "Animation überspringen" lay below the visible part of the screen
///   (`ui-a11y-xxxl-sorting-show-1`) and was only reached by scrolling. The show now knows how
///   high the screen is (`containerRelativeFrame`) and makes its decorative scene smaller, never
///   the text and the button, so the button stays on screen at every size; at a compact height
///   (an iPhone turned) the scene and the button stand beside the counts.
///
/// The App does not build on Linux, so these tests read `AssetThumbnail.swift`,
/// `SortingShow.swift` and `PlanReviewView.swift` (`AppSource`). On a Mac the accessibility walk
/// checks the skip button (`AccessibilityUITests.expectSkipInReach`) and reports what it can
/// read of the "+N" (`reportMoreCount`, never failing: the count sits inside the mosaic's
/// button, which XCUITest most likely shows as one element); the screenshot shows the count.
@Suite("Largest text: the mosaic's count and the show's skip button fit")
struct LargestTextFitTests {
    static let thumbnails = "App/Albumist/Views/AssetThumbnail.swift"
    static let show = "App/Albumist/Views/SortingShow.swift"
    static let walk = "App/AlbumistUITests/AccessibilityUITests.swift"
    static let screen = "App/Albumist/Views/PlanReviewView.swift"

    /// A file without comments, strings kept.
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    /// The modifiers of the view that starts with `start` (a regex) in `text`: the rest of its
    /// line and every following line that starts with ".", up to the first one that does not
    /// (blank lines, left by comments, are passed over).
    static func chain(from start: Regex<Substring>, in text: String) -> String? {
        guard let found = text.firstMatch(of: start) else { return nil }
        let rest = text[found.range.lowerBound...]
        var lines: [Substring] = []
        for (index, line) in rest.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.drop(while: { $0 == " " })
            // A comment between two modifiers is blank here (`AppSource.code`).
            if index > 0 && trimmed.isEmpty { continue }
            if index > 0 && !trimmed.hasPrefix(".") { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The helper ends a chain at the first line that is not a modifier.
    @Test func theChainEndsWithItsLastModifier() throws {
        let sample = """
        Text("+\\(more)").font(.headline)
            .lineLimit(1)
            // a note
            .padding(4)
        Color.red.opacity(0.4)
        """
        let chain = try #require(Self.chain(from: /Text\("\+/, in: AppSource.code(sample, keepStrings: true)))
        #expect(chain.contains(".lineLimit(1)"))
        #expect(chain.contains(".padding(4)"))
        #expect(!chain.contains("Color.red"))
    }

    // MARK: The mosaic's "+N"

    /// The "+N" of the mosaic's last tile.
    static func moreCount() throws -> String {
        let grid = try #require(AppSource.body(of: "struct ThumbnailGrid", in: try code(thumbnails)))
        return try #require(chain(from: /Text\("\+\\\(\w+\)"\)/, in: grid), "no \"+N\" in the mosaic")
    }

    /// "+24" is shown in full at every size: it stops growing at an accessibility size (like a
    /// badge on a photo), keeps to one line and shrinks a little rather than end in "…",
    /// with a little room to the tile's edges. Before: `.font(.headline)` alone, "+…" at the
    /// largest size in a quarter of the screen's width.
    @Test func theMosaicsCountIsNeverCut() throws {
        let more = try Self.moreCount()
        #expect(more.contains(/\.lineLimit\(\s*1\s*\)/), "the count may wrap or be cut: \(more)")
        #expect(more.contains(/\.minimumScaleFactor\(\s*0?\.\d+\s*\)/), "the count is cut instead of shrinking a little: \(more)")
        #expect(more.contains(/\.dynamicTypeSize\(\s*\.\.\.\s*DynamicTypeSize\.accessibility1\s*\)/),
                "the count grows past the first accessibility size and no longer fits a tile: \(more)")
        #expect(more.contains(/\.padding\(\s*\.horizontal/), "the count runs up to the tile's edges: \(more)")
    }

    /// The count stays text (VoiceOver reads the mosaic's button with its full count, "Alle 31
    /// Fotos ansehen") and carries an identifier. Inside the button the count is most likely not
    /// in the tree: then the walk only reports it, a failure there would fail every walk (second
    /// review of P3-18). Where the tree does list it, among the button's texts (never the button
    /// itself, whose own label an identifier could carry), a count cut even at the smallest size
    /// it may shrink to (half the size its height shows, `minimumScaleFactor(0.5)`) fails the
    /// walk (third review).
    @Test func theCountIsReportedByTheAccessibilityWalk() throws {
        let more = try Self.moreCount()
        #expect(!more.contains(".accessibilityHidden"), "\(more)")
        #expect(more.contains(/\.accessibilityIdentifier\(\s*"thumbnails\.more"\s*\)/), "\(more)")
        let walk = try Self.code(Self.walk)
        let report = try #require(AppSource.body(of: "func reportMoreCount(", in: walk), "the walk does not look at the count")
        #expect(report.contains("\"thumbnails.more\""))
        #expect(report.contains("UI_FACT"))
        let missing = try #require(AppSource.body(of: "guard let count", in: report), "no branch for a count not in the tree")
        #expect(!missing.contains("XCTFail"), "the walk fails where it cannot see the count: \(missing)")
        #expect(report.contains("XCTFail"), "a count measured as cut does not fail the walk: \(report)")
        #expect(report.contains(/\[\s*button\s*\]/) == false, "the button itself is searched for the count: \(report)")
        #expect(report.contains(/button\.children/), "\(report)")
        #expect(report.contains(/elementType\s*==\s*\.staticText/), "\(report)")
        #expect(report.contains(/(size\s*\*\s*0?\.5|size\s*\/\s*2|0?\.5\s*\*\s*size)/),
                "a count shrunk by its minimumScaleFactor would count as cut: \(report)")
        let body = try #require(AppSource.body(of: "private func walk(", in: walk))
        #expect(!AppSource.calls(of: "reportMoreCount(", in: body).isEmpty, "the walk never looks at the count")
    }

    // MARK: The sorting show's skip button

    /// The show's button: its modifiers.
    static func skip() throws -> String {
        let code = try code(show)
        let body = try #require(AppSource.body(of: ["struct SortingShow", "var skip: some View"], in: code),
                                "the button is not a part of its own that every layout of the show places")
        return try #require(chain(from: /Button\("Animation überspringen"/, in: body))
    }

    /// The show's own scale for its decorative scene.
    static func sceneScale() throws -> String {
        try #require(AppSource.body(of: ["struct SortingShow", "var sceneScale: CGFloat"], in: try code(show)),
                     "the scene has no scale: it is 360 pt high at every size")
    }

    /// The screen's visible height is known: the show measures the container it scrolls in (the
    /// screen between the navigation bar and the tab bar, `containerRelativeFrame`), and its
    /// scene takes what the counts and the button leave of it, never more than its own 360 pt.
    /// Before: header, a fixed 360 pt scene and then the button, below the tab bar on the small
    /// iPhone even at the default size.
    @Test func theSceneGivesWayToTheSkipButton() throws {
        let code = try Self.code(Self.show)
        let body = try #require(AppSource.body(of: ["struct SortingShow", "var body: some View"], in: code))
        #expect(body.contains(/\.containerRelativeFrame\(\s*\.vertical\s*\)/), "the show does not know how high the screen is")
        let scale = try Self.sceneScale()
        #expect(scale.contains(/\broom\b/), "\(scale)")
        #expect(scale.contains(/-=?\s*skipHeight\b/), "the button's height is not kept free: \(scale)")
        #expect(scale.contains(/-=?\s*\(?\s*headerHeight\b/), "the counts' height is not kept free: \(scale)")
        #expect(scale.contains(/\bmin\(\s*1\s*,/), "the scene may grow past its size: \(scale)")
        let scene = try #require(AppSource.body(of: ["struct SortingShow", "var scene: some View"], in: code))
        #expect(scene.contains(/\.scaleEffect\(\s*sceneScale\b/), "\(scene)")
        #expect(scene.contains(/\.frame\(\s*height:\s*sceneHeight\s*\*\s*sceneScale\b/),
                "the scene still takes its full height in the layout: \(scene)")
        // The heights it subtracts are measured, not guessed.
        #expect(code.contains(/headerHeight\s*=\s*\$0/), "the counts' height is not measured")
        #expect(code.contains(/skipHeight\s*=\s*\$0/), "the button's height is not measured")
    }

    /// The padding the screen puts around the show comes from the screen, not from a copy in
    /// the show that could drift (second review of P3-18): `PlanReviewView` pads its content
    /// with one value and hands the same value to the show, which keeps it free above and below.
    @Test func theShowKeepsTheScreensOwnPaddingFree() throws {
        let screen = try Self.code(Self.screen)
        let body = try #require(AppSource.body(of: ["struct PlanReviewView", "var body: some View"], in: screen))
        let padding = try #require(body.firstMatch(of: /\.padding\(\s*([^)]+?)\s*\)\s*\.id\(\s*Self\.top\s*\)/),
                                   "the content's padding is not found")
        let handed = try #require(AppSource.calls(of: "SortingShow(", in: body).first, "the screen shows no sorting show")
        let passed = try #require(handed.firstMatch(of: /screenPadding:\s*([^,)]+?)\s*$/), "the show is not told the padding: \(handed)")
        #expect(String(padding.output.1) == String(passed.output.1),
                "the content is padded by \(padding.output.1), the show keeps \(passed.output.1) free")
        let scale = try Self.sceneScale()
        #expect(scale.contains(/2\s*\*\s*screenPadding\b/), "the show does not keep the padding above and below free: \(scale)")
        let show = try Self.code(Self.show)
        #expect(!show.contains(/Theme\.Spacing\.l\s*\+\s*Theme\.Spacing\.m|2\s*\*\s*Theme\.Spacing\.l/),
                "the show copies the screen's padding")
    }

    /// The counts keep their height while the photos are counted up: a hidden copy of the line
    /// with every photo of the plan holds the room the widest count needs, so a line that wraps
    /// mid-show never shrinks the scene at once (second review of P3-18). Since DS-17 the count
    /// has its thousands separator (`%lld %@`, as every other count of photos).
    @Test func theCountsKeepTheirHeightWhileCounting() throws {
        let header = try #require(AppSource.body(of: ["struct SortingShow", "var header: some View"], in: try Self.code(Self.show)))
        #expect(header.contains(/Text\("\\\(totalPhotos\) \\\(totalPhotos\.formatted\(\)\) Fotos einsortiert"\)\s*\.hidden\(\)/), "\(header)")
        #expect(header.contains(/Text\("\\\(counted\) \\\(counted\.formatted\(\)\) Fotos einsortiert"\)/), "\(header)")
    }

    /// Every layout of the show places the button under the scene: the column (header, scene,
    /// button) and, at a compact height, the counts beside the scene and the button. One layout
    /// that changes its direction (`AnyLayout`), so turning the iPhone mid-show keeps the scene
    /// and its flying photos (second review of P3-18).
    @Test func everyLayoutPlacesTheButton() throws {
        let code = try Self.code(Self.show)
        let body = try #require(AppSource.body(of: ["struct SortingShow", "var body: some View"], in: code))
        #expect(body.contains(/AnyLayout\(\s*HStackLayout\(/), "\(body)")
        #expect(body.contains(/AnyLayout\(\s*VStackLayout\(/), "\(body)")
        #expect(body.contains(/layout\s*\{\s*header\s+VStack\([^)]*\)\s*\{\s*scene\s+skip\s*\}\s*\}/),
                "the button does not stand under the scene in one layout: \(body)")
        #expect(code.contains(/verticalSizeClass\s*==\s*\.compact/), "no layout for a compact height (an iPhone turned)")
    }

    /// The button keeps what it did: it ends only the animation (`onFinish`), and the walk finds
    /// it by an identifier. Its text stops growing at AX2, where "überspringen" still fits one
    /// line of the small iPhone (at AX5 it broke inside the word).
    @Test func theButtonKeepsItsActionAndIsFoundByTheWalk() throws {
        let skip = try Self.skip()
        #expect(skip.contains(/action:\s*onFinish\b/), "\(skip)")
        #expect(skip.contains(/\.accessibilityIdentifier\(\s*"show\.skip"\s*\)/), "\(skip)")
        #expect(skip.contains(/\.dynamicTypeSize\(\s*\.\.\.\s*DynamicTypeSize\.accessibility2\s*\)/), "\(skip)")
        let walk = try Self.code(Self.walk)
        let reach = try #require(AppSource.body(of: "func expectSkipInReach(", in: walk), "the walk does not check the button")
        #expect(reach.contains("\"show.skip\""))
        // One snapshot per poll: the show of a short plan may end between two queries.
        #expect(reach.contains("app.snapshot()"), "\(reach)")
        #expect(!reach.contains("app.buttons["), "the button is queried again and again: \(reach)")
        #expect(reach.contains(".tabBar"), "the button may stand behind the tab bar: \(reach)")
        #expect(reach.contains(".navigationBar"), "the button may stand under the navigation bar: \(reach)")
        // The show ends by itself after a few seconds: an end is harmless only when no poll saw
        // the show (third review of P3-18). A poll that saw it with the button out of reach,
        // and then the end, fails the walk.
        #expect(reach.contains(/pollsWithShow\s*\+=\s*1/), "the polls that saw the show are not counted: \(reach)")
        #expect(reach.contains(/if\s+[^{]*\bended\b[^{]*\bpollsWithShow\s*==\s*0\b[^{]*\{/),
                "a show that ended after it was seen with the button out of reach passes: \(reach)")
        // The first bar in the order of the tree, as `firstMatch` finds it.
        #expect(reach.contains(/children\.reversed\(\)/), "\(reach)")
        let body = try #require(AppSource.body(of: "private func walk(", in: walk))
        #expect(!AppSource.calls(of: "expectSkipInReach(", in: body).isEmpty, "the walk never checks the button")
    }

    /// The new part `scene` (pile, albums and flying photos, now scaled) stays decorative: hidden
    /// from VoiceOver, its labels capped. With Reduce Motion only the current album shows and
    /// nothing flies, as before. Red before the fix only because there was no `scene` yet.
    @Test func theShowKeepsItsVoiceOverAndReduceMotionBehaviour() throws {
        let code = try Self.code(Self.show)
        let scene = try #require(AppSource.body(of: ["struct SortingShow", "var scene: some View"], in: code))
        #expect(scene.contains(/\.accessibilityHidden\(\s*true\s*\)/))
        #expect(scene.contains(/\.dynamicTypeSize\(\s*\.\.\.\s*DynamicTypeSize\.xxLarge\s*\)/))
        #expect(code.contains(/reduceMotion\s*\?\s*\$0\s*==\s*current/))
        #expect(code.contains(/let\s+calm\s*=\s*!reduceMotion\s*&&\s*!voiceOver/))
    }
}
