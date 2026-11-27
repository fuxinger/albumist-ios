import Foundation
import StoreKit
import SwiftUI

/// Who sees the map prototype (concept 2.0 §13, wave 0: "eine versteckte Prototyp-Seite, nur in
/// TestFlight sichtbar"): debug builds, TestFlight builds, and UI runs that ask for it with
/// `-AlbumistUITestMapPrototype`. Never the App Store build.
///
/// TestFlight is told by StoreKit: its app transaction comes from the sandbox environment
/// (verified or not, both count). That answer is asynchronous, so the entry appears once
/// StoreKit has answered in this launch. No answer is kept across launches: a tester who moves
/// to the App Store build would otherwise see the entry from an old answer, and when StoreKit
/// cannot answer (offline) the entry stays hidden.
///
/// App Review runs its builds in the sandbox environment too, so a reviewer would see the
/// entry: the prototype (this gate, `MapPrototypeView` and its files) has to leave the app
/// before the first build goes to App Review. It exists for wave 0 only.
@MainActor
enum MapPrototypeGate {
    /// Where builds before 25.11.2026 kept the last answer; removed at the first check.
    private static let oldTestFlightKey = "mapPrototype.isTestFlight"
    /// The answer of this launch, once StoreKit gave it.
    private static var resolved: Bool?

    /// The launch argument of the UI test (`MapPrototypeUITests`).
    static let uiTestArgument = "-AlbumistUITestMapPrototype"

    /// Compiled in every configuration, so the release path is built (and checked) in every
    /// build, not only in the archive.
    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The answer now, without waiting: in a UI run only with the argument (the other UI tests
    /// and their screenshots keep the atlas as it is), in a debug build always, else the last
    /// answer StoreKit gave in this launch (hidden until then).
    static var isVisible: Bool {
        if UITestSupport.isRunning { return ProcessInfo.processInfo.arguments.contains(uiTestArgument) }
        if isDebugBuild { return true }
        return releaseAnswer(resolved)
    }

    /// A release build's answer: only what StoreKit said in this launch, never a stored one.
    static func releaseAnswer(_ storeKit: Bool?) -> Bool {
        storeKit ?? false
    }

    /// The answer after asking StoreKit once per launch (release builds only).
    static func checkVisible() async -> Bool {
        if UITestSupport.isRunning || isDebugBuild { return isVisible }
        if let resolved { return resolved }
        UserDefaults.standard.removeObject(forKey: oldTestFlightKey)
        guard let testFlight = await isTestFlightBuild() else { return releaseAnswer(nil) }
        resolved = testFlight
        return testFlight
    }

    /// Whether the app came from TestFlight: its app transaction is signed for the sandbox.
    /// `nil` when StoreKit cannot say (offline at the first launch).
    private static func isTestFlightBuild() async -> Bool? {
        do {
            let transaction = try await AppTransaction.shared
            switch transaction {
            case .verified(let app):
                return app.environment == .sandbox
            case .unverified(let app, _):
                return app.environment == .sandbox
            }
        } catch {
            return nil
        }
    }
}

/// The atlas's entry to the prototype: a "Karten-Prototyp" button in the toolbar, shown only
/// where `MapPrototypeGate` allows it, opening `MapPrototypeView` over everything. One modifier,
/// so `AtlasView` changes by one line. Main actor (as SwiftUI's modifiers are): its first state
/// is read from `MapPrototypeGate`.
@MainActor
struct MapPrototypeEntry: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var visible = MapPrototypeGate.isVisible
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if visible {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            open = true
                        } label: {
                            Image(systemName: "globe")
                        }
                        .accessibilityLabel(Text("Karte"))
                        .accessibilityIdentifier("atlas.map")
                    }
                }
            }
            .fullScreenCover(isPresented: $open) {
                // The map for laypeople (26.11.2026); the measuring page of wave 0 is behind
                // "Messwerte" in its menu.
                WorldMapView()
                    .environment(model)
            }
            .task {
                visible = await MapPrototypeGate.checkVisible()
            }
    }
}

extension View {
    /// The map prototype's entry (`MapPrototypeEntry`).
    @MainActor
    func mapPrototypeEntry() -> some View {
        modifier(MapPrototypeEntry())
    }
}
