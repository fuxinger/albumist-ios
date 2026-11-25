import Metal
import MetalKit
import QuartzCore
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

// Plan A of the map prototype (wave 0): our own Metal globe, shown beside Apple's globe (Plan B)
// so that the owner picks one on the iPhone. If Plan A wins, this renderer is split into its
// loading, its frame encoding and its gestures before release (docs/IMPROVEMENTS.md); if Plan B
// wins, the file goes. Until that choice its length is accepted (here, at the class and at
// `encode`):
// swiftlint:disable file_length

/// Draws our own globe with Metal and turns it with the fingers: the coordinator of
/// `OwnGlobeView`'s MTKView, its delegate and its gestures' target (concept §7, §9).
///
/// - Loading, off the main thread: the shaders compiled from source (`GlobeShaders`), the Earth
///   image as a mipmapped sRGB texture, the sphere, the stars, the arcs' ribbons and the visited
///   countries' mask. The globe fades in once the shaders, the image and the sphere are there;
///   the tint fades in when its mask is ready, the arcs grow in when theirs is.
/// - Each frame: the camera moves on (`GlobeMotion.advance`), the pins are placed for it (the
///   overlay, in step with the frame: the drawable is presented with Core Animation's
///   transaction), then one render pass draws stars, Earth, halo and arcs into 4× multisampled
///   memoryless targets resolved into the drawable. At most three frames are in flight.
/// - It draws only while something moves (a finger, coasting, a flight, the spin, a fade);
///   otherwise the view pauses (`isPaused`, `enableSetNeedsDisplay`) and the metrics hear so.
/// - Below the handover width it draws the frame of the handover, calls `onHandover` once and
///   stops until the controller's `jump(to:)`.
///
/// Measured (`PrototypeMetrics`, counts and times only): each frame when the GPU finished it
/// (close to when it reaches the screen), the GPU time of each frame, the first frame with the
/// Earth (from the view's creation), the way back from Apple's map, shader compile, texture load
/// and mask build, and notes on the texture, the arcs and the drawable.
@MainActor
final class GlobeRenderer: NSObject { // swiftlint:disable:this type_body_length
    /// The background of space (sRGB), also shown before the first frame.
    static let spaceColor = Color(red: 0.035, green: 0.045, blue: 0.075)
    static let spaceUIColor = UIColor(red: 0.035, green: 0.045, blue: 0.075, alpha: 1)
    /// The same colour in linear values, for the sRGB drawable.
    static let spaceClearColor = MTLClearColor(red: 0.0027, green: 0.0035, blue: 0.0066, alpha: 1)
    /// The globe fades in over this long when it first appears.
    static let appearSeconds = 0.5
    /// The tint and the arcs fade in or out over this long when switched or ready.
    static let fadeSeconds = 0.35
    /// The arcs' growth (`GlobeShaders`: 1.4 s each, staggered over 0.9 s).
    static let growSeconds = 2.4
    /// Arc sizes in points: the core's half width, the glow's radius, the ribbon's half width.
    static let arcCorePoints = 0.7
    static let arcGlowPoints = 2.0
    static let arcRibbonPoints = 6.5

    private(set) var controller: GlobeController
    private let metrics: PrototypeMetrics
    private let overlay: GlobeOverlayModel
    private var onHandover: (GlobeCamera) -> Void = { _ in }
    private var scene: GlobeScene?
    private var outlineCount = -1

    private let device: (any MTLDevice)?
    private let queue: (any MTLCommandQueue)?
    private let sampleCount: Int
    private weak var view: GlobeMetalView?
    private let createdAt = CACurrentMediaTime()
    private var stopped = false

    // Resources, nil until they are made.
    private var pipelines: GlobePipelines?
    private var earth: (any MTLTexture)?
    private var mask: (any MTLTexture)?
    private var emptyMask: (any MTLTexture)?
    private var sphere: GlobeIndexedMesh?
    private var stars: (buffer: any MTLBuffer, count: Int)?
    private var arcs: GlobeIndexedMesh?
    private var uniforms: (any MTLBuffer)?
    private var sampler: (any MTLSamplerState)?
    private var targets: GlobeRenderTargets?
    private var arcGeneration = 0
    private var maskGeneration = 0

