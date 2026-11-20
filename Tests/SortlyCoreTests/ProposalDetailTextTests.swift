import Foundation
import Testing
@testable import SortlyCore

/// The open suggestion (design wave 1, E2): its photos by day on the clock where they were
/// taken (`LocalTime`, decision of 19.11.2026), the sign "Vorschlag · noch nicht in Fotos", the
/// count with the days ("16 Fotos · 12. bis 16. Oktober") and where the album goes.
@Suite("Proposal detail text")
struct ProposalDetailTextTests {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let newYork = TimeZone(identifier: "America/New_York")!

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    static func facts(_ id: AssetID, _ iso: String?, zone: TimeZone?) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: id, creationDate: iso.map(date)), timeZone: zone)
    }

    /// The draft's Kyoto trip: 3 photos on Saturday 12 October 2024, 5 on Sunday, 8 more until Wednesday.
    static func kyoto() -> (ids: [AssetID], facts: [AssetID: AssetFacts]) {
        var times: [String] = []
        times += ["2024-10-12T09:00:00+09:00", "2024-10-12T13:30:00+09:00", "2024-10-12T23:45:00+09:00"]
        times += (0..<5).map { "2024-10-13T1\($0):00:00+09:00" }
        times += (0..<8).map { "2024-10-1\(4 + $0 % 3)T1\($0):00:00+09:00" }
        let ids = times.indices.map { AssetID("k\($0)") }
        let facts = Dictionary(uniqueKeysWithValues: zip(ids, times).map { ($0, Self.facts($0, $1, zone: tokyo)) })
        return (ids, facts)
    }

    static func trip(_ count: Int, title: String = "Kyoto, Oktober 2024", folder: [String] = ["Reisen"]) -> AlbumProposal {
        AlbumProposal(id: SortlyID("trip"), kind: .trip, title: title, folderPath: folder,
                      assetIDs: Set((0..<count).map { AssetID("k\($0)") }), reliability: .certain)
    }

    // MARK: Days

    @Test func photosAreGroupedByTheirDayOldestFirst() {
        let (ids, facts) = Self.kyoto()
        let days = PhotoDays.group(ids, facts: facts, fallback: Self.berlin)
        #expect(days.map(\.title) == ["Samstag, 12. Oktober", "Sonntag, 13. Oktober", "Montag, 14. Oktober",
                                      "Dienstag, 15. Oktober", "Mittwoch, 16. Oktober"])
        #expect(days.map(\.countText) == ["3 Fotos", "5 Fotos", "3 Fotos", "3 Fotos", "2 Fotos"])
        #expect(days.flatMap(\.ids).count == 16)
        #expect(days[0].ids == ["k0", "k1", "k2"], "the photos of a day keep their order")
        let english = PhotoDays.group(ids, facts: facts, fallback: Self.berlin, words: .english)
        #expect(english.prefix(2).map(\.title) == ["Saturday, October 12", "Sunday, October 13"])
        #expect(english[0].countText == "3 photos")
    }

    /// The page groups with the model's facts by id (`AppModel.factsByID`, a `FactsByID` since
    /// review P4-09 in main), the same way as with a dictionary of them.
    @Test func theModelsFactsByIDGroupAlike() {
        let (ids, facts) = Self.kyoto()
        let byID = FactsByID(ids.compactMap { facts[$0] })
        let days = PhotoDays.group(ids + ["unknown"], facts: byID, fallback: Self.berlin)
        #expect(days == PhotoDays.group(ids + ["unknown"], facts: facts, fallback: Self.berlin))
        #expect(days.last?.ids == ["unknown"])
    }

    /// 23:45 in Kyoto is 16:45 in Berlin the same day, but 23:00 in New York is the next day in
    /// Berlin: each photo counts on its own clock, as in Apple Photos.
    @Test func aPhotosDayIsTheDayOnItsOwnClock() {
        let facts: [AssetID: AssetFacts] = [
            "ny": Self.facts("ny", "2026-01-31T23:00:00-05:00", zone: Self.newYork),
            "berlin": Self.facts("berlin", "2026-01-31T08:00:00+01:00", zone: Self.berlin),
            "noZone": Self.facts("noZone", "2026-01-31T23:00:00-05:00", zone: nil),
        ]
        let days = PhotoDays.group(["berlin", "ny", "noZone"], facts: facts, fallback: Self.berlin)
        #expect(days.map(\.title) == ["Samstag, 31. Januar", "Sonntag, 1. Februar"])
        #expect(days[0].ids == ["berlin", "ny"])
        #expect(days[1].ids == ["noZone"], "without a zone the fallback's clock: 05:00 in Berlin on 1 February")
        #expect(days[0].countText == "2 Fotos")
        #expect(days[1].countText == "1 Foto")
        #expect(PhotoDays.group(["noZone"], facts: facts, fallback: Self.berlin, words: .english)[0].countText == "1 photo")
    }

    @Test func photosWithoutADateComeLast() {
        let facts: [AssetID: AssetFacts] = [
            "dated": Self.facts("dated", "2024-10-12T09:00:00+09:00", zone: Self.tokyo),
            "undated": Self.facts("undated", nil, zone: nil),
        ]
        let days = PhotoDays.group(["undated", "dated", "unknown"], facts: facts, fallback: Self.berlin)
        #expect(days.map(\.title) == ["Samstag, 12. Oktober", "Ohne Datum"])
        #expect(days[1].ids == ["undated", "unknown"])
        #expect(days[1].day == nil)
        #expect(Set(days.map(\.id)).count == 2)
        #expect(PhotoDays.group(["unknown"], facts: [:], fallback: Self.berlin, words: .english).map(\.title) == ["No date"])
    }

    @Test func theYearIsNamedWhenThePhotosSpanYears() {
        let facts: [AssetID: AssetFacts] = [
            "a": Self.facts("a", "2025-12-31T22:00:00+01:00", zone: Self.berlin),
            "b": Self.facts("b", "2026-01-01T00:30:00+01:00", zone: Self.berlin),
        ]
        #expect(PhotoDays.group(["a", "b"], facts: facts, fallback: Self.berlin).map(\.title)
                == ["Mittwoch, 31. Dezember 2025", "Donnerstag, 1. Januar 2026"])
        #expect(PhotoDays.group(["a", "b"], facts: facts, fallback: Self.berlin, words: .english).map(\.title)
                == ["Wednesday, December 31, 2025", "Thursday, January 1, 2026"])
    }

    @Test func noPhotosNoDays() {
        #expect(PhotoDays.group([], facts: [:], fallback: Self.berlin).isEmpty)
    }

    /// A big suggestion (a country over years): one group per day, nothing lost.
    @Test func manyPhotosOverManyDays() {
        var facts: [AssetID: AssetFacts] = [:]
        var ids: [AssetID] = []
        let start = Self.date("2020-01-01T12:00:00+01:00")
        for n in 0..<6_000 {
            let id = AssetID("p\(n)")
            ids.append(id)
            facts[id] = AssetFacts(asset: AssetSnapshot(id: id, creationDate: start.addingTimeInterval(Double(n / 15) * 86_400)), timeZone: Self.berlin)
        }
        let days = PhotoDays.group(ids, facts: facts, fallback: Self.berlin)
        #expect(days.count == 400)
        #expect(days.allSatisfy { $0.ids.count == 15 && $0.countText == "15 Fotos" })
        #expect(days.first?.title == "Mittwoch, 1. Januar 2020")
        #expect(days.map(\.id) == days.map(\.id).sorted())
    }

    // MARK: Under the cover

    static func detail(_ proposal: AlbumProposal, decision: ProposalDecision? = nil, userTitle: String? = nil,
                       match: MatchResult? = nil, inventory: CollectionInventory = CollectionInventory(), root: String = "",
                       words: ProposalWords = .german) -> ProposalDetailText {
        let (ids, facts) = Self.kyoto()
        let card = ProposalCardText(proposal: proposal, decision: decision, userTitle: userTitle, match: match,
                                    inventory: inventory, rootFolderTitle: root, words: words)
        let members = ids.filter { proposal.assetIDs.contains($0) }
        return ProposalDetailText(card: card, days: PhotoDays.group(members, facts: facts, fallback: Self.berlin, words: words), words: words)
    }

    /// E2: "Vorschlag · noch nicht in Fotos", "16 Fotos · 12. bis 16. Oktober", "Kommt als
    /// neues Album in „Reisen“" (the real folder: trips go into "Reisen").
    @Test func aNewAlbumAsInTheDraft() {
        let text = Self.detail(Self.trip(16))
        #expect(text.pill == "Vorschlag · noch nicht in Fotos")
        #expect(text.facts == "16 Fotos · 12. bis 16. Oktober")
        #expect(text.destination == "Kommt als neues Album in „Reisen“")
        let english = Self.detail(Self.trip(16), words: .english)
        #expect(english.pill == "Suggestion · not in Photos yet")
        #expect(english.facts == "16 photos · October 12–16")
        #expect(english.destination == "Becomes a new album in “Reisen”")
        #expect(Self.detail(Self.trip(16), root: "Albumist").destination == "Kommt als neues Album in „Albumist › Reisen“")
        #expect(Self.detail(Self.trip(16, folder: [])).destination == "Kommt als neues Album zu deinen Alben")
        #expect(Self.detail(Self.trip(16, folder: []), words: .english).destination == "Becomes a new album among your albums")
    }

    /// The year is said where the title does not say it.
    @Test func theYearWhereTheTitleDoesNotNameIt() {
        #expect(Self.detail(Self.trip(16, title: "Kyoto")).facts == "16 Fotos · 12. bis 16. Oktober 2024")
        #expect(Self.detail(Self.trip(16, title: "Kyoto"), words: .english).facts == "16 photos · October 12–16, 2024")
        #expect(Self.detail(Self.trip(3)).facts == "3 Fotos · 12. Oktober")
        #expect(Self.detail(Self.trip(1, title: "Kyoto"), words: .english).facts == "1 photo · October 12, 2024")
    }

    /// The title names the year only as a word of its own: "Haus 20245" or "Kyoto2024" do not.
    @Test(arguments: [("Haus 20245", true), ("Zimmer 12024", true), ("Kyoto2024", true), ("Kyoto 2024", false),
                      ("Kyoto (2024)", false), ("2024: Kyoto", false), ("Kyoto, 2024–2025", false), ("Sommer 2023", true)])
    func theYearIsAWordOfTheTitle(_ example: (title: String, saysYear: Bool)) {
        let facts = Self.detail(Self.trip(16, title: example.title)).facts
        #expect(facts == (example.saysYear ? "16 Fotos · 12. bis 16. Oktober 2024" : "16 Fotos · 12. bis 16. Oktober"), "\(example.title)")
    }

    /// The user's album gets a new name or another folder: the sign says nothing is changed yet,
    /// the line says what changes.
    @Test func aRenameOrAMoveSaysWhatChanges() {
        let proposal = Self.trip(16)
        let folder = CollectionSnapshot(id: "reisen", title: "Reisen", kind: .folder, childIDs: ["japan"])
        let album = CollectionSnapshot(id: "japan", title: "Japan", parentID: "reisen", assetIDs: proposal.assetIDs)
        let inventory = CollectionInventory([folder, album])
        let rename = ProposalDecision.renameExisting("japan", newTitle: "Kyoto", extend: false)
        let renamed = Self.detail(proposal, decision: rename, inventory: inventory)
        #expect(renamed.pill == "Vorschlag · noch nicht geändert")
        #expect(renamed.destination == "Dein Album „Japan“ heißt dann „Kyoto“")
        let english = Self.detail(proposal, decision: rename, inventory: inventory, words: .english)
        #expect(english.pill == "Suggestion · not changed yet")
        #expect(english.destination == "Your album “Japan” will be called “Kyoto”")
        let move = ProposalDecision.moveExisting("japan", folderPath: ["Asien"], extend: false)
        #expect(Self.detail(proposal, decision: move, inventory: inventory).pill == "Vorschlag · noch nicht geändert")
        #expect(Self.detail(proposal, decision: move, inventory: inventory).destination == "Dein Album „Japan“ kommt in „Asien“")
        #expect(Self.detail(proposal, decision: .moveExisting("japan", folderPath: ["Asien", "2024"], extend: false),
                            inventory: inventory, words: .english).destination == "Your album “Japan” moves to “Asien › 2024”")
        let top = ProposalDecision.moveExisting("japan", folderPath: [], extend: false)
        #expect(Self.detail(proposal, decision: top, inventory: inventory).destination == "Dein Album „Japan“ kommt aus seinem Ordner zu deinen Alben")
        #expect(Self.detail(proposal, decision: top, inventory: inventory, words: .english).destination
                == "Your album “Japan” moves out of its folder to your albums")
    }

    @Test func theUsersAlbumIsNamed() {
        let proposal = Self.trip(16, title: "Florenz, Mai 2023")
        let album = CollectionSnapshot(id: "toskana", title: "Toskana", assetIDs: ["k0", "k1"])
        let text = Self.detail(proposal, decision: .extendExisting("toskana"), inventory: CollectionInventory([album]))
        #expect(text.pill == "Vorschlag · noch nicht ergänzt")
        #expect(text.destination == "Kommt in dein Album „Toskana“")
        let english = Self.detail(proposal, decision: .extendExisting("toskana"), inventory: CollectionInventory([album]), words: .english)
        #expect(english.pill == "Suggestion · not added yet")
        #expect(english.destination == "Goes into your album “Toskana”")
        let full = CollectionSnapshot(id: "toskana", title: "Toskana", assetIDs: proposal.assetIDs)
        let done = Self.detail(proposal, decision: .keepExisting("toskana"), inventory: CollectionInventory([full]))
        #expect(done.pill == "Schon in Fotos")
        #expect(done.destination == "Schon in deinem Album „Toskana“")
        #expect(Self.detail(proposal, decision: .keepExisting("toskana"), inventory: CollectionInventory([full]), words: .english).pill
                == "Already in Photos")
    }

    @Test func aPlaceWithoutANameAndSeveralAlbums() {
        let place = AlbumProposal(id: SortlyID("place"), kind: .frequentPlace, title: "Häufiger Ort in Lindau", folderPath: ["Orte"],
                                  assetIDs: ["k0", "k1"], reliability: .likely, isSensitive: true, requiresUserName: true)
        let unnamed = Self.detail(place)
        #expect(unnamed.pill == "Vorschlag · noch nicht in Fotos")
        #expect(unnamed.destination == "Kommt als neues Album in „Orte“")
        #expect(unnamed.facts == "2 Fotos · 12. Oktober 2024")
        let proposal = Self.trip(16)
        let several = MatchResult(proposalID: proposal.id, status: .multipleMatches, best: nil, alternatives: [], sameNameAlbums: [], reasons: [])
        #expect(Self.detail(proposal, match: several).destination == "Mehrere deiner Alben passen")
        #expect(Self.detail(proposal, match: several, words: .english).destination == "Several of your albums fit")
    }

    @Test func withoutDatesOnlyTheCount() {
        let card = ProposalCardText(proposal: Self.trip(3), decision: nil, userTitle: nil, match: nil, inventory: CollectionInventory())
        let days = PhotoDays.group(["k0", "k1", "k2"], facts: [:], fallback: Self.berlin)
        #expect(ProposalDetailText(card: card, days: days).facts == "3 Fotos")
    }

    // MARK: Spans

    static func day(_ iso: String) -> CalendarDay { CalendarDay(wallClock: date(iso + "T12:00:00Z")) }

    /// A day made from its number is the day of every clock on it (`PhotoDays` makes one per day,
    /// not one per photo), over leap days and the turn of years.
    @Test func aDayFromItsNumberIsTheDayOfItsClocks() {
        for iso in ["2024-02-28", "2024-02-29", "2024-03-01", "2023-12-31", "2024-01-01", "2000-02-29", "1970-01-01", "2038-01-19"] {
            for time in ["T00:00:00Z", "T12:00:00Z", "T23:59:59Z"] {
                let day = CalendarDay(wallClock: Self.date(iso + time))
                #expect(CalendarDay(number: day.number) == day, "\(iso)\(time)")
                #expect(day == Self.day(iso), "\(iso)\(time)")
            }
        }
        let leap = Self.day("2024-02-29")
        #expect(leap.year == 2024)
        #expect(leap.month == 2)
        #expect(leap.day == 29)
        #expect(leap.weekday == 5, "a Thursday")
    }

    @Test(arguments: [
        ("2024-10-12", "2024-10-12", "12. Oktober", "12. Oktober 2024", "October 12", "October 12, 2024"),
        ("2024-10-12", "2024-10-16", "12. bis 16. Oktober", "12. bis 16. Oktober 2024", "October 12–16", "October 12–16, 2024"),
        ("2024-09-28", "2024-10-03", "28. September bis 3. Oktober", "28. September bis 3. Oktober 2024",
         "September 28 – October 3", "September 28 – October 3, 2024"),
        ("2024-12-28", "2025-01-03", "28. Dezember 2024 bis 3. Januar 2025", "28. Dezember 2024 bis 3. Januar 2025",
         "December 28, 2024 – January 3, 2025", "December 28, 2024 – January 3, 2025"),
        // 62 days still by day, 63 by month.
        ("2024-03-01", "2024-05-02", "1. März bis 2. Mai", "1. März bis 2. Mai 2024", "March 1 – May 2", "March 1 – May 2, 2024"),
        ("2024-03-01", "2024-05-03", "März bis Mai", "März bis Mai 2024", "March – May", "March – May 2024"),
        ("2023-12-01", "2024-03-20", "Dezember 2023 bis März 2024", "Dezember 2023 bis März 2024",
         "December 2023 – March 2024", "December 2023 – March 2024"),
        ("2019-05-01", "2024-08-01", "2019 bis 2024", "2019 bis 2024", "2019 – 2024", "2019 – 2024"),
        ("2023-01-10", "2024-03-20", "2023 bis 2024", "2023 bis 2024", "2023 – 2024", "2023 – 2024"),
    ])
    func spansInWords(_ example: (from: String, to: String, german: String, germanYear: String, english: String, englishYear: String)) {
        let a = Self.day(example.from), b = Self.day(example.to)
        #expect(ProposalWords.german.span(from: a, to: b, withYear: false) == example.german)
        #expect(ProposalWords.german.span(from: a, to: b, withYear: true) == example.germanYear)
        #expect(ProposalWords.english.span(from: a, to: b, withYear: false) == example.english)
        #expect(ProposalWords.english.span(from: a, to: b, withYear: true) == example.englishYear)
    }
}
