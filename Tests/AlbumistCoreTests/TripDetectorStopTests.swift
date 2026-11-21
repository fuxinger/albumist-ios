import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Review P4-07, second review: a Pause in the trips step waited for the whole trip detection
/// (6.3 s over 100,000 photos). `analyse` and `detectedHome` take a stop hook now and ask it
/// inside their work; never stopped, they find exactly what they found before.
@Suite("Trip detection stops when asked, and only then")
struct TripDetectorStopTests {
    /// Home with day trips, two trips abroad, photos without a location, a place the user is
    /// often at (Tegernsee, so `placesOftenVisited` runs), a split and a photo taken out.
    static func library() -> (assets: [AssetSnapshot], corrections: TripCorrections, places: RecurringPlaceAnswers) {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2026-06-30", at: Fixture.Places.munichHome, perDay: 3,
                  skipping: [("2025-05-10", "2025-05-20"), ("2025-09-01", "2025-09-10")])
        lib.daily(from: "2025-05-10", to: "2025-05-20", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let florence = lib.daily(from: "2025-09-01", to: "2025-09-10", at: Fixture.Places.florence, perDay: 6, hour: 10)
        lib.daily(from: "2025-03-01", to: "2026-03-01", at: Fixture.Places.tegernsee, perDay: 2, everyNthDay: 14, hour: 15)
        lib.daily(from: "2025-05-11", to: "2025-05-18", at: nil, perDay: 2, hour: 18)
        var corrections = TripCorrections()
        corrections.forcedBreaks = [Fixture.date("2025-09-05 00:00")]
        corrections.excludedAssets = [florence[0]]
        let places = RecurringPlaceAnswers().answering(true, at: Fixture.Places.tegernsee, name: "Tegernsee", date: Fixture.date("2025-06-01"))
        return (lib.assets, corrections, places)
    }

    static func same(_ a: TripAnalysis, _ b: TripAnalysis) -> Bool {
        a.trips == b.trips && a.stays == b.stays && a.places == b.places && a.atHome == b.atHome && a.detectedHome == b.detectedHome
    }

    /// A hook that never says stop changes nothing: same trips, stays, places, home photos and
    /// home, with and without corrections and answers, and the same counts said.
    @Test func neverStoppedTheResultIsTheSame() throws {
        let (assets, corrections, places) = Self.library()
        let detector = TripDetector(calendar: Fixture.calendar)
        for (c, p) in [(TripCorrections(), RecurringPlaceAnswers()), (corrections, places)] {
            var said: [[Int]] = [], saidWithHook: [[Int]] = []
            let plain = detector.analyse(in: assets, corrections: c, places: p, progress: { said.append([$0, $1]) })
            let hooked = try detector.analyse(in: assets, corrections: c, places: p, progress: { saidWithHook.append([$0, $1]) },
                                              stoppingWhen: { false })
            #expect(!plain.trips.isEmpty && !plain.atHome.isEmpty && plain.detectedHome != nil)
            #expect(Self.same(plain, hooked))
            #expect(said == saidWithHook && said.count > 2, "\(said)")
            #expect(try detector.detectedHome(in: assets, corrections: c, places: p, stoppingWhen: { false })
                    == detector.detectedHome(in: assets, corrections: c, places: p))
        }
        #expect(!detector.analyse(in: assets, corrections: corrections, places: places).places.isEmpty)
    }

    /// Asked to stop in the middle of grouping the photos: gives up there, no further count is
    /// said, and the hook is not asked for every photo (once per `progressEvery`).
    @Test func stopInTheMiddleEndsThere() throws {
        let (assets, corrections, places) = Self.library()
        let detector = TripDetector(calendar: Fixture.calendar)
        var said: [Int] = []
        var asked = 0
        var stopAfter: Int?
        #expect(throws: CancellationError.self) {
            _ = try detector.analyse(in: assets, corrections: corrections, places: places,
                                     progress: { grouped, _ in said.append(grouped); if grouped >= TripDetector.progressEvery { stopAfter = said.count } },
                                     stoppingWhen: { asked += 1; return stopAfter != nil })
        }
        #expect(said.last == TripDetector.progressEvery, "counts said after the stop: \(said)")
        #expect(asked <= 4, "asked \(asked) times")
    }

    /// Every place it asks can stop it: stopped at the n-th question, it throws and is asked no
    /// more; the number of questions without a stop is small (not one per photo).
    @Test func everyQuestionCanStopIt() throws {
        let (assets, corrections, places) = Self.library()
        let detector = TripDetector(calendar: Fixture.calendar)
        var questions = 0
        _ = try detector.analyse(in: assets, corrections: corrections, places: places, stoppingWhen: { questions += 1; return false })
        #expect(questions > 3 && questions < assets.count / 100, "\(questions) questions for \(assets.count) photos")
        for n in 1...questions {
            var asked = 0
            #expect(throws: CancellationError.self) {
                _ = try detector.analyse(in: assets, corrections: corrections, places: places, stoppingWhen: { asked += 1; return asked >= n })
            }
            #expect(asked == n)
        }
        var homeQuestions = 0
        _ = try detector.detectedHome(in: assets, stoppingWhen: { homeQuestions += 1; return false })
        for n in 1...homeQuestions {
            var asked = 0
            #expect(throws: CancellationError.self) {
                _ = try detector.detectedHome(in: assets, stoppingWhen: { asked += 1; return asked >= n })
            }
        }
    }
}
