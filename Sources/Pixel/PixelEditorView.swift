import SwiftUI
import UIKit

/// Full-screen pixel art editor for one document package.
struct PixelEditorView: View {
    @StateObject private var model: PixelEditorModel
    private let onClose: () -> Void

    init(packageURL: URL, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PixelEditorModel(packageURL: packageURL))
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .top) {
            PixelCanvasRepresentable(model: model)
                .ignoresSafeArea()
            PixelToolbar(model: model) {
                model.close()
                onClose()
            }
            .padding(.top, 8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.save(synchronously: true)
        }
        .onDisappear { model.save(synchronously: true) }
    }
}

private struct PixelCanvasRepresentable: UIViewRepresentable {
    let model: PixelEditorModel

    func makeUIView(context: Context) -> PixelCanvasView { PixelCanvasView(model: model) }
    func updateUIView(_ uiView: PixelCanvasView, context: Context) {}
}

/// Invisible UIKit view placed behind a SwiftUI control so UIKit popovers
/// (the share sheet) can point at it.
private struct PixelAnchorView: UIViewRepresentable {
    let model: PixelEditorModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        model.shareAnchor = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { model.shareAnchor = uiView }
}

private struct PixelToolbar: View {
    @ObservedObject var model: PixelEditorModel
    let onBack: () -> Void

    @State private var showLayers = false
    @State private var brushPanelTool: PixelTool?
    @State private var showCanvasSize = false

    var body: some View {
        HStack(spacing: 0) {
            BarButton(systemName: "chevron.left", label: "Back", action: onBack)
            BarDivider()
            ForEach(PixelTool.allCases) { tool in toolButton(tool) }
            BarDivider()
            Button { model.showColorPanel = true } label: {
                ColorDot(color: model.color.color, isSelected: model.showColorPanel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Colour")
            .popover(isPresented: $model.showColorPanel) { PixelColorPanel(model: model) }
            BarDivider()
            BarButton(systemName: "arrow.uturn.backward", isEnabled: model.canUndo, label: "Undo") { model.undo() }
            BarButton(systemName: "arrow.uturn.forward", isEnabled: model.canRedo, label: "Redo") { model.redo() }
            BarDivider()
            BarButton(systemName: "square.2.layers.3d", isSelected: showLayers, label: "Layers") { showLayers = true }
                .popover(isPresented: $showLayers) { PixelLayersPanel(model: model) }
            moreMenu
        }
        .padding(.horizontal, 6)
        .frame(height: Theme.barHeight)
        .floatingBar()
    }

    private func toolButton(_ tool: PixelTool) -> some View {
        BarButton(systemName: tool.symbol, isSelected: model.tool == tool, label: tool.title) {
            if model.tool == tool, tool.hasBrushSize {
                brushPanelTool = tool
            } else {
                model.select(tool)
            }
        }
        .popover(isPresented: Binding(get: { brushPanelTool == tool },
                                      set: { if !$0 { brushPanelTool = nil } })) {
            PixelBrushPanel(model: model, tool: tool)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { showCanvasSize = true } label: {
                Label("Canvas Size (\(model.canvasWidth) × \(model.canvasHeight))", systemImage: "square.resize")
            }
            Toggle(isOn: Binding(get: { model.showGrid }, set: { model.setShowGrid($0) })) {
                Label("Pixel Grid", systemImage: "grid")
            }
            Button { model.zoomToFit() } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Divider()
            Button { model.export(.png) } label: { Label("Export PNG", systemImage: "photo") }
            Button { model.export(.pdf) } label: { Label("Export PDF", systemImage: "doc") }
            Divider()
            Button(role: .destructive) { model.clearLayer() } label: { Label("Clear Layer", systemImage: "trash") }
        } label: {
            BarIcon(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
        .background(PixelAnchorView(model: model))
        .popover(isPresented: $showCanvasSize) { PixelCanvasSizePanel(model: model) }
    }
}
