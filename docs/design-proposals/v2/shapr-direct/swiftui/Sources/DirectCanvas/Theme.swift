import SwiftUI
import AppKit

/// Direction "Direct Canvas": one light theme, one accent.
enum VF {
    static let accent = Color(hex: 0x4F5BD5)
    static let accentSoft = Color(hex: 0x4F5BD5, opacity: 0.10)
    static let ok = Color(hex: 0x34C759)
    static let text = Color(hex: 0x1D1D1F)
    static let secondary = Color(hex: 0x8E8E93)
    static let track = Color(hex: 0xEEEFF2)
    static let hairline = Color.black.opacity(0.06)
    static let divider = Color.black.opacity(0.07)
    // Viewport gradient, tuned between the spec (#F4F5F7 to #E6E8EC) and the concept renders.
    static let vpTop = Color(hex: 0xEEF0F4)
    static let vpBottom = Color(hex: 0xE3E6EC)
    static let red = Color(hex: 0xE5483B)
    static let orange = Color(hex: 0xF08A3C)
}

enum Device { case mac, pad
    var row: CGFloat { self == .mac ? 32 : 48 }
    var rowFont: CGFloat { self == .mac ? 13 : 15 }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Floating card: white 92 percent, hairline, soft shadow (black 8 percent, r 20, y 6).
/// In the real app the fill becomes .regularMaterial (light) or .thickMaterial on #1C1C1E (dark).
struct CardBackground: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(VF.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func card(_ radius: CGFloat = 16) -> some View { modifier(CardBackground(radius: radius)) }
}

enum Asset {
    static func image(_ name: String) -> Image {
        if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
           let img = NSImage(contentsOf: url) {
            return Image(nsImage: img)
        }
        return Image(systemName: "questionmark.square.dashed")
    }
}

/// Concept images are 1536 x 1024. Screens place models and anchors in concept
/// coordinates and map them to the live size, the way the real app maps a
/// projected 3D anchor (OrbitCamera.project) into view space.
struct ConceptSpace {
    let size: CGSize
    var sx: CGFloat { size.width / 1536 }
    var sy: CGFloat { size.height / 1024 }
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
    func rect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0 * sx, y: y0 * sy, width: (x1 - x0) * sx, height: (y1 - y0) * sy)
    }
}

/// Places one model image at a concept rectangle, keeping its aspect ratio.
struct ModelImage: View {
    let name: String
    let rect: CGRect
    var body: some View {
        Asset.image(name)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}
