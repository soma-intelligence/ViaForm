import SwiftUI

// SwiftUI side of the ViaForm tokens: the `viaFormTheme` environment value, the root modifier that
// applies the user's Light / Dark / System setting, fonts, surfaces (materials) and small shared marks.

extension Color {
    init(vf c: VFColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

// MARK: - Theme value

/// The resolved theme a view draws with. Read it with `@Environment(\.viaFormTheme)`.
struct ViaFormTheme: Sendable {
    /// What the user picked.
    let mode: ThemeMode
    /// What is drawn (System resolved against the current appearance).
    let variant: ThemeVariant
    var palette: VFPalette { variant.palette }

    init(mode: ThemeMode = .default, systemIsDark: Bool = false) {
        self.mode = mode
        self.variant = mode.resolve(systemIsDark: systemIsDark)
    }

    var colorScheme: ColorScheme { variant == .dark ? .dark : .light }
    var isDark: Bool { variant == .dark }

    // Surfaces
    var chrome: Color { Color(vf: palette.chrome) }
    var chromeDeep: Color { Color(vf: palette.chromeDeep) }
    var panel: Color { Color(vf: palette.panel) }
    var well: Color { Color(vf: palette.well) }
    var floating: Color { Color(vf: palette.floating) }
    var floatingStroke: Color { Color(vf: palette.floatingStroke) }
    var hairline: Color { Color(vf: palette.hairline) }
    var selection: Color { Color(vf: palette.selection) }

    // Text
    var ink: Color { Color(vf: palette.ink) }
    var inkSecondary: Color { Color(vf: palette.inkSecondary) }
    var inkTertiary: Color { Color(vf: palette.inkTertiary) }

    // Accent and status
    var accent: Color { Color(vf: palette.accent) }
    var onAccent: Color { Color(vf: palette.onAccent) }
    var accentText: Color { Color(vf: palette.accentText) }
    var success: Color { Color(vf: palette.success) }
    var warning: Color { Color(vf: palette.warning) }
    var danger: Color { Color(vf: palette.danger) }
    func status(_ s: VFStatus) -> Color { Color(vf: palette.status(s)) }

    // Stage chips
    func stageFill(_ s: VFStage) -> Color { Color(vf: palette.tone(s).fill) }
    func stageLabel(_ s: VFStage) -> Color { Color(vf: palette.tone(s).label) }
    func stageWash(_ s: VFStage) -> Color { Color(vf: palette.tone(s).wash) }

    // Viewport
    var viewportGradient: LinearGradient {
        LinearGradient(colors: [Color(vf: palette.viewportTop), Color(vf: palette.viewportBottom)],
                       startPoint: .top, endPoint: .bottom)
    }

    // Tool chips
    /// The jet icons sit on a light chip in the dark variant (they are satin black).
    var jetIconsNeedChip: Bool { isDark }
    var toolChip: Color { Color(vf: palette.toolChip) }
    var toolChipStroke: Color { Color(vf: palette.toolChipStroke) }
    var toolChipSymbol: Color { Color(vf: palette.toolChipSymbol) }
}

extension EnvironmentValues {
    @Entry var viaFormTheme = ViaFormTheme()
    /// True while ImageRenderer draws a view: materials do not render there, surfaces use flat fills instead.
    @Entry var vfFlatSurfaces = false
}

// MARK: - Root modifier and setting

extension ThemeMode {
    /// `--theme light|dark|system` on the command line wins over the stored setting (screenshots, tests).
    static var launchOverride: ThemeMode? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--theme"), i + 1 < args.count else { return nil }
        return ThemeMode(rawValue: args[i + 1].lowercased())
    }

    /// The scheme to ask the window for; nil follows the system.
    var preferredScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

/// Applies the user's appearance setting to a window's content: asks the window for the scheme,
/// resolves System, injects `viaFormTheme` and tints controls with the accent.
struct ViaFormThemeRoot: ViewModifier {
    @AppStorage(ThemeMode.storageKey) private var stored: String = ThemeMode.default.rawValue
    var override: ThemeMode?

    private var mode: ThemeMode { override ?? ThemeMode.launchOverride ?? ThemeMode(rawValue: stored) ?? .default }

    func body(content: Content) -> some View {
        content
            .modifier(Resolve(mode: mode))
            .preferredColorScheme(mode.preferredScheme)
    }

    private struct Resolve: ViewModifier {
        let mode: ThemeMode
        @Environment(\.colorScheme) private var system

        func body(content: Content) -> some View {
            let theme = ViaFormTheme(mode: mode, systemIsDark: system == .dark)
            content
                .environment(\.viaFormTheme, theme)
                .environment(\.colorScheme, theme.colorScheme)
                .tint(theme.accent)
        }
    }
}

extension View {
    /// Put on each window's root view. `override` pins a mode (previews, offscreen renders).
    func viaFormTheme(_ override: ThemeMode? = nil) -> some View {
        modifier(ViaFormThemeRoot(override: override))
    }
}

/// The Light / Dark / System setting, for a Settings pane or a menu.
struct ThemeModePicker: View {
    @AppStorage(ThemeMode.storageKey) private var stored: String = ThemeMode.default.rawValue
    var showsLabel = true

    var body: some View {
        Picker(selection: $stored) {
            ForEach(ThemeMode.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
            if showsLabel { Text("Appearance") }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Light is the default. System follows the Mac's or iPad's appearance.")
    }
}

// MARK: - Fonts

enum VFFont {
    private static var bump: CGFloat {
        #if os(iOS)
        VFTypeScale.touchBump
        #else
        0
        #endif
    }

    static var micro: Font { .system(size: VFTypeScale.micro + bump, weight: .medium).monospacedDigit() }
    static var caps: Font { .system(size: VFTypeScale.caps + bump, weight: .semibold) }
    static var small: Font { .system(size: VFTypeScale.small + bump).monospacedDigit() }
    static var row: Font { .system(size: VFTypeScale.row + bump).monospacedDigit() }
    static var rowEmphasis: Font { .system(size: VFTypeScale.row + bump, weight: .semibold).monospacedDigit() }
    static var title: Font { .system(size: VFTypeScale.title + bump, weight: .semibold) }
    static var heading: Font { .system(size: VFTypeScale.heading + bump, weight: .semibold) }
    static var hud: Font { .system(size: VFTypeScale.hud, weight: .semibold).monospacedDigit() }
    static var mono: Font { .system(size: VFTypeScale.small + bump, design: .monospaced) }
}

/// Capitalised group caption: ribbon legends, BROWSER, PIPELINE OUTPUTS, inspector sections.
struct VFCaption: View {
    @Environment(\.viaFormTheme) private var theme
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) { self.text = text; self.color = color }

    var body: some View {
        Text(text.uppercased())
            .font(VFFont.caps)
            .tracking(VFTypeScale.capsTracking)
            .foregroundStyle(color ?? theme.inkSecondary)
    }
}

// MARK: - Surfaces (materials)

enum VFSurface {
    /// Window chrome band (toolbar row, status bar).
    case chrome
    /// Ribbon band.
    case ribbon
    /// Docked panel or card.
    case panel
    /// Inset well inside a card.
    case well
    /// Overlay floating on the viewport: material plus tint, stroke and shadow.
    case floating
}

struct VFSurfaceModifier: ViewModifier {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfFlatSurfaces) private var flat
    let kind: VFSurface
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch kind {
        case .chrome:
            content.background(theme.chrome)
        case .ribbon:
            content.background(theme.chromeDeep)
        case .panel:
            content
                .background(shape.fill(theme.panel))
                .overlay(shape.strokeBorder(theme.hairline, lineWidth: VFSize.hairline))
        case .well:
            content
                .background(shape.fill(theme.well))
                .overlay(shape.strokeBorder(theme.hairline, lineWidth: VFSize.hairline))
        case .floating:
            content
                .background {
                    if flat {
                        shape.fill(theme.floating)
                    } else {
                        shape.fill(.ultraThinMaterial).overlay(shape.fill(theme.floating.opacity(0.85)))
                    }
                }
                .overlay(shape.strokeBorder(theme.floatingStroke, lineWidth: VFSize.hairline))
                .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 10, y: 4)
        }
    }
}

