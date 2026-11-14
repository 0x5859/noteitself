import SwiftUI
import UIKit

enum PixelTool: CaseIterable, Identifiable {
    case pencil, eraser, fill, eyedropper

    var id: Self { self }

    var symbol: String {
        switch self {
        case .pencil: return "pencil"
        case .eraser: return "eraser"
        case .eyedropper: return "eyedropper"
        case .fill:
            if #available(iOS 26.0, *) { return "paint.bucket.classic" }
            return "drop.halffull"
        }
    }

    var title: String {
        switch self {
        case .pencil: return "Pencil"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .eyedropper: return "Eyedropper"
        }
    }

    var hasBrushSize: Bool { self == .pencil || self == .eraser }
}

enum PixelExportFormat {
    case png, pdf
}

struct PixelLayerInfo: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isVisible: Bool
    var opacity: Double

    init(_ layer: PixelLayer) {
        id = layer.id; name = layer.name; isVisible = layer.isVisible; opacity = layer.opacity
    }
}

/// Owns the document, undo history and persistence. Only discrete state is
/// published; per-touch pixel writes go straight to `document` and the canvas
/// pulls the edited layer's image itself.
@MainActor
final class PixelEditorModel: ObservableObject {
    /// Square sizes offered as shortcuts.
    static let canvasPresets = [16, 32, 64, 128]
    /// Largest side the size panel accepts. Undo keeps whole-layer snapshots,
    /// so this also bounds memory (about 26 MB of history at 256 × 256).
    static let maxCanvasSide = 256
    static let maxBrushSize = 4

    @Published private(set) var tool: PixelTool = .pencil
    @Published private(set) var pencilSize = 1
    @Published private(set) var eraserSize = 1
    @Published private(set) var color: PixelColor
    @Published private(set) var recentColors: [PixelColor]
    @Published private(set) var showGrid: Bool
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var layers: [PixelLayerInfo]
    @Published private(set) var activeLayerID: UUID
    @Published private(set) var canvasWidth: Int
    @Published private(set) var canvasHeight: Int
    @Published var showColorPanel = false
    let palette: [PixelColor]

    private(set) var document: PixelDocument
    weak var canvas: PixelCanvasView?
    /// View the share sheet points at (the "…" button).
    weak var shareAnchor: UIView?

    private let packageURL: URL
    private var history = PixelHistory()
    private var ownedLayerIDs: Set<UUID>
    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    private var toolBeforeEraser = PixelTool.pencil
    private var toolBeforePicker = PixelTool.pencil
    private var pickedCustomColor = false
    private var opacityEditLayerID: UUID?

    private struct Stroke {
        let layerIndex: Int
        let tool: PixelTool
        let value: UInt32
        let size: Int
        var last: PixelPoint
        var changed: Bool
    }
    private var stroke: Stroke?
    private var strokeBase: PixelDocument?

    init(packageURL: URL) {
        self.packageURL = packageURL
        let loaded = PixelStore.load(from: packageURL)
        document = loaded.document
        palette = loaded.settings.palette
        color = loaded.settings.color
        recentColors = loaded.settings.recentColors
        showGrid = loaded.settings.showGrid
        layers = loaded.document.layers.map(PixelLayerInfo.init)
        activeLayerID = loaded.document.activeLayerID
        canvasWidth = loaded.document.width
        canvasHeight = loaded.document.height
        ownedLayerIDs = Set(loaded.document.layers.map(\.id))
        if loaded.isNew { markDirty() }
    }

    var isStroking: Bool { stroke != nil }

    var brushSize: Int {
        switch tool {
        case .pencil: return pencilSize
        case .eraser: return eraserSize
        case .fill, .eyedropper: return 1
        }
    }

    // MARK: Strokes (called by the canvas on every input event)

    /// Starts a stroke at `p`. Returns whether the active layer's pixels changed.
    func beginStroke(at p: PixelPoint) -> Bool {
        cancelStroke()
        endOpacityEdit()
        let index = document.activeIndex
        strokeBase = document
        var revealed = false
        if tool != .eyedropper, !document.layers[index].isVisible {
            document.layers[index].isVisible = true
            revealed = true
            canvas?.syncLayers(rebuildImages: false)
            publishState()
        }
        let value = tool == .eraser ? 0 : color.pixel
        let size = brushSize
        let painted: Bool
        switch tool {
        case .pencil, .eraser: painted = document.stamp(p, size: size, value: value, layer: index)
        case .fill: painted = document.fill(at: p, value: value, layer: index)
        case .eyedropper: painted = false
        }
        stroke = Stroke(layerIndex: index, tool: tool, value: value, size: size, last: p, changed: painted || revealed)
        return painted
    }

