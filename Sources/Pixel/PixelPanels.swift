import SwiftUI

/// Square colour swatch; pixel-art flavoured rather than round.
private struct PixelSwatch: View {
    let color: PixelColor
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.color)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .padding(3)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.8), lineWidth: 2)
                }
            }
            .frame(width: PixelColorPanel.swatchSize, height: PixelColorPanel.swatchSize)
            .contentShape(Rectangle())
    }
}

struct PixelColorPanel: View {
    static let swatchSize: CGFloat = 34
    private static let columns = 6

    @ObservedObject var model: PixelEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.swatchSize), spacing: 2), count: Self.columns),
                      spacing: 2) {
                ForEach(model.palette, id: \.self) { swatch($0) }
            }
            if !model.recentColors.isEmpty {
                HStack(spacing: 2) {
                    ForEach(model.recentColors, id: \.self) { swatch($0) }
                }
            }
            Divider()
            ColorPicker(selection: Binding(get: { model.color.color },
                                           set: { model.setCustomColor(PixelColor($0)) }),
                        supportsOpacity: true) {
                Text("Custom").font(.subheadline)
            }
        }
        .padding(14)
        .frame(width: CGFloat(Self.columns) * (Self.swatchSize + 2) + 26)
        .presentationCompactAdaptation(.popover)
        .onDisappear { model.commitCustomColor() }
    }

    private func swatch(_ color: PixelColor) -> some View {
        Button {
            model.choose(color)
            dismiss()
        } label: {
            PixelSwatch(color: color, isSelected: color == model.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.hex)
    }
}

/// Brush size picker shown when tapping the already-selected pencil or eraser.
struct PixelBrushPanel: View {
    @ObservedObject var model: PixelEditorModel
    let tool: PixelTool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...PixelEditorModel.maxBrushSize, id: \.self) { size in
                let selected = (tool == .eraser ? model.eraserSize : model.pencilSize) == size
                Button {
                    model.setBrushSize(size, for: tool)
                    dismiss()
                } label: {
                    Rectangle()
                        .fill(Color.primary.opacity(selected ? 1 : 0.6))
                        .frame(width: CGFloat(size) * 5, height: CGFloat(size) * 5)
                        .frame(width: 44, height: 44)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.12))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(size) pixel")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(8)
        .presentationCompactAdaptation(.popover)
    }
}

/// Layer stack (top layer first) with visibility, selection, ordering and opacity.
struct PixelLayersPanel: View {
    private static let rowHeight: CGFloat = 48

    @ObservedObject var model: PixelEditorModel

    private var activeIndex: Int { model.layers.firstIndex { $0.id == model.activeLayerID } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.layers.reversed()) { row($0) }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(model.layers.count) * (Self.rowHeight + 2) + 10, 320))

            Divider()
            SliderRow(title: "Opacity",
                      value: Binding(get: { model.layers.first { $0.id == model.activeLayerID }?.opacity ?? 1 },
                                     set: { model.setOpacity($0) }),
                      range: 0...1,
                      format: { "\(Int(($0 * 100).rounded()))%" })
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()
            HStack(spacing: 0) {
                BarButton(systemName: "plus", label: "Add Layer") { model.addLayer() }
                BarButton(systemName: "plus.square.on.square", label: "Duplicate Layer") { model.duplicateLayer() }
                BarButton(systemName: "arrow.up", isEnabled: activeIndex < model.layers.count - 1,
                          label: "Move Up") { model.moveLayer(up: true) }
                BarButton(systemName: "arrow.down", isEnabled: activeIndex > 0,
                          label: "Move Down") { model.moveLayer(up: false) }
                Spacer(minLength: 0)
                BarButton(systemName: "trash", isEnabled: model.layers.count > 1,
                          label: "Delete Layer") { model.deleteLayer() }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
        .onDisappear { model.endOpacityEdit() }
    }

    private func row(_ layer: PixelLayerInfo) -> some View {
        let selected = layer.id == model.activeLayerID
        return HStack(spacing: 10) {
            thumbnail(layer.id)
            Text(layer.name)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
            Spacer(minLength: 0)
            Button { model.toggleVisibility(layer.id) } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(layer.isVisible ? 0.7 : 0.35))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(layer.isVisible ? "Hide \(layer.name)" : "Show \(layer.name)")
        }
        .padding(.leading, 6)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.1) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectLayer(layer.id) }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func thumbnail(_ id: UUID) -> some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image = model.thumbnail(for: id) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// Canvas size: square shortcuts, exact width and height, and which part of
/// the artwork stays put. Nothing changes until "Resize" is pressed.
struct PixelCanvasSizePanel: View {
    @ObservedObject var model: PixelEditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var width: Int
    @State private var height: Int
    @State private var anchor = PixelAnchor.centre

    init(model: PixelEditorModel) {
        self.model = model
        _width = State(initialValue: model.canvasWidth)
        _height = State(initialValue: model.canvasHeight)
    }

    private static let sides = 1...PixelEditorModel.maxCanvasSide

    private var isChanged: Bool { width != model.canvasWidth || height != model.canvasHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(PixelEditorModel.canvasPresets, id: \.self) { size in
                    let selected = width == size && height == size
                    Button {
                        width = size
                        height = size
                    } label: {
                        Text("\(size)")
                            .font(.subheadline.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(selected ? 0.16 : 0.06)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(size) by \(size)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            side("Width", $width)
            side("Height", $height)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Anchor").font(.subheadline)
                    Text("The artwork stays here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                anchorGrid
            }

            Button {
                model.resizeCanvas(width: width, height: height, anchor: anchor)
                dismiss()
            } label: {
                Text("Resize to \(width) × \(height)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isChanged)
            .accessibilityIdentifier("Resize Canvas")
        }
        .padding(14)
        .frame(width: 292)
        .presentationCompactAdaptation(.popover)
    }

    private func side(_ title: String, _ value: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            TextField(title, value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.subheadline.monospacedDigit())
                .frame(width: 48)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                .accessibilityIdentifier("Canvas \(title)")
            Stepper(title, value: value, in: Self.sides)
                .labelsHidden()
        }
        .onChange(of: value.wrappedValue) { _, new in
            // Typed values can be anything; keep them inside what the canvas supports.
            let clamped = min(max(new, Self.sides.lowerBound), Self.sides.upperBound)
            if clamped != new { value.wrappedValue = clamped }
        }
    }

    private static let anchorNames = [["top left", "top", "top right"],
                                      ["left", "centre", "right"],
                                      ["bottom left", "bottom", "bottom right"]]

    private var anchorGrid: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { column in
                        let position = PixelAnchor(column: column, row: row)
                        let selected = position == anchor
                        Button { anchor = position } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(selected ? 0.85 : 0.1))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Anchor \(Self.anchorNames[row][column])")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }
}
