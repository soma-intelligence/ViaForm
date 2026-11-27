import AppKit
import SwiftUI

// MARK: - Workspaces and accents

enum Workspace: String, CaseIterable, Identifiable {
    case design = "Design", generative = "Generative", mechanics = "Mechanics", electronics = "Electronics"
    case simulation = "Simulation", training = "Training", render = "Render", manufacture = "Manufacture"

    var id: String { rawValue }

    /// The one accent of the workspace. Used only for the active tab pill, the selected row, the primary
    /// button, the selection glow and the data marks of the workspace.
    var accent: Color {
        switch self {
        case .design: Color(hex: 0x3B82F6)
        case .generative: Color(hex: 0xE0409B)
        case .mechanics: Color(hex: 0x8B5CF6)
        case .electronics: Color(hex: 0xF5A524)
        case .simulation: Color(hex: 0x14C9A0)
        case .training: Color(hex: 0x84CC16)
        case .render: Color(hex: 0xFF6B5A)
        case .manufacture: Color(hex: 0xF97316)
        }
    }

    /// Text drawn on a filled accent surface. Light accents take dark text.
    var onAccent: Color {
        switch self {
        case .electronics, .simulation, .training: Color(hex: 0x0B0C0E)
        default: .white
        }
    }

    var symbol: String {
        switch self {
        case .design: "cube"
        case .generative: "sparkle"
        case .mechanics: "gearshape"
        case .electronics: "cpu"
        case .simulation: "waveform.path.ecg"
        case .training: "graduationcap"
        case .render: "camera.aperture"
        case .manufacture: "chart.bar.xaxis"
        }
    }

    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Workspace.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

extension EnvironmentValues {
    /// Accent of the active workspace, set once at the window root.
    @Entry var accent: Color = Workspace.design.accent
    @Entry var onAccent: Color = .white
    /// True while ImageRenderer draws the screen: materials and glass effects do not rasterise there,
    /// so glass falls back to a tinted fill that matches the live look.
    @Entry var staticRender: Bool = false
    /// The viewport plate and window size, so static glass can blur what sits behind it.
    @Entry var backdrop: PlateLayout? = nil
    @Entry var windowSize: CGSize = CGSize(width: 1600, height: 1000)
}

extension View {
    func workspaceAccent(_ w: Workspace) -> some View {
        environment(\.accent, w.accent).environment(\.onAccent, w.onAccent)
    }
}

// MARK: - Tokens

enum Tok {
    static let viewTop = Color(hex: 0x121316)
    static let viewBottom = Color(hex: 0x1B1D22)
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.60)
    static let tertiary = Color.white.opacity(0.38)
    static let hairline = Color.white.opacity(0.10)
    static let inset: CGFloat = 10
    static let radius: CGFloat = 18
    static let pad: CGFloat = 12

    static func caption(_ w: Font.Weight = .regular) -> Font { .system(size: 11, weight: w) }
    static func body(_ w: Font.Weight = .regular) -> Font { .system(size: 13, weight: w) }
    static let title = Font.system(size: 15, weight: .semibold)
    static func mono(_ size: CGFloat = 13, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

// MARK: - Resources

enum Asset {
    static func image(_ path: String) -> NSImage {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Resources/\(path)")
        return NSImage(contentsOf: url) ?? NSImage(size: NSSize(width: 8, height: 8))
    }

    static func tool(_ name: String) -> Image { Image(nsImage: image("ToolIcons/\(name).png")) }
    static func plate(_ name: String) -> Image { Image(nsImage: image("Plates/\(name).png")) }
    static func plateSize(_ name: String) -> CGSize { image("Plates/\(name).png").size }
}

/// Where a viewport plate sits: aspect fill, then zoom and shift so the model lands between the panels.
/// In the real app the plate is the live Metal viewport and `project` is OrbitCamera.project of the
/// selection anchor, which feeds the floating context pill and the value chip.
struct PlateLayout {
    var name: String
    var zoom: CGFloat = 1
    var shift: CGSize = .zero
    var feather = true

    func frame(in view: CGSize) -> CGRect {
        let plate = Asset.plateSize(name)
        let s = max(view.width / plate.width, view.height / plate.height) * zoom
        let w = plate.width * s, h = plate.height * s
        return CGRect(x: (view.width - w) / 2 + shift.width, y: (view.height - h) / 2 + shift.height, width: w, height: h)
    }

    func project(_ p: CGPoint, in view: CGSize) -> CGPoint {
        let plate = Asset.plateSize(name), f = frame(in: view)
        return CGPoint(x: f.minX + p.x / plate.width * f.width, y: f.minY + p.y / plate.height * f.height)
    }
}
