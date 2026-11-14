#if DEBUG
import CoreGraphics
import Foundation
import Metal
import UIKit

/// Launch arguments used by automated checks. Compiled into debug builds only.
///
///   -new <kind>           create a notebook / canvas / pixel note at launch and open it
///   -openTitle <name>     open the note with this title at launch
///   -importPDF <path>     import a PDF at launch and open it
///   -demoInk              draw sample strokes with every brush once a note opens
///   -demoFeel             draw simulated glass handwriting through each stroke pipeline
///   -demoImage            insert a sample image layer once a note opens
///   -rendererCheck        render every stroke kind offscreen and print the result
enum DebugHooks {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func launch(_ library: Library, open: (LibraryItem) -> Void) {
        if arguments.contains("-rendererCheck") { rendererCheck() }
        if let path = value(after: "-importPDF"),
           let item = try? library.importPDF(at: URL(fileURLWithPath: path)) {
            open(item)
        } else if let kind = value(after: "-new").flatMap(DocKind.init(rawValue:)),
                  let item = try? library.create(kind: kind) {
            open(item)
        } else if let title = value(after: "-openTitle"),
                  let item = library.items.first(where: { $0.title == title }) {
            open(item)
        }
    }

    /// Renders one stroke of every kind offscreen on this device's GPU and
    /// prints what came out. Touches no documents.
    private static func rendererCheck() {
        guard let device = MTLCreateSystemDefaultDevice(), let renderer = Renderer(device: device) else {
            print("GPU-CHECK FAIL renderer could not be created")
            return
        }
        print("GPU-CHECK gpu: \(device.name) | ink path: \(renderer.usesMask ? "exact coverage (framebuffer fetch + tile-memory mask)" : "fallback blend")")

        let side = 256
        let size = CGSize(width: side, height: side)
        renderer.resize(to: size)

        func line(_ y: Float, _ brush: BrushKind, _ color: RGBA8, radius: Float) -> Stroke {
            let points = stride(from: Float(20), through: 236, by: 6).map { StrokePoint(x: $0, y: y, r: radius, a: 0.9) }
            return Stroke(brush: brush, color: color, points: points)
        }
        let page = Page(size: size, paper: .blank)
        page.layers = [Layer(name: "check", strokes: [
            line(60.37, .pen, .black, radius: 1.4),
            line(110, .highlighter, RGBA8(hex: 0xFFE14D, alpha: 0.55), radius: 8),
            line(160, .pencil, .black, radius: 3),
            line(210, .marker, RGBA8(hex: 0xD63A2F), radius: 4),
        ])]
        page.isLoaded = true

        let frame = FrameInfo(viewport: size, pixelsPerUnit: 1, origin: .zero,
                              backdrop: MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        let draw = PageDraw(page: page, origin: .zero, rect: CGRect(origin: .zero, size: size), clips: true, upperStart: 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        descriptor.storageMode = .shared
        guard let commandBuffer = renderer.queue.makeCommandBuffer(),
              let readback = device.makeTexture(descriptor: descriptor) else {
            print("GPU-CHECK FAIL could not create command buffer")
            return
        }
        renderer.drawBase(in: commandBuffer, frame: frame, pages: [draw])
        if let scene = renderer.sceneTexture, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: side, height: side, depth: 1),
                      to: readback, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            print("GPU-CHECK FAIL gpu error: \(error)")
            return
        }

        var raw = [UInt8](repeating: 0, count: side * side * 4)
        readback.getBytes(&raw, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * side + x) * 4
            return (Int(raw[i + 2]), Int(raw[i + 1]), Int(raw[i]))
        }
        func report(_ ok: Bool, _ text: String) { print("GPU-CHECK \(ok ? "PASS" : "FAIL") \(text)") }

