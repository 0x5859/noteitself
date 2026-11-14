import Foundation
import OSLog

/// Editor preferences persisted alongside the artwork in `pixel.json`.
struct PixelSettings {
    var color: PixelColor
    var palette: [PixelColor]
    var recentColors: [PixelColor]
    var showGrid: Bool

    static let `default` = PixelSettings(color: PixelColor.defaultPalette[0], palette: PixelColor.defaultPalette,
                                         recentColors: [], showGrid: true)
}

/// On-disk shape of `pixel.json`. Decoding tolerates missing optional fields.
private struct PixelFile: Codable {
    struct LayerEntry: Codable {
        var id: UUID
        var name: String
        var visible: Bool
        var opacity: Double

        init(id: UUID, name: String, visible: Bool, opacity: Double) {
            self.id = id; self.name = name; self.visible = visible; self.opacity = opacity
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Layer"
            visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
            opacity = min(max(try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1, 0), 1)
        }
    }

    var version: Int
    var width: Int
    var height: Int
    var layers: [LayerEntry]
    var activeLayer: UUID?
    var color: String?
    var palette: [String]?
    var recentColors: [String]?
    var showGrid: Bool?
}

/// Reads and writes the files this module owns inside a document package:
/// `pixel.json`, `pixel/<layerID>.png` and `thumb.png`.
enum PixelStore {
    static let log = Logger(subsystem: "noteitself", category: "Pixel")
    static let maxSide = 512

    /// Serial queue so writes never interleave and a synchronous save waits for pending ones.
    private static let queue = DispatchQueue(label: "noteitself.pixel.save", qos: .utility)

    private static func jsonURL(_ package: URL) -> URL { package.appendingPathComponent("pixel.json") }
    private static func layersURL(_ package: URL) -> URL { package.appendingPathComponent("pixel", isDirectory: true) }
    private static func layerURL(_ package: URL, _ id: UUID) -> URL {
        layersURL(package).appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    /// Loads the artwork, or a default 32×32 document when `pixel.json` is missing or unreadable.
    /// `isNew` is true when nothing usable was on disk.
    static func load(from package: URL) -> (document: PixelDocument, settings: PixelSettings, isNew: Bool) {
        guard let data = try? Data(contentsOf: jsonURL(package)) else {
            return (.blank(size: 32), .default, true)
        }
        guard let file = try? JSONDecoder().decode(PixelFile.self, from: data),
              (1...maxSide).contains(file.width), (1...maxSide).contains(file.height) else {
            log.error("pixel.json is unreadable; starting a blank artwork")
            return (.blank(size: 32), .default, true)
        }
        let count = file.width * file.height
        var seen = Set<UUID>()
        let layers = file.layers.filter { seen.insert($0.id).inserted }.map { entry -> PixelLayer in
            let pixels = (try? Data(contentsOf: layerURL(package, entry.id)))
                .flatMap { PixelRaster.decode($0, width: file.width, height: file.height) }
            return PixelLayer(id: entry.id, name: entry.name, isVisible: entry.visible, opacity: entry.opacity,
                              pixels: pixels ?? [UInt32](repeating: 0, count: count))
        }
        let document = PixelDocument(width: file.width, height: file.height, layers: layers,
                                     activeLayerID: file.activeLayer)
        let palette = (file.palette ?? []).compactMap(PixelColor.init(hex:))
        let settings = PixelSettings(
            color: file.color.flatMap(PixelColor.init(hex:)) ?? PixelSettings.default.color,
            palette: palette.isEmpty ? PixelColor.defaultPalette : palette,
            recentColors: (file.recentColors ?? []).compactMap(PixelColor.init(hex:)),
            showGrid: file.showGrid ?? true)
        return (document, settings, false)
    }

    /// Writes everything off the main thread (or blocks until written when `synchronously`).
    /// `ownedLayerIDs` lists every layer this session has known; PNGs of those no longer
    /// in the document are deleted, while unknown files are left alone.
    static func save(_ document: PixelDocument, settings: PixelSettings, ownedLayerIDs: Set<UUID>,
                     to package: URL, synchronously: Bool) {
        let work = { write(document, settings: settings, ownedLayerIDs: ownedLayerIDs, to: package) }
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Blocks until queued writes have finished.
    static func flush() { queue.sync {} }

    private static func write(_ document: PixelDocument, settings: PixelSettings, ownedLayerIDs: Set<UUID>,
                              to package: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: layersURL(package), withIntermediateDirectories: true)
            for layer in document.layers {
                guard let png = PixelRaster.pngData(layer.pixels, width: document.width, height: document.height)
                else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: layerURL(package, layer.id), options: .atomic)
            }
            let file = PixelFile(
                version: 1, width: document.width, height: document.height,
                layers: document.layers.map { .init(id: $0.id, name: $0.name, visible: $0.isVisible, opacity: $0.opacity) },
                activeLayer: document.activeLayerID, color: settings.color.hex,
                palette: settings.palette.map(\.hex), recentColors: settings.recentColors.map(\.hex),
                showGrid: settings.showGrid)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: jsonURL(package), options: .atomic)
            if let thumb = PixelRaster.thumbnailPNG(document) {
                try thumb.write(to: package.appendingPathComponent("thumb.png"), options: .atomic)
            }
            let current = Set(document.layers.map(\.id))
            for id in ownedLayerIDs.subtracting(current) {
                try? fileManager.removeItem(at: layerURL(package, id))
            }
        } catch {
            log.error("Saving pixel artwork failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
