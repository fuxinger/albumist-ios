import Foundation
import Testing
import AlbumistTestSupport

/// `minimumHitTarget()` (44 × 44 pt to tap, HIG) makes a control easier to tap only on the label
/// of a control: a Button, Menu, Link, ShareLink, NavigationLink, Toggle, or the app's
/// `PushLink` (a Button). The control takes the tap on its label; a frame around the control
/// only grows the layout, and a near miss beside the label still misses (design wave 3, H14).
/// So every call sits inside a control's label, as written in the App, and so does every frame
/// written by hand with a minimum of 44 pt (review S3 of H14). The App does not build on Linux,
/// so this test reads its code (`AppSource`).
@Suite("Hit targets: 44 pt on the label, where the tap is taken")
struct HitTargetSourceTests {
    /// The controls whose label takes the tap.
    static let controls: Set<String> = ["Button", "Menu", "Link", "ShareLink", "NavigationLink", "Toggle", "PushLink"]

    /// Every call in the App sits on a control's label. The year chips of the atlas are the
    /// map's (its own thread of work) and are read like every other call.
    @Test func everyHitTargetSitsOnALabel() throws {
        var sites: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = AppSource.code(try AppSource.read(path))
            let name = URL(fileURLWithPath: path).lastPathComponent
            for site in AppSource.callSites(of: "minimumHitTarget(", in: code) {
                let control = Self.labelOwner(at: site.offset, in: code)
                let line = code.unicodeScalars.prefix(site.offset).filter { $0 == "\n" }.count + 1
                #expect(control != nil, "\(name):\(line): minimumHitTarget() outside a control's label only grows the layout")
                sites.append("\(name): \(control ?? "no label")")
            }
        }
        #expect(sites.sorted() == [
            "AlbumsView.swift: Button",
            "AlbumsView.swift: Button",
            "Atlas.swift: Button",
            "LibraryView.swift: Button",
            "LibraryView.swift: Button",
            "QuickCreateBar.swift: Button",
            "SettingsView.swift: Button",
            "SettingsView.swift: Button",
            "SettingsView.swift: Button",
            "VideoControls.swift: Button",
            "VideoControls.swift: Button",
        ], "\(sites.sorted())")
    }

    /// A frame written by hand with a minimum of 44 pt (`.frame(minHeight: 44`, `minWidth: 44`)
    /// promises what `minimumHitTarget()` does. After a control, at the end of a chain that
    /// starts with the control, also through a name of the file that makes one
    /// (`suggestTitleButton`), it only grows the layout ("OK" under the recount note and "Namen
    /// vorschlagen" did, review S3 of H14); on the label, with a content shape, the tap is taken
    /// there.
    @Test func noHandWrittenFrameOf44AroundAControl() throws {
        var around: [String] = []
        var read = 0
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let scan = Self.framesOf44(in: AppSource.code(try AppSource.read(path)))
            read += scan.read
            around += scan.aroundControls.map { "\(URL(fileURLWithPath: path).lastPathComponent):\($0)" }
        }
        #expect(read >= 20, "the scan reads too few frames: \(read)")
        #expect(around.isEmpty, "a 44 pt frame after a control only grows the layout, put it on the label: \(around)")
    }

    /// A chain that starts with a name of its file is read through that name to the view it makes
    /// (review T7 of H14's round 2: `suggestTitleButton.frame(minHeight: 44)` passed, its head
    /// being a name, not "Button"): a property's or a function's first view, also through another
    /// name; a name the file does not declare as a view, and a stack, stay as they are.
    @Test func aChainThatStartsWithANameIsReadThroughIt() {
        let file = """
        var body: some View {
            VStack {
                suggestButton.frame(minHeight: 44)
                rowLabel.frame(minHeight: 44)
                helper(1).frame(minWidth: 44)
                wrapped.frame(minHeight: 44)
                configuration.label.frame(minHeight: 44)
            }
        }
        private var suggestButton: some View {
            Button { go() } label: { Text("a") }
                .font(.body)
        }
        @ViewBuilder private var rowLabel: some View {
            if on { HStack { Text("b") } } else { Text("c") }
        }
        private func helper(_ value: Int) -> some View {
            Menu { Button("x") {} } label: { Text("d") }
        }
        private var wrapped: some View { suggestButton.padding() }
        """
        let scan = Self.framesOf44(in: AppSource.code(file))
        #expect(scan.read == 5)
        #expect(scan.aroundControls == ["3: suggestButton (Button)", "5: helper (Menu)", "6: wrapped (Button)"], "\(scan.aroundControls)")
    }

    /// The reading of a chain: back from `.frame(` over modifiers, arguments and closures (also a
    /// `label:` closure after the first one) to the view the chain starts with.
    @Test func theReadingFindsTheViewAChainStartsWith() {
        let cases: [(String, String?)] = [
            ("Button(\"OK\") { go() }.font(.subheadline).frame(minHeight: 44)", "Button"),
            ("Button { go() } label: { Text(\"a\") }\n    .font(.body)\n    .frame(minHeight: 44)", "Button"),
            ("Menu { Button(\"x\") {} } label: { Image(systemName: \"x\") }.frame(minWidth: 44)", "Menu"),
            ("Toggle(isOn: $on) { Text(\"a\") }.frame(minHeight: 44)", "Toggle"),
            ("ForEach(items) { item in Button(item.name) { go() }.frame(minHeight: 44) }", "Button"),
            ("Button { go() } label: { Text(\"a\").frame(minWidth: 44, minHeight: 44, alignment: .leading) }", "Text"),
            ("HStack { Text(\"a\") }.frame(maxWidth: .infinity, minHeight: 44)", "HStack"),
            ("configuration.label.font(.body).frame(minHeight: 44)", "configuration"),
        ]
        for (code, head) in cases {
            let sites = AppSource.callSites(of: "frame(", in: code)
            #expect(sites.count == 1, "\(code)")
            guard let site = sites.first else { continue }
            #expect(Self.promises44(site.arguments), "\(code)")
            #expect(Self.chainHead(of: site.offset, in: code) == head, "\(code)")
        }
        #expect(Self.promises44("maxWidth: fillsWidth ? .infinity : nil, minHeight: 44"))
        #expect(!Self.promises44("minHeight: 440"))
        #expect(!Self.promises44("maxHeight: 44"))
    }

    /// The modifier says where it belongs.
    @Test func theModifierSaysItBelongsOnTheLabel() throws {
        let theme = try AppSource.read("App/Albumist/DesignSystem/Theme.swift")
        let lines = theme.components(separatedBy: "\n")
        let index = try #require(lines.firstIndex { $0.contains("func minimumHitTarget() -> some View") })
        let comment = lines[..<index].reversed().prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.reversed().joined(separator: " ")
        #expect(comment.contains("label"), "\(comment)")
        #expect(comment.contains("HitTargetSourceTests"), "\(comment)")
    }

    /// The reading: a label closure (`label:`, the trailing closure of a Link, a Toggle, a
    /// ShareLink, a NavigationLink with its value or a PushLink) counts, wherever inside it the
    /// call is; a title button, a call after the label's closure, and an action do not.
    @Test func theReadingTellsALabelFromTheControlAroundIt() {
        let cases: [(String, String?)] = [
            ("Button { go() } label: { HStack { Text(\"a\") }.minimumHitTarget() }", "Button"),
            ("Button(action: go, label: { Text(\"a\").minimumHitTarget() })", "Button"),
            ("Menu { Button(\"x\") {} } label: { Image(systemName: \"x\").minimumHitTarget() }", "Menu"),
            ("Link(destination: url) { Text(\"a\").minimumHitTarget() }", "Link"),
            ("Toggle(isOn: $on) { Text(\"a\").minimumHitTarget() }", "Toggle"),
            ("NavigationLink(value: 1) { Text(\"a\").minimumHitTarget() }", "NavigationLink"),
            ("PushLink(.settings) { Text(\"a\").minimumHitTarget() }", "PushLink"),
            ("ShareLink(item: url) { Label(\"a\", systemImage: \"x\").minimumHitTarget() }", "ShareLink"),
            ("NavigationLink { Detail() } label: { Text(\"a\").minimumHitTarget() }", "NavigationLink"),
            ("Button(\"a\") { go() }.font(.body).minimumHitTarget()", nil),
            ("Button(action: go, label: { Text(\"a\") }, other: { Text(\"b\").minimumHitTarget() })", nil),
            ("NavigationLink { Text(\"a\").minimumHitTarget() } label: { Text(\"b\") }", nil),
            ("Button { go() } label: { Text(\"a\") }.disabled(no).minimumHitTarget()", nil),
            ("Button { Text(\"a\").minimumHitTarget() } label: { Text(\"b\") }", nil),
            ("Menu { Text(\"a\").minimumHitTarget() } label: { Text(\"b\") }", nil),
            ("HStack { Text(\"a\").minimumHitTarget() }.onTapGesture { go() }", nil),
        ]
        for (code, owner) in cases {
            let site = AppSource.callSites(of: "minimumHitTarget(", in: code)
            #expect(site.count == 1, "\(code)")
            guard let offset = site.first?.offset else { continue }
            #expect(Self.labelOwner(at: offset, in: code) == owner, "\(code)")
        }
    }

    // MARK: Reading frames

    /// The frames of 44 pt in `code` (`promises44`), how many, and those at the end of a chain
    /// that starts with a control, as "line: control".
    static func framesOf44(in code: String) -> (read: Int, aroundControls: [String]) {
        var read = 0
        var around: [String] = []
        for site in AppSource.callSites(of: "frame(", in: code) where promises44(site.arguments) {
            read += 1
            guard let head = chainHead(of: site.offset, in: code) else { continue }
            let view = view(startingWith: head, in: code)
            guard controls.contains(view) else { continue }
            let line = code.unicodeScalars.prefix(site.offset).filter { $0 == "\n" }.count + 1
            around.append("\(line): " + (view == head ? view : "\(head) (\(view))"))
        }
        return (read, around)
    }

    /// The view a chain that starts with `head` makes: `head` when it names a type, else the
    /// first view of the file's `var head: some View` or `func head(`, read as a sheet's content
    /// is (`SheetSizeSourceTests.shownView`, also through another name of the file); a name the
    /// file does not declare as a view stays itself (review T7 of H14's round 2).
    static func view(startingWith head: String, in file: String) -> String {
        guard head.first?.isLowercase == true else { return head }
        return SheetSizeSourceTests.shownView(in: head, file: file) ?? head
    }

    /// The arguments of a `frame(` ask for 44 pt to tap: a minimum height or width of 44.
    static func promises44(_ arguments: String) -> Bool {
        let parts = arguments.split(separator: ",").map { $0.filter { !$0.isWhitespace } }
        return parts.contains("minHeight:44") || parts.contains("minWidth:44")
    }

    /// The view a modifier chain starts with, read back from the modifier at `offset` (the "f"
    /// of `.frame(`): over modifiers, arguments, closures (also `label:` after the first
    /// closure) and subscripts, to the first name that does not follow a dot.
    static func chainHead(of offset: Int, in source: String) -> String? {
        let code = Array(AppSource.code(source).unicodeScalars)
        var index = skipSpace(back: offset - 1, in: code)
        guard index >= 0, code[index] == "." else { return nil }
        index = skipSpace(back: index - 1, in: code)
        while index >= 0 {
            switch code[index] {
            case ")":
                index = skipSpace(back: matching(open: "(", close: ")", from: index, in: code) - 1, in: code)
            case "]":
                index = skipSpace(back: matching(open: "[", close: "]", from: index, in: code) - 1, in: code)
            case "}":
                index = skipSpace(back: matching(open: "{", close: "}", from: index, in: code) - 1, in: code)
                // `} label: {`: the closure before the label's belongs to the same call.
                if index >= 0, code[index] == ":", let label = word(endingAt: index - 1, in: code) {
                    index = skipSpace(back: index - 1 - label.unicodeScalars.count, in: code)
                }
            default:
                guard let name = word(endingAt: index, in: code) else { return nil }
                let before = skipSpace(back: index - name.unicodeScalars.count, in: code)
                guard before >= 0, code[before] == "." else { return name }
                index = skipSpace(back: before - 1, in: code)
            }
        }
        return nil
    }
}

