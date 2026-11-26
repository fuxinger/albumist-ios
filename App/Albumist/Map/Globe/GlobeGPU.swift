import Foundation
import Metal
import MetalKit
import AlbumistMap

/// The Metal device, for work on other threads. Metal's devices may be used from any thread,
/// but not every SDK marks them Sendable, so they travel in this box.
struct GlobeDeviceBox: @unchecked Sendable {
    let device: any MTLDevice
}

/// The Earth's texture on its way from the loading thread to the renderer (see `GlobeDeviceBox`).
struct GlobeTextureBox: @unchecked Sendable {
    let texture: any MTLTexture

    /// "5400x2700, 78 MB": the size with its mipmaps, for `PrototypeMetrics.note`.
    var summary: String {
        let bytes = Double(texture.width * texture.height * 4) * 4 / 3
        return "\(texture.width)x\(texture.height), \(Int((bytes / 1_048_576).rounded())) MB"
    }
}

/// The compiled pipelines and depth states of our globe's four draws (`GlobeShaders`), made on
/// Metal's compiler thread (see `GlobeDeviceBox`).
struct GlobePipelines: @unchecked Sendable {
    let stars: any MTLRenderPipelineState
    let earth: any MTLRenderPipelineState
    let halo: any MTLRenderPipelineState
    let arcs: any MTLRenderPipelineState
    /// Stars: no depth at all.
    let noDepth: any MTLDepthStencilState
    /// The Earth: tests and writes depth.
    let solid: any MTLDepthStencilState
    /// Halo and arcs: hidden behind the Earth, but they write no depth, so they add up.
    let glowing: any MTLDepthStencilState
}

/// Why a part of our globe could not be made (shown on screen and noted, never a coordinate).
struct GlobeLoadError: Error {
    let message: String
}

/// The multisampled colour and depth the globe draws into before the colour is resolved into the
/// drawable. Memoryless: on Apple's GPUs they live in tile memory only and cost no RAM.
struct GlobeRenderTargets {
    let width: Int
    let height: Int
    /// Nil when the device draws without multisampling (straight into the drawable).
    let color: (any MTLTexture)?
    let depth: any MTLTexture
}

/// A mesh drawn with an index buffer.
struct GlobeIndexedMesh {
    let vertices: any MTLBuffer
    let indices: any MTLBuffer
    let indexCount: Int
}

/// The Metal objects of our own globe that do not depend on the frame: pipelines, textures,
/// buffers, render targets. Plain functions, free of any actor, so the heavy ones run off the
/// main thread.
enum GlobeGPU {
    static let colorFormat = MTLPixelFormat.bgra8Unorm_srgb
    static let depthFormat = MTLPixelFormat.depth32Float
    /// Frames the CPU may prepare while the GPU still draws earlier ones.
    static let framesInFlight = 3
    /// Bytes per frame's uniforms: the shaders' `GlobeUniforms` (224 bytes), rounded up to a
    /// buffer offset every Apple GPU accepts.
    static let uniformStride = 256
    /// The visited countries' mask: 2048 × 1024 has 12 mipmap levels down to 1 × 1.
    static let maskLevels = 12

    // MARK: Pipelines

    enum Blend {
        case opaque
        /// Light added to what is there (stars, halo).
        case add
        /// Light "screened" over what is there: `src + dst · (1 − src)`, so many arcs on one spot
        /// saturate softly instead of burning out (arcs).
        case screen
    }

    /// What every pipeline of one load shares: the device, the compiled shaders and the
    /// multisampling.
    private struct PipelineSource {
        let device: any MTLDevice
        let library: any MTLLibrary
        let sampleCount: Int
    }

    static func makePipelines(device: any MTLDevice, library: any MTLLibrary, sampleCount: Int) -> Result<GlobePipelines, GlobeLoadError> {
        let source = PipelineSource(device: device, library: library, sampleCount: sampleCount)
        do {
            let stars = try pipeline(source, vertex: "starVertex", fragment: "starFragment", blend: .add)
            let earth = try pipeline(source, vertex: "earthVertex", fragment: "earthFragment", blend: .opaque)
            let halo = try pipeline(source, vertex: "haloVertex", fragment: "haloFragment", blend: .add)
            let arcs = try pipeline(source, vertex: "arcVertex", fragment: "arcFragment", blend: .screen)
            guard let noDepth = depthState(device, compare: .always, write: false),
                  let solid = depthState(device, compare: .less, write: true),
                  let glowing = depthState(device, compare: .less, write: false) else {
                return .failure(GlobeLoadError(message: "Tiefenzustand fehlt"))
            }
            return .success(GlobePipelines(stars: stars, earth: earth, halo: halo, arcs: arcs, noDepth: noDepth, solid: solid, glowing: glowing))
        } catch let error as GlobeLoadError {
            return .failure(error)
        } catch {
            return .failure(GlobeLoadError(message: error.localizedDescription))
        }
    }

