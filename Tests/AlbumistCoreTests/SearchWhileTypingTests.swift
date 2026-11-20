import Foundation
import Testing
@testable import AlbumistCore

/// One answer for the word being typed: never "nicht erkannt" beside its completion (P3-13 / G3-06).
/// The search page showed the completion "Italien 29" for "Ital" and, right below it, "Suchbegriff
/// nicht erkannt" with the word struck through. A word the completions continue is still being
/// typed and is not reported as not recognised; a word nothing continues still is.
@Suite("Search while typing")
struct SearchWhileTypingTests {
    static let index = SearchQuerySetTests.index

    /// What the page shows for `text`: the result beside the completions for the same text.
    static func shown(_ text: String) -> (result: SearchResult, completions: [SearchSuggestion]) {
        let completions = index.suggestions(for: text)
        return (index.search(text, now: SearchLab.now).beside(completions, for: text), completions)
    }

    static func notRecognized(_ result: SearchResult) -> [String] {
        result.tokens.filter { $0.kind == .ignored }.map(\.label)
    }

    @Test func aWordTheCompletionContinuesIsNotReportedAsNotRecognized() {
        let (result, completions) = Self.shown("Ital")
        #expect(completions.contains { $0.label == "Italien" && $0.count > 0 })
        #expect(Self.notRecognized(result).isEmpty, "chips: \(result.tokens.map(\.label))")
        #expect(result.emptyState == nil, "\(String(describing: result.emptyState))")
        #expect(result.typing == ["Ital"])
    }

    @Test func wordsBeforeTheLastThatTheCompletionReplacesAreNotReportedEither() {
        // "New Yo" becomes "New York": both words are on their way to the name.
        let (result, completions) = Self.shown("New Yo")
        #expect(completions.contains { $0.completion == "New York" })
        #expect(Self.notRecognized(result).isEmpty, "chips: \(result.tokens.map(\.label))")
        #expect(result.emptyState == nil)
    }

    @Test func theOtherTermsStayAsTheyWere() {
        // "Hund Ital": the dogs are found and counted, the word being typed is no chip.
        let dogs = Self.index.search("Hund", now: SearchLab.now)
        let (result, completions) = Self.shown("Hund Ital")
        #expect(completions.first?.completion == "Hund Italien")
        #expect(result.tokens.map(\.label) == dogs.tokens.map(\.label))
        #expect(result.tokens.map(\.count) == dogs.tokens.map(\.count))
        #expect(result.ids == dogs.ids)
        #expect(result.emptyState == nil)
        // A word typed before that nothing continues is still not recognised, and said so.
        let (mixed, _) = Self.shown("xyzzy Ital")
        #expect(Self.notRecognized(mixed) == ["xyzzy"])
        #expect(mixed.emptyState == .notRecognized)
    }

    @Test func aWordNothingContinuesIsReportedAsBefore() {
        // Nothing in the library, a finished word (the space closes the completions), one letter.
        for text in ["xyzzy", "Japa", "Ital "] {
            let (result, completions) = Self.shown(text)
            #expect(completions.isEmpty, "\(text)")
            #expect(Self.notRecognized(result) == [text.trimmingCharacters(in: .whitespaces)], "\(text)")
            #expect(result.emptyState == .notRecognized, "\(text)")
            #expect(result.typing.isEmpty, "\(text)")
        }
        // Never an unexplained empty page: a single letter is still "Suchbegriff nicht erkannt".
        #expect(Self.shown("I").result.emptyState == .notRecognized)
        // A term without photos is named, not hidden behind the word being typed.
        let (japan, _) = Self.shown("Japan Ital")
        #expect(japan.emptyState == .noPhotos(japan.tokens[0]))
        #expect(japan.tokens.map(\.label) == ["Japan"])
    }

    @Test func typingAnyNameTheLibraryOffersNeverSaysNotRecognizedBesideACompletion() {
        // Every name the library offers, typed letter by letter as a person types it. Whenever
        // completions stand above the results, the word being typed (which every completion
        // continues) is not reported as not recognised; while the name itself is offered, nothing
        // on the page says "nicht erkannt". Chosen, every name is understood and finds photos.
        var contradictions: [String] = []
        var notUnderstood: [String] = []
        var steps = 0, offered = 0
        for candidate in Self.index.suggestionPool {
            for name in Set([candidate.german, candidate.english]) {
                var text = ""
                for letter in name {
                    text.append(letter)
                    let (result, completions) = Self.shown(text)
                    guard !completions.isEmpty else { continue }
                    steps += 1
                    let reported = Self.notRecognized(result)
                    let typing = QueryParser.tokenize(String(text.split(whereSeparator: \.isWhitespace).last ?? "")).map(\.typed)
                    if reported.contains(where: typing.contains) {
                        contradictions.append("\(text) → \(reported) beside \(completions.prefix(2).map(\.label))")
                    }
                    guard completions.contains(where: { $0.label == candidate.german || $0.label == candidate.english }) else { continue }
                    offered += 1
                    if !reported.isEmpty || result.emptyState == .notRecognized {
                        contradictions.append("\(text) → \(reported), \(String(describing: result.emptyState)) beside \(name)")
                    }
                }
                let chosen = Self.shown(name + " ").result
                if !Self.notRecognized(chosen).isEmpty || chosen.ids.isEmpty { notUnderstood.append(name) }
            }
        }
        #expect(steps > 300 && offered > 300, "\(steps) steps, \(offered) with the name offered")
        #expect(contradictions.isEmpty, "\(contradictions.count) of \(steps): \(contradictions.prefix(12))")
        #expect(notUnderstood.isEmpty, "\(notUnderstood)")
    }
}
