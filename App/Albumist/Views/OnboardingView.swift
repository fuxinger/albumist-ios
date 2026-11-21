import SwiftUI
import AlbumistCore
import AlbumistEngine

/// First start (prompt §7, Schritt 1–3): promise, areas, photo access, first analysis.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The steps after the welcome screen are pushed (design review W13): the system back
    /// button and the swipe from the edge lead back, e.g. to change the areas; the welcome
    /// screen itself has no way back.
    enum Step: Hashable { case areas, access, start }

    @State private var path: [Step] = []
    @State private var trialYear: Int?

    var body: some View {
        NavigationStack(path: $path) { // Own path: the onboarding pages only, no PushLink (navigation_rule.py OWN_STACKS).
            screen(welcome)
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .areas: screen(areas)
                    case .access: screen(access)
                    case .start: screen(start)
                    }
                }
        }
    }

    private func screen(_ content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
    }

    /// Goes one step on; a second tap while the push runs does not add the step twice.
    private func go(_ step: Step) {
        if path.last != step { path.append(step) }
    }

    /// One onboarding step: the content scrolls when it does not fit (large text, small
    /// iPhones) and is centered when it does; the button stays at the bottom.
    private func page<Content: View, Footer: View>(
        centered: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) { content() }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(centered ? .center : .top, for: .alignment)
        .safeAreaInset(edge: .bottom) {
            footer()
                .frame(maxWidth: 560)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        page {
            Text("Albumist").font(.subheadline.weight(.semibold)).foregroundStyle(.noteText)
            Text("Deine Fotos, endlich sortiert.").font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Theme.Spacing.s)
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                promise("iphone", "Deine Fotos bleiben auf deinem Gerät. Kein Foto wird hochgeladen.")
                promise("lock.shield", "Originale werden nie gelöscht, verändert oder kopiert.")
                promise("checklist", "Du siehst jeden Vorschlag, bevor etwas passiert, und kannst alles rückgängig machen.")
                promise("rectangle.stack", "Vorhandene Alben werden erkannt und ergänzt statt doppelt angelegt.")
            }
        } footer: {
            Button("Los geht’s") { go(.areas) }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func promise(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            IconTile(systemName: symbol, tint: Theme.accent)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var areas: some View {
        page(centered: false) {
            Text("Was soll Albumist sortieren?").font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Die markierten Bereiche zählen als deine Hauptsortierung. Du kannst das später jederzeit ändern.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.Spacing.s) {
                ForEach(OrganizationArea.available, id: \.self) { area in
                    areaCard(area)
                }
            }
        } footer: {
            VStack(spacing: Theme.Spacing.s) {
                Button("Weiter") {
                    model.saveSettings()
                    go(.access)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.settings.enabledAreas.isEmpty)
                // Why the button is grey (design review N6).
                if model.settings.enabledAreas.isEmpty {
                    Text("Wähle mindestens einen Bereich.")
                        .font(.footnote).foregroundStyle(.noteText)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("onboarding.areasHint")
                }
            }
        }
    }

    private func areaCard(_ area: OrganizationArea) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Toggle(isOn: Binding(
                get: { model.settings.enabledAreas.contains(area) },
                set: { on in
                    if on { model.settings.enabledAreas.insert(area) } else { model.settings.enabledAreas.remove(area) }
                }
            )) {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(systemName: area.symbol, tint: area.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(area.title).font(.body.weight(.medium))
                        Text(area.explanation).font(.footnote).foregroundStyle(.noteText)
                    }
                }
            }
            if area == .places && model.settings.enabledAreas.contains(.places) {
                citiesToggle
            }
        }
        .padding(Theme.Spacing.m)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card - 6, style: .continuous))
        .animation(.default, value: model.settings.enabledAreas.contains(.places))
    }

    /// Right at the start (Fuchs, 14.11.): cities are off by default, but whoever wants
    /// Rom and Florenz next to Italien can say so here, not only later in Settings.
    @ViewBuilder
    private var citiesToggle: some View {
        @Bindable var model = model
        Divider()
        Toggle(isOn: $model.settings.places.includesCities) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Städte als eigene Alben").font(.subheadline.weight(.medium))
                Text("Zum Beispiel Rom und Florenz zusätzlich zu Italien.")
                    .font(.footnote).foregroundStyle(.noteText)
            }
        }
    }

    private var access: some View {
        page {
            IconTile(systemName: "photo.on.rectangle", tint: Theme.accent).scaleEffect(1.4).padding(.bottom, Theme.Spacing.s)
            Text("Zugriff auf deine Fotos").font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            // Said where the user agrees (decision Fuchs 18.11.2026, review P2-03): place names come
            // from Apple, on by default, switch in the settings.
            Text("Albumist braucht vollen Zugriff, um deine Mediathek zu analysieren und Alben anzulegen. Die Analyse passiert nur auf diesem Gerät. Für Ortsnamen schickt iOS einzelne Aufnahmeorte (nur Koordinaten und die Sprache der Ortsnamen) an Apples Kartendienst – das kannst du in den Einstellungen ausschalten.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Testers asked exactly here whether "full access" means the app may delete.
            Label("Albumist löscht und verändert nie ein Foto. Es legt nur Alben an, und jeder Schritt lässt sich rückgängig machen.", systemImage: "checkmark.shield")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            switch model.access {
            case .denied, .restricted:
                Card {
                    // The path of iOS 18 and later, like the other access screens (design review W14).
                    Label("Kein Zugriff auf deine Fotos", systemImage: "exclamationmark.triangle").font(.headline)
                    Text("Erlaube ihn unter Einstellungen › Apps › Albumist › Fotos › Voller Zugriff.")
                }
            case .limited:
                Card {
                    Label("Nur ausgewählte Fotos", systemImage: "photo.badge.checkmark").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Albumist sortiert dann nur die Fotos, die du freigegeben hast. Für die ganze Mediathek kannst du später vollen Zugriff erlauben.")
                }
            default:
                EmptyView()
            }
        } footer: {
            if model.access.canRead {
                Button("Weiter") { go(.start) }.buttonStyle(PrimaryButtonStyle())
            } else if model.access == .denied || model.access == .restricted {
                // iOS does not ask a second time: the way on is the Settings app.
                Button("Einstellungen öffnen") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("access.settings")
            } else {
                // "Weiter", not "Zugriff erlauben": a screen before the system prompt must not
                // read like the consent itself (App Review 5.1.1, plugin review K5).
                Button("Weiter") {
                    Task {
                        await model.requestAccess()
                        if model.access.canRead { go(.start) }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("access.continue")
            }
        }
    }

    private var start: some View {
        let currentYear = Calendar.current.component(.year, from: Date())
        return page {
            Text("Womit soll Albumist anfangen?").font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Mit einem Jahr anzufangen geht schneller: Albumist analysiert dann nur diese Fotos und macht nur dafür Vorschläge. So prüfst du das Ergebnis in Ruhe. Die ganze Mediathek kannst du jederzeit dazunehmen.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A settings-style row with a menu instead of a wheel (HIG: menus for short lists).
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Anfangen mit")
                    Spacer(minLength: Theme.Spacing.m)
                    trialPicker(currentYear)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Anfangen mit")
                    trialPicker(currentYear)
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .frame(minHeight: 52)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            Text("Die erste Analyse kann bei großen Mediatheken eine Weile dauern. Du kannst die App dabei verlassen: Solange iOS es erlaubt, läuft sie weiter und zeigt den Fortschritt auf dem Sperrbildschirm, sonst geht sie beim nächsten Öffnen genau dort weiter. Wenn du magst, sagt Albumist dir Bescheid, sobald sie fertig ist.")
                .font(.footnote).foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("Analyse starten") {
                model.finishOnboarding(scope: trialYear.map { .year($0) } ?? .all)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

extension OnboardingView {
    fileprivate func trialPicker(_ currentYear: Int) -> some View {
        Picker("Anfangen mit", selection: $trialYear) {
            Text("Die ganze Mediathek").tag(Int?.none)
            ForEach((0..<6).map { currentYear - $0 }, id: \.self) { year in
                Text("Nur \(String(year))").tag(Int?.some(year))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.accent)
    }
}
