import Foundation
import Testing
import AlbumistTestSupport

/// The start page's app code after review A of design wave 1 (20.11.2026), read from the source
/// (the app does not build on Linux): the cards' cover candidates are kept, a visit begins when
/// the page is really back on top and when the app comes back, an album made after the purchase
/// sheet says "Angelegt", "Ergänzen …" pushes only where it was asked for, a working card says
/// what runs, and "Was heißt sortiert?" scrolls when it does not fit.
@Suite("Start page source")
struct StartPageSourceTests {
    static func startSections() throws -> String {
        try AppSource.read("App/Albumist/Views/Start/StartSections.swift")
    }

    /// The file of a suggestion's card on the page (`StartProposalCard`).
    static func startCard() throws -> String {
        try AppSource.read("App/Albumist/Views/Start/StartProposalCard.swift")
    }

    /// The body of `StartSections`, its comments blanked.
    static func startBody() throws -> String {
        let file = try startSections()
        return AppSource.code(try #require(AppSource.body(of: ["struct StartSections", "var body: some View"], in: file)))
    }

    /// Finding 1: every card asked for its cover candidates in each pass of the start page's
    /// body (and of the list's), one pass over all photos of its suggestion each. They are kept
    /// per suggestion now (`CoverCandidatesCache`) and worked out in a marked section of the
    /// main thread (`MainThreadWatch`), which also counts the page's passes.
    @Test func coverCandidatesAreKeptPerSuggestion() throws {
        let model = try AppSource.read("App/Albumist/Model/AppModel+ProposalCard.swift")
        let covers = AppSource.code(try #require(AppSource.body(of: "func proposalCoverIDs(", in: model)), keepStrings: true)
        let cached = try #require(covers.range(of: "CoverCandidatesCache.shared.candidates("),
                                  "worked out again at every call")
        #expect(!covers[..<cached.lowerBound].contains("PreviewPicker.coverCandidates("), "worked out before the cache is asked")
        #expect(covers[cached.lowerBound...].contains("MainThreadWatch.shared.section(\"cover candidates\")"))
        #expect(covers[cached.lowerBound...].contains("PreviewPicker.coverCandidates("))
        let page = AppSource.code(try #require(AppSource.body(of: ["struct StartSections", "var body: some View"],
                                                              in: try Self.startSections())), keepStrings: true)
        #expect(page.contains("MainThreadWatch.shared.count(\"start page body\")"))
    }

    /// Finding 4: a swipe back shows the page at its start, while the preview is still on the
    /// path and its picks still chosen; a visit begun then had no "Dein Startpaket" and showed
    /// "Neue Reisen" until the swipe ended. A visit begins only when the stack is back at the
    /// page: on appearing at the top, and when the path empties.
    @Test func aVisitBeginsWhenThePageIsBackOnTop() throws {
        let body = try Self.startBody()
        let appear = try #require(AppSource.body(of: ".onAppear", in: body))
        #expect(appear.contains("navigator?.path.isEmpty != false"), "begins under a swipe back that has not ended")
        #expect(AppSource.calls(of: "beginVisit(", in: appear) == [""])
        let back = try #require(AppSource.body(of: ".onChange(of: navigator?.path.isEmpty", in: body),
                                "the end of a swipe back begins no visit")
        #expect(AppSource.calls(of: "beginVisit(", in: back) == [""])
        // Only `beginVisit` makes a fresh visit.
        #expect(!body.contains("StartVisit(lastMade:"))
    }

    /// Finding 10: the app opened again from the background is a new visit too (what the
    /// visit's own documentation says): the "Angelegt" cards and big cards of hours ago go.
    @Test func aVisitBeginsWhenTheAppComesBack() throws {
        let body = try Self.startBody()
        let phase = try #require(AppSource.body(of: ".onChange(of: scenePhase", in: body), "the app's return begins no visit")
        #expect(phase.contains(".background"))
        #expect(phase.contains(".active"))
        #expect(AppSource.calls(of: "beginVisit(", in: phase) == [""])
    }

    /// Finding 10: an album made after the purchase sheet ("Anlegen" with the free albums used
    /// up, `continueQuickCreate`) was never told to the visit; its banner tells it now, as it
    /// does for one made at once.
    @Test func theBannerTellsTheVisitWhatWasMade() throws {
        let body = try Self.startBody()
        let banner = try #require(AppSource.body(of: ".onChange(of: model.quickCreateBanner?.id", in: body),
                                  "the banner of an album made after the purchase sheet is not told to the visit")
        #expect(!AppSource.calls(of: "visit.announced(", in: banner).isEmpty)
    }

    /// Finding 6: "Ergänzen …" whose plan turned out empty pushed the suggestion with
    /// `open(_:)`, without asking whether the page is still on top: onto a list opened
    /// meanwhile, or onto the stack of a tab the user left. Every push of the preview asks.
    @Test func ergaenzenPushesOnlyWhereItWasAskedFor() throws {
        let preview = AppSource.code(try #require(AppSource.body(of: ["struct StartSections", "private func preview("],
                                                                 in: try Self.startSections())))
        #expect(AppSource.calls(of: "open(", in: preview).isEmpty, "a push that does not ask")
        let pushes = AppSource.calls(of: "Navigator.push(", in: preview)
        #expect(pushes.count == 2)
        #expect(pushes.allSatisfy { $0.contains("ifStill: request.mark") }, "\(pushes)")
    }

    /// Finding 7: while its album is made (or its preview prepared), a card's button said
    /// "„Kyoto, Oktober 2024“ anlegen", dimmed, and nothing about the work. It says what the
    /// suggestion list says then.
    @Test func aWorkingCardSaysWhatRuns() throws {
        let file = AppSource.code(try Self.startCard(), keepStrings: true)
        let card = try #require(AppSource.body(of: "struct StartProposalCard", in: file))
        #expect(card.contains(".accessibilityLabel(working ? workingLabel : text.spokenAction)"))
        let label = try #require(AppSource.body(of: "private var workingLabel", in: card))
        #expect(label.contains("Text(\"Album wird angelegt\")"))
        #expect(label.contains("Text(\"Wird vorbereitet\")"))
        let list = AppSource.code(try AppSource.read("App/Albumist/Views/ProposalViews.swift"), keepStrings: true)
        #expect(list.contains("Text(\"Album wird angelegt\")"), "the list's words")
        #expect(list.contains("\"Wird vorbereitet\""), "the list's words")
    }

    /// Review B of design wave 1, 5, on the start page: a card's status line is the list's
    /// (`ProposalCardText.styledSubtitle`): "🔒 Persönlicher Inhalt" first, the count below it is
    /// what a two-line name cuts, and VoiceOver hears the status in words (`spokenStatus`), never
    /// the lock's symbol. The page built a line of its own, count first.
    @Test func aCardsStatusLineIsTheLists() throws {
        let file = AppSource.code(try Self.startCard(), keepStrings: true)
        let card = try #require(AppSource.body(of: "struct StartProposalCard", in: file))
        #expect(card.contains("subtitle: text.styledSubtitle"), "a status line of the page's own")
        #expect(!card.contains("lock.fill"), "the lock drawn by the page")
        #expect(!card.contains("subtitleParts"), "the status line's parts put together by the page")
    }

    /// Finding 8: at the largest text sizes on a small iPhone "Was heißt sortiert?" is taller
    /// than the room beside the ring: it scrolls then, as it is at every other size.
    @Test func whatSortedScrollsWhenItDoesNotFit() throws {
        let overview = AppSource.code(try AppSource.read("App/Albumist/Views/OverviewView.swift"))
        let popover = try #require(AppSource.body(of: ".popover(isPresented: $showsWhat)", in: overview))
        #expect(popover.contains("ViewThatFits(in: .vertical)"))
        #expect(popover.contains("ScrollView"))
    }

    /// An empty trial year: the card says it and offers the whole library, so the note under the
    /// analysis stays away meanwhile (`EmptyLibraryState.offersAllYears`). The flow tests know a
    /// trial year by the note or by that card (`UITestScreens.TrialYear.shown`), test6 and
    /// `prepare` alike.
    @Test func anEmptyTrialYearSaysItOnce() throws {
        let overview = AppSource.code(try AppSource.read("App/Albumist/Views/OverviewView.swift"))
        let rows = try #require(AppSource.body(of: "private func analysisRows(", in: overview), "the analysis rows do not know the card")
        #expect(rows.contains("if case .year(let year) = model.analysisScope, empty?.offersAllYears != true {"))
        #expect(overview.contains("analysisRows(empty: empty)"))
        let screens = try UITestScreensSource.read()
        let trialYear = try #require(AppSource.body(of: "enum TrialYear", in: screens))
        let shown = try #require(AppSource.body(of: "static func shown(", in: trialYear), "the UI tests know the trial year by its note only")
        #expect(shown.contains("analysis.trial") && shown.contains("Keine Fotos aus "))
        let flow = try AppSource.read("App/AlbumistUITests/AlbumistFlowUITests.swift")
        #expect(!flow.contains(#"["analysis.trial"]"#), "a flow test still looks for the note only")
        let prepare = try #require(AppSource.body(of: "private func prepare(", in: flow))
        #expect(prepare.contains("UITestScreens.TrialYear.shown(app)"))
        let test6 = try #require(AppSource.body(of: "func test6_AnalysisKeepsGoingThroughBackgroundAndTabs(", in: flow))
        #expect(test6.contains("UITestScreens.TrialYear.shown(app)"))
    }
}
