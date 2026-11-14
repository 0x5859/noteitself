import SwiftUI
import UIKit

/// Integer cell coordinate on the artwork; (0, 0) is the top-left pixel.
struct PixelPoint: Hashable {
    var x: Int
    var y: Int
}

/// Canvas pixel format: premultiplied sRGB RGBA8 packed into a `UInt32` whose
/// in-memory byte order is R, G, B, A (little-endian, so R is the low byte).
enum PixelRGBA {
    @inline(__always)
    static func pack(_ r: UInt32, _ g: UInt32, _ b: UInt32, _ a: UInt32) -> UInt32 {
        r | g << 8 | b << 16 | a << 24
    }

    @inline(__always)
    static func alpha(_ p: UInt32) -> UInt32 { p >> 24 }

    /// `x * y / 255`, correctly rounded, for 8-bit operands.
    @inline(__always)
    static func mul(_ x: UInt32, _ y: UInt32) -> UInt32 {
        let t = x * y + 128
        return (t + (t >> 8)) >> 8
    }

    /// Scales every channel of a premultiplied pixel by `factor / 255`.
    @inline(__always)
    static func scaled(_ p: UInt32, by factor: UInt32) -> UInt32 {
        if factor == 255 { return p }
        return pack(mul(p & 0xFF, factor), mul(p >> 8 & 0xFF, factor),
                    mul(p >> 16 & 0xFF, factor), mul(p >> 24, factor))
    }

    /// Porter-Duff source-over for premultiplied pixels.
    @inline(__always)
    static func over(_ src: UInt32, _ dst: UInt32) -> UInt32 {
        let sa = src >> 24
        if sa == 255 || dst == 0 { return src }
        if sa == 0 { return dst }
        let k = 255 - sa
        return pack((src & 0xFF) + mul(dst & 0xFF, k),
                    (src >> 8 & 0xFF) + mul(dst >> 8 & 0xFF, k),
                    (src >> 16 & 0xFF) + mul(dst >> 16 & 0xFF, k),
                    sa + mul(dst >> 24, k))
    }

    /// Flattens a premultiplied pixel onto opaque white.
    @inline(__always)
    static func overWhite(_ p: UInt32) -> UInt32 {
        let k = 255 - (p >> 24)
        return pack((p & 0xFF) + k, (p >> 8 & 0xFF) + k, (p >> 16 & 0xFF) + k, 255)
    }
}

/// A straight-alpha sRGB colour as the user sees and picks it.
struct PixelColor: Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        let v = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(r: UInt8(v >> 24), g: UInt8(v >> 16 & 0xFF), b: UInt8(v >> 8 & 0xFF), a: UInt8(v & 0xFF))
    }

    /// Converts a premultiplied canvas pixel back to straight alpha.
    init(pixel p: UInt32) {
        let a = PixelRGBA.alpha(p)
        func channel(_ c: UInt32) -> UInt8 {
            a == 0 ? 0 : UInt8(min(255, (c * 255 + a / 2) / a))
        }
        self.init(r: channel(p & 0xFF), g: channel(p >> 8 & 0xFF), b: channel(p >> 16 & 0xFF), a: UInt8(a))
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(r: byte(r), g: byte(g), b: byte(b), a: byte(a))
    }

    var hex: String { String(format: "#%02X%02X%02X%02X", r, g, b, a) }

    /// The colour in canvas pixel format.
    var pixel: UInt32 {
        let a = UInt32(self.a)
        return PixelRGBA.pack(PixelRGBA.mul(UInt32(r), a), PixelRGBA.mul(UInt32(g), a),
                              PixelRGBA.mul(UInt32(b), a), a)
    }

    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    /// The app's own 24-colour palette: an ink-and-paper neutral ramp, then warm,
    /// green/cool and indigo/earth rows, six per row.
    static let defaultPalette: [PixelColor] = [
        "#16161D", "#3B3946", "#6C6878", "#A39FAB", "#D9D5CF", "#FFFDF7",
        "#5A2A2E", "#A63A3A", "#E2603F", "#F2A541", "#F7D774", "#F4C7B0",
        "#263C2E", "#3E7A4A", "#8DB85A", "#2B5D73", "#3D8FB5", "#A8D8E0",
        "#232A55", "#4F4AA0", "#8D5BA8", "#D87BA0", "#6E4A33", "#B07D52",
    ].compactMap(PixelColor.init(hex:))
}
