import MapKit
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

/// A piece of "Reise abspielen" (concept §4.4, prototype tab "Reise abspielen"): `MKMapView` with
/// 3D satellite imagery without labels, our own camera day by day (`TripPlaybackModel`), pause,
/// day jump, waiting for the map before each day (at most 1.5 s, else the day runs as a
/// slideshow), and at the end the "Willkommen zurück" card.
///
/// The map takes the space above the bottom bar, so Apple's logo and "Rechtliches" stay visible at
/// its bottom edge; the title plate sits at its top. Give the view the area below the page's own
/// top bar.
struct TripPlaybackView: View {
    let trip: MapTrip
    let showsPhotos: Bool
    let autoplay: Bool
    let metrics: PrototypeMetrics
    let onFinished: () -> Void

    /// `showsPhotos`: false for the demo trip (its photo ids are made up): quiet placeholder tiles
    /// instead of photos.
    init(trip: MapTrip, showsPhotos: Bool, autoplay: Bool, metrics: PrototypeMetrics, onFinished: @escaping () -> Void) {
        self.trip = trip
        self.showsPhotos = showsPhotos
        self.autoplay = autoplay
        self.metrics = metrics
        self.onFinished = onFinished
    }

    var body: some View {
        TripPlaybackHost(trip: trip, showsPhotos: showsPhotos, autoplay: autoplay, metrics: metrics, onFinished: onFinished)
            .id(trip.id)
    }
}

/// Makes the model once per trip (a view's initializer runs again and again; the model must not).
private struct TripPlaybackHost: View {
    let trip: MapTrip
    let showsPhotos: Bool
    let autoplay: Bool
    let metrics: PrototypeMetrics
    let onFinished: () -> Void

    @State private var model: TripPlaybackModel?

    var body: some View {
        ZStack {
            if let model {
                TripPlaybackScreen(model: model, autoplay: autoplay)
            } else {
                Color.black
            }
        }
        .onAppear {
            if model == nil {
                model = TripPlaybackModel(trip: trip, showsPhotos: showsPhotos, metrics: metrics, onFinished: onFinished)
            }
        }
    }
}

/// The map with its plates and cards, and the bottom bar under it.
private struct TripPlaybackScreen: View {
    let model: TripPlaybackModel
    let autoplay: Bool

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TripPlaybackMap(model: model)
                    .ignoresSafeArea(edges: .top)
                TripPlaybackCoverLayer(model: model)
                TripPlaybackChrome(model: model)
                TripPlaybackEndLayer(model: model)
            }
            .animation(.easeInOut(duration: 0.25), value: model.showsCover)
            .animation(.easeInOut(duration: 0.3), value: model.state == .finished)
            TripPlaybackBottomBar(model: model)
        }
        .background(Color.black)
        .onAppear { model.appeared(autoplay: autoplay) }
        .onDisappear { model.disappeared() }
        .onChange(of: scenePhase) { _, phase in
            model.sceneChanged(active: phase == .active)
        }
    }
}

/// The `MKMapView` of the playback, in a container that also holds the dot.
private struct TripPlaybackMap: UIViewRepresentable {
    let model: TripPlaybackModel

    func makeCoordinator() -> TripPlaybackMapCoordinator {
        TripPlaybackMapCoordinator(model: model)
    }

    func makeUIView(context: Context) -> TripPlaybackMapContainer {
        let container = TripPlaybackMapContainer(frame: .zero)
        container.mapView.delegate = context.coordinator
        context.coordinator.container = container
        model.attach(container)
        return container
    }

    func updateUIView(_ container: TripPlaybackMapContainer, context: Context) {}

    static func dismantleUIView(_ container: TripPlaybackMapContainer, coordinator: TripPlaybackMapCoordinator) {
        coordinator.model?.detach()
        container.mapView.delegate = nil
    }
}

/// MapKit's callbacks for the playback: rendering (the wait for each day's map) and the route's
/// look.
@MainActor final class TripPlaybackMapCoordinator: NSObject {
    weak var model: TripPlaybackModel?
    weak var container: TripPlaybackMapContainer?

