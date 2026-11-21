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
    static let model = "App/Albumist/Model/AppModel+Moments.swift"
    static let tabs = "App/Albumist/Views/RootView.swift"
    static let banner = "App/Albumist/Views/Frame/QuickCreateBar.swift"
    static let start = "App/Albumist/Views/Start/StartSections.swift"
    static let list = "App/Albumist/Views/ProposalViews.swift"
    static let card = "App/Albumist/DesignSystem/PhotoCard.swift"
    static let cover = "App/Albumist/DesignSystem/CoverPhoto.swift"
    static let mark = "// Design W2 H6: moment source"

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
                     "ResultMomentLoader.kept(stack, scale: displayScale)", "madeFor = plan.id"] {
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
        for path in [Self.stack, Self.layer] {
            let file = try Self.code(path)
            for loader in ["PHImageManager", "PHCachingImageManager", "requestImage", "isNetworkAccessAllowed", "ThumbnailRequest"] {
                #expect(!file.contains(loader), "\(path) asks Photos itself: \(loader)")
            }
        }
        let stack = try Self.code(Self.stack)
        let load = try Self.body(["enum ResultMomentLoader", "static func prefetch("], in: stack)
        #expect(load.contains("CoverLoader.Request(ids: card.candidates, pixels: pixels)"), "\(load)")
        #expect(load.contains("await CoverLoader.load(request)"), "\(load)")
        #expect(load.contains("!Task.isCancelled"), "\(load)")
        #expect(stack.contains("static func kept(_ stack: ResultCoverStack, scale: CGFloat) -> [ResultMomentCover] {"),
                "the result's covers are not taken from the store at once")
        let fromStore = try Self.body(["enum ResultMomentLoader", "static func kept("], in: stack)
        #expect(fromStore.contains("ThumbnailCache.shared.cachedCover(for: photo, pixels: pixels)"), "\(fromStore)")
        #expect(!fromStore.contains("await"), "\(fromStore)")
        // The view itself never asks Photos: its only waits are the covers lying down.
        let view = try Self.body(["struct ResultCoverMoment"], in: stack)
        for asks in ["CoverLoader.load", "ResultMomentLoader.prefetch", "ResultMomentLoader.load"] {
            #expect(!view.contains(asks), "the result waits for Photos: \(asks)")
        }
        let waits = view.components(separatedBy: "await ").dropFirst().map { String($0.prefix(10)) }
        #expect(waits.allSatisfy { $0.hasPrefix("Task.sleep") || $0.hasPrefix("play()") }, "\(waits)")
        let layer = try Self.code(Self.layer)
        let kept = try Self.body(["final class QuickCreateMomentSources", "func keptCover("], in: layer)
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
        let layer = try Self.code(Self.layer)
        let photo = try Self.body(["final class QuickCreateMomentSources", "func photo(for"], in: layer)
        #expect(photo.contains("proposal.isSensitive || model.previewHidden(for: proposal)"), "\(photo)")
        #expect(photo.contains("personal ? nil : keptCover("), "\(photo)")
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
        for part in ["momentPending = true", "model.resultCoverSources(for: plan)",
                     "model.resultCoverStack(for: plan, taken: sources, expected: true)", "prefetch?.cancel()",
                     "prefetch = Task { await ResultMomentLoader.prefetch(stack, scale: scale) }"] {
            #expect(begin.contains(part), "\(part): \(begin)")
        }
        let end = try Self.body(["struct PlanReviewView", "func endMoment()"], in: file)
        for part in ["momentPending = false", "prefetch?.cancel()", "prefetch = nil"] {
            #expect(end.contains(part), "\(part): \(end)")
        }
        let button = try Self.body(["struct PlanReviewView", "func applyButton("], in: file)
        #expect(button.contains("beginMoment(plan)"), "\(button)")
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

    /// The layer lies over the tabs, where the banner shows: never tapped, hidden from
    /// VoiceOver, one haptic per album (the success tap with the banner, or the light tap as the
    /// cover lands), and the tab bar stays open while it flies.
    @Test func theSmallMomentFliesOverTheTabsOnly() throws {
        let tabs = try Self.code(Self.tabs)
        let main = try Self.body(["struct MainTabs", "var body: some View"], in: tabs)
        #expect(main.contains(".tabBarMinimizeBehavior(UITestSupport.isRunning || momentHoldsTabBar ? .never : .onScrollDown)"), "\(main)")
        let overlay = try #require(AppSource.body(of: ".overlay", in: main), "\(main)")
        #expect(overlay.contains("QuickCreateMomentLayer(holdsTabBar: $momentHoldsTabBar, showsAlbumsTab: tab != .search)"), "\(overlay)")
        #expect(!main.contains("sensoryFeedback"), "the tabs tap a second time")
        var layers = 0
        for path in AppSource.swiftFiles(under: "App/Albumist") {
            layers += AppSource.calls(of: "QuickCreateMomentLayer(", in: try AppSource.read(path)).count
        }
        #expect(layers == 1, "the moment is drawn somewhere else too")
        let file = try Self.code(Self.layer)
        let layer = try Self.body(["struct QuickCreateMomentLayer", "var body: some View"], in: file)
        for part in [".allowsHitTesting(false)", ".accessibilityHidden(true)", ".sensoryFeedback(.success, trigger: successes)",
                     ".sensoryFeedback(.impact(weight: .light), trigger: landings)", ".ignoresSafeArea()"] {
            #expect(layer.contains(part), "\(part): \(layer)")
        }
        #expect(Self.count(".sensoryFeedback(", in: file) == 2)
        let begin = try Self.body(["struct QuickCreateMomentLayer", "func begin("], in: file)
        #expect(begin.contains("switch QuickCreateMoment.haptic(for: kind)"), "\(begin)")
        #expect(begin.contains("QuickCreateMoment.kind(reduceMotion: reduceMotion"), "\(begin)")
        #expect(begin.contains("holdsTabBar = true"), "\(begin)")
        let finish = try Self.body(["struct QuickCreateMomentLayer", "func finish()"], in: file)
        #expect(finish.contains("holdsTabBar = false"), "\(finish)")
        let play = try Self.body(["struct QuickCreateMomentLayer", "func play()"], in: file)
        #expect(play.contains("landings += 1"), "\(play)")
        let fade = try #require(play.components(separatedBy: "case .fadeAtTab:").dropFirst().first?.components(separatedBy: "case .none:").first,
                                "\(play)")
        #expect(fade.contains("withAnimation(.easeOut") && !fade.contains("timingCurve"), "Reduce Motion still flies: \(fade)")
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

    /// Each card that offers "Anlegen" marks itself with one line, at the cover's own aspect
    /// ratio; nothing else marks a card.
    @Test func eachCardMarksWhereTheMomentStarts() throws {
        let expected = [Self.start: "style == .large ? 2 : 3.0 / 2.0", Self.list: "4.0 / 3.0"]
        for (path, ratio) in expected {
            let lines = try AppSource.read(path).split(separator: "\n").filter { $0.contains(Self.mark) }
            #expect(lines.count == 1, "\(path): \(lines)")
            let line = try #require(lines.first)
            #expect(line.contains(".quickCreateMomentSource(proposal.id, aspectRatio: \(ratio))"), "\(line)")
        }
        // The ratios are the ones the cards draw their covers at.
        let start = try Self.code(Self.start)
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
    /// only while that tab shows; the cards note where they are while on screen.
    @Test func theTabBarIsMeasuredWhereTheBannerShows() throws {
        let banner = try Self.code(Self.banner)
        let shows = try Self.body(["func showsQuickCreateBanner()"], in: banner)
        #expect(shows.contains(".modifier(QuickCreateMomentBarProbe())"), "\(shows)")
        let layer = try Self.code(Self.layer)
        let probe = try Self.body(["struct QuickCreateMomentBarProbe", "func body(content: Content)"], in: layer)
        #expect(probe.contains(".onAppear { QuickCreateMomentSources.shared.show(place: token, true) }"), "\(probe)")
        #expect(probe.contains(".onDisappear { QuickCreateMomentSources.shared.show(place: token, false) }"), "\(probe)")
        let measured = try Self.body(["struct QuickCreateMomentBarProbe", "var probe: some View"], in: layer)
        #expect(measured.contains(".ignoresSafeArea()") && measured.contains("proxy.safeAreaInsets"), "\(measured)")
        let source = try Self.body(["struct QuickCreateMomentSource:", "func body(content: Content)"], in: layer)
        #expect(source.contains(".onDisappear { QuickCreateMomentSources.shared.forget(token) }"), "\(source)")
        #expect(source.contains(".onAppear"), "a card back on screen is not noted again: \(source)")
    }
}
