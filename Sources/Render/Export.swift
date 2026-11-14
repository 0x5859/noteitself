import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// An immutable copy of a document's content, safe to read off the main thread.
struct ExportSnapshot {
    struct PageSnapshot {
        let info: PageInfo
        /// Nil when the page was not in memory; it is then read from disk.
        let layers: [Layer]?
    }

    let package: URL
    let title: String
    let kind: DocKind
    let pages: [PageSnapshot]

    init(document: NoteDocument) {
        package = document.url
        title = document.title
        kind = document.kind
        pages = document.pages.map { PageSnapshot(info: $0.info, layers: $0.isLoaded ? $0.layers : nil) }
    }

    func layers(of page: PageSnapshot) -> [Layer] {
        if let layers = page.layers { return layers }
        let file = NoteDocument.pageURL(in: package, id: page.info.id)
        // Read behind any save that is still queued.
        let data = NoteDocument.ioQueue.sync { try? Data(contentsOf: file) }
        return data.flatMap { try? PageCodec.decode($0) } ?? []
    }

    func assetURL(_ name: String) -> URL {
        package.appendingPathComponent("assets").appendingPathComponent(name)
    }
}

/// Draws pages with Core Graphics. Used for PDF export and thumbnails, where
/// output must be resolution independent: ink becomes vector paths and PDF
/// backgrounds are re-emitted as vector content, not screenshots.
enum CGRenderer {
    private static let ruleColor = CGColor(red: 0.74, green: 0.78, blue: 0.84, alpha: 1)

    /// Caches opened PDFs across the pages of one export.
    final class Assets {
        let snapshot: ExportSnapshot
        private var pdfs: [String: CGPDFDocument] = [:]

        init(_ snapshot: ExportSnapshot) { self.snapshot = snapshot }

        func pdfPage(_ ref: PDFRef) -> CGPDFPage? {
            if pdfs[ref.asset] == nil {
                pdfs[ref.asset] = CGPDFDocument(snapshot.assetURL(ref.asset) as CFURL)
            }
            return pdfs[ref.asset]?.page(at: ref.page)
        }

        func image(_ asset: String, maxPixel: Int) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(snapshot.assetURL(asset) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }

    /// Paints paper, PDF background and all layers of one page.
    /// `ctx` must be flipped (origin top-left, y down) with 1 unit = 1 page point.
    static func draw(page: ExportSnapshot.PageSnapshot, layers: [Layer], rect: CGRect, in ctx: CGContext, assets: Assets, imagePixels: Int = 3000) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)

        if let ref = page.info.pdf, let pdfPage = assets.pdfPage(ref) {
            // PDF content expects y up: flip locally around the page.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(page.info.height))
            ctx.scaleBy(x: 1, y: -1)
            PDFGeometry.draw(pdfPage, in: ctx, dest: CGRect(x: 0, y: 0, width: page.info.width, height: page.info.height))
            ctx.restoreGState()
        } else {
            drawRules(page.info.paper, rect: rect, in: ctx)
        }

