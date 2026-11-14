import CoreGraphics
import Foundation
import os

enum DocKind: String, Codable {
    case notebook
    case canvas
    case pixel
}

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, lined, grid, dots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return "Blank"
        case .lined: return "Lined"
        case .grid: return "Grid"
        case .dots: return "Dots"
        }
    }
}

/// A page of an imported PDF used as a page background.
struct PDFRef: Codable, Equatable, Hashable {
    /// File name inside the package's `assets` folder.
    var asset: String
    /// 1-based page number.
    var page: Int
}

struct ImageRef: Equatable {
    var asset: String
    /// Placement in page coordinates.
    var frame: CGRect
}

/// Monotonic stamp used to tell whether cached GPU geometry still matches a layer.
enum Revision {
    private static let counter = OSAllocatedUnfairLock(initialState: 0)

    static func next() -> Int {
        counter.withLock { value in
            value += 1
            return value
        }
    }
}

struct Layer: Identifiable {
    let id: UUID
    var name: String
    var isVisible = true
    var opacity: Float = 1
    var strokes: [Stroke] = []
    /// Non-nil makes this an image layer (used as a tracing reference).
    var image: ImageRef?
    private(set) var revision = Revision.next()

    init(id: UUID = UUID(), name: String, strokes: [Stroke] = [], image: ImageRef? = nil) {
        self.id = id
        self.name = name
        self.strokes = strokes
        self.image = image
    }

    var isImage: Bool { image != nil }

    /// Call after changing `strokes`.
    mutating func touch() { revision = Revision.next() }
}

final class Page: Identifiable {
    let id: UUID
    /// Zero for the single unbounded page of a canvas document.
    var size: CGSize
    var paper: PaperStyle
    var pdf: PDFRef?
    var layers: [Layer] = []
    var isLoaded = false
    var isDirty = false
    var activeLayerID: UUID?

    init(id: UUID = UUID(), size: CGSize, paper: PaperStyle, pdf: PDFRef? = nil) {
        self.id = id
        self.size = size
        self.paper = paper
        self.pdf = pdf
    }

    convenience init(info: PageInfo) {
        self.init(id: info.id, size: CGSize(width: info.width, height: info.height), paper: info.paper, pdf: info.pdf)
    }

    var info: PageInfo {
        PageInfo(id: id, width: Double(size.width), height: Double(size.height), paper: paper, pdf: pdf)
    }

    /// Gives a fresh page its first drawing layer.
    func ensureDefaultLayer() {
        if layers.isEmpty {
            layers = [Layer(name: "Layer 1")]
        }
    }
}

struct PageInfo: Codable {
    var id: UUID
    var width: Double
    var height: Double
    var paper: PaperStyle
    var pdf: PDFRef?
}

struct ViewState: Codable {
    var x: Double
    var y: Double
    var zoom: Double
}

/// `manifest.json` at the root of every document package.
struct Manifest: Codable {
    var version = 1
    var id = UUID()
    var kind: DocKind
    var created = Date()
    var modified = Date()
    var pages: [PageInfo] = []
    var view: ViewState?

    init(kind: DocKind) { self.kind = kind }

    static let fileName = "manifest.json"

    static func read(from package: URL) throws -> Manifest {
        let data = try Data(contentsOf: package.appendingPathComponent(fileName))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: data)
    }

    func write(to package: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: package.appendingPathComponent(Manifest.fileName), options: .atomic)
    }

    /// Bumps the modification date of a package without loading it.
    static func touch(_ package: URL) {
        guard var manifest = try? read(from: package) else { return }
        manifest.modified = Date()
        try? manifest.write(to: package)
    }
}

/// A document package on disk:
///
///     Name.noteitself/
///       manifest.json
///       pages/<page-id>.bin     strokes and layers of one page
///       assets/<name>           imported PDFs and images
///       thumb.png
final class NoteDocument {
    let url: URL
    private(set) var manifest: Manifest
    private(set) var pages: [Page]
    private var removedPageIDs: [UUID] = []
    private var manifestDirty = false
    private var contentChanged = false

    static let ioQueue = DispatchQueue(label: "noteitself.io", qos: .utility)

    var kind: DocKind { manifest.kind }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var isInfinite: Bool { manifest.kind == .canvas }
    var hasPDF: Bool { pages.contains { $0.pdf != nil } }

    init(url: URL) throws {
        self.url = url
        manifest = try Manifest.read(from: url)
        pages = manifest.pages.map(Page.init(info:))
        if pages.isEmpty {
            pages = [NoteDocument.defaultPage(for: manifest.kind)]
            manifestDirty = true
        }
    }

