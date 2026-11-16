import StoreKit
import SwiftUI
import SortlyCore
import SortlyEngine

/// Final preview before anything changes (prompt §7, Schritt 8–10): summary, guarantees,
/// conflicts, execution with progress, result and undo.
struct PlanReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    /// A plan built elsewhere (album merge); otherwise the accepted proposals are planned.
    var prebuilt: ChangePlan? = nil
    @State private var loading = true
    /// Albums of the plan that is running, for the "photos fly into albums" show.
    @State private var show: [SortingShow.Album]?
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var scroll = ScrollPosition(edge: .top)
    /// The screen loads once; coming back from another tab keeps the result and its undo.
    @State private var didLoad = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if let show {
                    SortingShow(albums: show) {
                        withAnimation(.smooth(duration: 0.45)) { self.show = nil }
                    }
                    .transition(.opacity)
                } else if let result = model.execution.finished, !model.execution.isRunning {
                    ResultCard(plan: result)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if model.execution.isRunning {
                    runningCard
                } else if loading {
                    ProgressView("Plan wird erstellt").frame(maxWidth: .infinity).padding(.top, 60)
                } else if let plan = model.plan {
                    planContent(plan)
                } else {
                    ContentUnavailableView("Nichts zu tun", systemImage: "checkmark.circle",
                                           description: Text("Es gibt gerade keine ausgewählten Vorschläge."))
                }
                if let failure = model.execution.failure {
                    Card {
                        Label("Nicht alles hat geklappt", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(failure).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Theme.Spacing.l)
        }
        .scrollPosition($scroll)
        .background(Theme.background)
        // One name for one step (design review W2): it is the preview of what changes.
        .navigationTitle("Vorschau")
        // Leaving mid-way would look like cancelling; the work goes on either way.
        .navigationBarBackButtonHidden(model.execution.isRunning)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ExecutionHaptics(execution: model.execution, holdSuccess: show != nil))
        .task {
            await model.refreshAccess()
            guard !didLoad else { return }
            didLoad = true
            if !model.execution.isRunning {
                // A new visit starts clean (the last result stays while the user only switched tabs).
                model.execution.finished = nil
                model.execution.failure = nil
                if let prebuilt { model.plan = prebuilt } else { await model.buildPlan() }
            }
            loading = false
        }
        .onChange(of: scenePhase) { _, phase in
            // Back from the Settings app: the full-access card disappears by itself.
            if phase == .active { Task { await model.refreshAccess() } }
        }
    }

    // MARK: Plan

    @ViewBuilder
    private func planContent(_ plan: ChangePlan) -> some View {
        let summary = plan.summary
        Text("Das ändert sich in Fotos").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
        if plan.retries != nil {
            // "Fehlendes erneut versuchen" (I16): say that this is not the whole plan again.
            Text("Nur was beim letzten Anlegen gefehlt hat. Schon Erledigtes bleibt, wie es ist, und wird nicht doppelt angelegt.")
                .font(.subheadline).foregroundStyle(.secondary)
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

        let albumList = plan.albumPreview(inventory: model.inventory, order: model.acceptedProposals.inDisplayOrder().map(\.id))
        if !albumList.isEmpty { PlanAlbumList(albums: albumList) }

        // Said as what does not happen (design review W1): "0 Originale gelöscht" left
        // "Originale gelöscht" in the mind when skimming or listening. A number only if a
        // plan ever were to do it.
        Card {
            if summary.originalsDeleted == 0 {
                guarantee(Text("Kein Original wird gelöscht"))
            } else {
                warning(Text("\(summary.originalsDeleted) Originale werden gelöscht"))
            }
            if summary.originalCopiesCreated == 0 {
                guarantee(Text("Es werden keine Kopien angelegt"))
            } else {
                warning(Text("\(summary.originalCopiesCreated) Kopien werden angelegt"))
            }
            Text("Fotos werden nur in Alben einsortiert. Die Originale bleiben, wo sie sind, und jede Änderung lässt sich rückgängig machen.")
                .font(.footnote).foregroundStyle(.secondary)
        }

        if !plan.conflicts.isEmpty {
            Card {
                Label("Bitte prüfen", systemImage: "exclamationmark.triangle").font(.headline)
                ForEach(Array(plan.conflicts.enumerated()), id: \.offset) { _, conflict in
                    Text(ConflictText.text(conflict, inventory: model.inventory))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }

        let blocking = plan.conflicts.contains(where: \.isBlocking)
        let albums = plan.freeAlbumUse(applied: false)
        if model.access == .limited && !UITestSupport.isRunning {
            FullAccessCard()
        } else if PlanGate.refusal(for: plan, interrupted: model.interruptedPlan) != nil {
            // One plan at a time (plugin review K2): the one that was cut off is settled first.
            Card {
                // Names what was cut off: creating albums or taking them back.
                let isUndo = model.interruptedPlan?.reverts != nil
                Label(isUndo ? LocalizedStringKey("Erst das unterbrochene Zurücknehmen abschließen") : LocalizedStringKey("Erst das unterbrochene Anlegen abschließen"),
                      systemImage: "pause.circle").font(.headline)
                Text(isUndo
                     ? LocalizedStringKey("Ein früheres Zurücknehmen wurde unterbrochen. Entscheide in der Übersicht, wie es weitergeht. Danach geht es hier weiter, und nichts wird doppelt zurückgenommen.")
                     : LocalizedStringKey("Ein früheres Anlegen wurde unterbrochen. Entscheide in der Übersicht, wie es weitergeht. Danach geht es hier weiter, und nichts wird doppelt angelegt."))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !purchases.allows(albums: albums) {
            UnlockCard(albumsInPlan: albums, onLimit: limitToFreeAlbums)
        } else {
            Button {
                let albums = SortingShow.albums(from: plan, inventory: model.inventory)
                if !albums.isEmpty {
                    withAnimation(.smooth(duration: 0.4)) {
                        show = albums
                        scroll.scrollTo(edge: .top)
                    }
                }
                Task { await model.execute(plan) }
            } label: {
                applyTitle(summary)
            }
            .buttonStyle(PrimaryButtonStyle())
            // Not while a change in "Dein Zuhause" makes the suggestions again (the plan would
            // not start, after the fly animation).
            .disabled(blocking || plan.steps.isEmpty || model.homeChangeRunning)
            .accessibilityIdentifier("plan.apply")
            if blocking {
                Text("Erst die markierten Punkte klären. Ändere dazu den Vorschlag unter „Anpassen“.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !purchases.isUnlocked && !Purchases.unlockedForUITests && albums > 0 && purchases.allows(albums: albums) {
                Text("Kostenlos. Danach hast du noch \(purchases.remainingFreeAlbums - albums) von \(Purchases.freeAlbumLimit) Gratis-Alben.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if prebuilt == nil && !model.acceptedProposals.isEmpty {
            // The way out: nothing selected, back to the open suggestions.
            Button("Auswahl aufheben") {
                model.clearSelection()
                dismiss()
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
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
            Text("Alben werden angelegt").font(.headline)
            ProgressView(value: Double(model.execution.completedSteps), total: Double(max(1, model.execution.totalSteps)))
                .tint(Theme.accent)
            Text("\(model.execution.completedSteps) von \(model.execution.totalSteps) Schritten")
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            Text("Du kannst die App dabei offen lassen. Bricht etwas ab, setzt Albumist beim nächsten Start sicher fort.")
                .font(.footnote).foregroundStyle(.secondary)
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

/// Result of an executed plan: what happened, a way to see it in Photos, and undo.
struct ResultCard: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan
    @State private var confirmUndo = false
    @State private var appeared = false
    @State private var photosDidNotOpen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        // What really happened (photos that were no longer there are not counted).
        let summary = plan.appliedSummary
        let failed = summary.failedSteps
        let isUndo = plan.reverts != nil
        Card {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: failed > 0 ? "exclamationmark.circle.fill" : isUndo ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(failed == 0 ? Theme.accent : Theme.tint(for: .documents))
                    .symbolEffect(.bounce, value: appeared)
                    .accessibilityHidden(true)
                Text(isUndo ? (failed == 0 ? "Rückgängig gemacht" : "Teilweise rückgängig gemacht") : (failed == 0 ? "Fertig" : "Teilweise fertig"))
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if isUndo {
                        Text("Albumist hat seine Alben und Zuordnungen wieder entfernt. Deine Fotos sind unverändert.")
                    } else {
                        Text(Counted.resultLine(summary))
                    }
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
                if failed > 0 {
                    Group {
                        if isUndo {
                            Text("\(failed) Schritte konnten nicht ausgeführt werden. Was Albumist nicht zurücknehmen konnte, bleibt, wie es ist.")
                        } else {
                            Text("\(failed) Schritte konnten nicht ausgeführt werden. Die fehlenden Fotos schlägt Albumist bei der nächsten Analyse wieder vor.")
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                if summary.unavailableAssets > 0 && !isUndo {
                    Text("\(summary.unavailableAssets) Fotos waren nicht mehr in deiner Mediathek und wurden nicht einsortiert.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            if let photos = URL(string: "photos-redirect://") {
                // iOS lets apps open Fotos, but not a particular album (first device test 15.11.:
                // "Ich springe nicht zu meinen Alben"). So the button says what it does, and the
                // way to the albums is written next to it.
                // "photos-redirect://" is not documented by Apple (plugin review N8). Should iOS
                // one day not open it, the button says so instead of staying silent.
                Button("Fotos-App öffnen") {
                    openURL(photos) { accepted in photosDidNotOpen = !accepted }
                }
                .buttonStyle(PrimaryButtonStyle())
                if photosDidNotOpen {
                    Text("Die Fotos-App ließ sich nicht öffnen. Öffne sie bitte selbst vom Home-Bildschirm.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                if !isUndo {
                    Group {
                        let root = model.settings.rootFolderTitle.trimmingCharacters(in: .whitespaces)
                        if root.isEmpty {
                            Text("Deine neuen Alben findest du in Fotos unter Sammlungen › Alben.")
                        } else {
                            Text("Deine neuen Alben findest du in Fotos unter Sammlungen › Alben, im Ordner „\(root)“.")
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
            }
            NavigationLink {
                PlanReceiptView(plan: plan)
            } label: {
                Text("Alle Änderungen ansehen")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("result.receipt")
            if !isUndo && !model.undonePlans.contains(plan.id) {
                Button("Rückgängig machen") { confirmUndo = true }
                    .buttonStyle(SecondaryButtonStyle())
                Text("Auch später möglich unter Einstellungen › Verlauf und Rückgängig. Rückgängig entfernt nur die neuen Alben und Zuordnungen, deine Fotos bleiben.")
                    .font(.footnote).foregroundStyle(.secondary)
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
            Text("Albumist entfernt die angelegten Alben und Zuordnungen wieder. Deine Fotos bleiben unverändert.")
        }
    }
}

enum ConflictText {
    static func text(_ conflict: PlanConflict, inventory: CollectionInventory) -> String {
        func title(_ id: CollectionID) -> String { inventory[id]?.title ?? "?" }
        switch conflict {
        case .duplicatePlannedTitle(let title, _, _):
            return String(localized: "Zwei neue Alben heißen „\(title)“. Bitte benenne eines um.")
        case .titleExistsInFolder(let title, _):
            return String(localized: "Es gibt schon ein anderes Album „\(title)“. Das neue bekommt einen Zusatz.")
        case .albumMissing(let id):
            return String(localized: "Das Album „\(title(id))“ gibt es nicht mehr.")
        case .albumNotEditable(let id):
            return String(localized: "„\(title(id))“ kann nicht bearbeitet werden.")
        case .albumChangedSincePreview(let id):
            return String(localized: "„\(title(id))“ wurde inzwischen geändert. Bitte prüfe den Vorschlag erneut.")
        case .assetsUnavailable(let count):
            return String(localized: "\(count) Fotos sind nicht mehr in der Mediathek.")
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
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Einstellungen › Apps › Albumist › Fotos › Voller Zugriff")
                .font(.footnote).foregroundStyle(.secondary)
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
                .font(.subheadline).foregroundStyle(.secondary)
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
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Tipp: Du kannst auch weniger Vorschläge auf einmal auswählen.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                        .font(.footnote).foregroundStyle(.secondary).compactLineLimit(2)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                badge
                Text("\(album.addedCount) Fotos").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cover: some View {
        if let id = album.coverAssetID {
            AssetThumbnail(id: id, side: side)
        } else {
            Theme.accent.opacity(0.15)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if album.isNew {
            Text("Neu").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
        } else {
            Text("Ergänzt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }
}