/// How the guards read the code around a call: the control whose label holds it, and the small
/// scanners both readings share (apart from the struct's tests, SwiftLint's type body length).
extension HitTargetSourceTests {
    // MARK: Reading labels

    /// The control whose label holds the code at `offset`, or nil when no enclosing block is a
    /// control's label.
    static func labelOwner(at offset: Int, in source: String) -> String? {
        let code = Array(AppSource.code(source).unicodeScalars)
        var depth = 0
        var index = offset - 1
        while index >= 0 {
            let scalar = code[index]
            if scalar == "}" || scalar == ")" { depth += 1 }
            if scalar == "{" || scalar == "(" {
                // An enclosing block or argument list (depth 0); only a block can be a label.
                if depth == 0, scalar == "{", let owner = closureOwner(open: index, in: code) { return owner }
                if depth > 0 { depth -= 1 }
            }
            index -= 1
        }
        return nil
    }

    /// The control a block opened at `open` is the label closure of: after `label:`, or the
    /// trailing closure of a control whose only closure is its label.
    private static func closureOwner(open: Int, in code: [Unicode.Scalar]) -> String? {
        let before = skipSpace(back: open - 1, in: code)
        guard before >= 0 else { return nil }
        if code[before] == ":" { return labelOwner(colon: before, in: code) }
        // The only trailing closure of a control whose closure is its label.
        guard code[before] == ")" else { return nil }
        return trailingLabelOwner(close: before, in: code)
    }

