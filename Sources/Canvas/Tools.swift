import Foundation

enum Tool: String, CaseIterable, Codable, Identifiable {
    case pen, pencil, brush, marker, highlighter, eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .brush: return "Brush"
        case .marker: return "Marker"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .brush: return "paintbrush.pointed"
        case .marker: return "paintbrush"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        }
    }

    /// Whether "natural ink" changes how this tool's line looks.
    var hasInkDynamics: Bool { self == .pen || self == .brush || self == .pencil }

    var brush: BrushKind? {
        switch self {
        case .pen: return .pen
        case .pencil: return .pencil
        case .brush: return .brush
        case .marker: return .marker
        case .highlighter: return .highlighter
        case .eraser: return nil
        }
    }

    /// Stroke width range in page points.
    var widthRange: ClosedRange<Double> {
        switch self {
        case .pen: return 0.5...6
        case .pencil: return 0.8...10
        case .brush: return 1...24
        case .marker: return 2...32
        case .highlighter: return 6...40
        case .eraser: return 8...80
        }
    }
}

struct ToolSettings: Codable, Equatable {
    var width: Double
    /// Classic time-based smoothing: 0 = off, 1 = heavy.
    var smoothing: Double
    var opacity: Double = 1
    /// Paper feel: 0 = bare glass, 1 = toothy paper. Friction that grows with
    /// pressure, tremor that settles out of the line, landing/lift skids removed.
    var paper: Double = 0.6
    /// Line weight follows the tip like real ink (tapered terminals, flow).
    var naturalInk = true

    init(width: Double, smoothing: Double, opacity: Double = 1, paper: Double = 0.6, naturalInk: Bool = true) {
        self.width = width
        self.smoothing = smoothing
        self.opacity = opacity
        self.paper = paper
        self.naturalInk = naturalInk
    }

    // Settings saved by earlier versions lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Double.self, forKey: .width)
        smoothing = try c.decode(Double.self, forKey: .smoothing)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        paper = try c.decodeIfPresent(Double.self, forKey: .paper) ?? 0.6
        naturalInk = try c.decodeIfPresent(Bool.self, forKey: .naturalInk) ?? true
    }

    static func defaults(for tool: Tool) -> ToolSettings {
        switch tool {
        case .pen: return ToolSettings(width: 1.3, smoothing: 0.1)
        case .pencil: return ToolSettings(width: 1.8, smoothing: 0.1)
        case .brush: return ToolSettings(width: 4, smoothing: 0.25)
        case .marker: return ToolSettings(width: 5, smoothing: 0.2)
        case .highlighter: return ToolSettings(width: 14, smoothing: 0.3, opacity: 0.55, paper: 0.4)
        case .eraser: return ToolSettings(width: 24, smoothing: 0, paper: 0, naturalInk: false)
        }
    }
}

enum EraserMode: String, Codable, CaseIterable, Identifiable {
    /// Rubs out exactly what the eraser touches.
    case precise
    /// Removes every stroke the eraser touches.
    case stroke

    var id: String { rawValue }
    var title: String { self == .precise ? "Precise" : "Stroke" }
}

/// What a single finger does on the canvas. Two fingers always pan and zoom.
enum FingerMode: String, Codable, CaseIterable, Identifiable {
    case pan, draw, erase

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pan: return "Scroll"
        case .draw: return "Draw"
        case .erase: return "Erase"
        }
    }
}

/// What an Apple Pencil double-tap or squeeze does.
enum PencilAction: String, Codable, CaseIterable, Identifiable {
    case eraser, previousTool, undo, none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .eraser: return "Switch to Eraser"
        case .previousTool: return "Previous Tool"
        case .undo: return "Undo"
        case .none: return "Off"
        }
    }
}

/// All tool preferences; persisted as one JSON blob in UserDefaults.
struct ToolBox: Codable, Equatable {
    var tool: Tool = .pen
    var settings: [String: ToolSettings] = [:]
    var eraserMode: EraserMode = .precise
    var eraserAutoReturn = false
    var inkColors: [UInt32] = [RGBA8.black.value, RGBA8(hex: 0x1F5FBF).value, RGBA8(hex: 0xD63A2F).value]
    var highlightColors: [UInt32] = [RGBA8(hex: 0xFFE14D).value, RGBA8(hex: 0x7EE08A).value, RGBA8(hex: 0xFF8FB8).value]
    var colorIndex: [String: Int] = [:]
    var fingerMode: FingerMode = .draw
    /// False until the user (or the first Pencil touch) has picked a finger mode.
    var fingerModeChosen = false
    var doubleTap: PencilAction = .eraser
    var squeeze: PencilAction = .previousTool

    private static let defaultsKey = "toolbox.v1"

    static func load() -> ToolBox {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let box = try? JSONDecoder().decode(ToolBox.self, from: data) else { return ToolBox() }
        return box
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ToolBox.defaultsKey)
        }
    }

    subscript(tool: Tool) -> ToolSettings {
        get { settings[tool.rawValue] ?? ToolSettings.defaults(for: tool) }
        set { settings[tool.rawValue] = newValue }
    }

    /// The three quick colours shown for a tool.
    func colors(for tool: Tool) -> [UInt32] {
        tool == .highlighter ? highlightColors : inkColors
    }

    func selectedColorIndex(for tool: Tool) -> Int {
        let index = colorIndex[tool.rawValue] ?? 0
        return min(max(index, 0), colors(for: tool).count - 1)
    }

    func color(for tool: Tool) -> RGBA8 {
        RGBA8(colors(for: tool)[selectedColorIndex(for: tool)])
    }

    mutating func setColor(_ color: RGBA8, slot: Int, for tool: Tool) {
        if tool == .highlighter {
            guard highlightColors.indices.contains(slot) else { return }
            highlightColors[slot] = color.value
        } else {
            guard inkColors.indices.contains(slot) else { return }
            inkColors[slot] = color.value
        }
    }
}
