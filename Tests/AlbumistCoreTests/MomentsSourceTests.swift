import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The two moments of design wave 2 (Scheibe 3) as the App draws them: the stack of covers above
/// the result (draft E3) and the cover that flies into "Alben" after "Anlegen" on a card (draft
/// E6). What they decide is core and tested as such (`ResultCoverStackTests`,
/// `QuickCreateMomentTests`); the App does not build on Linux, so these tests read its code
/// (`AppSource`). On a Mac the UI tests see the result and the banner; the feel of both moments
/// is a device check.
@Suite("Moments in the App: the result's stack and the cover that flies")
struct MomentsSourceTests {
    static let review = "App/Albumist/Views/PlanReviewView.swift"
    static let show = "App/Albumist/Views/SortingShow.swift"
    static let stack = "App/Albumist/Views/Moments/ResultCoverMoment.swift"
    static let layer = "App/Albumist/Views/Moments/QuickCreateMomentLayer.swift"
    static let sources = "App/Albumist/Views/Moments/QuickCreateMomentSources.swift"
    static let model = "App/Albumist/Model/AppModel+Moments.swift"
    static let tabs = "App/Albumist/Views/RootView.swift"
    static let banner = "App/Albumist/Views/Frame/QuickCreateBar.swift"
    static let start = "App/Albumist/Views/Start/StartSections.swift"
    static let list = "App/Albumist/Views/ProposalViews.swift"
    static let overview = "App/Albumist/Views/OverviewView.swift"
    static let card = "App/Albumist/DesignSystem/PhotoCard.swift"
    static let cover = "App/Albumist/DesignSystem/CoverPhoto.swift"
    static let mark = "// Design W2 H6: moment source"
    static let trailMark = "// Design W2 H6: scroll trail"

    /// A file without comments, strings kept.
    static func code(_ path: String) throws -> String {
        AppSource.code(try AppSource.read(path), keepStrings: true)
    }

    static func body(_ path: [String], in file: String) throws -> String {
        try #require(AppSource.body(of: path, in: file), "\(path) is not there")
    }

    static func count(_ text: String, in code: String) -> Int {
        code.components(separatedBy: text).count - 1
    }

    // MARK: The big moment (draft E3)

    /// The covers lie above the count on the screen's ground (no card around the result), the
    /// count, "Fotos-App öffnen", "Alle Änderungen" and "Rückgängig machen" below them; the stack
    /// takes only the height they leave (review E of design wave 2, finding 8). It is worked out
    /// once per plan as the result shows and kept, never in the card's body (finding 7).
    @Test func theStackLiesAboveTheCount() throws {
        let file = try Self.code(Self.review)
        let card = try Self.body(["struct ResultCard"], in: file)
        let body = try Self.body(["struct ResultCard", "var body: some View"], in: file)
        let moment = try #require(body.range(of: "moment(headline"), "\(body)")
        let essentials = try #require(body.range(of: "essentials(receipt"), "\(body)")
        let more = try #require(body.range(of: "more(undoNote"), "\(body)")
        #expect(moment.lowerBound < essentials.lowerBound && essentials.lowerBound < more.lowerBound)
        #expect(!card.contains("Card {"), "the result still stands in a card")
        let stack = try Self.body(["struct ResultCard", "func moment("], in: file)
        #expect(stack.contains("ResultCoverMoment(plan: plan, sources: sources"), "\(stack)")
        #expect(stack.contains("room: stackRoom") && stack.contains("onSettled: onMoment"), "\(stack)")
        #expect(!card.contains("resultCoverStack("), "the card works the stack out in its body")
        let covers = try Self.code(Self.stack)
        let view = try Self.body(["struct ResultCoverMoment", "var body: some View"], in: covers)
        #expect(view.contains(".onChange(of: plan.id, initial: true) { make() }"), "\(view)")
        let make = try Self.body(["struct ResultCoverMoment", "func make()"], in: covers)
        for part in ["guard madeFor != plan.id else { return }", "model.resultCoverStack(for: plan, taken: sources)",
                     "ResultMomentLoader.kept(stack, held: held, plan: plan.id, scale: displayScale)", "madeFor = plan.id"] {
            #expect(make.contains(part), "\(part): \(make)")
        }
        let kept = try Self.body(["struct ResultCard", "func essentials("], in: file)
        #expect(kept.contains("ResultLead(headline: headline"), "\(kept)")
        #expect(kept.contains("photosButton"), "\(kept)")
        let photos = try Self.body(["struct ResultCard", "var photosButton: some View"], in: file)
        #expect(photos.contains("Button(\"Fotos-App öffnen\")") && photos.contains(".buttonStyle(PrimaryButtonStyle())"), "\(photos)")
        // Everything below the stack is measured and stays in view; the screen's height is the
        // scroll view's.
        #expect(body.contains(/belowHeight\s*=\s*\$0/), "\(body)")
        let below = try #require(body.range(of: "belowHeight"))
        #expect(body[..<below.lowerBound].contains("more(undoNote"), "\"Alle Änderungen\" and \"Rückgängig machen\" are not measured")
        let room = try Self.body(["struct ResultCard", "var stackRoom: CGFloat?"], in: file)
        #expect(room.contains("2 * screenPadding") && room.contains("belowHeight"), "\(room)")
        // Not measured yet is nil, until both the screen and everything below the stack are
        // measured: the fan is laid out at its smallest size meanwhile and can only grow (review
        // E2 of design wave 2, N7).
        #expect(room.contains("guard let room, let belowHeight else { return nil }"), "\(room)")
        #expect(card.contains("@State private var belowHeight: CGFloat?"), "the block below the stack counts as measured before it is")
        let screen = try Self.body(["struct ResultCard", "var screenHeight: some View"], in: file)
        #expect(screen.contains(/\.containerRelativeFrame\(\s*\.vertical\s*\)/), "\(screen)")
        // The screen hands the result the padding it puts around it, as it does to the show.
        let handed = try Self.body(["struct PlanReviewView", "func resultCard("], in: file)
        #expect(handed.contains("screenPadding: Self.contentPadding"), "\(handed)")
    }

