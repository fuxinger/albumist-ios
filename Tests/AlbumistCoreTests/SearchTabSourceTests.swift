import Foundation
import Testing
import AlbumistTestSupport

/// The search as its own round button at the trailing end of the tab bar (design wave 3, DS-12a;
/// draft E1: "Suche als eigener runder Knopf wie in iOS 26"), built the way Apple documents a
/// search tab: the field on the tab view, the search tab's content a stack, and choosing the tab
/// activates the field (`tabViewSearchActivation(.searchTabSelection)`, which does what the page
/// did by hand: the field focused as the tab opens). What is typed lives with the tabs
/// (`SearchInput`), and the search page reads it; everything the page does stays as it was. The
/// placement until wave 3 (the field on the page's own stack) stays behind one switch,
/// `MainTabs.searchField`, until the screenshots on iOS 27.2 decide. The App does not build on
/// Linux, so these tests read its code (`AppSource`); how the bar looks is a screenshot check.
@Suite("Search tab: the round search button (DS-12a)")
struct SearchTabSourceTests {
    static let root = "App/Albumist/Views/RootView.swift"
    static let search = "App/Albumist/Views/SearchView.swift"

    /// The code of `path` (comments blanked, strings kept).
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ declarations: [String], in path: String) throws -> String {
        try #require(AppSource.body(of: declarations, in: try code(path)), "\(declarations) is not in \(path)")
    }

    /// `text` without any white space, so a check does not depend on how a line is broken.
    static func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The tabs keep what is typed and hand it to the search page; the field sits on the tab view
    /// itself, before anything else wraps it (the moment's layer, the alert, the purchase sheet),
    /// and the search tab's content is a stack, as Apple shows it.
    @Test func theTabsKeepTheSearchAndPutItsFieldOnTheTabView() throws {
        let tabs = try Self.body(["struct MainTabs"], in: Self.root)
        #expect(tabs.contains("@State private var search = SearchInput()"), "\(tabs)")
        let body = Self.squeezed(try Self.body(["struct MainTabs", "var body: some View"], in: Self.root))
        #expect(body.contains("Tab(value:MainTab.search,role:.search){NavigationRoot(quickCreate:true){SearchView(input:search)}.showsQuickCreateBanner()}}"),
                "the search tab's content is not the page's stack with the tabs' search: \(body)")
        #expect(body.contains("}.searchField(search,on:.tabView).tabViewStyle(.sidebarAdaptable)"),
                "the field is not on the tab view itself: \(body)")
        #expect(body.components(separatedBy: ".searchField(").count - 1 == 1, "\(body)")
        // The tab keeps its role: one role per tab, and only the search role makes the field's
        // tab the round button (`TabRole.prominent` would take the search role away).
        #expect(!body.contains(".prominent"), "\(body)")
    }

    /// One switch, documented, the new placement by default: `.page` brings the field back onto
    /// the search page's own stack, as until wave 3, in one line.
    @Test func oneSwitchKeepsTheOldPlacementAtHand() throws {
        let tabs = try Self.body(["struct MainTabs"], in: Self.root)
        #expect(tabs.contains("static let searchField: SearchInput.Host = .tabView"), "\(tabs)")
        let raw = try AppSource.read(Self.root)
        #expect(raw.components(separatedBy: "static let searchField").count - 1 == 1)
        // Its comment says what each value does.
        let lines = raw.components(separatedBy: "\n")
        let line = try #require(lines.firstIndex { $0.contains("static let searchField: SearchInput.Host = .tabView") })
        let above = lines[..<line].reversed().prefix(while: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("///") })
        let comment = above.reversed().joined(separator: " ")
        for word in ["`.tabView`", "`.page`", "iOS 27.2"] {
            #expect(comment.contains(word), "the switch's comment does not name \(word): \(comment)")
        }
        let host = try Self.body(["final class SearchInput", "enum Host"], in: Self.search)
        #expect(Self.squeezed(host) == "{casetabViewcasepage}", "\(host)")
    }

    /// Apple's search tab when the switch says `.tabView`: the page's prompt, and choosing the
    /// tab activates the field (the keyboard comes as the tab opens, as before; closing the field
    /// goes back to the tab before). With `.page` the page's own field as until wave 3: the same
    /// prompt, focused when the page opens with nothing typed. Never both: the modifier puts the
    /// field only where the switch says.
    @Test func theFieldSitsWhereTheSwitchSays() throws {
        let modifier = Self.squeezed(try Self.body(["private struct SearchFieldModifier", "func body(content: Content)"], in: Self.search))
        #expect(modifier.hasPrefix("{ifhost!=MainTabs.searchField{content}"), "\(modifier)")
        #expect(modifier.contains("}elseifhost==.tabView{content.searchable(text:$input.text,isPresented:$input.isPresented,prompt:SearchView.prompt).tabViewSearchActivation(.searchTabSelection)}"),
                "\(modifier)")
        #expect(modifier.contains("}else{content.searchable(text:$input.text,isPresented:$input.isPresented,prompt:SearchView.prompt).onAppear{ifinput.text.isEmpty{input.isPresented=true}}}"),
                "\(modifier)")
        let type = Self.squeezed(try Self.body(["private struct SearchFieldModifier"], in: Self.search))
        #expect(type.contains("@Bindablevarinput:SearchInput"), "\(type)")
        let extensionBody = Self.squeezed(try Self.body(["func searchField(_ input: SearchInput, on host: SearchInput.Host) -> some View"], in: Self.search))
        #expect(extensionBody == "{modifier(SearchFieldModifier(input:input,host:host))}", "\(extensionBody)")
        // The prompt as before, in its two variants.
        let prompt = Self.squeezed(try Self.body(["struct SearchView", "static var prompt: Text"], in: Self.search))
        #expect(prompt == "{SmartAssistant.isAvailable?Text(\"z.B.GrillenbeiOmaletztenSommer\"):Text(\"z.B.HundeItalien2023\")}", "\(prompt)")
        // The page puts the modifier where its own field was, between the undo bar's animation
        // and the starting points' task.
        let page = Self.squeezed(try Self.body(["struct SearchView", "var body: some View"], in: Self.search))
        #expect(page.contains(".animation(.snappy,value:model.lastIgnored).searchField(input,on:.page).task(id:model.factsVersion){"), "\(page)")
        #expect(!page.contains(".searchable("), "a field of the page's own besides the modifier")
        #expect(!page.contains(".onAppear"), "the page focuses its field by hand besides the modifier")
    }

    /// The page reads and writes the tabs' text: its starting points and completions set it, its
    /// search follows it after the pause of 250 ms, and nothing else of the page changed.
    @Test func thePageSearchesTheTabsText() throws {
        let type = try Self.body(["struct SearchView"], in: Self.search)
        #expect(type.contains("    let input: SearchInput\n"), "\(type)")
        #expect(!type.contains("@State private var query"), "the page keeps a text of its own")
        #expect(!type.contains("searchActive"), "the page keeps a presentation of its own")
        let query = Self.squeezed(try Self.body(["struct SearchView", "private var query: String"], in: Self.search))
        #expect(query == "{get{input.text}nonmutatingset{input.text=newValue}}", "\(query)")
        let page = Self.squeezed(try Self.body(["struct SearchView", "var body: some View"], in: Self.search))
        #expect(page.contains(".task(id:query){lettext=query"), "\(page)")
        #expect(page.contains("letcompletions=awaitmodel.searchSuggestions(for:text)suggestions=completionstry?awaitTask.sleep(for:.milliseconds(250))"),
                "\(page)")
        let completions = Self.squeezed(try Self.body(["struct SearchView", "private var suggestionList: some View"], in: Self.search))
        #expect(completions.contains("query=suggestion.completion+\"\""), "\(completions)")
    }

    /// One field for the search: `.searchable(` bound to `SearchInput` only in the modifier, and
    /// `tabViewSearchActivation` once. Every other field of the app ("Album suchen", "Ort suchen")
    /// binds a text of its own view, never the tabs' search, so typing there never starts a
    /// search; and only the tabs and the search page know `SearchInput`.
    @Test func theOtherFieldsSearchTheirOwnText() throws {
        var fields: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = try Self.code(path)
            let calls = Self.arguments(of: ".searchable(", in: code)
            if path == Self.search {
                #expect(calls == Array(repeating: "text: $input.text, isPresented: $input.isPresented, prompt: SearchView.prompt", count: 2), "\(calls)")
                continue
            }
            for call in calls {
                fields.append("\(URL(fileURLWithPath: path).lastPathComponent): \(call)")
                #expect(call.hasPrefix("text: $query,"), "\(path): \(call)")
                #expect(!call.contains("input") && !call.contains("isPresented"), "\(path): \(call)")
            }
            if !calls.isEmpty {
                // The text the field binds is the view's own.
                #expect(code.contains("@State private var query = \"\""), "\(path): the field binds a text that is not the view's own")
            }
            if path != Self.root {
                #expect(!code.contains("SearchInput") || path == Self.search, "\(path) knows the tabs' search")
            }
            #expect(path == Self.search || !code.contains(".tabViewSearchActivation("), "\(path)")
        }
        #expect(fields.sorted() == [
            "HomeSettingsView.swift: text: $query, prompt: Text(\"Ort suchen\")",
            "LibraryView.swift: text: $query, prompt: Text(\"Album suchen\")",
            "ProposalViews.swift: text: $query, prompt: Text(\"Album suchen\")",
        ], "\(fields)")
        let search = try Self.code(Self.search)
        #expect(search.components(separatedBy: ".tabViewSearchActivation(").count - 1 == 1)
    }

    /// The arguments of every call of `function` (ending in "(") in `code`, as written: strings kept.
    static func arguments(of function: String, in code: String) -> [String] {
        let masked = Array(AppSource.code(code).unicodeScalars)
        let kept = Array(code.unicodeScalars)
        return AppSource.callSites(of: function, in: code).map { site in
            let open = site.offset + function.unicodeScalars.count
            var depth = 1
            var end = open
            while end < masked.count, depth > 0 {
                if masked[end] == "(" { depth += 1 }
                if masked[end] == ")" { depth -= 1 }
                if depth > 0 { end += 1 }
            }
            let arguments = String(String.UnicodeScalarView(kept[open..<min(end, kept.count)]))
            return arguments.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
    }
}
