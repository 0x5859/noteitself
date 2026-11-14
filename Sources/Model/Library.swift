import CoreGraphics
import Foundation
import SwiftUI

struct LibraryItem: Identifiable, Hashable {
    let url: URL
    var kind: DocKind
    var modified: Date

    var id: String { url.standardizedFileURL.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var thumbnailURL: URL { url.appendingPathComponent("thumb.png") }
}

enum LibraryError: LocalizedError {
    case unreadablePDF
    case lockedPDF
    case nameTaken

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "That file could not be read as a PDF."
        case .lockedPDF: return "Password-protected PDFs can't be imported."
        case .nameTaken: return "A note with that name already exists."
        }
    }
}

/// The set of document packages in the app's Documents folder. Everything is
/// plain files, so notes show up in the Files app and survive without the app.
final class Library: ObservableObject {
    static let fileExtension = "noteitself"
    /// Extension used by early builds. Such notes are renamed when the
    /// library opens, and still listed if that fails.
    static let legacyExtension = "sumi"

    static func isNote(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == fileExtension || ext == legacyExtension
    }

    @Published private(set) var items: [LibraryItem] = []
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        adoptLegacyNotes()
        refresh()
    }

    /// Gives notes saved as `Name.sumi` the current extension. Only the
    /// folder is renamed; nothing inside changes. Runs once, before any note
    /// can be open.
    private func adoptLegacyNotes() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension.lowercased() == Library.legacyExtension {
            // Leave alone anything that is not one of this app's notes.
            guard (try? Manifest.read(from: url)) != nil else { continue }
            let target = uniqueURL(base: url.deletingPathExtension().lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: target)
        }
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var found: [LibraryItem] = []
        for url in urls where Library.isNote(url) {
            guard let manifest = try? Manifest.read(from: url) else { continue }
            found.append(LibraryItem(url: url, kind: manifest.kind, modified: manifest.modified))
        }
        items = found.sorted { $0.modified > $1.modified }
    }

    func item(at url: URL) -> LibraryItem? {
        let path = url.standardizedFileURL.path
        return items.first { $0.id == path }
    }

    private func packageURL(named name: String) -> URL {
        root.appendingPathComponent(name).appendingPathExtension(Library.fileExtension)
    }

    private func uniqueURL(base: String) -> URL {
        let clean = Library.sanitize(base)
        var candidate = packageURL(named: clean)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = packageURL(named: "\(clean) \(n)")
            n += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let trimmed = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(80))
    }

    @discardableResult
    func create(kind: DocKind) throws -> LibraryItem {
        let base: String
        switch kind {
        case .notebook: base = "Notebook"
        case .canvas: base = "Canvas"
        case .pixel: base = "Pixel Art"
        }
        let url = uniqueURL(base: base)
        try NoteDocument.create(at: url, kind: kind)
        refresh()
        return item(at: url) ?? LibraryItem(url: url, kind: kind, modified: Date())
    }

    /// Copies a PDF into a new notebook whose pages use the PDF pages as backgrounds.
    @discardableResult
    func importPDF(at source: URL) throws -> LibraryItem {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let pdf = CGPDFDocument(source as CFURL), pdf.numberOfPages > 0 else {
            throw LibraryError.unreadablePDF
        }
        if pdf.isEncrypted && !pdf.unlockWithPassword("") {
            throw LibraryError.lockedPDF
        }

        let asset = UUID().uuidString + ".pdf"
        var pages: [PageInfo] = []
        for number in 1...pdf.numberOfPages {
            guard let page = pdf.page(at: number) else { continue }
            let size = PDFGeometry.displaySize(of: page)
            pages.append(PageInfo(
                id: UUID(), width: Double(size.width), height: Double(size.height),
                paper: .blank, pdf: PDFRef(asset: asset, page: number)
            ))
        }
        guard !pages.isEmpty else { throw LibraryError.unreadablePDF }

        let url = uniqueURL(base: source.deletingPathExtension().lastPathComponent)
        try NoteDocument.create(at: url, kind: .notebook, pages: pages)
        do {
            try FileManager.default.copyItem(at: source, to: url.appendingPathComponent("assets").appendingPathComponent(asset))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        refresh()
        return item(at: url) ?? LibraryItem(url: url, kind: .notebook, modified: Date())
    }

    func rename(_ item: LibraryItem, to name: String) throws {
        let clean = Library.sanitize(name)
        guard clean != item.title else { return }
        let target = packageURL(named: clean)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw LibraryError.nameTaken }
        try FileManager.default.moveItem(at: item.url, to: target)
        refresh()
    }

    func duplicate(_ item: LibraryItem) throws {
        let target = uniqueURL(base: item.title + " copy")
        try FileManager.default.copyItem(at: item.url, to: target)
        if var manifest = try? Manifest.read(from: target) {
            manifest.id = UUID()
            manifest.modified = Date()
            try? manifest.write(to: target)
        }
        refresh()
    }

    func delete(_ item: LibraryItem) throws {
        try FileManager.default.removeItem(at: item.url)
        refresh()
    }
}
