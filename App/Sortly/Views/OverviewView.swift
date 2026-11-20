import Photos
import PhotosUI
import SwiftUI
import SortlyCore
import SortlyEngine

/// Overview (direction A): organized share, analysis state, open proposals, areas.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The ring grows with the text size, so "100 %" still fits inside at the largest sizes.
    @ScaledMetric(relativeTo: .title3) private var ringSide: CGFloat = 84
    @State private var showSettings = false
    /// The overview tab's stack (`MainTabs`). The suggestions, the plan, the starter plan and
    /// the atlas are pushed onto it, not from a NavigationLink inside the condition that shows
    /// its button: a run that starts while one is open (a check for new photos after the
    /// library changed) hides the button, and a link that leaves the screen takes its pushed
    /// screen with it (contrast UI run 44038288087: suggestions and atlas closed by
    /// themselves). A path, not `navigationDestination(isPresented:)`: with four of those on
    /// this stack, the atlas in landscape was presented again and again for 352 s (UI run
    /// 44055738268). See `AppScreen`.
    @Environment(Navigator.self) private var navigator: Navigator?
    /// The starter set is selected only while its preview is open.
    @State private var starterSelection: AppModel.PreviewSelection?

    var body: some View {
        let _ = MainThreadWatch.shared.count("overview body")
        ScrollView {
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
                // Nothing to sort or suggest: say why and how to go on instead of "0 von 0" (K6).
                if let empty = EmptyLibraryCard.state(for: model) {
                    EmptyLibraryCard(state: empty)
                } else {
                    statusCard
                }
                analysisCard
                if model.history.isEmpty && model.acceptedProposals.isEmpty {
                    StarterSetCard { set in
                        starterSelection = model.selectForPreview(set.map { ($0, model.recommendedDecision(for: $0)) })
                        Navigator.push(.starterPlan, on: navigator)
                    }
                }
                // While the analysis runs, "Schon fertig … Ansehen" on its card leads there; when it
                // has just finished, its card has "Vorschläge prüfen" (point 3, 4: not twice).
                if !model.openProposals.isEmpty, !model.analysis.isRunning, model.analysisFinished == nil {
                    Button {
                        Navigator.push(.proposals, on: navigator)
                    } label: {
                        Text("\(model.openProposals.count) Vorschläge prüfen")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if !model.proposalsToApply.isEmpty {
                    Button {
                        Navigator.push(.plan, on: navigator)
                    } label: {
                        Text("\(model.proposalsToApply.count) ausgewählte Alben anlegen")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                #if targetEnvironment(simulator)
                if !DemoLibrary.shared.isDone { DemoLibraryCard() }
                #endif
                AtlasTeaser(onOpen: { Navigator.push(.atlas, on: navigator) })
                areasSection
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background)
        .navigationTitle("Übersicht")
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
        .onChange(of: navigator?.path.contains(.starterPlan) ?? false) { _, showing in
            // Back without creating: the starter set is not selected any more.
            if !showing, let selection = starterSelection {
                model.endPreview(selection)
                starterSelection = nil
            }
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

    private var statusCard: some View {
        // Largest text sizes stack the ring above the text instead of squeezing it.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.m))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.l))
        let side = min(ringSide, 150)
        return Card {
            // Every number here agrees with "Alle 246 Fotos analysiert" below: the ring's total
            // and what it leaves out add up to those photos (P3-03).
            switch sortedCount {
            case .counting:
                // No suggestion yet, so no photo can count as sorted: no "0 von 0" or "0 von 246"
                // (first start, after the decisions came back from the backup).
                layout {
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: side, height: side)
                        .accessibilityHidden(true) // "Wird gezählt" beside it says it
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Wird gezählt")
                            .font(.headline)
                        Text("Die Zahl kommt mit den ersten Vorschlägen.")
                            .font(.subheadline)
                            .foregroundStyle(.noteText)
                    }
                    .accessibilityElement(children: .combine)
                }
            case .notCountedYet:
                // The same before the first suggestions, while the analysis does not run (paused,
                // waiting for the device or for Photos, ended early): nothing turns, the card
                // below says why (second review of P3-03).
                layout {
                    Image(systemName: "hourglass")
                        .font(.largeTitle)
                        .foregroundStyle(.noteText)
                        .frame(width: side, height: side)
                        .accessibilityHidden(true) // "Noch nicht gezählt" beside it says it
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Noch nicht gezählt")
                            .font(.headline)
                        Text("Die Zahl kommt, sobald die Analyse weiterläuft.")
                            .font(.subheadline)
                            .foregroundStyle(.noteText)
                    }
                    .accessibilityElement(children: .combine)
                }
            case .recounting(let recount):
                layout {
                    // Rebuilding: no false 0 %, the last count marked as being recounted.
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: side, height: side)
                        .accessibilityHidden(true) // "Wird neu gezählt" beside it says it
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Wird neu gezählt")
                            .font(.headline)
                        Group {
                            if recount.isForLabels {
                                // Photos analysed before "Themen" or "Dokumente" became a main area
                                // get their labels: the count would fall photo by photo meanwhile
                                // (`RecountState`).
                                Text("Zuletzt \(recount.fully.formatted()) von \(recount.total.formatted()) sortiert. Die neue Zahl kommt, sobald die Fotos für die neuen Bereiche angesehen sind.")
                            } else {
                                Text("Zuletzt \(recount.fully.formatted()) von \(recount.total.formatted()) sortiert. Die neue Zahl kommt mit den ersten Vorschlägen.")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.noteText)
                        .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            case .noMainAreaChosen:
                // No main area counts (none chosen, or the chosen ones turned off): the ring
                // stayed at "0 von 300 sortiert" for good.
                Label("Kein Bereich zählt als sortiert", systemImage: "circle.dashed")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("Wähle in den Einstellungen unter „Zählt als sortiert“, welche Bereiche zählen.")
                    .font(.subheadline)
                    .foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showSettings = true } label: { TapTarget("Einstellungen öffnen") }
            case .nothingToSort(let notCounted):
                // Counted, and every photo is left out (all of them ignored, for example):
                // said in words, not as "0 von 0 sortiert" (question to Fuchs, 18.11.).
                Label("Nichts zu sortieren", systemImage: "checkmark.circle")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(primaryAreasText)
                    if let text = notCountedText(notCounted, besidesRing: false) {
                        Text(text)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            case .ring(let ring):
                layout {
                    ProgressRing(fraction: ring.fraction)
                        .frame(width: side, height: side)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("\(ring.fully.formatted()) von \(ring.total.formatted()) sortiert")
                            .font(.headline)
                            .monospacedDigit()
                        if ring.partially > 0 {
                            // Photos already in a matching album for one main area but not yet for the
                            // other count as partly sorted; without this line the ring looked too low
                            // (device test 15.11.: 157 sorted, 1,199 partly).
                            Text("Dazu \(ring.partially) teilweise sortiert")
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                        if let note = model.recountNote {
                            // The hold for the labels ended lower than it held
                            // (`RecountState.LowerNote`): said once, so the lower number is not
                            // read as one going back.
                            Text("Neu gezählt: Zuvor waren es \(note.held.formatted()) sortiert. Die neue Zahl zählt alles, was sich seitdem geändert hat, etwa Fotos mit Themen oder Dokumenten, die jetzt auch ein passendes Album brauchen.")
                                .font(.subheadline)
                                .foregroundStyle(.noteText)
                                .monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("overview.recountNote")
                            Button("OK") { model.dismissRecountNote() }
                                .font(.subheadline)
                                .accessibilityLabel("Hinweis zur neuen Zahl ausblenden")
                                .accessibilityIdentifier("overview.recountNote.ok")
                        }
                        Text(primaryAreasText)
                            .font(.subheadline)
                            .foregroundStyle(.noteText)
                        if let text = notCountedText(ring.notCounted, besidesRing: true) {
                            Text(text)
                                .font(.subheadline)
                                .foregroundStyle(.noteText)
                                .monospacedDigit()
                        }
                        if model.interruptedPlan != nil {
                            // The unfinished run counts only once the user has decided above
                            // (unknown is not done), so "0 sortiert" next to "39 of 61 steps" is explained.
                            Text("Das unterbrochene Umsetzen zählt, sobald du oben entschieden hast.")
                                .font(.subheadline)
                                .foregroundStyle(.noteText)
                        }
                    }
                }
            }
        }
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
        return String(localized: "Gezählt werden nur Fotos, die zu deinen Hauptbereichen passen: \(names.formatted(.list(type: .and))).")
    }

    /// Every photo the ring leaves out, each in one group (`SortedCountCard.NotCounted`): with
    /// the ring's total they are the photos of "Alle 246 Fotos analysiert" below. Before, home
    /// and "kein eigenes Album" were said, and the photos without a place nowhere, so "82 von 176
    /// sortiert" and "57 Fotos von zu Hause" did not add up to 246 (P3-03). Since home no longer
    /// counts for "Länder und Orte", the total shrank without a word (review of the sorted count,
    /// 16.11.). In the core's order (`NotCounted.groups`): the one group said with a relative
    /// clause comes last, where the period closes it.
    private func notCountedText(_ notCounted: SortedCountCard.NotCounted, besidesRing: Bool) -> String? {
        var parts: [String] = []
        for group in notCounted.groups {
            switch group {
            case .home(let n):
                parts.append(String(localized: "\(n) Fotos von zu Hause"))
            case .noMainArea(let n, let isNoPlace):
                // No place, a screenshot; with "Reisen" as the only main area also photos from home.
                if isNoPlace {
                    parts.append(String(localized: "\(n) Fotos ohne Ort"))
                } else {
                    parts.append(String(localized: "\(n) Fotos außerhalb deiner Hauptbereiche"))
                }
            case .ignored(let n):
                // Ignored photos are neither sorted nor open, so they leave the ring (Fuchs 18.11.):
                // said here, so a total that shrinks after "Ignorieren" has its reason on screen.
                // With "Nur 2026" the ring counts the ignored photos of that year only ("Ignoriert"
                // in the library holds all of them).
                if case .year(let year) = model.analysisScope {
                    parts.append(String(localized: "\(n) ignorierte Fotos aus \(String(year))"))
                } else {
                    parts.append(String(localized: "\(n) ignorierte Fotos"))
                }
            case .excluded(let n):
                // Excluded from the analysis (no switch in the app today): only when there are some.
                parts.append(String(localized: "\(n) ausgeschlossene Fotos"))
            case .noAlbum(let n):
                parts.append(String(localized: "\(n) Fotos, für die sich kein eigenes Album lohnt"))
            }
        }
        guard !parts.isEmpty else { return nil }
        let list = parts.formatted(.list(type: .and))
        return besidesRing ? String(localized: "Außerdem nicht mitgezählt: \(list).")
            : String(localized: "Nicht mitgezählt: \(list).")
    }

    @ViewBuilder
    private var analysisCard: some View {
        Card {
            if let state = model.analysisCard {
                // Running, waiting, pausing, paused by the user, just finished, quick check.
                AnalysisProgressCard(state: state)
                // The finish moment sits on top of the plain card, which still says what is
                // analysed and offers "Neu prüfen" (UI run 43796538247, test6: after a long run
                // the card had neither "Alle 246 Fotos analysiert" nor "Neu prüfen").
                if case .finished = state { finishedAnalysis }
                // The photo mosaic: first analysis only (Fuchs 16.11., `ScanShowRule`).
                if model.showsScanShow { ScanShow() }
            } else if let reason = model.analysis.lastReport?.pausedBecause {
                // Ended by the device, iOS or the photo access: the reason and the way on.
                Text(reason.label).font(.headline)
                Text("Die Analyse setzt genau dort fort, wo sie aufgehört hat.").font(.subheadline).foregroundStyle(.noteText)
                Button("Fortsetzen") { model.startAnalysis(cause: .tap) }.buttonStyle(SecondaryButtonStyle())
            } else {
                finishedAnalysis
            }
            if case .year(let year) = model.analysisScope {
                trialNote(year)
            }
        }
        // A crossfade between states (running, paused, finished …), not with every count.
        .animation(reduceMotion ? nil : .smooth, value: model.analysisCard?.phase)
    }

    @ViewBuilder
    private var finishedAnalysis: some View {
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
                    Text("Zuletzt geprüft \(date.formatted(.relative(presentation: .named)))").font(.subheadline).foregroundStyle(.noteText)
                } else {
                    Text("Neue Fotos erkennt Albumist von selbst.").font(.subheadline).foregroundStyle(.noteText)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            Button { model.startAnalysis() } label: { TapTarget("Neu prüfen") }
        }
        if let report = model.analysis.lastReport, model.analysis.lastRun != nil, model.analysis.kind == .check {
            // What "Neu prüfen" found, so a check that ends after a few seconds is clearly done.
            // Photos that only got their labels ("Themen" or "Dokumente" turned on) are no new
            // photos (review of the labels fix, M2); both in one line (second review, nit).
            Group {
                if report.newPhotosAnalyzed > 0 && report.labelsAdded > 0 {
                    Text("Beim Prüfen \(report.newPhotosAnalyzed) neue Fotos analysiert und \(report.labelsAdded) weitere für die neuen Bereiche angesehen.")
                } else if report.newPhotosAnalyzed > 0 {
                    Text("Beim Prüfen \(report.newPhotosAnalyzed) neue Fotos analysiert.")
                } else if report.labelsAdded > 0 {
                    Text("Beim Prüfen \(report.labelsAdded) Fotos für die neuen Bereiche angesehen.")
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
            Label("Für die neuen Bereiche fehlen noch \(counts.labelsMissing) Fotos.", systemImage: "hourglass")
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if counts.unreadable > 0 {
            Label("\(counts.unreadable) Fotos konnten noch nicht gelesen werden. Albumist versucht es später noch einmal.", systemImage: "exclamationmark.icloud")
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let pending = model.analysis.lastReport?.placesPendingOnline, pending > 0 {
            Label("\(pending) Orte werden später genauer bestimmt.", systemImage: "moon.zzz")
                .font(.footnote).foregroundStyle(.noteText)
        }
        if let waiting = model.analysis.lastReport?.textWaitingForOriginal, waiting > 0 {
            Label("\(waiting) Dokumente liegen nur in iCloud und werden später gelesen.", systemImage: "icloud")
                .font(.footnote).foregroundStyle(.noteText)
        }
    }

    /// The trial year chosen at the start stays until the user takes in the whole library.
    @ViewBuilder
    private func trialNote(_ year: Int) -> some View {
        Divider()
        ViewThatFits(in: .horizontal) {
            HStack {
                Label("Probelauf: nur Fotos aus \(String(year))", systemImage: "calendar").font(.subheadline)
                Spacer()
                Button { model.changeScope(.all) } label: { TapTarget("Alle Jahre") }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("Probelauf: nur Fotos aus \(String(year))", systemImage: "calendar").font(.subheadline)
                Button { model.changeScope(.all) } label: { TapTarget("Ganze Mediathek dazunehmen") }
            }
        }
        .accessibilityIdentifier("analysis.trial")
    }

    private var areasSection: some View {
        let byArea = Dictionary(grouping: model.proposals, by: \.kind.area)
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            // Caps by style, not in the text (EN reads "Areas"), and a heading for VoiceOver
            // (design review W10).
            Text("Bereiche")
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.noteText)
                .padding(.top, Theme.Spacing.s)
                .padding(.leading, Theme.Spacing.xs)
            VStack(spacing: 0) {
                let areas = OrganizationArea.available.filter { model.settings.enabledAreas.contains($0) }
                ForEach(Array(areas.enumerated()), id: \.element) { index, area in
                    PushLink(.areaProposals(area), chevron: false) {
                        areaRow(area, proposals: byArea[area] ?? [])
                    }
                    .buttonStyle(.plain)
                    if index < areas.count - 1 { Divider().padding(.leading, 66) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func areaRow(_ area: OrganizationArea, proposals: [AlbumProposal]) -> some View {
        let open = proposals.filter { model.decisions[$0.id] == nil && model.match(for: $0)?.status != .alreadyComplete }.count
        let existing = proposals.filter { p in
            // The same albums as the ring (`AlbumMatcher.sortingAlbums`): a possible match gets
            // an album of its own, several matching albums count only when mostly this suggestion.
            !AlbumMatcher().sortingAlbums(model.match(for: p), kind: p.kind, title: p.title).isEmpty
        }.count
        // "0 Alben gefunden" read like an error: only mention albums that exist.
        var parts = [String(localized: "\(proposals.count) Vorschläge")]
        if existing > 0 { parts.append(String(localized: "\(existing) davon in deinen Alben")) }
        let summary = Counted.join(parts)
        let text = VStack(alignment: .leading, spacing: 2) {
            Text(area.title).font(.body.weight(.medium))
            Group {
                // While the labels come in, only the new areas wait for suggestions.
                if proposals.isEmpty, let recount = model.recount,
                   !recount.isForLabels || area == .imageCategories || area == .documents {
                    Text("Wird neu berechnet")
                } else if proposals.isEmpty {
                    Text("Noch keine Vorschläge")
                } else {
                    Text(summary)
                }
            }
            .font(.footnote).foregroundStyle(.noteText)
        }
        let chevron = Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        return Group {
            if typeSize.isAccessibilitySize {
                // Largest text sizes: icon and badge on top, the text gets the full width.
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        IconTile(systemName: area.symbol, tint: area.tint)
                        Spacer()
                        if open > 0 { StatusBadge(text: "\(open) offen") }
                        chevron
                    }
                    text
                }
            } else {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(systemName: area.symbol, tint: area.tint)
                    text
                    Spacer()
                    if open > 0 { StatusBadge(text: "\(open) offen") }
                    chevron
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .contentShape(Rectangle())
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
    /// "Alles zurücknehmen" deletes albums or folders: the confirmation says that iOS asks
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
                Button(isUndo ? LocalizedStringKey("Rest zurücknehmen") : isRemoval ? LocalizedStringKey("Rest entfernen") : LocalizedStringKey("Rest anlegen")) { Task { await model.resumeInterruptedPlan() } }
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
                        Text("Alles zurücknehmen").checkingBeside(askingUndo)
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
        .confirmationDialog("Alles zurücknehmen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Alles zurücknehmen", role: .destructive) {
                Task { await model.undoInterruptedPlan() }
            }
        } message: {
            DeleteQuestionNote.message(Text("Albumist entfernt, was sicher von Albumist ist, und sagt dir, falls etwas bleibt."),
                                       deletes: undoDeletes)
        }
    }
}

/// First use: the best albums of the library, ready to be created with one tap.
struct StarterSetCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    var onStart: ([AlbumProposal]) -> Void

    var body: some View {
        let limit = purchases.isUnlocked || Purchases.unlockedForUITests ? 10 : min(10, purchases.remainingFreeAlbums)
        let set = model.starterSet(limit: limit)
        if set.count >= 3 {
            Card {
                Text("Dein Startpaket").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Die \(set.count) besten Alben aus deiner Mediathek, fertig zum Anlegen. Du siehst vorher genau, was passiert.")
                    .font(.subheadline).foregroundStyle(.noteText)
                HStack(spacing: -14) {
                    ForEach(Array(set.prefix(5).enumerated()), id: \.element.id) { index, proposal in
                        CoverThumbnail(id: model.coverID(for: proposal), side: 64)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.background, lineWidth: 2))
                            .zIndex(Double(5 - index))
                    }
                }
                .accessibilityHidden(true)
                Text(ListFormatter.localizedString(byJoining: set.prefix(3).map { model.userTitles[$0.id] ?? $0.title })
                     + (set.count > 3 ? " …" : ""))
                    .font(.footnote).foregroundStyle(.noteText)
                    .compactLineLimit(2)
                Button {
                    onStart(set)
                } label: {
                    if purchases.isUnlocked {
                        Text("\(set.count) Alben anlegen")
                    } else {
                        Text("\(set.count) Alben kostenlos anlegen")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
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
            Text("Albumist sieht nur die \(model.facts.count) Fotos, die du freigegeben hast. Für Alben aus deiner ganzen Mediathek braucht Albumist vollen Zugriff.")
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
