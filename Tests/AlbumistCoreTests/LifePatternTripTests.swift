import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// "Was zählt alles als Reise? Was, wenn ich an einem anderen Ort arbeite, einen zweiten
/// Wohnsitz habe oder so etwas Ähnliches?" (Fuchs). For each way of life: which trips and which
/// place albums come out, before and after the user answers "Bist du hier öfter?".
@Suite("Life patterns: what counts as a trip")
struct LifePatternTripTests {
    let detector = TripDetector(calendar: Fixture.calendar)
    static let answeredAt = Fixture.date("2026-01-01")

    struct Outcome {
        var analysis: TripAnalysis
        var report: RecurringPlaceReport
        var proposals: [AlbumProposal]
        var tripOf: [AssetID: AlbumistID]

        var trips: [Trip] { analysis.trips }
        var questions: [RecurringPlaceCandidate] { report.candidates }
        /// Trip suggestions and the albums that gather several trips to one place.
        var tripAlbums: [AlbumProposal] { proposals.filter { $0.kind == .trip } }
        var tripPlaceAlbums: [AlbumProposal] {
            proposals.filter { if case .placeCollection = $0.kind { return $0.folderPath == ["Reisen"] } else { return false } }
        }
        /// The album of a place the user is often at.
        var placeAlbums: [AlbumProposal] { proposals.filter { $0.kind == .frequentPlace } }

        func question(on proposal: AlbumProposal) -> RecurringPlaceCandidate? {
            report.question(for: proposal) { tripOf[$0] }
        }
    }

    func outcome(_ library: LifePatterns.Library, answers: RecurringPlaceAnswers = .init()) -> Outcome {
        let analysis = detector.analyse(in: library.assets, places: answers)
        let report = RecurringPlaceReport(analysis, trips: analysis.trips, answers: answers)
        var tripOf: [AssetID: AlbumistID] = [:]
        for trip in analysis.trips { for id in trip.geotaggedAssetIDs { tripOf[id] = trip.id } }
        let facts = LifePatterns.facts(for: library.assets).map { f -> AssetFacts in
            var f = f
            f.tripID = tripOf[f.id]
            return f
        }
        var settings = OrganizationSettings()
        settings.titleLanguage = .german
        let proposals = ProposalEngine(settings: settings, calendar: Fixture.calendar)
            .proposals(for: AnalysisSnapshot(facts: facts, trips: analysis.trips, recurringPlaces: report.places))
        return Outcome(analysis: analysis, report: report, proposals: proposals, tripOf: tripOf)
    }

    /// The answer to the question about `candidate`, as the app stores it.
    func answer(_ oftenHere: Bool, _ candidate: RecurringPlaceCandidate) -> RecurringPlaceAnswers {
        RecurringPlaceAnswers().answering(oftenHere, at: candidate.center, name: nil, date: Self.answeredAt)
    }

    /// Every stay away is exactly one trip.
    func expectOneTripPerStay(_ outcome: Outcome, _ stays: [[AssetID]], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(outcome.trips.count == stays.count, sourceLocation: sourceLocation)
        #expect(Set(outcome.trips.map { Set($0.geotaggedAssetIDs) }) == Set(stays.map(Set.init)), sourceLocation: sourceLocation)
    }