    // Frames.
    private let gate = GlobeFrameGate(count: GlobeGPU.framesInFlight)
    private var frameSlot = 0
    private var lastDrawTime: Double?
    /// Frames committed whose presentation has not been reported yet.
    private var framesInFlight = 0
    /// Frames were committed since the metrics last heard of a pause.
    private var runActive = false
    /// The view stopped drawing after a run and the metrics have not heard so yet (they hear it
    /// once the run's last frame is on screen, so no frame of it counts into the next run).
    private var pauseOwed = false
    private var firstFramePending = true
    /// The handover went out; nothing draws until the controller's jump.
    private var isHandedOver = false

    // Animations.
    private var appear = 0.0
    private var tintLevel = 0.0
    private var arcLevel = 0.0
    private var growTime = 0.0

    // Gestures.
    private var isPinching = false

    init(controller: GlobeController, metrics: PrototypeMetrics, overlay: GlobeOverlayModel) {
        self.controller = controller
        self.metrics = metrics
        self.overlay = overlay
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        sampleCount = device?.supportsTextureSampleCount(4) == true ? 4 : 1
        super.init()
        controller.renderer = self
    }

    // MARK: View

    func makeView() -> GlobeMetalView {
        let view = GlobeMetalView(frame: .zero, device: device)
        view.renderer = self
        view.delegate = self
        view.colorPixelFormat = GlobeGPU.colorFormat
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        // The pins above move in the same Core Animation transaction as the Earth below.
        view.presentsWithTransaction = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isOpaque = true
        view.backgroundColor = Self.spaceUIColor
        view.isMultipleTouchEnabled = true
        // VoiceOver: the globe is one element that takes the fingers directly (turn, zoom); the
        // pins above it are read one by one.
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Unser Globus"
        view.accessibilityTraits = .allowsDirectInteraction
        installGestures(on: view)
        self.view = view
        startLoading()
        return view
    }

    /// The page's scene, outlines and handover, at every SwiftUI update: what changed is made again.
    func update(scene: GlobeScene, outlines: [AtlasShape], controller: GlobeController, onHandover: @escaping (GlobeCamera) -> Void) {
        self.onHandover = onHandover
        if controller !== self.controller {
            if self.controller.renderer === self { self.controller.renderer = nil }
            self.controller = controller
            controller.renderer = self
            requestFrame()
        }
        let previous = self.scene
        guard previous != scene || outlines.count != outlineCount else { return }
        self.scene = scene
        if previous?.arcs != scene.arcs { rebuildArcs(scene.arcs) }
        if previous?.visitedCountryCodes != scene.visitedCountryCodes || outlines.count != outlineCount {
            outlineCount = outlines.count
            rebuildMask(shapes: outlines, visited: scene.visitedCountryCodes)
        }
        requestFrame()
    }

    /// The view went away: no more frames, and the metrics hear that this source stopped.
    func stop() {
        stopped = true
        if let view {
            view.isPaused = true
            view.delegate = nil
        }
        if runActive || pauseOwed { reportPause() }
        overlay.pins = []
        if controller.renderer === self { controller.renderer = nil }
    }

    func viewMovedToWindow() {
        requestFrame()
    }

    // MARK: Controller

    func controllerChanged() {
        requestFrame()
    }

    /// The controller jumped: back from Apple's map if the globe had handed over.
    func controllerJumped() {
        isHandedOver = false
        requestFrame()
    }

    // MARK: Loading

    private func startLoading() {
        guard let device, queue != nil else {
            overlay.problem = "Unser Globus braucht Metal, das hier nicht verfügbar ist."
            metrics.note(.ownGlobe, "metal", "fehlt")
            return
        }
        uniforms = device.makeBuffer(length: GlobeGPU.uniformStride * GlobeGPU.framesInFlight, options: .storageModeShared)
        sampler = GlobeGPU.makeSampler(device: device)
        emptyMask = GlobeGPU.makeMask(device: device, levels: [CountryMask.Level(width: 1, height: 1, pixels: [0])])
        metrics.note(.ownGlobe, "msaa", "\(sampleCount)x")

        let box = GlobeDeviceBox(device: device)
        let samples = sampleCount
        let compileStart = CACurrentMediaTime()
        device.makeLibrary(source: GlobeShaders.source, options: nil) { @Sendable library, error in
            let seconds = CACurrentMediaTime() - compileStart
            let result: Result<GlobePipelines, GlobeLoadError>
            if let library {
                result = GlobeGPU.makePipelines(device: box.device, library: library, sampleCount: samples)
            } else {
                result = .failure(GlobeLoadError(message: error?.localizedDescription ?? "unbekannter Fehler"))
            }
            Task { @MainActor in
                self.pipelinesArrived(result, seconds: seconds)
            }
        }

        Task.detached(priority: .userInitiated) {
            let start = CACurrentMediaTime()
            let result = GlobeGPU.loadEarth(device: box.device)
            let seconds = CACurrentMediaTime() - start
            await self.earthArrived(result, seconds: seconds)
        }

        Task.detached(priority: .userInitiated) {
            let sphere = GlobeMesh.sphere()
            let stars = GlobeMesh.stars()
            await self.meshesArrived(sphere: sphere, starValues: stars)
        }
    }

