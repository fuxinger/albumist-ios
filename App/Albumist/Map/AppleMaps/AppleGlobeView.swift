import MapKit
import SwiftUI
import AlbumistCore
import AlbumistMap

/// Plan B: Apple's satellite globe (SwiftUI `Map`, hybrid imagery with realistic elevation, so with
/// Apple's names) with the scene's arcs as flat geodesic lines and its pins as annotations
/// (concept §7, prototype tab "Apples Globus").
///
/// - Starts at `camera`, converted to MapKit's camera distance (`MapKitCamera.distance(forWidth:factor:)`)
///   and follows it when the page passes another one.
/// - The pins are picked and grouped for the width on screen (`MapPins.onGlobe`, at most 60) and
///   picked again whenever the camera comes to rest.
/// - The ratio of MapKit's camera distance to the view's width is measured from what MapKit reports
///   (the coordinates at the view's left and right edge) and noted (`metrics.note`), so the
///   conversion uses Apple's real field of view from then on.
/// - `isAutoRotating`: the 60-second test spin, about 10° per second (`MapKitCamera.spin`).
/// - No user location, no location permission: the map shows no position of the iPhone.
struct AppleGlobeView: View {
    let scene: GlobeScene
    let camera: GlobeCamera
    let isAutoRotating: Bool
    let metrics: PrototypeMetrics

    @State private var position: MapCameraPosition
    /// The view as MapKit last reported it, in the prototype's terms.
    @State private var shown: GlobeCamera
    /// MapKit's camera as last reported, for the spin to keep its latitude and distance.
    @State private var lastMapCamera: MapCamera?
    @State private var groups: [MapPinGroup] = []
    @State private var size: CGSize = .zero
    @State private var factor = MapKitCamera.assumedDistanceFactor
    @State private var sampler: DisplayLinkSampler?

    init(scene: GlobeScene, camera: GlobeCamera, isAutoRotating: Bool, metrics: PrototypeMetrics) {
        self.scene = scene
        self.camera = camera
        self.isAutoRotating = isAutoRotating
        self.metrics = metrics
        let start = camera.clamped
        _position = State(initialValue: .camera(Self.mapCamera(for: start, factor: MapKitCamera.assumedDistanceFactor)))
        _shown = State(initialValue: start)
    }

    var body: some View {
        GeometryReader { proxy in
            MapReader { reader in
                AppleGlobeMap(position: $position, arcs: arcs, groups: groups, house: house) { context in
                    cameraChanged(context, reader: reader, size: proxy.size)
                }
            }
            .onAppear { appeared(size: proxy.size) }
            .onChange(of: proxy.size) { _, newSize in
                size = newSize
                repick()
            }
        }
        .ignoresSafeArea()
        .onDisappear { sampler?.stop() }
        .onChange(of: camera) { _, newCamera in move(to: newCamera) }
        .task(id: isAutoRotating) {
            if isAutoRotating { await spin() }
        }
    }

    /// The arcs where `MapArcs.areShown(atWidth:)` allows them (from 300 km up).
    private var arcs: [MapArc] {
        MapArcs.areShown(atWidth: shown.widthMeters) ? scene.arcs : []
    }

    /// The rounded home, where `MapHome.showsHouse(atWidth:)` allows the house (never on the world view).
    private var house: CLLocationCoordinate2D? {
        guard let home = scene.home, MapHome.showsHouse(atWidth: shown.widthMeters) else { return nil }
        return AppleMapsBridge.coordinate(home.coordinate)
    }

    private func appeared(size newSize: CGSize) {
        size = newSize
        repick()
        if sampler == nil { sampler = DisplayLinkSampler(source: .appleGlobe, metrics: metrics) }
        sampler?.start()
        metrics.note(.appleGlobe, "Abstandsfaktor", String(format: "%.2f (angenommen)", factor))
    }

    /// MapKit's camera came to rest: the prototype's camera from it, the distance factor measured
    /// where the view is small enough to tell, and the pins picked for it.
    private func cameraChanged(_ context: MapCameraUpdateContext, reader: MapProxy, size viewSize: CGSize) {
        let mapCamera = context.camera
        lastMapCamera = mapCamera
        var width = MapKitCamera.widthMeters(forDistance: mapCamera.distance, factor: factor)
        if let measured = measuredWidth(reader: reader, size: viewSize), mapCamera.pitch < 1 {
            if let found = MapKitCamera.distanceFactor(distance: mapCamera.distance, widthMeters: measured) {
                if abs(found - factor) > 0.01 * factor {
                    factor = found
                    metrics.note(.appleGlobe, "Abstandsfaktor", String(format: "%.2f (gemessen)", found))
                }
                width = measured
            }
        }
        shown = GlobeCamera(center: AppleMapsBridge.geo(mapCamera.centerCoordinate), widthMeters: width).clamped
        repick()
    }

