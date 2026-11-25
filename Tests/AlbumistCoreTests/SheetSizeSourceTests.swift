import Foundation
import Testing
import AlbumistTestSupport

/// One rule for how tall a sheet opens (design wave 3, DS-12b): a short explanation or a small
/// form opens at half height and can be pulled to the full height; a whole page with its own
/// navigation (the settings, "Zu Album hinzufügen", the trip workshop) opens at full height; at
/// the accessibility text sizes every sheet opens at full height only, as half a screen shows
/// two lines there. The rule lives in one place (`SheetSize`, `DesignSystem/SheetSize.swift`)
/// and every sheet says its size where it opens. The drag indicator is the system's, and no
/// sheet has a ground of its own (a sheet at half height is glass in iOS 26), except the photo
/// view's two solid ones over the black viewer. The App does not build on Linux, so these tests
/// read its code (`AppSource`).
@Suite("Sheets: one rule for how tall they open (DS-12b)")
struct SheetSizeSourceTests {
    static let rule = "App/Albumist/DesignSystem/SheetSize.swift"
    /// The map's sheets ("Teilen" in the atlas, `ShareCardSheet`; "Seit wann?" in the home
    /// settings, `HomeSinceSheet`) belong to the map's own thread of work and keep their own
    /// heights until it takes the rule: left out on purpose, by name, so every other sheet of
    /// their files is read like any other (review S9 of H14).
    static let mapsOwn: Set<String> = ["ShareCardSheet", "HomeSinceSheet"]

    /// Every Swift file of the App.
    static var files: [String] { AppSource.swiftFiles(under: "App/Albumist") }