    /// `label:` (its ":" at `colon`) after the first trailing closure (`Button { } label: {`,
    /// `Menu { } label: {`); as an argument (`Button(action: go, label: {`) the parentheses tell.
    private static func labelOwner(colon: Int, in code: [Unicode.Scalar]) -> String? {
        guard word(endingAt: colon - 1, in: code) == "label" else { return nil }
        var before = skipSpace(back: colon - 1 - "label".unicodeScalars.count, in: code)
        guard before >= 0 else { return nil }
        if code[before] == "," || code[before] == "(" {
            // An argument: the control is the call whose parentheses hold it.
            before = skipSpace(back: openParenthesis(around: before, in: code) - 1, in: code)
        } else {
            if code[before] == "}" {
                before = skipSpace(back: matching(open: "{", close: "}", from: before, in: code) - 1, in: code)
            }
            if before >= 0, code[before] == ")" {
                before = skipSpace(back: matching(open: "(", close: ")", from: before, in: code) - 1, in: code)
            }
        }
        guard let name = word(endingAt: before, in: code), controls.contains(name) else { return nil }
        return name
    }

    /// The control whose argument list closes at `close`, when its trailing closure is its
    /// label: a link, a toggle, or a button or navigation link given its action or destination.
    private static func trailingLabelOwner(close before: Int, in code: [Unicode.Scalar]) -> String? {
        let start = matching(open: "(", close: ")", from: before, in: code)
        let arguments = String(String.UnicodeScalarView(code[start...before]))
        guard let name = word(endingAt: skipSpace(back: start - 1, in: code), in: code) else { return nil }
        switch name {
        case "Link", "ShareLink", "Toggle", "PushLink": return name
        case "NavigationLink" where arguments.contains("value:") || arguments.contains("destination:"): return name
        case "Button" where arguments.contains("action:"): return name
        default: return nil
        }
    }