    private static func pipeline(_ source: PipelineSource, vertex: String, fragment: String,
                                 blend: Blend) throws -> any MTLRenderPipelineState {
        guard let vertexFunction = source.library.makeFunction(name: vertex),
              let fragmentFunction = source.library.makeFunction(name: fragment) else {
            throw GlobeLoadError(message: "Shader \(vertex)/\(fragment) fehlt")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = vertex
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = source.sampleCount
        descriptor.depthAttachmentPixelFormat = depthFormat
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        switch blend {
        case .opaque:
            descriptor.colorAttachments[0].isBlendingEnabled = false
        case .add, .screen:
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = blend == .add ? .one : .oneMinusSourceColor
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        }
        return try source.device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func depthState(_ device: any MTLDevice, compare: MTLCompareFunction, write: Bool) -> (any MTLDepthStencilState)? {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = compare
        descriptor.isDepthWriteEnabled = write
        return device.makeDepthStencilState(descriptor: descriptor)
    }

    // MARK: Textures

    /// The NASA Blue Marble image from the app bundle (`EarthBlueMarble-5400.jpg`, 5400 × 2700,
    /// equirectangular, north up): sRGB, so the shader reads linear colours; mipmapped, so the
    /// whole Earth does not shimmer; private, the GPU's alone. Never from the network.
    static func loadEarth(device: any MTLDevice) -> Result<GlobeTextureBox, GlobeLoadError> {
        guard let url = Bundle.main.url(forResource: "EarthBlueMarble-5400", withExtension: "jpg") else {
            return .failure(GlobeLoadError(message: "EarthBlueMarble-5400.jpg fehlt im App-Paket"))
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: NSNumber(value: true),
            .generateMipmaps: NSNumber(value: true),
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        do {
            let texture = try loader.newTexture(URL: url, options: options)
            return .success(GlobeTextureBox(texture: texture))
        } catch {
            return .failure(GlobeLoadError(message: error.localizedDescription))
        }
    }

    /// The visited countries' mask as an 8-bit texture with all its mipmap levels
    /// (`CountryMask.mipmaps`); nil when there are no levels or the device refuses.
    static func makeMask(device: any MTLDevice, levels: [CountryMask.Level]) -> (any MTLTexture)? {
        guard let first = levels.first else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: first.width, height: first.height,
                                                                  mipmapped: levels.count > 1)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        // The full chain unless fewer levels came (each level of the mask halves like Metal's).
        descriptor.mipmapLevelCount = min(levels.count, descriptor.mipmapLevelCount)
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        for (index, level) in levels.prefix(texture.mipmapLevelCount).enumerated() where level.pixels.count == level.width * level.height {
            level.pixels.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.replace(region: MTLRegionMake2D(0, 0, level.width, level.height), mipmapLevel: index,
                                withBytes: base, bytesPerRow: level.width)
            }
        }
        return texture
    }

    /// The multisampled colour and the depth for a drawable of `width` × `height` pixels.
    static func makeTargets(device: any MTLDevice, width: Int, height: Int, sampleCount: Int) -> GlobeRenderTargets? {
        guard width > 0, height > 0 else { return nil }
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthFormat, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .memoryless
        if sampleCount > 1 {
            depthDescriptor.textureType = .type2DMultisample
            depthDescriptor.sampleCount = sampleCount
        }
        guard let depth = device.makeTexture(descriptor: depthDescriptor) else { return nil }
        guard sampleCount > 1 else { return GlobeRenderTargets(width: width, height: height, color: nil, depth: depth) }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = .renderTarget
        colorDescriptor.storageMode = .memoryless
        colorDescriptor.textureType = .type2DMultisample
        colorDescriptor.sampleCount = sampleCount
        guard let color = device.makeTexture(descriptor: colorDescriptor) else { return nil }
        return GlobeRenderTargets(width: width, height: height, color: color, depth: depth)
    }

    // MARK: Buffers

    static func makeBuffer(device: any MTLDevice, floats: [Float]) -> (any MTLBuffer)? {
        guard !floats.isEmpty else { return nil }
        return device.makeBuffer(bytes: floats, length: floats.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    static func makeMesh(device: any MTLDevice, vertices: [Float], indices: [UInt32]) -> GlobeIndexedMesh? {
        guard !indices.isEmpty, let vertexBuffer = makeBuffer(device: device, floats: vertices),
              let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride,
                                                  options: .storageModeShared) else { return nil }
        return GlobeIndexedMesh(vertices: vertexBuffer, indices: indexBuffer, indexCount: indices.count)
    }

    /// The image sampler: trilinear with anisotropy, so the Earth stays sharp towards its edge;
    /// round the world in u (the image's left and right edges meet), clamped at the poles.
    static func makeSampler(device: any MTLDevice) -> (any MTLSamplerState)? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 8
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }
}
