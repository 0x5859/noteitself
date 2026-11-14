import CoreGraphics
import Foundation
import UIKit
import os

/// One sample of a finished stroke, in page coordinates.
/// The layout (4 × Float32) is also the on-disk format.
struct StrokePoint: Equatable {
    var x: Float
    var y: Float
    /// Half of the stroke width at this point.
    var r: Float
    /// Opacity 0…1; only textured brushes use it.
    var a: Float
}

enum BrushKind: UInt8, CaseIterable {
    case pen = 0
    case pencil = 1
    case brush = 2
    case marker = 3
    case highlighter = 4

    var renderKind: RenderKind {
        switch self {
        case .pencil: return .stamp
        case .highlighter: return .highlight
        case .pen, .brush, .marker: return .capsule
        }
    }
}

/// How a stroke is rasterised.
enum RenderKind: UInt8 {
    /// Exact, anti-aliased variable-width segments.
    case capsule
    /// Same geometry, darken blend so text underneath stays legible.
    case highlight
    /// Overlapping textured dabs (graphite).
    case stamp
}

/// sRGB colour packed as R | G<<8 | B<<16 | A<<24 (straight alpha).
struct RGBA8: Equatable, Hashable, Codable {
    var value: UInt32

    init(_ value: UInt32) { self.value = value }

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        value = UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24
    }

    /// From 0xRRGGBB.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            r: UInt8((hex >> 16) & 0xFF),
            g: UInt8((hex >> 8) & 0xFF),
            b: UInt8(hex & 0xFF),
            a: UInt8((max(0, min(1, alpha)) * 255).rounded())
        )
    }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let srgb = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        if let c = srgb?.components, c.count >= 4 {
            r = c[0]; g = c[1]; b = c[2]; a = c[3]
        } else {
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((max(0, min(1, v)) * 255).rounded()) }
        self.init(r: byte(r), g: byte(g), b: byte(b), a: byte(a))
    }

    var r: UInt8 { UInt8(value & 0xFF) }
    var g: UInt8 { UInt8((value >> 8) & 0xFF) }
    var b: UInt8 { UInt8((value >> 16) & 0xFF) }
    var a: UInt8 { UInt8((value >> 24) & 0xFF) }

    var alpha: Double { Double(a) / 255 }

    func withAlpha(_ alpha: Double) -> RGBA8 {
        RGBA8(r: r, g: g, b: b, a: UInt8((max(0, min(1, alpha)) * 255).rounded()))
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    var cgColor: CGColor { uiColor.cgColor }

    static let black = RGBA8(hex: 0x1C1C1E)
}

/// An immutable finished stroke. Shared freely between the document,
/// undo history and background savers.
final class Stroke {
    let id: UInt64
    let brush: BrushKind
    let color: RGBA8
    let points: [StrokePoint]
    /// Bounding box including the stroke width.
    let bounds: CGRect

    init(brush: BrushKind, color: RGBA8, points: [StrokePoint]) {
        self.id = Stroke.nextID()
        self.brush = brush
        self.color = color
        self.points = points
        self.bounds = Stroke.bounds(of: points)
    }

    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    private static func nextID() -> UInt64 {
        counter.withLock { value in
            value += 1
            return value
        }
    }

    static func bounds(of points: [StrokePoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x - first.r, maxX = first.x + first.r
        var minY = first.y - first.r, maxY = first.y + first.r
        for p in points.dropFirst() {
            minX = min(minX, p.x - p.r); maxX = max(maxX, p.x + p.r)
            minY = min(minY, p.y - p.r); maxY = max(maxY, p.y + p.r)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }
}
