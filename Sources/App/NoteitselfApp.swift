import SwiftUI

@main
struct NoteitselfApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}

/// The library, with the open document (if any) covering it.
struct RootView: View {
    @EnvironmentObject private var library: Library
    @State private var current: LibraryItem?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            LibraryView(open: { item in
                withAnimation(.easeOut(duration: 0.2)) { current = item }
            })

            if let item = current {
                DocumentHost(item: item) {
                    library.refresh()
                    withAnimation(.easeOut(duration: 0.2)) { current = nil }
                }
                .id(item.id)
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .onOpenURL(perform: open(url:))
        #if DEBUG
        .onAppear { DebugHooks.launch(library) { current = $0 } }
        #endif
        .alert("Couldn't open file", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    /// Files handed to the app: PDFs are imported as notebooks, notes are opened.
    private func open(url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf":
            do {
                current = try library.importPDF(at: url)
            } catch {
                errorText = error.localizedDescription
            }
        case Library.fileExtension, Library.legacyExtension:
            library.refresh()
            if let item = library.item(at: url) { current = item }
        default:
            break
        }
    }
}

/// Picks the right editor for a document.
struct DocumentHost: View {
    let item: LibraryItem
    let onClose: () -> Void

    var body: some View {
        switch item.kind {
        case .pixel:
            PixelEditorView(packageURL: item.url) {
                Manifest.touch(item.url)
                onClose()
            }
        case .notebook, .canvas:
            EditorView(url: item.url, onClose: onClose)
        }
    }
}
