import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    /// Increase Contrast is on: hairlines, strokes and secondary inks are stronger.
    let highContrast: Bool
    var palette: VFPalette { highContrast ? variant.highContrastPalette : variant.palette }

    init(mode: ThemeMode = .default, systemIsDark: Bool = false, highContrast: Bool = false) {
        self.mode = mode
        self.variant = mode.resolve(systemIsDark: systemIsDark)
        self.highContrast = highContrast
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
    /// Fill of the e-stop and destructive buttons, and its label.
    var dangerFill: Color { Color(vf: palette.dangerFill) }
    var onDanger: Color { Color(vf: palette.onDanger) }
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
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        func body(content: Content) -> some View {
            let theme = ViaFormTheme(mode: mode, systemIsDark: system == .dark, highContrast: contrast == .increased)
            content
                .environment(\.viaFormTheme, theme)
                .environment(\.colorScheme, theme.colorScheme)
                // Reduce Transparency: every vfSurface draws a flat, opaque fill instead of a material.
                .environment(\.vfFlatSurfaces, reduceTransparency)
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
        .help("System follows the Mac's or iPad's appearance. Light and Dark pin one.")
    }
}

// MARK: - Fonts

/// The type scale as fonts. On the Mac the sizes are the token sizes (the Mac has no Dynamic
/// Type for app text). On iPad and iPhone each token maps to the text style of the same default
/// size, so every label follows the reader's text size (FRONTEND-SPEC 7.8).
enum VFFont {
    #if os(iOS)
    static var micro: Font { .caption.weight(.medium).monospacedDigit() }
    static var caps: Font { .footnote.weight(.semibold) }
    static var small: Font { .footnote.monospacedDigit() }
    static var row: Font { .subheadline.monospacedDigit() }
    static var rowEmphasis: Font { .subheadline.weight(.semibold).monospacedDigit() }
    static var title: Font { .headline }
    static var heading: Font { .title2.weight(.semibold) }
    static var hud: Font { .title.weight(.semibold).monospacedDigit() }
    static var mono: Font { .footnote.monospaced() }
    /// An SF Symbol inside a control, scaled with the text size.
    static func glyph(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(.body, weight: weight).leading(.tight)
    }
    #else
    static var micro: Font { .system(size: VFTypeScale.micro, weight: .medium).monospacedDigit() }
    static var caps: Font { .system(size: VFTypeScale.caps, weight: .semibold) }
    static var small: Font { .system(size: VFTypeScale.small).monospacedDigit() }
    static var row: Font { .system(size: VFTypeScale.row).monospacedDigit() }
    static var rowEmphasis: Font { .system(size: VFTypeScale.row, weight: .semibold).monospacedDigit() }
    static var title: Font { .system(size: VFTypeScale.title, weight: .semibold) }
    static var heading: Font { .system(size: VFTypeScale.heading, weight: .semibold) }
    static var hud: Font { .system(size: VFTypeScale.hud, weight: .semibold).monospacedDigit() }
    static var mono: Font { .system(size: VFTypeScale.small, design: .monospaced) }
    /// An SF Symbol inside a control.
    static func glyph(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    #endif
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
    /// Overlay floating on the viewport that shows content (HUD numbers, cards, banners): a
    /// near-opaque fill, stroke and shadow. Never glass (HIG: glass is for controls).
    case floating
    /// Navigation and controls floating on the viewport (nav pill, context pill, iPad capsule and
    /// tool groups, job capsule): Liquid Glass, or a flat fill under Reduce Transparency.
    case control
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
        case .control:
            if flat {
                content
                    .background(shape.fill(Color(vf: theme.palette.floating.over(theme.palette.panel))))
                    .overlay(shape.strokeBorder(theme.floatingStroke, lineWidth: VFSize.hairline))
            } else {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay(theme.highContrast ? shape.strokeBorder(theme.floatingStroke, lineWidth: VFSize.hairline) : nil)
            }
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
            case .control:
                #if os(iOS)
                VFRadius.touchFloating
                #else
                VFRadius.floating
                #endif
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

/// A pipeline status mark. Never colour alone (FRONTEND-SPEC 5): each state has its own shape
/// (filled dot current, triangle stale, cross failed, open ring running, hollow dot not built),
/// a tooltip and a VoiceOver value with the reason when one is known.
struct VFStatusDot: View {
    @Environment(\.viaFormTheme) private var theme
    let status: VFStatus
    var size: CGFloat = VFSize.dot
    /// Why ("Frame v12 replaced v11"), read after the state.
    var reason: String? = nil

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
            case .stale:
                VFTriangle().fill(color).frame(width: size + 2, height: size + 1)
            case .failed:
                Image(systemName: "xmark")
                    .font(.system(size: size + 1, weight: .heavy))
                    .foregroundStyle(color)
                    .frame(width: size + 2, height: size + 2)
            case .current:
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .frame(minWidth: size + 3, minHeight: size + 3)
        .help(reason.map { "\(status.word): \($0)" } ?? status.word)
        .accessibilityElement()
        .accessibilityLabel(Text(status.word))
        .accessibilityValue(reason.map { Text($0) } ?? Text(""))
    }
}

/// Upward triangle for the stale mark.
struct VFTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

extension VFStatus {
    var word: String {
        switch self {
        case .current: String(localized: "Up to date")
        case .empty: String(localized: "Not built yet")
        case .stale: String(localized: "Stale")
        case .running: String(localized: "Running")
        case .failed: String(localized: "Failed")
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
/// Height follows the platform (44 pt on iPad); hover lightens on the Mac and with an iPad pointer.
struct VFPrimaryButtonStyle: ButtonStyle {
    var isLoading = false

    func makeBody(configuration: Configuration) -> some View {
        VFButtonBody(configuration: configuration, prominent: true, isLoading: isLoading)
    }
}

/// The secondary action (Cancel, Show, Reveal): ink on a light wash, same size as the primary.
struct VFSecondaryButtonStyle: ButtonStyle {
    var isLoading = false

    func makeBody(configuration: Configuration) -> some View {
        VFButtonBody(configuration: configuration, prominent: false, isLoading: isLoading)
    }
}

private struct VFButtonBody: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let isLoading: Bool
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
        let fill: Color = prominent ? theme.accent : theme.ink.opacity(0.07)
        configuration.label
            .font(VFFont.rowEmphasis)
            .foregroundStyle(prominent ? theme.onAccent : theme.ink)
            // The label keeps its width while a spinner shows, so the button never jumps.
            .opacity(isLoading ? 0 : 1)
            .overlay { if isLoading { ProgressView().controlSize(.small).tint(prominent ? theme.onAccent : theme.ink) } }
            .padding(.horizontal, VFSpace.l)
            .frame(minHeight: VFSize.buttonHeight)
            .background(shape.fill(fill))
            .overlay(shape.fill(Color.white.opacity(hovered && enabled && !configuration.isPressed ? 0.08 : 0)))
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.14 : 0)))
            .overlay(theme.highContrast && !prominent ? shape.strokeBorder(theme.hairline) : nil)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
            .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }
}

