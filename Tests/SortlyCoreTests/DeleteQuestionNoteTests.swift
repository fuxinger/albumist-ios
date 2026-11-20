import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

/// Before Albumist deletes albums or folders in Photos, iOS asks once more ("delete 15 albums
/// and 9 folders"). Albumist's own question before it did not say so, and the word "delete"
/// scared (review 18.11., P3-07 / G3-09). Every confirmation that leads there now announces
/// it, with one sentence (`DeleteQuestionNote`), and only when the plan really deletes one.
/// The confirmations are found by what they call, not by line numbers.
@Suite("Announcing the iOS question before albums are deleted")
struct DeleteQuestionNoteTests {
    static let german = "iOS fragt gleich noch einmal, ob Albumist die Alben löschen darf. Deine Fotos bleiben."
    static let english = "iOS will ask once more whether Albumist may delete the albums. Your photos stay."
    /// What the views use to say it.
    static let note = "DeleteQuestionNote"
    /// The ways into the plan executor that can delete albums or folders: an undo, the undo of
    /// an interrupted plan, and the removal of one of Albumist's albums.
    static let deletingCalls = ["undo(", "undoInterruptedPlan(", "removalPlan("]
    /// The ways that run such a plan without a dialog of their own: going on with an
    /// interrupted undo ("Rest zurücknehmen"), and carrying out a plan built elsewhere (the
    /// removal of an album, "Fehlendes erneut versuchen" of an undo) in the preview.
    static let directCalls = ["resumeInterruptedPlan(", "execute("]

    // MARK: Only when albums are deleted

    static let done = StepState.succeeded(createdID: nil, verifiedAt: Date(timeIntervalSince1970: 1))

    static func plan(_ steps: [PlanStep], resolved: [String: CollectionID] = [:], record: ExecutionRecord? = nil) -> ChangePlan {
        var p = ChangePlan(id: SortlyID("first"), createdAt: Date(), confirmedAt: Date(), status: .completed, baseline: [:],
                           baselineCollectionIDs: [], steps: steps, conflicts: [], notes: [], resolvedKeys: resolved)
        p.record = record
        return p
    }

