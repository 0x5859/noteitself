import CoreGraphics
import Foundation
import ImageIO
import Metal
import os

/// Decodes images and rasterises PDF pages off the main thread and keeps the
/// resulting textures within a small budget.
///
/// PDF backgrounds use two levels: a modest whole-page texture that is always
/// available while scrolling, and one sharp "detail" texture covering what is
/// on screen at the exact current zoom, refreshed whenever the view settles.
final class TextureStore {
    struct Detail {
        let texture: MTLTexture
        let worldRect: CGRect
        let pixelsPerUnit: Double
    }

    struct PDFPlacement {
        let ref: PDFRef
        /// Page frame in world coordinates.
        let frame: CGRect
    }

    private struct Base {
        let texture: MTLTexture
        var lastUse: Int
    }

    let device: MTLDevice
    var packageURL: URL?
    /// Called on the main thread when a texture becomes available.
    var onChange: (() -> Void)?

    private(set) var detail: Detail?

    private var images: [String: MTLTexture] = [:]
    private var bases: [PDFRef: Base] = [:]
    private var pending = Set<String>()
    private var useCounter = 0
    private let detailGeneration = OSAllocatedUnfairLock(initialState: 0)

    private let queue = DispatchQueue(label: "noteitself.textures", qos: .userInitiated)
    private var documents: [String: CGPDFDocument] = [:]   // touched only on `queue`

    private static let baseLongSide: CGFloat = 1400
    private static let maxBases = 6
    private static let imageLongSide = 2048

    init(device: MTLDevice) { self.device = device }

    // MARK: Lookup (main thread)

    func image(_ asset: String) -> MTLTexture? {
        if let texture = images[asset] { return texture }
        guard let package = packageURL, pending.insert("img:" + asset).inserted else { return nil }
        let url = package.appendingPathComponent("assets").appendingPathComponent(asset)
        queue.async { [weak self] in
            guard let self else { return }
            let texture = self.decodeImage(at: url)
            DispatchQueue.main.async {
                self.pending.remove("img:" + asset)
                guard let texture else { return }
                self.images[asset] = texture
                self.onChange?()
            }
        }
        return nil
    }

    /// Pixels per page unit of the whole-page texture for a page of this size.
    static func baseDensity(for size: CGSize) -> CGFloat {
        min(2, baseLongSide / max(size.width, size.height, 1))
    }

    func pdfBase(_ ref: PDFRef, pageSize: CGSize) -> MTLTexture? {
        useCounter += 1
        if bases[ref] != nil {
            bases[ref]?.lastUse = useCounter
            return bases[ref]?.texture
        }
        let key = "pdf:\(ref.asset):\(ref.page)"
        guard let package = packageURL, pending.insert(key).inserted else { return nil }
        let density = TextureStore.baseDensity(for: pageSize)
        queue.async { [weak self] in
            guard let self else { return }
            let texture = self.renderPDF(package: package, ref: ref, pageSize: pageSize, density: density)
            DispatchQueue.main.async {
                self.pending.remove(key)
                guard let texture else { return }
                self.bases[ref] = Base(texture: texture, lastUse: self.useCounter)
                self.trimBases()
                self.onChange?()
            }
        }
        return nil
    }

    private func trimBases() {
        while bases.count > TextureStore.maxBases,
              let oldest = bases.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            bases.removeValue(forKey: oldest.key)
        }
    }

    /// Renders the given PDF pages into one texture covering `worldRect`.
    func requestDetail(pages: [PDFPlacement], worldRect: CGRect, pixelsPerUnit: Double) {
        let generation = detailGeneration.withLock { value -> Int in
            value += 1
            return value
        }
        guard !pages.isEmpty, let package = packageURL else {
            detail = nil
            return
        }
        if let d = detail, d.worldRect == worldRect, d.pixelsPerUnit == pixelsPerUnit { return }
        queue.async { [weak self] in
            guard let self else { return }
            // Skip work that a newer request has already superseded.
            guard self.detailGeneration.withLock({ $0 }) == generation else { return }
            let texture = self.renderDetail(package: package, pages: pages, worldRect: worldRect, pixelsPerUnit: pixelsPerUnit)
            DispatchQueue.main.async {
                guard self.detailGeneration.withLock({ $0 }) == generation, let texture else { return }
                self.detail = Detail(texture: texture, worldRect: worldRect, pixelsPerUnit: pixelsPerUnit)
                self.onChange?()
            }
        }
    }

    /// Drops the detail texture, e.g. after pages moved.
    func invalidateDetail() {
        detailGeneration.withLock { $0 += 1 }
        detail = nil
    }

    // MARK: Rasterising (background queue)

    private func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private func makeTexture(from ctx: CGContext) -> MTLTexture? {
        guard let bytes = ctx.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: ctx.width, height: ctx.height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, ctx.width, ctx.height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: ctx.bytesPerRow
        )
        return texture
    }

    private func decodeImage(at url: URL) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: TextureStore.imageLongSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let ctx = makeContext(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return makeTexture(from: ctx)
    }

    private func pdfPage(package: URL, ref: PDFRef) -> CGPDFPage? {
        if documents[ref.asset] == nil {
            let url = package.appendingPathComponent("assets").appendingPathComponent(ref.asset)
            documents[ref.asset] = CGPDFDocument(url as CFURL)
        }
        return documents[ref.asset]?.page(at: ref.page)
    }

    private func renderPDF(package: URL, ref: PDFRef, pageSize: CGSize, density: CGFloat) -> MTLTexture? {
        let width = max(1, Int((pageSize.width * density).rounded()))
        let height = max(1, Int((pageSize.height * density).rounded()))
        guard let page = pdfPage(package: package, ref: ref),
              let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        PDFGeometry.draw(page, in: ctx, dest: CGRect(x: 0, y: 0, width: width, height: height))
        return makeTexture(from: ctx)
    }

    private func renderDetail(package: URL, pages: [PDFPlacement], worldRect: CGRect, pixelsPerUnit: Double) -> MTLTexture? {
        let width = Int((worldRect.width * pixelsPerUnit).rounded())
        let height = Int((worldRect.height * pixelsPerUnit).rounded())
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              let ctx = makeContext(width: width, height: height) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for placement in pages {
            guard let page = pdfPage(package: package, ref: placement.ref) else { continue }
            let w = placement.frame.width * pixelsPerUnit
            let h = placement.frame.height * pixelsPerUnit
            let x = (placement.frame.minX - worldRect.minX) * pixelsPerUnit
            let top = (placement.frame.minY - worldRect.minY) * pixelsPerUnit
            // Bitmap contexts have their origin at the bottom-left.
            let dest = CGRect(x: x, y: CGFloat(height) - top - h, width: w, height: h)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(dest)
            PDFGeometry.draw(page, in: ctx, dest: dest)
            ctx.restoreGState()
        }
        return makeTexture(from: ctx)
    }
}
