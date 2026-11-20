import SwiftUI
import SortlyCore

/// The change receipt of one executed plan (I01): what Albumist really changed, album by
/// album, read from the execution journal, and what it did not touch. Opened from
/// Einstellungen › Verlauf and from the result after "Alben jetzt anlegen".
struct PlanReceiptView: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan
    @State private var receipt: PlanReceipt?
    /// Undos of this plan, newest first (more than one when the first was only partial).
    @State private var undos: [PlanReceipt] = []
    /// The text of "Liste teilen", made with the receipt (it was made again at every redraw).
    @State private var shareText: String?
    private var undo: PlanReceipt? { undos.first }
    /// Taken back only in part: the rest can be taken back again (audit 2, 1.6).
    private var partlyUndone: Bool { (undo.map { !$0.isComplete } ?? false) && !model.undonePlans.contains(plan.id) }
    @State private var showAllAlbums = false
    @State private var confirmUndo = false
    /// The undo deletes albums or folders: the confirmation says that iOS asks next (P3-07).
    @State private var undoDeletes = false
    /// Albumist reads the albums to see whether the undo deletes any: a spinner beside the
    /// button, and no second tap meanwhile (third review of P3-07, SHOULD-2).
    @State private var askingUndo = false
    /// "Erneut versuchen": the plan with what is missing, opened in the normal review.
    @Environment(Navigator.self) private var navigator: Navigator?
    /// "Fehlendes erneut versuchen" is building its plan: the button waits (a second tap
    /// pushed a second preview), and so does "Rückgängig machen" (the plan would be made from a
    /// library that is being taken back).
    @State private var retrying = false
    /// A plan of "Fehlendes erneut versuchen" that was ready while another tab was chosen:
    /// offered again when this tab shows (`showWaiting()`).
    @State private var waiting: WaitingRetry?

    private struct WaitingRetry {
        let plan: ChangePlan
        let request: PlanRequest
    }
    @State private var nothingToRetry = false
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28
    private let collapsedCount = 12

    var body: some View {
        List {
            if let receipt {
                header(receipt)
                changes(receipt)
                originals(receipt)
                if !receipt.isComplete { problems(receipt) }
                if !receipt.albums.isEmpty { albums(receipt) }
                // Stays at the end, where "Rückgängig machen" was tapped; the header says it too.
                undoSection(receipt)
            }
        }
        .navigationTitle("Änderungen")
        .navigationBarTitleDisplayMode(.inline)
        // Opened from the result, the receipt belongs to it: the App Store rating question
        // waits until the user has left both (`ReviewPrompt`).
        .onAppear {
            ReviewPrompt.shared.screenAppeared()
            showWaiting()
        }
        .onDisappear {
            ReviewPrompt.shared.screenDisappeared()
        }
        // The tab shows again (`Navigator.appearances`): a result that waited is offered now.
        .onChange(of: navigator?.appearances) { showWaiting() }
        .toolbar {
            if receipt != nil, let shareText {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareText) {
                        Label("Liste teilen", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        // Reloaded after an undo, also after one that was only partial.
        .task(id: "\(model.undonePlans.contains(plan.id))-\(model.execution.finished?.id.rawValue ?? "")") {
            let loaded = await model.receipt(for: plan)
            // A newer load (after an undo) has started: this older one writes nothing.
            guard !Task.isCancelled else { return }
            receipt = loaded.plan
            undos = loaded.undos
            let inventory = model.inventory
            let removal = isRemoval
            let text = await Task.detached(priority: .userInitiated) {
                ReceiptText.text(loaded.plan, undo: loaded.undos.first, inventory: inventory, isRemoval: removal)
            }.value
            // A newer load (after an undo) or a closed screen keeps its own text.
            guard !Task.isCancelled else { return }
            shareText = text
        }
        .confirmationDialog("Diese Änderungen rückgängig machen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Rückgängig machen", role: .destructive) {
                Task {
                    await model.undo(plan)
                    await model.refreshDerived()
                }
            }
        } message: {
            DeleteQuestionNote.message(Text("Alben und Zuordnungen von Albumist werden entfernt."), deletes: undoDeletes)
        }
        .alert("Nichts mehr zu tun", isPresented: $nothingToRetry) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Was gefehlt hat, ist inzwischen erledigt oder das Album gibt es nicht mehr.")
        }
    }

    // MARK: Sections

    /// A removal from "Alben von Albumist" (or its retry): its receipt says "entfernt" where
    /// one that created albums says "angelegt" (review P3-09: "umgesetzt" was a third word).
    private var isRemoval: Bool { plan.reverts == nil && !plan.removalSources.isEmpty }

    /// The state now comes first: a plan that was taken back says so at the top instead of
    /// "Vollständig angelegt" (Fuchs 15.11.: "Finde die Nachricht oben etwas komisch").
    private func header(_ receipt: PlanReceipt) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Group {
                    if undo != nil, !receipt.isUndo {
                        if partlyUndone {
                            Label("Teilweise rückgängig gemacht", systemImage: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(Theme.tint(for: .documents))
                        } else {
                            Label("Rückgängig gemacht", systemImage: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    } else if receipt.isComplete {
                        Label(isRemoval ? LocalizedStringKey("Vollständig entfernt") : LocalizedStringKey("Vollständig angelegt"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.accent)
                    } else {
                        Label(isRemoval ? LocalizedStringKey("Teilweise entfernt") : LocalizedStringKey("Teilweise angelegt"), systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(Theme.tint(for: .documents))
                    }
                }
                .font(.headline)
                if let undo, !receipt.isUndo {
                    let started = receipt.startedAt.formatted(date: .abbreviated, time: .shortened)
                    Text(isRemoval ? LocalizedStringKey("Entfernt am \(started)") : LocalizedStringKey("Angelegt am \(started)"))
                        .font(.subheadline).foregroundStyle(.noteText)
                    Text("Rückgängig gemacht am \(undo.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.noteText)
                } else {
                    Text(receipt.startedAt.formatted(date: .long, time: .shortened))
                        .font(.subheadline).foregroundStyle(.noteText)
                }
                Text("Alle Zahlen hat Albumist danach in deiner Mediathek nachgeprüft.")
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityElement(children: .combine)
        }
    }

    private func changes(_ receipt: PlanReceipt) -> some View {
        Section {
            if receipt.albumsCreated > 0 { row("rectangle.stack.badge.plus", "Neue Alben", receipt.albumsCreated) }
            if receipt.albumsExtended > 0 { row("plus.rectangle.on.rectangle", "Ergänzte Alben", receipt.albumsExtended) }
            if !receipt.createdFolders.isEmpty { row("folder.badge.plus", "Neue Ordner", receipt.createdFolders.count) }
            row("photo", "Fotos einsortiert", receipt.photosAdded)
            if receipt.assignmentsAdded != receipt.photosAdded { row("square.on.square", "Album-Zuordnungen", receipt.assignmentsAdded) }
            if receipt.renamed > 0 { row("pencil", "Umbenannt", receipt.renamed) }
            if receipt.moved > 0 { row("arrow.right.square", "Verschoben", receipt.moved) }
            if receipt.membershipsRemoved > 0 { row("minus.rectangle", "Aus Alben genommen", receipt.membershipsRemoved) }
            if receipt.containersDeleted > 0 { row("rectangle.stack.badge.minus", "Entfernte Alben und Ordner", receipt.containersDeleted) }
        } header: {
            Text("Das hat Albumist geändert")
        }
    }

    private func originals(_ receipt: PlanReceipt) -> some View {
        Section {
            // What did not happen, in words (design review W1); a number only if it ever did.
            if receipt.originalsDeleted == 0 {
                guarantee(Text("Kein Original gelöscht"))
            } else {
                Text("\(receipt.originalsDeleted) Originale gelöscht")
            }
            if receipt.originalsEdited == 0 {
                guarantee(Text("Kein Original bearbeitet"))
            } else {
                Text("\(receipt.originalsEdited) Originale bearbeitet")
            }
            if receipt.originalCopiesCreated == 0 {
                guarantee(Text("Keine Kopie angelegt"))
            } else {
                Text("\(receipt.originalCopiesCreated) Kopien angelegt")
            }
        } header: {
            Text("Deine Originale")
        } footer: {
            Text("Albumist ordnet Fotos nur Alben zu. Löschen, Bearbeiten oder Kopieren von Fotos gibt es in Albumist nicht. Ein Album verweist nur auf deine Fotos.")
        }
    }

    /// Guided repair (I16): what is missing and why, in plain words, and the ways out:
    /// try the missing part again, take everything back (below), or leave it as it is.
    private func problems(_ receipt: PlanReceipt) -> some View {
        Section {
            if receipt.failedSteps > 0 {
                Text("\(receipt.failedSteps) Schritte konnten nicht ausgeführt werden.")
            }
            if receipt.leftSteps > 0 {
                Text("\(receipt.leftSteps) Schritte hast du nach der Unterbrechung so gelassen.")
            }
            // Not a failure, but not sorted in either: the plan is not complete (audit 2, 7.1).
            if receipt.unavailablePhotos > 0 {
                Text("\(receipt.unavailablePhotos) \(receipt.unavailablePhotos.formatted()) Fotos waren beim Anlegen nicht mehr in deiner Mediathek und wurden nicht einsortiert.")
            }
            ForEach(StepProblemText.texts(receipt.problems), id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(.noteText)
            }
            if receipt.unconfirmedSteps > 0 {
                Text("\(receipt.unconfirmedSteps) Schritte konnte Albumist in der Mediathek nicht nachprüfen. Sie zählen hier nicht mit.")
                    .font(.subheadline).foregroundStyle(.noteText)
            }
            if canRepair(receipt) {
                Button {
                    retry()
                } label: {
                    Label("Fehlendes erneut versuchen", systemImage: "arrow.clockwise")
                }
                .disabled(model.execution.isRunning || retrying)
                .accessibilityIdentifier("receipt.retry")
            }
            DiagnosticShareRow()
        } header: {
            Text("Nicht erledigt")
        } footer: {
            if canRepair(receipt) {
                Text("Erneut versuchen legt nur an, was fehlt; nichts wird doppelt angelegt, und du siehst vorher, was passiert. Du kannst es auch so lassen: Das Erledigte bleibt, und die fehlenden Fotos schlägt Albumist bei der nächsten Analyse wieder vor.")
            }
        }
    }

    /// Makes the plan of what is missing; the button waits meanwhile.
    private func retry(attempt: Int = 1) {
        waiting = nil
        retrying = true
        let request = PlanRequest(model: model, navigator: navigator)
        Task {
            let said = model.message
            let missing = await model.retryPlan(for: plan)
            retrying = false
            guard let missing else {
                // Not "Nichts mehr zu tun" when the app said why (an album that may still land).
                if model.message == said, navigator?.isShowing(request.mark) == true { nothingToRetry = true }
                return
            }
            offer(WaitingRetry(plan: missing, request: request), attempt: attempt)
        }
    }

    /// A plan of "Fehlendes erneut versuchen" that is ready, or that waited for this tab, with
    /// the same checks both times (`PlanRequest`): pushed onto the stack's path (`AppScreen`) if
    /// it is still current; kept while another tab is chosen; made again once when the album
    /// list changed meanwhile and the plan can still be completed (a second change says Albumist
    /// is busy); dropped when the user went elsewhere on this stack. Never pushed twice:
    /// `waiting` holds it only while it is not shown.
    private func offer(_ ready: WaitingRetry, attempt: Int) {
        switch ready.request.verdict(model: model, navigator: navigator) {
        case .show:
            Navigator.push(.prebuiltPlan(PlanToken(ready.plan)), on: navigator, ifStill: ready.request.mark)
        case .wait:
            waiting = ready
        case .gone:
            break
        case .busy:
            model.message = .busy
        case .stale:
            if attempt > 1 {
                model.message = .busy
            } else if let receipt, canRepair(receipt) {
                retry(attempt: attempt + 1)
            }
            // Otherwise the plan was taken back meanwhile: the receipt says so.
        }
    }

    /// The tab shows again: a plan that was ready meanwhile is offered now.
    private func showWaiting() {
        guard let ready = waiting, navigator?.showing == true else { return }
        waiting = nil
        offer(ready, attempt: 1)
    }

    /// Only plans that changed the library and were not taken back can be completed.
    private func canRepair(_ receipt: PlanReceipt) -> Bool {
        !receipt.isUndo && receipt.failedSteps + receipt.leftSteps > 0 && !model.undonePlans.contains(plan.id)
            && plan.steps.contains { $0.state.canBeRetried }
    }

    private func albums(_ receipt: PlanReceipt) -> some View {
        let visible = showAllAlbums ? receipt.albums : Array(receipt.albums.prefix(collapsedCount))
        return Section {
            ForEach(visible) { album in
                ReceiptAlbumRow(album: album, title: title(album), isRemoval: isRemoval)
            }
            if receipt.albums.count > collapsedCount {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { showAllAlbums.toggle() }
                } label: {
                    if showAllAlbums {
                        Text("Weniger anzeigen")
                    } else {
                        Text("Alle \(receipt.albums.count) Alben anzeigen")
                    }
                }
            }
        } header: {
            Text("Alben")
        } footer: {
            if undo != nil {
                Text("So sah es beim Anlegen aus. Was davon rückgängig gemacht wurde, steht unten unter „Rückgängig gemacht“.")
            } else {
                Text("Namen wie beim Anlegen. Was du danach in Fotos geändert hast, respektiert Albumist.")
            }
        }
    }

    @ViewBuilder
    private func undoSection(_ receipt: PlanReceipt) -> some View {
        if let undo {
            let deleted = undos.reduce(0) { $0 + $1.containersDeleted }
            let removed = undos.reduce(0) { $0 + $1.membershipsRemoved }
            Section {
                Text(undo.startedAt.formatted(date: .long, time: .shortened))
                if deleted > 0 { row("rectangle.stack.badge.minus", "Entfernte Alben und Ordner", deleted) }
                if removed > 0 { row("minus.rectangle", "Aus Alben genommen", removed) }
                if partlyUndone {
                    Text("Nicht alles ließ sich rückgängig machen. Du kannst es noch einmal versuchen oder es so lassen.")
                        .font(.subheadline).foregroundStyle(.noteText)
                    // Why, in words the user can act on (first iPhone test, 15.11.).
                    ForEach(StepProblemText.texts(undo.problems), id: \.self) { text in
                        Label(text, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.noteText)
                    }
                    Button(role: .destructive) { askUndo() } label: {
                        Text("Rest rückgängig machen").checkingBeside(askingUndo)
                    }
                        .disabled(model.execution.isRunning || retrying || askingUndo)
                        .accessibilityIdentifier("receipt.undoRest")
                } else if !undo.isComplete {
                    Text("Was Albumist nicht rückgängig machen konnte, bleibt, wie es ist.")
                        .font(.footnote).foregroundStyle(.noteText)
                }
            } header: {
                Text("Rückgängig gemacht")
            } footer: {
                if partlyUndone {
                    Text("Macht nur rückgängig, was noch von Albumist ist. Was du inzwischen selbst geändert hast, bleibt.")
                }
            }
        } else if !receipt.isUndo && !model.undonePlans.contains(plan.id)
                    && (plan.status == .completed || plan.status == .completedWithErrors) {
            Section {
                Button(role: .destructive) { askUndo() } label: {
                    Text("Rückgängig machen").checkingBeside(askingUndo)
                }
                    .disabled(model.execution.isRunning || retrying || askingUndo)
                    .accessibilityIdentifier("receipt.undo")
            } footer: {
                Text("Entfernt nur die neuen Alben und Zuordnungen dieser Änderungen. Deine Fotos bleiben.")
            }
        }
    }

    /// "Rückgängig machen" and "Rest rückgängig machen" ask first, and say whether iOS asks too
    /// (from the albums read fresh from Photos, a moment after the tap).
    private func askUndo() {
        guard !askingUndo else { return }
        askingUndo = true
        Task {
            // Full access first: not "not possible" after the dialog was confirmed.
            guard await model.changesHaveFullAccess() else { askingUndo = false; return }
            undoDeletes = await model.undoDeletesCollections(plan)
            askingUndo = false
            confirmUndo = true
        }
    }

    // MARK: Parts

    /// An album that is no longer in the library keeps the name it had when the plan ran.
    private func title(_ album: PlanReceipt.Album) -> String {
        if !album.title.isEmpty { return album.title }
        return String(localized: "Album")
    }

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

    private func guarantee(_ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.accent)
        }
    }
}

private struct ReceiptAlbumRow: View {
    let album: PlanReceipt.Album
    let title: String
    /// The plan removed photos (`PlanReceiptView.isRemoval`): "Nicht vollständig entfernt".
    let isRemoval: Bool
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        AdaptiveStack(spacing: Theme.Spacing.m) {
            cover
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).compactLineLimit(2)
                if !album.folderPath.isEmpty {
                    Text(album.folderPath.joined(separator: " › "))
                        .font(.footnote).foregroundStyle(.noteText).compactLineLimit(2)
                }
                if album.failed {
                    Text(isRemoval ? LocalizedStringKey("Nicht vollständig entfernt") : LocalizedStringKey("Nicht vollständig angelegt")).font(.footnote).foregroundStyle(Theme.tint(for: .documents))
                } else if album.unconfirmed {
                    Text("Nicht nachgeprüft").font(.footnote).foregroundStyle(.noteText)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                badge
                if album.added > 0 {
                    Text("+\(album.added) \(album.added.formatted()) Fotos").font(.footnote).foregroundStyle(.noteText).monospacedDigit()
                }
                if album.removed > 0 {
                    Text("−\(album.removed) \(album.removed.formatted()) Fotos").font(.footnote).foregroundStyle(.noteText).monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cover: some View {
        if album.coverAssetID != nil || album.added > 0 {
            // No cover although photos were added: every one is a sensitive document, and the
            // tile says the preview is hidden, as in the lists (`CoverThumbnail`).
            CoverThumbnail(id: album.coverAssetID, side: side)
        } else {
            ZStack {
                Theme.accent.opacity(0.15)
                Image(systemName: album.change == .deleted ? "rectangle.stack.badge.minus" : "rectangle.stack")
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch album.change {
        case .created:
            Text("Neu").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
        case .adopted:
            Text("Übernommen").font(.caption.weight(.semibold)).foregroundStyle(.noteText)
        case .extended:
            Text("Ergänzt").font(.caption.weight(.semibold)).foregroundStyle(.noteText)
        case .reduced:
            Text("Fotos herausgenommen").font(.caption.weight(.semibold)).foregroundStyle(.noteText)
        case .deleted:
            Text("Entfernt").font(.caption.weight(.semibold)).foregroundStyle(.noteText)
        }
    }
}

/// The receipt as plain text for "Beleg teilen": numbers and album names, no photos.
enum ReceiptText {
    static func text(_ receipt: PlanReceipt, undo: PlanReceipt?, inventory: CollectionInventory, isRemoval: Bool = false) -> String {
        var lines: [String] = []
        lines.append(String(localized: "Albumist – Änderungen"))
        lines.append(receipt.startedAt.formatted(date: .long, time: .shortened))
        if isRemoval {
            lines.append(receipt.isComplete ? String(localized: "Vollständig entfernt") : String(localized: "Teilweise entfernt"))
        } else {
            lines.append(receipt.isComplete ? String(localized: "Vollständig angelegt") : String(localized: "Teilweise angelegt"))
        }
        lines.append("")
        func add(_ label: String.LocalizationValue, _ value: Int, always: Bool = false) {
            if always || value > 0 { lines.append("\(String(localized: label)): \(value.formatted())") }
        }
        add("Neue Alben", receipt.albumsCreated)
        add("Ergänzte Alben", receipt.albumsExtended)
        add("Neue Ordner", receipt.createdFolders.count)
        add("Fotos einsortiert", receipt.photosAdded, always: true)
        add("Nicht mehr in der Mediathek", receipt.unavailablePhotos)
        add("Aus Alben genommen", receipt.membershipsRemoved)
        add("Entfernte Alben und Ordner", receipt.containersDeleted)
        // As on screen: what did not happen in words, a number only if it did (W1).
        lines.append(receipt.originalsDeleted == 0 ? String(localized: "Kein Original gelöscht")
                     : "\(String(localized: "Originale gelöscht")): \(receipt.originalsDeleted.formatted())")
        lines.append(receipt.originalsEdited == 0 ? String(localized: "Kein Original bearbeitet")
                     : "\(String(localized: "Originale bearbeitet")): \(receipt.originalsEdited.formatted())")
        lines.append(receipt.originalCopiesCreated == 0 ? String(localized: "Keine Kopie angelegt")
                     : "\(String(localized: "Kopien angelegt")): \(receipt.originalCopiesCreated.formatted())")
        if !receipt.albums.isEmpty {
            lines.append("")
            lines.append(String(localized: "Alben"))
            for album in receipt.albums {
                let path = (album.folderPath + [album.title.isEmpty ? String(localized: "Album") : album.title]).joined(separator: " › ")
                var detail: [String] = []
                if album.added > 0 { detail.append("+" + album.added.formatted()) }
                if album.removed > 0 { detail.append("−" + album.removed.formatted()) }
                lines.append("• \(path)" + (detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))"))
            }
        }
        if let undo {
            lines.append("")
            lines.append(String(localized: "Rückgängig gemacht: \(undo.startedAt.formatted(date: .long, time: .shortened))"))
        }
        return lines.joined(separator: "\n")
    }
}
