import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// What review B of design wave 1 found around "Anlegen" on a card (decision 7B), read in the
/// App's code: the App does not build on Linux. Each test was red on the code before its fix.
///
/// - Finding 1: "Album anlegen" on a suggestion opened in a sheet over the tabs (a photo's
///   "Info") made its album at once, but the banner with "Widerrufen", the purchase sheet and
///   the messages show only on the tabs, under that sheet.
@Suite("Quick create: where and when it may make an album")
struct QuickCreateSafeguardTests {
    static let navigation = "App/Sortly/Views/Navigation.swift"
    static let tabs = "App/Sortly/Views/RootView.swift"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path))
    }

    static func body(_ declaration: String, in path: String) throws -> String {
        let code = try code(path)
        return try #require(AppSource.body(of: declaration, in: code), "\(declaration) is not in \(path)")
    }

    // MARK: Finding 1: only where the banner shows

    /// Every stack says whether "Anlegen" may make an album at once on it, false unless it is
    /// told otherwise: a sheet's or a cover's own stack over a tab sets false for itself, where
    /// it would otherwise inherit the tab's true.
    @Test func everyStackSaysWhetherItMakesAtOnce() throws {
        let root = try Self.body("struct NavigationRoot<", in: Self.navigation)
        #expect(root.contains("quickCreate: Bool = false"), "NavigationRoot has no quickCreate parameter that defaults to false")
        #expect(root.contains(".environment(\\.quickCreateAtOnce, quickCreate)"), "NavigationRoot does not set quickCreateAtOnce on its stack")
        // Set nowhere else: no screen turns it on for itself.
        for path in AppSource.swiftFiles(under: "App/Sortly") where path != Self.navigation {
            #expect(!(try Self.code(path)).contains(".environment(\\.quickCreateAtOnce"), "\(path) sets quickCreateAtOnce")
        }
    }

    /// The four tabs make albums at once, and each shows the banner; no other stack does.
    @Test func onlyTheTabsMakeAtOnceAndEachShowsTheBanner() throws {
        let tabs = try Self.body("struct MainTabs", in: Self.tabs)
        let roots = AppSource.calls(of: "NavigationRoot(", in: tabs)
        #expect(roots.count == 4, "\(roots)")
        #expect(roots.allSatisfy { $0.contains("quickCreate: true") }, "\(roots)")
        #expect(tabs.firstMatch(of: /NavigationRoot\s*\{/) == nil, "a tab's stack without quickCreate: true")
        #expect(tabs.components(separatedBy: ".showsQuickCreateBanner()").count - 1 == 4)
        for path in AppSource.swiftFiles(under: "App/Sortly") where path != Self.tabs {
            #expect(!(try Self.code(path)).contains("quickCreate: true"), "\(path) makes albums at once on a stack without the banner")
        }
    }

    /// Every "Anlegen" asks first whether its stack makes albums at once. If not, the
    /// suggestion's page opens (a card), or its preview (the page's "Album anlegen"), as before
    /// wave 1, all on the stack the user is on.
    @Test func everyAnlegenAsksFirst() throws {
        var calls = 0
        for path in AppSource.swiftFiles(under: "App/Sortly/Views") {
            let code = try Self.code(path)
            let sites = AppSource.callSites(of: "createNow(", in: code)
            guard !sites.isEmpty else { continue }
            #expect(code.contains("@Environment(\\.quickCreateAtOnce) private var quickCreateAtOnce"), "\(path)")
            let scalars = Array(code.unicodeScalars)
            for site in sites {
                calls += 1
                let before = String(String.UnicodeScalarView(scalars[..<site.offset]))
                // The function the call is in, up to the call.
                let function = try #require(before.range(of: "func ", options: .backwards), "\(path): a call outside a function")
                let upToCall = before[function.lowerBound...]
                guard let asks = upToCall.range(of: "guard quickCreateAtOnce", options: .backwards) else {
                    Issue.record("\(path): createNow without asking whether the banner shows on this stack")
                    continue
                }
                let otherwise = upToCall[asks.lowerBound...]
                #expect(otherwise.contains("await applyNow()") || otherwise.contains("open(proposal)"),
                        "\(path): not the suggestion's page or its preview where nothing is made at once")
            }
        }
        #expect(calls == 3, "the start page, the list and the suggestion's page")
    }
}
