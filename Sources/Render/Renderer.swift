import CoreGraphics
import Foundation
import Metal
import simd

// Uniform layouts; must match Shaders.metal.

struct Uniforms {
    var offset: SIMD2<Float> = .zero
    var viewport: SIMD2<Float> = .zero
    var scale: Float = 1
    var opacity: Float = 1
    var grainScale: Float = 1
    var flags: UInt32 = 0
}

struct PaperUniforms {
    var rect: SIMD4<Float>
    var paper: SIMD4<Float>
    var line: SIMD4<Float>
    var spacing: Float
    var style: Float
    var inset: Float
    var pad: Float = 0
}

struct QuadUniforms {
    var rect: SIMD4<Float>
    var alpha: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

/// Camera for one frame. `pixel = (world - origin) * pixelsPerUnit`.
struct FrameInfo {
    var viewport: CGSize
    var pixelsPerUnit: Double
    var origin: CGPoint
    var backdrop: MTLClearColor
}

/// One page (or the visible part of an unbounded canvas) to paint.
struct PageDraw {
    let page: Page
    /// World position of the page's local origin.
    let origin: CGPoint
    /// Region to paint, in page coordinates.
    let rect: CGRect
    /// Whether ink is clipped to `rect`.
    let clips: Bool
    /// Layers from this index up sit above the stroke being drawn and are
    /// composited per frame instead of being baked into the scene texture.
    let upperStart: Int
}

/// Draws documents with Metal.
///
/// Everything that is not changing is baked into one screen-sized "scene"
/// texture. A frame during writing is then just: copy the scene, draw the
/// stroke in progress, done — its cost does not depend on how much ink is
/// already on the page. The scene is re-rendered from vector geometry
/// whenever the camera or the content changes.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let textures: TextureStore

    private let capsulePipeline: MTLRenderPipelineState
    private let highlightPipeline: MTLRenderPipelineState
    private let stampPipeline: MTLRenderPipelineState
    private let paperPipeline: MTLRenderPipelineState
    private let quadPipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState

    private let grain: MTLTexture
    private let clampSampler: MTLSamplerState
    private let repeatSampler: MTLSamplerState

    private var scene: MTLTexture?
    /// Per-stroke coverage scratch attachment (see `capsule_fragment`).
    private var mask: MTLTexture?
    /// False where the GPU cannot read the framebuffer; ink then blends plainly.
    let usesMask: Bool
    private var meshes: [UUID: LayerMesh] = [:]

    private static let paperColor = SIMD4<Float>(1, 1, 1, 1)
    private static let ruleColor = SIMD4<Float>(0.74, 0.78, 0.84, 1)
    private static let grainScale: Float = 1 / 115

    private enum Blend { case none, over, darken }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        // Exact stroke coverage needs a second attachment the ink shader can
        // read back. Every pipeline used in a pass must agree on attachments,
        // so decide first whether this GPU can do it.
        var usesMask = true

        func pipeline(_ vertex: String, _ fragment: String, _ blend: Blend, writesMask: Bool = false) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            guard let attachment = descriptor.colorAttachments[0],
                  let maskAttachment = descriptor.colorAttachments[1] else { return nil }
            if usesMask {
                maskAttachment.pixelFormat = .rgba8Unorm
                maskAttachment.writeMask = writesMask ? .all : []
            }
            attachment.pixelFormat = .bgra8Unorm
            switch blend {
            case .none:
                attachment.isBlendingEnabled = false
            case .over:
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .darken:
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .min
                attachment.alphaBlendOperation = .max
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        // Ink composites itself in the shader (framebuffer fetch), so it uses
        // no fixed-function blend. Where that is unavailable, fall back.
        var capsuleState = pipeline("capsule_vertex", "capsule_fragment", .none, writesMask: true)
        if capsuleState == nil {
            usesMask = false
            capsuleState = pipeline("capsule_vertex", "capsule_fragment_plain", .over)
        }

        let clamp = MTLSamplerDescriptor()
        clamp.minFilter = .linear
        clamp.magFilter = .linear
        clamp.mipFilter = .linear
        clamp.sAddressMode = .clampToEdge
        clamp.tAddressMode = .clampToEdge

        let tile = MTLSamplerDescriptor()
        tile.minFilter = .linear
        tile.magFilter = .linear
        tile.mipFilter = .linear
        tile.sAddressMode = .repeat
        tile.tAddressMode = .repeat

        guard let capsule = capsuleState,
              let highlight = pipeline("capsule_vertex", "highlight_fragment", .darken),
              let stamp = pipeline("stamp_vertex", "stamp_fragment", .over),
              let paper = pipeline("paper_vertex", "paper_fragment", .none),
              let quad = pipeline("quad_vertex", "quad_fragment", .over),
              let blit = pipeline("blit_vertex", "blit_fragment", .none),
              let clampSampler = device.makeSamplerState(descriptor: clamp),
              let repeatSampler = device.makeSamplerState(descriptor: tile),
              let grain = Renderer.makeGrain(device: device) else { return nil }

        self.device = device
        self.queue = queue
        self.textures = TextureStore(device: device)
        capsulePipeline = capsule
        highlightPipeline = highlight
        stampPipeline = stamp
        paperPipeline = paper
        quadPipeline = quad
        blitPipeline = blit
        self.clampSampler = clampSampler
        self.repeatSampler = repeatSampler
        self.grain = grain
        self.usesMask = usesMask
    }

