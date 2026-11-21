import MetalKit
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

/// Our own globe (concept §4.2, §7, plan A): the Earth drawn with Metal, glowing arcs above it,
/// the visited countries a little brighter, and the pins as SwiftUI views on top. Turned, zoomed
/// and flown like Apple's maps (`GlobeController`, `GlobeMotion`); below 3,000 km it hands over
/// to Apple's map once and stops drawing until `controller.jump(to:)` brings it back.
struct OwnGlobeView: View {
    private let scene: GlobeScene
    private let outlines: [AtlasShape]
    private let controller: GlobeController
    private let metrics: PrototypeMetrics
    private let onHandover: (GlobeCamera) -> Void
    @State private var overlay = GlobeOverlayModel()

    /// `outlines`: the country shapes for the tint (`AtlasOutlines.shared.load(from:)` gives
    /// them; may be empty at first and arrive later). `onHandover`: called once when the
    /// camera's width goes below `GlobeCamera.handoverWidthMeters`; the globe then stops
    /// drawing until `controller.jump(to:)` brings it back.
    init(scene: GlobeScene, outlines: [AtlasShape], controller: GlobeController, metrics: PrototypeMetrics,
         onHandover: @escaping (GlobeCamera) -> Void) {
        self.scene = scene
        self.outlines = outlines
        self.controller = controller
        self.metrics = metrics
        self.onHandover = onHandover
    }

    var body: some View {
        ZStack {
            GlobeMetalRepresentable(scene: scene, outlines: outlines, controller: controller, metrics: metrics,
                                    overlay: overlay, onHandover: onHandover)
            GlobePinOverlay(model: overlay)
                .allowsHitTesting(false)
            GlobeProblemNote(model: overlay)
                .allowsHitTesting(false)
        }
        .background(GlobeRenderer.spaceColor)
    }
}

/// The MTKView of our globe in SwiftUI; its coordinator is the renderer.
struct GlobeMetalRepresentable: UIViewRepresentable {
    let scene: GlobeScene
    let outlines: [AtlasShape]
    let controller: GlobeController
    let metrics: PrototypeMetrics
    let overlay: GlobeOverlayModel
    let onHandover: (GlobeCamera) -> Void

    func makeCoordinator() -> GlobeRenderer {
        GlobeRenderer(controller: controller, metrics: metrics, overlay: overlay)
    }

    func makeUIView(context: Context) -> GlobeMetalView {
        let view = context.coordinator.makeView()
        context.coordinator.update(scene: scene, outlines: outlines, controller: controller, onHandover: onHandover)
        return view
    }

    func updateUIView(_ view: GlobeMetalView, context: Context) {
        context.coordinator.update(scene: scene, outlines: outlines, controller: controller, onHandover: onHandover)
    }

    static func dismantleUIView(_ view: GlobeMetalView, coordinator: GlobeRenderer) {
        coordinator.stop()
    }
}

/// The MTKView of our globe: tells the renderer when a finger touches it (a flight or the
/// coasting stops at once, as in Apple's maps) and draws at the screen's own pixel density.
final class GlobeMetalView: MTKView {
    weak var renderer: GlobeRenderer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        renderer?.touchDown()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The screen's real pixels (smaller than its point scale on some iPhones): sharp, and
        // no pixel drawn only to be scaled away.
        if let screen = window?.windowScene?.screen {
            contentScaleFactor = screen.nativeScale
        }
        renderer?.viewMovedToWindow()
    }
}
