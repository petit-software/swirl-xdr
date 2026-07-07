// Offline preview harness for SwirlCore.metal.
// Compiles the shared core at runtime, runs it as a compute kernel, and writes
// PNG stills so the look can be tuned without building the .saver bundle.
//
// Usage: swift preview.swift <core.metal> <outDir> [W H] [t0 t1 t2 ...]

import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { fputs("usage: preview <core.metal> <outDir> [W H] [times...]\n", stderr); exit(1) }
let corePath = args[1]
let outDir = args[2]
var width = 1280, height = 720
var idx = 3
if args.count >= 5, let w = Int(args[3]), let h = Int(args[4]) { width = w; height = h; idx = 5 }
var times: [Float] = []
while idx < args.count { if let t = Float(args[idx]) { times.append(t) }; idx += 1 }
if times.isEmpty { times = [0.0] }

let coreSrc = try String(contentsOfFile: corePath, encoding: .utf8)
let kernelSrc = coreSrc + """

kernel void previewKernel(texture2d<float, access::write> out [[texture(0)]],
                          constant SwirlUniforms& u [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 frag = float2(gid) + 0.5;
    float3 c = swirl_color(frag, u);
    out.write(float4(c, 1.0), gid);
}
"""

// Mirror of the Metal SwirlUniforms struct layout.
struct Uniforms {
    var resX: Float; var resY: Float
    var time: Float; var speed: Float; var density: Float; var warp: Float
    var chroma: Float; var hueShift: Float; var brightness: Float; var saturation: Float
    var lineDensity: Float; var paletteScale: Float
}

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let lib: MTLLibrary
do { lib = try device.makeLibrary(source: kernelSrc, options: nil) }
catch { fputs("shader compile error:\n\(error)\n", stderr); exit(2) }
let pipe = try device.makeComputePipelineState(function: lib.makeFunction(name: "previewKernel")!)

let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
td.usage = [.shaderWrite, .shaderRead]
td.storageMode = .shared
let tex = device.makeTexture(descriptor: td)!

func render(time: Float, to path: String) {
    var u = Uniforms(resX: Float(width), resY: Float(height),
                     time: time, speed: 1.0, density: 1.4, warp: 3.5,
                     chroma: 0.13, hueShift: 0.0, brightness: 2.0, saturation: 1.0,
                     lineDensity: 5.0, paletteScale: 2.2)
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipe)
    enc.setTexture(tex, index: 0)
    enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()

    let bpr = width * 4
    var raw = [UInt8](repeating: 0, count: bpr * height)
    tex.getBytes(&raw, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: bpr, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for t in times {
    let path = "\(outDir)/frame_\(String(format: "%.2f", t)).png"
    render(time: t, to: path)
    print("wrote \(path)")
}
