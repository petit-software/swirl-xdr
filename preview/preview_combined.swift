// Offline preview for the combined "swirl through liquid glass" effect.
// Usage: swift preview_combined.swift <core.metal> <outDir> [W H] [times...]

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let corePath = args[1]
let outDir = args[2]
var width = 1280, height = 720, idx = 3
if args.count >= 5, let w = Int(args[3]), let h = Int(args[4]) { width = w; height = h; idx = 5 }
var times: [Float] = []
while idx < args.count { if let t = Float(args[idx]) { times.append(t) }; idx += 1 }
if times.isEmpty { times = [0.0] }

let coreSrc = try String(contentsOfFile: corePath, encoding: .utf8)
let kernelSrc = coreSrc + """

kernel void combinedKernel(texture2d<float, access::write> out [[texture(0)]],
                           constant SwirlUniforms& su [[buffer(0)]],
                           constant LiquidUniforms& lu [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 frag = float2(gid) + 0.5;
    out.write(float4(combined_color(frag, su, lu), 1.0), gid);
}
"""

struct SwirlUniforms {
    var resX: Float = 0; var resY: Float = 0
    var time: Float = 0
    var speed: Float = 1.2
    var density: Float = 1.4
    var warp: Float = 3.5
    var chroma: Float = 0.13
    var hueShift: Float = 0.0
    var brightness: Float = 1.75
    var saturation: Float = 0.0
    var lineDensity: Float = 5.0
    var paletteScale: Float = 2.2
}
struct LiquidUniforms {
    var size = SIMD2<Float>(0, 0)
    var time: Float = 0
    var _pad0: Float = 0
    var color1 = SIMD4<Float>(0.98, 0.98, 1.00, 1)
    var color2 = SIMD4<Float>(0.10, 0.10, 0.10, 1)
    var bgColor = SIMD4<Float>(0.976, 0.976, 0.976, 1)
    var patternScale: Float = 1.85
    var waveSize: Float = 1.80
    var refraction: Float = 0.035
    var edge: Float = 0.021
    var patternBlur: Float = 0.0025
    var liquid: Float = 0.2425
    var grainIntensity: Float = 0.04
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

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let lib: MTLLibrary
do { lib = try device.makeLibrary(source: kernelSrc, options: nil) }
catch { fputs("compile error:\n\(error)\n", stderr); exit(2) }
let pipe = try device.makeComputePipelineState(function: lib.makeFunction(name: "combinedKernel")!)

let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
td.usage = [.shaderWrite, .shaderRead]; td.storageMode = .shared
let tex = device.makeTexture(descriptor: td)!

func render(time: Float, to path: String) {
    var su = SwirlUniforms(); su.resX = Float(width); su.resY = Float(height); su.time = time
    var lu = LiquidUniforms(); lu.size = SIMD2<Float>(Float(width), Float(height)); lu.time = time
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipe)
    enc.setTexture(tex, index: 0)
    enc.setBytes(&su, length: MemoryLayout<SwirlUniforms>.stride, index: 0)
    enc.setBytes(&lu, length: MemoryLayout<LiquidUniforms>.stride, index: 1)
    let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

    let bpr = width * 4
    var raw = [UInt8](repeating: 0, count: bpr * height)
    tex.getBytes(&raw, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: bpr, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for t in times {
    let path = "\(outDir)/combined_\(String(format: "%.2f", t)).png"
    render(time: t, to: path); print("wrote \(path)")
}
