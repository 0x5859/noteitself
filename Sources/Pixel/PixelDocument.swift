import Foundation

struct PixelLayer: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isVisible: Bool
    var opacity: Double
    /// Row-major premultiplied pixels (see `PixelRGBA`), `width * height` long.
    var pixels: [UInt32]

    /// Opacity as an 8-bit factor for compositing.
    var opacity8: UInt32 { UInt32((min(max(opacity, 0), 1) * 255).rounded()) }
}

/// The part of the artwork that stays where it is when the canvas is resized:
/// one of nine positions, from the top-left corner to the bottom-right.
struct PixelAnchor: Hashable {
    /// 0 = left, 1 = centre, 2 = right.
    var column: Int
    /// 0 = top, 1 = centre, 2 = bottom.
    var row: Int

    static let centre = PixelAnchor(column: 1, row: 1)
    static let topLeft = PixelAnchor(column: 0, row: 0)

    /// How far existing pixels shift along one axis.
    fileprivate func offset(from old: Int, to new: Int, position: Int) -> Int {
        switch position {
        case 0: return 0
        case 1: return (new - old) / 2
        default: return new - old
        }
    }
}

/// The undoable state of an artwork. A value type: copies share pixel buffers
/// until one side writes, which keeps undo snapshots cheap.
struct PixelDocument: Equatable {
    private(set) var width: Int
    private(set) var height: Int
    /// Bottom-most layer first.
    var layers: [PixelLayer]
    var activeLayerID: UUID

    init(width: Int, height: Int, layers: [PixelLayer], activeLayerID: UUID?) {
        self.width = width
        self.height = height
        if layers.isEmpty {
            let layer = PixelLayer(id: UUID(), name: "Layer 1", isVisible: true, opacity: 1,
                                   pixels: [UInt32](repeating: 0, count: width * height))
            self.layers = [layer]
        } else {
            self.layers = layers
        }
        let ids = self.layers.map(\.id)
        self.activeLayerID = activeLayerID.flatMap { ids.contains($0) ? $0 : nil } ?? ids[ids.count - 1]
    }

    static func blank(size: Int) -> PixelDocument {
        PixelDocument(width: size, height: size, layers: [], activeLayerID: nil)
    }

    var activeIndex: Int { layers.firstIndex { $0.id == activeLayerID } ?? layers.count - 1 }

    var emptyPixels: [UInt32] { [UInt32](repeating: 0, count: width * height) }

    func contains(_ p: PixelPoint) -> Bool { p.x >= 0 && p.y >= 0 && p.x < width && p.y < height }

    func index(of id: UUID) -> Int? { layers.firstIndex { $0.id == id } }

    var nextLayerName: String {
        let numbers = layers.compactMap { $0.name.hasPrefix("Layer ") ? Int($0.name.dropFirst(6)) : nil }
        return "Layer \((numbers.max() ?? 0) + 1)"
    }

    // MARK: Painting

    /// Writes a `size`×`size` square centred on `p`; returns whether anything changed.
    mutating func stamp(_ p: PixelPoint, size: Int, value: UInt32, layer index: Int) -> Bool {
        let offset = (size - 1) / 2
        let x0 = max(0, p.x - offset), x1 = min(width, p.x - offset + size)
        let y0 = max(0, p.y - offset), y1 = min(height, p.y - offset + size)
        guard x0 < x1, y0 < y1 else { return false }
        let w = width
        var changed = false
        layers[index].pixels.withUnsafeMutableBufferPointer { buf in
            for y in y0..<y1 {
                for i in (y * w + x0)..<(y * w + x1) where buf[i] != value {
                    buf[i] = value
                    changed = true
                }
            }
        }
        return changed
    }

    /// Bresenham line from `a` (exclusive, already stamped) to `b` (inclusive).
    mutating func line(from a: PixelPoint, to b: PixelPoint, size: Int, value: UInt32, layer index: Int) -> Bool {
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        var p = a
        var changed = false
        while p != b {
            let e2 = 2 * err
            if e2 >= dy { err += dy; p.x += sx }
            if e2 <= dx { err += dx; p.y += sy }
            if stamp(p, size: size, value: value, layer: index) { changed = true }
        }
        return changed
    }

    /// 4-connected flood fill of the region sharing `p`'s exact colour.
    mutating func fill(at p: PixelPoint, value: UInt32, layer index: Int) -> Bool {
        guard contains(p) else { return false }
        let w = width, count = width * height
        let start = p.y * w + p.x
        let target = layers[index].pixels[start]
        guard target != value else { return false }
        layers[index].pixels.withUnsafeMutableBufferPointer { buf in
            var stack = [start]
            buf[start] = value
            while let i = stack.popLast() {
                let x = i % w
                if x > 0, buf[i - 1] == target { buf[i - 1] = value; stack.append(i - 1) }
                if x < w - 1, buf[i + 1] == target { buf[i + 1] = value; stack.append(i + 1) }
                if i >= w, buf[i - w] == target { buf[i - w] = value; stack.append(i - w) }
                if i + w < count, buf[i + w] == target { buf[i + w] = value; stack.append(i + w) }
            }
        }
        return true
    }

    // MARK: Compositing

    /// The composited premultiplied colour of visible layers at a pixel index.
    func composite(at i: Int) -> UInt32 {
        var out: UInt32 = 0
        for layer in layers where layer.isVisible {
            out = PixelRGBA.over(PixelRGBA.scaled(layer.pixels[i], by: layer.opacity8), out)
        }
        return out
    }

    /// All visible layers composited into one premultiplied buffer.
    func flattened() -> [UInt32] {
        var out = emptyPixels
        for layer in layers where layer.isVisible && layer.opacity8 > 0 {
            let factor = layer.opacity8
            out.withUnsafeMutableBufferPointer { dst in
                layer.pixels.withUnsafeBufferPointer { src in
                    for i in 0..<dst.count where src[i] != 0 {
                        dst[i] = PixelRGBA.over(PixelRGBA.scaled(src[i], by: factor), dst[i])
                    }
                }
            }
        }
        return out
    }

    /// A copy at a new size. Pixels are neither scaled nor moved relative to
    /// `anchor`: the canvas grows or is cropped on the other sides.
    func resized(width newWidth: Int, height newHeight: Int, anchor: PixelAnchor = .centre) -> PixelDocument {
        let dx = anchor.offset(from: width, to: newWidth, position: anchor.column)
        let dy = anchor.offset(from: height, to: newHeight, position: anchor.row)
        var copy = self
        copy.width = newWidth
        copy.height = newHeight
        for index in copy.layers.indices {
            let old = layers[index].pixels
            var out = [UInt32](repeating: 0, count: newWidth * newHeight)
            for y in max(0, -dy)..<min(height, newHeight - dy) {
                for x in max(0, -dx)..<min(width, newWidth - dx) {
                    out[(y + dy) * newWidth + x + dx] = old[y * width + x]
                }
            }
            copy.layers[index].pixels = out
        }
        return copy
    }
}

/// Bounded linear undo history of whole-document snapshots. Consecutive
/// snapshots share every layer buffer that did not change between them, so
/// each step costs roughly one layer's pixels (64 KB at 128×128, 256 KB at 256×256).
struct PixelHistory {
    static let limit = 100

    private var undoStack: [PixelDocument] = []
    private var redoStack: [PixelDocument] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(_ state: PixelDocument) {
        undoStack.append(state)
        if undoStack.count > Self.limit { undoStack.removeFirst(undoStack.count - Self.limit) }
        redoStack.removeAll()
    }

    mutating func undo(from current: PixelDocument) -> PixelDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(from current: PixelDocument) -> PixelDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }
}
