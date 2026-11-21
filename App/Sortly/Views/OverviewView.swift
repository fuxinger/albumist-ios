import Photos
import PhotosUI
import SwiftUI
import SortlyCore
import SortlyEngine

/// The start page "Vorschläge" (design wave 1, drafts E1, E6, E7; overview draft B of 19.11.):
/// what needs the user first (an interrupted plan, a restore, limited access …), then the ring
/// card (how much is sorted, the analysis, "Bescheid sagen, wenn fertig"), then the suggestions
/// as photo cards (`StartSections`, decided in `StartPage`).
///
/// The ring card shows what matters at a glance; the numbers behind the ring are in the sheet
/// "Sortiert", what the analysis did in the sheet "Analyse": nothing of P3-03 or P3-08 is gone,
/// it is one tap further.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    /// The sheet "Sortiert" behind the ring.
    @State private var showSorted = false
    /// The sheet "Analyse" behind the analysis' line.
    @State private var showAnalysis = false
    @State private var notifications = FinishNotificationAsk.shared
    /// The overview tab's stack (`MainTabs`). The suggestions, the plan, the starter plan and
    /// the atlas are pushed onto it, not from a NavigationLink inside the condition that shows
    /// its button: a run that starts while one is open (a check for new photos after the
    /// library changed) hides the button, and a link that leaves the screen takes its pushed
    /// screen with it (contrast UI run 44038288087: suggestions and atlas closed by
    /// themselves). A path, not `navigationDestination(isPresented:)`: with four of those on
    /// this stack, the atlas in landscape was presented again and again for 352 s (UI run
    /// 44055738268). See `AppScreen`.
    @Environment(Navigator.self) private var navigator: Navigator?

    var body: some View {
        let _ = MainThreadWatch.shared.count("overview body")
        // Nothing to sort or suggest: say why and how to go on instead of "0 von 0" (K6).
        let empty = EmptyLibraryCard.state(for: model)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.m) {
                    if let interrupted = model.interruptedPlan {
                        InterruptedPlanCard(plan: interrupted)
                    }
                    if let restore = model.restoredFromBackup {
                        RestoredFromBackupCard(restore: restore)
                    }
                    if model.recheckedSuggestions > 0 {
                        RecheckedSuggestionsCard(count: model.recheckedSuggestions)
                    }
                    if let notice = model.homeChangeNotice {
                        HomeChangeCard(notice: notice)
                    }
                    if model.access == .limited { LimitedAccessCard() }
                    if let empty {
                        EmptyLibraryCard(state: empty)
                        RingCardFrame { analysisRows }
                    } else {
                        RingCardFrame {
                            statusCard
                            RingCardSeparator()
                            analysisRows
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                // The cards read plain values from here: the analysis' many changes redraw the
                // ring card, not every suggestion.
                StartSections(libraryHint: empty != nil, analysedOnce: model.analysedOnce, showsMosaic: model.showsScanShow,
                              rebuilding: model.suggestionsRebuilding, analysing: model.analysisMayBringSuggestions)
                #if targetEnvironment(simulator)
                if !DemoLibrary.shared.isDone {
                    DemoLibraryCard()
                        .padding(.horizontal, Theme.Spacing.l)
                }
                #endif
            }
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background)
        .navigationTitle("Vorschläge")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Einstellungen")
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationRoot { SettingsView() }
        }
        .sheet(isPresented: $showSorted) {
            SortedSheet(ring: shownRing, subject: subjectText, explanation: whatSortedMeans,
                        areas: primaryAreasText, notCounted: shownRing.flatMap { notCountedText($0.notCounted, besidesRing: true) })
        }
        .sheet(isPresented: $showAnalysis) {
            AnalysisSummarySheet()
        }
        // What iOS knows about the notifications, for "Bescheid sagen, wenn fertig" (3B); again
        // when Albumist comes back from the Settings app.
        .task { await notifications.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refresh() } }
        }
        .refreshable { await model.refreshDerived() }
    }

    /// What the first card says about the sorted count, decided in `SortedCountCard` (tested on
    /// Linux, review P3-03): with the same facts about the analysis as the card for an
    /// empty library (`EmptyLibraryCard.state(for:)`), so the two never both stay away and
    /// "0 von 0 sortiert" never shows; and with the analysis card below, so "Wird gezählt"
    /// turns only while that card shows the analysis working.
    private var sortedCount: SortedCountCard {
        let analysis = model.analysis
        return SortedCountCard.make(.init(
            progress: model.progress, leftOut: model.leftOut, recount: model.recount, settings: model.settings,
            hasSuggestions: !model.proposals.isEmpty, analysisRunning: analysis.isRunning,
            analysisPaused: analysis.lastReport?.pausedBecause != nil || analysis.needsResume,
            analysedOnce: AnalysisMarker.completedOnce || analysis.lastReport?.isComplete == true,
            analysisCard: model.analysisCard))
    }

    /// The ring's numbers while there are any (the sheet "Sortiert" shows them).
    private var shownRing: SortedCountCard.Ring? {
        if case .ring(let ring) = sortedCount { ring } else { nil }
    }

    /// The ring's row (draft B): the ring, "495 von 3.114" and what it counts; the other states
    /// in the same place, each with its words. Every number agrees with "Alle 246 Fotos
    /// analysiert" in the sheet "Analyse": the ring's total and what it leaves out add up to
    /// those photos (P3-03).
    private var statusCard: some View {
        Group {
            switch sortedCount {
            case .counting:
                // No suggestion yet, so no photo can count as sorted: no "0 von 0" or "0 von 246"
                // (first start, after the decisions came back from the backup). The empty ring
                // turns while the analysis works.
                RingCardRow(title: Text("Noch nichts sortiert"), titleFont: Self.ringTitleFont) {
                    SortedRing(fraction: nil) {
                        ProgressView()
                            .accessibilityHidden(true) // "Noch nichts sortiert" beside it says it
                    }
                } detail: {
                    Text("Albumist sieht sich deine Fotos an")
                }
            case .notCountedYet:
                // The same before the first suggestions, while the analysis does not run (paused,
                // waiting for the device or for Photos, ended early): nothing turns, the analysis
                // below says why (second review of P3-03).
                RingCardRow(title: Text("Noch nicht gezählt"), titleFont: Self.ringTitleFont) {
                    Image(systemName: "hourglass")
                        .font(.title2)
                        .foregroundStyle(.noteText)
                        .accessibilityHidden(true) // "Noch nicht gezählt" beside it says it
                } detail: {
                    Text("Die Zahl kommt, sobald die Analyse weiterläuft.")
                }
            case .recounting(let recount):
                // Rebuilding: no false 0 %, the last count marked as being recounted.
                RingCardRow(title: Text("Wird neu gezählt"), titleFont: Self.ringTitleFont) {
                    SortedRing(fraction: nil) {
                        ProgressView()
                            .accessibilityHidden(true) // "Wird neu gezählt" beside it says it
                    }
                } detail: {
                    if recount.isForLabels {
                        // Photos analysed before "Themen" or "Dokumente" became a main area get
                        // their labels: the count would fall photo by photo meanwhile
                        // (`RecountState`).
                        Text("Zuletzt \(recount.fully.formatted()) von \(recount.total.formatted()) sortiert. Die neue Zahl kommt, sobald die Fotos für die neuen Bereiche angesehen sind.")
                    } else {
                        Text("Zuletzt \(recount.fully.formatted()) von \(recount.total.formatted()) sortiert. Die neue Zahl kommt mit den ersten Vorschlägen.")
                    }
                }
            case .recountWaiting(let recount):
                // The same held count while the analysis does not work (paused, waiting for the
                // device or for Photos, ended early): it stands still, nothing turns, the analysis
                // below says why (third look at P3-03).
                RingCardRow(title: Text("Zuletzt \(recount.fully.formatted()) von \(recount.total.formatted()) sortiert"),
                            titleFont: Self.ringTitleFont) {
                    Image(systemName: "hourglass")
                        .font(.title2)
                        .foregroundStyle(.noteText)
                        .accessibilityHidden(true) // the held count beside it says it
                } detail: {
                    Text("Wird weitergezählt, sobald die Analyse weiterläuft.")
                }
            case .noMainAreaChosen:
                // No main area counts (none chosen, or the chosen ones turned off): the ring
                // stayed at "0 von 300 sortiert" for good.
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Label("Kein Bereich zählt als sortiert", systemImage: "circle.dashed")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Wähle in den Einstellungen unter „Zählt als sortiert“, welche Bereiche zählen.")
                        .font(.subheadline)
                        .foregroundStyle(.noteText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { showSettings = true } label: { TapTarget("Einstellungen öffnen") }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .nothingToSort(let notCounted):
                // Counted, and every photo is left out (all of them ignored, for example):
                // said in words, not as "0 von 0 sortiert" (question to Fuchs, 18.11.).
                RingCardRow(title: Text("Nichts zu sortieren"), titleFont: Self.ringTitleFont) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                } detail: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(primaryAreasText)
                        if let text = notCountedText(notCounted, besidesRing: false) {
                            Text(text)
                        }
                    }
                    .monospacedDigit()
                }
            case .ring(let ring):
                SortedRingRow(ring: ring, subject: subjectText, explanation: whatSortedMeans,
                              recounted: model.recountNote != nil) {
                    showSorted = true
                }
            }
        }
    }

    /// The ring row's first line: the draft's 19 pt semibold.
    private static var ringTitleFont: Font { .title3.weight(.semibold) }

    /// What the ring counts (`SortedCountCard.subject`): "Reisefotos sortiert" while only
    /// "Reisen" and "Länder und Orte" count, else "Fotos sortiert"; with the trial year
    /// "Reisefotos aus 2026 sortiert".
    private var subjectText: Text {
        switch SortedCountCard.subject(settings: model.settings, scope: model.analysisScope) {
        case .travelPhotos(let year):
            if let year { return Text("Reisefotos aus \(String(year)) sortiert") }
            return Text("Reisefotos sortiert")
        case .photos(let year):
            if let year { return Text("Fotos aus \(String(year)) sortiert") }
            return Text("Fotos sortiert")
        }
    }

    /// "Was heißt sortiert?" at the ring (decision 8A): two lines, the rest behind "Mehr erfahren".
    private var whatSortedMeans: WhatSorted {
        let travel = SortedCountCard.subject(settings: model.settings, scope: model.analysisScope).isTravel
        return WhatSorted(
            short: travel ? Text("Sortiert heißt: in einem Album für Reise oder Land.")
                : Text("Sortiert heißt: in einem passenden Album für jeden Bereich, der zählt."),
            full: Text("Ein Foto gilt als sortiert, wenn es in einem passenden Album liegt, zum Beispiel ein Reisefoto im Album seiner Reise oder ein Foto aus Italien im Album „Italien“. Welche Bereiche zählen, wählst du in den Einstellungen unter „Zählt als sortiert“. Fotos, die zu keinem dieser Bereiche passen, zählen nicht mit."))
    }

    private var primaryAreasText: String {
        // Quoted, so "Länder und Orte" and "Reisen" do not read as one list of three.
        let open = Locale.current.quotationBeginDelimiter ?? "\"", close = Locale.current.quotationEndDelimiter ?? "\""
        // Only the main areas that are on count (`SortedCountCard.countedAreas`): the start can
        // turn "Länder und Orte" and "Reisen" off while they stay main areas (P3-03).
        let counted = SortedCountCard.countedAreas(model.settings)
        let names = OrganizationArea.available.filter { counted.contains($0) }
            .map { open + String(localized: $0.titleResource) + close }
        // Only photos the main areas apply to count, so the total is smaller than the library
        // (device test 15.11.: "141 von 5.737 sortiert" next to "14.351 von 14.352 Fotos analysiert").
        // The areas by name, no word of their own: the setting is "Zählt als sortiert" (P3-09).
        return String(localized: "Gezählt werden nur Fotos, die zu \(names.formatted(.list(type: .and))) passen.")
    }

    /// Every photo the ring leaves out, each in one group (`SortedCountCard.NotCounted`): with
    /// the ring's total they are the photos of "Alle 246 Fotos analysiert" in the sheet
    /// "Analyse". Before, home and "kein eigenes Album" were said, and the photos without a place
    /// nowhere, so "82 von 176 sortiert" and "57 Fotos von zu Hause" did not add up to 246
    /// (P3-03). Since home no longer counts for "Länder und Orte", the total shrank without a
    /// word (review of the sorted count, 16.11.). In the core's order (`NotCounted.groups`): the
    /// one group said with a relative clause comes last, where the period closes it.
    private func notCountedText(_ notCounted: SortedCountCard.NotCounted, besidesRing: Bool) -> String? {
        var parts: [String] = []
        for group in notCounted.groups {
            switch group {
            case .home(let n):
                parts.append(String(localized: "\(n) \(n.formatted()) Fotos von zu Hause"))
            case .noMainArea(let n, let isNoPlace):
                // No place, a screenshot; with "Reisen" as the only main area also photos from home.
                if isNoPlace {
                    parts.append(String(localized: "\(n) \(n.formatted()) Fotos ohne Ort"))
                } else {
                    parts.append(String(localized: "\(n) \(n.formatted()) Fotos außerhalb dieser Bereiche"))
                }
            case .ignored(let n):
                // Ignored photos are neither sorted nor open, so they leave the ring (Fuchs 18.11.):
                // said here, so a total that shrinks after "Ignorieren" has its reason on screen.
                // With "Nur 2026" the ring counts the ignored photos of that year only ("Ignoriert"
                // in the library holds all of them).
                if case .year(let year) = model.analysisScope {
                    parts.append(String(localized: "\(n) \(n.formatted()) ignorierte Fotos aus \(String(year))"))
                } else {
                    parts.append(String(localized: "\(n) \(n.formatted()) ignorierte Fotos"))
                }
            case .excluded(let n):
                // Excluded from the analysis (no switch in the app today): only when there are some.
                parts.append(String(localized: "\(n) \(n.formatted()) ausgeschlossene Fotos"))
            case .noAlbum(let n):
                parts.append(String(localized: "\(n) \(n.formatted()) Fotos, für die sich kein eigenes Album lohnt"))
            }
        }
        guard !parts.isEmpty else { return nil }
        let list = parts.formatted(.list(type: .and))
        return besidesRing ? String(localized: "Außerdem nicht mitgezählt: \(list).")
            : String(localized: "Nicht mitgezählt: \(list).")
    }

    /// The ring card's lower part: the analysis, then "Bescheid sagen, wenn fertig" while it may
    /// be asked (3B), then the trial year.
    @ViewBuilder
    private var analysisRows: some View {
        analysisCard
        // Known only once iOS answered (`FinishNotificationAsk.refresh`), a moment after the
        // page appears: the row fades in and the card grows smoothly, not with a jump.
        VStack(spacing: 0) {
            if let notice = finishNotice {
                RingCardSeparator()
                FinishNotificationRow(notice: notice)
                    .transition(.opacity)
            }
        }
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: finishNotice)
        if case .year(let year) = model.analysisScope {
            RingCardSeparator()
            trialNote(year)
        }
    }

    /// The analysis on the ring card: running, waiting, pausing, paused by the user and the
    /// quick check as the analysis card shows them (P3-08: five parts and "Details"); just
    /// finished as one line with its check mark; ended by the device or iOS with the reason and
    /// "Fortsetzen"; otherwise one line with a check mark (draft B). The lines open the sheet
    /// "Analyse".
    @ViewBuilder
    private var analysisCard: some View {
        Group {
            if let state = model.analysisCard {
                // Running, waiting, pausing, paused by the user, just finished, quick check.
                AnalysisProgressCard(state: state) { showAnalysis = true }
            } else if let reason = model.analysis.lastReport?.pausedBecause {
                // Ended by the device, iOS or the photo access: the reason and the way on.
                VStack(alignment: .leading, spacing: 0) {
                    RingCardRow(title: Text(reason.label)) {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.noteText)
                            .accessibilityHidden(true)
                    } detail: {
                        Text("Die Analyse setzt genau dort fort, wo sie aufgehört hat.")
                    }
                    Button("Fortsetzen") { model.startAnalysis(cause: .tap) }
                        .buttonStyle(CardActionButtonStyle())
                        .accessibilityIdentifier("analysis.resume")
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.bottom, Theme.Spacing.m)
                }
            } else {
                doneRow
            }
        }
        // A crossfade between states (running, paused, finished …), not with every count.
        .animation(reduceMotion ? nil : .smooth, value: model.analysisCard?.phase)
    }

    /// Nothing runs: the analysis in one line with a check mark (draft B), its numbers in the
    /// sheet "Analyse".
    private var doneRow: some View {
        let counts = model.analysisCounts
        let report = model.analysis.lastReport
        // Each of these has its count in the sheet.
        let later = counts.unreadable + counts.labelsMissing + (report?.placesPendingOnline ?? 0)
            + (report?.textWaitingForOriginal ?? 0)
        let line = AnalysisDoneLine.make(photos: counts.photos, analyzed: counts.analyzed, later: later)
        return Button { showAnalysis = true } label: {
            RingCardRow(title: doneTitle(line), chevron: true) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            } detail: {
                if line.restFollows {
                    Text("Den Rest holt Albumist später nach")
                } else if let date = model.analysis.lastRun {
                    LastCheckLine(date: date)
                } else {
                    Text("Neue Fotos erkennt Albumist von selbst.")
                }
            }
        }
        .buttonStyle(RingCardRowButtonStyle())
        // UI runs read how the image requests ended (all demo photos were unreadable there).
        .accessibilityValue(UITestSupport.isRunning ? "image loads: \(ImageLoadStats.summary)" : "")
        .accessibilityIdentifier("analysis.summary")
    }

    private func doneTitle(_ line: AnalysisDoneLine) -> Text {
        switch line {
        case .upToDate: Text("Analyse aktuell")
        case .all(let photos): Text("Alle \(photos.formatted()) Fotos analysiert")
        // Cut off part way: how far it got, never "Analyse fertig" (second review).
        case .partly(let analyzed, let photos): Text("\(analyzed.formatted()) von \(photos.formatted()) Fotos analysiert")
        case .restLater: Text("Analyse fertig")
        }
    }

    /// "Bescheid sagen, wenn fertig" (3B): while the analysis goes on by itself and takes a
    /// while (`FinishNotice`); never before iOS said what it knows.
    private var finishNotice: FinishNotice? {
        guard let permission = notifications.permission else { return nil }
        let goesOn: Bool = switch model.analysisCard {
        case .running?, .waiting?: !model.analysis.refining
        default: false
        }
        let finish: Date? = switch model.analysisFinish {
        case .at(let date)?: date
        case .soon?: .now
        case .none: nil
        }
        return FinishNotice.make(runGoesOn: goesOn, finish: finish, now: .now, firstAnalysis: !model.analysedOnce,
                                 permission: permission, allowedHere: notifications.allowedHere)
    }

    /// The trial year chosen at the start stays until the user takes in the whole library.
    private func trialNote(_ year: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Label("Albumist arbeitet nur mit Fotos aus \(String(year))", systemImage: "calendar").font(.subheadline)
                Spacer()
                Button { model.changeScope(.all) } label: { TapTarget("Alle Jahre") }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("Albumist arbeitet nur mit Fotos aus \(String(year))", systemImage: "calendar").font(.subheadline)
                Button { model.changeScope(.all) } label: { TapTarget("Ganze Mediathek dazunehmen") }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityIdentifier("analysis.trial")
    }
}