    /// The "(" of the argument list that holds `index` (a "," or the "(" itself), or -1.
    private static func openParenthesis(around index: Int, in code: [Unicode.Scalar]) -> Int {
        if code[index] == "(" { return index }
        var depth = 0
        var at = index - 1
        while at >= 0 {
            if code[at] == ")" || code[at] == "}" || code[at] == "]" { depth += 1 }
            if code[at] == "(" || code[at] == "{" || code[at] == "[" {
                if depth == 0 { return code[at] == "(" ? at : -1 }
                depth -= 1
            }
            at -= 1
        }
        return -1
    }

    private static func skipSpace(back index: Int, in code: [Unicode.Scalar]) -> Int {
        var index = index
        while index >= 0, CharacterSet.whitespacesAndNewlines.contains(code[index]) { index -= 1 }
        return index
    }

    /// The identifier that ends at `index`, if one does.
    private static func word(endingAt index: Int, in code: [Unicode.Scalar]) -> String? {
        var start = index
        while start >= 0, CharacterSet.alphanumerics.contains(code[start]) || code[start] == "_" { start -= 1 }
        guard start < index else { return nil }
        return String(String.UnicodeScalarView(code[(start + 1)...index]))
    }

    /// Where the `open` that `close` at `from` closes is.
    private static func matching(open: Unicode.Scalar, close: Unicode.Scalar, from: Int, in code: [Unicode.Scalar]) -> Int {
        var depth = 0
        var index = from
        while index >= 0 {
            if code[index] == close { depth += 1 }
            if code[index] == open {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return 0
    }
}