extension View {
    func vfSurface(_ kind: VFSurface, radius: CGFloat? = nil) -> some View {
        let r = radius ?? {
            switch kind {
            case .chrome, .ribbon: 0
            case .panel: VFRadius.card
            case .well: VFRadius.well
            case .floating: VFRadius.floating
            }
        }()
        return modifier(VFSurfaceModifier(kind: kind, radius: r))
    }
}

// MARK: - Shared marks

/// The viewport backdrop: grey gradient in light, near-black gradient in dark.
struct ViewportBackdrop: View {
    @Environment(\.viaFormTheme) private var theme
    var body: some View { theme.viewportGradient.ignoresSafeArea() }
}

struct VFHairline: View {
    @Environment(\.viaFormTheme) private var theme
    var vertical = false
    var body: some View {
        Rectangle().fill(theme.hairline)
            .frame(width: vertical ? VFSize.hairline : nil, height: vertical ? nil : VFSize.hairline)
    }
}

/// A pipeline status dot; running draws an open ring.
struct VFStatusDot: View {
    @Environment(\.viaFormTheme) private var theme
    let status: VFStatus
    var size: CGFloat = VFSize.dot

    var body: some View {
        let color = theme.status(status)
        Group {
            switch status {
            case .running:
                Circle().trim(from: 0.08, to: 0.82)
                    .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size / 4), lineCap: .round))
                    .frame(width: size + 3, height: size + 3)
            case .empty:
                Circle().strokeBorder(color, lineWidth: 1).frame(width: size, height: size)
            default:
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .accessibilityLabel(Text(status.word))
    }
}

extension VFStatus {
    var word: String {
        switch self {
        case .current: "Up to date"
        case .empty: "Not built yet"
        case .stale: "Stale"
        case .running: "Running"
        case .failed: "Failed"
        }
    }
}

/// Background of a PipelineBar chip: the stage's accent when active, a wash on hover, clear otherwise.
/// Use `stageChipForeground` for the label.
struct VFStageChipBackground: View {
    @Environment(\.viaFormTheme) private var theme
    let stage: VFStage
    var active: Bool
    var hovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: VFRadius.chip, style: .continuous)
            .fill(active ? theme.stageFill(stage) : hovered ? theme.stageWash(stage) : .clear)
    }
}

extension ViaFormTheme {
    func stageChipForeground(_ stage: VFStage, active: Bool) -> Color {
        active ? stageLabel(stage) : ink
    }
}

/// The app's primary action (Done, Update, Re-run on Frame vN): the single accent, never a stage colour.
struct VFPrimaryButtonStyle: ButtonStyle {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFFont.rowEmphasis)
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, VFSpace.l)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                .fill(theme.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.45)
    }
}

extension ButtonStyle where Self == VFPrimaryButtonStyle {
    static var vfPrimary: VFPrimaryButtonStyle { VFPrimaryButtonStyle() }
}
