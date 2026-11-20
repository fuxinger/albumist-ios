import SwiftUI
import SortlyCore
import SortlyEngine

/// First start (decision 1A of 17.11.2026, review P3-04; design DS-09, draft `E5-willkommen`):
/// the welcome with the app's own icon and the four promises, then the photo access, and with
/// the access the first analysis starts at once with the settings as they are (decision 2A:
/// the areas as today, cities off, the whole library). The areas, "Städte als eigene Alben"
/// and "nur ein Jahr" are in the settings only. iOS asks about notifications when the user
/// taps "Bescheid sagen, wenn fertig" on the analysis card (decision 3B), never here.
///
/// Every way through: access not asked yet ("Weiter", then the iOS question: full or limited
/// starts the analysis, denied shows the way to the Settings app); denied or restricted before
/// ("Einstellungen öffnen"; back with access, "Analyse starten"); readable before, e.g. a
/// relaunch after the iOS question ("Analyse starten"). Nothing of the onboarding is stored
/// but its end (`onboardingDone`), so a relaunch half way starts at the welcome again;
/// settings an earlier version stored on its areas page stay as they are, and a part of the
/// library stored before is kept (`analysisScope`, `.all` on a first start).
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// The access page is pushed (design review W13): the system back button and the swipe
    /// from the edge lead back to the welcome; the welcome itself has no way back.
    enum Step: Hashable { case access }

    @State private var path: [Step] = []
    /// The iOS question is open (a second tap on "Weiter" does not ask twice).
    @State private var asking = false
    /// The analysis is started (a second tap does not start it twice).
    @State private var starting = false

    var body: some View {
        NavigationStack(path: $path) { // Own path: the onboarding pages only, no PushLink (navigation_rule.py OWN_STACKS).
            screen(WelcomePage { go(.access) })
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .access: screen(access)
                    }
                }
        }
        // Back from the Settings app (access denied before): the access page shows what iOS
        // allows now ("Analyse starten" once the photos can be read). Not while the iOS
        // question is open: its answer comes with `requestAccess`.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !asking { Task { await model.refreshAccess() } }
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

    /// The end of the onboarding: the analysis starts over the part of the library stored
    /// before (the whole library on a first start), the main screen follows.
    private func start() {
        guard !starting else { return }
        starting = true
        model.finishOnboarding(scope: model.analysisScope)
    }

    /// "Weiter": the iOS question; with access (full or limited) the analysis starts at once.
    private func askForAccess() {
        guard !asking else { return }
        asking = true
        Task {
            await model.requestAccess()
            asking = false
            if model.access.canRead { start() }
        }
    }

    // MARK: Access

    private var access: some View {
        OnboardingPage {
            IconTile(systemName: "photo.on.rectangle", tint: Theme.accent).scaleEffect(1.4).padding(.bottom, Theme.Spacing.s)
            Text("Zugriff auf deine Fotos").font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
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
                // The photos can be read already (a relaunch after the iOS question, or back
                // from the Settings app): the button says what happens.
                Button("Analyse starten") { start() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(starting)
                    .accessibilityIdentifier("onboarding.start")
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
                Button("Weiter") { askForAccess() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(asking || starting)
                    .accessibilityIdentifier("access.continue")
            }
        }
    }
}

/// The welcome (draft `E5-willkommen`): the app's own icon, large, with a calm entrance, its
/// name, the headline and the four promises, word for word as decided and tested
/// (`PromiseWordingTests`). The icon comes in rising a little and settling, the texts follow
/// one after the other; with Reduce Motion everything only fades in.
private struct WelcomePage: View {
    var letsGo: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var shown = false

    var body: some View {
        OnboardingPage {
            VStack(spacing: 0) {
                AppIconImage(side: typeSize.isAccessibilitySize ? 80 : 112)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.86)
                    .entrance(shown, order: 0, calm: reduceMotion)
                    .padding(.bottom, 22)
                Text("Albumist").font(.subheadline.weight(.semibold)).foregroundStyle(.noteText)
                    .entrance(shown, order: 1, calm: reduceMotion)
                    .padding(.bottom, 6)
                Text("Deine Fotos, endlich sortiert.").font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .entrance(shown, order: 1, calm: reduceMotion)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.m)
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                promise("iphone", "Deine Fotos bleiben auf deinem Gerät. Kein Foto wird hochgeladen.")
                    .entrance(shown, order: 2, calm: reduceMotion)
                promise("lock.shield", "Originale werden nie gelöscht, verändert oder kopiert.")
                    .entrance(shown, order: 3, calm: reduceMotion)
                promise("checklist", "Du siehst jeden Vorschlag, bevor etwas passiert, und kannst alles rückgängig machen.")
                    .entrance(shown, order: 4, calm: reduceMotion)
                promise("rectangle.stack", "Vorhandene Alben werden erkannt und ergänzt statt doppelt angelegt.")
                    .entrance(shown, order: 5, calm: reduceMotion)
            }
        } footer: {
            // The one filled button of the page; there from the start (not part of the entrance).
            Button("Los geht’s", action: letsGo)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("onboarding.letsGo")
        }
        .onAppear { shown = true }
    }

    private func promise(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            IconTile(systemName: symbol, tint: Theme.accent)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The app's icon as the Home Screen shows it (an app cannot draw its own `AppIcon` set, so the
/// same artwork is in the image set `AppIconImage`, light and dark): the rounded square of iOS,
/// a soft shadow and a hairline edge that keeps its shape on the light background. Decorative:
/// the name below says what it is.
private struct AppIconImage: View {
    var side: CGFloat

    var body: some View {
        // iOS rounds an icon's corners by about 22.4 % of its side (continuous corners).
        let shape = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
        Image("AppIconImage")
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5) }
            .shadow(color: Color(red: 10 / 255, green: 60 / 255, blue: 70 / 255).opacity(0.18), radius: 15, y: 12)
            .accessibilityHidden(true)
    }
}

/// One onboarding page: the content scrolls when it does not fit (large text, small iPhones)
/// and is centered when it does; the button stays at the bottom.
private struct OnboardingPage<Content: View, Footer: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) { content }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
        .safeAreaInset(edge: .bottom) {
            footer
                .frame(maxWidth: 560)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
        }
    }
}

extension View {
    /// The welcome's entrance: rising a little and fading in, `order` steps after the start;
    /// `calm` (Reduce Motion): only the fade, sooner and without movement.
    fileprivate func entrance(_ shown: Bool, order: Int, calm: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || calm ? 0 : 10)
            .animation(calm ? Animation.easeOut(duration: 0.35).delay(0.04 * Double(order))
                            : Animation.spring(duration: 0.7, bounce: 0.18).delay(0.1 + 0.08 * Double(order)),
                       value: shown)
    }
}
