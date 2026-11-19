import Foundation
import Testing
import SortlyTestSupport

/// The App's code as the source tests read it (`AppSource`, re-review of 7e8aba3): a brace in a
/// comment or a string never ends a body early, and a line left only in a comment or a string
/// never passes for code.
@Suite("App source reading")
struct AppSourceTests {
    static let sample = #"""
    struct Card {
        // A brace in a comment: }
        /* and in a block comment: } /* nested } */ still a comment } */
        func start() {
            let text = "a brace in a string: }"
            let more = """
                multiline }
                """
            let raw = #"raw } with \(not interpolated) and "quotes" }"#
            let says = "with \(name(of: "inner }")) interpolated"
            // startAnalysis(cause: .tap)
            startAnalysis()
            let note = "startAnalysis(cause: .userChange)"
            restartAnalysis(cause: .tap)
        }

        func after() { startAnalysis(cause: .tap) }
    }
    """#

    @Test func bracesInCommentsAndStringsDoNotEndABody() throws {
        let body = try #require(AppSource.body(of: "func start(", in: Self.sample))
        let wholeBody = body.contains("restartAnalysis(cause: .tap)") && !body.contains("func after(")
        #expect(wholeBody, "the body ended at a brace in a comment or a string: \(body)")
        let card = try #require(AppSource.body(of: ["struct Card", "func after("], in: Self.sample))
        #expect(card == "{ startAnalysis(cause: .tap) }")
    }

    @Test func callsInCommentsAndStringsAreNoCalls() {
        let start = AppSource.body(of: "func start(", in: Self.sample) ?? ""
        #expect(AppSource.calls(of: "startAnalysis(", in: start) == [""])
        #expect(AppSource.calls(of: "startAnalysis(", in: Self.sample) == ["", "cause: .tap"])
    }

    @Test func codeBlanksCommentsAndStringsInPlace() {
        let code = AppSource.code(Self.sample)
        #expect(code.unicodeScalars.count == Self.sample.unicodeScalars.count)
        #expect(code.split(separator: "\n", omittingEmptySubsequences: false).count
                == Self.sample.split(separator: "\n", omittingEmptySubsequences: false).count)
        let leftInText = code.contains("brace") || code.contains("multiline") || code.contains("quotes") || code.contains("cause: .userChange")
            || code.contains("// startAnalysis")
        #expect(!leftInText, "a comment or a string was left in the code")
        // The code inside an interpolation stays code.
        #expect(code.contains("name(of:"))
        let kept = AppSource.code(Self.sample, keepStrings: true)
        let stringsKept = kept.contains("\"a brace in a string: }\"") && !kept.contains("A brace in a comment")
        #expect(stringsKept, "keepStrings did not keep the strings or kept the comments")
    }

    /// A default argument with a closure is not the body (`changeHome(home: … = { $0 }`).
    @Test func aClosureInTheParametersIsNotTheBody() {
        let source = """
        private func changeHome(home: (Int) -> Int = { $0 },
                                places: (Int) -> Int = { $0 }) async -> Bool {
            startAnalysis(cause: queued.cause)
        }
        """
        let body = AppSource.body(of: "func changeHome(", in: source)
        #expect(body?.contains("startAnalysis(cause: queued.cause)") == true, "the default argument was taken for the body")
    }

    /// A declaration named only in a comment or a string is not found there.
    @Test func aDeclarationInACommentIsNotTheDeclaration() {
        let source = """
        // func changeTrips() { startAnalysis(cause: .userChange) }
        let s = "func changeTrips() { }"
        func changeTrips() { startAnalysis() }
        """
        #expect(AppSource.body(of: "func changeTrips(", in: source) == "{ startAnalysis() }")
    }
}
