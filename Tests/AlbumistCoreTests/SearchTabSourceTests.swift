import Foundation
import Testing
import AlbumistTestSupport

/// The search on the tab view (design wave 3, DS-12a; draft E1: "Suche als eigener runder Knopf
/// wie in iOS 26"), built the way Apple documents a search tab: the field on the tab view, the
/// search tab's content a stack. Where the field sits also decides how the search behaves, so the
/// one switch, `MainTabs.searchField`, names both (review S1 of H14):
/// - `.tabViewKeepingSearch`, the default: choosing the tab shows the page with its starting
///   points (DS-13) and the field; the keyboard comes when the field is tapped; the query, the
///   hits and the scroll position stay while another tab is looked at, as before wave 3.
/// - `.tabViewOpeningKeyboard`: choosing the tab activates the field
///   (`tabViewSearchActivation(.searchTabSelection)`), so the keyboard comes every time, also over
///   an earlier query, and closing the field goes back to the tab before and empties it (Apple:
///   dismissing a search clears its text). Round 1 took this one for what the page did by hand;
///   it is not: the page focused its field only while it was empty and kept the search.
/// - `.pageFocusingField`: the field on the page's own stack as until wave 3, focused as the page
///   opens with nothing typed.
/// What is typed lives with the tabs (`SearchInput`), and the search page reads it. A route that
/// changes the tab in code takes only the keyboard away by default and keeps the search; with the
/// other two placements it ends the search. The screenshots on iOS 27.2 and the owner decide.
/// The App does not build on Linux, so these tests read its code (`AppSource`); how the bar looks
/// is a screenshot check.
@Suite("Search tab: the field on the tab view (DS-12a)")
struct SearchTabSourceTests {
    static let root = "App/Albumist/Views/RootView.swift"
    static let search = "App/Albumist/Views/SearchView.swift"
    /// The field as every placement makes it: the page's prompt, bound to the tabs' search.
    static let field = "content.searchable(text:$input.text,isPresented:$input.isPresented,prompt:SearchView.prompt)"

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
        // tab the search of the bar (`TabRole.prominent` would take the search role away).
        #expect(!body.contains(".prominent"), "\(body)")
    }

    /// One switch, documented, with three values named for what the user gets; the field on the
    /// tab view that keeps the search by default. Each of the other two is the same one line.
    @Test func oneSwitchNamesThreePlacementsByWhatTheyDo() throws {
        let tabs = try Self.body(["struct MainTabs"], in: Self.root)
        let switchLine = "static let searchField: SearchInput.Placement = .tabViewKeepingSearch"
        #expect(tabs.contains(switchLine), "\(tabs)")
        let raw = try AppSource.read(Self.root)
        #expect(raw.components(separatedBy: "static let searchField").count - 1 == 1)
        // Its comment says what each value does: where the keyboard comes, and what stays.
        let comment = try Self.docComment(above: switchLine, in: Self.root)
        for word in ["`.tabViewKeepingSearch`", "`.tabViewOpeningKeyboard`", "`.pageFocusingField`", "iOS 27.2",
                     "starting points", "tapped", "every time", "tab before", "empties"] {
            #expect(comment.contains(word), "the switch's comment does not say \(word): \(comment)")
        }
        let placement = Self.squeezed(try Self.body(["final class SearchInput", "enum Placement"], in: Self.search))
        #expect(placement == "{casetabViewKeepingSearchcasetabViewOpeningKeyboardcasepageFocusingField"
                + "varhost:Host{self==.pageFocusingField?.page:.tabView}}", "\(placement)")
        let host = try Self.body(["final class SearchInput", "enum Host"], in: Self.search)
        #expect(Self.squeezed(host) == "{casetabViewcasepage}", "\(host)")
    }

    /// The field where the switch says, with the behaviour its name says, never twice:
    /// - keeping the search: only the field, which the system activates when it is tapped; no
    ///   activation by the tab, no focus by hand (iOS 26 shows the field in the bar, and the
    ///   starting points are the empty page's);
    /// - opening the keyboard: the tab's selection activates the field (`.searchTabSelection`);
    /// - on the page: the page's own field as until wave 3, focused while nothing is typed.
    @Test func theFieldSitsAndBehavesAsTheSwitchSays() throws {
        let modifier = Self.squeezed(try Self.body(["private struct SearchFieldModifier", "func body(content: Content)"], in: Self.search))
        #expect(modifier == "{ifhost!=MainTabs.searchField.host{content}"
                + "elseifMainTabs.searchField==.tabViewKeepingSearch{\(Self.field).searchFocused($focused)"
                + ".onChange(of:focused){_,nowininput.isFocused=now}.onChange(of:input.isFocused){_,nowinif!now{focused=false}}}"
                + "elseifMainTabs.searchField==.tabViewOpeningKeyboard{\(Self.field).tabViewSearchActivation(.searchTabSelection)}"
                + "else{\(Self.field).onAppear{ifinput.text.isEmpty{input.isPresented=true}}}}", "\(modifier)")
        let type = Self.squeezed(try Self.body(["private struct SearchFieldModifier"], in: Self.search))
        #expect(type.contains("@Bindablevarinput:SearchInput"), "\(type)")
        #expect(type.contains("@FocusStateprivatevarfocused:Bool"), "\(type)")
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

    /// Round 1 said the activation by the tab does what the page did by hand. It does not, and the
    /// comments say what it does: the keyboard every time, and closing goes back and empties.
    @Test func theCommentsSayWhatEachPlacementDoes() throws {
        let raw = try AppSource.read(Self.search)
        let modifier = try #require(AppSource.body(of: ["private struct SearchFieldModifier", "func body(content: Content)"], in: raw))
        let keeping = try Self.comments(between: "== .tabViewKeepingSearch {", and: "== .tabViewOpeningKeyboard {", in: modifier)
        for word in ["tapped", "stays"] {
            #expect(keeping.contains(word), "the comment of the default does not say \(word): \(keeping)")
        }
        let opening = try Self.comments(between: "== .tabViewOpeningKeyboard {", and: "} else {", in: modifier)
        #expect(!opening.contains("did by hand"), "\(opening)")
        for word in ["every time", "tab before", "empties"] {
            #expect(opening.contains(word), "the comment beside the activation does not say \(word): \(opening)")
        }
        let header = try Self.docComment(above: "@Suite(\"Search tab", in: "Tests/AlbumistCoreTests/SearchTabSourceTests.swift")
        #expect(!header.contains("which does what the page did by hand"), "the header still says what round 1 said: \(header)")
        #expect(header.contains("empties"), "\(header)")
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
    /// tab changes (review S of H14, unsure 2), which does what the placement promises (review T2
    /// of round 2): by default (`.tabViewKeepingSearch`) only the keyboard goes, through the
    /// field's focus bound with `.searchFocused`, and the query, the hits and the scroll position
    /// stay, as after a look at another tab; ending the search there emptied the field (Apple:
    /// dismissing a search clears its text). With the other two placements the search ends, so
    /// neither its field nor the keyboard stays up over "Vorschläge".
    @Test func aRouteLeavesTheSearchAsItsPlacementSays() throws {
        let body = Self.squeezed(try Self.body(["struct MainTabs", "var body: some View"], in: Self.root))
        let route = try #require(body.range(of: ".onChange(of:model.route,initial:true){_,targetin"), "\(body)")
        let rest = body[route.upperBound...]
        let leaves = try #require(rest.range(of: "iftab==.search{search.leftInCode()}"), "a route leaves an open search as it is: \(rest)")
        let chosen = try #require(rest.range(of: "tab=.suggestions"), "\(rest)")
        #expect(leaves.upperBound <= chosen.lowerBound, "the search is left after the tab changed")
        #expect(!body.contains("search.isPresented"), "the tabs end the search themselves, whatever the placement: \(body)")
        let input = try Self.body(["final class SearchInput"], in: Self.search)
        #expect(input.contains("    var isFocused = false\n"), "\(input)")
        let left = Self.squeezed(try Self.body(["final class SearchInput", "func leftInCode()"], in: Self.search))
        #expect(left == "{ifMainTabs.searchField==.tabViewKeepingSearch{isFocused=false}else{isPresented=false}}", "\(left)")
        // Its comment says what becomes of the query in each placement.
        let comment = try Self.docComment(above: "func leftInCode()", in: Self.search)
        for word in ["only the keyboard", "the query", "stay", "ends", "empties"] {
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

    /// One field for the search: `.searchable(` bound to `SearchInput` only in the modifier (once
    /// per placement), and `tabViewSearchActivation` once. Every other field of the app ("Album
    /// suchen", "Ort suchen") binds a text of its own view, never the tabs' search, so typing there
    /// never starts a search; and only the tabs and the search page know `SearchInput`.
    @Test func theOtherFieldsSearchTheirOwnText() throws {
        var fields: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let code = try Self.code(path)
            let calls = Self.arguments(of: "searchable(", in: code)
            if path == Self.search {
                #expect(calls == Array(repeating: "text: $input.text, isPresented: $input.isPresented, prompt: SearchView.prompt", count: 3), "\(calls)")
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