    /// The great-circle distance between the points at the view's left and right edge, half way
    /// down: `GlobeCamera.widthMeters` as MapKit shows it. `nil` when an edge is beyond the Earth.
    private func measuredWidth(reader: MapProxy, size viewSize: CGSize) -> Double? {
        guard viewSize.width > 0, viewSize.height > 0,
              let west = reader.convert(CGPoint(x: 0, y: viewSize.height / 2), from: .local),
              let east = reader.convert(CGPoint(x: viewSize.width, y: viewSize.height / 2), from: .local) else { return nil }
        return GeoMath.distance(AppleMapsBridge.geo(west), AppleMapsBridge.geo(east))
    }

    private func repick() {
        guard size.width > 0, size.height > 0 else { return }
        let viewport = shown.viewport(widthPoints: Double(size.width), heightPoints: Double(size.height))
        let picked = MapPins.onGlobe(scene.pins, in: viewport)
        if picked != groups { groups = picked }
    }

    private func move(to newCamera: GlobeCamera) {
        let target = newCamera.clamped
        shown = target
        position = .camera(Self.mapCamera(for: target, factor: factor))
        repick()
    }

    /// The test spin: linear animated steps round the north axis, jumping across the antimeridian
    /// between two steps (`MapKitCamera.spin`); ends after 60 s or when `isAutoRotating` goes off.
    private func spin() async {
        let start = lastMapCamera ?? Self.mapCamera(for: shown, factor: factor)
        let latitude = start.centerCoordinate.latitude
        let distance = start.distance
        for step in MapKitCamera.spin(fromLongitude: start.centerCoordinate.longitude) {
            if Task.isCancelled { return }
            let target = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: step.longitude),
                                   distance: distance, heading: 0, pitch: 0)
            if step.seconds > 0 {
                withAnimation(.linear(duration: step.seconds)) { position = .camera(target) }
                try? await Task.sleep(for: .seconds(step.seconds))
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { position = .camera(target) }
            }
        }
    }

    /// MapKit's camera for `camera`: straight down on its centre, north up, from the distance
    /// that shows its width with `factor`.
    static func mapCamera(for camera: GlobeCamera, factor: Double) -> MapCamera {
        MapCamera(centerCoordinate: AppleMapsBridge.coordinate(camera.center),
                  distance: MapKitCamera.distance(forWidth: camera.widthMeters, factor: factor), heading: 0, pitch: 0)
    }
}

/// The `Map` itself, kept apart so the view's body stays small: hybrid imagery with realistic
/// elevation, the arcs as geodesic lines from warm white to gold, the pins and the house.
private struct AppleGlobeMap: View {
    @Binding var position: MapCameraPosition
    let arcs: [MapArc]
    let groups: [MapPinGroup]
    let house: CLLocationCoordinate2D?
    /// MapKit's camera came to rest.
    let onCameraChange: (MapCameraUpdateContext) -> Void

    var body: some View {
        Map(position: $position) {
            arcContent
            pinContent
            houseContent
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .onMapCameraChange(frequency: .onEnd) { context in
            onCameraChange(context)
        }
    }

    @MapContentBuilder private var arcContent: some MapContent {
        ForEach(arcs) { arc in
            MapPolyline(coordinates: [AppleMapsBridge.coordinate(arc.from), AppleMapsBridge.coordinate(arc.to)], contourStyle: .geodesic)
                .stroke(AppleMapsStyle.arcGradient, style: AppleMapsStyle.arcStroke(weight: arc.weight))
        }
    }

    @MapContentBuilder private var pinContent: some MapContent {
        ForEach(groups) { group in
            Annotation(coordinate: AppleMapsBridge.coordinate(group.pin.coordinate), anchor: .center) {
                AppleMapsPinBubble(pin: group.pin)
            } label: {
                EmptyView()
            }
        }
    }

    @MapContentBuilder private var houseContent: some MapContent {
        if let house {
            Annotation(coordinate: house, anchor: .center) {
                AppleMapsHousePlate()
            } label: {
                EmptyView()
            }
        }
    }
}
