import Combine
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One undoable edit.
enum PageChange {
    /// The common case, kept tiny: a stroke was added to a layer.
    case append(pageID: UUID, layerID: UUID, stroke: Stroke)
    /// Anything else: the page's layers before and after. Strokes are shared
    /// immutable objects, so a snapshot only costs the arrays of references.
    case replace(pageID: UUID, before: [Layer], after: [Layer])
}

struct BrushSpec {
    let kind: BrushKind
    let color: RGBA8
    let width: Double
    let smoothing: Double
    let paper: Double
    let naturalInk: Bool
}

/// Editing state for one open document: tools, undo history, layers, pages
/// and saving. SwiftUI observes it; the canvas view drives it.
final class EditorSession: ObservableObject {
    let document: NoteDocument
    let hasPDF: Bool
    weak var canvas: CanvasView?

    @Published var box: ToolBox {
        didSet {
            guard box != oldValue else { return }
            box.save()
            canvas?.toolsChanged()
        }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Bumped whenever layers or pages change so panels refresh.
    @Published private(set) var structure = 0
    @Published private(set) var activePageIndex = 0
    @Published var isExporting = false

    private(set) var pageFrames: [CGRect] = []
    private(set) var contentBounds: CGRect = .null

    private var undoStack: [PageChange] = []
    private var redoStack: [PageChange] = []
    private var previousTool: Tool = .pen
    private var lastInk: Tool = .pen
    private var eraseStart: (page: Page, layers: [Layer])?
    private var eraseChanged = false
    private var saveItem: DispatchWorkItem?
    private var editedSinceThumbnail = false
    private var observers: [NSObjectProtocol] = []

    static let pageGap: CGFloat = 14
    private static let undoLimit = 120

    init(document: NoteDocument) {
        self.document = document
        self.hasPDF = document.hasPDF
        let saved = ToolBox.load()
        box = saved
        lastInk = saved.tool == .eraser ? .pen : saved.tool
        previousTool = lastInk
        layoutPages()
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flush()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Layout

    func layoutPages() {
        guard !document.isInfinite else {
            pageFrames = []
            contentBounds = .null
            return
        }
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for page in document.pages {
            frames.append(CGRect(x: -page.size.width / 2, y: y, width: page.size.width, height: page.size.height))
            y += page.size.height + EditorSession.pageGap
        }
        pageFrames = frames
        contentBounds = frames.reduce(CGRect.null) { $0.union($1) }
    }

    /// The page under a world point and that page's origin in world space.
    func pageHit(_ world: CGPoint) -> (index: Int, origin: CGPoint)? {
        if document.isInfinite { return (0, .zero) }
        for (index, frame) in pageFrames.enumerated() where frame.contains(world) {
            return (index, frame.origin)
        }
        return nil
    }

    func origin(ofPage index: Int) -> CGPoint {
        pageFrames.indices.contains(index) ? pageFrames[index].origin : .zero
    }

    // MARK: Pages and layers

    func loadedPage(_ index: Int) -> Page? {
        guard document.pages.indices.contains(index) else { return nil }
        let page = document.pages[index]
        document.ensureLoaded(page)
        return page
    }

    private func page(withID id: UUID) -> Page? {
        document.pages.first { $0.id == id }
    }

    func setActivePage(_ index: Int) {
        guard index != activePageIndex, document.pages.indices.contains(index) else { return }
        activePageIndex = index
        canvas?.setNeedsBase()
    }

    func activeLayerIndex(in page: Page) -> Int {
        if let id = page.activeLayerID, let index = page.layers.firstIndex(where: { $0.id == id }) {
            return index
        }
        return page.layers.lastIndex(where: { !$0.isImage }) ?? max(0, page.layers.count - 1)
    }

    /// Layers of the active page, bottom first.
    var layers: [Layer] { loadedPage(activePageIndex)?.layers ?? [] }

    var activeLayerID: UUID? {
        guard let page = loadedPage(activePageIndex), !page.layers.isEmpty else { return nil }
        return page.layers[activeLayerIndex(in: page)].id
    }

    /// The active layer when it is an image being positioned.
    var activeImage: (pageIndex: Int, layerIndex: Int, frame: CGRect)? {
        guard let page = loadedPage(activePageIndex), !page.layers.isEmpty else { return nil }
        let index = activeLayerIndex(in: page)
        guard let image = page.layers[index].image else { return nil }
        return (activePageIndex, index, image.frame)
    }

    /// Releases strokes and GPU geometry of clean pages far from the viewport.
    func trimLoadedPages(keeping visible: Range<Int>) {
        let keep = (visible.lowerBound - 6)..<(visible.upperBound + 6)
        for (index, page) in document.pages.enumerated()
        where page.isLoaded && !page.isDirty && !keep.contains(index) && index != activePageIndex {
            canvas?.renderer?.dropMeshes(for: page.layers.map(\.id))
            document.unload(page)
        }
    }

    // MARK: Tools

    func select(_ tool: Tool) {
        guard tool != box.tool else { return }
        previousTool = box.tool
        if tool != .eraser { lastInk = tool }
        box.tool = tool
    }

    func toggleEraser() {
        select(box.tool == .eraser ? lastInk : .eraser)
    }

    func perform(_ action: PencilAction) {
        switch action {
        case .eraser: toggleEraser()
        case .previousTool: select(previousTool)
        case .undo: undo()
        case .none: break
        }
    }

    /// The tool whose colours the toolbar shows (the last ink tool while erasing).
    var colorTool: Tool { box.tool == .eraser ? lastInk : box.tool }

    /// Picks one of the quick colours; from the eraser this also returns to ink.
    func selectColor(slot: Int) {
        if box.tool == .eraser { select(lastInk) }
        box.colorIndex[box.tool.rawValue] = slot
    }

    func brushSpec() -> BrushSpec? {
        guard let kind = box.tool.brush else { return nil }
        let settings = box[box.tool]
        var color = box.color(for: box.tool)
        if kind == .highlighter { color = color.withAlpha(settings.opacity) }
        return BrushSpec(kind: kind, color: color, width: settings.width, smoothing: settings.smoothing,
                         paper: settings.paper, naturalInk: settings.naturalInk)
    }

    /// The first Pencil touch switches fingers from drawing to scrolling,
    /// unless the user already chose a finger mode.
    func notePencilSeen() {
        guard !box.fingerModeChosen else { return }
        box.fingerMode = .pan
        box.fingerModeChosen = true
    }

    // MARK: Ink edits

    func commit(_ stroke: Stroke, pageIndex: Int) {
        guard let page = loadedPage(pageIndex), !page.layers.isEmpty else { return }
        let index = activeLayerIndex(in: page)
        guard !page.layers[index].isImage else { return }
        let old = page.layers[index].revision
        let wasHidden = !page.layers[index].isVisible
        page.layers[index].strokes.append(stroke)
        page.layers[index].isVisible = true
        page.layers[index].touch()
        canvas?.renderer?.strokeAppended(stroke, layerID: page.layers[index].id, from: old, to: page.layers[index].revision)
        record(.append(pageID: page.id, layerID: page.layers[index].id, stroke: stroke))
        markDirty(page)
        if wasHidden { structure += 1 }
    }

    func beginErase(pageIndex: Int) {
        guard let page = loadedPage(pageIndex) else { return }
        eraseStart = (page, page.layers)
        eraseChanged = false
    }

    /// Erases along a segment given in page coordinates. Returns true when ink changed.
    @discardableResult
    func erase(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Bool {
        guard let page = eraseStart?.page, !page.layers.isEmpty else { return false }
        let index = activeLayerIndex(in: page)
        guard !page.layers[index].isImage, page.layers[index].isVisible else { return false }
        var strokes = page.layers[index].strokes
        guard !strokes.isEmpty else { return false }

        let distance = hypot(b.x - a.x, b.y - a.y)
        let steps = min(256, max(1, Int((distance / max(radius * 0.5, 0.01)).rounded(.up))))
        let r = Float(radius)
        let mode = box.eraserMode
        var changed = false

        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let cx = Float(a.x + (b.x - a.x) * t)
            let cy = Float(a.y + (b.y - a.y) * t)
            var out: [Stroke]?
            for (i, stroke) in strokes.enumerated() {
                let pieces: [Stroke]?
                switch mode {
                case .precise: pieces = Eraser.cut(stroke, cx: cx, cy: cy, radius: r)
                case .stroke: pieces = Eraser.hits(stroke, cx: cx, cy: cy, radius: r) ? [] : nil
                }
                if let pieces {
                    if out == nil { out = Array(strokes[..<i]) }
                    out?.append(contentsOf: pieces)
                } else {
                    out?.append(stroke)
                }
            }
            if let out {
                strokes = out
                changed = true
            }
        }

        guard changed else { return false }
        page.layers[index].strokes = strokes
        page.layers[index].touch()
        eraseChanged = true
        return true
    }

    func endErase() {
        defer { eraseStart = nil }
        guard let start = eraseStart, eraseChanged else { return }
        record(.replace(pageID: start.page.id, before: start.layers, after: start.page.layers))
        markDirty(start.page)
        if box.eraserAutoReturn, box.tool == .eraser { select(lastInk) }
    }

    func cancelErase() {
        defer { eraseStart = nil }
        guard let start = eraseStart, eraseChanged else { return }
        start.page.layers = start.layers
        canvas?.setNeedsBase()
    }

    // MARK: Undo

    private func record(_ change: PageChange) {
        undoStack.append(change)
        if undoStack.count > EditorSession.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        if canUndo != !undoStack.isEmpty { canUndo = !undoStack.isEmpty }
        if canRedo != !redoStack.isEmpty { canRedo = !redoStack.isEmpty }
    }

    func undo() {
        guard let change = undoStack.popLast() else { return }
        apply(change, reverse: true)
        redoStack.append(change)
        refreshUndoFlags()
    }

    func redo() {
        guard let change = redoStack.popLast() else { return }
        apply(change, reverse: false)
        undoStack.append(change)
        refreshUndoFlags()
    }

    private func apply(_ change: PageChange, reverse: Bool) {
        switch change {
        case let .append(pageID, layerID, stroke):
            guard let page = page(withID: pageID) else { return }
            document.ensureLoaded(page)
            guard let index = page.layers.firstIndex(where: { $0.id == layerID }) else { return }
            if reverse {
                if let at = page.layers[index].strokes.lastIndex(where: { $0 === stroke }) {
                    page.layers[index].strokes.remove(at: at)
                }
            } else {
                page.layers[index].strokes.append(stroke)
            }
            page.layers[index].touch()
            markDirty(page)
        case let .replace(pageID, before, after):
            guard let page = page(withID: pageID) else { return }
            page.layers = reverse ? before : after
            page.isLoaded = true
            page.ensureDefaultLayer()
            markDirty(page)
        }
        structure += 1
        canvas?.setNeedsBase()
    }

    // MARK: Layer operations

    private func mutateLayers(_ page: Page, _ body: (inout [Layer]) -> Void) {
        let before = page.layers
        body(&page.layers)
        page.ensureDefaultLayer()
        record(.replace(pageID: page.id, before: before, after: page.layers))
        markDirty(page)
        structure += 1
        canvas?.setNeedsBase()
    }

    func selectLayer(_ id: UUID) {
        guard let page = loadedPage(activePageIndex) else { return }
        page.activeLayerID = id
        structure += 1
        canvas?.setNeedsBase()
    }

    func addLayer() {
        guard let page = loadedPage(activePageIndex) else { return }
        let index = page.layers.isEmpty ? 0 : activeLayerIndex(in: page) + 1
        let number = page.layers.filter { !$0.isImage }.count + 1
        let layer = Layer(name: "Layer \(number)")
        page.activeLayerID = layer.id
        mutateLayers(page) { $0.insert(layer, at: index) }
    }

    func deleteLayer(_ id: UUID) {
        guard let page = loadedPage(activePageIndex), page.layers.count > 1,
              let index = page.layers.firstIndex(where: { $0.id == id }) else { return }
        canvas?.renderer?.dropMeshes(for: [id])
        if page.activeLayerID == id { page.activeLayerID = nil }
        mutateLayers(page) { $0.remove(at: index) }
    }

    func toggleVisibility(_ id: UUID) {
        guard let page = loadedPage(activePageIndex),
              let index = page.layers.firstIndex(where: { $0.id == id }) else { return }
        mutateLayers(page) { $0[index].isVisible.toggle() }
    }

    /// Continuous (slider) change; not recorded for undo.
    func setOpacity(_ value: Float, layer id: UUID) {
        guard let page = loadedPage(activePageIndex),
              let index = page.layers.firstIndex(where: { $0.id == id }) else { return }
        page.layers[index].opacity = max(0, min(1, value))
        markDirty(page)
        structure += 1
        canvas?.setNeedsBase()
    }

    /// Reorders layers; offsets are in storage (bottom-first) order.
    func moveLayer(from source: Int, to destination: Int) {
        guard let page = loadedPage(activePageIndex),
              page.layers.indices.contains(source), destination != source else { return }
        mutateLayers(page) { layers in
            let layer = layers.remove(at: source)
            layers.insert(layer, at: min(max(destination, 0), layers.count))
        }
    }

    // MARK: Images (tracing references)

    /// Adds an image as a half-transparent layer beneath the current drawing
    /// layer and selects it so it can be positioned.
    func insertImage(data: Data) {
        guard let page = loadedPage(activePageIndex), let canvas,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let size = EditorSession.pixelSize(of: source) else { return }
        let ext = (CGImageSourceGetType(source) as String?)
            .flatMap { UTType($0)?.preferredFilenameExtension } ?? "img"
        guard let asset = try? document.addAsset(data, fileExtension: ext) else { return }

        var area = canvas.visibleRect(inPage: activePageIndex)
        if !document.isInfinite {
            area = area.intersection(CGRect(origin: .zero, size: page.size))
            if area.isNull || area.isEmpty { area = CGRect(origin: .zero, size: page.size) }
        }
        let scale = min(area.width * 0.7 / size.width, area.height * 0.7 / size.height)
        let frame = CGRect(
            x: area.midX - size.width * scale / 2, y: area.midY - size.height * scale / 2,
            width: size.width * scale, height: size.height * scale
        )

        let index = page.layers.isEmpty ? 0 : activeLayerIndex(in: page)
        var layer = Layer(name: "Image", image: ImageRef(asset: asset, frame: frame))
        layer.opacity = 0.5
        page.activeLayerID = layer.id
        mutateLayers(page) { $0.insert(layer, at: index) }
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    func beginImageEdit() -> [Layer]? {
        loadedPage(activePageIndex)?.layers
    }

    func setImageFrame(_ frame: CGRect) {
        guard let image = activeImage, let page = loadedPage(image.pageIndex) else { return }
        page.layers[image.layerIndex].image?.frame = frame
    }

    func endImageEdit(before: [Layer]) {
        guard let page = loadedPage(activePageIndex) else { return }
        record(.replace(pageID: page.id, before: before, after: page.layers))
        markDirty(page)
    }

    /// Leaves image positioning: selects the drawing layer above the image,
    /// creating one if needed.
    func finishImagePlacement() {
        guard let image = activeImage, let page = loadedPage(image.pageIndex) else { return }
        if let above = page.layers[(image.layerIndex + 1)...].first(where: { !$0.isImage }) {
            selectLayer(above.id)
        } else {
            addLayer()
        }
    }

    // MARK: Page operations

    private func pagesChanged() {
        layoutPages()
        canvas?.renderer?.textures.invalidateDetail()
        structure += 1
        canvas?.layoutChanged()
        scheduleSave()
    }

    func addPage() {
        guard !document.isInfinite, let current = loadedPage(activePageIndex) else { return }
        let paper = document.pages.first(where: { $0.pdf == nil })?.paper ?? .blank
        let page = Page(size: current.size, paper: paper)
        document.insert(page, at: activePageIndex + 1)
        editedSinceThumbnail = true
        activePageIndex += 1
        pagesChanged()
        canvas?.scroll(toPage: activePageIndex)
    }

    func deleteActivePage() {
        guard !document.isInfinite, document.pages.count > 1,
              let page = loadedPage(activePageIndex) else { return }
        canvas?.renderer?.dropMeshes(for: page.layers.map(\.id))
        document.removePage(at: activePageIndex)
        editedSinceThumbnail = true
        activePageIndex = min(activePageIndex, document.pages.count - 1)
        pagesChanged()
    }

    var activePaper: PaperStyle { document.pages.first(where: { $0.pdf == nil })?.paper ?? .blank }

    /// True when at least one page can show a paper pattern.
    var hasPlainPages: Bool { document.pages.contains { $0.pdf == nil } }

    /// Paper is a property of the whole notebook: every non-PDF page gets it,
    /// and new pages inherit it.
    func setPaper(_ style: PaperStyle) {
        var changed = false
        for page in document.pages where page.pdf == nil && page.paper != style {
            page.paper = style
            changed = true
        }
        guard changed else { return }
        document.markManifestDirty()
        editedSinceThumbnail = true
        structure += 1
        canvas?.setNeedsBase()
        scheduleSave()
    }

    // MARK: Saving

    private func markDirty(_ page: Page) {
        page.isDirty = true
        editedSinceThumbnail = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.document.save(synchronously: false) }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// Writes everything out now: the app is going to the background, or the
    /// note is being closed. Also remembers the view position and refreshes
    /// the library thumbnail.
    func flush() {
        saveItem?.cancel()
        if let state = canvas?.viewState { document.setViewState(state) }
        document.save(synchronously: true)
        let thumbnail = document.url.appendingPathComponent("thumb.png")
        if editedSinceThumbnail || !FileManager.default.fileExists(atPath: thumbnail.path) {
            Thumbnailer.write(for: ExportSnapshot(document: document), to: thumbnail)
            editedSinceThumbnail = false
        }
    }

    func close() { flush() }

    // MARK: Export

    func exportPDF(completion: @escaping (URL?) -> Void) {
        guard !isExporting else { return }
        isExporting = true
        let snapshot = ExportSnapshot(document: document)
        DispatchQueue.global(qos: .userInitiated).async {
            let url = try? PDFExporter.export(snapshot)
            DispatchQueue.main.async {
                self.isExporting = false
                completion(url)
            }
        }
    }
}