    // MARK: Creation

    static var defaultPageSize: CGSize {
        // US Letter where it is the norm, A4 elsewhere.
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    static func defaultPage(for kind: DocKind) -> Page {
        switch kind {
        case .canvas: return Page(size: .zero, paper: .dots)
        default: return Page(size: defaultPageSize, paper: .blank)
        }
    }

    static func create(at url: URL, kind: DocKind, pages: [PageInfo]? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("assets"), withIntermediateDirectories: true)
        var manifest = Manifest(kind: kind)
        if let pages {
            manifest.pages = pages
        } else if kind != .pixel {
            manifest.pages = [defaultPage(for: kind).info]
        }
        try manifest.write(to: url)
    }

    // MARK: Pages

    static func pageURL(in package: URL, id: UUID) -> URL {
        package.appendingPathComponent("pages").appendingPathComponent(id.uuidString + ".bin")
    }

    /// Reads a page's layers from disk the first time it is needed.
    func ensureLoaded(_ page: Page) {
        guard !page.isLoaded else { return }
        // Go through the IO queue so a save that is still in flight lands first.
        let file = NoteDocument.pageURL(in: url, id: page.id)
        let data = NoteDocument.ioQueue.sync { try? Data(contentsOf: file) }
        if let data, let layers = try? PageCodec.decode(data) {
            page.layers = layers
        }
        page.ensureDefaultLayer()
        page.isLoaded = true
    }

    /// Releases a clean page's strokes; they reload on demand.
    func unload(_ page: Page) {
        guard page.isLoaded, !page.isDirty else { return }
        page.layers = []
        page.isLoaded = false
    }

    func insert(_ page: Page, at index: Int) {
        page.ensureDefaultLayer()
        page.isLoaded = true
        page.isDirty = true
        pages.insert(page, at: min(max(index, 0), pages.count))
        manifestDirty = true
    }

    func removePage(at index: Int) {
        guard pages.indices.contains(index), pages.count > 1 else { return }
        removedPageIDs.append(pages.remove(at: index).id)
        manifestDirty = true
    }

    /// Call after changing page properties (paper style, size).
    func markManifestDirty() {
        manifestDirty = true
        contentChanged = true
    }

    func setViewState(_ state: ViewState) {
        manifest.view = state
        manifestDirty = true
    }

    // MARK: Assets

    func assetURL(_ name: String) -> URL {
        url.appendingPathComponent("assets").appendingPathComponent(name)
    }

    /// Copies data into the package and returns the asset name.
    func addAsset(_ data: Data, fileExtension: String) throws -> String {
        let name = UUID().uuidString + "." + fileExtension
        let folder = url.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        return name
    }

    // MARK: Saving

    struct SaveJob {
        let package: URL
        let manifest: Manifest?
        let pages: [(id: UUID, layers: [Layer])]
        let removed: [UUID]

        func run() {
            let fm = FileManager.default
            try? fm.createDirectory(at: package.appendingPathComponent("pages"), withIntermediateDirectories: true)
            for page in pages {
                let data = PageCodec.encode(page.layers)
                try? data.write(to: NoteDocument.pageURL(in: package, id: page.id), options: .atomic)
            }
            for id in removed {
                try? fm.removeItem(at: NoteDocument.pageURL(in: package, id: id))
            }
            try? manifest?.write(to: package)
        }
    }

    var hasUnsavedChanges: Bool {
        manifestDirty || !removedPageIDs.isEmpty || pages.contains { $0.isDirty }
    }

    /// Captures everything that changed and marks it clean. Strokes are
    /// immutable, so the job can be written from any thread.
    func makeSaveJob() -> SaveJob? {
        guard hasUnsavedChanges else { return nil }
        manifest.pages = pages.map(\.info)
        let dirty = pages.filter(\.isDirty)
        // Only real edits count as a modification; remembering the scroll
        // position should not reorder the library.
        if contentChanged || !dirty.isEmpty || !removedPageIDs.isEmpty {
            manifest.modified = Date()
        }
        contentChanged = false
        let job = SaveJob(
            package: url,
            manifest: manifest,
            pages: dirty.map { ($0.id, $0.layers) },
            removed: removedPageIDs
        )
        dirty.forEach { $0.isDirty = false }
        removedPageIDs = []
        manifestDirty = false
        return job
    }

    func save(synchronously: Bool) {
        guard let job = makeSaveJob() else {
            if synchronously { NoteDocument.ioQueue.sync {} }
            return
        }
        if synchronously {
            NoteDocument.ioQueue.sync { job.run() }
        } else {
            NoteDocument.ioQueue.async { job.run() }
        }
    }
}
