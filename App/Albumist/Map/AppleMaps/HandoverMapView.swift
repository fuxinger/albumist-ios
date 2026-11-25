import MapKit
import QuartzCore
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

/// Apple's map after the handover (concept §7: under about 3,000 km our globe hands over to
/// `MKMapView`): standard style, muted, realistic elevation, no points of interest. It starts
/// showing exactly `camera`'s area (no animation), draws the arcs as flat geodesic lines, the pins
/// of the level for its width (picked and grouped again whenever the view comes to rest) and the
/// rounded home's house where `MapHome.showsHouse(atWidth:)` says so.
///
/// `onReady`: once, when the map has rendered fully for the first time (the page then cross-fades
/// in 0.3 s; `metrics` gets `.handover` with the seconds since this view was made). Without a full
/// rendering after `AppleHandoverCoordinator.readyFallbackSeconds` (no network) it is called anyway,
/// so the page never hangs on the globe; the measurement then waits for the real rendering.
/// `onBackToGlobe`: when the user zooms out beyond 1.1 × the handover width, with the camera to
/// continue our globe from. No user location, no location permission.
struct HandoverMapView: View {
    let scene: GlobeScene
    let camera: GlobeCamera
    let metrics: PrototypeMetrics
    let onReady: () -> Void
    let onBackToGlobe: (GlobeCamera) -> Void

    init(scene: GlobeScene, camera: GlobeCamera, metrics: PrototypeMetrics,
         onReady: @escaping () -> Void, onBackToGlobe: @escaping (GlobeCamera) -> Void) {
        self.scene = scene
        self.camera = camera
        self.metrics = metrics
        self.onReady = onReady
        self.onBackToGlobe = onBackToGlobe
    }

    var body: some View {
        GeometryReader { proxy in
            AppleHandoverMap(scene: scene, camera: camera, size: proxy.size, metrics: metrics,
                             onReady: onReady, onBackToGlobe: onBackToGlobe)
        }
        .ignoresSafeArea()
    }
}

/// The `MKMapView` of the handover.
private struct AppleHandoverMap: UIViewRepresentable {
    let scene: GlobeScene
    let camera: GlobeCamera
    let size: CGSize
    let metrics: PrototypeMetrics
    let onReady: () -> Void
    let onBackToGlobe: (GlobeCamera) -> Void

    func makeCoordinator() -> AppleHandoverCoordinator {
        AppleHandoverCoordinator(scene: scene, camera: camera, metrics: metrics)
    }

    func makeUIView(context: Context) -> MKMapView {
        let coordinator = context.coordinator
        coordinator.onReady = onReady
        coordinator.onBackToGlobe = onBackToGlobe
        return coordinator.makeMapView(size: size)
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onReady = onReady
        coordinator.onBackToGlobe = onBackToGlobe
        coordinator.startIfSized(mapView, size: size)
    }

    static func dismantleUIView(_ mapView: MKMapView, coordinator: AppleHandoverCoordinator) {
        coordinator.dismantle(mapView)
    }
}

/// Runs Apple's map after the handover: its start area, arcs, pins, house, the first full
/// rendering, and the way back to our globe.
@MainActor final class AppleHandoverCoordinator: NSObject {
    /// How long the page waits at most for the first full rendering before it shows the map anyway.
    static let readyFallbackSeconds = 5.0
    static let houseReuseName = "albumist.apple-maps.house"

    var onReady: () -> Void = {}
    var onBackToGlobe: (GlobeCamera) -> Void = { _ in }

    private let scene: GlobeScene
    private let startCamera: GlobeCamera
    private let metrics: PrototypeMetrics
    private let createdAt = CACurrentMediaTime()
    /// Beyond this width the map hands back: 1.1 × the handover width, or 1.1 × the start's width
    /// when the handover came at a wider view, so the start itself never hands back.
    private let backWidthMeters: Double
    private var started = false
    private var renderingSinceStart = false
    /// The map has finished a rendering since the start: from then on its own view counts.
    private var hasRendered = false
    private var measuredHandover = false
    private var calledReady = false
    private var handedBack = false
    private weak var mapView: MKMapView?
    private var sampler: DisplayLinkSampler?
    private var readyFallback: Task<Void, Never>?
    private var pins: [String: AppleMapsPinAnnotation] = [:]
    private var arcLines: [MKGeodesicPolyline] = []
    private var arcWeights: [ObjectIdentifier: Int] = [:]
    private var arcsShown = false
    private var house: AppleMapsHouseAnnotation?