    private func pipelinesArrived(_ result: Result<GlobePipelines, GlobeLoadError>, seconds: Double) {
        switch result {
        case .success(let made):
            pipelines = made
            metrics.event(.shaderCompile, .ownGlobe, seconds: seconds)
            requestFrame()
        case .failure(let error):
            overlay.problem = "Die Shader des Globus ließen sich nicht übersetzen: " + String(error.message.prefix(600))
            metrics.note(.ownGlobe, "shader", "Fehler")
        }
    }

    private func earthArrived(_ result: Result<GlobeTextureBox, GlobeLoadError>, seconds: Double) {
        switch result {
        case .success(let box):
            earth = box.texture
            metrics.event(.textureLoad, .ownGlobe, seconds: seconds)
            metrics.note(.ownGlobe, "texture", box.summary)
            requestFrame()
        case .failure(let error):
            overlay.problem = "Das Erdbild ließ sich nicht laden: " + error.message
            metrics.note(.ownGlobe, "texture", "Fehler")
        }
    }

    private func meshesArrived(sphere mesh: (vertices: [Float], indices: [UInt32]), starValues: [Float]) {
        guard let device else { return }
        sphere = GlobeGPU.makeMesh(device: device, vertices: mesh.vertices, indices: mesh.indices)
        if let buffer = GlobeGPU.makeBuffer(device: device, floats: starValues) {
            stars = (buffer, starValues.count / GlobeMesh.floatsPerStar)
        }
        requestFrame()
    }

    private func rebuildArcs(_ sceneArcs: [MapArc]) {
        arcGeneration += 1
        let generation = arcGeneration
        Task.detached(priority: .userInitiated) {
            let mesh = GlobeArcGeometry.ribbons(sceneArcs)
            await self.arcsArrived(mesh, generation: generation)
        }
    }

    private func arcsArrived(_ mesh: GlobeArcMesh, generation: Int) {
        guard generation == arcGeneration, let device else { return }
        arcs = GlobeGPU.makeMesh(device: device, vertices: mesh.vertices, indices: mesh.indices)
        growTime = UIAccessibility.isReduceMotionEnabled ? Self.growSeconds : 0
        metrics.note(.ownGlobe, "arcs", "\(mesh.arcCount) Bögen, \(mesh.vertexCount) Ecken")
        requestFrame()
    }

    private func rebuildMask(shapes: [AtlasShape], visited: Set<String>) {
        maskGeneration += 1
        let generation = maskGeneration
        guard !shapes.isEmpty, !visited.isEmpty else {
            mask = nil
            requestFrame()
            return
        }
        Task.detached(priority: .utility) {
            let start = CACurrentMediaTime()
            let built = CountryMask.build(shapes: shapes, visited: visited)
            let levels = built.mipmaps(levels: GlobeGPU.maskLevels)
            let seconds = CACurrentMediaTime() - start
            await self.maskArrived(levels, seconds: seconds, generation: generation)
        }
    }

    private func maskArrived(_ levels: [CountryMask.Level], seconds: Double, generation: Int) {
        guard generation == maskGeneration, let device else { return }
        mask = GlobeGPU.makeMask(device: device, levels: levels)
        metrics.event(.maskBuild, .ownGlobe, seconds: seconds)
        if let first = levels.first {
            metrics.note(.ownGlobe, "mask", "\(first.width)x\(first.height)")
        }
        requestFrame()
    }

