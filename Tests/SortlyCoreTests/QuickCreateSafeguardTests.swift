import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// What review B of design wave 1 found around "Anlegen" on a card (decision 7B). The memory of
/// "Nicht jetzt" is core and tested as such; the rest is read in the App's code, as the App does
/// not build on Linux. Each test was red on the code before its fix.
///
/// - Finding 1: "Album anlegen" on a suggestion opened in a sheet over the tabs (a photo's
///   "Info") made its album at once, but the banner with "Widerrufen", the purchase sheet and
///   the messages show only on the tabs, under that sheet.
/// - Findings 4 and 9: "Anlegen" on a card under "Nicht jetzt" kept the stored rejection, and
///   "Widerrufen" did not set the suggestion aside again; the card jumped to its area's section
///   the moment it was tapped.
/// - Finding 10: after the purchase sheet, the album was made from the sheet's copy of a
///   suggestion the analysis no longer had.
/// - Finding 11: "Widerrufen" did not hold the turn while it checked whether the album is deleted,
///   and an "Anlegen" meanwhile ended the undo without a word.
@Suite("Quick create: where and when it may make an album")
struct QuickCreateSafeguardTests {
    static let model = "App/Sortly/Model/AppModel+QuickCreate.swift"
    static let appModel = "App/Sortly/Model/AppModel.swift"
    static let navigation = "App/Sortly/Views/Navigation.swift"
    static let tabs = "App/Sortly/Views/RootView.swift"
    static let list = "App/Sortly/Views/ProposalViews.swift"

    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path))
    }

    static func body(_ declaration: String, in path: String) throws -> String {
        let code = try code(path)
        return try #require(AppSource.body(of: declaration, in: code), "\(declaration) is not in \(path)")
    }

    /// The text of `code` from `first` to `second` (both must be there, in this order).
    static func between(_ first: String, _ second: String, in code: String) throws -> Substring {
        let start = try #require(code.range(of: first), "missing: \(first)")
        let end = try #require(code.range(of: second, range: start.upperBound..<code.endIndex), "missing after \(first): \(second)")
        return code[start.lowerBound..<end.upperBound]
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

    // MARK: Findings 4 and 9: a card under "Nicht jetzt"

    static let rome = AlbumProposal(id: SortlyID("rome"), kind: .trip, title: "Rom, Mai 2024", folderPath: ["Reisen"],
                                    assetIDs: ["r1", "r2", "r3"])
    static let oslo = AlbumProposal(id: SortlyID("oslo"), kind: .trip, title: "Oslo, Juni 2024", folderPath: ["Reisen"],
                                    assetIDs: ["o1", "o2"])

    /// A card made from "Nicht jetzt" is remembered from the tap until its banner ends: its card
    /// stays there meanwhile, and a completed "Widerrufen" gets the suggestion back, once, to set
    /// it aside again. An open suggestion is never remembered.
    @Test func aCardFromNichtJetztIsRememberedWhileItsBannerShows() {
        var memory = QuickCreateSetAside()
        memory.begin(Self.oslo, setAside: false)
        #expect(!memory.contains(Self.oslo.id), "an open suggestion is no card under \"Nicht jetzt\"")
        memory.begin(Self.rome, setAside: true)
        #expect(memory.contains(Self.rome.id), "while its album is made")
        memory.bannerShown(for: Self.rome.id)
        #expect(memory.contains(Self.rome.id), "while its banner shows")
        #expect(memory.undone(Self.rome.id) == Self.rome)
        #expect(!memory.contains(Self.rome.id))
        #expect(memory.undone(Self.rome.id) == nil, "set aside again only once")
    }

    /// Nothing made, or a banner that went by itself (the album stays, and the lifted rejection
    /// with it): forgotten, the card follows its decision again.
    @Test func whatIsNotMadeOrStaysIsForgotten() {
        var memory = QuickCreateSetAside()
        memory.begin(Self.rome, setAside: true)
        memory.notMade(Self.rome.id)
        #expect(!memory.contains(Self.rome.id))
        memory.begin(Self.rome, setAside: true)
        memory.bannerShown(for: Self.rome.id)
        memory.bannerGone(for: Self.rome.id)
        #expect(!memory.contains(Self.rome.id))
        #expect(memory.undone(Self.rome.id) == nil, "no \"Widerrufen\" without its banner")
        // Tapped on an open card later: not set aside any more.
        memory.begin(Self.rome, setAside: true)
        memory.begin(Self.rome, setAside: false)
        #expect(!memory.contains(Self.rome.id))
    }

    /// A banner ends only its own memory, never that of a card being made meanwhile; a newer
    /// banner replaces the older one, whose "Widerrufen" is gone with it.
    @Test func aNewerBannerEndsTheOlderOnes() {
        var memory = QuickCreateSetAside()
        memory.begin(Self.rome, setAside: true)
        memory.bannerShown(for: Self.rome.id)
        memory.begin(Self.oslo, setAside: true)
        #expect(memory.contains(Self.rome.id) && memory.contains(Self.oslo.id))
        memory.bannerGone(for: Self.rome.id)
        #expect(!memory.contains(Self.rome.id) && memory.contains(Self.oslo.id), "Oslo is still being made")

        memory = QuickCreateSetAside()
        memory.begin(Self.rome, setAside: true)
        memory.bannerShown(for: Self.rome.id)
        memory.begin(Self.oslo, setAside: true)
        memory.bannerShown(for: Self.oslo.id)
        #expect(!memory.contains(Self.rome.id) && memory.contains(Self.oslo.id))
        #expect(memory.undone(Self.rome.id) == nil)
    }

    /// The model's stored "Nicht jetzt" can be lifted from the quick create file
    /// (`removeRejection` was private to `AppModel.swift`).
    @Test func theStoredRejectionCanBeLifted() throws {
        let code = try Self.code(Self.appModel)
        #expect(!code.contains("private func removeRejection("))
        #expect(code.contains("func removeRejection(of sources: Set<SortlyID>?) async"))
    }

    /// "Anlegen" notes whether the suggestion was set aside before its pick took the decision's
    /// place, and forgets it whenever nothing was made. Once the album is made, the stored
    /// rejection is lifted before the banner shows, so "Widerrufen" never runs ahead of it.
    @Test func anlegenRemembersNichtJetzt() throws {
        let create = try Self.body("func createNow(", in: Self.model)
        let noted = try #require(create.range(of: "let setAside = chosen == .reject"), "the decision before the pick is not noted")
        let remembered = try #require(create.range(of: "state.setAside.begin(proposal, setAside: setAside)"))
        let picked = try #require(create.range(of: "selectForPreview("))
        #expect(noted.lowerBound < picked.lowerBound && remembered.lowerBound < picked.lowerBound,
                "noted after the pick took the decision's place")
        #expect(create.contains("if !created { state.setAside.notMade(proposal.id) }"), "kept in \"Nicht jetzt\" although nothing was made")
        #expect(create.contains("created = outcome == .created"))
        #expect(create.contains("finishQuickCreate(made, proposal: proposal, setAside: setAside)"))
        let finish = try Self.body("private func finishQuickCreate(", in: Self.model)
        let ended = try #require(finish.range(of: "QuickCreate.ending(of: finished)"))
        let lifted = try #require(finish.range(of: "if setAside { await removeRejection(of: [proposal.id]) }"),
                                  "the stored rejection stays")
        let shown = try #require(finish.range(of: "showQuickCreateBanner("))
        #expect(ended.lowerBound < lifted.lowerBound, "lifted before the album is in Photos")
        #expect(lifted.lowerBound < shown.lowerBound, "lifted after the banner shows: \"Widerrufen\" can run ahead of it")
    }

    /// The banner keeps the memory: a newer banner ends the older ones', a banner that goes by
    /// itself ends its own, and a completed "Widerrufen" sets the suggestion aside again.
    @Test func widerrufenSetsItAsideAgain() throws {
        let shown = try Self.body("private func showQuickCreateBanner(", in: Self.model)
        #expect(shown.contains("setAside.bannerShown(for: banner.proposalID)"))
        let expiry = try Self.body("private func expireQuickCreateBanner(", in: Self.model)
        #expect(expiry.contains("setAside.bannerGone(for:"))
        let undo = try Self.body("func undoQuickCreate(", in: Self.model)
        let completed = try Self.between("if undonePlans.contains(banner.plan.id)", "} else {", in: undo)
        #expect(completed.contains("if let setAside = state.setAside.undone(banner.proposalID)"))
        #expect(completed.contains("setDecision(.reject, for: setAside)"))
    }

    /// The list keeps such a card in "Nicht jetzt" while its album is made and while its banner
    /// shows, instead of following the pick to its area: one memory for the list and for
    /// "Widerrufen".
    @Test func theCardStaysInNichtJetzt() throws {
        let sections = try Self.body("private func sections(of all: [AlbumProposal])", in: Self.list)
        #expect(sections.contains("model.quickCreateKeepsNotNow("), "the sections follow the decisions only")
        #expect(!sections.contains("all.filter { model.decisions[$0.id] != .reject }"))
        let model = try Self.code(Self.model)
        #expect(model.contains("func quickCreateKeepsNotNow(_ id: SortlyID) -> Bool"))
        #expect(model.contains("var setAside = QuickCreateSetAside()"))
    }

    // MARK: Finding 10: after the purchase sheet

    /// After the purchase, only a suggestion the analysis still has is made. A gone one is said,
    /// never made from a copy: the sheet keeps the suggestion's id only.
    @Test func afterThePurchaseOnlyACurrentSuggestionIsMade() throws {
        let after = try Self.body("func continueQuickCreate(after purchase: QuickCreatePurchase)", in: Self.model)
        #expect(!after.contains("purchase.proposal"), "made from the sheet's copy")
        let gone = try Self.between("guard let current = proposals.first(where: { $0.id == purchase.id }) else {", "return", in: after)
        #expect(gone.contains("message = "), "a gone suggestion is not said")
        #expect(after.contains("await createNow(current)"))
        let request = try Self.body("struct QuickCreatePurchase", in: Self.model)
        #expect(!request.contains("AlbumProposal"), "the purchase sheet keeps a copy of the suggestion")
    }

    // MARK: Finding 11: "Widerrufen" holds the turn

    /// While a banner checks or takes back its album, "Anlegen" is refused as busy, before it
    /// takes the turn; an undo whose banner went meanwhile says so instead of ending silently.
    @Test func widerrufenHoldsTheTurn() throws {
        let create = try Self.body("func createNow(", in: Self.model)
        let refused = try Self.between("if let banner = state.banner, !banner.canUndo {", "return .notNow", in: create)
        #expect(refused.contains("message = .busy"))
        let taken = try #require(create.range(of: "state.creating = proposal.id"))
        #expect(refused.endIndex <= taken.lowerBound, "refused only after taking the turn")
        let undo = try Self.body("func undoQuickCreate(", in: Self.model)
        let replaced = try Self.between("guard state.banner?.id == banner.id else {", "return", in: undo)
        #expect(replaced.contains("message = .busy"), "the undo ends without a word")
    }
}
