import Foundation
import Testing
import AlbumistTestSupport

/// The search tab (design wave 3, DS-12a; draft E1: "Suche als eigener runder Knopf wie in
/// iOS 26"), as the owner chose it on 25.11.2026 ("Runder Knopf, Suche bleibt"): a round button
/// of its own at the bar's end; choosing it shows the page with its starting points (DS-13) and
/// the field; the keyboard comes when the field is tapped; the query, the hits and the scroll
/// position stay while another tab is looked at, as before wave 3. Where the field sits is the
/// system's (`MainTabs.searchField`, `MainTabs.searchRole`):
/// - iOS 26: the search role, drawn as the round button, and the field on the tab view in the
///   bar's place (`.tabView`), Apple's documented search tab.
/// - iOS 27: the same tab was a fourth tab in the row on iOS 27.2 and showed no field until it
///   was activated, which put it at the top (UI run 45567033486): the prominent role, the
///   documented separate round button at the bar's end, and the field on the page's own stack
///   under its title, always shown (`.page`).
/// Choosing the tab never activates the field (no `tabViewSearchActivation`), and nothing
/// focuses it by hand. What is typed lives with the tabs (`SearchInput`), and the search page
/// reads it. A route that changes the tab in code takes only the keyboard away and keeps the
/// search. The two placements before the owner's choice (the keyboard every time; the page's
/// own field focused as it opened) are gone. The App does not build on Linux, so these tests
/// read its code (`AppSource`); how the bar looks is the frame test's (`FrameUITests` test1).
@Suite("Search tab: a round button, the search stays (DS-12a)")
struct SearchTabSourceTests {
    static let root = "App/Albumist/Views/RootView.swift"
    static let search = "App/Albumist/Views/SearchView.swift"
    /// The field as both places make it: the page's prompt, bound to the tabs' search, drawn as
    /// its place says.
    static let field = "content.searchable(text:$input.text,isPresented:$input.isPresented,placement:host.field,prompt:SearchView.prompt)"

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

