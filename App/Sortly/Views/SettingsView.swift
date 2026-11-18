import SwiftUI
import SortlyCore
import SortlyEngine

/// Settings (prompt §17): areas, naming, privacy, history and undo, about.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Purchases.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    @State private var redeeming = false
    @State private var rejectedCount = 0
    @State private var confirmTripReset = false

    var body: some View {
        @Bindable var model = model
        Form {
            // Undo first and on its own screen (design review W16: the history sat between
            // privacy and the purchase, the seventh of twelve sections).
            Section {
                // Pushed by value (`AppScreen`), like the screens behind it: a receipt pushes
                // "Fehlendes erneut versuchen".
                PushLink(.history) {
                    LabeledContent {
                        if model.interruptedPlan != nil { Text("Unterbrochen") }
                    } label: {
                        Label("Verlauf und Rückgängig", systemImage: "clock.arrow.circlepath")
                    }
                }
                .accessibilityIdentifier("settings.history")
            } footer: {
                Text("Alles, was Albumist in Fotos geändert hat, und der Weg zurück.")
            }

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
                LabeledContent("Ordner für neue Alben") {
                    TextField("Kein Ordner", text: $model.settings.rootFolderTitle)
                        .multilineTextAlignment(.trailing)
                }
                if model.settings.enabledAreas.contains(.places) {
                    // Off by default: a trip would otherwise bring a country, two cities and
                    // itself as four albums (usability test 14.11.2026).
                    Toggle(isOn: $model.settings.places.includesCities) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Städte als eigene Alben")
                            Text("Zum Beispiel Rom und Florenz zusätzlich zu Italien.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Foto in mehreren Alben erlauben", isOn: $model.settings.allowMultipleAssignments)
                // Pushed by value: it pushes the preview of a removal (`AppScreen`).
                PushLink(.managedAlbums) {
                    LabeledContent("Alben von Albumist", value: model.managedAlbums.count.formatted())
                }
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
                Text("Die Analyse läuft immer auf deinem Gerät. Für Ortsnamen schickt iOS einzelne Aufnahmeorte (nur Koordinaten) an Apples Kartendienst, nie ein Foto. Aus iCloud werden nur Screenshots und Dokumente geladen, nie Videos, und nur im WLAN, wenn du nichts anderes einstellst.")
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
                        .disabled(model.analysis.isRunning || model.execution.isRunning)
                        .accessibilityIdentifier("settings.resetTrips")
                        .confirmationDialog("Reisen wieder automatisch erkennen?", isPresented: $confirmTripReset, titleVisibility: .visible) {
                            Button("Automatisch erkennen") { Task { await model.resetTripCorrections() } }
                        } message: {
                            Text("Albumist vergisst, welche Reisen du geteilt oder zusammengelegt hast. Schon angelegte Alben bleiben, wie sie sind.")
                        }
                } header: {
                    Text("Reisen")
                } footer: {
                    Text("Albumist hält sich an deine Änderungen, auch bei jeder neuen Analyse.")
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
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Über")
            } footer: {
                Text("Die Diagnose hilft bei Problemen. Sie enthält nur Zustände und Zahlen, keine Fotos, Albumnamen oder Orte, und du siehst sie vor dem Senden.")
            }
        }
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
                        model.startAnalysis(userInitiated: true)
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

/// Every change Albumist made, newest first, each with its way back (design review W16).
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
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if model.undonePlans.contains(plan.id) {
                    Text("Rückgängig gemacht")
                        .font(.subheadline).foregroundStyle(.secondary)
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

    var body: some View {
        let done = plan.steps.filter { if case .succeeded = $0.state { true } else { false } }.count
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text((plan.confirmedAt ?? plan.createdAt).formatted(date: .abbreviated, time: .shortened))
                Text("Unterbrochen: \(done) von \(plan.steps.count) Schritten erledigt")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.l) { buttons }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) { buttons }
            }
            .buttonStyle(.borderless) // several buttons in one list row, each tappable on its own
            .font(.subheadline)
            .disabled(model.execution.isRunning)
        }
        .confirmationDialog("Alles zurücknehmen?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Alles zurücknehmen", role: .destructive) {
                Task { await model.undoInterruptedPlan() }
            }
        } message: {
            Text("Albumist entfernt, was sicher von Albumist ist, und sagt dir, falls etwas bleibt. Deine Fotos bleiben unverändert.")
        }
    }

    /// The same words as on the overview card (design review W17).
    @ViewBuilder
    private var buttons: some View {
        let isUndo = plan.reverts != nil
        // Borderless buttons in one row: each label gets the 44 pt tap area itself (W9).
        Button {
            Task {
                await model.resumeInterruptedPlan()
                await model.refreshDerived()
            }
        } label: {
            Text(isUndo ? LocalizedStringKey("Rest zurücknehmen") : LocalizedStringKey("Rest anlegen")).minimumHitTarget()
        }
        // An interrupted undo cannot itself be taken back; it goes on or stays as it is.
        if !isUndo {
            Button { confirmUndo = true } label: { Text("Alles zurücknehmen").minimumHitTarget() }
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
                Text("Für Ortsnamen schickt iOS einzelne Aufnahmeorte (nur Koordinaten) an Apples Kartendienst. Das ist ab Werk eingeschaltet und lässt sich unter „Orte online genauer bestimmen“ ausschalten. Fotos verlassen dein Gerät nie.")
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
