import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Opens the document once and keeps its session alive for the editor's lifetime.
final class SessionHolder: ObservableObject {
    let session: EditorSession?

    init(url: URL) {
        session = (try? NoteDocument(url: url)).map(EditorSession.init(document:))
    }
}

struct EditorView: View {
    @StateObject private var holder: SessionHolder
    private let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        _holder = StateObject(wrappedValue: SessionHolder(url: url))
        self.onClose = onClose
    }

    var body: some View {
        if let session = holder.session {
            EditorContent(session: session, onClose: onClose)
        } else {
            VStack(spacing: 16) {
                Text("This note couldn't be opened.")
                Button("Close", action: onClose)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }
}

/// Full-screen canvas with a single floating toolbar.
struct EditorContent: View {
    @ObservedObject var session: EditorSession
    let onClose: () -> Void

    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importingImage = false
    @State private var confirmingDelete = false

    var body: some View {
        ZStack(alignment: .top) {
            CanvasRepresentable(session: session)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                EditorToolbar(
                    session: session,
                    onClose: {
                        session.close()
                        onClose()
                    },
                    addPhoto: { pickingPhoto = true },
                    addFile: { importingImage = true },
                    deletePage: { confirmingDelete = true }
                )
                if session.activeImage != nil {
                    ImageStrip(session: session)
                        .transition(.opacity)
                }
            }
            .padding(.top, 8)

            if !session.document.isInfinite, session.document.pages.count > 1 {
                Text("\(session.activePageIndex + 1) / \(session.document.pages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .floatingBar()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }

            if session.isExporting {
                ProgressView()
                    .padding(18)
                    .floatingPanel()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        #if DEBUG
        .onAppear { DebugHooks.editorAppeared(session) }
        #endif
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await MainActor.run { session.insertImage(data: data) }
                }
            }
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { session.insertImage(data: data) }
        }
        .confirmationDialog("Delete this page and everything on it?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) { session.deleteActivePage() }
        }
    }
}

struct CanvasRepresentable: UIViewRepresentable {
    let session: EditorSession

    func makeUIView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateUIView(_ view: CanvasView, context: Context) {}
}

// MARK: - Toolbar

struct EditorToolbar: View {
    @ObservedObject var session: EditorSession
    let onClose: () -> Void
    let addPhoto: () -> Void
    let addFile: () -> Void
    let deletePage: () -> Void

    private enum Panel: Equatable {
        case tool
        case color(Int)
        case layers
    }

    @State private var panel: Panel?

    var body: some View {
        // In a narrow Split View the bar scrolls sideways instead of clipping.
        ViewThatFits(in: .horizontal) {
            items
                .padding(.horizontal, 6)
                .frame(height: Theme.barHeight)
                .floatingBar()
            ScrollView(.horizontal, showsIndicators: false) {
                items.padding(.horizontal, 6)
            }
            .frame(height: Theme.barHeight)
            .clipShape(Capsule())
            .floatingBar()
            .padding(.horizontal, 8)
        }
    }

    private var items: some View {
        HStack(spacing: 2) {
            BarButton(systemName: "chevron.left", label: "Library", action: onClose)
            BarDivider()

            ForEach(Tool.allCases) { tool in
                BarButton(systemName: tool.symbol, isSelected: session.box.tool == tool, label: tool.title) {
                    // Tapping the active tool opens its settings.
                    if session.box.tool == tool { panel = .tool } else { session.select(tool) }
                }
                .popover(isPresented: isShowing(.tool, when: session.box.tool == tool)) {
                    ToolSettingsView(session: session, tool: tool)
                }
            }
            BarDivider()

            colorDots
            BarDivider()

            BarButton(systemName: "arrow.uturn.backward", isEnabled: session.canUndo, label: "Undo") { session.undo() }
            BarButton(systemName: "arrow.uturn.forward", isEnabled: session.canRedo, label: "Redo") { session.redo() }
            BarDivider()

            BarButton(systemName: "square.2.layers.3d", label: "Layers") { panel = .layers }
                .popover(isPresented: isShowing(.layers)) {
                    LayersPanel(session: session, addPhoto: { afterDismissing(addPhoto) }, addFile: { afterDismissing(addFile) })
                }
            moreMenu
        }
    }

    private func isShowing(_ target: Panel, when condition: Bool = true) -> Binding<Bool> {
        Binding(
            get: { panel == target && condition },
            set: { if !$0, panel == target { panel = nil } }
        )
    }

    /// Closes the open popover before something else is presented.
    private func afterDismissing(_ action: @escaping () -> Void) {
        panel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: action)
    }

    @ViewBuilder
    private var colorDots: some View {
        let tool = session.colorTool
        let slots = session.box.colors(for: tool)
        let selected = session.box.tool == .eraser ? -1 : session.box.selectedColorIndex(for: tool)
        ForEach(slots.indices, id: \.self) { slot in
            Button {
                // Tapping the active colour opens the palette.
                if slot == selected { panel = .color(slot) } else { session.selectColor(slot: slot) }
            } label: {
                ColorDot(color: Color(uiColor: RGBA8(slots[slot]).uiColor), isSelected: slot == selected)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Colour \(slot + 1)")
            .popover(isPresented: isShowing(.color(slot))) {
                PalettePopover(session: session, tool: tool, slot: slot)
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if !session.document.isInfinite {
                Button("Add Page", systemImage: "plus.rectangle.portrait") { session.addPage() }
            }
            if session.hasPlainPages {
                Picker(selection: Binding(get: { session.activePaper }, set: { session.setPaper($0) })) {
                    ForEach(PaperStyle.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label(session.document.isInfinite ? "Background" : "Paper", systemImage: "square.grid.3x3")
                }
                .pickerStyle(.menu)
            }
            Menu("Add Image", systemImage: "photo") {
                Button("Photo Library", systemImage: "photo.on.rectangle", action: addPhoto)
                Button("Files", systemImage: "folder", action: addFile)
            }
            Divider()
            Button("Export PDF", systemImage: "square.and.arrow.up") {
                session.exportPDF { url in
                    if let url { Presenter.share(url, from: session.canvas) }
                }
            }
            Divider()
            Menu("Pencil & Touch", systemImage: "hand.draw") {
                Picker(selection: Binding(
                    get: { session.box.fingerMode },
                    set: {
                        session.box.fingerMode = $0
                        session.box.fingerModeChosen = true
                    }
                )) {
                    ForEach(FingerMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("One Finger", systemImage: "hand.point.up.left")
                }
                .pickerStyle(.menu)
                Picker(selection: $session.box.doubleTap) {
                    ForEach(PencilAction.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Pencil Double-Tap", systemImage: "hand.tap")
                }
                .pickerStyle(.menu)
                Picker(selection: $session.box.squeeze) {
                    ForEach(PencilAction.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Pencil Squeeze", systemImage: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .pickerStyle(.menu)
            }
            if !session.document.isInfinite, session.document.pages.count > 1 {
                Divider()
                Button("Delete Page", systemImage: "trash", role: .destructive, action: deletePage)
            }
        } label: {
            BarIcon(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }
}

/// Shown while an image layer is selected: opacity for tracing, and a way out.
struct ImageStrip: View {
    @ObservedObject var session: EditorSession

    var body: some View {
        if let id = session.activeLayerID, let layer = session.layers.first(where: { $0.id == id }) {
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { Double(layer.opacity) }, set: { session.setOpacity(Float($0), layer: id) }),
                    in: 0.05...1
                )
                .frame(width: 180)
                Button("Done") { session.finishImagePlacement() }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .floatingBar()
        }
    }
}

// MARK: - Popovers

struct ToolSettingsView: View {
    @ObservedObject var session: EditorSession
    let tool: Tool

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tool.title).font(.headline)
            if tool == .eraser {
                Picker("Mode", selection: $session.box.eraserMode) {
                    ForEach(EraserMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Size", value: binding(\.width), range: tool.widthRange) { "\(Int($0.rounded()))" }
                Toggle("Switch back after erasing", isOn: $session.box.eraserAutoReturn)
                    .font(.subheadline)
            } else {
                StrokePreview(width: session.box[tool].width,
                              color: Color(uiColor: session.box.color(for: tool).uiColor),
                              opacity: tool == .highlighter ? session.box[tool].opacity : 1)
                    .frame(height: 44)
                SliderRow(title: "Size", value: binding(\.width), range: tool.widthRange)
                SliderRow(title: "Paper feel", value: binding(\.paper), range: 0...1, format: ToolSettingsView.percent)
                SliderRow(title: "Smoothing", value: binding(\.smoothing), range: 0...1, format: ToolSettingsView.percent)
                if tool == .highlighter {
                    SliderRow(title: "Opacity", value: binding(\.opacity), range: 0.2...1, format: ToolSettingsView.percent)
                }
                if tool.hasInkDynamics {
                    Toggle("Natural ink", isOn: Binding(
                        get: { session.box[tool].naturalInk },
                        set: { session.box[tool].naturalInk = $0 }
                    ))
                    .font(.subheadline)
                }
            }
        }
        .padding(18)
        .frame(width: 280)
    }

    private func binding(_ keyPath: WritableKeyPath<ToolSettings, Double>) -> Binding<Double> {
        Binding(
            get: { session.box[tool][keyPath: keyPath] },
            set: { session.box[tool][keyPath: keyPath] = $0 }
        )
    }
}

/// A sample squiggle at the chosen width.
struct StrokePreview: View {
    let width: Double
    let color: Color
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let steps = 48
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let point = CGPoint(
                    x: 14 + t * (size.width - 28),
                    y: size.height / 2 + sin(t * .pi * 2) * size.height * 0.26
                )
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            // Roughly how wide the stroke looks on a page fitted to the screen.
            context.stroke(path, with: .color(color.opacity(opacity)),
                           style: StrokeStyle(lineWidth: max(1, width * 1.6), lineCap: .round, lineJoin: .round))
        }
    }
}

struct PalettePopover: View {
    @ObservedObject var session: EditorSession
    let tool: Tool
    let slot: Int

    private static let inks: [UInt32] = [
        0x1C1C1E, 0x48484A, 0x8E8E93, 0xFFFFFF, 0x1F5FBF, 0x0A84FF,
        0x30B0C7, 0x248A3D, 0x34C759, 0xA2845E, 0xD63A2F, 0xFF453A,
        0xFF9F0A, 0xFFD60A, 0xBF5AF2, 0x5E5CE6, 0xFF375F, 0x8B4513,
    ]
    private static let highlights: [UInt32] = [
        0xFFE14D, 0xFFB340, 0xFF8FB8, 0xFF7A70, 0x7EE08A, 0x66D4CF,
        0x70B8FF, 0xB18CFF, 0xD0D0D5, 0xC7F464, 0xFFD1A6, 0x9BE7FF,
    ]

    var body: some View {
        let colors = tool == .highlighter ? PalettePopover.highlights : PalettePopover.inks
        let current = RGBA8(session.box.colors(for: tool)[slot])
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 6), spacing: 8) {
                ForEach(colors, id: \.self) { hex in
                    let color = RGBA8(hex: hex)
                    Button {
                        session.box.setColor(color, slot: slot, for: tool)
                    } label: {
                        ColorDot(color: Color(uiColor: color.uiColor), isSelected: color == current, size: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            ColorPicker("Custom", selection: Binding(
                get: { Color(uiColor: current.uiColor) },
                set: { session.box.setColor(RGBA8(UIColor($0)), slot: slot, for: tool) }
            ), supportsOpacity: false)
            .font(.subheadline)
        }
        .padding(18)
        .frame(width: 276)
    }
}

struct LayersPanel: View {
    @ObservedObject var session: EditorSession
    let addPhoto: () -> Void
    let addFile: () -> Void

    var body: some View {
        // Shown top-most first, like a stack of sheets.
        let layers = Array(session.layers.reversed())
        let activeID = session.activeLayerID
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Text("Layers").font(.headline)
                Spacer()
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle", action: addPhoto)
                    Button("Files", systemImage: "folder", action: addFile)
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .accessibilityLabel("Add image layer")
                Button { session.addLayer() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add layer")
            }
            .font(.system(size: 17, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            List {
                ForEach(layers) { layer in
                    HStack(spacing: 10) {
                        Button {
                            session.toggleVisibility(layer.id)
                        } label: {
                            Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
                        Image(systemName: layer.isImage ? "photo" : "scribble")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(layer.name)
                        Spacer()
                        if layer.id == activeID {
                            Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { session.selectLayer(layer.id) }
                    .listRowBackground(layer.id == activeID ? Color.primary.opacity(0.08) : Color.clear)
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    var ids = layers.map(\.id)
                    let moved = ids[from]
                    ids.move(fromOffsets: source, toOffset: destination)
                    guard let to = ids.firstIndex(of: moved) else { return }
                    // Convert display positions back to bottom-first storage order.
                    session.moveLayer(from: layers.count - 1 - from, to: layers.count - 1 - to)
                }
                .onDelete { offsets in
                    for id in offsets.map({ layers[$0].id }) { session.deleteLayer(id) }
                }
                .deleteDisabled(layers.count <= 1)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            if let id = activeID, let layer = layers.first(where: { $0.id == id }) {
                Divider()
                SliderRow(
                    title: "Opacity",
                    value: Binding(get: { Double(layer.opacity) }, set: { session.setOpacity(Float($0), layer: id) }),
                    range: 0...1
                ) { "\(Int(($0 * 100).rounded()))%" }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 300, height: 380)
    }
}

/// UIKit presentation helpers.
enum Presenter {
    /// Shows the system share sheet for a file, anchored under the toolbar.
    static func share(_ url: URL, from view: UIView?) {
        guard let view, var top = view.window?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: 64, width: 1, height: 1)
        sheet.popoverPresentationController?.permittedArrowDirections = [.up]
        top.present(sheet, animated: true)
    }
}
