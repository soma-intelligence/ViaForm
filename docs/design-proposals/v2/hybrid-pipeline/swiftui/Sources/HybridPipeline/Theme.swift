import SwiftUI
import AppKit

// Hybrid Pipeline tokens. Every colour of the direction lives here.
extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum VF {
    static let chrome = Color(hex: 0x1C1C1E)
    static let panel = Color(hex: 0x2A2A2D)
    static let well = Color(hex: 0x202023)
    static let hairline = Color(hex: 0x3A3A3C)
    static let accent = Color(hex: 0x3D8BFF)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.38)
    static let green = Color(hex: 0x34C759)
    static let amber = Color(hex: 0xFFB020)
    static let red = Color(hex: 0xFF453A)
    static let cyan = Color(hex: 0x3FD8FF)
    static let orange = Color(hex: 0xFF8A2A)
    static let viewTop = Color(hex: 0x26272B)
    static let viewBottom = Color(hex: 0x18181B)
    static let floating = Color(hex: 0x1F2024, alpha: 0.92)

    // PCB layers
    static let fCu = Color(hex: 0xE5383B)
    static let in1 = Color(hex: 0xF2A03D)
    static let in2 = Color(hex: 0xA25BE0)
    static let bCu = Color(hex: 0x2F7DF6)
    static let silk = Color(hex: 0xF2F2F2)
    static let edge = Color(hex: 0x8E8E93)
}

enum StageStatus {
    case upToDate, stale, running, failed, idle

    var color: Color {
        switch self {
        case .upToDate: VF.green
        case .stale: VF.amber
        case .running: VF.accent
        case .failed: VF.red
        case .idle: VF.tertiary
        }
    }

    var word: String {
        switch self {
        case .upToDate: "Up to date"
        case .stale: "Stale"
        case .running: "Running"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }
}

enum Workspace: Int, CaseIterable, Identifiable {
    case design, generative, mechanics, electronics, simulation, training, render, manufacture

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .design: "Design"
        case .generative: "Generative"
        case .mechanics: "Mechanics"
        case .electronics: "Electronics"
        case .simulation: "Simulation"
        case .training: "Training"
        case .render: "Render"
        case .manufacture: "Manufacture"
        }
    }

    var symbol: String {
        switch self {
        case .design: "cube"
        case .generative: "circle.hexagongrid"
        case .mechanics: "gearshape.2"
        case .electronics: "cpu"
        case .simulation: "wind"
        case .training: "graduationcap"
        case .render: "camera.aperture"
        case .manufacture: "shippingbox"
        }
    }

    /// Cmd+1 to Cmd+8.
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String(rawValue + 1))) }
}

// Type scale (SF Pro 11 to 13, monospaced digits on every number).
extension Font {
    static let vfRow = Font.system(size: 13)
    static let vfRowSemibold = Font.system(size: 13, weight: .semibold)
    static let vfSmall = Font.system(size: 12)
    static let vfCaps = Font.system(size: 11, weight: .semibold)
    static let vfMicro = Font.system(size: 10, weight: .medium)
    static let vfHUD = Font.system(size: 28, weight: .semibold)
}

struct CapsLabel: View {
    let text: String
    var size: CGFloat = 11
    var color: Color = VF.secondary
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(color)
    }
}

struct StatusDot: View {
    let status: StageStatus
    var size: CGFloat = 6
    var body: some View {
        if status == .running {
            Circle()
                .trim(from: 0.08, to: 0.82)
                .stroke(status.color, style: StrokeStyle(lineWidth: max(1.5, size / 4), lineCap: .round))
                .frame(width: size + 3, height: size + 3)
        } else {
            Circle().fill(status.color).frame(width: size, height: size)
        }
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(VF.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Floating surface for viewport overlays. In the live app this is
/// .ultraThinMaterial; ImageRenderer does not draw materials, so the
/// headless renders use the same tinted fill.
struct FloatingSurface: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(VF.floating))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

extension View {
    func floatingSurface(radius: CGFloat = 12) -> some View { modifier(FloatingSurface(radius: radius)) }
    func panelWell(radius: CGFloat = 8) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(VF.well))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(VF.hairline, lineWidth: 1))
    }
}

// Package art (concept crops for the 3D area, tool icons for the ribbon).
enum Art {
    static func image(_ name: String, folder: String = "Art") -> Image {
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder),
           let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        return Image(systemName: "questionmark.square.dashed")
    }

    static func tool(_ name: String) -> Image { image(name, folder: "ToolIcons") }
}
