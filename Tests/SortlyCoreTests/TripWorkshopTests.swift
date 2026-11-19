import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Reise-Werkstatt (I07): split a trip at a day, merge two neighbours, go back to automatic.
@Suite("Trip workshop")
struct TripWorkshopTests {
    let detector = TripDetector(calendar: Fixture.calendar)

    /// Munich every second day, Rome 12.–19. May 2024 (8 days, 6 photos a day).
    func library() -> LibraryBuilder {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2024-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        lib.daily(from: "2024-05-12", to: "2024-05-19", at: Fixture.Places.rome, perDay: 6, hour: 10)
        return lib
    }

    func dates(_ lib: LibraryBuilder) -> [AssetID: Date] {
        Dictionary(uniqueKeysWithValues: lib.assets.compactMap { a in a.creationDate.map { (a.id, $0) } })
    }

    @Test func splittingAtADayMakesTwoTripsThatStaySplit() throws {
        let lib = library()
        let trip = try #require(detector.detect(in: lib.assets).first)
        let days = TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: dates(lib), calendar: Fixture.calendar)
        #expect(days.count == 8)
        #expect(days.allSatisfy { $0.count == 6 })

        // The first day cannot start a new trip; day 4 (15 May) can.
        #expect(TripWorkshop.split(days, before: 0, dates: dates(lib)) == nil)
        let preview = try #require(TripWorkshop.split(days, before: 3, dates: dates(lib)))
        #expect(preview.first.count == 18)
        #expect(preview.second.count == 30)

