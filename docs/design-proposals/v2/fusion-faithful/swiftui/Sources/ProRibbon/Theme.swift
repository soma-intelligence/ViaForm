import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Design tokens of the Pro Ribbon direction. Every value comes from the art director's notes.
enum VF {
    static let accent = Color(hex: 0x0A6CFF)
    static let chrome = Color(hex: 0xF5F5F5)
    static let chromeDeep = Color(hex: 0xEDEDED)
    static let separator = Color(hex: 0xDADADA)
    static let secondary = Color(hex: 0x6B6B6B)
    static let ink = Color(hex: 0x1D1D1F)
    static let success = Color(hex: 0x2DBE60)
    static let timeline = Color(hex: 0xF7F7F7)
    static let canvasTop = Color(hex: 0xDCE6F0)
    static let pcbBack = Color(hex: 0x1C1E22)
    static let panel = Color.white

    static let overlayInset: CGFloat = 16
    static let panelPadding: CGFloat = 12
    static let macRow: CGFloat = 29
    static let touchRow: CGFloat = 56

    static func caps(_ size: CGFloat = 11.5) -> Font { .system(size: size, weight: .semibold) }
}

/// True while ImageRenderer draws a screen. AppKit backed controls (popovers, scroll views,
/// materials) do not draw inside ImageRenderer, so the views swap them for plain stand ins.
enum RenderMode {
    static var active = false
}

/// Icons and viewport placeholders shipped in the package resources.
enum Assets {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, folder: String) -> NSImage {
        let key = folder + "/" + name
        if let hit = cache[key] { return hit }
        let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: folder)
        let img = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(size: NSSize(width: 8, height: 8))
        cache[key] = img
        return img
    }
}
