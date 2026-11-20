import Foundation
import Testing
import SortlyTestSupport

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
/// The App does not build on Linux, so these tests read `AssetThumbnail.swift` and
/// `SortingShow.swift` (`AppSource`). On a Mac the accessibility walk measures both
/// (`AccessibilityUITests`: `checkMoreCountShown`, `expectSkipInReach`).
@Suite("Largest text: the mosaic's count and the show's skip button fit")
struct LargestTextFitTests {
    static let thumbnails = "App/Sortly/Views/AssetThumbnail.swift"
    static let show = "App/Sortly/Views/SortingShow.swift"
    static let walk = "App/SortlyUITests/AccessibilityUITests.swift"

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
    /// Fotos ansehen") and carries an identifier the accessibility walk measures it by.
    @Test func theCountIsMeasuredByTheAccessibilityWalk() throws {
        let more = try Self.moreCount()
        #expect(!more.contains(".accessibilityHidden"), "\(more)")
        #expect(more.contains(/\.accessibilityIdentifier\(\s*"thumbnails\.more"\s*\)/), "\(more)")
        let walk = try Self.code(Self.walk)
        let check = try #require(AppSource.body(of: "func checkMoreCountShown(", in: walk), "the walk does not measure the count")
        #expect(check.contains("\"thumbnails.more\""))
        let body = try #require(AppSource.body(of: "private func walk(", in: walk))
        #expect(!AppSource.calls(of: "checkMoreCountShown(", in: body).isEmpty, "the walk never measures the count")
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

    /// Every layout of the show places the button: the column (header, scene, button) and,
    /// at a compact height, the counts beside the scene and the button.
    @Test func everyLayoutPlacesTheButton() throws {
        let code = try Self.code(Self.show)
        let body = try #require(AppSource.body(of: ["struct SortingShow", "var body: some View"], in: code))
        let besides = body.matches(of: /\bskip\b/).count
        #expect(besides >= 2, "the button is missing from a layout: \(body)")
        #expect(body.contains(/verticalSizeClass\s*==\s*\.compact/) || code.contains(/verticalSizeClass\s*==\s*\.compact/),
                "no layout for a compact height (an iPhone turned)")
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
        #expect(reach.contains("isHittable"))
        #expect(reach.contains("tabBars"), "the button may stand behind the tab bar: \(reach)")
        let body = try #require(AppSource.body(of: "private func walk(", in: walk))
        #expect(!AppSource.calls(of: "expectSkipInReach(", in: body).isEmpty, "the walk never checks the button")
    }

    /// What the show already did stays: its scene is decorative (hidden from VoiceOver, its labels
    /// capped), with Reduce Motion only the current album shows and nothing flies.
    @Test func theShowKeepsItsVoiceOverAndReduceMotionBehaviour() throws {
        let code = try Self.code(Self.show)
        let scene = try #require(AppSource.body(of: ["struct SortingShow", "var scene: some View"], in: code))
        #expect(scene.contains(/\.accessibilityHidden\(\s*true\s*\)/))
        #expect(scene.contains(/\.dynamicTypeSize\(\s*\.\.\.\s*DynamicTypeSize\.xxLarge\s*\)/))
        #expect(code.contains(/reduceMotion\s*\?\s*\$0\s*==\s*current/))
        #expect(code.contains(/let\s+calm\s*=\s*!reduceMotion\s*&&\s*!voiceOver/))
    }
}
