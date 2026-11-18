import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Review finding P1-13 (core logic, 18.11.2026): "seit 2024", "vor 2024" and "nach 2024" all
/// showed exactly the year 2024, "Winter 2025/26" showed parts of two winters, and a date that
/// does not exist ("29.2.2025") showed the whole year. Expectations come from the photos' dates,
/// never from what the search answers.
@Suite("Search: periods before, since and after a date (P1-13)")
struct SearchDateRangeTests {
    static let lab = SearchLab.build()
    static let index = SearchIndex(facts: lab.facts, calendar: SearchLab.calendar)

    static func hits(_ query: String) -> Set<AssetID> { Set(index.search(query, now: SearchLab.now).ids) }
    static func ignored(_ query: String) -> [String] {
        index.search(query, now: SearchLab.now).tokens.filter { $0.kind == .ignored }.map(\.label)
    }
    static func from(_ date: String) -> Set<AssetID> { lab.between(date, "2100-01-01") }
    static func before(_ date: String) -> Set<AssetID> { lab.between("1900-01-01", date) }

    @Test func aWordBeforeAYearMakesItAPeriod() {
        let lab = Self.lab
        // The library must have photos on both sides of the years asked about.
        #expect(!Self.before("2024-01-01").isEmpty && !Self.from("2025-01-01").isEmpty)
        let cases: [(String, Set<AssetID>)] = [
            ("seit 2024", Self.from("2024-01-01")), ("ab 2024", Self.from("2024-01-01")), ("since 2024", Self.from("2024-01-01")),
            ("nach 2024", Self.from("2025-01-01")), ("after 2024", Self.from("2025-01-01")),
            ("vor 2024", Self.before("2024-01-01")), ("before 2024", Self.before("2024-01-01")),
            ("bis 2024", Self.before("2025-01-01")), ("until 2024", Self.before("2025-01-01")), ("till 2024", Self.before("2025-01-01")),
            // "from 2024" means "taken in 2024" in English, as "aus 2024" does in German.
            ("from 2024", lab.between("2024-01-01", "2025-01-01")), ("aus 2024", lab.between("2024-01-01", "2025-01-01")),
            ("Fotos seit 2025 in Italien", Self.from("2025-01-01").intersection(lab.country("IT"))),
            ("seit dem 24.12.2024", Self.from("2024-12-24")), ("vor dem 24.12.2024", Self.before("2024-12-24")),
            ("bis 24.12.2024", Self.before("2024-12-25")),
            ("seit Mai 2025", Self.from("2025-05-01")), ("vor Juni 2024", Self.before("2024-06-01")),
            ("seit letztem Jahr", Self.from("2025-01-01")),
            // Unchanged: "vor 2 Jahren" is a year, "nach Italien" a place.
            ("vor 2 Jahren", lab.between("2024-01-01", "2025-01-01")), ("nach Italien", lab.country("IT")),
        ]
        var wrong: [String] = []
        for (query, expected) in cases {
            let got = Self.hits(query)
            if got != expected || expected.isEmpty || !Self.ignored(query).isEmpty {
                wrong.append("„\(query)“: \(got.count) hits, expected \(expected.count), not understood \(Self.ignored(query))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
    }

    @Test func thePeriodIsShownAsOneTermWithItsBound() {
        let tokens = Self.index.search("vor 2024", now: SearchLab.now).tokens
        #expect(tokens.count == 1)
        #expect(tokens.first?.kind == .date)
        #expect(tokens.first?.label == "Vor 2024")
        #expect(tokens.first?.detail == "bis 31. Dez. 2023")
        let english = Self.index.search("after 2024", now: SearchLab.now).tokens
        #expect(english.first?.label == "After 2024")
        #expect(english.first?.detail == "from Jan 1, 2025")
    }

    /// A word that sets a period before a date it cannot make a period of is shown as not
    /// understood instead of being dropped without a word.
    @Test func aPeriodWordItCannotUseIsShownAsNotUnderstood() {
        #expect(Self.ignored("seit Weihnachten") == ["seit"])
        #expect(Self.ignored("nach Mai") == ["nach"])
        #expect(Self.ignored("before christmas") == ["before"])
    }

    @Test func winterWithTwoYearsIsOneWinter() {
        let winter = Self.lab.between("2025-12-01", "2026-03-01")
        #expect(!winter.isEmpty)
        for query in ["Winter 2025/26", "winter 2025/2026", "Winter 2025-26", "Winter 2025-2026", "winter 25/26", "Winter 2025 / 26"] {
            #expect(Self.hits(query) == winter, "„\(query)“")
            #expect(Self.ignored(query).isEmpty, "„\(query)“")
        }
        // The same winter as "diesen Winter" on New Year's Day, as the reviewer compared it.
        #expect(Self.hits("Winter 2025/26") == Set(Self.index.search("diesen Winter", now: Fixture.date("2026-01-01 00:30")).ids))
        let tokens = Self.index.search("Winter 2025/26", now: SearchLab.now).tokens
        #expect(tokens.map(\.label) == ["Winter 2025/26"])
        // Years that are not one winter are not understood.
        #expect(Self.hits("Winter 2025/27").isEmpty)
        #expect(Self.ignored("Winter 2025/27") == ["Winter 2025/27"])
    }

    @Test func aDateThatDoesNotExistIsNotUnderstood() {
        for query in ["29.2.2025", "31.4.2025", "2025-02-30", "31.4.", "30.2.", "13.13.2025"] {
            #expect(Self.hits(query).isEmpty, "„\(query)“ finds photos")
            #expect(Self.ignored(query) == [query], "„\(query)“: \(Self.ignored(query))")
        }
        // A date that exists still is one.
        #expect(Self.index.search("29.2.2024", now: SearchLab.now).tokens.map(\.kind) == [.date])
        #expect(Self.index.search("29.2.", now: SearchLab.now).tokens.map(\.kind) == [.date])
        #expect(Self.hits("24.12.2024") == Self.lab.between("2024-12-24", "2024-12-25"))
    }

    /// The same mistake in another form: "12/24/2025" was read as the whole year 2025.
    @Test func aDateWithSlashesIsADayOrNotUnderstood() {
        let christmasEve = Self.lab.between("2025-12-24", "2025-12-25")
        #expect(!christmasEve.isEmpty)
        #expect(Self.hits("12/24/2025") == christmasEve)
        #expect(Self.hits("24/12/2025") == christmasEve)
        #expect(Self.ignored("12/24/2025").isEmpty)
        // 3/4/2025 is the 3rd of April or the 4th of March: not understood.
        #expect(Self.hits("3/4/2025").isEmpty)
        #expect(Self.ignored("3/4/2025") == ["3/4/2025"])
    }

    /// The reviewer's own case, on the simulated library of 5,875 photos.
    @Test func theReviewersCaseOnTheSimulatedLibrary() {
        let index = SearchIndex(facts: SimulatedLibrary.fuchs().analysis().facts, calendar: Fixture.calendar)
        let now = Fixture.date("2026-11-18 06:00")
        let only = Set(index.search("2024", now: now).ids)
        #expect(Set(index.search("seit 2024", now: now).ids).isStrictSuperset(of: only))
        #expect(Set(index.search("vor 2024", now: now).ids).isDisjoint(with: only))
        #expect(index.search("Winter 2025/26", now: now).ids == index.search("diesen Winter", now: Fixture.date("2026-01-01 00:30")).ids)
        #expect(index.search("29.2.2025", now: now).ids.count < index.search("2025", now: now).ids.count)
    }
}

/// Second review of P1-13 (18.11.2026): two bounds were joined as alternatives, so
/// "nach 2022 und vor 2024" showed every photo under "Nach 2022 oder Vor 2024"; "Mai bis
/// Juli 2024" was May of any year or anything up to July 2024; "bis Ende 2024" lost its "bis".
/// Expectations come from the photos' dates.
@Suite("Search: bounds on both sides and ranges between two dates (P1-13, second review)")
struct SearchDateBetweenTests {
    static let lab = SearchDateRangeTests.lab
    static let index = SearchDateRangeTests.index
    static func hits(_ query: String) -> Set<AssetID> { SearchDateRangeTests.hits(query) }
    static func ignored(_ query: String) -> [String] { SearchDateRangeTests.ignored(query) }
    static func labels(_ query: String) -> [String] { index.search(query, now: SearchLab.now).tokens.map(\.label) }

    @Test func boundsOnBothSidesApplyTogether() {
        let lab = Self.lab
        let only2023 = lab.between("2023-01-01", "2024-01-01")
        #expect(!only2023.isEmpty && only2023.count < lab.between("1900-01-01", "2100-01-01").count)
        let cases: [(String, Set<AssetID>)] = [
            ("nach 2022 und vor 2024", only2023), ("after 2022 before 2024", only2023), ("before 2024 and after 2022", only2023),
            ("nach 2020 vor 2024", lab.between("2021-01-01", "2024-01-01")),
            ("seit Mai 2024 bis Juli 2024", lab.between("2024-05-01", "2024-08-01")),
            ("Italien nach 2022 und vor 2026", lab.between("2023-01-01", "2026-01-01").intersection(lab.country("IT"))),
        ]
        var wrong: [String] = []
        for (query, expected) in cases {
            let got = Self.hits(query)
            if got != expected || expected.isEmpty || !Self.ignored(query).isEmpty {
                wrong.append("„\(query)“: \(got.count) hits, expected \(expected.count), not understood \(Self.ignored(query))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
        let tokens = Self.index.search("nach 2022 und vor 2024", now: SearchLab.now).tokens
        #expect(tokens.map(\.label) == ["Nach 2022 und vor 2024"])
        #expect(tokens.first?.detail == "2023")
        #expect(Self.labels("after 2022 before 2024") == ["After 2022 and before 2024"])
    }

    /// No day lies after 2024 and before 2020: the search says so and finds nothing, rather
    /// than dropping the words and showing photos the user did not ask for.
    @Test func boundsThatExcludeEachOtherFindNothingAndSaySo() {
        for query in ["vor 2020 nach 2024", "Juli 2024 bis Mai 2024"] {
            #expect(Self.hits(query).isEmpty, "„\(query)“")
            #expect(Self.ignored(query).isEmpty, "„\(query)“")
            let tokens = Self.index.search(query, now: SearchLab.now).tokens
            #expect(tokens.count == 1 && tokens.first?.detail == "kein gemeinsamer Zeitraum", "„\(query)“: \(tokens)")
        }
    }

    @Test func aRangeBetweenTwoDatesIsOnePeriod() {
        let lab = Self.lab
        let cases: [(String, Set<AssetID>)] = [
            ("Mai bis Juli 2024", lab.between("2024-05-01", "2024-08-01")),
            ("von Mai bis Juli 2024", lab.between("2024-05-01", "2024-08-01")),
            ("May until July 2024", lab.between("2024-05-01", "2024-08-01")),
            ("Mai 2023 bis Juli 2024", lab.between("2023-05-01", "2024-08-01")),
            ("November bis Februar 2025", lab.between("2024-11-01", "2025-03-01")),
            ("24.12.2024 bis 6.1.2025", lab.between("2024-12-24", "2025-01-07")),
        ]
        var wrong: [String] = []
        for (query, expected) in cases {
            let got = Self.hits(query)
            if got != expected || expected.isEmpty || !Self.ignored(query).isEmpty {
                wrong.append("„\(query)“: \(got.count) hits, expected \(expected.count), not understood \(Self.ignored(query))")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "\n"))")
        #expect(Self.labels("Mai bis Juli 2024") == ["Mai bis Juli 2024"])
    }

    /// "bis Ende 2024" is up to the end of 2024; an edge that does not fit the word
    /// ("bis Anfang 2024") is shown as not understood, never dropped without a word.
    @Test func theEdgeOfADateAfterAPeriodWord() {
        let lab = Self.lab
        #expect(Self.hits("bis Ende 2024") == lab.between("1900-01-01", "2025-01-01"))
        #expect(Self.ignored("bis Ende 2024").isEmpty)
        #expect(Self.labels("bis Ende 2024") == ["Bis Ende 2024"])
        #expect(Self.hits("until the end of May 2025") == lab.between("1900-01-01", "2025-06-01"))
        #expect(Self.hits("seit Anfang 2024") == lab.between("2024-01-01", "2100-01-01"))
        #expect(Self.ignored("bis Anfang 2024") == ["bis", "Anfang"])
    }

    /// Two dates written as numbers in one query crashed the search: the second one's place
    /// was counted with the first still in the text.
    @Test func twoDatesWrittenAsNumbers() {
        #expect(Self.hits("24.12.2024 25.12.2024") == Self.lab.between("2024-12-24", "2024-12-26"))
        #expect(Self.labels("24.12.2024 25.12.2024") == ["24. Dez. 2024 oder 25. Dez. 2024"])
    }
}