        for layer in layers where layer.isVisible && layer.opacity > 0.001 {
            if let image = layer.image {
                guard let cg = assets.image(image.asset, maxPixel: imagePixels) else { continue }
                ctx.saveGState()
                ctx.setAlpha(CGFloat(layer.opacity))
                ctx.translateBy(x: image.frame.minX, y: image.frame.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(origin: .zero, size: image.frame.size))
                ctx.restoreGState()
            } else {
                for stroke in layer.strokes where stroke.bounds.intersects(rect) {
                    draw(stroke, opacity: CGFloat(layer.opacity), in: ctx)
                }
            }
        }
        ctx.restoreGState()
    }

    private static func drawRules(_ style: PaperStyle, rect: CGRect, in ctx: CGContext) {
        guard style != .blank, rect.width < 20000, rect.height < 20000 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(ruleColor)
        ctx.setFillColor(ruleColor)
        ctx.setLineWidth(0.5)
        switch style {
        case .blank:
            break
        case .lined:
            var y = 64 + ((max(rect.minY, 64) - 64) / 24).rounded(.up) * 24
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += 24
            }
            ctx.strokePath()
        case .grid:
            var x = (rect.minX / 18).rounded(.up) * 18
            while x < rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += 18
            }
            var y = (rect.minY / 18).rounded(.up) * 18
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += 18
            }
            ctx.strokePath()
        case .dots:
            var y = (rect.minY / 18).rounded(.up) * 18
            while y < rect.maxY {
                var x = (rect.minX / 18).rounded(.up) * 18
                while x < rect.maxX {
                    ctx.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    x += 18
                }
                y += 18
            }
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Emits one stroke as stroked paths. Runs of near-constant width are
    /// merged into a single round-joined polyline to keep files small.
    static func draw(_ stroke: Stroke, opacity: CGFloat, in ctx: CGContext) {
        let points = stroke.points
        guard let first = points.first else { return }
        let color = stroke.color
        let kind = stroke.brush.renderKind

        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        var needsGroup = false
        switch kind {
        case .highlight:
            // Same result as the on-screen MIN blend: tint mixed towards
            // white, darken-blended, so overlaps never build up.
            let a = color.alpha * Double(opacity)
            func mix(_ c: UInt8) -> CGFloat { CGFloat(1 + (Double(c) / 255 - 1) * a) }
            let tint = CGColor(red: mix(color.r), green: mix(color.g), blue: mix(color.b), alpha: 1)
            ctx.setBlendMode(.darken)
            ctx.setStrokeColor(tint)
            ctx.setFillColor(tint)
        case .capsule, .stamp:
            var alpha = color.alpha * Double(opacity)
            if kind == .stamp {
                // Graphite texture has no vector equivalent; approximate its tone.
                let mean = points.reduce(0) { $0 + Double($1.a) } / Double(points.count)
                alpha *= 0.35 + 0.6 * mean
            }
            let solid = color.withAlpha(1).cgColor
            ctx.setStrokeColor(solid)
            ctx.setFillColor(solid)
            if alpha < 0.995 {
                // Draw opaque into a group, then fade the group: the stroke's
                // own overlaps must not darken.
                needsGroup = true
                ctx.setAlpha(CGFloat(alpha))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
        }

        if points.count == 1 {
            ctx.fillEllipse(in: CGRect(x: CGFloat(first.x - first.r), y: CGFloat(first.y - first.r),
                                       width: CGFloat(first.r * 2), height: CGFloat(first.r * 2)))
        } else {
            // A run is points[runStart...end]; consecutive runs share a point
            // so their round caps close the joint.
            var runStart = 0
            var runRadius = first.r
            var sum = first.r
            var count: Float = 1
            func flush(to end: Int) {
                guard end > runStart else { return }
                ctx.setLineWidth(CGFloat(sum / count) * 2)
                ctx.move(to: CGPoint(x: CGFloat(points[runStart].x), y: CGFloat(points[runStart].y)))
                for i in (runStart + 1)...end {
                    ctx.addLine(to: CGPoint(x: CGFloat(points[i].x), y: CGFloat(points[i].y)))
                }
                ctx.strokePath()
            }
            for i in 1..<points.count {
                let r = points[i].r
                if abs(r - runRadius) > max(runRadius * 0.04, 0.01) {
                    flush(to: i)
                    runStart = i
                    runRadius = r
                    sum = r
                    count = 1
                } else {
                    sum += r
                    count += 1
                }
            }
            flush(to: points.count - 1)
        }

        if needsGroup { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }
}

enum PDFExporter {
    /// Writes the document to a PDF in the temporary directory.
    static func export(_ snapshot: ExportSnapshot) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(snapshot.title).appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: url)

        let assets = CGRenderer.Assets(snapshot)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: snapshot.title, kCGPDFContextCreator as String: "noteitself"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)

        try renderer.writePDF(to: url) { context in
            for page in snapshot.pages {
                autoreleasepool {
                    let layers = snapshot.layers(of: page)
                    if snapshot.kind == .canvas {
                        // An unbounded canvas exports as one page fitted to its content.
                        let content = contentBounds(of: layers).insetBy(dx: -24, dy: -24)
                        let scale = min(1, 14000 / max(content.width, content.height))
                        let size = CGSize(width: content.width * scale, height: content.height * scale)
                        context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                        let ctx = context.cgContext
                        ctx.scaleBy(x: scale, y: scale)
                        ctx.translateBy(x: -content.minX, y: -content.minY)
                        CGRenderer.draw(page: page, layers: layers, rect: content, in: ctx, assets: assets)
                    } else {
                        let bounds = CGRect(x: 0, y: 0, width: page.info.width, height: page.info.height)
                        context.beginPage(withBounds: bounds, pageInfo: [:])
                        CGRenderer.draw(page: page, layers: layers, rect: bounds, in: context.cgContext, assets: assets)
                    }
                }
            }
        }
        return url
    }

    static func contentBounds(of layers: [Layer]) -> CGRect {
        var bounds = CGRect.null
        for layer in layers where layer.isVisible {
            if let image = layer.image { bounds = bounds.union(image.frame) }
            for stroke in layer.strokes { bounds = bounds.union(stroke.bounds) }
        }
        return bounds.isNull ? CGRect(x: -300, y: -200, width: 600, height: 400) : bounds
    }
}

enum Thumbnailer {
    /// Renders the first page into a small PNG for the library grid.
    static func write(for snapshot: ExportSnapshot, to url: URL) {
        guard let page = snapshot.pages.first else { return }
        let layers = snapshot.layers(of: page)
        let rect: CGRect
        if snapshot.kind == .canvas {
            var content = PDFExporter.contentBounds(of: layers).insetBy(dx: -24, dy: -24)
            // Keep a 3:4 card shape around the content.
            let target = max(content.width, content.height * 0.75)
            content = CGRect(x: content.midX - target / 2, y: content.midY - target / 1.5, width: target, height: target / 0.75)
            rect = content
        } else {
            rect = CGRect(x: 0, y: 0, width: page.info.width, height: page.info.height)
        }
        guard rect.width > 0, rect.height > 0 else { return }

        let scale = 420 / max(rect.width, rect.height)
        let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            CGRenderer.draw(page: page, layers: layers, rect: rect, in: ctx, assets: CGRenderer.Assets(snapshot), imagePixels: 600)
        }
        try? image.pngData()?.write(to: url, options: .atomic)
    }
}