    /// The code of `path` (comments blanked, strings kept).
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    /// `text` without any white space, so a check does not depend on how a line is broken.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The rule: two sizes, and the heights each allows at a text size, which the modifier reads
    /// from the environment, so a sheet follows the text size even while it is open.
    @Test func theRuleIsOnePlaceThatReadsTheTextSize() throws {
        let rule = try Self.code(Self.rule)
        let sizes = Self.squeezed(try #require(AppSource.body(of: ["enum SheetSize"], in: rule)))
        #expect(sizes.hasPrefix("{caseshortcasepage"), "\(sizes)")
        let declaration = "func detents(at typeSize: DynamicTypeSize) -> Set<PresentationDetent>"
        let detents = Self.squeezed(try #require(AppSource.body(of: ["enum SheetSize", declaration], in: rule)))
        #expect(detents == "{ifself==.page||typeSize.isAccessibilitySize{return[.large]}return[.medium,.large]}", "\(detents)")
        let modifier = try #require(AppSource.body(of: ["private struct SheetSizeModifier"], in: rule))
        #expect(modifier.contains("@Environment(\\.dynamicTypeSize) private var typeSize"), "\(modifier)")
        let body = Self.squeezed(try #require(AppSource.body(of: ["private struct SheetSizeModifier", "func body(content: Content)"], in: rule)))
        #expect(body == "{content.presentationDetents(size.detents(at:typeSize))}", "\(body)")
        let entry = Self.squeezed(try #require(AppSource.body(of: ["func sheetSize(_ size: SheetSize) -> some View"], in: rule)))
        #expect(entry == "{modifier(SheetSizeModifier(size:size))}", "\(entry)")
    }

    /// Every sheet of the App goes through the rule in the closure that makes its content, so
    /// each sheet says where it opens how tall it is; the same content has the same size
    /// wherever it opens. A new sheet joins this list with its size.
    @Test func everySheetTakesItsSizeFromTheRule() throws {
        var sheets: [String] = []
        for path in Self.files {
            let code = try Self.code(path)
            for content in Self.sheetContents(in: code) {
                let sizes = AppSource.calls(of: "sheetSize(", in: content)
                let shown = Self.shownView(in: content, file: code) ?? "?"
                let own = Self.mapsOwn.contains(shown)
                #expect(sizes.count == 1 || own && sizes.isEmpty, "\(path): a sheet without its size from the rule, or with two: \(content)")
                let size = sizes.first ?? (own ? "(the map's own)" : "-")
                sheets.append("\(URL(fileURLWithPath: path).lastPathComponent): \(shown) \(size)")
            }
        }
        #expect(sheets.sorted() == [
            "AlbumsView.swift: AddToAlbumSheet .page",
            "AnalysisProgressCard.swift: AnalysisDetailsSheet .short",
            "Atlas.swift: ShareCardSheet (the map's own)",
            "HomeSettingsView.swift: HomeSinceSheet (the map's own)",
            "LearnMore.swift: LearnMoreSheet .short",
            "LibraryView.swift: AddToAlbumSheet .page",
            "LibraryView.swift: SettingsView .page",
            "OverviewView.swift: AnalysisSummarySheet .short",
            "OverviewView.swift: SettingsView .page",
            "OverviewView.swift: SettingsView .page",
            "OverviewView.swift: SortedSheet .short",
            "PhotoViewer.swift: AddToAlbumSheet .page",
            "PhotoViewer.swift: AssetDetailView .short",
            "PlanReviewView.swift: UnlockSheet .short",
            "ProposalViews.swift: AdjustProposalView .short",
            "ProposalViews.swift: TripWorkshopView .page",
            "RootView.swift: UnlockSheet .short",
            "SearchView.swift: AddToAlbumSheet .page",
            "SuggestionMenuFlows.swift: AdjustProposalView .short",
            "SuggestionMenuFlows.swift: TripWorkshopView .page",
        ], "\(sheets.sorted())")
    }

    /// A sheet at half height scrolls its content, so nothing is cut there: the view of every
    /// `.short` sheet is a scroll view, a list or a form.
    @Test func everyShortSheetScrolls() throws {
        var short: Set<String> = []
        for path in Self.files {
            let code = try Self.code(path)
            for content in Self.sheetContents(in: code) where AppSource.calls(of: "sheetSize(", in: content) == [".short"] {
                short.insert(try #require(Self.shownView(in: content, file: code), "\(path): \(content)"))
            }
        }
        #expect(short == ["AdjustProposalView", "AnalysisDetailsSheet", "AnalysisSummarySheet", "AssetDetailView",
                          "LearnMoreSheet", "SortedSheet", "UnlockSheet"], "\(short.sorted())")
        for view in short.sorted() {
            let body = try #require(try Self.body(ofView: view), "no body of \(view)")
            #expect(["ScrollView {", "List {", "Form {"].contains { body.contains($0) }, "\(view) does not scroll at half height: \(body)")
        }
    }

    /// Heights only through the rule: `.presentationDetents` in `SheetSize` alone, and in the
    /// map's two sheets (`mapsOwn`). No drag indicator of the App's own: the system shows one
    /// where a sheet has two heights. No ground of a sheet's own, as a sheet at half height is
    /// glass in iOS 26; only the photo view keeps its two solid ones (over the black viewer the
    /// glass lost the text's contrast, UI run 43773339053).
    @Test func heightsIndicatorAndGroundAreTheRulesOrTheSystems() throws {
        var mapsHeights: [String] = []
        for path in Self.files {
            let code = try Self.code(path)
            let own = Self.mapsOwn.compactMap { AppSource.body(of: ["struct \($0): View"], in: code) }
                .flatMap { AppSource.calls(of: "presentationDetents(", in: $0) }
            mapsHeights += own
            let detents = AppSource.calls(of: "presentationDetents(", in: code)
            #expect(detents.count - own.count == (path == Self.rule ? 1 : 0), "\(path) sets a sheet's heights by hand: \(detents)")
            #expect(AppSource.calls(of: "presentationDragIndicator(", in: code).isEmpty, "\(path) has a drag indicator of its own")
            let grounds = AppSource.calls(of: "presentationBackground(", in: code)
            let solid = path == "App/Albumist/Views/PhotoViewer.swift" ? ["Theme.background", "Theme.background"] : []
            #expect(grounds == solid, "\(path): \(grounds)")
        }
        #expect(mapsHeights.sorted() == ["[.large]", "[.medium, .large]"], "\(mapsHeights)")
    }

    /// The scan finds a sheet's content however it is opened (a binding with closures, an
    /// `onDismiss`, right after a name, a `content:` argument), names the view it shows also
    /// through a helper of the file, and sees a sheet without the rule; a size or a height
    /// written right after a name counts too. Content passed by name has no size of its own.
    @Test func theScanSeesEverySheetAndOneWithoutTheRule() {
        let code = """
        .sheet(isPresented: Binding(get: { a != nil }, set: { if !$0 { a = nil } })) {
            NavigationRoot { Foo(x: "{") }
        }
        .sheet(item: $b, onDismiss: { done() }) { item in helper(item).sheetSize(.short) }
        content.sheet(isPresented: $c) { shown.sheetSize(.page) }
        .sheet(isPresented: $d, onDismiss: done, content: { Qux(y: "}").sheetSize(.short) })
        .sheet(item: $e, content: makeSheet)
        func helper(_ item: Int) -> some View { Bar(item).sheetSize(.page) }
        private var shown: some View { Baz().presentationDetents([.medium]) }
        """
        let contents = Self.sheetContents(in: code)
        #expect(contents.count == 5, "\(contents)")
        guard contents.count == 5 else { return }
        #expect(AppSource.calls(of: "sheetSize(", in: contents[0]).isEmpty)
        #expect(AppSource.calls(of: "sheetSize(", in: contents[1]) == [".short"])
        #expect(AppSource.calls(of: "sheetSize(", in: contents[2]) == [".page"])
        #expect(AppSource.calls(of: "sheetSize(", in: contents[3]) == [".short"])
        #expect(contents[4] == "makeSheet")
        #expect(Self.shownView(in: contents[0], file: code) == "Foo")
        #expect(Self.shownView(in: contents[1], file: code) == "Bar")
        #expect(Self.shownView(in: contents[2], file: code) == "Baz")
        #expect(Self.shownView(in: contents[3], file: code) == "Qux")
        #expect(AppSource.calls(of: "presentationDetents(", in: code) == ["[.medium]"])
    }

    // MARK: Reading sheets

    /// The content of every `sheet(` call in `code`, as written: the closure after its arguments,
    /// or its `content:` argument (a closure, or what is passed by name); also one written right
    /// after a name (`view.sheet(`).
    static func sheetContents(in code: String) -> [String] {
        let masked = Array(AppSource.code(code).unicodeScalars)
        let kept = Array(code.unicodeScalars)
        return AppSource.callSites(of: "sheet(", in: code).compactMap { site in
            var index = site.offset + "sheet(".unicodeScalars.count
            var depth = 1
            var argument: Int?
            while index < masked.count, depth > 0 {
                if "([{".unicodeScalars.contains(masked[index]) { depth += 1 }
                if ")]}".unicodeScalars.contains(masked[index]) { depth -= 1 }
                // `content:` among the call's own arguments, not inside one of them.
                if depth == 1, argument == nil, Self.isLabel("content:", at: index, in: masked) {
                    argument = Self.skipSpace(from: index + "content:".unicodeScalars.count, in: masked)
                }
                index += 1
            }
            let trailing = Self.skipSpace(from: index, in: masked)
            if trailing < masked.count, masked[trailing] == "{" { return Self.closure(at: trailing, masked: masked, kept: kept) }
            guard let argument, argument < masked.count else { return nil }
            if masked[argument] == "{" { return Self.closure(at: argument, masked: masked, kept: kept) }
            return String(String.UnicodeScalarView(kept[argument..<Self.argumentEnd(from: argument, in: masked)]))
        }
    }

    /// The closure that opens at `open`, as written.
    private static func closure(at open: Int, masked: [Unicode.Scalar], kept: [Unicode.Scalar]) -> String? {
        var depth = 0
        for index in open..<masked.count {
            if masked[index] == "{" { depth += 1 }
            if masked[index] == "}" {
                depth -= 1
                if depth == 0 { return String(String.UnicodeScalarView(kept[open...index])) }
            }
        }
        return nil
    }

    /// Where an argument that starts at `start` ends: at the "," or ")" after it, outside brackets.
    private static func argumentEnd(from start: Int, in masked: [Unicode.Scalar]) -> Int {
        var depth = 0
        for index in start..<masked.count {
            if "([{".unicodeScalars.contains(masked[index]) { depth += 1 }
            if ")]}".unicodeScalars.contains(masked[index]) {
                if depth == 0 { return index }
                depth -= 1
            }
            if masked[index] == ",", depth == 0 { return index }
        }
        return masked.count
    }

    /// `label` (such as "content:") starts at `index`, and not as the end of a longer name.
    private static func isLabel(_ label: String, at index: Int, in masked: [Unicode.Scalar]) -> Bool {
        let wanted = Array(label.unicodeScalars)
        guard index + wanted.count <= masked.count, Array(masked[index..<(index + wanted.count)]) == wanted else { return false }
        return index == 0 || !isWordScalar(masked[index - 1])
    }

    private static func skipSpace(from index: Int, in masked: [Unicode.Scalar]) -> Int {
        var index = index
        while index < masked.count, CharacterSet.whitespacesAndNewlines.contains(masked[index]) { index += 1 }
        return index
    }

    /// The view a sheet's content shows: the first type it makes (`Name(` or `Name {`) other
    /// than the stack around it, else the first helper of the file it calls (`func name(` or
    /// `var name: some View`), read the same way.
    static func shownView(in content: String, file: String, depth: Int = 0) -> String? {
        let masked = Array(AppSource.code(content).unicodeScalars)
        let wrappers: Set<String> = ["NavigationRoot", "Task", "Binding"]
        var words: [(word: String, next: Unicode.Scalar?)] = []
        var index = 0
        while index < masked.count {
            guard Self.isWordScalar(masked[index]) else { index += 1; continue }
            let start = index
            while index < masked.count, Self.isWordScalar(masked[index]) { index += 1 }
            let word = String(String.UnicodeScalarView(masked[start..<index]))
            var after = index
            while after < masked.count, CharacterSet.whitespaces.contains(masked[after]) { after += 1 }
            let previous = start > 0 ? masked[start - 1] : nil
            // A member (`.short`, `model.x`) is never the view.
            if previous != "." { words.append((word, after < masked.count ? masked[after] : nil)) }
        }
        if let type = words.first(where: { $0.word.first?.isUppercase == true && !wrappers.contains($0.word) && ($0.next == "(" || $0.next == "{") }) {
            return type.word
        }
        guard depth < 2 else { return nil }
        for (word, _) in words where word.first?.isLowercase == true {
            for declaration in ["func \(word)(", "var \(word): some View"] {
                if let helper = AppSource.body(of: [declaration], in: file) {
                    return shownView(in: helper, file: file, depth: depth + 1)
                }
            }
        }
        return nil
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    /// The `body` of the view `name`, wherever in the App it is declared, in code only.
    static func body(ofView name: String) throws -> String? {
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = AppSource.code(try AppSource.read(path))
            for declaration in ["struct \(name): ", "struct \(name) {"] where code.contains(declaration) {
                if let body = AppSource.body(of: [declaration, "var body: some View"], in: code) { return body }
            }
        }
        return nil
    }
}