    /// The stack is decorative: never tapped, hidden from VoiceOver (the count is the heading).
    /// With Reduce Motion the covers only fade in where they lie (and in the UI tests, whose
    /// picture of the result is taken a second after it shows). Fewer covers at the largest
    /// text, and the fan scales to the room it has.
    @Test func theStackIsDecorativeAndCalm() throws {
        let file = try Self.code(Self.stack)
        let fan = try Self.body(["struct ResultCoverMoment", "var fanArea: some View"], in: file)
        #expect(fan.contains(".allowsHitTesting(false)") && fan.contains(".accessibilityHidden(true)"), "\(fan)")
        let symbol = try Self.body(["struct ResultCoverMoment", "var symbolView: some View"], in: file)
        #expect(symbol.contains(".accessibilityHidden(true)"), "\(symbol)")
        let laid = try Self.body(["struct FannedCover", "var body: some View"], in: file)
        #expect(laid.contains("let rise: CGFloat = down || calm ? 0 : 1"), "\(laid)")
        #expect(laid.contains(".opacity(down ? 1 : 0)"), "\(laid)")
        let calm = try Self.body(["struct ResultCoverMoment", "var calm: Bool"], in: file)
        #expect(calm.contains("reduceMotion || UITestSupport.isRunning"), "\(calm)")
        let play = try Self.body(["struct ResultCoverMoment", "func play()"], in: file)
        let fades = try #require(AppSource.body(of: "if calm", in: play), "\(play)")
        #expect(fades.contains("withAnimation(.easeOut(duration: ResultCoverFan.fadeIn))") && !fades.contains("spring"), "\(fades)")
        // The core's times: the main cover lies within `ResultCoverFan.settleTime`.
        #expect(play.contains("ResultCoverFan.layingStep") && play.contains("ResultCoverFan.lastFall"), "\(play)")
        #expect(file.contains("down: position < laid, calm: calm)"))
        let limit = try Self.body(["struct ResultCoverMoment", "var limit: Int"], in: file)
        #expect(limit.contains("typeSize.isAccessibilitySize ? ResultCoverStack.limitAtLargestText : ResultCoverStack.limit"))
        let scale = try Self.body(["struct ResultCoverMoment", "func fanScale("], in: file)
        #expect(scale.contains("ResultCoverFan.scale(count:") && scale.contains("room"), "\(scale)")
        // An unmeasured room is the smallest scale (the core's), never the full size (review E2
        // of design wave 2, N7: the count jumped up as the fan shrank in the first frames).
        #expect(scale.contains("height: room.map { Double($0) }") && !scale.contains(".infinity"), "\(scale)")
        // No room held for covers that may come: the fan is as high as what it shows (finding 9).
        #expect(!file.contains("heldHeight") && !file.contains("expected"), "the stack still holds room while it loads")
        // No glow, no confetti: a white edge and a soft shadow.
        #expect(!file.contains("blur(") && !file.contains("confetti") && !file.contains(".glow"))
    }