extension ButtonStyle where Self == VFPrimaryButtonStyle {
    static var vfPrimary: VFPrimaryButtonStyle { VFPrimaryButtonStyle() }
    static func vfPrimary(loading: Bool) -> VFPrimaryButtonStyle { VFPrimaryButtonStyle(isLoading: loading) }
}

extension ButtonStyle where Self == VFSecondaryButtonStyle {
    static var vfSecondary: VFSecondaryButtonStyle { VFSecondaryButtonStyle() }
    static func vfSecondary(loading: Bool) -> VFSecondaryButtonStyle { VFSecondaryButtonStyle(isLoading: loading) }
}

// MARK: - Motion

extension VFMotion {
    /// Reduce Motion is on: no slides, scales or camera flights; fades at most.
    @MainActor static var reduced: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    /// The animation to use, or nil under Reduce Motion.
    @MainActor static func animation(_ a: Animation) -> Animation? { reduced ? nil : a }
    @MainActor static var fastEase: Animation? { animation(.easeOut(duration: fast)) }
    @MainActor static var standardEase: Animation? { animation(.easeOut(duration: standard)) }
}

/// `withAnimation` that does nothing under Reduce Motion.
@MainActor
func vfWithAnimation<R>(_ animation: Animation = .easeOut(duration: VFMotion.fast), _ body: () throws -> R) rethrows -> R {
    try withAnimation(VFMotion.animation(animation), body)
}

private struct VFAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let animation: Animation
    let value: V
    func body(content: Content) -> some View { content.animation(reduce ? nil : animation, value: value) }
}

private struct VFTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let transition: AnyTransition
    func body(content: Content) -> some View { content.transition(reduce ? .opacity : transition) }
}

extension View {
    /// `.animation(_:value:)` that is off under Reduce Motion.
    func vfAnimation<V: Equatable>(_ animation: Animation = .easeOut(duration: VFMotion.fast), value: V) -> some View {
        modifier(VFAnimationModifier(animation: animation, value: value))
    }

    /// `.transition(_:)` that falls back to a fade under Reduce Motion.
    func vfTransition(_ transition: AnyTransition) -> some View {
        modifier(VFTransitionModifier(transition: transition))
    }
}
