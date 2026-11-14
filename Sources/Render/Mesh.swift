import CoreGraphics
import Foundation
import Metal
import simd

// GPU instance layouts. These must match the structs in Shaders.metal.

struct CapsuleInstance {
    var p0: SIMD2<Float>
    var p1: SIMD2<Float>
    var r0: Float
    var r1: Float
    var color: UInt32
    /// 24-bit id of the owning stroke (never 0); see `capsule_fragment`.
    var key: UInt32 = 1
}

struct StampInstance {
    var center: SIMD2<Float>
    var radius: Float
    var alpha: Float
    var color: UInt32
    var pad: UInt32 = 0
}

/// Instance storage that only ever grows in place. Replacing the contents
/// allocates a fresh buffer, so a frame the GPU is still drawing never sees
/// its data change underneath it.
final class InstanceBuffer<T> {
    private let device: MTLDevice
    private(set) var buffer: MTLBuffer?
    private(set) var count = 0
    private var capacity = 0

    init(device: MTLDevice) { self.device = device }

    private func allocate(_ capacity: Int) -> MTLBuffer? {
        device.makeBuffer(length: max(capacity, 1) * MemoryLayout<T>.stride, options: .storageModeShared)
    }

    func replace(with items: [T]) {
        count = 0
        capacity = 0
        buffer = nil
        guard !items.isEmpty else { return }
        let newCapacity = items.count + items.count / 2 + 64
        guard let fresh = allocate(newCapacity) else { return }
        items.withUnsafeBytes { fresh.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        buffer = fresh
        capacity = newCapacity
        count = items.count
    }

    func append(_ items: [T]) {
        guard !items.isEmpty else { return }
        let stride = MemoryLayout<T>.stride
        if count + items.count > capacity || buffer == nil {
            let newCapacity = max(256, (count + items.count) * 2)
            guard let fresh = allocate(newCapacity) else { return }
            if let old = buffer, count > 0 {
                fresh.contents().copyMemory(from: old.contents(), byteCount: count * stride)
            }
            buffer = fresh
            capacity = newCapacity
        }
        guard let buffer else { return }
        items.withUnsafeBytes {
            (buffer.contents() + count * stride).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        count += items.count
    }
}

/// Lays pencil dabs along a polyline at a spacing tied to the local radius.
/// It is a value type so the live stroke can copy it to preview the
/// not-yet-committed tail without disturbing the committed state.
struct StampWalker {
    private var last: StrokePoint?
    private var sinceLast: Float = 0
    private var index: UInt32 = 0

    private static func jitter(_ i: UInt32) -> Float {
        var h = i &* 0x9E37_79B1
        h ^= h >> 15
        h = h &* 0x85EB_CA77
        h ^= h >> 13
        return Float(h & 0xFFFF) / 65535
    }

    private mutating func stamp(_ p: StrokePoint, color: UInt32, into out: inout [StampInstance]) {
        // Each spot is covered by several overlapping dabs; solve for the
        // per-dab alpha that builds up to the requested opacity.
        let target = min(0.97, max(0, p.a))
        let perDab = 1 - powf(1 - target, 0.22)
        let variation = 0.8 + 0.4 * StampWalker.jitter(index)
        index &+= 1
        out.append(StampInstance(center: SIMD2(p.x, p.y), radius: p.r, alpha: perDab * variation, color: color))
    }

    mutating func feed(_ p: StrokePoint, color: UInt32, into out: inout [StampInstance]) {
        guard let a = last else {
            last = p
            stamp(p, color: color, into: &out)
            return
        }
        let dx = p.x - a.x, dy = p.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        last = p
        guard length > 1e-6 else { return }

        var travelled: Float = 0
        while true {
            let t = travelled / length
            let radius = a.r + (p.r - a.r) * t
            let spacing = max(0.08, radius * 0.28)
            let needed = spacing - sinceLast
            if travelled + needed > length {
                sinceLast += length - travelled
                break
            }
            travelled += max(needed, 0)
            sinceLast = 0
            let u = travelled / length
            stamp(
                StrokePoint(x: a.x + dx * u, y: a.y + dy * u, r: a.r + (p.r - a.r) * u, a: a.a + (p.a - a.a) * u),
                color: color, into: &out
            )
        }
    }
}

enum MeshBuilder {
    /// Appends one capsule per segment of `points[from...]`.
    static func appendCapsules(_ points: [StrokePoint], from start: Int = 1, color: UInt32, key: UInt32 = 1,
                               into out: inout [CapsuleInstance]) {
        if points.count == 1, start <= 1 {
            let p = points[0]
            out.append(CapsuleInstance(p0: SIMD2(p.x, p.y), p1: SIMD2(p.x, p.y), r0: p.r, r1: p.r, color: color, key: key))
            return
        }
        guard points.count > 1 else { return }
        for i in max(start, 1)..<points.count {
            let a = points[i - 1], b = points[i]
            out.append(CapsuleInstance(p0: SIMD2(a.x, a.y), p1: SIMD2(b.x, b.y), r0: a.r, r1: b.r, color: color, key: key))
        }
    }

    /// Stroke ids folded into the 24 bits the coverage mask can hold, avoiding 0.
    static func key(for id: UInt64) -> UInt32 {
        UInt32(id % 0xFF_FFFE) + 1
    }

    static func appendStamps(_ points: [StrokePoint], color: UInt32, into out: inout [StampInstance]) {
        var walker = StampWalker()
        for p in points { walker.feed(p, color: color, into: &out) }
    }
}

/// GPU geometry for one ink layer: instances packed in z-order plus a list of
/// draw runs (consecutive strokes that share a pipeline) with bounds for culling.
final class LayerMesh {
    struct Run {
        var kind: RenderKind
        var start: Int
        var count: Int
        var bounds: CGRect
    }

    private(set) var runs: [Run] = []
    let capsules: InstanceBuffer<CapsuleInstance>
    let stamps: InstanceBuffer<StampInstance>
    /// The `Layer.revision` this mesh was built from.
    var revision = -1

    private static let maxRunLength = 6000

    init(device: MTLDevice) {
        capsules = InstanceBuffer(device: device)
        stamps = InstanceBuffer(device: device)
    }

    func rebuild(from strokes: [Stroke]) {
        var caps: [CapsuleInstance] = []
        var dabs: [StampInstance] = []
        runs.removeAll(keepingCapacity: true)
        for stroke in strokes {
            add(stroke, caps: &caps, dabs: &dabs, capBase: 0, dabBase: 0)
        }
        capsules.replace(with: caps)
        stamps.replace(with: dabs)
    }

    func append(_ stroke: Stroke) {
        var caps: [CapsuleInstance] = []
        var dabs: [StampInstance] = []
        add(stroke, caps: &caps, dabs: &dabs, capBase: capsules.count, dabBase: stamps.count)
        capsules.append(caps)
        stamps.append(dabs)
    }

    private func add(_ stroke: Stroke, caps: inout [CapsuleInstance], dabs: inout [StampInstance], capBase: Int, dabBase: Int) {
        let kind = stroke.brush.renderKind
        let start: Int
        let count: Int
        switch kind {
        case .capsule, .highlight:
            let before = caps.count
            MeshBuilder.appendCapsules(stroke.points, color: stroke.color.value,
                                       key: MeshBuilder.key(for: stroke.id), into: &caps)
            start = capBase + before
            count = caps.count - before
        case .stamp:
            let before = dabs.count
            MeshBuilder.appendStamps(stroke.points, color: stroke.color.value, into: &dabs)
            start = dabBase + before
            count = dabs.count - before
        }
        guard count > 0 else { return }
        if let last = runs.last, last.kind == kind, last.start + last.count == start, last.count < LayerMesh.maxRunLength {
            runs[runs.count - 1].count += count
            runs[runs.count - 1].bounds = last.bounds.union(stroke.bounds)
        } else {
            runs.append(Run(kind: kind, start: start, count: count, bounds: stroke.bounds))
        }
    }
}

/// Geometry of the stroke being drawn right now.
final class LiveStroke {
    let builder: StrokeBuilder
    let brush: BrushKind
    let color: RGBA8
    let pageIndex: Int
    let pageOrigin: CGPoint

    let capsules: InstanceBuffer<CapsuleInstance>
    let stamps: InstanceBuffer<StampInstance>
    private(set) var tailCapsules: [CapsuleInstance] = []
    private(set) var tailStamps: [StampInstance] = []

    private var consumed = 0
    private var walker = StampWalker()

    /// Mask id shared by the committed part and the tail of the live stroke.
    private static let key: UInt32 = 0xFF_FFFF

    // `setVertexBytes` carries at most 4 KB, which bounds the per-frame tail.
    private static let maxTailCapsules = 4096 / MemoryLayout<CapsuleInstance>.stride
    private static let maxTailStamps = 4096 / MemoryLayout<StampInstance>.stride

    init(builder: StrokeBuilder, brush: BrushKind, color: RGBA8, pageIndex: Int, pageOrigin: CGPoint, device: MTLDevice) {
        self.builder = builder
        self.brush = brush
        self.color = color
        self.pageIndex = pageIndex
        self.pageOrigin = pageOrigin
        capsules = InstanceBuffer(device: device)
        stamps = InstanceBuffer(device: device)
    }

    var renderKind: RenderKind { brush.renderKind }

    /// Pulls newly committed points out of the builder and rebuilds the tail.
    func sync(predicted: [CGPoint]) {
        let points = builder.points
        let tail = builder.tailPoints(predicted: predicted)
        let packed = color.value

        switch renderKind {
        case .capsule, .highlight:
            if points.count > consumed, points.count > 1 {
                var fresh: [CapsuleInstance] = []
                MeshBuilder.appendCapsules(points, from: max(consumed, 1), color: packed, key: LiveStroke.key, into: &fresh)
                capsules.append(fresh)
            }
            tailCapsules.removeAll(keepingCapacity: true)
            // Until the first ink has settled, the tail is the whole stroke.
            let chain = points.last.map { [$0] + tail } ?? tail
            if !chain.isEmpty {
                MeshBuilder.appendCapsules(chain, color: packed, key: LiveStroke.key, into: &tailCapsules)
                if tailCapsules.count > LiveStroke.maxTailCapsules {
                    tailCapsules.removeLast(tailCapsules.count - LiveStroke.maxTailCapsules)
                }
            }
        case .stamp:
            if points.count > consumed {
                var fresh: [StampInstance] = []
                for i in consumed..<points.count { walker.feed(points[i], color: packed, into: &fresh) }
                stamps.append(fresh)
            }
            tailStamps.removeAll(keepingCapacity: true)
            var preview = walker
            for p in tail { preview.feed(p, color: packed, into: &tailStamps) }
            if tailStamps.count > LiveStroke.maxTailStamps {
                tailStamps.removeLast(tailStamps.count - LiveStroke.maxTailStamps)
            }
        }
        consumed = points.count
    }
}