    /// Extends a pencil/eraser stroke to `p`. Returns whether pixels changed.
    func continueStroke(to p: PixelPoint) -> Bool {
        guard let s = stroke, s.tool == .pencil || s.tool == .eraser, p != s.last else { return false }
        let painted = document.line(from: s.last, to: p, size: s.size, value: s.value, layer: s.layerIndex)
        stroke?.last = p
        if painted { stroke?.changed = true }
        return painted
    }

    /// Commits the stroke as one undo step (or performs the eyedropper pick).
    func endStroke(at p: PixelPoint) {
        guard let s = stroke, let base = strokeBase else { return }
        stroke = nil
        strokeBase = nil
        if s.tool == .eyedropper {
            pick(at: p)
        } else if s.changed {
            history.record(base)
            ownedLayerIDs.formUnion(document.layers.map(\.id))
            publishState()
            markDirty()
        }
    }

    /// Reverts an in-progress stroke and resyncs the canvas.
    func cancelStroke() {
        guard let s = stroke, let base = strokeBase else { return }
        stroke = nil
        strokeBase = nil
        guard s.changed else { return }
        document = base
        canvas?.syncLayers()
        publishState()
    }

    func activeLayerImage() -> CGImage? {
        let index = document.activeIndex
        return PixelRaster.image(document.layers[index].pixels, width: document.width, height: document.height)
    }

    func thumbnail(for id: UUID) -> CGImage? {
        guard let index = document.index(of: id) else { return nil }
        return PixelRaster.image(document.layers[index].pixels, width: document.width, height: document.height)
    }

    private func pick(at p: PixelPoint) {
        if document.contains(p) {
            let value = document.composite(at: p.y * document.width + p.x)
            if PixelRGBA.alpha(value) > 0 { setColor(PixelColor(pixel: value)) }
        }
        tool = toolBeforePicker
    }

    // MARK: Tools and colour

    func select(_ newTool: PixelTool) {
        guard newTool != tool else { return }
        switch newTool {
        case .eyedropper: toolBeforePicker = tool == .eraser ? .pencil : tool
        case .eraser: toolBeforeEraser = tool == .eyedropper ? toolBeforePicker : tool
        case .pencil, .fill: break
        }
        tool = newTool
    }

    func toggleEraser() {
        if tool == .eraser { tool = toolBeforeEraser } else { select(.eraser) }
    }

    func setBrushSize(_ size: Int, for tool: PixelTool) {
        let size = min(max(size, 1), Self.maxBrushSize)
        if tool == .eraser { eraserSize = size } else { pencilSize = size }
        canvas?.refreshHover()
    }

    /// Applies an Apple Pencil double-tap / squeeze according to the user's system preference.
    func performPencilAction(_ action: UIPencilPreferredAction) {
        if #available(iOS 17.5, *), action == .runSystemShortcut { return }
        switch action {
        case .ignore: return
        case .showColorPalette: showColorPanel.toggle()
        default: toggleEraser()
        }
    }

    /// Picks a swatch; leaves the eraser so the next stroke paints with it.
    func choose(_ newColor: PixelColor) {
        setColor(newColor)
        if tool == .eraser { tool = toolBeforeEraser }
    }

    /// Live updates from the system colour picker; committed to recents by `commitCustomColor`.
    func setCustomColor(_ newColor: PixelColor) {
        guard newColor != color else { return }
        choose(newColor)
        pickedCustomColor = true
    }

    func commitCustomColor() {
        guard pickedCustomColor else { return }
        pickedCustomColor = false
        guard !palette.contains(color) else { return }
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > 6 { recentColors.removeLast(recentColors.count - 6) }
        markDirty()
    }

    private func setColor(_ newColor: PixelColor) {
        guard newColor != color else { return }
        color = newColor
        markDirty()
    }

    func setShowGrid(_ visible: Bool) {
        showGrid = visible
        canvas?.setGridVisible(visible)
        markDirty()
    }

    func zoomToFit() { canvas?.fitToScreen() }

    // MARK: Layers and document operations (one undo step each)

    func selectLayer(_ id: UUID) {
        guard id != document.activeLayerID, document.index(of: id) != nil else { return }
        cancelStroke()
        endOpacityEdit()
        document.activeLayerID = id
        publishState()
        markDirty()
    }

    func toggleVisibility(_ id: UUID) {
        commit { doc in
            if let i = doc.index(of: id) { doc.layers[i].isVisible.toggle() }
        }
    }

    func addLayer() {
        commit { doc in
            let layer = PixelLayer(id: UUID(), name: doc.nextLayerName, isVisible: true, opacity: 1, pixels: doc.emptyPixels)
            doc.layers.insert(layer, at: doc.activeIndex + 1)
            doc.activeLayerID = layer.id
        }
    }

    func duplicateLayer() {
        commit { doc in
            let source = doc.layers[doc.activeIndex]
            let copy = PixelLayer(id: UUID(), name: "\(source.name) Copy", isVisible: source.isVisible,
                                  opacity: source.opacity, pixels: source.pixels)
            doc.layers.insert(copy, at: doc.activeIndex + 1)
            doc.activeLayerID = copy.id
        }
    }

