import SwiftUI
import UniformTypeIdentifiers

/// Grid of every note in the Documents folder.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    let open: (LibraryItem) -> Void

    @State private var importingPDF = false
    @State private var renaming: LibraryItem?
    @State private var renameText = ""
    @State private var deleting: LibraryItem?
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 164, maximum: 220), spacing: 28)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.items.isEmpty {
                    VStack(spacing: 8) {
                        Text("No notes yet")
                            .font(.title3.weight(.medium))
                        Text("Tap + to start a notebook, a canvas or pixel art, or to import a PDF.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 160)
                    .padding(.horizontal, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(library.items) { item in
                            Button { open(item) } label: { DocCard(item: item) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename", systemImage: "pencil") {
                                        renameText = item.title
                                        renaming = item
                                    }
                                    Button("Duplicate", systemImage: "plus.square.on.square") {
                                        attempt { try library.duplicate(item) }
                                    }
                                    Divider()
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                                }
                        }
                    }
                    .padding(28)
                }
            }
            .navigationTitle("noteitself")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Notebook", systemImage: "book.closed") { create(.notebook) }
                        Button("Canvas", systemImage: "scribble.variable") { create(.canvas) }
                        Button("Pixel Art", systemImage: "square.grid.3x3") { create(.pixel) }
                        Divider()
                        Button("Import PDF", systemImage: "doc.badge.plus") { importingPDF = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New")
                }
            }
        }
        .onAppear { library.refresh() }
        .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
            guard case let .success(url) = result else { return }
            attempt { open(try library.importPDF(at: url)) }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let item = renaming { attempt { try library.rename(item, to: renameText) } }
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = deleting { attempt { try library.delete(item) } }
            }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private func create(_ kind: DocKind) {
        attempt { open(try library.create(kind: kind)) }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Thumbnail card for one note.
struct DocCard: View {
    let item: LibraryItem
    @State private var thumbnail: UIImage?

    private var placeholder: String {
        switch item.kind {
        case .notebook: return "book.closed"
        case .canvas: return "scribble.variable"
        case .pixel: return "square.grid.3x3"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            // The card keeps one shape whatever the thumbnail's proportions.
            shape.fill(Color.white)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .interpolation(item.kind == .pixel ? .none : .medium)
                            .aspectRatio(contentMode: item.kind == .pixel ? .fit : .fill)
                    } else {
                        Image(systemName: placeholder)
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.gray.opacity(0.35))
                    }
                }
                .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.modified, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .task(id: item.modified) {
            let path = item.thumbnailURL.path
            thumbnail = await Task.detached(priority: .utility) { UIImage(contentsOfFile: path) }.value
        }
    }
}
