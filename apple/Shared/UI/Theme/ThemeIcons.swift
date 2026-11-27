import SwiftUI

// Jet tool icons in the theme. CommandIcon picks the picture (rendered satin-black PNG or SF Symbol);
// this decides what it sits on. In light it sits straight on the chrome; in dark it sits on a light
// chip, because the satin-black renders fall under 3:1 on #1C1E22 (see ThemeContrastTests).

enum ToolChipStyle {
    /// Chip in the dark variant only.
    case auto
    /// Always on a chip (pinned tools, iPad rail).
    case always
    /// Never (the caller draws its own background).
    case never
}

struct ToolChipIcon: View {
    @Environment(\.viaFormTheme) private var theme
    private let icon: CommandIcon
    private let size: CGFloat
    var style: ToolChipStyle = .auto

    /// A registry command (its `icon` name and id).
    init(icon: String, id: String, size: CGFloat = VFSize.ribbonIconSmall, style: ToolChipStyle = .auto) {
        if let symbol = Self.renderSymbol(id) {
            // The render commands share one icon in the catalog: give each its own picture.
            self.icon = CommandIcon(art: nil, symbol: symbol, size: size)
        } else {
            self.icon = CommandIcon(icon: icon, id: id, size: size)
        }
        self.size = size
        self.style = style
    }

    /// One of the app's tools.
    init(tool: Tool, size: CGFloat = VFSize.ribbonIconSmall, style: ToolChipStyle = .auto) {
        self.icon = CommandIcon(tool: tool, size: size)
        self.size = size
        self.style = style
    }

    /// Any action: a rendered icon name when it has one, else the SF Symbol.
    init(art: String?, symbol: String, size: CGFloat = VFSize.ribbonIconSmall, style: ToolChipStyle = .auto) {
        self.icon = CommandIcon(art: art, symbol: symbol, size: size)
        self.size = size
        self.style = style
    }

    /// A distinct symbol for each render command (image, batch, results, scene, lights...).
    static func renderSymbol(_ id: String) -> String? {
        guard id.hasPrefix("render") else { return nil }
        let table: [(String, String)] = [
            ("batch", "square.stack.3d.down.right"), ("export", "square.and.arrow.up"), ("save", "square.and.arrow.down"),
            ("result", "photo.on.rectangle.angled"), ("gallery", "photo.on.rectangle.angled"), ("compare", "rectangle.split.2x1"),
            ("environment", "sun.horizon"), ("scene", "sun.max"), ("light", "lightbulb"), ("background", "rectangle.fill"),
            ("ground", "square.bottomhalf.filled"), ("camera", "camera"), ("material", "paintpalette"), ("appearance", "paintbrush"),
            ("decal", "seal"), ("canvas", "photo"), ("turntable", "arrow.triangle.2.circlepath.camera"), ("animation", "film"),
            ("stop", "stop.circle"), ("start", "camera.aperture"), ("image", "camera.aperture"),
        ]
        return table.first { id.contains($0.0) }?.1 ?? "camera.aperture"
    }

    private var chipped: Bool {
        switch style {
        // The light chip by default, in both themes: the satin icons never stand bare.
        case .auto: true
        case .always: true
        case .never: false
        }
    }

    var body: some View {
        if chipped {
            let side = size + 14
            let shape = RoundedRectangle(cornerRadius: max(VFRadius.chip, side * 0.22), style: .continuous)
            icon
                // On the light chip the icon must draw as on a light ribbon (no light rim, dark symbol).
                .environment(\.colorScheme, .light)
                .foregroundStyle(theme.toolChipSymbol)
                .frame(width: side, height: side)
                .background(shape.fill(chipFill))
                .overlay(shape.strokeBorder(theme.toolChipStroke, lineWidth: VFSize.hairline))
        } else {
            icon.foregroundStyle(theme.ink)
        }
    }

    /// The chip colour; in light (style .always) it uses the panel white with a hairline.
    private var chipFill: Color { theme.isDark ? theme.toolChip : theme.panel }
}

/// A ribbon button face: jet icon (on its chip in dark) over a capitalised caption.
struct RibbonToolFace: View {
    @Environment(\.viaFormTheme) private var theme
    let icon: ToolChipIcon
    let caption: String
    var hasMenu = false

    var body: some View {
        VStack(spacing: VFSpace.xs) {
            icon
            HStack(spacing: VFSpace.xxs) {
                Text(caption.uppercased())
                    .font(.system(size: VFTypeScale.micro, weight: .semibold))
                    .tracking(VFTypeScale.capsTracking)
                    .lineLimit(1)
                if hasMenu {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(theme.inkSecondary)
        }
        .padding(.horizontal, VFSpace.xs)
        .contentShape(Rectangle())
    }
}