    init(scene: GlobeScene, camera: GlobeCamera, metrics: PrototypeMetrics) {
        self.scene = scene
        let start = camera.clamped
        self.startCamera = start
        self.metrics = metrics
        self.backWidthMeters = max(MapKitCamera.backToGlobeWidthMeters, 1.1 * start.widthMeters)
        super.init()
    }

    func makeMapView(size: CGSize) -> MKMapView {
        let mapView = MKMapView(frame: CGRect(origin: .zero, size: size))
        let configuration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = configuration
        // Apple's logo and "Rechtliches" stay above the page's controls at the bottom.
        mapView.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: AppleMapsStyle.handoverBottomMargin, right: 0)
        mapView.register(AppleMapsPinAnnotationView.self, forAnnotationViewWithReuseIdentifier: AppleMapsPinAnnotationView.reuseName)
        mapView.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.houseReuseName)
        mapView.delegate = self
        self.mapView = mapView
        var lines: [MKGeodesicPolyline] = []
        for arc in scene.arcs {
            let coordinates = [AppleMapsBridge.coordinate(arc.from), AppleMapsBridge.coordinate(arc.to)]
            let line = MKGeodesicPolyline(coordinates: coordinates, count: coordinates.count)
            arcWeights[ObjectIdentifier(line)] = arc.weight
            lines.append(line)
        }
        arcLines = lines
        startIfSized(mapView, size: size)
        let sampler = DisplayLinkSampler(source: .handoverMap, metrics: metrics)
        sampler.start()
        self.sampler = sampler
        readyFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppleHandoverCoordinator.readyFallbackSeconds))
            guard !Task.isCancelled else { return }
            self?.readyWithoutFullMap()
        }
        return mapView
    }

    /// Shows the start area once the view has a size: a flat rect exactly the camera's width
    /// (`MapKitCamera.region`, west to east through the centre), which MapKit fits by its width
    /// whatever the screen's height (a portrait-high rect could reach past the pole).
    func startIfSized(_ mapView: MKMapView, size: CGSize) {
        guard !started, size.width > 0, size.height > 0 else { return }
        if mapView.bounds.width <= 0 || mapView.bounds.height <= 0 {
            mapView.frame = CGRect(origin: mapView.frame.origin, size: size)
        }
        started = true
        let region = MapKitCamera.region(for: startCamera, widthPoints: Double(size.width), heightPoints: Double(size.height))
        let worldWidth = MKMapRect.world.width
        let width = worldWidth * region.longitudeDelta / 360
        let middle = MKMapPoint(AppleMapsBridge.coordinate(region.center))
        var x = middle.x - width / 2
        // A rect across the antimeridian runs past the world's east edge, as MapKit expects.
        if x < 0 { x += worldWidth }
        let rect = MKMapRect(x: x, y: middle.y - width / 200, width: width, height: width / 100)
        mapView.setVisibleMapRect(rect, animated: false)
        refresh(mapView)
    }

    func dismantle(_ mapView: MKMapView) {
        readyFallback?.cancel()
        readyFallback = nil
        sampler?.stop()
        sampler = nil
        mapView.delegate = nil
    }

    /// The view now: pins, arcs and house for its width, or back to our globe when it is too wide.
    private func refresh(_ mapView: MKMapView) {
        guard started, !handedBack else { return }
        let camera: GlobeCamera
        if hasRendered {
            let width = measuredWidth(mapView)
            if width > backWidthMeters {
                handBack(mapView, width: width)
                return
            }
            camera = GlobeCamera(center: AppleMapsBridge.geo(mapView.centerCoordinate), widthMeters: width).clamped
        } else {
            // Before MapKit has drawn anything its view may not be the start area yet.
            camera = startCamera
        }
        updatePins(mapView, camera: camera)
        updateArcs(mapView, width: camera.widthMeters)
        updateHouse(mapView, width: camera.widthMeters)
    }

    /// The great-circle distance between the points at the view's left and right edge, half way
    /// down (`GlobeCamera.widthMeters`); infinite when an edge is beyond the Earth (zoomed out to
    /// the globe), not a number for a view without a size.
    private func measuredWidth(_ mapView: MKMapView) -> Double {
        let bounds = mapView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return .nan }
        let west = mapView.convert(CGPoint(x: bounds.minX, y: bounds.midY), toCoordinateFrom: mapView)
        let east = mapView.convert(CGPoint(x: bounds.maxX, y: bounds.midY), toCoordinateFrom: mapView)
        guard CLLocationCoordinate2DIsValid(west), CLLocationCoordinate2DIsValid(east) else { return .infinity }
        return GeoMath.distance(AppleMapsBridge.geo(west), AppleMapsBridge.geo(east))
    }

    private func handBack(_ mapView: MKMapView, width: Double) {
        guard !handedBack else { return }
        handedBack = true
        var widthMeters = width
        if !widthMeters.isFinite {
            let region = mapView.region
            widthMeters = MapKitCamera.widthMeters(centerLatitude: region.center.latitude, longitudeDelta: region.span.longitudeDelta) ?? backWidthMeters
        }
        let camera = GlobeCamera(center: AppleMapsBridge.geo(mapView.centerCoordinate), widthMeters: max(widthMeters, backWidthMeters)).clamped
        onBackToGlobe(camera)
    }

    private func becomeReady() {
        readyFallback?.cancel()
        readyFallback = nil
        guard !calledReady else { return }
        calledReady = true
        onReady()
    }

    private func readyWithoutFullMap() {
        readyFallback = nil
        guard !calledReady else { return }
        calledReady = true
        metrics.note(.handoverMap, "Übergabe", "nach 5 s ohne fertiges Kartenbild")
        // From now on the map's own view counts, drawn or not: zooming out goes back to the globe.
        if let mapView, started {
            hasRendered = true
            refresh(mapView)
        }
        onReady()
    }

    // MARK: Pins, arcs, house

    private func updatePins(_ mapView: MKMapView, camera: GlobeCamera) {
        let bounds = mapView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let viewport = camera.viewport(widthPoints: Double(bounds.width), heightPoints: Double(bounds.height))
        var wanted: [String: AlbumistMap.MapPin] = [:]
        for group in MapPins.onGlobe(scene.pins, in: viewport) {
            wanted[group.id] = group.pin
        }
        var stale: [AppleMapsPinAnnotation] = []
        for (id, annotation) in pins where wanted[id] != annotation.pin {
            stale.append(annotation)
            pins[id] = nil
        }
        mapView.removeAnnotations(stale)
        var added: [AppleMapsPinAnnotation] = []
        for (id, pin) in wanted where pins[id] == nil {
            let annotation = AppleMapsPinAnnotation(pin: pin)
            pins[id] = annotation
            added.append(annotation)
        }
        mapView.addAnnotations(added)
    }

    private func updateArcs(_ mapView: MKMapView, width: Double) {
        let shows = MapArcs.areShown(atWidth: width)
        guard shows != arcsShown else { return }
        arcsShown = shows
        if shows {
            mapView.addOverlays(arcLines, level: .aboveRoads)
        } else {
            mapView.removeOverlays(arcLines)
        }
    }

    private func updateHouse(_ mapView: MKMapView, width: Double) {
        let shows = MapHome.showsHouse(atWidth: width)
        if shows, house == nil, let home = scene.home {
            let annotation = AppleMapsHouseAnnotation(coordinate: AppleMapsBridge.coordinate(home.coordinate))
            house = annotation
            mapView.addAnnotation(annotation)
        } else if !shows, let annotation = house {
            mapView.removeAnnotation(annotation)
            house = nil
        }
    }
}

