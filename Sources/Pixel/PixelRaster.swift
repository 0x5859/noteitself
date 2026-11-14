import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Conversions between pixel buffers, `CGImage`s and files. Thread-safe.
enum PixelRaster {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Builds an image from premultiplied pixels (copied, so the buffer may change afterwards).
    static func image(_ pixels: [UInt32], width: Int, height: Int, opaque: Bool = false) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Decodes image data into premultiplied pixels of exactly `width`×`height`.
    static func decode(_ data: Data, width: Int, height: Int) -> [UInt32]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func pngData(_ pixels: [UInt32], width: Int, height: Int, opaque: Bool = false) -> Data? {
        image(pixels, width: width, height: height, opaque: opaque).flatMap(pngData)
    }

    /// Nearest-neighbour upscale by an integer factor.
    static func upscaled(_ pixels: [UInt32], width: Int, height: Int, by factor: Int) -> [UInt32] {
        guard factor > 1 else { return pixels }
        let outWidth = width * factor
        var out = [UInt32](repeating: 0, count: outWidth * height * factor)
        out.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            for y in 0..<height {
                let row = base + y * factor * outWidth
                for x in 0..<width {
                    let value = pixels[y * width + x]
                    for k in 0..<factor { row[x * factor + k] = value }
                }
                for k in 1..<factor { (row + k * outWidth).update(from: row, count: outWidth) }
            }
        }
        return out
    }

    // MARK: Package and export renditions

    /// Library preview: flattened over white, upscaled so the long side is ~512 px.
    static func thumbnailPNG(_ document: PixelDocument) -> Data? {
        let factor = max(1, 512 / max(document.width, document.height))
        let flat = document.flattened().map(PixelRGBA.overWhite)
        return pngData(upscaled(flat, width: document.width, height: document.height, by: factor),
                       width: document.width * factor, height: document.height * factor, opaque: true)
    }

    /// Transparent PNG upscaled so the long side is at least 1024 px.
    static func writePNG(_ document: PixelDocument, to url: URL) throws {
        let long = max(document.width, document.height)
        let factor = max(1, (1024 + long - 1) / long)
        let big = upscaled(document.flattened(), width: document.width, height: document.height, by: factor)
        guard let data = pngData(big, width: document.width * factor, height: document.height * factor) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Vector PDF: one filled rectangle per horizontal run of identical pixels.
    static func writePDF(_ document: PixelDocument, to url: URL) throws {
        let w = document.width, h = document.height
        let cell = 512 / CGFloat(max(w, h))
        let flat = document.flattened()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: CGFloat(w) * cell, height: CGFloat(h) * cell))
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            let cg = context.cgContext
            for y in 0..<h {
                var x = 0
                while x < w {
                    let value = flat[y * w + x]
                    var end = x + 1
                    while end < w, flat[y * w + end] == value { end += 1 }
                    if PixelRGBA.alpha(value) > 0 {
                        cg.setFillColor(PixelColor(pixel: value).cgColor)
                        cg.fill(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                       width: CGFloat(end - x) * cell, height: cell))
                    }
                    x = end
                }
            }
        }
    }
}