    private var isReady: Bool {
        pipelines != nil && earth != nil && sphere != nil && stars != nil && uniforms != nil && sampler != nil && emptyMask != nil
    }

    // MARK: Drawing on demand

    /// Whether the next frame differs from this one without new input.
    private var needsFrames: Bool {
        let motion = controller.motion
        guard !stopped, !isHandedOver, !motion.isHandedOver || hasPendingHandover else { return false }
        if motion.isMoving || motion.isInteracting { return true }
        guard isReady else { return false }
        return appear < 1 || tintLevel != tintTarget || arcLevel != arcTarget || (arcs != nil && growTime < Self.growSeconds)
    }

    /// The motion handed over, and the renderer has not drawn that frame yet.
    private var hasPendingHandover: Bool { controller.motion.isHandedOver && !isHandedOver }

    private var tintTarget: Double { controller.showsTint && mask != nil ? 1 : 0 }

    private var arcTarget: Double {
        controller.showsArcs && arcs != nil && MapArcs.areShown(atWidth: controller.motion.camera.widthMeters) ? 1 : 0
    }

    /// Something changed: draw continuously while it moves, else draw this one frame.
    private func requestFrame() {
        guard !stopped, let view else { return }
        if needsFrames {
            startDrawing()
        } else if !isHandedOver {
            view.setNeedsDisplay()
        }
    }

    private func startDrawing() {
        guard let view, !stopped else { return }
        if pauseOwed { reportPause() }
        view.preferredFramesPerSecond = preferredFrameRate(for: view)
        if view.isPaused {
            lastDrawTime = nil
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        }
    }

    private func stopDrawing() {
        guard let view else { return }
        if !view.isPaused {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
        }
        lastDrawTime = nil
        guard runActive else { return }
        pauseOwed = true
        if framesInFlight == 0 { reportPause() }
    }

    private func reportPause() {
        pauseOwed = false
        runActive = false
        metrics.pause(.ownGlobe)
    }