    /// A small tiling noise texture that gives graphite its paper tooth.
    private static func makeGrain(device: MTLDevice) -> MTLTexture? {
        let size = 256
        var state: UInt32 = 0x1234_5678
        func random() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        let white = (0..<size * size).map { _ in random() }
        var level = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                var blur: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        blur += white[((y + dy + size) % size) * size + (x + dx + size) % size]
                    }
                }
                let v = 0.55 * white[y * size + x] + 0.45 * (blur / 9)
                level[y * size + x] = UInt8(max(0, min(255, ((v - 0.5) * 1.7 + 0.5) * 255)))
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: size, height: size, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var side = size
        var mip = 0
        while side >= 1 {
            texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: mip, withBytes: level, bytesPerRow: side)
            guard side > 1 else { break }
            let half = side / 2
            var next = [UInt8](repeating: 0, count: half * half)
            for y in 0..<half {
                for x in 0..<half {
                    let sum = Int(level[(2 * y) * side + 2 * x]) + Int(level[(2 * y) * side + 2 * x + 1])
                        + Int(level[(2 * y + 1) * side + 2 * x]) + Int(level[(2 * y + 1) * side + 2 * x + 1])
                    next[y * half + x] = UInt8(sum / 4)
                }
            }
            level = next
            side = half
            mip += 1
        }
        return texture
    }

    // MARK: Targets and caches

    func resize(to size: CGSize) {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return }
        if let scene, scene.width == width, scene.height == height { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        scene = device.makeTexture(descriptor: descriptor)

        guard usesMask else { return }
        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        maskDescriptor.usage = .renderTarget
        // Only ever read back within a render pass: keep it in tile memory,
        // so it costs no RAM.
        maskDescriptor.storageMode = .memoryless
        mask = device.makeTexture(descriptor: maskDescriptor)
    }

    private func attachMask(to pass: MTLRenderPassDescriptor) {
        guard usesMask, let mask else { return }
        pass.colorAttachments[1].texture = mask
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].storeAction = .dontCare
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    /// The baked scene, for diagnostics.
    var sceneTexture: MTLTexture? { scene }

    func matchesScene(_ size: CGSize) -> Bool {
        guard let scene else { return false }
        return scene.width == Int(size.width) && scene.height == Int(size.height)
    }

    /// Fast path after a stroke is added: extend the cached geometry in
    /// place instead of rebuilding the layer.
    func strokeAppended(_ stroke: Stroke, layerID: UUID, from oldRevision: Int, to newRevision: Int) {
        guard let mesh = meshes[layerID], mesh.revision == oldRevision else { return }
        mesh.append(stroke)
        mesh.revision = newRevision
    }

    func dropMeshes(for layerIDs: [UUID]) {
        for id in layerIDs { meshes.removeValue(forKey: id) }
    }

    private func mesh(for layer: Layer) -> LayerMesh {
        let mesh: LayerMesh
        if let existing = meshes[layer.id] {
            mesh = existing
        } else {
            mesh = LayerMesh(device: device)
            meshes[layer.id] = mesh
        }
        if mesh.revision != layer.revision {
            mesh.rebuild(from: layer.strokes)
            mesh.revision = layer.revision
        }
        return mesh
    }

    // MARK: Frames

    /// Re-renders all settled content into the scene texture.
    func drawBase(in commandBuffer: MTLCommandBuffer, frame: FrameInfo, pages: [PageDraw]) {
        guard let scene else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scene
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = frame.backdrop
        attachMask(to: pass)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        for draw in pages {
            guard let ctx = context(for: draw, frame: frame, encoder: encoder) else { continue }
            drawBackground(draw, ctx)
            drawLayers(draw, 0..<min(draw.upperStart, draw.page.layers.count), ctx)
        }
        encoder.endEncoding()
    }

    /// Copies the scene to the screen and adds what changes every frame:
    /// the stroke in progress and any layers stacked above it.
    func present(in commandBuffer: MTLCommandBuffer, target: MTLTexture, frame: FrameInfo,
                 live: LiveStroke?, liveOpacity: Float, activePage: PageDraw?) {
        guard let scene else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        attachMask(to: pass)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        encoder.setRenderPipelineState(blitPipeline)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if let draw = activePage, let ctx = context(for: draw, frame: frame, encoder: encoder) {
            if let live { drawLive(live, opacity: liveOpacity, ctx) }
            let count = draw.page.layers.count
            if draw.upperStart < count {
                drawLayers(draw, draw.upperStart..<count, ctx)
            }
        }
        encoder.endEncoding()
    }

    // MARK: Drawing

    private struct DrawContext {
        let encoder: MTLRenderCommandEncoder
        let uniforms: Uniforms
        /// Visible region in page coordinates, for culling.
        let visible: CGRect
        let pixelsPerUnit: Double
    }

    private func context(for draw: PageDraw, frame: FrameInfo, encoder: MTLRenderCommandEncoder) -> DrawContext? {
        let ppu = frame.pixelsPerUnit
        let offsetX = (Double(draw.origin.x) - Double(frame.origin.x)) * ppu
        let offsetY = (Double(draw.origin.y) - Double(frame.origin.y)) * ppu
        let width = Int(frame.viewport.width), height = Int(frame.viewport.height)
        guard width > 0, height > 0 else { return nil }

        var scissor = MTLScissorRect(x: 0, y: 0, width: width, height: height)
        if draw.clips {
            func pixel(_ v: Double, _ limit: Int) -> Int {
                Int(max(0, min(Double(limit), v.rounded())))
            }
            let x0 = pixel(offsetX + Double(draw.rect.minX) * ppu, width)
            let x1 = pixel(offsetX + Double(draw.rect.maxX) * ppu, width)
            let y0 = pixel(offsetY + Double(draw.rect.minY) * ppu, height)
            let y1 = pixel(offsetY + Double(draw.rect.maxY) * ppu, height)
            guard x1 > x0, y1 > y0 else { return nil }
            scissor = MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        encoder.setScissorRect(scissor)

        let uniforms = Uniforms(
            offset: SIMD2(Float(offsetX), Float(offsetY)),
            viewport: SIMD2(Float(frame.viewport.width), Float(frame.viewport.height)),
            scale: Float(ppu),
            opacity: 1,
            grainScale: Renderer.grainScale
        )
        let visible = CGRect(
            x: frame.origin.x - draw.origin.x, y: frame.origin.y - draw.origin.y,
            width: frame.viewport.width / ppu, height: frame.viewport.height / ppu
        )
        return DrawContext(encoder: encoder, uniforms: uniforms, visible: visible, pixelsPerUnit: ppu)
    }

    private func bind(_ uniforms: Uniforms, _ encoder: MTLRenderCommandEncoder) {
        var u = uniforms
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
    }

    private func drawBackground(_ draw: PageDraw, _ ctx: DrawContext) {
        let page = draw.page
        var style: Float = 0
        var spacing: Float = 20
        var inset: Float = 0
        if page.pdf == nil {
            switch page.paper {
            case .blank: style = 0
            case .lined: style = 1; spacing = 24; inset = 64
            case .grid: style = 2; spacing = 18
            case .dots: style = 3; spacing = 18
            }
            if !draw.clips, style > 0 {
                // Unbounded canvas: coarsen the pattern instead of letting it
                // turn into noise when zoomed far out.
                while Double(spacing) * ctx.pixelsPerUnit < 16, spacing < 1e6 { spacing *= 5 }
            }
        }
        var paper = PaperUniforms(
            rect: SIMD4(Float(draw.rect.minX), Float(draw.rect.minY), Float(draw.rect.width), Float(draw.rect.height)),
            paper: Renderer.paperColor, line: Renderer.ruleColor,
            spacing: spacing, style: style, inset: inset
        )
        let encoder = ctx.encoder
        encoder.setRenderPipelineState(paperPipeline)
        bind(ctx.uniforms, encoder)
        encoder.setVertexBytes(&paper, length: MemoryLayout<PaperUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&paper, length: MemoryLayout<PaperUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        guard let ref = page.pdf else { return }
        let bounds = CGRect(origin: .zero, size: page.size)
        if let base = textures.pdfBase(ref, pageSize: page.size) {
            drawQuad(base, rect: bounds, alpha: 1, ctx)
        }
        // Prefer the detail texture when it is sharper than the whole-page one,
        // or when it was rasterised for (about) the current zoom.
        if let detail = textures.detail,
           detail.pixelsPerUnit > Double(TextureStore.baseDensity(for: page.size)) * 1.05
            || abs(log2(detail.pixelsPerUnit / ctx.pixelsPerUnit)) < 0.3 {
            let local = detail.worldRect.offsetBy(dx: -draw.origin.x, dy: -draw.origin.y)
            if local.intersects(bounds) {
                drawQuad(detail.texture, rect: local, alpha: 1, ctx)
            }
        }
    }

    private func drawQuad(_ texture: MTLTexture, rect: CGRect, alpha: Float, _ ctx: DrawContext) {
        var quad = QuadUniforms(
            rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
            alpha: alpha
        )
        let encoder = ctx.encoder
        encoder.setRenderPipelineState(quadPipeline)
        bind(ctx.uniforms, encoder)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 2)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(clampSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawLayers(_ draw: PageDraw, _ range: Range<Int>, _ ctx: DrawContext) {
        for index in range {
            let layer = draw.page.layers[index]
            guard layer.isVisible, layer.opacity > 0.001 else { continue }
            if let image = layer.image {
                if image.frame.intersects(ctx.visible), let texture = textures.image(image.asset) {
                    drawQuad(texture, rect: image.frame, alpha: layer.opacity, ctx)
                }
                continue
            }
            let mesh = mesh(for: layer)
            var uniforms = ctx.uniforms
            uniforms.opacity = layer.opacity
            for run in mesh.runs where run.bounds.intersects(ctx.visible) {
                switch run.kind {
                case .capsule, .highlight:
                    guard let buffer = mesh.capsules.buffer else { continue }
                    drawCapsules(buffer: buffer, start: run.start, count: run.count, highlight: run.kind == .highlight, uniforms, ctx.encoder)
                case .stamp:
                    guard let buffer = mesh.stamps.buffer else { continue }
                    drawStamps(buffer: buffer, start: run.start, count: run.count, uniforms, ctx.encoder)
                }
            }
        }
    }

    private func drawCapsules(buffer: MTLBuffer, start: Int, count: Int, highlight: Bool,
                              _ uniforms: Uniforms, _ encoder: MTLRenderCommandEncoder) {
        guard count > 0 else { return }
        encoder.setRenderPipelineState(highlight ? highlightPipeline : capsulePipeline)
        bind(uniforms, encoder)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count, baseInstance: start)
    }

    private func drawStamps(buffer: MTLBuffer, start: Int, count: Int,
                            _ uniforms: Uniforms, _ encoder: MTLRenderCommandEncoder) {
        guard count > 0 else { return }
        encoder.setRenderPipelineState(stampPipeline)
        bind(uniforms, encoder)
        encoder.setFragmentTexture(grain, index: 0)
        encoder.setFragmentSamplerState(repeatSampler, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count, baseInstance: start)
    }

    private func drawLive(_ live: LiveStroke, opacity: Float, _ ctx: DrawContext) {
        var uniforms = ctx.uniforms
        uniforms.opacity = opacity
        let encoder = ctx.encoder
        switch live.renderKind {
        case .capsule, .highlight:
            let highlight = live.renderKind == .highlight
            if let buffer = live.capsules.buffer {
                drawCapsules(buffer: buffer, start: 0, count: live.capsules.count, highlight: highlight, uniforms, encoder)
            }
            let tail = live.tailCapsules
            guard !tail.isEmpty else { return }
            encoder.setRenderPipelineState(highlight ? highlightPipeline : capsulePipeline)
            bind(uniforms, encoder)
            tail.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: tail.count)
        case .stamp:
            if let buffer = live.stamps.buffer {
                drawStamps(buffer: buffer, start: 0, count: live.stamps.count, uniforms, encoder)
            }
            let tail = live.tailStamps
            guard !tail.isEmpty else { return }
            encoder.setRenderPipelineState(stampPipeline)
            bind(uniforms, encoder)
            encoder.setFragmentTexture(grain, index: 0)
            encoder.setFragmentSamplerState(repeatSampler, index: 0)
            tail.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: tail.count)
        }
    }
}
