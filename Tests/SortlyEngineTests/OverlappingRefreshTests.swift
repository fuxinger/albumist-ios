import Foundation
import Testing
@testable import SortlyEngine
import SortlyTestSupport

/// Reviews G4-03 and P4-10: `AppModel.refreshDerived` guarded only its last assignment with
/// `LatestCall`. The suggestions (`snapshot`), the facts, the inventory, the history and the
/// rest were assigned as each was read, so two overlapping calls that finished in swapped order
/// left an older call's suggestions or facts next to the newer call's states until the next
/// refresh. With a trip change in flight that was the old trip back in the list for a moment.
/// Now everything is read first and assigned together, only by the newest call.
@Suite("Overlapping refreshes: only the newest call assigns")
struct OverlappingRefreshTests {
    /// Everything the overview shows from a refresh.
    static let shown = ["snapshot", "recheckedSuggestions", "recurringPlaceReport", "detectedHome", "homeChangeNotice",
                        "facts", "previewRanksCache", "inventory", "mergeSuggestions", "historyHasMore", "history",
                        "undonePlans", "removedFromProposals"]

    /// The rule itself: of two overlapping calls only the newest one may assign, whichever ends last.
    @Test func onlyTheNewestCallAssigns() {
        var calls = LatestCall()
        let older = calls.begin()
        let newer = calls.begin()
        #expect(calls.isNewest(newer))
        #expect(!calls.isNewest(older), "an older call that ends last would put back its result")
    }

    /// The App assigns nothing it shows before the newest-call guard, and each of it after the
    /// guard (it does not build on Linux, so its code is read without comments and strings,
    /// `AppSource.code`). The reopenings after a recheck are decisions and stay before it.
    @Test func refreshDerivedAssignsOnlyAfterTheNewestCallGuard() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        let body = AppSource.code(try #require(AppSource.body(of: "func refreshDerived(", in: model)))
        let guardLine = "guard derivedCalls.isNewest(call), scope == analysisScope else { return }"
        let parts = body.components(separatedBy: guardLine)
        #expect(parts.count == 2, "refreshDerived has no single newest-call guard")
        guard parts.count == 2 else { return }
        func assigns(_ name: String, in text: String) throws -> Bool {
            let pattern = try Regex("(?m)^\\s*(self\\.)?\(name)\\s*=[^=]")
            return text.contains(pattern) || text.contains("{ self.\(name) = ") || text.contains("{ \(name) = ")
        }
        for name in Self.shown {
            let early = try assigns(name, in: parts[0])
            let late = try assigns(name, in: parts[1])
            #expect(!early, "refreshDerived assigns \(name) before it knows it is the newest call")
            #expect(late, "refreshDerived does not assign \(name) after the guard")
        }
        let reopensFirst = parts[0].contains("reopenAfterRecheck(refresh.reopened)")
        #expect(reopensFirst, "the reopenings after a recheck depend on the call being the newest")
    }
}
