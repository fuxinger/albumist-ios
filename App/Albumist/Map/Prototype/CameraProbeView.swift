import MapKit
import QuartzCore
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

/// The camera probe over Apple's map (`CameraProbe`), full screen from the prototype's "Reise
/// abspielen" tab: one fixed camera after another on 3D satellite imagery with realistic
/// elevation, without labels and gestures, as the playback shows it. For each the plate says what
/// was asked, what MapKit gave back once the map had rendered, and when that was; "Werte kopieren"
/// puts all of it on the clipboard. The map keeps its full width and Apple's logo and
/// "Rechtliches" stay visible above the bar.
struct CameraProbeView: View {
    let onClose: () -> Void

    @State private var model = CameraProbeModel()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                CameraProbeMap(model: model)
                    .ignoresSafeArea(edges: .top)
                plate
            }
            bar
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: model.title)
                .font(.headline)
                .accessibilityIdentifier("probe.title")
            Text(verbatim: model.asked)
                .font(.footnote)
                .accessibilityIdentifier("probe.asked")
            Text(verbatim: model.got)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("probe.got")
            Text(verbatim: model.readiness)
                .font(.footnote)
                .accessibilityIdentifier("probe.state")
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            PrototypeButton(title: "Zurück", prominent: false) { model.step(by: -1) }
                .accessibilityIdentifier("probe.previous")
            PrototypeButton(title: "Weiter", prominent: true) { model.step(by: 1) }
                .accessibilityIdentifier("probe.next")
            PrototypeButton(title: model.copied ? "Kopiert" : "Werte kopieren", prominent: false) { model.copy() }
                .accessibilityIdentifier("probe.copy")
            PrototypeButton(title: "Schließen", prominent: false) { onClose() }
                .accessibilityIdentifier("probe.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black)
    }
}

/// Sets the probe's cameras on the map, waits for MapKit's first fully rendered map after each
/// (or `CameraProbe.waitSeconds`), and reads back the camera MapKit made of it. A rendering
/// counts only when it started after the camera was set, so the end of the previous camera's
/// rendering never reads as the new one being ready.
@MainActor @Observable final class CameraProbeModel {
    private(set) var index = 0
    private(set) var results: [Int: CameraProbeResult] = [:]
    private(set) var copied = false

    @ObservationIgnored private weak var mapView: MKMapView?
    @ObservationIgnored private var shownAt: CFTimeInterval = 0
    @ObservationIgnored private var renderingSinceShown = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wait: Task<Void, Never>?

    var title: String { CameraProbe.title(index: index) }
    var asked: String { CameraProbe.asked(shot) }
    var got: String { results[index].map { CameraProbe.got(shot, $0) } ?? "MapKit: …" }
    var readiness: String { results[index].map(CameraProbe.readiness) ?? "Karte lädt …" }

    private var shot: CameraProbeShot { CameraProbe.shots[index] }

    func attach(_ mapView: MKMapView) {
        self.mapView = mapView
        show()
    }

    func detach() {
        wait?.cancel()
        wait = nil
        mapView = nil
    }

    /// The map got a new size: the camera again, and the wait starts over unless the shot is done.
    func layoutChanged() {
        guard results[index] == nil else { return }
        show()
    }

    func step(by delta: Int) {
        let count = CameraProbe.shots.count
        index = ((index + delta) % count + count) % count
        copied = false
        show()
    }

    func renderingStarted() {
        renderingSinceShown = true
    }

    /// The first fully rendered map after the camera was set ends the wait.
    func renderingFinished(fully: Bool) {
        guard fully, renderingSinceShown, results[index] == nil else { return }
        finish(readySeconds: CACurrentMediaTime() - shownAt)
    }

    func copy() {
        let lines = CameraProbe.shots.indices.map { CameraProbe.line(index: $0, results[$0]) }
        UIPasteboard.general.string = (["Kamera-Probe (Reise abspielen, Entwurf 4)"] + lines).joined(separator: "\n")
        copied = true
    }

    private func show() {
        guard let mapView, mapView.bounds.width > 0, mapView.bounds.height > 0 else { return }
        generation += 1
        results[index] = nil
        renderingSinceShown = false
        shownAt = CACurrentMediaTime()
        mapView.setCamera(TripPlaybackCameraDriver.mapCamera(shot.camera), animated: false)
        let mine = generation
        wait?.cancel()
        wait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CameraProbe.waitSeconds))
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            self.finish(readySeconds: nil)
        }
    }

    private func finish(readySeconds: Double?) {
        guard results[index] == nil, let camera = mapView?.camera else { return }
        results[index] = CameraProbeResult(distanceMeters: camera.centerCoordinateDistance, pitchDegrees: Double(camera.pitch),
                                           readySeconds: readySeconds)
    }
}

/// The probe's `MKMapView`, in a container that tells the model when its size changes (MapKit
/// needs the camera again then).
private struct CameraProbeMap: UIViewRepresentable {
    let model: CameraProbeModel

    func makeCoordinator() -> CameraProbeMapCoordinator {
        CameraProbeMapCoordinator(model: model)
    }

    func makeUIView(context: Context) -> CameraProbeMapContainer {
        let container = CameraProbeMapContainer(frame: .zero)
        container.mapView.delegate = context.coordinator
        let model = self.model
        container.onLayout = { [weak model] in model?.layoutChanged() }
        model.attach(container.mapView)
        return container
    }

    func updateUIView(_ container: CameraProbeMapContainer, context: Context) {}

    static func dismantleUIView(_ container: CameraProbeMapContainer, coordinator: CameraProbeMapCoordinator) {
        coordinator.model?.detach()
        container.mapView.delegate = nil
    }
}

/// MapKit's rendering callbacks for the probe.
@MainActor final class CameraProbeMapCoordinator: NSObject {
    weak var model: CameraProbeModel?

    init(model: CameraProbeModel) {
        self.model = model
        super.init()
    }
}

extension CameraProbeMapCoordinator: @preconcurrency MKMapViewDelegate {
    func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
        model?.renderingStarted()
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        model?.renderingFinished(fully: fullyRendered)
    }
}

/// Apple's map as the playback shows it (3D satellite imagery without labels, realistic
/// elevation, no gestures), filling the container.
@MainActor final class CameraProbeMapContainer: UIView {
    let mapView = MKMapView(frame: .zero)
    var onLayout: (@MainActor () -> Void)?
    private var laidOutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        addSubview(mapView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            onLayout?()
        }
    }
}
