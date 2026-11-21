import SwiftUI
import AlbumistCore
import AlbumistEngine

/// Settings (prompt §17): the library, areas, naming, privacy, about. "Verlauf und Rückgängig"
/// and Albumist's albums are in the tab "Alben" (design 5C).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmReset = false
    @State private var redeeming = false
    @State private var rejectedCount = 0
    @State private var confirmTripReset = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Albumist arbeitet mit", selection: scopeYear) {
                    Text("Ganze Mediathek").tag(Int?.none)
                    ForEach(scopeYears, id: \.self) { year in
                        Text("Nur \(String(year))").tag(Int?.some(year))
                    }
                }
                .adaptivePickerStyle()
            } header: {
                Text("Mediathek")
            } footer: {
                Text("Mit einem Jahr geht es schneller: Albumist analysiert dann nur diese Fotos und macht nur dafür Vorschläge.")
            }

            // Where the user lives, former homes and other places that are not trips (also the
            // places answered with "Ja, hier bin ich öfter").
            Section {
                HomeSettingsRow()
            } footer: {
                Text("Wo du wohnst und welche Orte keine Reisen sind.")
            }

            Section {
                ForEach(OrganizationArea.available) { area in
                    Toggle(isOn: areaBinding(area, \.enabledAreas)) {
                        Label { Text(area.title) } icon: { Image(systemName: area.symbol).foregroundStyle(area.tint) }
                    }
                }
            } header: {
                Text("Bereiche")
            } footer: {
                Text("Nur eingeschaltete Bereiche bekommen Vorschläge.")
            }

            // Says what the second list of areas is for (W16: it read like the first one again).
            Section {
                ForEach(OrganizationArea.available.filter { model.settings.enabledAreas.contains($0) }) { area in
                    Toggle(isOn: areaBinding(area, \.primaryAreas)) { Text(area.title) }
                }
            } header: {
                Text("Zählt als sortiert")
            } footer: {
                Text("Ein Foto gilt als sortiert, wenn es in einem dieser Bereiche in einem Album liegt.")
            }

            Section("Alben") {
                Picker("Sprache der Albumnamen", selection: $model.settings.titleLanguage) {
                    Text("Deutsch").tag(TitleLanguage.german)
                    Text("Englisch").tag(TitleLanguage.english)
                }
                .adaptivePickerStyle()
                LabeledContent {
                    TextField("Kein Ordner", text: $model.settings.rootFolderTitle)
                        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                } label: {
                    Text("Ordner für neue Alben")
                        .accessibilityIdentifier("settings.rootFolder.label")
                }
                .labeledContentStyle(FieldRowStyle())
                if model.settings.enabledAreas.contains(.places) {
                    // Off by default: a trip would otherwise bring a country, two cities and
                    // itself as four albums (usability test 14.11.2026).
                    Toggle(isOn: $model.settings.places.includesCities) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Städte als eigene Alben")
                            Text("Zum Beispiel Rom und Florenz zusätzlich zu Italien.")
                                .font(.footnote)
                                .foregroundStyle(.noteText)
                        }
                    }
                }
                Toggle("Foto in mehreren Alben erlauben", isOn: $model.settings.allowMultipleAssignments)
            }

            Section {
                Toggle("Ausgeblendete Fotos einbeziehen", isOn: $model.settings.privacy.includeHiddenAssets)
                Toggle("Orte online genauer bestimmen", isOn: $model.settings.privacy.allowOnlineGeocoding)
                Toggle("Screenshots aus iCloud laden", isOn: $model.settings.privacy.allowNetworkForAnalysis)
                if model.settings.privacy.allowNetworkForAnalysis {
                    Toggle("Auch über Mobilfunk", isOn: $model.settings.privacy.allowCellularDownloads)
                }
            } header: {
                Text("Datenschutz")
            } footer: {
                Text("Die Analyse läuft immer auf deinem Gerät. Für Ortsnamen schickt iOS einzelne Aufnahmeorte (nur Koordinaten und die Sprache der Ortsnamen) an Apples Kartendienst, nie ein Foto. Aus iCloud werden nur Screenshots und Dokumente geladen, nie Videos, und nur im WLAN, wenn du nichts anderes einstellst.")
            }

            if rejectedCount > 0 {
                Section {
                    Button("Abgelehnte Vorschläge wieder zeigen") {
                        Task {
                            await model.restoreRejectedProposals()
                            rejectedCount = 0
                        }
                    }
                } footer: {
                    Text("\(rejectedCount) Vorschläge hast du mit „Nicht jetzt“ beiseitegelegt. Sie erscheinen nach der nächsten Analyse wieder.")
                }
            }

            // Reise-Werkstatt (I07): the user's own splits and merges, and the way back.
            if model.tripCorrections.changeCount > 0 {
                Section {
                    LabeledContent("Selbst geteilt oder zusammengelegt", value: model.tripCorrections.changeCount.formatted())
                    Button("Reisen wieder automatisch erkennen") { confirmTripReset = true }
                        // Grey while an analysis runs or albums are made; the footer says why.
                        .disabled(model.tripChangeWait != nil)
                        .tripChangeWaitHint(model.tripChangeWait)
                        .accessibilityIdentifier("settings.resetTrips")
                        .confirmationDialog("Reisen wieder automatisch erkennen?", isPresented: $confirmTripReset, titleVisibility: .visible) {
                            Button("Automatisch erkennen") { Task { await model.resetTripCorrections() } }
                        } message: {
                            // During a Pause the reset starts the analysis again (decision 18.11.2026).
                            if model.analysis.isPausedByUser {
                                Text("Albumist vergisst, welche Reisen du geteilt oder zusammengelegt hast. Schon angelegte Alben bleiben, wie sie sind. Die pausierte Analyse läuft dann weiter.")
                            } else {
                                Text("Albumist vergisst, welche Reisen du geteilt oder zusammengelegt hast. Schon angelegte Alben bleiben, wie sie sind.")
                            }
                        }
                } header: {
                    Text("Reisen")
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        TripChangeWaitNote(identifier: "settings.resetTripsBusyNote")
                        Text("Albumist hält sich an deine Änderungen, auch bei jeder neuen Analyse.")
                    }
                }
            }

            Section {
                Button("Analyse neu aufbauen", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Löscht nur Albumists eigene Analyse. Deine Fotos und Alben bleiben, wie sie sind.")
            }

            Section("Vollversion") {
                if purchases.isUnlocked {
                    Label("Freigeschaltet", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                } else {
                    LabeledContent {
                        Text("\(purchases.remainingFreeAlbums) Alben")
                    } label: {
                        Text("Noch kostenlos")
                    }
                    UnlockButton() // without a price: "Preis wird geladen …", not tappable (W7)
                    Button("Kauf wiederherstellen") { Task { await purchases.restore() } }
                        .disabled(purchases.isPurchasing)
                    Button("Code einlösen") { redeeming = true }
                    if let error = purchases.lastError {
                        ErrorNote(text: error)
                    }
                }
            }
            // The price comes from StoreKit; a start without network is made up for here.
            .task { await purchases.loadProductIfNeeded() }
            .offerCodeRedemption(isPresented: $redeeming) { _ in
                Task { await purchases.refreshEntitlements(mayLock: false) }
            }

            SamplePhotosSection()

            #if targetEnvironment(simulator)
            Section {
                DemoLibraryCard().listRowInsets(EdgeInsets())
            }
            #endif

            Section {
                NavigationLink("Datenschutz") { PrivacyView() }
                LabeledContent("Version", value: AppInfo.version)
                DiagnosticShareRow()
                Text("Kartendaten: Natural Earth (gemeinfrei). Ortsnamen online: Apple.")
                    .font(.footnote).foregroundStyle(.noteText)
            } header: {
                Text("Über")
            } footer: {
                Text("Die Diagnose hilft bei Problemen. Sie enthält nur Zustände und Zahlen, keine Fotos, Albumnamen oder Orte, und du siehst sie vor dem Senden.")
            }
        }
        // The trip reset greys and its note comes and goes with the run, without a jump.
        .animation(reduceMotion ? nil : .smooth, value: model.tripChangeWait)
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
        }
        .onChange(of: model.settings) { model.saveSettings() }
        .task { rejectedCount = await model.rejectedProposalCount() }
        .confirmationDialog("Analyse neu aufbauen?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Neu aufbauen", role: .destructive) {
                Task {
                    // Refused during a change in "Dein Zuhause": only the busy message, no run.
                    if await model.resetAnalysis() {
                        model.startAnalysis(cause: .tap)
                    }
                }
            }
        } message: {
            Text("Die Analyse läuft danach noch einmal über alle Fotos, mit denen Albumist arbeitet.")
        }
    }

    /// The trial year (kept for every run) or the whole library.
    private var scopeYear: Binding<Int?> {
        Binding(
            get: { if case .year(let year) = model.analysisScope { year } else { nil } },
            set: { model.changeScope($0.map { .year($0) } ?? .all) }
        )
    }

    private var scopeYears: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        var years = (0..<6).map { current - $0 }
        if case .year(let chosen) = model.analysisScope, !years.contains(chosen) { years.append(chosen) }
        return years
    }

    private func areaBinding(_ area: OrganizationArea, _ keyPath: WritableKeyPath<OrganizationSettings, Set<OrganizationArea>>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath].contains(area) },
            set: { on in
                if on { model.settings[keyPath: keyPath].insert(area) } else { model.settings[keyPath: keyPath].remove(area) }
                if keyPath == \OrganizationSettings.enabledAreas && !on { model.settings.primaryAreas.remove(area) }
            }
        )
    }
}