extension OrganizationArea {
    /// Same texts as `title`, as a resource for string interpolation.
    var titleResource: LocalizedStringResource {
        switch self {
        case .places: "Länder und Orte"
        case .trips: "Reisen"
        case .frequentPlaces: "Häufige Orte"
        case .peopleAndPets: "Personen und Tiere"
        case .messenger: "Messenger"
        case .screenshots: "Screenshots"
        case .imageCategories: "Themen"
        case .documents: "Dokumente"
        case .chronology: "Jahre und Monate"
        case .mediaTypes: "Medientypen"
        }
    }
}

/// A short text action with Apple's minimum tap area of 44 pt (the label alone is ~18 pt tall).
private struct TapTarget: View {
    var title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// Shown once after Albumist started with an empty database (rebuilt after damage, or a new
/// iPhone) and took the user's decisions back from the copy in the device backup.
struct RestoredFromBackupCard: View {
    @Environment(AppModel.self) private var model
    var restore: AppModel.BackupRestore

    var body: some View {
        let date = restore.date.formatted(date: .long, time: .omitted)
        Card {
            Label("Entscheidungen zurückgeholt", systemImage: "arrow.clockwise.circle").font(.headline)
            Group {
                switch restore.albums {
                case .included:
                    Text("Albumist hat deine Entscheidungen, Einstellungen, Alben und den Verlauf aus der Sicherung vom \(date) übernommen. Die Analyse deiner Fotos läuft neu.")
                case .noAlbums:
                    Text("Albumist hat deine Entscheidungen und Einstellungen aus der Sicherung vom \(date) übernommen. Die Analyse deiner Fotos läuft neu.")
                case .waiting:
                    Text("Albumist hat deine Entscheidungen und Einstellungen aus der Sicherung vom \(date) übernommen. Die Alben von Albumist und der Verlauf folgen, sobald Albumist alle Fotos sehen darf.")
                case .otherLibrary:
                    Text("Albumist hat deine Entscheidungen und Einstellungen aus der Sicherung vom \(date) übernommen. Die Sicherung stammt aus einer anderen Mediathek, darum beginnt der Verlauf hier neu. Deine Alben in Fotos bleiben, wie sie sind.")
                }
            }
            .font(.subheadline).foregroundStyle(.noteText)
            .fixedSize(horizontal: false, vertical: true)
            Button("OK") { model.restoredFromBackup = nil }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("overview.restoredFromBackup.ok")
        }
    }
}

/// Shown once after an update made the rules for the user's own albums stricter (re-check
/// 16.11.): suggestions whose "ergänzen" was chosen under the old rules are open again, so
/// nothing changes in an album without the user looking again.
struct RecheckedSuggestionsCard: View {
    @Environment(AppModel.self) private var model
    var count: Int