    /// The `///` lines right above the first line of `path` that contains `marker`, as one text
    /// without their slashes, so a phrase broken over two lines reads as one.
    static func docComment(above marker: String, in path: String) throws -> String {
        let lines = try AppSource.read(path).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let line = try #require(lines.firstIndex { $0.contains(marker) }, "\(marker) is not in \(path)")
        let above = lines[..<line].reversed().prefix { $0.hasPrefix("///") }
        return above.reversed().map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// The `//` lines of `text` between `start` and the next `end`, as one text without their
    /// slashes.
    static func comments(between start: String, and end: String, in text: String) throws -> String {
        let from = try #require(text.range(of: start), "\(start) is not there")
        let to = try #require(text.range(of: end, range: from.upperBound..<text.endIndex), "\(end) is not there")
        return text[from.upperBound..<to.lowerBound].components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("//") }
            .map { $0.drop { $0 == "/" }.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    /// The tabs keep what is typed and hand it to the search page. The search tab is the page's
    /// stack with a name and a symbol of its own (the prominent role has no system label) and the
    /// role of its system (`MainTabs.searchRole`); the field's place on the tab view is asked for
    /// on the tab view itself, before anything else wraps it (the moment's layer, the alert, the
    /// purchase sheet), and the page asks for its own place: one of the two gets the field.
    @Test func theTabsKeepTheSearchAndAskForItsFieldOnTheTabView() throws {
        let tabs = try Self.body(["struct MainTabs"], in: Self.root)
        #expect(tabs.contains("@State private var search = SearchInput()"), "\(tabs)")
        let body = Self.squeezed(try Self.body(["struct MainTabs", "var body: some View"], in: Self.root))
        #expect(body.contains("Tab(\"Suchen\",systemImage:\"magnifyingglass\",value:MainTab.search,role:Self.searchRole){"
                              + "NavigationRoot(quickCreate:true){SearchView(input:search)}.showsQuickCreateBanner()}}"),
                "the search tab's content is not the page's stack with the tabs' search: \(body)")
        #expect(body.contains("}.searchField(search,on:.tabView).tabViewStyle(.sidebarAdaptable)"),
                "the field's place on the tab view is not asked for on the tab view itself: \(body)")
        #expect(body.components(separatedBy: ".searchField(").count - 1 == 1, "\(body)")
        // One role per tab, from one place (`MainTabs.searchRole`); no other tab takes a role of
        // the search's (the alert's "OK" keeps its own).
        #expect(body.components(separatedBy: "role:Self.searchRole").count - 1 == 1, "\(body)")
        for role in ["role:.search", "role:.prominent"] {
            #expect(!body.contains(role), "a tab takes \(role) beside the search's own: \(body)")
        }
    }

    /// The owner's choice on both systems, from one place each, documented: the field and the
    /// role by the system the app runs on. The comment says what the user gets and what iOS 27.2
    /// showed of the search role alone.
    @Test func theRoleAndTheFieldFollowTheSystem() throws {
        let raw = try AppSource.read(Self.root)
        #expect(raw.components(separatedBy: "static var searchField").count - 1 == 1)
        #expect(raw.components(separatedBy: "static var searchRole").count - 1 == 1)
        let field = Self.squeezed(try Self.body(["struct MainTabs", "static var searchField: SearchInput.Placement"], in: Self.root))
        #expect(field == "{if#available(iOS27,*){return.page}return.tabView}", "\(field)")
        let role = Self.squeezed(try Self.body(["struct MainTabs", "static var searchRole: TabRole"], in: Self.root))
        #expect(role == "{if#available(iOS27,*){return.prominent}return.search}", "\(role)")
        let comment = try Self.docComment(above: "static var searchField: SearchInput.Placement", in: Self.root)
        for word in ["25.11.2026", "Runder Knopf, Suche bleibt", "round button", "starting points", "tapped", "stay",
                     "iOS 26", "iOS 27.2", "45567033486", "prominent", "always shown"] {
            #expect(comment.contains(word), "the comment does not say \(word): \(comment)")
        }
        let roleComment = try Self.docComment(above: "static var searchRole: TabRole", in: Self.root)
        for word in ["search role", "prominent role", "round button", "One role per tab"] {
            #expect(roleComment.contains(word), "the role's comment does not say \(word): \(roleComment)")
        }
        // Two places, each with the field's look on its view; the choices of before are gone.
        let placement = Self.squeezed(try Self.body(["final class SearchInput", "enum Placement"], in: Self.search))
        #expect(placement == "{casetabViewcasepagevarfield:SearchFieldPlacement{switchself{"
                + "case.tabView:.automaticcase.page:.navigationBarDrawer(displayMode:.always)}}}", "\(placement)")
        let app = try AppSource.swiftFiles(under: "App/Albumist").map { AppSource.code(try AppSource.read($0)) }.joined()
        for gone in ["tabViewKeepingSearch", "tabViewOpeningKeyboard", "pageFocusingField", "enum Host", ".tabViewSearchActivation("] {
            #expect(!app.contains(gone), "\(gone) is still in the app")
        }
    }

    /// The field where the system puts it, one field, which keeps the search: the system activates
    /// it when it is tapped, never the tab and never the page by hand (on iOS 26 it is the bar's,
    /// on iOS 27 it stands under the page's title); its focus is bound, so a route can take the
    /// keyboard away (`leftInCode`).
    @Test func theFieldSitsWhereTheSystemPutsItAndKeepsTheSearch() throws {
        let modifier = Self.squeezed(try Self.body(["private struct SearchFieldModifier", "func body(content: Content)"], in: Self.search))
        #expect(modifier == "{ifhost!=MainTabs.searchField{content}else{\(Self.field).searchFocused($focused)"
                + ".onChange(of:input.keyboardAway){focused=false}}}", "\(modifier)")
        let type = Self.squeezed(try Self.body(["private struct SearchFieldModifier"], in: Self.search))
        #expect(type.contains("@Bindablevarinput:SearchInput"), "\(type)")
        #expect(type.contains("varhost:SearchInput.Placement"), "\(type)")
        #expect(type.contains("@FocusStateprivatevarfocused:Bool"), "\(type)")
        let extensionBody = Self.squeezed(try Self.body(["func searchField(_ input: SearchInput, on host: SearchInput.Placement) -> some View"],
                                                        in: Self.search))
        #expect(extensionBody == "{modifier(SearchFieldModifier(input:input,host:host))}", "\(extensionBody)")
        // The prompt as before, in its two variants.
        let prompt = Self.squeezed(try Self.body(["struct SearchView", "static var prompt: Text"], in: Self.search))
        #expect(prompt == "{SmartAssistant.isAvailable?Text(\"z.B.GrillenbeiOmaletztenSommer\"):Text(\"z.B.HundeItalien2023\")}", "\(prompt)")
        // The page asks for the field where its own field was, between the undo bar's animation
        // and the starting points' task, inside its stack (the stack's bar draws it on iOS 27).
        let page = Self.squeezed(try Self.body(["struct SearchView", "var body: some View"], in: Self.search))
        #expect(page.contains(".animation(.snappy,value:model.lastIgnored).searchField(input,on:.page).task(id:model.factsVersion){"), "\(page)")
        #expect(!page.contains(".searchable("), "a field of the page's own besides the modifier")
        #expect(!page.contains(".onAppear"), "the page focuses its field by hand besides the modifier")
    }

    /// The comments say what the field does: it becomes active when it is tapped, and the search
    /// stays while another tab is chosen; none says the keyboard comes every time.
    @Test func theCommentsSayWhatTheFieldDoes() throws {
        let raw = try AppSource.read(Self.search)
        let modifier = try #require(AppSource.body(of: ["private struct SearchFieldModifier", "func body(content: Content)"], in: raw))
        let kept = try Self.comments(between: "} else {", and: "content\n", in: modifier)
        for word in ["tapped", "stays"] {
            #expect(kept.contains(word), "the field's comment does not say \(word): \(kept)")
        }
        let placement = try #require(AppSource.body(of: ["final class SearchInput", "enum Placement"], in: raw))
        for word in ["iOS 26", "iOS 27", "always shown", "under its title"] {
            #expect(placement.contains(word), "the places' comments do not say \(word): \(placement)")
        }
        let header = try Self.docComment(above: "@Suite(\"Search tab", in: "Tests/AlbumistCoreTests/SearchTabSourceTests.swift")
        #expect(header.contains("Runder Knopf, Suche bleibt") && header.contains("45567033486"), "\(header)")
        for text in [raw, try AppSource.read(Self.root)] {
            #expect(!text.contains("every time"), "a comment still says the keyboard comes every time")
        }
    }

    /// The page reads and writes the tabs' text: its starting points and completions set it, its
    /// search follows it after the pause of 250 ms, and nothing else of the page changed.
    @Test func thePageSearchesTheTabsText() throws {
        let type = try Self.body(["struct SearchView"], in: Self.search)
        #expect(type.contains("    let input: SearchInput\n"), "\(type)")
        #expect(!type.contains("@State private var query"), "the page keeps a text of its own")
        #expect(!type.contains("searchActive"), "the page keeps a presentation of its own")
        // The hits' parts sit in an extension beside the struct (SwiftLint's type body length).
        let parts = try Self.body(["extension SearchView"], in: Self.search)
        #expect(!parts.contains("searchActive"), "the page keeps a presentation of its own")
        let query = Self.squeezed(try Self.body(["struct SearchView", "private var query: String"], in: Self.search))
        #expect(query == "{get{input.text}nonmutatingset{input.text=newValue}}", "\(query)")
        let page = Self.squeezed(try Self.body(["struct SearchView", "var body: some View"], in: Self.search))
        #expect(page.contains(".task(id:query){lettext=query"), "\(page)")
        #expect(page.contains("letcompletions=awaitmodel.searchSuggestions(for:text)suggestions=completionstry?awaitTask.sleep(for:.milliseconds(250))"),
                "\(page)")
        let completions = Self.squeezed(try Self.body(["struct SearchView", "private var suggestionList: some View"], in: Self.search))
        #expect(completions.contains("query=suggestion.completion+\"\""), "\(completions)")
    }

    /// Siri, Shortcuts, Spotlight and a notification change the tab in code (`model.route`). A
    /// route that leaves the search tab hands the search to `SearchInput.leftInCode()` before the
    /// tab changes (review S of H14, unsure 2), which keeps the search as the owner chose (review T2
    /// of round 2): only the keyboard goes, through the field's focus bound with `.searchFocused`,
    /// and the query, the hits and the scroll position stay, as after a look at another tab; ending
    /// the search there would empty the field (Apple: dismissing a search clears its text). The
    /// keyboard is taken away by a request, a counter the route raises (review Q3 of round 3), not
    /// by a mirrored focus: had the binding not seen the field of the tab bar focused, the mirror
    /// was false already, nothing changed, and the keyboard stayed. Asking a field without focus to
    /// give it up costs nothing.
    @Test func aRouteTakesOnlyTheKeyboardAway() throws {
        let body = Self.squeezed(try Self.body(["struct MainTabs", "var body: some View"], in: Self.root))
        let route = try #require(body.range(of: ".onChange(of:model.route,initial:true){_,targetin"), "\(body)")
        let rest = body[route.upperBound...]
        let leaves = try #require(rest.range(of: "iftab==.search{search.leftInCode()}"), "a route leaves an open search as it is: \(rest)")
        let chosen = try #require(rest.range(of: "tab=.suggestions"), "\(rest)")
        #expect(leaves.upperBound <= chosen.lowerBound, "the search is left after the tab changed")
        #expect(!body.contains("search.isPresented"), "the tabs end the search themselves: \(body)")
        let input = try Self.body(["final class SearchInput"], in: Self.search)
        #expect(input.contains("    private(set) var keyboardAway = 0\n"), "\(input)")
        #expect(!input.contains("isFocused"), "the keyboard follows a mirrored focus: \(input)")
        let left = Self.squeezed(try Self.body(["final class SearchInput", "func leftInCode()"], in: Self.search))
        #expect(left == "{keyboardAway&+=1}", "\(left)")
        // Raised there only, and only the field's modifier answers it.
        let code = Self.squeezed(try Self.code(Self.search))
        #expect(code.components(separatedBy: "keyboardAway&+=1").count - 1 == 1, "\(code)")
        #expect(code.components(separatedBy: "input.keyboardAway").count - 1 == 1, "\(code)")
        // Nothing ends the search in code: `isPresented` is set false only where it is declared.
        #expect(code.components(separatedBy: "isPresented=false").count - 1 == 1, "something ends the search in code: \(code)")
        #expect(code.contains("varisPresented=false"), "\(code)")
        // Its comment says what becomes of the query.
        let comment = try Self.docComment(above: "func leftInCode()", in: Self.search)
        for word in ["only the keyboard", "the query", "stay", "empty"] {
            #expect(comment.contains(word), "the comment does not say \(word): \(comment)")
        }
        // Only the field's modifier binds its focus.
        let search = try Self.code(Self.search)
        #expect(search.components(separatedBy: ".searchFocused(").count - 1 == 1, "\(search)")
    }

    /// Coming back to the search tab does not search again (review T3 of H14's round 2): the
    /// page's task starts again each time its page appears, so it asks `SearchAnswer` at its top,
    /// right after the empty check, with the text and the revision of everything a search reads
    /// (`model.searchRevisionNow()`, review Q1 of round 3: not only the photos' facts), and does
    /// nothing when the answer on the page is the finished one for both: no second question to
    /// Apple Intelligence, no "Verstanden als" going away and back, the pages of hits shown stay.
    /// Only a new text shows the hits from the first page again. The task's id is the text alone:
    /// a change is searched when the tab is chosen again, never while the page stays open.
    @Test func comingBackToTheTabDoesNotSearchAgain() throws {
        let type = try Self.body(["struct SearchView"], in: Self.search)
        #expect(type.contains("@State private var answer = SearchAnswer()"), "\(type)")
        #expect(!type.contains("@State private var resultQuery") && !type.contains("@State private var searching"), "\(type)")
        let page = Self.squeezed(try Self.body(["struct SearchView", "var body: some View"], in: Self.search))
        let task = try #require(page.range(of: ".task(id:query){"), "\(page)")
        let rest = String(page[task.upperBound...])
        #expect(rest.hasPrefix("lettext=queryguard!text.trimmingCharacters(in:.whitespaces).isEmptyelse{"
                + "result=SearchResult();answer.emptied();suggestions=[]return}"
                + "letrevision=awaitmodel.searchRevisionNow()guard!Task.isCancelledelse{return}"
                + "guardanswer.starts(text,revision:revision)else{return}"), "\(rest)")
        #expect(rest.contains("result=found.beside(completions,for:text)ifanswer.shows(text,revision:revision){shown=Self.page}}"), "\(rest)")
        #expect(!rest.contains("factsVersion"), "the answer keys on the photos' facts alone: \(rest)")
        // The revision is asked by this task only, and is no task's id: no search of its own while
        // the page stays open (during an analysis it would ask Apple Intelligence again and again).
        let view = Self.squeezed(try Self.code(Self.search))
        #expect(view.components(separatedBy: "searchRevision").count - 1 == 1, "\(view)")
        #expect(page.components(separatedBy: ".task(id:").count - 1 == 2, "\(page)")
        #expect(page.contains(".task(id:model.factsVersion){") && page.contains(".task(id:query){"), "\(page)")
        #expect(page.components(separatedBy: "shown=Self.page").count - 1 == 1, "\(page)")
        #expect(page.contains("ifletrewrite=model.lastSearchRewrite,!answer.searching{"), "\(page)")
        // The core's two calls with the revision, nothing of the facts' revision.
        #expect(!view.contains("facts:facts"), "\(view)")
        #expect(page.contains("ifanswer.text.isEmpty{"), "\(page)")
        let parts = Self.squeezed(try Self.body(["extension SearchView"], in: Self.search))
        #expect(parts.contains("ContentUnavailableView.search(text:answer.text)"), "\(parts)")
    }

    /// One field for the search: `.searchable(` bound to `SearchInput` once, in the modifier, and no
    /// `tabViewSearchActivation` (choosing the tab never brings the keyboard). Every other field of
    /// the app ("Album suchen", "Ort suchen") binds a text of its own view, never the tabs' search,
    /// so typing there never starts a search; and only the tabs and the search page know
    /// `SearchInput`.
    @Test func theOtherFieldsSearchTheirOwnText() throws {
        var fields: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = try Self.code(path)
            let calls = Self.arguments(of: "searchable(", in: code)
            if path == Self.search {
                #expect(calls == ["text: $input.text, isPresented: $input.isPresented, placement: host.field, prompt: SearchView.prompt"], "\(calls)")
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
            #expect(!code.contains(".tabViewSearchActivation("), "\(path): choosing the tab activates the field")
        }
        #expect(fields.sorted() == [
            "HomeSettingsView.swift: text: $query, prompt: Text(\"Ort suchen\")",
            "LibraryView.swift: text: $query, prompt: Text(\"Album suchen\")",
            "ProposalViews.swift: text: $query, prompt: Text(\"Album suchen\")",
        ], "\(fields)")
    }

    /// The arguments of every call of `function` (ending in "(") in `code`, as written: strings
    /// kept. Without its dot, so a call right after a name (`content.searchable(`) counts too.
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