    /// The screen's highest rate (120 on ProMotion iPhones), 60 in Low Power Mode.
    private func preferredFrameRate(for view: UIView) -> Int {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 60 }
        return view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
    }

    // MARK: Frame

    private func drawFrame(in view: MTKView) {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        let step = lastDrawTime.map { min(max(now - $0, 0), GlobeMotion.longestStep) } ?? 0
        lastDrawTime = now
        let size = view.bounds.size
        if size.width > 0, size.height > 0 {
            controller.motion.widthPoints = Double(size.width)
            controller.motion.heightPoints = Double(size.height)
        }
        controller.motion.advance(by: step)
        let handover = isHandedOver ? nil : controller.motion.takeHandover()
        let optics = controller.motion.optics
        if isReady {
            advanceAnimations(by: step)
            updatePins(optics)
            encode(in: view, optics: optics)
        }
        if let handover {
            isHandedOver = true
            stopDrawing()
            onHandover(handover)
        } else if !needsFrames {
            stopDrawing()
        }
    }

    private func advanceAnimations(by step: Double) {
        appear = Self.approach(appear, 1, by: step / Self.appearSeconds)
        // The first frame of the Earth shows it already a little.
        if appear == 0 { appear = 0.05 }
        tintLevel = Self.approach(tintLevel, tintTarget, by: step / Self.fadeSeconds)
        arcLevel = Self.approach(arcLevel, arcTarget, by: step / Self.fadeSeconds)
        if arcs != nil { growTime = min(growTime + step, Self.growSeconds) }
    }

    private static func approach(_ value: Double, _ target: Double, by amount: Double) -> Double {
        value < target ? min(value + amount, target) : max(value - amount, target)
    }

    /// The pins for this frame: the groups `MapPins.onGlobe` picks for the camera, placed where
    /// the Earth below shows their places, fading in with the globe.
    private func updatePins(_ optics: GlobeOptics) {
        guard controller.showsPins, let scene, !scene.pins.isEmpty else {
            if !overlay.pins.isEmpty { overlay.pins = [] }
            return
        }
        let viewport = optics.camera.viewport(widthPoints: optics.widthPoints, heightPoints: optics.heightPoints)
        var placed = optics.place(MapPins.onGlobe(scene.pins, in: viewport))
        if appear < 1 {
            placed = placed.map { GlobePlacedPin(group: $0.group, x: $0.x, y: $0.y, opacity: $0.opacity * appear) }
        }
        if placed != overlay.pins { overlay.pins = placed }
    }

    private func encode(in view: MTKView, optics: GlobeOptics) { // swiftlint:disable:this function_body_length
        guard let device, let queue, let pipelines, let earth, let sphere, let stars, let uniforms, let sampler,
              let tint = mask ?? emptyMask, let drawable = view.currentDrawable else { return }
        let texture = drawable.texture
        if targets?.width != texture.width || targets?.height != texture.height {
            targets = GlobeGPU.makeTargets(device: device, width: texture.width, height: texture.height, sampleCount: sampleCount)
            metrics.note(.ownGlobe, "drawable", "\(texture.width)x\(texture.height)")
        }
        guard let targets else { return }

        gate.wait()
        guard let commandBuffer = queue.makeCommandBuffer() else {
            gate.signal()
            return
        }
        let slot = frameSlot
        frameSlot = (frameSlot + 1) % GlobeGPU.framesInFlight
        let offset = slot * GlobeGPU.uniformStride
        let pixelsPerPoint = Double(texture.width) / max(Double(view.bounds.width), 1)
        let values = uniformValues(optics: optics, drawableWidth: Double(texture.width), drawableHeight: Double(texture.height),
                                   pixelsPerPoint: pixelsPerPoint)
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            uniforms.contents().advanced(by: offset).copyMemory(from: base, byteCount: bytes.count)
        }

        let pass = MTLRenderPassDescriptor()
        if let color = targets.color {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].resolveTexture = texture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = Self.spaceClearColor
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            gate.signal()
            return
        }
        encoder.label = "Globus"
        encoder.setVertexBuffer(uniforms, offset: offset, index: 1)
        encoder.setFragmentBuffer(uniforms, offset: offset, index: 0)

        encoder.setDepthStencilState(pipelines.noDepth)
        encoder.setRenderPipelineState(pipelines.stars)
        encoder.setVertexBuffer(stars.buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: stars.count)

        encoder.setDepthStencilState(pipelines.solid)
        encoder.setRenderPipelineState(pipelines.earth)
        encoder.setVertexBuffer(sphere.vertices, offset: 0, index: 0)
        encoder.setFragmentTexture(earth, index: 0)
        encoder.setFragmentTexture(tint, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: sphere.indexCount, indexType: .uint32,
                                      indexBuffer: sphere.indices, indexBufferOffset: 0)

        encoder.setDepthStencilState(pipelines.glowing)
        encoder.setRenderPipelineState(pipelines.halo)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        if let arcs, arcLevel > 0 {
            encoder.setRenderPipelineState(pipelines.arcs)
            encoder.setVertexBuffer(arcs.vertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: arcs.indexCount, indexType: .uint32,
                                          indexBuffer: arcs.indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()

        // The frame's time is when the GPU finished it, on the host clock of `CACurrentMediaTime()`:
        // Xcode 27's SDK offers Swift no presented handler on the drawable (CI 44871403392).
        let frameGate = gate
        let gpuMetrics = metrics
        commandBuffer.addCompletedHandler { @Sendable buffer in
            let seconds = buffer.gpuEndTime - buffer.gpuStartTime
            let finished = buffer.status == .completed ? buffer.gpuEndTime : 0
            frameGate.signal()
            Task { @MainActor in
                gpuMetrics.gpuTime(.ownGlobe, seconds: seconds)
                self.frameFinished(at: finished)
            }
        }
        framesInFlight += 1
        runActive = true
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
    }

    /// The 56 floats of the shaders' `GlobeUniforms`.
    private func uniformValues(optics: GlobeOptics, drawableWidth: Double, drawableHeight: Double, pixelsPerPoint: Double) -> [Float] {
        let eye = optics.eye, right = optics.right, up = optics.up
        // From the upper left, a little in front: lit gently, never dark.
        let light = (optics.back * 0.75 + up * 0.45 - right * 0.48).normalized
        var values: [Float] = []
        values.reserveCapacity(56)
        values += optics.viewProjectionMatrix.floats
        values += optics.skyMatrix.floats
        values += [Float(eye.x), Float(eye.y), Float(eye.z), Float(appear)]
        values += [Float(right.x), Float(right.y), Float(right.z), Float(optics.haloHalfSize)]
        values += [Float(up.x), Float(up.y), Float(up.z), Float(GlobeOptics.haloRadius)]
        values += [Float(light.x), Float(light.y), Float(light.z), Float(tintLevel)]
        values += [Float(drawableWidth), Float(drawableHeight), Float(pixelsPerPoint), Float(growTime)]
        values += [Float(Self.arcCorePoints * pixelsPerPoint), Float(Self.arcGlowPoints * pixelsPerPoint),
                   Float(Self.arcRibbonPoints * pixelsPerPoint), Float(arcLevel * appear)]
        return values
    }

    /// The GPU finished a frame at `time` (> 0), the moment it can reach the screen, or the frame
    /// failed (0).
    private func frameFinished(at time: Double) {
        framesInFlight = max(0, framesInFlight - 1)
        // After `stop()` the metrics have heard this source's pause: a frame still in flight
        // then would start a run that never ends.
        guard !stopped else { return }
        if time > 0 {
            metrics.frame(.ownGlobe, presentedAt: time)
            if firstFramePending {
                firstFramePending = false
                metrics.event(.firstFrame, .ownGlobe, seconds: time - createdAt)
            }
            if let start = controller.backToGlobeStart, time >= start {
                controller.backToGlobeStart = nil
                metrics.event(.backToGlobe, .ownGlobe, seconds: time - start)
            }
        }
        if pauseOwed, framesInFlight == 0, view?.isPaused ?? true {
            reportPause()
        }
    }

    // MARK: Gestures

    private func installGestures(on view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self
        for recognizer in [pan, pinch, doubleTap, twoFingerTap] as [UIGestureRecognizer] {
            view.addGestureRecognizer(recognizer)
        }
    }

    /// A finger came down: a flight or the coasting stops where it is.
    func touchDown() {
        guard !isHandedOver, controller.motion.isFlying || controller.motion.isCoasting else { return }
        controller.motion.halt()
        requestFrame()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let view, !isHandedOver else { return }
        let location = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            guard !isPinching else { break }
            // The drag holds the point where the finger came down; the first move catches up
            // the few points the recognizer waited for.
            let moved = recognizer.translation(in: view)
            controller.motion.beginDrag(atX: Double(location.x - moved.x), y: Double(location.y - moved.y))
            controller.motion.moveDrag(toX: Double(location.x), y: Double(location.y))
        case .changed:
            guard !isPinching else { break }
            controller.motion.moveDrag(toX: Double(location.x), y: Double(location.y))
        case .ended:
            let velocity = recognizer.velocity(in: view)
            controller.motion.endDrag(velocityX: Double(velocity.x), velocityY: Double(velocity.y))
        case .cancelled, .failed:
            controller.motion.endDrag(velocityX: 0, velocityY: 0)
        default:
            break
        }
        requestFrame()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let view, !isHandedOver else { return }
        let location = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            isPinching = true
            controller.motion.beginPinch(atX: Double(location.x), y: Double(location.y))
            controller.motion.movePinch(scale: Double(recognizer.scale), atX: Double(location.x), y: Double(location.y))
        case .changed:
            controller.motion.movePinch(scale: Double(recognizer.scale), atX: Double(location.x), y: Double(location.y))
        case .ended, .cancelled, .failed:
            isPinching = false
            controller.motion.endPinch()
        default:
            break
        }
        requestFrame()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view, !isHandedOver, recognizer.state == .ended else { return }
        let location = recognizer.location(in: view)
        controller.motion.doubleTap(atX: Double(location.x), y: Double(location.y))
        requestFrame()
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard !isHandedOver, recognizer.state == .ended else { return }
        controller.motion.zoomOut()
        requestFrame()
    }
}

extension GlobeRenderer: @preconcurrency MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestFrame()
    }

    func draw(in view: MTKView) {
        drawFrame(in: view)
    }
}

extension GlobeRenderer: @preconcurrency UIGestureRecognizerDelegate {
    /// Pan and pinch together (a pinch's fingers also move the globe), taps beside them.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Lets at most `count` frames be in flight: the main thread waits before preparing another
/// while the GPU still draws that many. Signalled from Metal's completion thread.
final class GlobeFrameGate: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    init(count: Int) {
        semaphore = DispatchSemaphore(value: count)
    }

    func wait() {
        semaphore.wait()
    }

    func signal() {
        semaphore.signal()
    }
}