/// A label with a text field after it whose label is never cut: the label takes the width it
/// needs, the field the rest. With the system style the two shared the row half and half and
/// the label ended in "…" already at the default text size ("Ordner für neue Al…", review
/// P3-17 / G3-08). At the accessibility text sizes the field goes under the label, where both
/// have the whole width.
private struct FieldRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        FieldRow(label: configuration.label, field: configuration.content)
    }

    private struct FieldRow<RowLabel: View, Field: View>: View {
        var label: RowLabel
        var field: Field
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    label
                    field
                }
            } else {
                HStack {
                    label.layoutPriority(1)
                    field
                }
            }
        }
    }
}

/// Every change Albumist made, newest first, each with its way back (design review W16). Opened
/// from the row "Verlauf und Rückgängig" in the tab "Alben" (design 5C).
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                if let interrupted = model.interruptedPlan {
                    InterruptedHistoryRow(plan: interrupted)
                }
                if model.history.isEmpty && model.interruptedPlan == nil {
                    Text("Noch keine Änderungen").foregroundStyle(.secondary)
                }
                ForEach(model.history) { plan in
                    HistoryRow(plan: plan)
                }
                if model.historyHasMore {
                    Button("Ältere anzeigen") { Task { await model.loadMoreHistory() } }
                }
            } footer: {
                // The analysis can be rebuilt, the decisions cannot: they are copied into the
                // device backup (I12), so a new iPhone or a rebuilt database gets them back.
                if let saved = model.lastSafetyBackup {
                    Text("Deine Entscheidungen, Alben und der Verlauf liegen als kleine Kopie im Backup deines Geräts. Zuletzt gesichert: \(saved.formatted(date: .abbreviated, time: .shortened)).")
                }
            }
        }
        .navigationTitle("Verlauf und Rückgängig")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One executed plan; opens its change receipt (with "Rückgängig machen" there).
struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    var plan: ChangePlan

    var body: some View {
        PushLink(.receipt(PlanToken(plan))) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text((plan.confirmedAt ?? plan.createdAt).formatted(date: .abbreviated, time: .shortened))
                    Text(Counted.historyLine(plan.appliedSummary))
                        .font(.footnote).foregroundStyle(.noteText)
                }
                Spacer()
                if model.undonePlans.contains(plan.id) {
                    Text("Rückgängig gemacht")
                        .font(.subheadline).foregroundStyle(.noteText)
                }
            }
        }
        .accessibilityIdentifier("history.row")
    }
}

/// An apply that was cut off (app closed). It can be finished or taken back here as well
/// as on the overview.
struct InterruptedHistoryRow: View {
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
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text((plan.confirmedAt ?? plan.createdAt).formatted(date: .abbreviated, time: .shortened))
                Text("Unterbrochen: \(done) von \(plan.steps.count) Schritten erledigt")
                    .font(.footnote).foregroundStyle(.noteText)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.l) { buttons }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) { buttons }
            }
            .buttonStyle(.borderless) // several buttons in one list row, each tappable on its own
            .font(.subheadline)
            .disabled(model.execution.isRunning)
            // Going on deletes albums (an undo, or a removal from "Alben von Albumist"): iOS
            // asks right after the button (P3-07).
            if plan.deletesCollections {
                DeleteQuestionNote.text
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The same words as on the overview card (design review W17).
    @ViewBuilder
    private var buttons: some View {
        let isUndo = plan.reverts != nil
        // A removal from "Alben von Albumist" is called one, as on the overview card (NIT-5).
        let isRemoval = !isUndo && !plan.removalSources.isEmpty
        // Borderless buttons in one row: each label gets the 44 pt tap area itself (W9).
        Button {
            Task {
                await model.resumeInterruptedPlan()
                await model.refreshDerived()
            }
        } label: {
            Text(isUndo ? LocalizedStringKey("Rest rückgängig machen") : isRemoval ? LocalizedStringKey("Rest entfernen") : LocalizedStringKey("Rest anlegen")).minimumHitTarget()
        }
        // An interrupted undo cannot itself be taken back; it goes on or stays as it is.
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
            } label: { Text("Alles rückgängig machen").checkingBeside(askingUndo).minimumHitTarget() }
            .disabled(askingUndo)
        }
        Button { Task { await model.keepInterruptedPlanAsIs() } } label: {
            Text(isUndo ? LocalizedStringKey("So lassen") : LocalizedStringKey("Nur Erledigtes behalten")).minimumHitTarget()
        }
    }
}