extension AppleHandoverCoordinator: @preconcurrency MKMapViewDelegate {
    func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
        if started { renderingSinceStart = true }
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        guard started, renderingSinceStart else { return }
        if !hasRendered {
            hasRendered = true
            refresh(mapView)
        }
        guard fullyRendered, !measuredHandover else { return }
        measuredHandover = true
        metrics.event(.handover, .handoverMap, seconds: max(0, CACurrentMediaTime() - createdAt))
        becomeReady()
    }

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
        metrics.event(.tileFailure, .handoverMap, seconds: 0)
    }

    /// While the user pinches: back to our globe as soon as the view is too wide.
    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        guard started, hasRendered, !handedBack else { return }
        let width = measuredWidth(mapView)
        if width > backWidthMeters { handBack(mapView, width: width) }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        refresh(mapView)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKGradientPolylineRenderer(polyline: line)
        renderer.setColors([AppleMapsStyle.arcStartUIColor, AppleMapsStyle.arcEndUIColor], locations: [0, 1])
        renderer.lineWidth = AppleMapsStyle.arcWidth(weight: arcWeights[ObjectIdentifier(line)] ?? 1)
        renderer.lineCap = .round
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if let pin = annotation as? AppleMapsPinAnnotation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: AppleMapsPinAnnotationView.reuseName, for: pin)
            (view as? AppleMapsPinAnnotationView)?.show(pin.pin)
            return view
        }
        if annotation is AppleMapsHouseAnnotation {
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.houseReuseName, for: annotation)
            view.image = AppleMapsArt.house()
            view.displayPriority = .required
            view.isAccessibilityElement = true
            view.accessibilityLabel = AppleMapsText.house
            return view
        }
        return nil
    }
}
