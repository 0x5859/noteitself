import SwiftUI

/// Shared look for every floating control in the app. Keep chrome to one
/// pill of monochrome icons; colour only appears where it carries meaning.
enum Theme {
    static let buttonSize: CGFloat = 36
    static let barHeight: CGFloat = 48
    static let iconSize: CGFloat = 17
}

extension View {
    /// Translucent capsule used behind floating toolbars.
    @ViewBuilder
    func floatingBar() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }

    /// Same material on a rounded rectangle, for floating panels.
    @ViewBuilder
    func floatingPanel(cornerRadius: CGFloat = 18) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }
}

/// Icon button used inside a floating bar.
struct BarButton: View {
    let systemName: String
    var isSelected = false
    var isEnabled = true
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BarIcon(systemName: systemName, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.28)
        .accessibilityLabel(label ?? systemName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The visual of a bar button, for use as a `Menu` label.
struct BarIcon: View {
    let systemName: String
    var isSelected = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: Theme.iconSize, weight: .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.6))
            .frame(width: Theme.buttonSize, height: Theme.buttonSize)
            .background {
                if isSelected {
                    Circle().fill(Color.primary.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 5)
    }
}

/// A colour swatch; shows a ring when selected.
struct ColorDot: View {
    let color: Color
    var isSelected = false
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))
            .padding(4)
            .overlay {
                if isSelected {
                    Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5)
                }
            }
            .frame(width: Theme.buttonSize - 4, height: Theme.buttonSize)
            .contentShape(Rectangle())
    }
}

/// Labelled slider row used in popovers.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.1f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(format(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