    /// An undo of a plan that made an album deletes it: iOS asks.
    @Test func undoOfANewAlbumDeletesIt() {
        let made = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .addAssets(album: .planned("A"), assets: ["x"]), sourceID: nil, state: Self.done),
        ], resolved: ["A": "a1"])
        let current = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x"])])
        let undo = UndoPlanner().undoPlan(for: made, current: current, owned: ["a1": ["x"]])
        #expect(undo.deletesCollections)
    }

    /// An undo that only takes photos out of the user's own album deletes nothing: no word about
    /// deleting. So does an album the user put photos of their own into: it stays.
    @Test func undoThatOnlyTakesPhotosOutDeletesNothing() {
        let extended = Self.plan([
            PlanStep(id: "0", operation: .addAssets(album: .existing("mine"), assets: ["x"]), sourceID: nil, state: Self.done),
        ])
        let current = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["own", "x"])])
        let undo = UndoPlanner().undoPlan(for: extended, current: current, owned: ["mine": ["x"]])
        #expect(!undo.steps.isEmpty)
        #expect(!undo.deletesCollections)

        let made = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .succeeded(createdID: "a1", verifiedAt: Date())),
            PlanStep(id: "1", operation: .addAssets(album: .planned("A"), assets: ["x"]), sourceID: nil, state: Self.done),
        ], resolved: ["A": "a1"])
        let filledByUser = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom", assetIDs: ["x", "own"])])
        #expect(!UndoPlanner().undoPlan(for: made, current: filledByUser, owned: ["a1": ["x"]]).deletesCollections)
    }

    /// An interrupted undo ("Rest zurücknehmen") says it while a deletion is still open, not
    /// after it ran.
    @Test func onlyOpenDeletionsCount() {
        var undo = Self.plan([
            PlanStep(id: "0", operation: .removeAssets(album: "mine", assets: ["x"]), sourceID: nil, state: Self.done),
            PlanStep(id: "1", operation: .deleteCollection("a1", title: "Rom"), sourceID: nil, state: .pending),
        ])
        #expect(undo.deletesCollections)
        undo.steps[1].state = Self.done
        #expect(!undo.deletesCollections)
    }

    /// "Alles zurücknehmen" of an interrupted plan: the album whose step was cut off counts when
    /// it is there under the id Photos gave it, as the undo will settle it.
    @Test func undoOfAnInterruptedPlanCountsTheAlbumMadeBeforeTheInterruption() {
        let current = CollectionInventory([CollectionSnapshot(id: "a1", title: "Rom")])
        let cutOff = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], resolved: ["A": "a1"])
        #expect(InterruptedPlanUndo.deletesCollections(interrupted: cutOff, current: current))
        var noted = ExecutionRecord()
        noted.maybeCreated["A"] = "a1"
        let unanswered = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ], record: noted)
        #expect(InterruptedPlanUndo.deletesCollections(interrupted: unanswered, current: current))
        // Nothing made yet: nothing to delete.
        let nothingYet = Self.plan([
            PlanStep(id: "0", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .running(startedAt: Date())),
        ])
        #expect(!InterruptedPlanUndo.deletesCollections(interrupted: nothingYet, current: CollectionInventory()))
        // Only photos added to the user's album before the interruption: taken out, nothing deleted.
        let onlyAdded = Self.plan([
            PlanStep(id: "0", operation: .addAssets(album: .existing("mine"), assets: ["x"]), sourceID: nil, state: Self.done),
            PlanStep(id: "1", operation: .createAlbum(key: "A", title: "Rom", parent: .topLevel), sourceID: nil, state: .pending),
        ])
        let mine = CollectionInventory([CollectionSnapshot(id: "mine", title: "Familie", assetIDs: ["own", "x"])])
        #expect(!InterruptedPlanUndo.deletesCollections(interrupted: onlyAdded, current: mine))
    }

    // MARK: Reading the App

    private struct Dialog {
        var file: String
        var line: Int
        var action: String
        var message: String
    }

    private static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    /// The index just past the bracket that closes the one at `open`, in code with comments and
    /// strings blanked.
    private static func closing(_ code: [Unicode.Scalar], from open: Int) -> Int? {
        let opening = code[open]
        let close: Unicode.Scalar = opening == "(" ? ")" : "}"
        var depth = 0
        for index in open..<code.count {
            if code[index] == opening { depth += 1 }
            if code[index] == close {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
        }
        return nil
    }

    private static func skipSpaces(_ code: [Unicode.Scalar], _ index: Int) -> Int {
        var i = index
        while i < code.count, code[i] == " " || code[i] == "\n" || code[i] == "\t" { i += 1 }
        return i
    }

    /// Every `.confirmationDialog(…) { actions } message: { message }` of the App's views: its
    /// buttons and its message, as code (comments and strings blanked).
    private static func dialogs() throws -> [Dialog] {
        var found: [Dialog] = []
        for file in AppSource.swiftFiles(under: "App/Sortly") {
            let source = try AppSource.read(file)
            let code = scalars(AppSource.code(source))
            for site in AppSource.callSites(of: "confirmationDialog(", in: source) {
                let open = site.offset + "confirmationDialog".unicodeScalars.count
                guard let argumentsEnd = closing(code, from: open) else { continue }
                let actionStart = skipSpaces(code, argumentsEnd)
                guard actionStart < code.count, code[actionStart] == "{", let actionEnd = closing(code, from: actionStart) else { continue }
                var messageStart = skipSpaces(code, actionEnd)
                let label = Array("message:".unicodeScalars)
                guard messageStart + label.count <= code.count, Array(code[messageStart..<(messageStart + label.count)]) == label else {
                    found.append(Dialog(file: file, line: line(of: site.offset, in: code), action: string(code[actionStart..<actionEnd]), message: ""))
                    continue
                }
                messageStart = skipSpaces(code, messageStart + label.count)
                guard code[messageStart] == "{", let messageEnd = closing(code, from: messageStart) else { continue }
                found.append(Dialog(file: file, line: line(of: site.offset, in: code),
                                    action: string(code[actionStart..<actionEnd]), message: string(code[messageStart..<messageEnd])))
            }
        }
        return found
    }

    private static func line(of offset: Int, in code: [Unicode.Scalar]) -> Int {
        code[..<offset].filter { $0 == "\n" }.count + 1
    }

    /// Whether `code` calls one of `calls`, directly or through a function declared in `source`
    /// (the album removal's button calls `prepare(state)`, which asks for `removalPlan(`).
    private static func reaches(_ calls: [String], from code: String, in source: String) -> Bool {
        if calls.contains(where: { !AppSource.calls(of: $0, in: code).isEmpty }) { return true }
        let names = Set(code.matches(of: /([A-Za-z_][A-Za-z0-9_]*)\(/).map { String($0.output.1) })
        return names.contains { name in
            guard let body = AppSource.body(of: "func \(name)(", in: source) else { return false }
            return calls.contains { !AppSource.calls(of: $0, in: body).isEmpty }
        }
    }

    // MARK: Tests

    /// Every confirmation whose button leads to an undo or a removal says that iOS asks next.
    @Test func everyConfirmationBeforeDeletingAlbumsAnnouncesTheIOSQuestion() throws {
        var deleting: [String] = []
        for dialog in try Self.dialogs() {
            let source = try AppSource.read(dialog.file)
            guard Self.reaches(Self.deletingCalls, from: dialog.action, in: source) else { continue }
            let place = "\(dialog.file.split(separator: "/").last ?? ""):\(dialog.line)"
            deleting.append(place)
            #expect(dialog.message.contains(Self.note), "\(place): the confirmation does not announce the iOS question")
        }
        // The confirmations the review names, and the one on the result card: none is lost by a
        // change in how they are written.
        let files = Set(deleting.map { $0.split(separator: ":").first.map(String.init) ?? "" })
        for named in ["PlanReceiptView.swift", "OverviewView.swift", "SettingsView.swift", "ManagedAlbumsView.swift", "PlanReviewView.swift"] {
            #expect(files.contains(named), "no confirmation before deleting found in \(named): \(deleting)")
        }
        #expect(deleting.count >= 5, "\(deleting)")
    }

    /// The ways that delete without a dialog of their own (going on with an interrupted undo,
    /// carrying out a removal in the preview) say it on the screen that has the button.
    @Test func screensThatDeleteWithoutADialogAnnounceTheIOSQuestion() throws {
        var checked: [String] = []
        for file in AppSource.swiftFiles(under: "App/Sortly/Views") {
            let source = try AppSource.read(file)
            let code = Self.scalars(AppSource.code(source))
            for call in Self.directCalls {
                for site in AppSource.callSites(of: call, in: source) {
                    // The innermost type around the call.
                    var enclosing: Range<Int>?
                    for match in AppSource.code(source).matches(of: /(?m)^\s*(?:private |fileprivate )?struct ([A-Za-z0-9_]+)/) {
                        guard let range = AppSource.bodyRange(of: "struct \(match.output.1)", in: source),
                              range.contains(site.offset) else { continue }
                        if enclosing.map({ range.count < $0.count }) ?? true { enclosing = range }
                    }
                    let body = try #require(enclosing.map { Self.string(code[$0]) }, "\(file): \(call) outside a view")
                    let place = "\(file.split(separator: "/").last ?? ""):\(Self.line(of: site.offset, in: code))"
                    checked.append(place)
                    #expect(body.contains(Self.note), "\(place): \(call) without announcing the iOS question")
                }
            }
        }
        #expect(checked.count >= 3, "\(checked)")
    }

    /// One sentence, in German and English, kept in one place.
    @Test func theSentenceIsOneStringWithEnglish() throws {
        let file = try #require(AppSource.swiftFiles(under: "App/Sortly").first {
            (try? AppSource.code(AppSource.read($0)).contains("enum \(Self.note)")) == true
        }, "no enum \(Self.note) in the App")
        let source = AppSource.code(try AppSource.read(file), keepStrings: true)
        #expect(source.contains("\"\(Self.german)\""))
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: AppSource.root.appendingPathComponent("App/Sortly/Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let entry = try #require(strings[Self.german] as? [String: Any])
        let english = ((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        #expect(english?["value"] as? String == Self.english)
        // Said only here: no second wording of the same sentence in the views.
        for other in AppSource.swiftFiles(under: "App/Sortly") where other != file {
            #expect(!AppSource.code(try AppSource.read(other), keepStrings: true).contains(Self.german), "\(other)")
        }
    }
}