        let corrections = TripCorrections().splitting(at: TripWorkshop.splitInstant(before: days[3]))
        let parts = detector.detect(in: lib.assets, corrections: corrections)
        #expect(parts.count == 2)
        #expect(parts.map(\.geotaggedAssetIDs.count) == [18, 30])
        #expect(Fixture.calendar.startOfDay(for: parts[1].start) == days[3].start)
        // Splitting twice at the same day stores one split.
        #expect(corrections.splitting(at: days[3].start).forcedBreaks.count == 1)
        #expect(corrections.changeCount == 1)
    }

    @Test func mergingTwoNeighboursMakesOneTripAndUndoesASplitInside() throws {
        let lib = library()
        let all = dates(lib)
        let trip = try #require(detector.detect(in: lib.assets).first)
        let days = TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: all, calendar: Fixture.calendar)
        let split = TripCorrections().splitting(at: days[3].start)
        let parts = detector.detect(in: lib.assets, corrections: split)
        #expect(parts.count == 2)

        // Neighbours: the second part follows the first right away.
        let spans = parts.map { DateInterval(start: $0.start, end: $0.end) }
        let around = TripWorkshop.neighbours(of: spans[0], among: spans)
        #expect(around.before == nil)
        #expect(around.after == 1)
        #expect(TripWorkshop.neighbours(of: spans[1], among: spans).before == 0)

        let interval = TripWorkshop.mergeInterval(spans[0], spans[1],
                                                  members: parts[0].geotaggedAssetIDs + parts[1].geotaggedAssetIDs, dates: all)
        let merged = split.merging(interval)
        #expect(merged.forcedBreaks.isEmpty) // the split inside is gone, or it would still cut
        let again = detector.detect(in: lib.assets, corrections: merged)
        #expect(again.count == 1)
        #expect(again.first?.geotaggedAssetIDs.count == 48)
    }

    @Test func mergingKeepsTwoTripsWithAHomeStayTogether() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2026-01-01", to: "2026-12-31", at: Fixture.Places.munichHome, perDay: 2, hour: 8,
                  skipping: [("2026-08-01", "2026-08-03"), ("2026-08-06", "2026-08-08")])
        lib.daily(from: "2026-08-01", to: "2026-08-03", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        lib.daily(from: "2026-08-06", to: "2026-08-08", at: Fixture.Places.gardaLake, perDay: 5, hour: 10)
        let trips = detector.detect(in: lib.assets)
        #expect(trips.count == 2)
        let spans = trips.map { DateInterval(start: $0.start, end: $0.end) }
        let interval = TripWorkshop.mergeInterval(spans[0], spans[1], members: trips.flatMap(\.geotaggedAssetIDs), dates: dates(lib))
        let joined = detector.detect(in: lib.assets, corrections: TripCorrections().merging(interval))
        #expect(joined.count == 1)
        #expect(joined.first?.geotaggedAssetIDs.count == 30)
    }

    @Test func neighboursFurtherThanTwoWeeksAwayAreNotOffered() {
        let day: TimeInterval = 86_400
        let base = Fixture.date("2026-03-01")
        let trip = DateInterval(start: base, duration: 3 * day)
        let close = DateInterval(start: base.addingTimeInterval(10 * day), duration: 2 * day)
        let far = DateInterval(start: base.addingTimeInterval(-40 * day), duration: 2 * day)
        let around = TripWorkshop.neighbours(of: trip, among: [far, trip, close])
        #expect(around.before == nil)
        #expect(around.after == 2)
    }

    @Test func aSplitIsListedAtBothPartsAndCanBeUndoneThere() throws {
        let lib = library()
        let trip = try #require(detector.detect(in: lib.assets).first)
        let days = TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: dates(lib), calendar: Fixture.calendar)
        let corrections = TripCorrections().splitting(at: days[4].start)
        let parts = detector.detect(in: lib.assets, corrections: corrections)
        #expect(parts.count == 2)
        for part in parts {
            #expect(corrections.changes(around: DateInterval(start: part.start, end: part.end)) == [.split(days[4].start)])
        }
        // A split far away from the trip is not listed with it.
        let elsewhere = corrections.splitting(at: Fixture.date("2024-09-01"))
        #expect(elsewhere.changes(around: DateInterval(start: parts[0].start, end: parts[0].end)).count == 1)

        let undone = corrections.removing(.split(days[4].start))
        #expect(undone.changeCount == 0)
        #expect(detector.detect(in: lib.assets, corrections: undone).count == 1)
    }

    @Test func resetKeepsPhotosTakenOutOfTrips() {
        let photo = AssetID("p1")
        let corrections = TripCorrections(forcedBreaks: [Fixture.date("2026-01-01")],
                                          forcedJoins: [DateInterval(start: Fixture.date("2026-02-01"), duration: 86_400)],
                                          excludedAssets: [photo])
        #expect(corrections.changeCount == 2)
        let reset = corrections.withoutSplitsAndMerges()
        #expect(reset.changeCount == 0)
        #expect(reset.excludedAssets == [photo])
    }

    // MARK: Audit 2 (2.1, 2.2)

    /// A split right after the first photo: the one-photo part is kept, as the workshop promised.
    @Test func forcedSplitKeepsAOnePhotoPart() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2024-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        let first = lib.photo(at: Fixture.date("2024-05-13 20:00"), Fixture.Places.rome)
        lib.daily(from: "2024-05-14", to: "2024-05-17", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let trip = try #require(detector.detect(in: lib.assets).first)
        #expect(trip.geotaggedAssetIDs.first == first)
        let days = TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: dates(lib), calendar: Fixture.calendar)
        let preview = try #require(TripWorkshop.split(days, before: 1, dates: dates(lib)))
        #expect(preview.first.count == 1)
        let parts = detector.detect(in: lib.assets, corrections: TripCorrections().splitting(at: TripWorkshop.splitInstant(before: days[1])))
        #expect(parts.map(\.geotaggedAssetIDs.count) == [1, 24])
    }

    /// A photo without GPS right at the split (both parts are closer than twice the time
    /// tolerance there) belongs to one part only.
    @Test func photoWithoutGPSAtTheSplitIsInOnePartOnly() throws {
        var lib = LibraryBuilder()
        lib.daily(from: "2024-01-01", to: "2024-12-31", at: Fixture.Places.munichHome, perDay: 1, everyNthDay: 2)
        lib.daily(from: "2024-05-12", to: "2024-05-14", at: Fixture.Places.rome, perDay: 6, hour: 10)
        _ = lib.photo(at: Fixture.date("2024-05-14 23:30"), Fixture.Places.rome)
        let between = lib.photo(at: Fixture.date("2024-05-15 00:30"), nil)
        _ = lib.photo(at: Fixture.date("2024-05-15 01:00"), Fixture.Places.rome)
        lib.daily(from: "2024-05-15", to: "2024-05-17", at: Fixture.Places.rome, perDay: 6, hour: 10)
        let trip = try #require(detector.detect(in: lib.assets).first)
        #expect(trip.inferredAssetIDs.contains(between))
        let days = TripWorkshop.days(of: trip.geotaggedAssetIDs, dates: dates(lib), calendar: Fixture.calendar)
        let parts = detector.detect(in: lib.assets, corrections: TripCorrections().splitting(at: TripWorkshop.splitInstant(before: days[3])))
        #expect(parts.count == 2)
        #expect(parts.filter { $0.inferredAssetIDs.contains(between) }.count == 1)
        #expect(parts.last?.inferredAssetIDs.contains(between) == true)
    }

    // MARK: Waiting (UI run 44375768011)

    /// A split, a merge or "Aufheben" starts a check; until it ends, and while albums are made,
    /// the next change waits. Whenever it waits there is a reason to say, and only then.
    @Test func aChangeWaitsOnlyWithAReasonToSay() {
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false, check: false) == nil)
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: false, check: true) == nil)
        // The check a change starts (or one for new photos) is short: "Gleich wieder möglich".
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: true, check: true) == .tripsAgain)
        // The first analysis, or one that goes on after an interruption, can take long: no "gleich".
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: true, check: false) == .analysis)
        // Albums first: the check after them is said once they are made.
        #expect(TripWorkshop.wait(creatingAlbums: true, analysing: false, check: false) == .creatingAlbums)
        #expect(TripWorkshop.wait(creatingAlbums: true, analysing: true, check: true) == .creatingAlbums)
    }

    /// "Gleich wieder möglich" only for a check that is soon done (review of b240899): not for a
    /// check with work of its own (labels after "Themen" or "Dokumente", many new photos), and
    /// not for the overnight refinement, which runs without a kind of its own and keeps the last
    /// run's.
    @Test func onlyAShortCheckSaysSoon() {
        #expect(TripWorkshop.shortCheck(kind: true, newWork: false, refinement: false))
        #expect(!TripWorkshop.shortCheck(kind: true, newWork: true, refinement: false), "a check with new work said gleich")
        #expect(!TripWorkshop.shortCheck(kind: true, newWork: false, refinement: true), "the refinement said gleich")
        #expect(!TripWorkshop.shortCheck(kind: false, newWork: false, refinement: false))
        #expect(!TripWorkshop.shortCheck(kind: false, newWork: true, refinement: true))
        let labels = TripWorkshop.shortCheck(kind: true, newWork: true, refinement: false)
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: true, check: labels) == .analysis)
        let refinement = TripWorkshop.shortCheck(kind: true, newWork: false, refinement: true)
        #expect(TripWorkshop.wait(creatingAlbums: false, analysing: true, check: refinement) == .analysis)
    }

    /// A trip change during a Pause starts the run that goes on with the paused analysis
    /// (decision 18.11.2026), which can take tens of minutes; the sheet waited for it with no
    /// way to close (review of 163d656). It waits only for a short check, the run a change
    /// starts after a complete analysis; otherwise the change is saved and the sheet says so
    /// and can be closed. Also when no run started yet (one waits for a change in "Dein
    /// Zuhause" or for "Analyse neu aufbauen"): there was no end to wait for.
    @Test func aChangeWaitsInTheSheetOnlyForAShortCheck() {
        #expect(TripWorkshop.afterChange(running: true, check: true) == .waitHere)
        #expect(TripWorkshop.afterChange(running: true, check: false) == .savedForLater, "the sheet waited for a long run")
        #expect(TripWorkshop.afterChange(running: false, check: true) == .savedForLater, "the sheet waited for a run that never started")
        #expect(TripWorkshop.afterChange(running: false, check: false) == .savedForLater)
        // The same notion of "soon" as the note under the controls.
        for running in [false, true] {
            for check in [false, true] {
                let soon = TripWorkshop.wait(creatingAlbums: false, analysing: running, check: check) == .tripsAgain
                #expect((TripWorkshop.afterChange(running: running, check: check) == .waitHere) == soon)
            }
        }
    }

    /// Right after a split the merge row was off while the check ran, looked tappable and said
    /// nothing (the settings' "Reisen wieder automatisch erkennen" too). The model refuses a
    /// change exactly while `TripWorkshop.wait` gives a reason, both screens take their state
    /// from it and show the note next to the controls, and every reason is in the catalog with
    /// English. The App does not build on Linux, so its sources are read.
    @Test func waitingTripControlsSayWhyOnTheirScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let model = try source("App/Sortly/Model/AppModel.swift")
        let workshop = try source("App/Sortly/Views/TripWorkshopView.swift")
        let settings = try source("App/Sortly/Views/SettingsView.swift")
        // Booleans first: an expectation on `contains` would print the whole file.
        let modelUsesTheRule = model.contains("TripWorkshop.wait(")
        let refusesByTheRule = model.contains("tripChangeWait == nil else { return false }")
        #expect(modelUsesTheRule, "AppModel does not take the waiting from TripWorkshop.wait")
        #expect(refusesByTheRule, "changeTrips refuses for another reason than the screens say")
        for (name, view) in [("TripWorkshopView", workshop), ("SettingsView", settings)] {
            let showsTheNote = view.contains("TripChangeWaitNote(")
            let waitsSilently = view.contains(".disabled(model.analysis.isRunning")
            #expect(showsTheNote, "\(name): its trip controls wait without saying why")
            #expect(!waitsSilently, "\(name): waits for the analysis without saying why")
        }
        // Each part the screens rely on, so taking one back goes red (review of b240899).
        let tripChangeWait = try #require(AppSource.body(of: "var tripChangeWait:", in: model))
        let waitsForAlbums = tripChangeWait.contains("creatingAlbums: execution.isRunning")
        let waitsForTheRun = tripChangeWait.contains("analysing: analysis.isRunning")
        #expect(waitsForAlbums, "tripChangeWait does not wait while albums are made")
        #expect(waitsForTheRun, "tripChangeWait does not wait while an analysis runs")
        let busyByTheModel = workshop.contains("busy: Bool { model.tripChangeWait != nil }")
        #expect(busyByTheModel, "TripWorkshopView greys its controls for another reason than the model refuses")
        let resetByTheModel = settings.contains(".disabled(model.tripChangeWait != nil)")
        #expect(resetByTheModel, "SettingsView: the trip reset is not greyed while the model refuses")
        let mergeLabel = try #require(AppSource.body(of: "struct MergeRowLabel", in: workshop))
        let mergeLooksDisabled = mergeLabel.contains("@Environment(\\.isEnabled)") && mergeLabel.contains("isEnabled ?")
        #expect(mergeLooksDisabled, "the merge rows keep their accent colour while disabled")
        let mergeSection = try #require(AppSource.body(of: "func mergeSection(", in: workshop))
        let mergeFooter = mergeSection.components(separatedBy: "footer:").dropFirst().joined()
        let noteInTheMergeFooter = mergeFooter.contains("TripChangeWaitNote()")
        #expect(noteInTheMergeFooter, "the merge rows wait without the note in their footer")
        let catalog = try StringCatalogTests.catalog()
        for reason in ["Albumist rechnet die Reisen gerade neu. Gleich wieder möglich.",
                       "Albumist analysiert gerade deine Fotos. Danach wieder möglich.",
                       "Albumist legt gerade Alben an. Danach wieder möglich."] {
            let shown = workshop.contains("\"\(reason)\"")
            #expect(shown, "Not shown: \(reason)")
            let english = catalog[reason].flatMap { StringCatalogTests.localization($0, "en") }
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
            #expect(english?.isEmpty == false, "Not in the catalog with English: \(reason)")
        }
    }

    /// A trip change during a Pause starts the run that goes on with the paused analysis
    /// (decision 18.11.2026): the sheet waits only for a short check and otherwise says the
    /// change is saved and can be closed; "gleich" only for a short check, the refinement too;
    /// VoiceOver says on each greyed control why it waits; the confirmations say that the paused
    /// analysis goes on (review of 163d656). The App does not build on Linux, so its sources are
    /// read; each check goes red when its part is taken back.
    @Test func aChangeDuringAPauseLeavesTheSheetFreeAndSaysSo() throws {
        let model = try AppSource.read("App/Sortly/Model/AppModel.swift")
        let workshop = try AppSource.read("App/Sortly/Views/TripWorkshopView.swift")
        let settings = try AppSource.read("App/Sortly/Views/SettingsView.swift")
        func body(_ declaration: String, in source: String) throws -> String {
            try #require(AppSource.body(of: declaration, in: source), "no \(declaration)")
        }
        // The model: what a short check is, for the note and for the sheet alike.
        let shortCheck = try body("var runIsShortCheck:", in: model)
        let checkByTheRule = shortCheck.contains(
            "TripWorkshop.shortCheck(kind: analysis.kind == .check, newWork: analysis.newWork != nil, refinement: analysis.isRefinement)")
        #expect(checkByTheRule, "runIsShortCheck does not take the kind, the new work and the refinement")
        let waitUsesIt = try body("var tripChangeWait:", in: model).contains("check: runIsShortCheck")
        #expect(waitUsesIt, "tripChangeWait says gleich for every check")
        let afterChange = try body("var afterTripChange:", in: model)
        let afterByTheRule = afterChange.contains("TripWorkshop.afterChange(running: analysis.isRunning, check: runIsShortCheck)")
        #expect(afterByTheRule, "afterTripChange does not follow TripWorkshop.afterChange")
        let refinement = try body("func refinePass(", in: model)
        let refinementMarked = refinement.contains("analysis.isRefinement = true") && refinement.contains("analysis.isRefinement = false")
        #expect(refinementMarked, "the refinement does not mark itself, and reads as a check")

        // The sheet: waits only when the model says so, else saved and free to close.
        let perform = try body("func perform(", in: workshop)
        let sheetAsksTheModel = perform.contains("switch model.afterTripChange") && perform.contains("case .savedForLater")
        #expect(sheetAsksTheModel, "the sheet waits for every run a change starts")
        let saysSaved = workshop.contains("Text(\"Gespeichert. Albumist wendet die Änderung an, sobald die Analyse fertig ist.\")")
        #expect(saysSaved, "the sheet does not say the change is saved")
        let closeWhenSaved = workshop.contains("if working == nil && (done == nil || saved)")
        #expect(closeWhenSaved, "the sheet cannot be closed once the change is saved")

        // VoiceOver: each greyed control says why it waits.
        let hint = try body("func tripChangeWaitHint(", in: workshop)
        let hintSaysWhy = hint.contains("accessibilityHint(") && hint.contains("TripChangeWaitNote.reason(")
        #expect(hintSaysWhy, "the hint does not say the reason of the note")
        let greyed = try Regex(#"\.disabled\(busy\)"#)
        let greyedWithHint = try Regex(#"\.disabled\(busy\)\s*\.tripChangeWaitHint\(model\.tripChangeWait\)"#)
        let workshopGreyed = workshop.matches(of: greyed).count
        #expect(workshopGreyed == 3)
        #expect(workshop.matches(of: greyedWithHint).count == workshopGreyed, "TripWorkshopView: a greyed control does not say why to VoiceOver")
        let resetWithHint = try Regex(#"\.disabled\(model\.tripChangeWait != nil\)\s*\.tripChangeWaitHint\(model\.tripChangeWait\)"#)
        #expect(settings.matches(of: resetWithHint).count == 1, "SettingsView: the greyed trip reset does not say why to VoiceOver")

        // The confirmations say that the paused analysis goes on.
        let merge = try body("func mergeButton(", in: workshop)
        let mergeSaysIt = merge.contains("if model.analysis.isPausedByUser")
            && merge.contains("Fotos. Die pausierte Analyse läuft dann weiter.\")")
        #expect(mergeSaysIt, "the merge confirmation does not say that the paused analysis goes on")
        let resetSaysIt = settings.contains("if model.analysis.isPausedByUser")
            && settings.contains("Schon angelegte Alben bleiben, wie sie sind. Die pausierte Analyse läuft dann weiter.\")")
        #expect(resetSaysIt, "the trip reset confirmation does not say that the paused analysis goes on")

        let catalog = try StringCatalogTests.catalog()
        for key in ["Gespeichert. Albumist wendet die Änderung an, sobald die Analyse fertig ist.",
                    "„%@“ und „%@“ werden eine Reise mit %lld Fotos. Die pausierte Analyse läuft dann weiter.",
                    "Albumist vergisst, welche Reisen du geteilt oder zusammengelegt hast. Schon angelegte Alben bleiben, wie sie sind. Die pausierte Analyse läuft dann weiter."] {
            let english = catalog[key].flatMap { StringCatalogTests.localization($0, "en") }
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
            #expect(english?.isEmpty == false, "Not in the catalog with English: \(key)")
        }
    }
}
