import StoreKit
import SwiftUI
import SortlyCore
import SortlyEngine

/// Final preview before anything changes (prompt §7, Schritt 8–10): summary, guarantees,
/// conflicts, execution with progress, result and undo.
///
/// The button that runs the plan stands at the bottom of the screen, above the tab bar, with the
/// promise in one line above it (`applyBar`; review P3-05 = G3-05: it was the last thing of the
/// plan, below the fold, and so were the promises). It is there only while the plan is on screen
/// and can run; what stops the plan stands at the top of the plan instead (`Obstacle`).
///
/// The body only reads what it shows. Everything worked out from the plan (summary, album
/// list, conflict texts, free albums, the albums of the sorting show) is `PlanReviewFacts`,
/// made off the main thread once per plan and album list; the step counter while the plan
/// runs is drawn by `ExecutionProgressBar` alone. UI run 44038288087 saw the main thread busy
/// for 52 and 68 s drawing this screen again and again, right after "Anlegen" in the
/// add-to-album sheet.
struct PlanReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    /// A plan built elsewhere (album merge); otherwise the accepted proposals are planned.
    var prebuilt: ChangePlan? = nil
    @State private var loading = true
    /// Albums of the plan that is running, for the "photos fly into albums" show.
    @State private var show: [SortingShow.Album]?
    /// What the screen shows of `model.plan`, made by `makeFacts()`.
    @State private var facts: PlanReviewFacts?
    /// The plan and album list `facts` were made for.
    @State private var factsMadeFor: FactsKey?
    /// Suggestions were selected when the facts were made ("Auswahl aufheben" is offered).
    @State private var hasSelection = false
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// At the accessibility text sizes and in landscape on an iPhone the bar is compact (`compactBar`).
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The screen loads once; coming back from another tab keeps the result and its undo.
    @State private var didLoad = false
    private static let top = "plan.top"
    /// Padding around the screen's content; the sorting show keeps it free when it fits itself
    /// to the screen (`SortingShow.screenPadding`).
    private static let contentPadding = Theme.Spacing.l

    /// The facts are made again for another plan, or when the albums in Photos changed.
    private struct FactsKey: Equatable {
        var plan: SortlyID?
        var steps: Int
        var conflicts: Int
        var inventory: Int

        /// The same plan (id, steps and conflicts), whatever the album list.
        func samePlan(as other: FactsKey?) -> Bool {
            guard let other else { return false }
            return plan == other.plan && steps == other.steps && conflicts == other.conflicts
        }
    }

    var body: some View {
        let _ = MainThreadWatch.shared.count("plan review body")
        // A reader, not `scrollPosition(_:)`: that binding is written by the scroll view while
        // it moves, and each write drew the whole screen again.
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    if let show {
                        SortingShow(albums: show, screenPadding: Self.contentPadding) {
                            withAnimation(.smooth(duration: 0.45)) { self.show = nil }
                        }
                        .transition(.opacity)
                    } else if let result = model.execution.finished, !model.execution.isRunning {
                        ResultCard(plan: result)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else if model.execution.isRunning {
                        runningCard
                    } else if loading || (model.plan != nil && !factsKey.samePlan(as: factsMadeFor)) {
                        // Facts of another plan (or of this plan before "Nur die Gratis-Alben"
                        // or a change of steps) are never shown. After a change of the album
                        // list alone the shown facts stay until the new ones are made, so the
                        // screen neither jumps to the top nor takes away "Anlegen" while Photos
                        // reports a change.
                        ProgressView("Plan wird erstellt").frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let previewed {
                        planContent(previewed.plan, previewed.facts, obstacle: previewed.obstacle)
                    } else {
                        ContentUnavailableView("Nichts zu tun", systemImage: "checkmark.circle",
                                               description: Text("Es gibt gerade keine ausgewählten Vorschläge."))
                    }
                    if let failure = model.execution.failure {
                        Card {
                            Label("Nicht alles hat geklappt", systemImage: "exclamationmark.triangle").font(.headline)
                            Text(failure).font(.subheadline).foregroundStyle(.noteText)
                        }
                    }
                }
                .padding(Self.contentPadding)
                .id(Self.top)
            }
            // The button in reach while the plan scrolls under it (review P3-05 = G3-05). In the
            // safe area, so above the tab bar and never behind it; only while the plan is on
            // screen and can run: not during the sorting show, the run or over the result.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let previewed, previewed.obstacle == nil {
                    applyBar(previewed.plan, previewed.facts) {
                        reader.scrollTo(Self.top, anchor: .top)
                    }
                    .motionAwareTransition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(Theme.background)
        // One name for one step (design review W2), and it follows the step: the preview, the
        // run with its sorting show, the result (review P3-15, `PlanReviewPhase`).
        .navigationTitle(phase.title)
        // Leaving mid-way would look like cancelling; the work goes on either way.
        .navigationBarBackButtonHidden(model.execution.isRunning)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ExecutionHaptics(execution: model.execution, holdSuccess: show != nil))
        .task {
            await model.refreshAccess()
            guard !didLoad else { return }
            didLoad = true
            if !model.execution.isRunning {
                // A new visit starts clean (the last result stays while the user only switched
                // tabs). Written only when there is something to clear: every write redraws
                // every screen that reads `execution`.
                if model.execution.finished != nil { model.execution.finished = nil }
                if model.execution.failure != nil { model.execution.failure = nil }
                if let prebuilt { model.plan = prebuilt } else { await model.buildPlan() }
            }
            loading = false
        }
        .task(id: factsKey) { await makeFacts() }
        .onChange(of: scenePhase) { _, phase in
            // Back from the Settings app: the full-access card disappears by itself.
            if phase == .active { Task { await model.refreshAccess() } }
        }
    }

    /// What the screen shows, in the order of the body: a run (the sorting show or the
    /// progress card), its result, the preview.
    private var phase: PlanReviewPhase {
        PlanReviewPhase(running: model.execution.isRunning, runningPlan: model.execution.planID,
                        previewedPlan: model.plan?.id, hasResult: model.execution.finished != nil)
    }

    private var factsKey: FactsKey {
        let plan = model.plan
        return FactsKey(plan: plan?.id, steps: plan?.steps.count ?? 0, conflicts: plan?.conflicts.count ?? 0,
                        inventory: model.inventoryVersion)
    }

    /// The plan on screen, with what stops it: nil during the sorting show, the run, over a
    /// result and while the plan is made. One value for the plan and the bar under it, so the
    /// button never stands where the plan is not shown.
    private var previewed: (plan: ChangePlan, facts: PlanReviewFacts, obstacle: Obstacle?)? {
        guard show == nil, !model.execution.isRunning, model.execution.finished == nil, !loading,
              let plan = model.plan, let facts, factsKey.samePlan(as: factsMadeFor) else { return nil }
        return (plan, facts, obstacle(for: plan, facts))
    }

    /// What stops the plan before it runs; shown at the top of the plan instead of the button.
    private enum Obstacle {
        /// Only selected photos are shared: Photos lets an app make albums only with all.
        case fullAccess
        /// A plan that was cut off is settled first (plugin review K2).
        case interruptedPlan
        /// More albums than are still free.
        case unlock
    }

    /// In the order the preview has always asked (`AppModel.execute` and `run` ask the same).
    private func obstacle(for plan: ChangePlan, _ facts: PlanReviewFacts) -> Obstacle? {
        if model.access == .limited && !UITestSupport.isRunning { return .fullAccess }
        if PlanGate.refusal(for: plan, interrupted: model.interruptedPlan) != nil { return .interruptedPlan }
        if !purchases.allows(albums: facts.freeAlbumUse) { return .unlock }
        return nil
    }

    /// Works out what the screen shows of the current plan, off the main thread.
    private func makeFacts() async {
        guard let plan = model.plan else { return }
        let key = factsKey
        let inventory = model.inventory
        let order = MainThreadWatch.shared.section("plan review: order") {
            model.acceptedProposals.inDisplayOrder().map(\.id)
        }
        // Covers and the sorting show leave sensitive documents out (`PreviewRank`).
        let ranks = model.previewRanks
        let made = await Task.detached(priority: .userInitiated) {
            PlanReviewFacts(plan: plan, inventory: inventory, order: order, ranks: ranks)
        }.value
        guard !Task.isCancelled else { return }
        facts = made
        factsMadeFor = key
        hasSelection = !order.isEmpty
    }

    // MARK: Plan

    /// The plan, from what stops it (if anything) to the way out. The button that runs it is
    /// not part of it: it stands in the bar at the bottom (`applyBar`).
    @ViewBuilder
    private func planContent(_ plan: ChangePlan, _ facts: PlanReviewFacts, obstacle: Obstacle?) -> some View {
        let summary = facts.summary
        // What stops the plan is the first thing seen as the preview opens (review P3-05): it
        // stood at the end, where the button stood, below the fold.
        if let obstacle { obstacleCard(obstacle, facts) }
        Text("Das ändert sich in Fotos").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
        if plan.retries != nil {
            // "Fehlendes erneut versuchen" (I16): say that this is not the whole plan again.
            Text("Nur was beim letzten Anlegen gefehlt hat. Schon Erledigtes bleibt, wie es ist, und wird nicht doppelt angelegt.")
                .font(.subheadline).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        Card {
            if summary.newFolders > 0 { row("folder.badge.plus", "Neue Ordner", summary.newFolders) }
            row("rectangle.stack.badge.plus", "Neue Alben", summary.newAlbums)
            if summary.extendedAlbums > 0 { row("plus.rectangle.on.rectangle", "Ergänzte Alben", summary.extendedAlbums) }
            row("photo", "Betroffene Fotos und Videos", summary.distinctAssets)
            if summary.totalAssignments != summary.distinctAssets {
                row("square.on.square", "Album-Zuordnungen", summary.totalAssignments)
            }
            if summary.renamedCollections > 0 { row("pencil", "Umbenannt", summary.renamedCollections) }
            if summary.movedCollections > 0 { row("arrow.right.square", "Verschoben", summary.movedCollections) }
            if summary.removedMemberships > 0 { row("minus.rectangle", "Aus Alben genommen", summary.removedMemberships) }
            if summary.deletedContainers > 0 { row("rectangle.stack.badge.minus", "Entfernte Alben", summary.deletedContainers) }
        }

        if !facts.albums.isEmpty { PlanAlbumList(albums: facts.albums) }

        // The promises themselves stand in one line above the button (`promise`); what they
        // mean stays here, under the albums.
        Text("Fotos werden nur in Alben einsortiert. Die Originale bleiben, wo sie sind, und jede Änderung lässt sich rückgängig machen.")
            .font(.footnote).foregroundStyle(.noteText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Spacing.l)

        if !facts.conflicts.isEmpty {
            Card {
                Label("Bitte prüfen", systemImage: "exclamationmark.triangle").font(.headline)
                ForEach(Array(facts.conflicts.enumerated()), id: \.offset) { _, conflict in
                    Text(ConflictText.text(conflict))
                        .font(.subheadline).foregroundStyle(.noteText)
                }
            }
        }

        // Where room is short the bar holds the button and what explains it (`compactBar`); the
        // promise and the free albums left stand here, at the end of the plan.
        if obstacle == nil && compactBar {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                promise(summary)
                freeAlbumNote(facts)
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
        if prebuilt == nil && hasSelection {
            // The way out: nothing selected, back to the open suggestions.
            Button("Auswahl aufheben") {
                model.clearSelection()
                dismiss()
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    /// What stops the plan, in the words it always had; it stands where the preview opens.
    @ViewBuilder
    private func obstacleCard(_ obstacle: Obstacle, _ facts: PlanReviewFacts) -> some View {
        switch obstacle {
        case .fullAccess:
            FullAccessCard()
        case .interruptedPlan:
            // One plan at a time (plugin review K2): the one that was cut off is settled first.
            Card {
                // Names what was cut off: creating albums or taking them back.
                let isUndo = model.interruptedPlan?.reverts != nil
                Label(isUndo ? LocalizedStringKey("Erst das unterbrochene Rückgängigmachen abschließen") : LocalizedStringKey("Erst das unterbrochene Anlegen abschließen"),
                      systemImage: "pause.circle").font(.headline)
                Text(isUndo
                     ? LocalizedStringKey("Ein früheres Rückgängigmachen wurde unterbrochen. Entscheide in der Übersicht, wie es weitergeht. Danach geht es hier weiter, und nichts wird doppelt rückgängig gemacht.")
                     : LocalizedStringKey("Ein früheres Anlegen wurde unterbrochen. Entscheide in der Übersicht, wie es weitergeht. Danach geht es hier weiter, und nichts wird doppelt angelegt."))
                    .font(.subheadline).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .unlock:
            UnlockCard(albumsInPlan: facts.freeAlbumUse, onLimit: limitToFreeAlbums)
        }
    }

    /// The bar at the bottom of the preview, as in Apple's own confirmations: the promise in
    /// one line, the button, and what the button needs said. On the screen's background, so
    /// the plan that scrolls under it never shows through its words, and inside the safe area,
    /// so it ends above the tab bar.
    private func applyBar(_ plan: ChangePlan, _ facts: PlanReviewFacts, scrollToTop: @escaping () -> Void) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            if !compactBar { promise(facts.summary) }
            applyButton(plan, facts, scrollToTop: scrollToTop)
            // Why the button waits and that iOS asks next: beside it at every size (P3-07).
            applyNotes(facts)
            if !compactBar { freeAlbumNote(facts) }
        }
        .multilineTextAlignment(.center)
        // As the onboarding's button: clear of the tab bar, which takes taps a little above it.
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        // A container of its own: an identifier on a plain container is handed down to every
        // element inside (`EmptyLibraryCard`), and the button keeps "plan.apply". The
        // accessibility test counts rows passing under the bar as cut, as under the tab bar.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan.bar")
    }

    /// Where room is short the bar holds the button and what explains it, nothing more: at the
    /// accessibility text sizes, and in landscape on an iPhone, where the whole bar could fill
    /// most of the room between the navigation bar and the tab bar (second review of P3-05).
    private var compactBar: Bool {
        typeSize.isAccessibilitySize || verticalSizeClass == .compact
    }

    /// Runs the plan, with the sorting show when photos go into albums.
    private func applyButton(_ plan: ChangePlan, _ facts: PlanReviewFacts, scrollToTop: @escaping () -> Void) -> some View {
        Button {
            let albums = SortingShow.albums(from: facts.filledAlbums)
            if !albums.isEmpty {
                withAnimation(.smooth(duration: 0.4)) {
                    show = albums
                    scrollToTop()
                }
            }
            Task { await model.execute(plan) }
        } label: {
            applyTitle(facts.summary)
        }
        .buttonStyle(PrimaryButtonStyle())
        // Not while a change in "Dein Zuhause" makes the suggestions again (the plan would
        // not start, after the fly animation).
        .disabled(facts.isBlocking || facts.hasNoSteps || model.homeChangeRunning)
        .accessibilityIdentifier("plan.apply")
    }

    /// What the button needs said beside it at every size: why it waits, and that iOS asks
    /// next (second review of P3-05: at the accessibility sizes both stood at the end of the
    /// plan, and a removal could be started without the iOS question announced).
    @ViewBuilder
    private func applyNotes(_ facts: PlanReviewFacts) -> some View {
        let summary = facts.summary
        if facts.isBlocking {
            Text("Erst die markierten Punkte klären. Das geht im Vorschlag oben rechts unter „…“ › „Anpassen“.")
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A removal from "Alben von Albumist", or the retry of one, deletes albums: iOS asks
        // right after this button, and this screen is the confirmation before it (review
        // 18.11., P3-07).
        if summary.deletedContainers > 0 {
            DeleteQuestionNote.text
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The free albums this plan leaves: under the button, or at the end of the plan where
    /// room is short (`compactBar`).
    @ViewBuilder
    private func freeAlbumNote(_ facts: PlanReviewFacts) -> some View {
        let albums = facts.freeAlbumUse
        if !purchases.isUnlocked && !Purchases.unlockedForUITests && albums > 0 && purchases.allows(albums: albums) {
            Text("Kostenlos. Danach hast du noch \(purchases.remainingFreeAlbums - albums) von \(Purchases.freeAlbumLimit) Gratis-Alben.")
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The two promises in one line (review P3-05; design review W1: said as what does not
    /// happen, as "0 Originale gelöscht" left "Originale gelöscht" in the mind when skimming or
    /// listening). A number only if a plan ever were to do it.
    private func promise(_ summary: PlanSummary) -> some View {
        Group {
            if summary.originalsDeleted == 0 && summary.originalCopiesCreated == 0 {
                guarantee(Text("Kein Original wird gelöscht oder kopiert.").foregroundStyle(.noteText))
            } else {
                if summary.originalsDeleted > 0 { warning(Text("\(summary.originalsDeleted) Originale werden gelöscht")) }
                if summary.originalCopiesCreated > 0 { warning(Text("\(summary.originalCopiesCreated) Kopien werden angelegt")) }
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Die ersten N jetzt anlegen", only for plans built from accepted suggestions.
    private var limitToFreeAlbums: (() -> Void)? {
        guard prebuilt == nil, purchases.remainingFreeAlbums > 0 else { return nil }
        let free = purchases.remainingFreeAlbums
        return { Task { await model.keepFirstAccepted(free) } }
    }

    /// The button says what it does (design review W2: "Jetzt umsetzen" was the fourth name
    /// for this step).
    private func applyTitle(_ summary: PlanSummary) -> Text {
        if summary.newAlbums > 0 { return Text("Alben jetzt anlegen") }
        if summary.removedMemberships == 0 && summary.deletedContainers == 0 { return Text("Fotos jetzt einsortieren") }
        return Text("Änderungen jetzt ausführen")
    }

    private func guarantee(_ text: Text) -> some View {
        Label { text } icon: { Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.accent) }
    }

    private func warning(_ text: Text) -> some View {
        Label { text } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.tint(for: .documents)) }
    }

    /// One line of the summary. Icons share one width so the titles line up.
    private func row(_ symbol: String, _ title: LocalizedStringKey, _ value: Int) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
                .hiddenAtAccessibilitySizes()
            Text(title)
            Spacer(minLength: Theme.Spacing.s)
            Text(value.formatted()).monospacedDigit().font(.body.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private var runningCard: some View {
        Card {
            // An undo of the result runs here too: it says what really happens.
            Text(phase.title).font(.headline)
            ExecutionProgressBar(showsCount: true)
            Text("Du kannst die App dabei offen lassen. Bricht etwas ab, setzt Albumist beim nächsten Start sicher fort.")
                .font(.footnote).foregroundStyle(.noteText)
        }
    }
}

/// The progress bar of the running plan, with "N von M Schritten" when asked. A view of its
/// own: it is the only part of a screen drawn again after every step (`AppModel.ExecutionProgress`).
///
/// While a step has waited 10 s or more for Photos (`PhotosDeadline.slowFor`, app-speed
/// 18.11.2026), a line says so instead of the bar standing still without a word. Not while
/// iOS asks the user before albums are deleted: that wait is the user's.
struct ExecutionProgressBar: View {
    @Environment(AppModel.self) private var model
    var showsCount = false

    var body: some View {
        let progress = model.executionProgress
        ProgressView(value: Double(progress.completedSteps), total: Double(max(1, progress.totalSteps)))
            .tint(Theme.accent)
        if showsCount {
            Text("\(progress.completedSteps) von \(progress.totalSteps) Schritten")
                .font(.footnote).foregroundStyle(.noteText).monospacedDigit()
        }
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if PhotoKitLibrary.deadline.slowFor() != nil {
                Label("Fotos antwortet gerade nicht. Albumist wartet noch.", systemImage: "hourglass")
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("execution.photosSlow")
            }
        }
    }
}

/// Haptic feedback when the changes are done, or when something went wrong.
/// (A separate modifier keeps the screen's body quick to type-check.)
private struct ExecutionHaptics: ViewModifier {
    var execution: AppModel.ExecutionState
    /// While the sorting show plays, the success tap waits for its end.
    var holdSuccess: Bool

    func body(content: Content) -> some View {
        let finished: SortlyID? = holdSuccess ? nil : execution.finished?.id
        return content
            .sensoryFeedback(.success, trigger: finished) { (old: SortlyID?, new: SortlyID?) in
                old == nil && new != nil
            }
            .sensoryFeedback(.error, trigger: execution.failure) { (old: String?, new: String?) in
                old == nil && new != nil
            }
    }
}

/// Result of an executed plan (design 7.1, N-07): what happened, counted as in its receipt and
/// named by what the plan did (`ResultHeadline`): big "10 neue Alben", small "mit 342 Fotos",
/// where the new albums are, a way to Photos, and "Rückgängig machen" with what it does. A
/// removal says "1 Album entfernt", never "0 Fotos einsortiert" or where new albums are.
struct ResultCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator: Navigator?
    var plan: ChangePlan
    @State private var confirmUndo = false
    /// The undo deletes albums or folders: the confirmation says that iOS asks next (P3-07).
    @State private var undoDeletes = false
    /// Albumist reads the albums to see whether the undo deletes any: a spinner beside the
    /// button, and no second tap meanwhile (third review of P3-07, SHOULD-2).
    @State private var askingUndo = false
    @State private var appeared = false
    @State private var photosDidNotOpen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        // What really happened, counted as in the receipt ("Zahlen wie im Beleg"; photos that
        // were no longer there are not counted), named by what the plan did.
        let receipt = PlanReceipt(plan: plan, inventory: model.inventory)
        let headline = ResultHeadline(receipt, kind: PlanReceipt.Kind(plan))
        let failed = receipt.failedSteps
        Card {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: failed > 0 ? "exclamationmark.circle.fill"
                      : headline.kind == .undone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(failed == 0 ? Theme.accent : Theme.tint(for: .documents))
                    .symbolEffect(.bounce, value: appeared)
                    .accessibilityHidden(true)
                ResultLead(headline: headline, partly: failed > 0)
                if failed > 0 {
                    Text(ResultText.failed(failed, kind: headline.kind))
                        .font(.footnote).foregroundStyle(.noteText)
                        .multilineTextAlignment(.center)
                }
                if receipt.unavailablePhotos > 0 && headline.kind == .created {
                    Text("\(receipt.unavailablePhotos) \(receipt.unavailablePhotos.formatted()) Fotos waren nicht mehr in deiner Mediathek und wurden nicht einsortiert.")
                        .font(.footnote).foregroundStyle(.noteText)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            // Where the new albums are, above the way to Photos (draft E3). Only after a run that
            // made new albums: a removal or an undo has none (N-07).
            if let way = ResultText.whereNewAlbums(headline, root: model.settings.rootFolderTitle) {
                Text(way)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            if let photos = URL(string: "photos-redirect://") {
                // iOS lets apps open Fotos, but not a particular album (first device test 15.11.:
                // "Ich springe nicht zu meinen Alben"). So the button says what it does, and the
                // way to the albums is written above it.
                // "photos-redirect://" is not documented by Apple (plugin review N8). Should iOS
                // one day not open it, the button says so instead of staying silent.
                Button("Fotos-App öffnen") {
                    openURL(photos) { accepted in photosDidNotOpen = !accepted }
                }
                .buttonStyle(PrimaryButtonStyle())
                if photosDidNotOpen {
                    Text("Die Fotos-App ließ sich nicht öffnen. Öffne sie bitte selbst vom Home-Bildschirm.")
                        .font(.footnote).foregroundStyle(.noteText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            // Pushed by value (`AppScreen`): the receipt may push "Fehlendes erneut versuchen".
            Button {
                Navigator.push(.receipt(PlanToken(plan)), on: navigator)
            } label: {
                Text("Alle Änderungen ansehen")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("result.receipt")
            // A real button that says what it does (draft E3); an undo is not taken back itself.
            if let note = headline.undoNote, !model.undonePlans.contains(plan.id) {
                Button {
                    guard !askingUndo else { return }
                    askingUndo = true
                    Task {
                        // Full access first: not "not possible" after the dialog was confirmed.
                        guard await model.changesHaveFullAccess() else { askingUndo = false; return }
                        undoDeletes = await model.undoDeletesCollections(plan)
                        askingUndo = false
                        confirmUndo = true
                    }
                } label: {
                    Label("Rückgängig machen", systemImage: "arrow.uturn.backward").checkingBeside(askingUndo)
                }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(askingUndo)
                Text(ResultText.undoNote(note))
                    .font(.footnote).foregroundStyle(.noteText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            appeared = true
            ReviewPrompt.shared.screenAppeared()
        }
        // The App Store rating question never covers the result: it may come only once the user
        // has left it (and its receipt), a moment later (`ReviewPrompt`, `ReviewPromptPolicy`).
        .onDisappear { ReviewPrompt.shared.screenDisappeared() }
        .task(id: plan.id) {
            // Seen: on screen for a moment, again for each plan the card shows (an undo).
            do { try await Task.sleep(for: ReviewPrompt.seenAfter) } catch { return }
            ReviewPrompt.shared.resultSeen(plan)
        }
        .confirmationDialog("Änderungen rückgängig machen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Rückgängig machen", role: .destructive) {
                Task { await model.undo(plan) }
            }
        } message: {
            DeleteQuestionNote.message(Text(ResultText.undoQuestion(PlanReceipt.Kind(plan))), deletes: undoDeletes)
        }
    }
}

/// The big line of the result (design 7.1): the count in the wide figures with what it counts
/// below it ("10" over "neue Alben"), read by VoiceOver as one heading ("10 neue Alben"), and
/// the line below in the note grey ("mit 342 Fotos"; no arrow). Without a count the heading is
/// a word as before ("Rückgängig gemacht", "Fertig"; the UI tests wait for it).
private struct ResultLead: View {
    let headline: ResultHeadline
    /// Steps did not happen: "Teilweise fertig" above the count.
    let partly: Bool
    /// Big like the draft's number; a long count shrinks to fit instead of being cut.
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 60

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if let count = ResultText.count(headline.lead) {
                if partly {
                    Text("Teilweise fertig")
                        .font(.headline)
                }
                VStack(spacing: 0) {
                    Text(count, format: .number)
                        .font(.system(size: numberSize, weight: .heavy).width(.expanded).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    Text(ResultText.noun(headline.lead))
                        .font(.title2.weight(.bold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            } else {
                Text(ResultText.heading(headline.lead, partly: partly))
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
            }
            if let detail = headline.detail {
                Text(ResultText.detail(detail))
                    .font(.body)
                    .foregroundStyle(.noteText)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

/// The words of the result (`ResultHeadline`): what the count counts, the line below it, where
/// new albums are, and what "Rückgängig machen" does. The counts are the receipt's.
enum ResultText {
    /// The big count; nil when the headline has none ("Rückgängig gemacht", "Fertig").
    static func count(_ lead: ResultHeadline.Lead) -> Int? {
        switch lead {
        case .newAlbums(let count), .extendedAlbums(let count), .sortedPhotos(let count), .removedAlbums(let count),
             .takenOutPhotos(let count):
            count
        case .undone, .plain:
            nil
        }
    }

    /// What the count counts, below the number (as the atlas's "1 Land", "2 Länder").
    static func noun(_ lead: ResultHeadline.Lead) -> String {
        switch lead {
        case .newAlbums(let count): count == 1 ? String(localized: "neues Album") : String(localized: "neue Alben")
        case .extendedAlbums(let count): count == 1 ? String(localized: "Album ergänzt") : String(localized: "Alben ergänzt")
        case .sortedPhotos(let count): count == 1 ? String(localized: "Foto einsortiert") : String(localized: "Fotos einsortiert")
        case .removedAlbums(let count): count == 1 ? String(localized: "Album entfernt") : String(localized: "Alben entfernt")
        case .takenOutPhotos(let count):
            count == 1 ? String(localized: "Foto herausgenommen") : String(localized: "Fotos herausgenommen")
        case .undone, .plain: heading(lead, partly: false)
        }
    }

    /// The heading of a result without a count.
    static func heading(_ lead: ResultHeadline.Lead, partly: Bool) -> String {
        if lead == .undone {
            return partly ? String(localized: "Teilweise rückgängig gemacht") : String(localized: "Rückgängig gemacht")
        }
        return partly ? String(localized: "Teilweise fertig") : String(localized: "Fertig")
    }

    /// The line below the count.
    static func detail(_ detail: ResultHeadline.Detail) -> String {
        switch detail {
        case .withPhotos(let count):
            String(localized: "mit \(count) \(count.formatted()) Fotos")
        case .extendedAndSorted(let albums, let photos):
            Counted.join([String(localized: "\(albums) Alben ergänzt"),
                          String(localized: "\(photos) \(photos.formatted()) Fotos einsortiert")])
        case .photosStay:
            String(localized: "Die Fotos bleiben in deiner Mediathek.")
        case .undoRemoved:
            String(localized: "Albumist hat seine Alben und Zuordnungen wieder entfernt. Deine Fotos sind unverändert.")
        case .undoRestored:
            String(localized: "Was Albumist entfernt hatte, ist wieder da. Deine Fotos sind unverändert.")
        }
    }

    /// Where the new albums are (draft E3: "Du findest sie in Fotos unter Sammlungen ›
    /// Alben."), in Albumist's folder when it has one. Nil unless the run made new albums.
    static func whereNewAlbums(_ headline: ResultHeadline, root: String) -> String? {
        guard headline.showsWhereNewAlbumsAre, case .newAlbums(let count) = headline.lead else { return nil }
        let folder = root.trimmingCharacters(in: .whitespaces)
        switch (count == 1, folder.isEmpty) {
        case (true, true): return String(localized: "Du findest es in Fotos unter Sammlungen › Alben.")
        case (true, false): return String(localized: "Du findest es in Fotos unter Sammlungen › Alben, im Ordner „\(folder)“.")
        case (false, true): return String(localized: "Du findest sie in Fotos unter Sammlungen › Alben.")
        case (false, false): return String(localized: "Du findest sie in Fotos unter Sammlungen › Alben, im Ordner „\(folder)“.")
        }
    }

    /// What "Rückgängig machen" on the result does, below the button (draft E3).
    static func undoNote(_ note: ResultHeadline.UndoNote) -> String {
        switch note {
        case .removesNewAlbums(let count):
            String(localized: "Entfernt die \(count) neuen Alben. Deine Fotos bleiben.")
        case .takesOutAddedPhotos(let albums):
            String(localized: "Nimmt die hinzugefügten Fotos wieder aus deinen \(albums) Alben. Deine Fotos bleiben.")
        case .removesNewAlbumsAndAddedPhotos:
            String(localized: "Entfernt die neuen Alben und nimmt die hinzugefügten Fotos wieder aus deinen Alben. Deine Fotos bleiben.")
        case .bringsBackAlbums(let count):
            String(localized: "Legt die \(count) Alben mit denselben Fotos wieder an.")
        case .putsBackPhotos:
            String(localized: "Legt die herausgenommenen Fotos wieder zurück.")
        case .general:
            String(localized: "Entfernt nur die neuen Alben und Zuordnungen dieser Änderungen. Deine Fotos bleiben.")
        }
    }

    /// The question before the undo; `DeleteQuestionNote` adds that the photos stay, or that iOS asks.
    static func undoQuestion(_ kind: PlanReceipt.Kind) -> String {
        kind == .removed ? String(localized: "Albumist bringt zurück, was es entfernt hat.")
            : String(localized: "Albumist entfernt die angelegten Alben und Zuordnungen wieder.")
    }

    /// Steps that did not happen, with what that means for the kind of plan.
    static func failed(_ count: Int, kind: PlanReceipt.Kind) -> String {
        switch kind {
        case .created:
            String(localized: "\(count) Schritte konnten nicht ausgeführt werden. Die fehlenden Fotos schlägt Albumist bei der nächsten Analyse wieder vor.")
        case .removed:
            String(localized: "\(count) Schritte konnten nicht ausgeführt werden.")
        case .undone:
            String(localized: "\(count) Schritte konnten nicht ausgeführt werden. Was Albumist nicht rückgängig machen konnte, bleibt, wie es ist.")
        }
    }
}

extension PlanReviewPhase {
    /// The screen's title, and the heading of the card while a plan runs.
    var title: LocalizedStringKey {
        switch self {
        case .preview: LocalizedStringKey("Vorschau")
        case .creating: LocalizedStringKey("Alben werden angelegt")
        case .changing: LocalizedStringKey("Alben werden geändert")
        case .result: LocalizedStringKey("Ergebnis")
        }
    }
}

enum ConflictText {
    static func text(_ conflict: PlanConflict, inventory: CollectionInventory) -> String {
        text(ResolvedConflict(conflict, inventory: inventory))
    }

    /// The text of a conflict whose album name was looked up before (`PlanReviewFacts`).
    static func text(_ resolved: ResolvedConflict) -> String {
        func title(_ id: CollectionID) -> String { resolved.albumTitle ?? "?" }
        switch resolved.conflict {
        case .duplicatePlannedTitle(let title, _, _):
            return String(localized: "Zwei neue Alben heißen „\(title)“. Bitte benenne eines um.")
        case .titleExistsInFolder(let title, _):
            // Albumist makes it under the same name, next to the other one (review P2-02).
            return String(localized: "Es gibt schon ein anderes Album „\(title)“. Danach hast du zwei Alben mit diesem Namen.")
        case .albumMissing(let id):
            return String(localized: "Das Album „\(title(id))“ gibt es nicht mehr.")
        case .albumNotEditable(let id):
            return String(localized: "„\(title(id))“ kann nicht bearbeitet werden.")
        case .albumChangedSincePreview(let id):
            return String(localized: "„\(title(id))“ wurde inzwischen geändert. Bitte prüfe den Vorschlag erneut.")
        case .assetsUnavailable(let count):
            return String(localized: "\(count) \(count.formatted()) Fotos sind nicht mehr in der Mediathek.")
        case .writeAccessMissing:
            return String(localized: "Albumist hat keinen vollen Zugriff auf deine Fotos.")
        }
    }
}

/// Shown instead of "Jetzt umsetzen" when only selected photos are shared: Photos lets an
/// app create albums only with full access, so the plan would fail half way.
struct FullAccessCard: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Card {
            Label("Voller Zugriff nötig", systemImage: "photo.on.rectangle.angled").font(.headline)
            Text("Albumist kann Alben nur anlegen, wenn du alle Fotos freigibst. Gerade sind nur ausgewählte Fotos freigegeben.")
                .font(.subheadline).foregroundStyle(.noteText)
            Text("Einstellungen › Apps › Albumist › Fotos › Voller Zugriff")
                .font(.footnote).foregroundStyle(.noteText)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Einstellungen öffnen") { openURL(url) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

/// Shown when a plan needs more albums than are still free.
struct UnlockCard: View {
    @Environment(Purchases.self) private var purchases
    var albumsInPlan: Int
    /// Shrinks the plan to the albums that are still free ("Die ersten N jetzt anlegen").
    var onLimit: (() -> Void)? = nil
    @State private var redeeming = false

    var body: some View {
        Card {
            Label("Albumist freischalten", systemImage: "lock.open").font(.headline)
            Text("Für diese Auswahl brauchst du \(albumsInPlan) Alben. Kostenlos sind noch \(purchases.remainingFreeAlbums). Mit einem einmaligen Kauf sortierst du unbegrenzt, ohne Abo.")
                .font(.subheadline).foregroundStyle(.noteText)
            // Without a price: "Preis wird geladen …", not tappable (plugin review W7).
            UnlockButton(prominent: true)
            // Text buttons with a 44 pt tap area (design review W9: the bare text was ~20 pt).
            HStack {
                Button { Task { await purchases.restore() } } label: {
                    Text("Kauf wiederherstellen").minimumHitTarget()
                }
                .disabled(purchases.isPurchasing)
                Spacer()
                Button { redeeming = true } label: {
                    Text("Code einlösen").minimumHitTarget()
                }
            }
            .font(.subheadline)
            .offerCodeRedemption(isPresented: $redeeming) { _ in
                Task { await purchases.refreshEntitlements(mayLock: false) }
            }
            if let onLimit {
                Button("Die ersten \(purchases.remainingFreeAlbums) jetzt kostenlos anlegen", action: onLimit)
                    .buttonStyle(SecondaryButtonStyle())
                Text("Die übrigen Vorschläge bleiben offen und laufen dir nicht weg.")
                    .font(.footnote).foregroundStyle(.noteText)
            } else {
                Text("Tipp: Du kannst auch weniger Vorschläge auf einmal auswählen.")
                    .font(.footnote).foregroundStyle(.noteText)
            }
            if let error = purchases.lastError {
                ErrorNote(text: error)
            }
        }
        // The price comes from StoreKit; a start without network is made up for here.
        .task { await purchases.loadProductIfNeeded() }
    }
}

/// Every album of the plan with its folder and photo count, so it is clear what
/// Albumist will make before anything happens (Fuchs, 14.11.).
struct PlanAlbumList: View {
    let albums: [PlannedAlbumPreview]
    @State private var showAll = false
    private let collapsedCount = 6

    var body: some View {
        let visible = showAll ? albums : Array(albums.prefix(collapsedCount))
        Card {
            Group {
                if albums.allSatisfy(\.isNew) {
                    Text("Diese Alben werden angelegt")
                } else {
                    Text("Diese Alben werden angelegt oder ergänzt")
                }
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            ForEach(visible) { album in
                PlanAlbumRow(album: album)
                if album.id != visible.last?.id { Divider() }
            }
            if albums.count > collapsedCount {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { showAll.toggle() }
                } label: {
                    Group {
                        if showAll {
                            Text("Weniger anzeigen")
                        } else {
                            Text("Alle \(albums.count) Alben anzeigen")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
        }
    }
}

private struct PlanAlbumRow: View {
    let album: PlannedAlbumPreview
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        AdaptiveStack(spacing: Theme.Spacing.m) {
            cover
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.body.weight(.medium)).compactLineLimit(2)
                if !album.folderPath.isEmpty {
                    Text(album.folderPath.joined(separator: " › "))
                        .font(.footnote).foregroundStyle(.noteText).compactLineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                badge
                Text("\(album.addedCount) \(album.addedCount.formatted()) Fotos").font(.footnote).foregroundStyle(.noteText).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cover: some View {
        if album.coverAssetID != nil || album.addedCount > 0 {
            // No cover although photos are added: every one is a sensitive document, and the
            // tile says the preview is hidden, as in the lists (`CoverThumbnail`).
            CoverThumbnail(id: album.coverAssetID, side: side)
        } else {
            Theme.accent.opacity(0.15)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if album.isNew {
            Text("Neu").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
        } else {
            Text("Ergänzt").font(.caption.weight(.semibold)).foregroundStyle(.noteText)
        }
    }
}