    /// The covers come only from the device, through the cards' own loader (`CoverLoader`, which
    /// keeps only sharp ones), never from iCloud; the flying cover is the very image its card
    /// keeps. No second image loader. They load while the plan runs; the result takes them from
    /// the covers' store and never waits for Photos (review E of design wave 2, finding 1).
    @Test func theCoversComeOnlyFromTheDevice() throws {
        for path in [Self.stack, Self.layer, Self.sources] {
            let file = try Self.code(path)
            for loader in ["PHImageManager", "PHCachingImageManager", "requestImage", "isNetworkAccessAllowed", "ThumbnailRequest"] {
                #expect(!file.contains(loader), "\(path) asks Photos itself: \(loader)")
            }
        }
        let stack = try Self.code(Self.stack)
        // Side by side, as the core decides (review E2 of design wave 2, N3): a few cards at once
        // in the stack's order, a card Photos did not answer for comes back later, and the
        // loading stops once the stack is decided, cancelled or out of patience.
        let load = try Self.body(["enum ResultMomentLoader", "static func prefetch("], in: stack)
        for part in ["withTaskGroup(of: ResultCoverPrefetch.Arrival.self)", "ResultCoverPrefetch(cards: stack.cards.map(\\.id))",
                     "while let start = loading.next()", "loading.record(arrival)", "!loading.isDecided", "!Task.isCancelled",
                     "prefetchPatience", "group.cancelAll()", "CoverLoader.Request(ids: candidates[start.card] ?? [], pixels: pixels)",
                     "await ThumbnailCache.shared.lookUp("] {
            #expect(load.contains(part), "\(part): \(load)")
        }
        let fetch = try Self.body(["enum ResultMomentLoader", "static func fetch("], in: stack)
        for part in ["await CoverLoader.load(request)", "Task.isCancelled", "try? await Task.sleep(for: retryDelay)",
                     "held.keep(ResultMomentCover(", "ThumbnailCache.shared.cachedCover(for: $0, pixels: request.pixels)"] {
            #expect(fetch.contains(part), "\(part): \(fetch)")
        }
        // Kept as they arrive in the result's own state, not observed (nothing is drawn again).
        #expect(stack.contains("@MainActor\nfinal class ResultMomentCovers {"), "the kept covers are observed, or not a class")
        #expect(stack.contains("static func kept(_ stack: ResultCoverStack, held: ResultMomentCovers?, plan: AlbumistID, scale: CGFloat) -> [ResultMomentCover] {"),
                "the result's covers are not taken from what was kept at once")
        let fromStore = try Self.body(["enum ResultMomentLoader", "static func kept("], in: stack)
        #expect(fromStore.contains("stack.sharpPhotos(held: ahead)"), "\(fromStore)")
        #expect(fromStore.contains("ThumbnailCache.shared.cachedCover(for: $0, pixels: pixels)"), "\(fromStore)")
        #expect(!fromStore.contains("await"), "\(fromStore)")
        // The view itself never asks Photos: its only waits are the covers lying down.
        let view = try Self.body(["struct ResultCoverMoment"], in: stack)
        for asks in ["CoverLoader.load", "ResultMomentLoader.prefetch", "ResultMomentLoader.load"] {
            #expect(!view.contains(asks), "the result waits for Photos: \(asks)")
        }
        let waits = view.components(separatedBy: "await ").dropFirst().map { String($0.prefix(10)) }
        #expect(waits.allSatisfy { $0.hasPrefix("Task.sleep") || $0.hasPrefix("play()") }, "\(waits)")
        let sources = try Self.code(Self.sources)
        let kept = try Self.body(["final class QuickCreateMomentSources", "func keptCover("], in: sources)
        #expect(kept.contains("QuickCreateMoment.coverPixels(") && kept.contains("ThumbnailCache.shared.cachedCover("), "\(kept)")
        #expect(kept.contains("prefix(CoverLoader.attempts)"), "\(kept)")
        // The size the card asked for: `coverPixels` follows `CoverPhoto` and `PhotoCard`.
        let cover = try Self.code(Self.cover)
        let request = try Self.body(["struct CoverPhoto", "var request: CoverLoader.Request?"], in: cover)
        #expect(request.contains("width.rounded(.up)") && request.contains("(width / aspectRatio).rounded(.up)"), "\(request)")
        #expect(request.contains("displayScale"), "\(request)")
        let card = try Self.code(Self.card)
        let shown = try Self.body(["var shownAspectRatio: CGFloat"], in: card)
        #expect(shown.contains("typeSize.isAccessibilitySize ? max(aspectRatio, 3) : aspectRatio"), "\(shown)")
    }

    /// Personal content never shows: a sensitive suggestion's or a hidden preview's photo is
    /// neither on the stack nor flies. What the result knows of the suggestions is taken as the
    /// plan starts; a suggestion the analysis does not know is taken as personal, at the start as
    /// later (`ResultCoverStack.personalSources`, review E of design wave 2, finding 10).
    @Test func personalContentNeverShows() throws {
        let model = try Self.code(Self.model)
        let taken = try Self.body(["func resultCoverSources("], in: model)
        #expect(taken.contains("proposal.isSensitive || previewHidden(for: proposal)"), "\(taken)")
        #expect(taken.contains("known.insert(proposal.id)") && taken.contains("personal.insert(proposal.id)"), "\(taken)")
        #expect(taken.contains("ResultCoverStack.personalSources(of: plan, known: known, personal: personal)"), "\(taken)")
        let stack = try Self.body(["func resultCoverStack("], in: model)
        #expect(stack.contains("taken.plan == plan.id"), "\(stack)")
        #expect(stack.contains("resultCoverSources(for: plan)"), "\(stack)")
        #expect(!stack.contains(".subtracting("), "the stack decides personal sources a second way: \(stack)")
        #expect(stack.contains("personalSources: sources.personal"), "\(stack)")
        let sources = try Self.code(Self.sources)
        let photo = try Self.body(["final class QuickCreateMomentSources", "func photo(for"], in: sources)
        #expect(photo.contains("proposal.isSensitive || model.previewHidden(for: proposal)"), "\(photo)")
        #expect(photo.contains("personal ? nil : keptCover("), "\(photo)")
        // The card's own suggestion, whether or not the analysis still has it as the banner comes.
        #expect(photo.contains("let proposal = source.proposal") && !photo.contains("model.proposals"), "\(photo)")
        // As the card shows it now: a suggestion the analysis updates in place while its card
        // rests is noted anew, so the flying photo is never an older cover (review E2 of design
        // wave 2, N5).
        let layer = try Self.code(Self.layer)
        let source = try Self.body(["struct QuickCreateMomentSource:", "func body(content: Content)"], in: layer)
        let changed = try #require(AppSource.body(of: ".onChange(of: proposal)", in: source), "\(source)")
        #expect(changed.contains("if let frame { note(frame) }"), "\(changed)")
    }

    /// One success tap per run, as before: it waits for the show's end and then for the main
    /// cover to lie down (or the symbol to show), but never longer than
    /// `ResultCoverFan.successDeadline` once the result shows; a run without a result lets it go
    /// at once, and the covers loaded ahead stop loading then (review E of design wave 2,
    /// findings 1, 11 and 15). The stack makes no haptic of its own.
    @Test func theSuccessTapWaitsForTheMoment() throws {
        let file = try Self.code(Self.review)
        #expect(Self.count(".sensoryFeedback(", in: file) == 2, "the result screen has haptics of its own")
        #expect(file.contains("ExecutionHaptics(execution: model.execution, holdSuccess: show != nil || momentPending)"))
        let begin = try Self.body(["struct PlanReviewView", "func beginMoment("], in: file)
        for part in ["momentPending = true", "coverSources = sources",
                     "model.resultCoverStack(for: plan, taken: sources, expected: true)", "prefetch?.cancel()",
                     "covers.start(id)",
                     "prefetch = Task { await ResultMomentLoader.prefetch(stack, plan: id, scale: scale, keepingIn: covers) }"] {
            #expect(begin.contains(part), "\(part): \(begin)")
        }
        // The covers that arrive are the screen's own, kept while the result shows (review E2 of
        // design wave 2, N3).
        #expect(file.contains("@State private var momentCovers = ResultMomentCovers()"))
        let handed = try Self.body(["struct PlanReviewView", "func resultCard("], in: file)
        #expect(handed.contains("held: momentCovers"), "\(handed)")
        let moment = try Self.body(["struct ResultCard", "func moment("], in: file)
        #expect(moment.contains("held: held"), "\(moment)")
        let end = try Self.body(["struct PlanReviewView", "func endMoment()"], in: file)
        for part in ["momentPending = false", "prefetch?.cancel()", "prefetch = nil"] {
            #expect(end.contains(part), "\(part): \(end)")
        }
        let button = try Self.body(["struct PlanReviewView", "func applyButton("], in: file)
        // Taken once as the plan starts, for the show and the stack (second review of H13, K10).
        #expect(button.contains("let sources = model.resultCoverSources(for: plan)"), "\(button)")
        #expect(button.contains("beginMoment(plan, sources: sources)"), "\(button)")
        // A plan that did not start, or stopped with an error, has no result: the tap goes.
        let notTaken = try #require(button.range(of: "freshness.notTaken()"))
        #expect(button[notTaken.upperBound...].prefix(120).contains("if model.execution.finished?.id != plan.id { endMoment() }"),
                "\(button)")
        let result = try Self.body(["struct PlanReviewView", "func resultCard("], in: file)
        #expect(result.contains("endMoment()"), "\(result)")
        // A real deadline once the result shows, which also ends the loading ahead.
        let body = try Self.body(["struct PlanReviewView", "var body: some View"], in: file)
        #expect(body.contains(".task(id: momentDue) { await holdMomentAtMost() }"), "\(body)")
        let due = try Self.body(["struct PlanReviewView", "var momentDue: AlbumistID?"], in: file)
        for part in ["momentPending", "show == nil", "!model.execution.isRunning", "model.execution.finished?.id"] {
            #expect(due.contains(part), "\(part): \(due)")
        }
        let hold = try Self.body(["struct PlanReviewView", "func holdMomentAtMost()"], in: file)
        let cancel = try #require(hold.range(of: "prefetch?.cancel()"), "\(hold)")
        let sleep = try #require(hold.range(of: "try? await Task.sleep(for: .seconds(ResultCoverFan.successDeadline))"), "\(hold)")
        let ends = try #require(hold.range(of: "endMoment()", options: .backwards), "\(hold)")
        #expect(cancel.lowerBound < sleep.lowerBound && sleep.upperBound <= ends.lowerBound, "\(hold)")
        let stack = try Self.code(Self.stack)
        #expect(!stack.contains("sensoryFeedback"), "the stack has a haptic of its own")
        let settle = try Self.body(["struct ResultCoverMoment", "func settle("], in: stack)
        #expect(settle.contains("onSettled()"))
        #expect(Self.count("onSettled()", in: stack) == 1, "the moment is told settled only once per plan")
        #expect(settle.contains("guard settledFor != plan.id else { return }"), "\(settle)")
    }

    /// "Animation überspringen" and the show's own end hand over to the same result: one
    /// `onFinish`, which ends the show; the result depends only on the plan. The show's counter
    /// ends on the receipt's count (`confirmedAddedMedia`).
    @Test func skippingTheShowEndsOnTheSameResult() throws {
        let show = try Self.code(Self.show)
        let skip = try Self.body(["struct SortingShow", "var skip: some View"], in: show)
        #expect(skip.contains("Button(\"Animation überspringen\", action: onFinish)"), "\(skip)")
        #expect(show.contains("let applied = finished.confirmedAddedMedia"))
        #expect(!show.contains("appliedAssets"), "the show still counts what the receipt does not")
        let review = try Self.code(Self.review)
        let body = try Self.body(["struct PlanReviewView", "var body: some View"], in: review)
        let ends = try #require(body.firstMatch(of: /SortingShow\([^)]*\)\s*\{\s*withAnimation\([^)]*\)\)?\s*\{\s*self\.show\s*=\s*nil\s*\}/),
                                "the show's end does not simply end the show: \(body)")
        #expect(!ends.output.isEmpty)
        for call in AppSource.calls(of: "ResultCard(", in: review) {
            #expect(!call.contains("show"), "the result depends on the show: \(call)")
        }
    }

    // MARK: The small moment (draft E6)

    /// The layer lies over the tabs, where the banner shows: never tapped, hidden from VoiceOver,
    /// no haptic of its own. The album's one haptic is the success tap with every banner, given by
    /// the tabs as before the moment, whether or not the cover flies: never late, never lost
    /// (review E of design wave 2, finding 6). The cover fades into the bar on its way and never
    /// lands (finding 4); the tab bar's behaviour is never switched for it (finding 5).
    @Test func theSmallMomentFliesOverTheTabsOnly() throws {
        let tabs = try Self.code(Self.tabs)
        let main = try Self.body(["struct MainTabs", "var body: some View"], in: tabs)
        #expect(main.contains(".tabBarMinimizeBehavior(UITestSupport.isRunning ? .never : .onScrollDown)"), "\(main)")
        let overlay = try #require(AppSource.body(of: ".overlay", in: main), "\(main)")
        #expect(overlay.contains("QuickCreateMomentLayer(showsAlbumsTab: tab != .search)"), "\(overlay)")
        #expect(Self.count(".sensoryFeedback(", in: main) == 1, "\(main)")
        #expect(main.contains(".sensoryFeedback(.success, trigger: model.quickCreateBanner?.id)"), "the banner's success tap is gone")
        #expect(main.contains("new != nil && new != old"), "\(main)")
        var layers = 0
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            let file = try AppSource.read(path)
            layers += AppSource.calls(of: "QuickCreateMomentLayer(", in: file).count
            #expect(!file.contains("oldsTabBar"), "\(path) switches the tab bar for the moment")
        }
        #expect(layers == 1, "the moment is drawn somewhere else too")
        let file = try Self.code(Self.layer)
        #expect(!file.contains("sensoryFeedback"), "the moment has a haptic of its own")
        let layer = try Self.body(["struct QuickCreateMomentLayer", "var body: some View"], in: file)
        for part in [".allowsHitTesting(false)", ".accessibilityHidden(true)", ".ignoresSafeArea()"] {
            #expect(layer.contains(part), "\(part): \(layer)")
        }
        #expect(layer.contains(".task(id: pending) { await begin() }"), "\(layer)")
        let begin = try Self.body(["struct QuickCreateMomentLayer", "func begin("], in: file)
        #expect(begin.contains("QuickCreateMoment.kind(reduceMotion: reduceMotion"), "\(begin)")
        #expect(begin.contains("barOpen: sources.barOpen"), "\(begin)")
        // Looked at a moment after the banner came: a list puts the made card back in its place.
        let look = try #require(begin.range(of: "try? await Task.sleep(for: Self.lookDelay)"), "\(begin)")
        let lookup = try #require(begin.range(of: "sources.photo(for:"), "\(begin)")
        #expect(look.upperBound <= lookup.lowerBound, "\(begin)")
        // A banner without a flight leaves a cover still flying for the one before.
        #expect(!begin.contains("finish()") && !begin.contains("moment = nil"), "\(begin)")
        let play = try Self.body(["struct QuickCreateMomentLayer", "func play()"], in: file)
        #expect(play.contains("QuickCreateMoment.Flight.duration"), "\(play)")
        #expect(!play.contains("landings") && !play.contains("fading") && !play.contains("fadeAtTab"), "\(play)")
        let placement = try Self.body(["struct MomentPlacement", "func body(content: Content)"], in: file)
        #expect(placement.contains(".opacity(flight.opacity(at: t))"), "\(placement)")
    }

    /// The cover flies only into an open tab bar (review E of design wave 2, finding 5): what the
    /// bar does is read from the scroll of the screens with cards, the start page and the
    /// suggestion list, not from where the cards are (review E2, N1 and N2), and decided in the
    /// core (`QuickCreateMoment.TabWatch`, `QuickCreateMomentBarTests`; N6). Each of the two
    /// screens marks its scroll view with one line; the modifier hands over the offset, the
    /// phase and when the screen shows and goes, only on a tab's own stack (a sheet's says no).
    @Test func theCoverFliesOnlyIntoAnOpenTabBar() throws {
        // One marked line on each screen's scroll view, and no other screen calls it. On the start
        // page before the sheets of a card's long press (`suggestionMenuFlows`), so that no scroll
        // in "Anpassen" or the trip workshop reaches it.
        let chains = [Self.overview: "}.quickCreateMomentScrollTrail().suggestionMenuFlows(menuFlows).background(Theme.background)",
                      Self.list: "}.quickCreateMomentScrollTrail().background(Theme.background)"]
        for (path, chain) in chains {
            let file = try AppSource.read(path)
            let lines = file.split(separator: "\n").filter { $0.contains(Self.trailMark) }
            #expect(lines.count == 1, "\(path): \(lines)")
            let line = try #require(lines.first).trimmingCharacters(in: .whitespaces)
            #expect(line == ".quickCreateMomentScrollTrail() \(Self.trailMark)", "\(path): \(line)")
            let view = path == Self.overview ? "struct OverviewView" : "struct ProposalListView"
            let body = try Self.body([view, "var body: some View"], in: try Self.code(path))
            let squeezed = String(body.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
            #expect(squeezed.contains(chain), "\(path): not on the scroll view")
        }
        for path in AppSource.swiftFiles(under: "App/Albumist") where ![Self.overview, Self.list, Self.layer].contains(path) {
            let file = try AppSource.read(path)
            #expect(AppSource.calls(of: "quickCreateMomentScrollTrail(", in: file).isEmpty, "\(path) reads a scroll too")
        }
        let layer = try Self.code(Self.layer)
        let trail = try Self.body(["struct QuickCreateMomentScrollTrail", "func body(content: Content)"], in: layer)
        for part in [".onScrollGeometryChange(for: QuickCreateMoment.ScrollSpot.self)", "offset: Double(geometry.contentOffset.y)",
                     "top: -Double(geometry.contentInsets.top)",
                     "end: Double(geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)",
                     ".onScrollPhaseChange", "QuickCreateMomentSources.shared.scrolled(token, to: now, motion)",
                     "QuickCreateMomentSources.shared.appeared(token, on: place, at: spot, again: shownBefore)",
                     ".onDisappear { QuickCreateMomentSources.shared.disappeared(token) }"] {
            #expect(trail.contains(part), "\(part): \(trail)")
        }
        // Only a tab's own stack: a sheet over the tabs has a stack of its own.
        #expect(Self.count("guard onTab", in: trail) == 2, "\(trail)")
        #expect(layer.contains("@Environment(\\.quickCreateAtOnce) private var onTab"), "the modifier does not ask for the tab's stack")
        // The user's scroll only: at rest, laid out anew or animated by the system is none.
        let motion = try Self.body(["struct QuickCreateMomentScrollTrail", "static func motion("], in: layer)
        #expect(motion.contains("case .tracking, .interacting, .decelerating: .user"), "\(motion)")
        #expect(motion.contains("default: .other"), "\(motion)")
        // The app keeps no trail of its own: the core's watch decides.
        let sources = try Self.code(Self.sources)
        for file in [layer, sources] {
            #expect(!file.contains("BarTrail(") && !file.contains("anchor") && !file.contains("lostSight"), "a trail in the app")
        }
        let note = try Self.body(["final class QuickCreateMomentSources", "func note(_ source: Source"], in: sources)
        #expect(!note.contains("trail") && !note.contains("watch"), "the cards' frames feed the trail again: \(note)")
        let open = try Self.body(["final class QuickCreateMomentSources", "var barOpen: Bool"], in: sources)
        #expect(open.contains("watch.barOpen"), "\(open)")
        let show = try Self.body(["final class QuickCreateMomentSources", "func show(place"], in: sources)
        #expect(show.contains("watch.show(place: token, shown, now: Self.now)"), "\(show)")
        // A tab chosen in code (Siri, Spotlight, the analysis card) may come with a shrunk bar.
        let chosen = try Self.body(["final class QuickCreateMomentSources", "func tabChosenInCode()"], in: sources)
        #expect(chosen.contains("watch.tabChosenInCode()"), "\(chosen)")
        let tabs = try Self.code(Self.tabs)
        let route = try #require(AppSource.body(of: [".onChange(of: model.route, initial: true)"], in: tabs), "the route is gone")
        let mark = try #require(route.range(of: "if tab != .suggestions { QuickCreateMomentSources.shared.tabChosenInCode() }"), "\(route)")
        let chooses = try #require(route.range(of: "tab = .suggestions"), "\(route)")
        #expect(mark.upperBound <= chooses.lowerBound, "\(route)")
    }

    /// The cover lands on "Alben": the third of three tabs beside the round search button, as
    /// `QuickCreateMoment.TabBar` places it.
    @Test func theAlbumsTabIsWhereTheMomentLands() throws {
        let tabs = try Self.code(Self.tabs)
        let main = try Self.body(["struct MainTabs", "var body: some View"], in: tabs)
        let titles = main.matches(of: /Tab\("([^"]+)"/).map { String($0.output.1) }
        #expect(titles.count == QuickCreateMoment.TabBar.tabs, "\(titles)")
        #expect(titles.firstIndex(of: "Alben") == QuickCreateMoment.TabBar.albumsIndex, "\(titles)")
        #expect(main.contains("Tab(value: MainTab.search, role: .search)"), "no round search button beside the tabs")
    }

    /// Each card that offers "Anlegen" marks itself with one line, with its suggestion as the card
    /// shows it and the cover's own aspect ratio; nothing else marks a card.
    @Test func eachCardMarksWhereTheMomentStarts() throws {
        let expected = [Self.start: "style == .large ? 2 : 3.0 / 2.0", Self.list: "4.0 / 3.0"]
        for (path, ratio) in expected {
            let lines = try AppSource.read(path).split(separator: "\n").filter { $0.contains(Self.mark) }
            #expect(lines.count == 1, "\(path): \(lines)")
            let line = try #require(lines.first)
            #expect(line.contains(".quickCreateMomentSource(proposal, aspectRatio: \(ratio))"), "\(line)")
        }
        // The ratios are the ones the cards draw their covers at.
        let start = try Self.code("App/Albumist/Views/Start/StartProposalCard.swift")
        // The start card is built from small typed parts (Xcode's type checker, wave 2 H7): its
        // photo card takes the ratio from its own property.
        let startCard = try Self.body(["struct StartProposalCard", "private var photoCard: some View"], in: start)
        #expect(startCard.contains("aspectRatio: aspectRatio"), "\(startCard)")
        let startRatio = try Self.body(["struct StartProposalCard", "private var aspectRatio: CGFloat"], in: start)
        #expect(startRatio.contains("style == .large ? 2 : 3.0 / 2.0"), "\(startRatio)")
        let list = try Self.code(Self.list)
        let listCard = try Self.body(["var photoCard: some View"], in: list)
        #expect(listCard.contains("PhotoCard(") && !listCard.contains("aspectRatio:"), "\(listCard)")
        let card = try Self.code(Self.card)
        #expect(card.contains("aspectRatio: CGFloat = 4.0 / 3.0"), "PhotoCard's own ratio changed")
        var marked: [String] = []
        for path in AppSource.swiftFiles(under: "App/Albumist") where !AppSource.calls(of: ".quickCreateMomentSource(", in: try AppSource.read(path)).isEmpty {
            marked.append(path)
        }
        #expect(Set(marked) == Set(expected.keys), "\(marked)")
    }

    /// Where the tab bar begins is measured on every tab's screen, where the banner shows, and
    /// only while that tab shows; the cards note where they are, and on which tab, while on
    /// screen. Both measures are taken inside the area they ignore: what `ignoresSafeArea()`
    /// itself reports is the safe frame (review E of design wave 2, finding 2). The tabs' screens
    /// noted are pruned (finding 14).
    @Test func theTabBarIsMeasuredWhereTheBannerShows() throws {
        let banner = try Self.code(Self.banner)
        let shows = try Self.body(["func showsQuickCreateBanner()"], in: banner)
        #expect(shows.contains(".modifier(QuickCreateMomentBarProbe())"), "\(shows)")
        let layer = try Self.code(Self.layer)
        let probe = try Self.body(["struct QuickCreateMomentBarProbe", "func body(content: Content)"], in: layer)
        #expect(probe.contains(".environment(\\.quickCreateMomentPlace, token)"), "\(probe)")
        #expect(probe.contains("QuickCreateMomentSources.shared.show(place: token, true)"), "\(probe)")
        #expect(probe.contains(".onDisappear { QuickCreateMomentSources.shared.show(place: token, false) }"), "\(probe)")
        let measured = try Self.body(["struct QuickCreateMomentBarProbe", "var probe: some View"], in: layer)
        #expect(measured.contains("proxy.safeAreaInsets"), "\(measured)")
        let drawn = try Self.body(["struct QuickCreateMomentLayer", "var body: some View"], in: layer)
        for (name, code) in [("probe", measured), ("layer", drawn)] {
            let measure = try #require(code.range(of: ".onGeometryChange("), "\(name): \(code)")
            let ignores = try #require(code.range(of: ".ignoresSafeArea()"), "\(name): \(code)")
            #expect(measure.lowerBound < ignores.lowerBound, "\(name) measures outside the area it ignores")
        }
        let source = try Self.body(["struct QuickCreateMomentSource:", "func body(content: Content)"], in: layer)
        #expect(source.contains(".onDisappear { QuickCreateMomentSources.shared.forget(token) }"), "\(source)")
        #expect(source.contains(".onAppear"), "a card back on screen is not noted again: \(source)")
        let note = try Self.body(["struct QuickCreateMomentSource:", "func note("], in: layer)
        #expect(note.contains("place: place"), "\(note)")
        // Pruned in the core (`QuickCreateMomentBarTests.theTabsScreensArePruned`).
        let places = try Self.body(["final class QuickCreateMomentSources", "func note(_ place: Place"], in: try Self.code(Self.sources))
        #expect(places.contains("watch.measured("), "the tabs' screens are never pruned: \(places)")
    }
}
