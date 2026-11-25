import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The sorting show's words as the App says them (DS-17, verification review V8): the line under
/// the count and the show's VoiceOver value as the catalog writes them, with the photos grouped
/// as the language writes them, and UI test 2 reading them exactly. The App does not build on
/// Linux, so these tests read its code (`AppSource`), as `SortingShowSourceTests` does, whose
/// helpers they use.
@Suite("Sorting show's words in the App (DS-17)")
struct SortingShowWordsSourceTests {
    static let show = SortingShowSourceTests.show

    /// A language the words are read in, with what the show says there.
    struct Language {
        var code: String
        var locale: Locale
        var words: [String]
    }

    static func code(_ path: String) throws -> String {
        try SortingShowSourceTests.code(path)
    }

    static func body(_ path: [String], in file: String) throws -> String {
        try SortingShowSourceTests.body(path, in: file)
    }

    static func count(_ text: String, in code: String) -> Int {
        SortingShowSourceTests.count(text, in: code)
    }

    /// The catalog's text of `key` in `language`, filled as iOS fills it: each `%#@name@` by the
    /// plural form its argument's count picks (German and English: "one" for 1 only) with `%arg`
    /// as that count, then every `%N$lld` and `%N$@` by its argument.
    static func filled(_ key: String, _ language: String, _ arguments: [Any]) throws -> String {
        let entry = try #require(try StringCatalogTests.catalog()[key], "\(key) is not in the catalog")
        let localization = try #require(StringCatalogTests.localization(entry, language), "\(key) has no \(language)")
        var text = try #require((localization["stringUnit"] as? [String: Any])?["value"] as? String, "\(key) \(language)")
        for (name, substitution) in localization["substitutions"] as? [String: [String: Any]] ?? [:] {
            let place = try #require(substitution["argNum"] as? Int, "\(key) \(language): \(name)")
            let count = try #require(arguments[place - 1] as? Int, "\(key) \(language): \(name) counts by argument \(place)")
            let plural = try #require((substitution["variations"] as? [String: Any])?["plural"] as? [String: Any])
            let form = try #require(((plural[count == 1 ? "one" : "other"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String)
            text = text.replacingOccurrences(of: "%#@\(name)@", with: form.replacingOccurrences(of: "%arg", with: "\(count)"))
        }
        for (index, argument) in arguments.enumerated() {
            for specifier in ["lld", "@"] {
                text = text.replacingOccurrences(of: "%\(index + 1)$\(specifier)", with: "\(argument)")
            }
        }
        return text
    }

