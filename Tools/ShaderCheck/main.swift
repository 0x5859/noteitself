import Foundation
import Metal
import simd

struct Uniforms { var offset = SIMD2<Float>(0, 0); var viewport: SIMD2<Float>; var scale: Float = 1; var opacity: Float = 1; var grainScale: Float = 1; var flags: UInt32 = 0 }
struct CapsuleInstance { var p0: SIMD2<Float>; var p1: SIMD2<Float>; var r0: Float; var r1: Float; var color: UInt32; var key: UInt32 }

let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
let queue = device.makeCommandQueue()!
let W = 128, H = 64
print("device:", device.name)

func pipeline(fetch: Bool) -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: "capsule_vertex")
    d.fragmentFunction = library.makeFunction(name: fetch ? "capsule_fragment" : "capsule_fragment_plain")
    d.colorAttachments[0].pixelFormat = .bgra8Unorm
    if fetch {
        d.colorAttachments[1].pixelFormat = .rgba8Unorm
    } else {
        let a = d.colorAttachments[0]!
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    return try! device.makeRenderPipelineState(descriptor: d)
}

/// Renders the instances on white and returns the red channel of every pixel.
func render(_ instances: [CapsuleInstance], fetch: Bool) -> [UInt8] {
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
    let target = device.makeTexture(descriptor: td)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
    pass.colorAttachments[0].storeAction = .store
    if fetch {
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        md.usage = .renderTarget; md.storageMode = .memoryless
        pass.colorAttachments[1].texture = device.makeTexture(descriptor: md)!
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[1].storeAction = .dontCare
    }
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
    enc.setRenderPipelineState(pipeline(fetch: fetch))
    var u = Uniforms(viewport: SIMD2(Float(W), Float(H)))
    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    let buffer = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<CapsuleInstance>.stride)!
    enc.setVertexBuffer(buffer, offset: 0, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var raw = [UInt8](repeating: 0, count: W * H * 4)
    target.getBytes(&raw, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    return (0..<W * H).map { raw[$0 * 4 + 2] }
}

func stroke(_ pts: [(Float, Float, Float)], alpha: UInt32 = 255, key: UInt32) -> [CapsuleInstance] {
    zip(pts, pts.dropFirst()).map { a, b in
        CapsuleInstance(p0: SIMD2(a.0, a.1), p1: SIMD2(b.0, b.1), r0: a.2, r1: b.2, color: alpha << 24, key: key)
    }
}

// CPU reference of the shader's distance function, adapted from Inigo Quilez's
// "Uneven Capsule" (MIT License; see THIRD_PARTY_NOTICES.md).
func sd(_ p: SIMD2<Float>, _ pa: SIMD2<Float>, _ pb: SIMD2<Float>, _ ra: Float, _ rb: Float) -> Float {
    let ba = pb - pa
    let h = simd_dot(ba, ba), b = ra - rb
    if h <= b * b + 1e-6 { return min(simd_length(p - pa) - ra, simd_length(p - pb) - rb) }
    let q0 = p - pa
    var q = SIMD2(simd_dot(q0, SIMD2(ba.y, -ba.x)), simd_dot(q0, ba)) / h
    q.x = abs(q.x)
    let c = SIMD2((h - b * b).squareRoot(), b)
    let k = c.x * q.y - c.y * q.x, m = simd_dot(c, q), n = simd_dot(q, q)
    if k < 0 { return (h * n).squareRoot() - ra }
    if k > c.x { return (h * (n + 1 - 2 * q.y)).squareRoot() - rb }
    return m - ra
}

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
func spread(_ px: [UInt8], rows: ClosedRange<Int>, cols: Range<Int>) -> Int {
    rows.map { y in let v = cols.map { Int(px[y * W + $0]) }; return v.max()! - v.min()! }.max()!
}

// 1. A straight opaque hairline made of 10 segments, edge on a fractional pixel row.
let straight = stroke((0...10).map { (10 + Float($0) * 10, 20.37, 1.4) }, key: 5)
let plain = render(straight, fetch: false), exact = render(straight, fetch: true)
let beadsPlain = spread(plain, rows: 17...24, cols: 14..<106)
let beadsExact = spread(exact, rows: 17...24, cols: 14..<106)
print("fringe variation along the line: plain blend \(beadsPlain)/255, coverage mask \(beadsExact)/255")
check(beadsPlain > 20, "plain blending shows beads at joints (the artefact being fixed)")
check(beadsExact <= 1, "coverage mask: fringe is uniform along the stroke")
check(exact[20 * W + 60] <= 2, "opaque core is fully inked")

// 2. Translucent ink must not darken where its own segments overlap.
let half = render(stroke((0...10).map { (10 + Float($0) * 10, 30, 5) }, alpha: 128, key: 9), fetch: true)
check(spread(half, rows: 27...33, cols: 14..<106) <= 1, "translucent stroke: no build-up at joints")
check(abs(Int(half[30 * W + 60]) - 127) <= 2, "translucent stroke: 50% ink gives mid grey (\(half[30 * W + 60]))")

// 3. Two different translucent strokes do build up where they cross.
let cross = render(stroke([(20, 30, 5), (110, 30, 5)], alpha: 128, key: 1) + stroke([(64, 5, 5), (64, 60, 5)], alpha: 128, key: 2), fetch: true)
check(abs(Int(cross[30 * W + 64]) - 64) <= 2, "separate strokes multiply at the crossing (\(cross[30 * W + 64]))")
check(abs(Int(cross[30 * W + 30]) - 127) <= 2, "…and stay single elsewhere")

// 4. A wavy, self-overlapping, variable-width stroke equals the analytic union.
let wavy: [(Float, Float, Float)] = (0...60).map { i in
    let t = Float(i) / 60
    return (20 + 90 * t + 6 * sin(t * 40), 32 + 18 * sin(t * 9), 0.8 + 2.5 * abs(sin(t * 5)))
}
let wavyInstances = stroke(wavy, key: 77)
let gpu = render(wavyInstances, fetch: true)
var worst = 0
for y in 0..<H { for x in 0..<W {
    let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
    let d = wavyInstances.map { sd(p, $0.p0, $0.p1, $0.r0, $0.r1) }.min()!
    let expected = Int((255 * (1 - max(0, min(1, 0.5 - d)))).rounded())
    worst = max(worst, abs(expected - Int(gpu[y * W + x])))
} }
check(worst <= 3, "wavy stroke matches the exact union of its segments (max error \(worst)/255)")

exit(failures == 0 ? 0 : 1)
