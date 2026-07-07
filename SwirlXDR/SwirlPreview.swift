//
//  SwirlPreview.swift
//  SwirlSaver
//
//  Live Xcode canvas preview. Wrapped in #if DEBUG so none of this ships in the
//  Release .saver.
//
//  Metal CAMetalLayer / MTKView content is unreliable in Xcode's preview canvas
//  (it renders in an out-of-process snapshotter). So instead of hosting a live
//  MTKView, we render each frame to an offscreen texture, read it back to a
//  CGImage, and show it as a SwiftUI Image driven by TimelineView(.animation).
//  Slower than on-screen Metal, but it actually appears in the canvas.
//
//  Open this file, show the canvas (Editor ▸ Canvas / ⌥⌘↩), press Resume.
//

#if DEBUG
import SwiftUI
import MetalKit

/// Renders the combined effect to a CGImage (same shaders as the saver).
@available(macOS 14.0, *)
final class SwirlImageRenderer {
    static let shared = SwirlImageRenderer()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var texW = 0, texH = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: SwirlRenderer.self)),
              let vfn = library.makeFunction(name: "swirl_vertex"),
              let ffn = library.makeFunction(name: "combined_fragment") else { return nil }
        self.device = device
        self.queue = queue
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .rgba8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = p
    }

    func image(width: Int, height: Int, time: Float, speed: Float, density: Float) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        if texture == nil || texW != width || texH != height {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                              width: width, height: height, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .shared
            texture = device.makeTexture(descriptor: td)
            texW = width; texH = height
        }
        guard let tex = texture else { return nil }

        var su = SwirlUniforms()
        su.resX = Float(width); su.resY = Float(height); su.time = time
        su.speed = speed; su.density = density; su.saturation = 0.0
        var lu = LiquidUniforms()
        lu.size = SIMD2<Float>(Float(width), Float(height)); lu.time = time
        lu.speed = 0.05 + 0.16 * speed

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(pipeline)
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
}

@available(macOS 14.0, *)
private struct SwirlPreviewHarness: View {
    @State private var speed: Float = 1.2
    @State private var density: Float = 1.4
    @State private var startDate = Date()

    private let renderer = SwirlImageRenderer.shared
    // Preview render resolution (kept modest since it runs on the main thread).
    private let renderW = 768, renderH = 432

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation) { context in
                let t = Float(context.date.timeIntervalSince(startDate))
                Group {
                    if let img = renderer?.image(width: renderW, height: renderH,
                                                 time: t, speed: speed, density: density) {
                        Image(decorative: img, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.black
                    }
                }
            }
            .frame(minWidth: 480, minHeight: 270)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                row("Speed", $speed, 0...3)
                row("Density", $density, 0.7...3)
            }
            .padding(12)
            .background(.black)
        }
        .background(.black)
    }

    private func row(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label).foregroundStyle(.white).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Float($0) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
        }
        .font(.caption)
    }
}

@available(macOS 14.0, *)
#Preview("Swirl — live") {
    SwirlPreviewHarness()
        .frame(width: 640, height: 460)
}
#endif