        let paper = rgb(128, 30), pen = rgb(128, 60), marker = rgb(128, 210), highlight = rgb(128, 106), pencil = rgb(128, 160)
        report(paper.r > 250 && paper.g > 250 && paper.b > 250, "paper is white \(paper)")
        report(pen.r < 60, "pen core is dark \(pen)")
        report(marker.r > 180 && marker.g < 100, "marker is red \(marker)")
        report(highlight.r > 230 && highlight.b < 200 && highlight.b > 100, "highlighter tints the paper \(highlight)")
        report(pencil.r < 200 && pencil.r > 10, "pencil lays down graphite \(pencil)")
        // The pen's anti-aliased edge rows must be even along the stroke: no beads at joints.
        var spread = 0
        for y in 58...62 {
            let row = (30..<226).map { rgb($0, y).r }
            spread = max(spread, row.max()! - row.min()!)
        }
        report(renderer.usesMask ? spread <= 2 : true, "pen edge variation along the stroke: \(spread)/255")
        print("GPU-CHECK done")
    }

    static func editorAppeared(_ session: EditorSession) {
        // Wait for the canvas to lay out so content lands in the visible area.
        if arguments.contains("-demoInk") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { drawSamples(in: session) }
        }
        if arguments.contains("-demoFeel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { drawFeelComparison(in: session) }
        }
        if arguments.contains("-demoImage") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { session.insertImage(data: sampleImage()) }
        }
    }

    /// The same simulated glass handwriting through different pipelines, one
    /// per row: intended path, raw input, the old default smoothing, heavy
    /// smoothing, the paper-feel default, and paper feel at full strength.
    private static func drawFeelComparison(in session: EditorSession) {
        let zoom = CGFloat(session.canvas?.viewState.zoom ?? 1.4)
        let rows: [(slip: CGFloat, smoothing: Double, paper: Double, natural: Bool)] = [
            (0, 0, 0, false),
            (1, 0, 0, false),
            (1, 0.25, 0, false),
            (1, 0.8, 0, false),
            (1, 0.15, 0.6, true),
            (1, 0.15, 1.0, true),
        ]
        let xHeight: CGFloat = 10
        for (index, row) in rows.enumerated() {
            for column in 0..<4 {
                let origin = CGPoint(x: 34 + CGFloat(column) * 134, y: 110 + CGFloat(index) * 46)
                let strokes = SyntheticHand.strokes(origin: origin, xHeight: xHeight, zoom: zoom, slip: row.slip, seed: UInt64(11 + column))
                for stroke in strokes {
                    let builder = StrokeBuilder(kind: .pen, radius: 0.65, smoothing: row.smoothing, zoom: Double(zoom),
                                                paper: row.paper, naturalInk: row.natural)
                    stroke.samples.forEach(builder.add)
                    let points = builder.finish()
                    guard !points.isEmpty else { continue }
                    session.commit(Stroke(brush: .pen, color: .black, points: points), pageIndex: session.activePageIndex)
                }
            }
        }
        session.canvas?.setNeedsBase()
    }

    /// A simple picture to trace over.
    private static func sampleImage() -> Data {
        let size = CGSize(width: 600, height: 400)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            let ctx = context.cgContext
            UIColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.20, green: 0.45, blue: 0.70, alpha: 1).setFill()
            ctx.fill(CGRect(x: 80, y: 90, width: 440, height: 220))
            UIColor(red: 0.95, green: 0.60, blue: 0.20, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: 230, y: 130, width: 140, height: 140))
        }
    }

    /// Feeds synthetic 240 Hz Pencil samples (with varying pressure and tilt)
    /// through the real stroke pipeline.
    private static func drawSamples(in session: EditorSession) {
        guard let page = session.loadedPage(session.activePageIndex) else { return }
        let width: CGFloat = session.document.isInfinite ? 520 : page.size.width
        let left: CGFloat = session.document.isInfinite ? -260 : 0
        var baseline: CGFloat = session.document.isInfinite ? -160 : 90

        func stroke(_ tool: Tool, color: RGBA8, y: CGFloat, tilt: CGFloat = .pi / 2, wobble: CGFloat = 1) {
            guard let kind = tool.brush else { return }
            let settings = session.box[tool]
            let builder = StrokeBuilder(kind: kind, radius: Float(settings.width / 2), smoothing: settings.smoothing, zoom: 1.6,
                                        paper: settings.paper, naturalInk: settings.naturalInk)
            var x = left + 50
            var time: TimeInterval = 0
            var n = 0
            while x < left + width - 50 {
                let t = Double(n) / 240
                let jitter = CGFloat(sin(Double(n) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) * 0.35
                let point = CGPoint(
                    x: x,
                    y: y + wobble * (13 * sin(x / 17) + 5 * sin(x / 6.5)) + jitter
                )
                let pressure = 0.5 + 0.42 * sin(t * 5.5)
                builder.add(InputSample(position: point, pressure: CGFloat(pressure), altitude: tilt, time: time))
                x += 1.5 + 0.9 * CGFloat(sin(t * 3))
                time += 1.0 / 240
                n += 1
            }
            let points = builder.finish()
            let ink = kind == .highlighter ? color.withAlpha(settings.opacity) : color
            session.commit(Stroke(brush: kind, color: ink, points: points), pageIndex: session.activePageIndex)
        }

        let ink = RGBA8(session.box.inkColors[0])
        stroke(.pen, color: ink, y: baseline)
        stroke(.highlighter, color: RGBA8(session.box.highlightColors[0]), y: baseline, wobble: 0.2)
        baseline += 70
        stroke(.pencil, color: ink, y: baseline)
        baseline += 55
        stroke(.pencil, color: ink, y: baseline, tilt: 0.35)
        baseline += 70
        stroke(.brush, color: RGBA8(session.box.inkColors[1]), y: baseline)
        baseline += 70
        stroke(.marker, color: RGBA8(session.box.inkColors[2]), y: baseline)
        baseline += 70
        stroke(.pen, color: ink, y: baseline)

        // Rub a vertical band out of everything with the precise eraser.
        let x = left + width * 0.62
        session.beginErase(pageIndex: session.activePageIndex)
        session.erase(from: CGPoint(x: x, y: baseline - 400), to: CGPoint(x: x, y: baseline - 20), radius: 9)
        session.endErase()
        session.canvas?.setNeedsBase()
    }
}
#endif
