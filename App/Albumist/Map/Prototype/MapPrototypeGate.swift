import Foundation
import StoreKit
import SwiftUI

/// Who sees the map prototype (concept 2.0 §13, wave 0: "eine versteckte Prototyp-Seite, nur in
/// TestFlight sichtbar"): debug builds, TestFlight builds, and UI runs that ask for it with
/// `-AlbumistUITestMapPrototype`. Never the App Store build.
///
/// TestFlight is told by StoreKit: its app transaction comes from the sandbox environment
/// (verified or not, both count). That answer is asynchronous, so the last one is kept in the
/// user defaults and the entry shows at once on the next visit; the App Store build always
/// answers "production" and so never shows it.
@MainActor
enum MapPrototypeGate {
    private static let testFlightKey = "mapPrototype.isTestFlight"
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
    /// answer StoreKit gave.
    static var isVisible: Bool {
        if UITestSupport.isRunning { return ProcessInfo.processInfo.arguments.contains(uiTestArgument) }
        if isDebugBuild { return true }
        return resolved ?? UserDefaults.standard.bool(forKey: testFlightKey)
    }

    /// The answer after asking StoreKit once per launch (release builds only).
    static func checkVisible() async -> Bool {
        if UITestSupport.isRunning || isDebugBuild { return isVisible }
        if let resolved { return resolved }
        guard let testFlight = await isTestFlightBuild() else { return isVisible }
        resolved = testFlight
        UserDefaults.standard.set(testFlight, forKey: testFlightKey)
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
                        .accessibilityLabel(Text(verbatim: "Karten-Prototyp"))
                    }
                }
            }
            .fullScreenCover(isPresented: $open) {
                MapPrototypeView()
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