    init(model: TripPlaybackModel) {
        self.model = model
        super.init()
    }
}

extension TripPlaybackMapCoordinator: @preconcurrency MKMapViewDelegate {
    func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
        model?.renderingStarted()
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        model?.renderingFinished(fully: fullyRendered)
    }

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
        model?.loadingFailed()
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        container?.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
    }
}

/// Apple's map (3D satellite imagery without labels, realistic elevation, no gestures: the
/// playback moves the camera) with the bright dot above it, and the route as straight lines: the
/// stops reached solid white with a dark border, the way to the next one dashed.
@MainActor final class TripPlaybackMapContainer: UIView {
    let mapView = MKMapView(frame: .zero)
    /// Called when the view gets a new size (MapKit needs the camera again then).
    var onLayout: (@MainActor () -> Void)?

    private let dot = TripPlaybackDotView(frame: CGRect(x: 0, y: 0, width: TripPlaybackDotView.side, height: TripPlaybackDotView.side))
    private var laidOutSize: CGSize = .zero
    private var travelled: MKPolyline?
    private var travelledBorder: MKPolyline?
    private var ahead: MKPolyline?
    private var aheadBorder: MKPolyline?

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
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        addSubview(dot)
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

    /// Puts the dot where `coordinate` is on screen; hidden when it is not on the map.
    func placeDot(at coordinate: GeoCoordinate) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = mapView.convert(AppleMapsBridge.coordinate(coordinate), toPointTo: self)
        guard point.x.isFinite, point.y.isFinite, bounds.insetBy(dx: -20, dy: -20).contains(point) else {
            dot.isHidden = true
            return
        }
        dot.isHidden = false
        dot.center = point
    }

    /// Draws `route` instead of the route before.
    func showRoute(_ route: PlaybackRoute) {
        let old = [aheadBorder, ahead, travelledBorder, travelled].compactMap { $0 }
        mapView.removeOverlays(old)
        aheadBorder = nil
        ahead = nil
        travelledBorder = nil
        travelled = nil
        var added: [MKPolyline] = []
        if route.ahead.count >= 2 {
            let coordinates = route.ahead.map(AppleMapsBridge.coordinate)
            let border = MKPolyline(coordinates: coordinates, count: coordinates.count)
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            aheadBorder = border
            ahead = line
            added += [border, line]
        }
        if route.travelled.count >= 2 {
            let coordinates = route.travelled.map(AppleMapsBridge.coordinate)
            let border = MKPolyline(coordinates: coordinates, count: coordinates.count)
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            travelledBorder = border
            travelled = line
            added += [border, line]
        }
        // Later overlays lie on top: the borders under their lines, the way travelled over the way ahead.
        mapView.addOverlays(added, level: .aboveRoads)
    }

    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        if line === travelledBorder {
            renderer.strokeColor = UIColor.black.withAlphaComponent(0.6)
            renderer.lineWidth = 7
        } else if line === travelled {
            renderer.strokeColor = UIColor.white
            renderer.lineWidth = 3.5
        } else if line === aheadBorder {
            renderer.strokeColor = UIColor.black.withAlphaComponent(0.35)
            renderer.lineWidth = 5
        } else {
            renderer.strokeColor = UIColor.white.withAlphaComponent(0.9)
            renderer.lineWidth = 2.5
            renderer.lineDashPattern = [6, 7]
        }
        return renderer
    }
}

/// The bright dot that travels the route: white with a gold ring and a soft glow.
@MainActor final class TripPlaybackDotView: UIView {
    static let side: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.cornerRadius = frame.width / 2
        layer.borderWidth = 3
        layer.borderColor = AppleMapsStyle.arcEndUIColor.cgColor
        layer.shadowColor = UIColor.white.cgColor
        layer.shadowOpacity = 0.9
        layer.shadowRadius = 8
        layer.shadowOffset = .zero
    }

    required init?(coder: NSCoder) {
        return nil
    }
}