/// The privacy policy in plain words, readable without a network connection.
struct PrivacyView: View {
    var body: some View {
        List {
            Section {
                Text("Deine Fotos bleiben auf deinem Gerät. Albumist hat keinen Server, kein Konto, keine Werbung und kein Tracking.")
            }
            Section("Was Albumist speichert") {
                Text("Eine kleine Datenbank auf deinem Gerät: Datum, Ort und Analyseergebnisse deiner Fotos sowie deine Entscheidungen. Keine Bildkopien. Sie ist verschlüsselt und nicht im Backup.")
                Text("Nur deine Entscheidungen, Regeln, Einstellungen, die Alben von Albumist und der Verlauf liegen zusätzlich als kleine, verschlüsselte Kopie im Backup deines Geräts, damit sie einen Gerätewechsel überstehen. Erkannter Text und Analyseergebnisse gehören nicht dazu.")
                Text("Ausweise und medizinische Dokumente werden nicht als Text gespeichert. IBANs und Kartennummern werden unkenntlich gemacht.")
            }
            Section("Was dein Gerät verlässt") {
                Text("Für Ortsnamen schickt iOS einzelne Aufnahmeorte (nur Koordinaten und die Sprache der Ortsnamen) an Apples Kartendienst. Das ist ab Werk eingeschaltet und lässt sich unter „Orte online genauer bestimmen“ ausschalten. Fotos verlassen dein Gerät nie.")
                Text("Käufe laufen über Apple. Albumist sieht keine Zahlungsdaten.")
                Text("Die Diagnose nur, wenn du sie selbst teilst: Zustände und Zahlen, keine Fotos, Namen oder Orte.")
            }
            Section("Löschen") {
                Text("„Analyse neu aufbauen“ löscht alle Analysedaten, deine Entscheidungen bleiben. Wenn du die App löschst, ist alles weg, auch die Kopie. Deine Alben in Fotos bleiben.")
            }
            Section {
                Link("Vollständige Datenschutzerklärung", destination: AppInfo.privacyPolicyURL)
            }
        }
        .navigationTitle("Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
    }
}