    /// The line under the count and the show's VoiceOver value read as the catalog writes them,
    /// with their photos grouped as the language writes them: "1.234 Fotos einsortiert", "3 of
    /// 12 albums done, 1,234 photos sorted" (the UI test's two photos cannot show the grouping).
    /// The App takes the grouped number from the core (`SortingShowWords.number`), of the same
    /// count as the plural form and in the screen's locale; no other number is formatted there.
    @Test func theCountReadsAsTheCatalogWritesIt() throws {
        let line = "%lld %@ Fotos einsortiert", value = "%lld von %lld Alben fertig, %lld %@ Fotos einsortiert"
        let languages = [
            Language(code: "de", locale: Locale(identifier: "de_DE"),
                     words: ["1.234 Fotos einsortiert", "1 Foto einsortiert",
                             "3 von 12 Alben fertig, 1.234 Fotos einsortiert",
                             "0 von 1 Album fertig, 0 Fotos einsortiert",
                             "1 von 1 Album fertig, 2 Fotos einsortiert"]),
            Language(code: "en", locale: Locale(identifier: "en_US"),
                     words: ["1,234 photos sorted", "1 photo sorted",
                             "3 of 12 albums done, 1,234 photos sorted",
                             "0 of 1 album done, 0 photos sorted",
                             "1 of 1 album done, 2 photos sorted"]),
        ]
        for each in languages {
            let language = each.code, locale = each.locale, words = each.words
            func number(_ count: Int) -> String { SortingShowWords.number(count, locale: locale) }
            #expect(try Self.filled(line, language, [1_234, number(1_234)]) == words[0])
            #expect(try Self.filled(line, language, [1, number(1)]) == words[1])
            #expect(try Self.filled(value, language, [3, 12, 1_234, number(1_234)]) == words[2])
            // What UI test 2 reads while its album of two photos waits, and once it landed.
            #expect(try Self.filled(value, language, [0, 1, 0, number(0)]) == words[3])
            #expect(try Self.filled(value, language, [1, 1, 2, number(2)]) == words[4])
        }
        let show = try Self.code(Self.show)
        #expect(show.contains("@Environment(\\.locale) private var locale"), "the show does not know the screen's locale")
        let header = try Self.body(["struct SortingShow", "var header: some View"], in: show)
        for text in ["Text(\"\\(totalPhotos) \\(SortingShowWords.number(totalPhotos, locale: locale)) Fotos einsortiert\")",
                     "Text(\"\\(counted) \\(SortingShowWords.number(counted, locale: locale)) Fotos einsortiert\")",
                     ".accessibilityValue(spokenProgress)"] {
            #expect(header.contains(text), "missing: \(text)")
        }
        #expect(!header.contains(".formatted("), "the header formats a number of its own: \(header)")
        let spoken = try Self.body(["struct SortingShow", "private var spokenProgress: Text"], in: show)
        #expect(spoken.contains("Text(\"\\(landed.count) von \\(albums.count) Alben fertig, \\(counted) "
                                    + "\\(SortingShowWords.number(counted, locale: locale)) Fotos einsortiert\")"), "\(spoken)")
        #expect(!spoken.contains(".formatted("), "the spoken value formats a number of its own: \(spoken)")
    }

    /// UI test 2 reads the show's exact words: its value ends in ", 0 Fotos einsortiert" while
    /// the album waits and in ", 2 Fotos einsortiert" once it landed with its two photos, and a
    /// test whose looks all missed the landing fails. The landing is there for half a second
    /// before the show hands over, and XCTest's reads took 5 to 7 s each in busy runs: the test
    /// lets the show hold its end (`-AlbumistUITestShowHold`, 15 s), a switch inert outside UI
    /// runs (`flag`, see `FirstAnalysisMomentSourceTests`) that only the show reads.
    @Test func theUITestReadsTheShowsExactWords() throws {
        let test = AppSource.code(try AppSource.read("App/AlbumistUITests/ShowAndHandwritingUITests.swift"), keepStrings: true)
        let body = try Self.body(["final class ShowAndHandwritingUITests", "func test2_SortingShowCountsThePhotosItSorts()"], in: test)
        #expect(body.contains("prepare(\"show\", [\"-AlbumistUITestSlowPlan\", \"-AlbumistUITestShowHold\"])"), "\(body)")
        let waiting = try #require(body.range(of: "XCTAssertTrue(value.hasSuffix(\", 0 Fotos einsortiert\")"), "no exact end while the album waits: \(body)")
        let landed = try #require(body.range(of: "XCTAssertTrue(landed.hasSuffix(\", 2 Fotos einsortiert\")"), "no exact end once it landed: \(body)")
        #expect(waiting.upperBound < landed.lowerBound)
        #expect(body.contains("XCTFail(\"The show ended before a look saw its album land"), "a missed landing passes: \(body)")
        #expect(!test.contains("sortedPhotos"), "the UI test still claims grouped digits its two photos cannot show")
        let switches = try Self.code("App/Albumist/Platform/UITestSwitches.swift")
        #expect(switches.contains("static let holdsShowEnd = flag(\"-AlbumistUITestShowHold\")"), "no switch that holds the show's end")
        let show = try Self.code(Self.show)
        let run = try Self.body(["extension SortingShow", "private func run() async"], in: show)
        #expect(run.contains("try? await Task.sleep(for: .seconds(UITestSupport.holdsShowEnd ? 15 : 0.5))"), "\(run)")
        var readers: [String: Int] = [:]
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let count = Self.count("UITestSupport.holdsShowEnd", in: try Self.code(path))
            if count > 0 { readers[path] = count }
        }
        #expect(readers == [Self.show: 1], "\(readers)")
    }
}