    /// No suggestion calls a place anything the user did not say: no "Zuhause", no guess at
    /// what the place is to them.
    func expectNoLabels(_ outcome: Outcome, sourceLocation: SourceLocation = #_sourceLocation) {
        for p in outcome.proposals {
            for word in ["Zuhause", "Home", "Zweitwohnsitz", "Arbeit", "Familie", "Wohnort"] {
                #expect(!p.title.contains(word) && !p.folderPath.contains(where: { $0.contains(word) }), "\(p.title)", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: Second workplace

    /// Commuting 57 km to Augsburg with a photo there every few days is everyday life: no trip,
    /// nothing to ask (there is no trip the answer would change).
    @Test func dailyCommuterWithFewPhotosAtWork() {
        let library = LifePatterns.commuter()
        let o = outcome(library)
        #expect(o.trips.isEmpty)
        #expect(o.analysis.stays.count == library.stays.count)       // every workday photo is a stay away…
        #expect(o.analysis.stays.allSatisfy { $0.tripIndex == nil })  // …too small to be a trip
        #expect(o.questions.isEmpty)
        #expect(o.tripAlbums.isEmpty && o.tripPlaceAlbums.isEmpty && o.placeAlbums.isEmpty)
    }

    /// Photographing at work every day makes the workplace part of everyday life by itself.
    @Test func dailyCommuterPhotographingAtWork() {
        let o = outcome(LifePatterns.commuter(photographsAtWork: true))
        #expect(o.trips.isEmpty)
        #expect(o.analysis.stays.isEmpty)
        #expect(o.questions.isEmpty)
        #expect(o.placeAlbums.isEmpty)
    }

    // MARK: Places the user goes to again and again

    @Test func weekendHomeEverySecondWeekend() throws {
        let library = LifePatterns.weekendHome()
        let all = Set(library.stays.joined())
        // Before the answer: 52 weekends, each a trip; the suggestions gather them in one album,
        // and that album asks the question.
        let before = outcome(library)
        expectOneTripPerStay(before, library.stays)
        #expect(before.trips.allSatisfy { $0.kind == .weekendTrip })
        let question = try #require(before.questions.first)
        #expect(before.questions.count == 1)
        #expect(question.stayCount == 52)
        #expect(Set(question.tripIDs) == Set(before.trips.map(\.id)))
        #expect(GeoMath.distance(question.center, LifePatterns.Places.garmisch) < 1_000)
        let gathered = try #require(before.tripPlaceAlbums.first)
        #expect(gathered.title == "Garmisch-Partenkirchen")
        #expect(gathered.assetIDs == all)
        #expect(before.question(on: gathered) == question)
        #expect(before.placeAlbums.isEmpty)

        // "Ja, hier bin ich öfter": no trips there any more, one album for the place.
        let yes = outcome(library, answers: answer(true, question))
        #expect(yes.trips.isEmpty)
        #expect(yes.questions.isEmpty)
        #expect(yes.tripAlbums.isEmpty && yes.tripPlaceAlbums.isEmpty)
        let place = try #require(yes.placeAlbums.first)
        #expect(yes.placeAlbums.count == 1)
        #expect(place.title == "Garmisch-Partenkirchen")
        #expect(place.folderPath == ["Orte"])
        #expect(place.assetIDs == all)
        #expect(place.isSensitive && !place.requiresUserName)
        expectNoLabels(yes)

        // "Nein, das sind Reisen": the trips stay, the question is not asked again.
        let no = outcome(library, answers: answer(false, question))
        expectOneTripPerStay(no, library.stays)
        #expect(no.questions.isEmpty)
        #expect(no.tripPlaceAlbums.map(\.assetIDs) == [all])
        #expect(no.placeAlbums.isEmpty)
    }

    @Test func holidayFlatOnceAMonth() throws {
        let library = LifePatterns.holidayFlat()
        let before = outcome(library)
        expectOneTripPerStay(before, library.stays)
        // Four days each: a trip of its own every month, each asking the question.
        #expect(before.tripAlbums.count == 24)
        #expect(before.tripAlbums.first?.title == "Malcesine, Januar 2024")
        let question = try #require(before.questions.first)
        #expect(before.questions.count == 1 && question.stayCount == 24)
        #expect(before.tripAlbums.allSatisfy { before.question(on: $0) == question })

        let yes = outcome(library, answers: answer(true, question))
        #expect(yes.trips.isEmpty && yes.tripAlbums.isEmpty && yes.questions.isEmpty)
        #expect(yes.placeAlbums.map(\.title) == ["Malcesine"])
        #expect(yes.placeAlbums.first?.assetIDs == Set(library.stays.joined()))
        expectNoLabels(yes)

        let no = outcome(library, answers: answer(false, question))
        #expect(no.tripAlbums.count == 24)
        #expect(no.questions.isEmpty && no.placeAlbums.isEmpty)
    }

    @Test func familyInAnotherCityEveryFewWeeks() throws {
        let library = LifePatterns.family()
        let before = outcome(library)
        expectOneTripPerStay(before, library.stays)
        let question = try #require(before.questions.first)
        #expect(before.questions.count == 1 && question.stayCount == library.stays.count)
        let gathered = try #require(before.tripPlaceAlbums.first)
        #expect(gathered.title == "Hamburg" && before.question(on: gathered) == question)

        let yes = outcome(library, answers: answer(true, question))
        #expect(yes.trips.isEmpty && yes.questions.isEmpty && yes.tripPlaceAlbums.isEmpty)
        #expect(yes.placeAlbums.map(\.title) == ["Hamburg"])
        #expect(yes.placeAlbums.first?.assetIDs == Set(library.stays.joined()))

        let no = outcome(library, answers: answer(false, question))
        expectOneTripPerStay(no, library.stays)
        #expect(no.questions.isEmpty && no.placeAlbums.isEmpty)
    }

    // MARK: Moving

    /// Moving from Hamburg to Munich is not a trip. Visits to Hamburg a few months after the
    /// move are; the place album after "Ja" holds those visits, never the years lived there.
    @Test func movingHouseAndVisitingTheOldTown() throws {
        let library = LifePatterns.movingHouse()
        let before = outcome(library)
        let moved = Fixture.date("2024-07-01")
        #expect(before.trips.allSatisfy { $0.start > moved })
        // The first visit (August 2024) is still inside the old habitual area.
        expectOneTripPerStay(before, Array(library.stays.dropFirst()))
        let question = try #require(before.questions.first)
        #expect(GeoMath.distance(question.center, LifePatterns.Places.hamburg) < 1_000)

        let yes = outcome(library, answers: answer(true, question))
        #expect(yes.trips.isEmpty)
        let place = try #require(yes.placeAlbums.first)
        #expect(place.assetIDs == Set(library.stays.dropFirst().joined()))
    }

    // MARK: Long times away

    /// Four months in Lisbon with weekends in Porto: one trip. Before, Lisbon became the
    /// habitual area for those months and only the Porto weekends were trips.
    @Test func semesterAbroadIsOneTrip() throws {
        let library = LifePatterns.semester()
        let before = outcome(library)
        let trip = try #require(before.trips.first)
        #expect(before.trips.count == 1)
        #expect(Set(trip.geotaggedAssetIDs) == Set(library.stays.joined()))
        #expect(trip.start == Fixture.date("2024-09-01 17:00"))
        #expect(LifePatterns.ymd(trip.end) == "2024-12-31")
        #expect(trip.kind == .vacation)  // one place holds most evenings: no road trip
        #expect(before.tripAlbums.map(\.title) == ["Lissabon, September–Dezember 2024"])
        #expect(before.questions.isEmpty)

        // "Keine Reise, hier bin ich öfter" on the semester: Lisbon is a place of its own, the
        // weekends in Porto are trips from there.
        let place = try #require(before.report.tripPlaces[trip.id])
        #expect(GeoMath.distance(place, LifePatterns.Places.lisbon) < 1_000)
        let yes = outcome(library, answers: RecurringPlaceAnswers().answering(true, at: place, name: "Lissabon", date: Self.answeredAt))
        #expect(yes.trips.map { LifePatterns.ymd($0.start) } == ["2024-10-12", "2024-11-16"])
        #expect(yes.placeAlbums.map(\.title) == ["Lissabon"])
        #expect(yes.placeAlbums.first?.assetIDs.count == 354)
    }

    /// A Christmas visit home ends the first part, like coming home ends every trip.
    @Test func semesterWithChristmasAtHome() {
        let o = outcome(LifePatterns.semester(christmasAtHome: true))
        #expect(o.trips.map { "\(LifePatterns.ymd($0.start))…\(LifePatterns.ymd($0.end))" } == ["2024-09-01…2024-12-19", "2025-01-07…2025-01-31"])
        #expect(o.questions.isEmpty)
    }

    /// Six months away, two of them working in Sydney: one journey. Before, Sydney became the
    /// habitual area and the journey ended at New Year.
    @Test func longJourneyThroughManyCountries() throws {
        let library = LifePatterns.longJourney()
        let o = outcome(library)
        let trip = try #require(o.trips.first)
        #expect(o.trips.count == 1)
        #expect(Set(trip.geotaggedAssetIDs) == Set(library.stays.joined()))
        #expect(LifePatterns.ymd(trip.start) == "2024-10-01" && LifePatterns.ymd(trip.end) == "2025-03-31")
        #expect(trip.kind == .roadTrip)
        #expect(o.tripAlbums.count == 1)
        #expect(o.questions.isEmpty && o.placeAlbums.isEmpty)
    }

    /// A stay of up to a year that ends with the return is time away; two years abroad are a
    /// move, even with the return (no trip of two years).
    @Test func twoYearsAbroadAreAMoveNotATrip() {
        var lib = LibraryBuilder()
        lib.daily(from: "2022-01-01", to: "2022-12-31", at: LifePatterns.Places.munich, perDay: 2, hour: 19)
        lib.daily(from: "2023-01-01", to: "2024-12-31", at: LifePatterns.Places.lisbon, perDay: 2, hour: 19)
        lib.daily(from: "2025-01-01", to: "2025-12-31", at: LifePatterns.Places.munich, perDay: 2, hour: 19)
        #expect(detector.detect(in: lib.assets).isEmpty)
    }

    /// While the user has not come back yet, a long stay is where they live: it may be a move.
    @Test func longStayWithoutReturnIsWhereTheUserLives() {
        var lib = LibraryBuilder()
        lib.daily(from: "2025-01-01", to: "2025-08-31", at: LifePatterns.Places.munich, perDay: 2, hour: 19)
        lib.daily(from: "2025-09-01", to: "2025-12-31", at: LifePatterns.Places.lisbon, perDay: 3, hour: 17)
        #expect(detector.detect(in: lib.assets).isEmpty)
    }

    // MARK: Business and nomads

    /// Business trips with many photos are trips, also three weeks at a fair in Shanghai. The
    /// office in Frankfurt every two months is asked about.
    @Test func businessTripsWithManyPhotos() throws {
        let library = LifePatterns.businessTrips()
        let before = outcome(library)
        expectOneTripPerStay(before, library.stays)
        let question = try #require(before.questions.first)
        #expect(before.questions.count == 1)
        #expect(GeoMath.distance(question.center, LifePatterns.Places.frankfurt) < 1_000 && question.stayCount == 6)
        #expect(before.tripAlbums.map(\.title) == [
            "Hamburg, Februar 2024", "Berlin, März 2024", "Paris, April 2024", "London, 14. Mai 2024", "Wien, Juni 2024",
            "Zürich, September 2024", "Mailand, Oktober 2024", "Shanghai, November 2024",
        ])
        #expect(before.tripAlbums.allSatisfy { before.question(on: $0) == nil })
        #expect(before.tripPlaceAlbums.map(\.title) == ["Frankfurt am Main"])

        let yes = outcome(library, answers: answer(true, question))
        expectOneTripPerStay(yes, Array(library.stays.prefix(8)))
        #expect(yes.tripPlaceAlbums.isEmpty)
        #expect(yes.placeAlbums.map(\.title) == ["Frankfurt am Main"])
        #expect(yes.placeAlbums.first?.assetIDs == Set(library.stays.suffix(6).joined()))

        let no = outcome(library, answers: answer(false, question))
        expectOneTripPerStay(no, library.stays)
        #expect(no.questions.isEmpty && no.placeAlbums.isEmpty)
    }

    /// A new city every month and never back: every month is its own trip, named after its
    /// city. Before, the whole year was one road trip.
    @Test func digitalNomadChangingCitiesMonthly() {
        let library = LifePatterns.digitalNomad()
        let o = outcome(library)
        expectOneTripPerStay(o, library.stays)
        #expect(o.trips.allSatisfy { $0.kind == .vacation })
        #expect(o.tripAlbums.map(\.title) == [
            "Lissabon, Januar 2025", "Marrakesch, Februar 2025", "Valencia, März 2025", "Barcelona, April 2025",
            "Split, Mai 2025", "Athen, Juni 2025", "Istanbul, Juli 2025", "Tiflis, August 2025",
            "Budapest, September 2025", "Prag, Oktober 2025", "Kopenhagen, November 2025", "Edinburgh, Dezember 2025",
        ])
        #expect(o.questions.isEmpty)
    }

    /// Mostly photographs while travelling: every trip is found, also three weeks in Croatia
    /// (before, that holiday became the habitual area and vanished). Rome three times in four
    /// years is a favourite destination, not a place to ask about.
    @Test func mostlyPhotographsWhileTravelling() {
        let library = LifePatterns.mostlyWhileTravelling()
        let o = outcome(library)
        expectOneTripPerStay(o, library.stays)
        #expect(o.questions.isEmpty)
        #expect(o.tripAlbums.contains { $0.title == "Split, August 2021" })
        #expect(o.placeAlbums.isEmpty)
    }

    // MARK: Rules behind it

    /// Stays elsewhere are counted per stay, not per trip album: a place is asked about from four
    /// stays within a year on, spread over at least four weeks.
    @Test func recurrenceNeedsFourStaysWithinAYear() {
        let day = { (s: String) in Fixture.date(s) }
        #expect(RecurringPlaces.isRecurring([day("2024-01-01"), day("2024-04-01"), day("2024-08-01"), day("2024-12-01")]))
        #expect(!RecurringPlaces.isRecurring([day("2024-01-01"), day("2024-05-01"), day("2024-09-01"), day("2025-02-01")]))
        #expect(!RecurringPlaces.isRecurring([day("2024-01-01"), day("2024-01-03"), day("2024-01-05"), day("2024-01-07")]))
        #expect(!RecurringPlaces.isRecurring([day("2024-01-01"), day("2024-04-01"), day("2024-08-01")]))
    }

    /// An answer is kept by position: answering again keeps its id (the place album keeps its
    /// suggestion and the decisions on it), taking it back makes the stays trips again and does
    /// not bring the question back.
    @Test func answersKeepTheirPlaceAndCanBeTakenBack() throws {
        let center = LifePatterns.Places.garda
        let yes = RecurringPlaceAnswers().answering(true, at: center, name: "Malcesine", date: Self.answeredAt)
        let entry = try #require(yes.places.first)
        let nearby = GeoCoordinate(latitude: center.latitude + 0.05, longitude: center.longitude)    // 5.5 km
        let changed = yes.answering(false, at: nearby, name: nil, date: Self.answeredAt)
        #expect(changed.places.count == 1)
        #expect(changed.places.first?.id == entry.id && changed.places.first?.center == center)
        #expect(changed.places.first?.name == "Malcesine")
        #expect(changed.oftenHere.isEmpty)
        let elsewhere = yes.answering(true, at: LifePatterns.Places.hamburg, name: "Hamburg", date: Self.answeredAt)
        #expect(elsewhere.oftenHere.count == 2)

        let withdrawn = yes.withdrawing(entry.id, date: Self.answeredAt)
        #expect(withdrawn.oftenHere.isEmpty)
        #expect(withdrawn.answer(near: center)?.oftenHere == false)

        // Encoded like every stored value.
        let data = try JSONEncoder().encode(elsewhere)
        #expect(try JSONDecoder().decode(RecurringPlaceAnswers.self, from: data) == elsewhere)
    }

    /// After "Ja" and taking it back, the trips come back as they were (same photos, same ids
    /// from the detector).
    @Test func takingTheAnswerBackRestoresTheTrips() throws {
        let library = LifePatterns.holidayFlat()
        let before = outcome(library)
        let question = try #require(before.questions.first)
        let yes = answer(true, question)
        #expect(outcome(library, answers: yes).trips.isEmpty)
        let back = outcome(library, answers: yes.withdrawing(try #require(yes.places.first).id, date: Self.answeredAt))
        #expect(back.trips == before.trips)
        #expect(back.questions.isEmpty)
    }

    /// An excursion from the place the user is often at is a trip that starts there.
    @Test func excursionFromAPlaceTheUserIsOftenAtIsATrip() throws {
        var lib = LibraryBuilder()
        let stays = LifePatterns.every([14], from: "2024-01-06", until: "2024-12-28", days: 2, place: LifePatterns.Places.garmisch, perDay: 6)
        _ = LifePatterns.life(to: "2024-12-31", stays: stays, into: &lib)
        // Sunday afternoon at the Achensee (Tyrol, 46 km from Garmisch, 77 km from Munich)
        // after the morning at the weekend place.
        let achensee = GeoCoordinate(latitude: 47.4500, longitude: 11.7100)
        let sunday = lib.daily(from: "2024-06-23", to: "2024-06-23", at: achensee, perDay: 12, hour: 15)
        let answers = RecurringPlaceAnswers().answering(true, at: LifePatterns.Places.garmisch, name: nil, date: Self.answeredAt)
        let trips = detector.detect(in: lib.assets, places: answers)
        #expect(trips.map { Set($0.geotaggedAssetIDs) } == [Set(sunday)])
    }
}