    func deleteLayer() {
        guard document.layers.count > 1 else { return }
        commit { doc in
            let index = doc.activeIndex
            doc.layers.remove(at: index)
            doc.activeLayerID = doc.layers[max(0, index - 1)].id
        }
    }

    /// Moves the active layer one step towards the top (`up`) or bottom.
    func moveLayer(up: Bool) {
        commit { doc in
            let index = doc.activeIndex
            let target = up ? index + 1 : index - 1
            guard doc.layers.indices.contains(target) else { return }
            doc.layers.swapAt(index, target)
        }
    }

    /// Live opacity changes; a run of changes to one layer is a single undo step.
    func setOpacity(_ value: Double) {
        cancelStroke()
        let index = document.activeIndex
        let value = min(max(value, 0), 1)
        guard document.layers[index].opacity != value else { return }
        if opacityEditLayerID != document.activeLayerID {
            history.record(document)
            opacityEditLayerID = document.activeLayerID
        }
        document.layers[index].opacity = value
        canvas?.syncLayers(rebuildImages: false)
        publishState()
        markDirty()
    }

    func endOpacityEdit() { opacityEditLayerID = nil }

    func clearLayer() {
        commit { doc in doc.layers[doc.activeIndex].pixels = doc.emptyPixels }
    }

    /// Changes the canvas size without scaling the artwork: the canvas grows
    /// or is cropped away from `anchor`. One undo step.
    func resizeCanvas(width: Int, height: Int, anchor: PixelAnchor = .centre) {
        let side = 1...PixelEditorModel.maxCanvasSide
        let width = min(max(width, side.lowerBound), side.upperBound)
        let height = min(max(height, side.lowerBound), side.upperBound)
        guard width != document.width || height != document.height else { return }
        commit { doc in doc = doc.resized(width: width, height: height, anchor: anchor) }
    }

    func undo() {
        cancelStroke()
        endOpacityEdit()
        guard let previous = history.undo(from: document) else { return }
        document = previous
        documentDidChange()
    }

    func redo() {
        cancelStroke()
        endOpacityEdit()
        guard let next = history.redo(from: document) else { return }
        document = next
        documentDidChange()
    }

    private func commit(_ change: (inout PixelDocument) -> Void) {
        cancelStroke()
        endOpacityEdit()
        let before = document
        change(&document)
        guard document != before else { return }
        history.record(before)
        ownedLayerIDs.formUnion(document.layers.map(\.id))
        documentDidChange()
    }

    private func documentDidChange() {
        canvas?.syncLayers()
        publishState()
        markDirty()
    }

    private func publishState() {
        let infos = document.layers.map(PixelLayerInfo.init)
        if infos != layers { layers = infos }
        if activeLayerID != document.activeLayerID { activeLayerID = document.activeLayerID }
        if canvasWidth != document.width { canvasWidth = document.width }
        if canvasHeight != document.height { canvasHeight = document.height }
        if canUndo != history.canUndo { canUndo = history.canUndo }
        if canRedo != history.canRedo { canRedo = history.canRedo }
    }

    // MARK: Export

    func export(_ format: PixelExportFormat) {
        cancelStroke()
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("PixelExport", isDirectory: true)
        let name = packageURL.deletingPathExtension().lastPathComponent
        let url = directory.appendingPathComponent(name.isEmpty ? "Pixel Art" : name)
            .appendingPathExtension(format == .png ? "png" : "pdf")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            switch format {
            case .png: try PixelRaster.writePNG(document, to: url)
            case .pdf: try PixelRaster.writePDF(document, to: url)
            }
        } catch {
            PixelStore.log.error("Export failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        presentShareSheet(for: url)
    }

    private func presentShareSheet(for url: URL) {
        guard let anchor = shareAnchor ?? canvas, var presenter = anchor.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed { presenter = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
        }
        presenter.present(sheet, animated: true)
    }

    // MARK: Persistence

    private var settings: PixelSettings {
        PixelSettings(color: color, palette: palette, recentColors: recentColors, showGrid: showGrid)
    }

    private func markDirty() {
        isDirty = true
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            if self.isStroking { self.scheduleAutosave() } else { self.save(synchronously: false) }
        }
    }

    /// Writes pending changes. A synchronous call also waits for earlier background writes.
    func save(synchronously: Bool) {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else {
            if synchronously { PixelStore.flush() }
            return
        }
        isDirty = false
        PixelStore.save(strokeBase ?? document, settings: settings, ownedLayerIDs: ownedLayerIDs,
                        to: packageURL, synchronously: synchronously)
    }

    /// Final save before the editor goes away.
    func close() {
        cancelStroke()
        commitCustomColor()
        save(synchronously: true)
    }
}
