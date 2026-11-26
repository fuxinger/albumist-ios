import SwiftUI
import AlbumistCore
import AlbumistMap

/// The tab "Unser Globus": our Metal globe and, after a handover (`OwnGlobeView.onHandover`),
/// Apple's map above it. The map starts practically invisible and fades in over 0.3 s once it
/// has rendered fully (`HandoverMapView.onReady`), so the user never sees half-loaded tiles;
/// zoomed back out (`onBackToGlobe`), our globe continues from the map's camera and the map
/// fades out.
struct MapPrototypeGlobeTab: View {
    let scene: GlobeScene
    let outlines: [AtlasShape]
    let controller: GlobeController
    let metrics: PrototypeMetrics
    @Binding var handover: PrototypeHandover?
    /// Counts the handovers of this tab: each one gets a map view of its own.
    @State private var handovers = 0

    /// The cross-fade of the handover: 0.3 s.
    static var fade: Animation { .easeInOut(duration: 0.3) }
    /// Apple's map shows after this long even if it never says it rendered fully (no network,
    /// tiles that never come), so the page never stands on a stopped globe.
    static let revealFallbackSeconds = 5.0
    /// The map's opacity until it is shown. Not 0: a view that is fully transparent may be
    /// treated as hidden, and the map must load and render its tiles meanwhile.
    static let waitingOpacity = 0.02

    var body: some View {
        ZStack {
            OwnGlobeView(scene: scene, outlines: outlines, controller: controller, metrics: metrics,
                         onHandover: { camera in handOver(at: camera) })
            if let handover {
                handoverMap(handover)
            }
        }
    }

    private func handoverMap(_ current: PrototypeHandover) -> some View {
        HandoverMapView(scene: scene, camera: current.camera, metrics: metrics,
                        onReady: { reveal(current.number) },
                        onBackToGlobe: { camera in backToGlobe(from: current.number, at: camera) })
            .id(current.number)
            .opacity(current.shown ? 1 : Self.waitingOpacity)
            .allowsHitTesting(current.shown)
            .transition(.opacity)
            .task(id: current.number) { await revealLate(current.number) }
    }

    /// Our globe went below the handover width and stopped drawing: Apple's map starts there.
    private func handOver(at camera: GlobeCamera) {
        handovers += 1
        handover = PrototypeHandover(camera: camera, number: handovers)
    }

    /// Apple's map has rendered fully (or the fallback ran out): cross-fade it in.
    private func reveal(_ number: Int) {
        guard let current = handover, current.number == number, !current.shown else { return }
        withAnimation(Self.fade) {
            handover?.shown = true
        }
    }

    private func revealLate(_ number: Int) async {
        try? await Task.sleep(for: .seconds(Self.revealFallbackSeconds))
        guard !Task.isCancelled else { return }
        reveal(number)
    }

    /// The user zoomed out on Apple's map: our globe continues from its camera, the map fades out.
    private func backToGlobe(from number: Int, at camera: GlobeCamera) {
        guard handover?.number == number else { return }
        controller.jump(to: camera)
        withAnimation(Self.fade) {
            handover = nil
        }
    }
}
