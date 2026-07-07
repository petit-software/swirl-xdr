//
//  SwirlRenderer.swift
//  SwirlSaver
//
//  Single-pass Metal renderer for the unified effect: the neon Swirl scene seen
//  through the Liquid Glass lens (SwirlCore.metal / combined_fragment). Draws one
//  full-screen triangle and feeds it two uniform buffers — the swirl scene (0)
//  and the glass parameters (1). User-tunable Speed / Detail drive both layers.
//

import MetalKit
import CoreGraphics

/// Must match `SwirlUniforms` in SwirlCore.metal exactly (field order + types).
struct SwirlUniforms {
    var resX: Float = 0; var resY: Float = 0
    var time: Float = 0
    var speed: Float = 1.0
    var density: Float = 1.4
    var warp: Float = 3.5
    var chroma: Float = 0.009
    var hueShift: Float = 0.0
    var brightness: Float = 1.75
    var saturation: Float = 1.0
    var lineDensity: Float = 5.0
    var paletteScale: Float = 2.2
}

/// Must match `LiquidUniforms` in SwirlCore.metal exactly. SIMD types give the
/// same 16-byte alignment as the Metal struct.
struct LiquidUniforms {
    var size = SIMD2<Float>(0, 0)
    var time: Float = 0
    var _pad0: Float = 0
    var color1 = SIMD4<Float>(0.98, 0.98, 1.00, 1)   // light stripe  #FAFAFF
    var color2 = SIMD4<Float>(0.10, 0.10, 0.10, 1)   // dark stripe   #1A1A1A
    var bgColor = SIMD4<Float>(0.976, 0.976, 0.976, 1) // background   #F9F9F9
    var patternScale: Float = 1.85
    var waveSize: Float = 1.80
    var refraction: Float = 0.035
    var edge: Float = 0.021
    var patternBlur: Float = 0.0025
    var liquid: Float = 0.2425
    var grainIntensity: Float = 0.04   // subtle film grain
    var grainSpeed: Float = 2.0
    var grainMean: Float = 0.0
    var grainVariance: Float = 0.5
    var rectWidth: Float = 1.08
    var rectHeight: Float = 1.08
    var cornerRadius: Float = 0.2975
    var edgeSoftness: Float = 0.10
    var speed: Float = 0.24
    var direction: Float = 0.0
}

final class SwirlRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState        // for the on-screen MTKView
    private let snapshotPipeline: MTLRenderPipelineState? // rgba8Unorm for offscreen capture

    private let startDate = Date()

    // Live, user-controllable settings (all drivable from the companion app).
    var speed: Float = 1.2       // swirl flow + glass ripple rate
    var density: Float = 1.4     // "Detail" — swirl ribbon size + count
    var saturation: Float = 0.0  // 0 = monochrome, 1 = full neon
    var brightness: Float = 1.75 // overall gain
    var chroma: Float = 0.009    // chromatic-aberration edge width
    var glassBend: Float = 0.035 // glass refraction (lu.refraction)
    var ripple: Float = 0.2425   // glass wave amount (lu.liquid)
    var waveSize: Float = 1.80   // glass wave scale
    var grain: Float = 0.04      // film grain
    var hueShift: Float = 0.0

    // Cap the render resolution; the effect is soft so downscaling is invisible
    // but the pixel-count saving is large on Retina / 4K–5K displays.
    private let maxDrawableDimension: CGFloat = 1920

    init?(metalView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true

        // Load the compiled shaders from THIS saver bundle, never the host's
        // default library (the legacyScreenSaver host has no metallib of ours).
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: SwirlRenderer.self)),
              let vfn = library.makeFunction(name: "swirl_vertex"),
              let ffn = library.makeFunction(name: "combined_fragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pipeline

        // A parallel pipeline targeting an rgba8Unorm offscreen texture, for
        // high-res snapshots.
        let sdesc = MTLRenderPipelineDescriptor()
        sdesc.vertexFunction = vfn
        sdesc.fragmentFunction = ffn
        sdesc.colorAttachments[0].pixelFormat = .rgba8Unorm
        self.snapshotPipeline = try? device.makeRenderPipelineState(descriptor: sdesc)

        super.init()
        metalView.delegate = self
    }

    /// Builds both uniform buffers for a given target size + time. Shared by the
    /// live draw and the offscreen snapshot so they render identically.
    private func makeUniforms(width: Float, height: Float, time: Float) -> (SwirlUniforms, LiquidUniforms) {
        var su = SwirlUniforms()
        su.resX = width; su.resY = height; su.time = time
        su.speed = speed; su.density = density; su.saturation = saturation
        su.brightness = brightness; su.chroma = chroma; su.hueShift = hueShift
        su.lineDensity = max(1.0, density * 3.57)

        var lu = LiquidUniforms()
        lu.size = SIMD2<Float>(width, height); lu.time = time
        lu.speed = 0.05 + 0.16 * speed
        lu.refraction = glassBend; lu.liquid = ripple; lu.waveSize = waveSize; lu.grainIntensity = grain
        return (su, lu)
    }

    /// Render the current frame to an offscreen texture at an arbitrary size and
    /// return it as a CGImage (used for high-res screenshots).
    func snapshot(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let snapshotPipeline else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        var (su, lu) = makeUniforms(width: Float(width), height: Float(height),
                                    time: Float(Date().timeIntervalSince(startDate)))
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(snapshotPipeline)
        enc.setFragmentBytes(&su, length: MemoryLayout<SwirlUniforms>.stride, index: 0)
        enc.setFragmentBytes(&lu, length: MemoryLayout<LiquidUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()

        let bpr = width * 4
        var raw = [UInt8](repeating: 0, count: bpr * height)
        tex.getBytes(&raw, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Cap resolution (view sets autoResizeDrawable = false so this sticks).
        if view.bounds.width > 0, view.bounds.height > 0 {
            let scale = view.window?.backingScaleFactor ?? 2.0
            var w = view.bounds.width * scale, h = view.bounds.height * scale
            let m = max(w, h)
            if m > maxDrawableDimension { let k = maxDrawableDimension / m; w *= k; h *= k }
            let target = CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
            if abs(view.drawableSize.width - target.width) > 0.5 ||
               abs(view.drawableSize.height - target.height) > 0.5 {
                view.drawableSize = target
            }
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let size = view.drawableSize
        let now = Float(Date().timeIntervalSince(startDate))
        var (su, lu) = makeUniforms(width: Float(size.width), height: Float(size.height), time: now)

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&su, length: MemoryLayout<SwirlUniforms>.stride, index: 0)
        enc.setFragmentBytes(&lu, length: MemoryLayout<LiquidUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}
