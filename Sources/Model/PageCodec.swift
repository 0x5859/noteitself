import CoreGraphics
import Foundation

/// Compact binary format for one page (its layers and strokes).
///
///     header   "SUMI" (format tag kept from early builds) · version u8 · flags u8 (bit 0 = LZFSE payload)
///     payload  u16 layerCount, then per layer:
///                uuid(16) · name · flags u8 (1 visible, 2 image) · opacity f32
///                [image: asset name · frame 4×f64]
///                u32 strokeCount, then per stroke:
///                  brush u8 · colour u32 · u32 pointCount · points (4×f32 each)
enum PageCodec {
    enum CodecError: Error { case badHeader, truncated, unsupportedVersion }

    private static let magic: [UInt8] = Array("SUMI".utf8)
    private static let version: UInt8 = 1

    static func encode(_ layers: [Layer]) -> Data {
        var w = Writer()
        w.u16(UInt16(min(layers.count, Int(UInt16.max))))
        for layer in layers.prefix(Int(UInt16.max)) {
            w.uuid(layer.id)
            w.string(layer.name)
            w.u8((layer.isVisible ? 1 : 0) | (layer.isImage ? 2 : 0))
            w.f32(layer.opacity)
            if let image = layer.image {
                w.string(image.asset)
                w.f64(Double(image.frame.minX)); w.f64(Double(image.frame.minY))
                w.f64(Double(image.frame.width)); w.f64(Double(image.frame.height))
            }
            w.u32(UInt32(layer.strokes.count))
            for stroke in layer.strokes {
                w.u8(stroke.brush.rawValue)
                w.u32(stroke.color.value)
                w.u32(UInt32(stroke.points.count))
                stroke.points.withUnsafeBytes { w.data.append(contentsOf: $0) }
            }
        }

        var out = Data(magic)
        out.append(version)
        if let packed = try? (w.data as NSData).compressed(using: .lzfse) as Data, packed.count < w.data.count {
            out.append(1)
            out.append(packed)
        } else {
            out.append(0)
            out.append(w.data)
        }
        return out
    }

    static func decode(_ data: Data) throws -> [Layer] {
        guard data.count >= 6, Array(data.prefix(4)) == magic else { throw CodecError.badHeader }
        guard data[data.startIndex + 4] == version else { throw CodecError.unsupportedVersion }
        let flags = data[data.startIndex + 5]
        var payload = data.subdata(in: (data.startIndex + 6)..<data.endIndex)
        if flags & 1 != 0 {
            payload = try (payload as NSData).decompressed(using: .lzfse) as Data
        }

        var r = Reader(data: payload)
        let layerCount = Int(try r.u16())
        var layers: [Layer] = []
        layers.reserveCapacity(layerCount)
        for _ in 0..<layerCount {
            let id = try r.uuid()
            let name = try r.string()
            let layerFlags = try r.u8()
            let opacity = try r.f32()
            var image: ImageRef?
            if layerFlags & 2 != 0 {
                let asset = try r.string()
                let x = try r.f64(), y = try r.f64(), w = try r.f64(), h = try r.f64()
                image = ImageRef(asset: asset, frame: CGRect(x: x, y: y, width: w, height: h))
            }
            let strokeCount = Int(try r.u32())
            var strokes: [Stroke] = []
            strokes.reserveCapacity(min(strokeCount, 1 << 20))
            for _ in 0..<strokeCount {
                let brush = BrushKind(rawValue: try r.u8()) ?? .pen
                let color = RGBA8(try r.u32())
                let pointCount = Int(try r.u32())
                let points = try r.points(pointCount)
                strokes.append(Stroke(brush: brush, color: color, points: points))
            }
            var layer = Layer(id: id, name: name, strokes: strokes, image: image)
            layer.isVisible = layerFlags & 1 != 0
            layer.opacity = max(0, min(1, opacity))
            layers.append(layer)
        }
        return layers
    }

    // MARK: Primitive IO (little-endian)

    private struct Writer {
        var data = Data()

        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func f32(_ v: Float) { u32(v.bitPattern) }
        mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        mutating func uuid(_ v: UUID) { withUnsafeBytes(of: v.uuid) { data.append(contentsOf: $0) } }
        mutating func string(_ v: String) {
            let bytes = Array(v.utf8.prefix(Int(UInt16.max)))
            u16(UInt16(bytes.count))
            data.append(contentsOf: bytes)
        }
    }

    private struct Reader {
        let data: Data
        var offset = 0

        private mutating func take(_ count: Int) throws -> Range<Data.Index> {
            guard count >= 0, offset + count <= data.count else { throw CodecError.truncated }
            let range = (data.startIndex + offset)..<(data.startIndex + offset + count)
            offset += count
            return range
        }

        private mutating func scalar<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let range = try take(MemoryLayout<T>.size)
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: range) }
            return T(littleEndian: value)
        }

        mutating func u8() throws -> UInt8 { try scalar(UInt8.self) }
        mutating func u16() throws -> UInt16 { try scalar(UInt16.self) }
        mutating func u32() throws -> UInt32 { try scalar(UInt32.self) }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func f64() throws -> Double { Double(bitPattern: try scalar(UInt64.self)) }

        mutating func uuid() throws -> UUID {
            let range = try take(16)
            var raw: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            _ = withUnsafeMutableBytes(of: &raw) { data.copyBytes(to: $0, from: range) }
            return UUID(uuid: raw)
        }

        mutating func string() throws -> String {
            let range = try take(Int(try u16()))
            return String(decoding: data[range], as: UTF8.self)
        }

        mutating func points(_ count: Int) throws -> [StrokePoint] {
            let range = try take(count * MemoryLayout<StrokePoint>.stride)
            guard count > 0 else { return [] }
            return [StrokePoint](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer), from: range)
                initialized = count
            }
        }
    }
}