    var body: some View {
        Card {
            Label("Vorschläge neu geprüft", systemImage: "checklist").font(.headline)
            Text("\(count) Vorschläge neu geprüft: bitte noch einmal ansehen.")
                .font(.subheadline).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Albumist ergänzt deine eigenen Alben jetzt nur noch, wenn sie sicher passen. Diese Vorschläge sind wieder offen; an deinen Alben hat sich nichts geändert.")
                .font(.subheadline).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { model.dismissRecheckNotice() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("overview.rechecked.ok")
        }
    }
}

/// Shown after the app was closed while a plan ran: the rest can be done now, or what
/// already happened can be taken back. Each button says what it does (design review W17:
/// "Fortsetzen / Rückgängig machen / So lassen" needed a paragraph to explain them).
struct InterruptedPlanCard: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan
    @State private var confirmUndo = false
    /// "Alles rückgängig machen" deletes albums or folders: the confirmation says that iOS asks
    /// next (P3-07). Worked out once on the tap, not while the dialog is drawn.
    @State private var undoDeletes = false
    /// Albumist reads the albums to see whether the undo deletes any: a spinner beside the
    /// button, and no second tap meanwhile (third review of P3-07, SHOULD-2).
    @State private var askingUndo = false

    var body: some View {
        let done = plan.steps.filter { if case .succeeded = $0.state { true } else { false } }.count
        let isUndo = plan.reverts != nil
        // A removal from "Alben von Albumist" (or its retry) is called one: "Rest anlegen" above
        // "iOS fragt … löschen" read as a contradiction (third review of P3-07, NIT-5).
        let isRemoval = !isUndo && !plan.removalSources.isEmpty
        Card {
            Group {
                if isUndo {
                    Label("Rückgängig wurde unterbrochen", systemImage: "pause.circle")
                } else if isRemoval {
                    Label("Entfernen wurde unterbrochen", systemImage: "pause.circle")
                } else {
                    Label("Anlegen wurde unterbrochen", systemImage: "pause.circle")
                }
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            Text("Erledigt: \(done) von \(plan.steps.count) Schritten")
                .font(.subheadline).foregroundStyle(.noteText).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if model.execution.isRunning {
                ExecutionProgressBar()
            } else {
                // The ways out (I16). An interrupted undo cannot itself be taken back (Photos
                // cannot bring deleted albums back): it can only go on or stay as it is.
                Button(isUndo ? LocalizedStringKey("Rest rückgängig machen") : isRemoval ? LocalizedStringKey("Rest entfernen") : LocalizedStringKey("Rest anlegen")) { Task { await model.resumeInterruptedPlan() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("interrupted.resume")
                if !isUndo {
                    Button {
                        guard !askingUndo else { return }
                        askingUndo = true
                        Task {
                            // Full access first: not "not possible" after the dialog was confirmed.
                            guard await model.changesHaveFullAccess() else { askingUndo = false; return }
                            undoDeletes = await model.interruptedUndoDeletesCollections()
                            askingUndo = false
                            confirmUndo = true
                        }
                    } label: {
                        Text("Alles rückgängig machen").checkingBeside(askingUndo)
                    }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(askingUndo)
                        .accessibilityIdentifier("interrupted.undo")
                }
                Button { Task { await model.keepInterruptedPlanAsIs() } } label: {
                    Group {
                        if isUndo { Text("So lassen") } else { Text("Nur Erledigtes behalten") }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("interrupted.keep")
                Group {
                    // Going on deletes albums (an undo, or a removal from "Alben von
                    // Albumist"): iOS asks right after the button (P3-07).
                    if plan.deletesCollections {
                        DeleteQuestionNote.text
                    } else {
                        Text("Deine Fotos bleiben in jedem Fall unverändert.")
                    }
                }
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = model.execution.failure {
                ErrorNote(text: failure)
            }
        }
        .confirmationDialog("Alles rückgängig machen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Alles rückgängig machen", role: .destructive) {
                Task { await model.undoInterruptedPlan() }
            }
        } message: {
            DeleteQuestionNote.message(Text("Albumist entfernt, was sicher von Albumist ist, und sagt dir, falls etwas bleibt."),
                                       deletes: undoDeletes)
        }
    }
}

/// Limited photo access: says how many photos Albumist sees, so nobody wonders where the
/// suggestions come from, and lets the user change the selection or allow everything.
struct LimitedAccessCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Card {
            Label("Nur ausgewählte Fotos", systemImage: "photo.badge.checkmark").font(.headline).accessibilityAddTraits(.isHeader)
            // Every photo Albumist reads, not the ring's: with "Nur 2026" those are only the
            // photos of 2026, and the card said "sieht nur die 12 Fotos" of 40 shared (P3-03).
            Text("Albumist sieht nur die \(model.facts.count) \(model.facts.count.formatted()) Fotos, die du freigegeben hast. Für Alben aus deiner ganzen Mediathek braucht Albumist vollen Zugriff.")
                .font(.subheadline).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
            #if targetEnvironment(simulator)
            if DemoLibrary.shared.isDone {
                Text("Die Beispielfotos zählen mit: Fotos, die eine App selbst gespeichert hat, gibt iOS automatisch für sie frei.")
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.s) { buttons }
                VStack(spacing: Theme.Spacing.s) { buttons }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the Settings app: with full access the whole library is analysed.
            guard phase == .active else { return }
            Task {
                let before = model.access
                await model.refreshAccess()
                // A Pause stays: "Fortsetzen" is the only way on (review of the Pause fix, b).
                if model.access != before, !model.analysis.pausedByUser, !model.analysis.pausing {
                    model.startAnalysis(cause: .tap)
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Auswahl ändern") { presentPicker() }
            .buttonStyle(SecondaryButtonStyle())
        if let url = URL(string: UIApplication.openSettingsURLString) {
            Button("Alle Fotos erlauben") { openURL(url) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func presentPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.compactMap({ $0.keyWindow?.rootViewController }).first else { return }
        while let presented = top.presentedViewController { top = presented }
        let model = model
        // @Sendable: PhotoKit may call this from its own queue.
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { @Sendable _ in
            Task { @MainActor in
                // A Pause stays: "Fortsetzen" is the only way on (review of the Pause fix, b).
                guard !model.analysis.pausedByUser, !model.analysis.pausing else { return }
                model.startAnalysis(cause: .tap)
            }
        }
    }
}

// MARK: - The ring card's sheets

/// What "sortiert" means, in two lines and in full (decision 8A).
struct WhatSorted {
    var short: Text
    var full: Text
}

/// The ring's row (draft B): the ring with its percent and a small "i" that says what
/// "sortiert" means (`LearnMore`), then "495 von 3.114" with what it counts and a chevron to the
/// sheet "Sortiert". Two buttons side by side, never one inside the other; at the accessibility
/// text sizes the ring sits above the words.
private struct SortedRingRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var column: CGFloat = 54
    @ScaledMetric(relativeTo: .caption) private var infoSide: CGFloat = 17
    @State private var showsWhat = false
    var ring: SortedCountCard.Ring
    var subject: Text
    var explanation: WhatSorted
    /// The count was made anew lower than before (`RecountState.LowerNote`): the sheet says why.
    var recounted: Bool
    var onOpen: () -> Void

    var body: some View {
        let side = min(column, 108)
        let shown = OrganizationStatusResolver.Progress.shownShare(ring.fraction)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 0))
        layout {
            Button { showsWhat = true } label: {
                SortedRing(fraction: ring.fraction)
                    .frame(width: side, height: side)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: min(infoSide, 28), weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .background(Circle().fill(Theme.card))
                            .offset(x: 3, y: 3)
                    }
                    .padding(.leading, Theme.Spacing.l)
                    .padding(.trailing, 14)
                    .padding(.vertical, Theme.Spacing.m)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Was heißt sortiert?"))
            .accessibilityValue(Text(shown, format: .percent.precision(.fractionLength(0))))
            .accessibilityIdentifier("overview.sortedInfo")
            .popover(isPresented: $showsWhat) {
                // At the largest text sizes on a small iPhone the two lines and "Mehr erfahren"
                // can be taller than the room beside the ring: they scroll then (review A of
                // design wave 1).
                ViewThatFits(in: .vertical) {
                    whatSorted
                    ScrollView { whatSorted }
                }
                .frame(idealWidth: 320)
                .presentationCompactAdaptation(.popover)
            }
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ring.fully.formatted()) von \(ring.total.formatted())")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .monospacedDigit()
                        subject
                            .font(.subheadline)
                            .foregroundStyle(.noteText)
                        if recounted {
                            Text("Neu gezählt · Mehr dazu")
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.leading, typeSize.isAccessibilitySize ? Theme.Spacing.l : 0)
                .padding(.trailing, 14)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(RingCardRowButtonStyle())
            .accessibilityIdentifier("overview.sorted")
        }
    }

    /// What "sortiert" means: two lines and "Mehr erfahren" (decision 8A).
    private var whatSorted: some View {
        LearnMore(short: explanation.short, full: explanation.full, title: Text("Was heißt sortiert?"))
            .padding(Theme.Spacing.l)
    }
}

/// "Sortiert" (the ring's row opens it): the numbers behind the ring and every photo it leaves
/// out (P3-03), what "sortiert" means, the note on a count made anew, and the way to change
/// what counts. All of it stood on the first card before design wave 1.
private struct SortedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var ringSide: CGFloat = 84
    @State private var showSettings = false
    /// Nil while the number is being counted again (the sheet stays open meanwhile).
    var ring: SortedCountCard.Ring?
    var subject: Text
    var explanation: WhatSorted
    var areas: String
    var notCounted: String?

    var body: some View {
        NavigationRoot {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    numbers
                    if let note = model.recountNote {
                        // The hold for the labels ended lower than it held
                        // (`RecountState.LowerNote`): said once, so the lower number is not
                        // read as one going back.
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Neu gezählt: Zuvor waren es \(note.held.formatted()) sortiert. Die neue Zahl zählt alles, was sich seitdem geändert hat, etwa Fotos mit Themen oder Dokumenten, die jetzt auch ein passendes Album brauchen.")
                                .font(.subheadline)
                                .foregroundStyle(.noteText)
                                .monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("overview.recountNote")
                            Button("OK") { model.dismissRecountNote() }
                                .font(.subheadline)
                                .frame(minHeight: 44)
                                .accessibilityLabel("Hinweis zur neuen Zahl ausblenden")
                                .accessibilityIdentifier("overview.recountNote.ok")
                        }
                    }
                    explanation.full
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(areas)
                        if let notCounted {
                            Text(notCounted)
                        }
                        if let interrupted = model.interruptedPlan {
                            // The unfinished run counts only once the user has decided on the
                            // page (unknown is not done), so "0 sortiert" next to "39 of 61 steps"
                            // is explained. Named with the card's own words ("Anlegen wurde
                            // unterbrochen", P3-09): in a sheet nothing is "oben" (second review).
                            if interrupted.reverts != nil {
                                Text("Das unterbrochene Rückgängigmachen zählt, sobald du auf der Karte „Rückgängig wurde unterbrochen“ entschieden hast.")
                            } else if !interrupted.removalSources.isEmpty {
                                Text("Das unterbrochene Entfernen zählt, sobald du auf der Karte „Entfernen wurde unterbrochen“ entschieden hast.")
                            } else {
                                Text("Das unterbrochene Anlegen zählt, sobald du auf der Karte „Anlegen wurde unterbrochen“ entschieden hast.")
                            }
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.noteText)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Was zählt, ändern") { showSettings = true }
                        .buttonStyle(CardActionButtonStyle())
                        .accessibilityIdentifier("sorted.settings")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .navigationTitle("Sortiert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .accessibilityIdentifier("sorted.done")
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationRoot { SettingsView() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var numbers: some View {
        if let ring {
            AdaptiveStack(verticalAlignment: .center, spacing: Theme.Spacing.l) {
                ProgressRing(fraction: ring.fraction)
                    .frame(width: min(ringSide, 150), height: min(ringSide, 150))
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("\(ring.fully.formatted()) von \(ring.total.formatted())")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    subject
                        .font(.subheadline)
                        .foregroundStyle(.noteText)
                    if ring.partially > 0 {
                        // Photos already in a matching album for one main area but not yet for
                        // the other count as partly sorted; without this line the ring looked
                        // too low (device test 15.11.: 157 sorted, 1,199 partly).
                        Text("Dazu \(ring.partially.formatted()) teilweise sortiert")
                            .font(.subheadline)
                            .foregroundStyle(.noteText)
                            .monospacedDigit()
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Wird neu gezählt")
                .font(.headline)
        }
    }
}

/// "Analyse" (the analysis' line opens it): how many photos are analysed and when Albumist last
/// looked, what a check found, what it does later, and "Neu prüfen". All of it stood on the
/// analysis card before design wave 1.
private struct AnalysisSummarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationRoot {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    summary
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .navigationTitle("Analyse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .accessibilityIdentifier("analysis.summary.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var summary: some View {
        let counts = model.analysisCounts
        let stack = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.s))
            : AnyLayout(HStackLayout())
        stack {
            VStack(alignment: .leading, spacing: 2) {
                // Says what is done, so "aktuell" is not read as "stopped" (first device test 15.11.).
                Group {
                    if counts.photos == 0 {
                        Text("Analyse aktuell")
                    } else if counts.analyzed >= counts.photos {
                        Text("Alle \(counts.photos.formatted()) Fotos analysiert")
                    } else {
                        Text("\(counts.analyzed.formatted()) von \(counts.photos.formatted()) Fotos analysiert")
                    }
                }
                .font(.headline)
                // UI runs read how the image requests ended (all demo photos were unreadable there).
                .accessibilityValue(UITestSupport.isRunning ? "image loads: \(ImageLoadStats.summary)" : "")
                if let date = model.analysis.lastRun {
                    LastCheckLine(date: date)
                        .font(.subheadline).foregroundStyle(.noteText)
                } else {
                    Text("Neue Fotos erkennt Albumist von selbst.").font(.subheadline).foregroundStyle(.noteText)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            // The card shows the check at once: the sheet goes.
            Button {
                model.startAnalysis()
                dismiss()
            } label: { TapTarget("Neu prüfen") }
        }
        if let report = model.analysis.lastReport, model.analysis.lastRun != nil, model.analysis.kind == .check {
            // What "Neu prüfen" found, so a check that ends after a few seconds is clearly done.
            // Photos that only got their labels ("Themen" or "Dokumente" turned on) are no new
            // photos (review of the labels fix, M2); both in one line (second review, nit).
            Group {
                if report.newPhotosAnalyzed > 0 && report.labelsAdded > 0 {
                    Text("Beim Prüfen \(report.newPhotosAnalyzed) \(report.newPhotosAnalyzed.formatted()) neue Fotos analysiert und \(report.labelsAdded) \(report.labelsAdded.formatted()) weitere für die neuen Bereiche angesehen.")
                } else if report.newPhotosAnalyzed > 0 {
                    Text("Beim Prüfen \(report.newPhotosAnalyzed) \(report.newPhotosAnalyzed.formatted()) neue Fotos analysiert.")
                } else if report.labelsAdded > 0 {
                    Text("Beim Prüfen \(report.labelsAdded) \(report.labelsAdded.formatted()) Fotos für die neuen Bereiche angesehen.")
                } else if report.newOrChanged == 0 && report.removed == 0 {
                    Text("Beim Prüfen keine neuen Fotos gefunden.")
                }
            }
            .font(.footnote).foregroundStyle(.noteText)
        }
        if counts.labelsMissing > 0 {
            // Analysed before "Themen" or "Dokumente" was turned on and still without their image
            // labels (no run yet, or a read that failed waits for its retry): said apart, the
            // count above stays (second review of the labels fix, finding 6).
            Label("Für die neuen Bereiche fehlen noch \(counts.labelsMissing) \(counts.labelsMissing.formatted()) Fotos.", systemImage: "hourglass")
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if counts.unreadable > 0 {
            Label("\(counts.unreadable) \(counts.unreadable.formatted()) Fotos konnten noch nicht gelesen werden. Albumist versucht es später noch einmal.", systemImage: "exclamationmark.icloud")
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let pending = model.analysis.lastReport?.placesPendingOnline, pending > 0 {
            Label("\(pending) \(pending.formatted()) Orte werden später genauer bestimmt.", systemImage: "moon.zzz")
                .font(.footnote).foregroundStyle(.noteText)
        }
        if let waiting = model.analysis.lastReport?.textWaitingForOriginal, waiting > 0 {
            Label("\(waiting) \(waiting.formatted()) Dokumente liegen nur in iCloud und werden später gelesen.", systemImage: "icloud")
                .font(.footnote).foregroundStyle(.noteText)
        }
    }
}

/// „Gerade eben geprüft“ in the first minute, not „Zuletzt geprüft jetzt“ (P3-18). Drawn again a
/// minute after the check and every minute from there, so neither stays after its minute has
/// passed (a timeline by the clock's minute kept „Gerade eben“ up to two minutes).
private struct LastCheckLine: View {
    var date: Date

    var body: some View {
        TimelineView(.periodic(from: date, by: LastCheck.justNowSpan)) { context in
            switch LastCheck(date, now: context.date) {
            case .justNow: Text("Gerade eben geprüft")
            case .earlier(let checked): Text("Zuletzt geprüft \(checked.formatted(.relative(presentation: .named)))")
            }
        }
    }
}
