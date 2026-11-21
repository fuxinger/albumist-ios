import MapKit
import SwiftUI
import UIKit

// The camera probe's map (CameraProbeView): Apple's map as the playback shows it, and MapKit's
// rendering callbacks for the probe's model.

/// The probe's `MKMapView`, in a container that tells the model when its size changes (MapKit
/// needs the camera again then).
struct CameraProbeMap: UIViewRepresentable {
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
