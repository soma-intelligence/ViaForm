import CoreGraphics
import Foundation

// ViaForm design tokens: colours, type sizes, spacing, radii and control sizes.
//
// This file is plain Foundation on purpose: the theme test target compiles it alone (no SwiftUI,
// no engine) to check every text token against WCAG AA. SwiftUI wrappers live in ThemeSwiftUI.swift.

// MARK: - Colour value

/// One sRGB colour, 0...1 per channel. Tokens are stored as values so the contrast test can do maths on them.
struct VFColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    func opacity(_ a: Double) -> VFColor { VFColor(red: red, green: green, blue: blue, alpha: alpha * a) }

    /// This colour laid over an opaque `base` (what the eye sees through a translucent fill).
    func over(_ base: VFColor) -> VFColor {
        let a = alpha
        return VFColor(red: red * a + base.red * (1 - a),
                       green: green * a + base.green * (1 - a),
                       blue: blue * a + base.blue * (1 - a))
    }

    /// WCAG 2 relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }

    /// WCAG 2 contrast ratio against an opaque background (1...21). A translucent foreground is composited first.
    func contrast(on background: VFColor) -> Double {
        let bg = background.alpha < 1 ? background.over(VFColor(hex: 0x000000)) : background
        let fg = alpha < 1 ? over(bg) : self
        let a = fg.luminance, b = bg.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The more legible of two label colours on this fill.
    func bestLabel(light: VFColor, dark: VFColor) -> VFColor {
        light.contrast(on: self) >= dark.contrast(on: self) ? light : dark
    }
}

// MARK: - Modes

/// The user's appearance setting. Stored under `ThemeMode.storageKey`.
enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case light, dark, system

    static let storageKey = "viaform.theme.mode"
    /// Light is the house default (grey gradient viewport, light chrome).
    static let `default`: ThemeMode = .light

    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    /// The variant this mode draws with, given what the system currently is.
    func resolve(systemIsDark: Bool) -> ThemeVariant {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: systemIsDark ? .dark : .light
        }
    }
}

enum ThemeVariant: String, CaseIterable, Sendable {
    case light, dark
    var palette: VFPalette { self == .light ? .light : .dark }
}

// MARK: - Stages

/// The 9 pipeline stages, keyed by the Rust core's stage ids (core/src/flow.rs).
/// Each has one chip accent, used only on its active PipelineBar chip and its status dot.
enum VFStage: String, CaseIterable, Sendable {
    case design, generate, assemble, electronics, simulate, train, render, make, robot
}

/// A stage's chip colours in one variant.
struct VFStageTone: Hashable, Sendable {
    /// Fill of the active chip, and the stage's dot (non-text, 3:1 on chrome).
    let fill: VFColor
    /// Label on the filled chip (text, 4.5:1 on `fill`).
    let label: VFColor
    /// Tinted wash behind an inactive-but-hovered chip.
    var wash: VFColor { fill.opacity(0.16) }
}

/// The pipeline's node states (FlowModel.Status raw values).
enum VFStatus: String, CaseIterable, Sendable {
    case current, empty, stale, running, failed
}

// MARK: - Palette

/// Every colour of one variant. Text tokens (`ink`, `inkSecondary`, `inkTertiary`, `accentText`, status
/// colours, stage labels) pass WCAG AA (4.5:1) on every surface they are listed against in `textSurfaces`.
struct VFPalette: Sendable {
    // Surfaces
    /// Window and toolbar chrome.
    let chrome: VFColor
    /// Ribbon band, status bar, sidebar header: one step off the chrome.
    let chromeDeep: VFColor
    /// Inspector, browser and card bodies.
    let panel: VFColor
    /// Inset wells (fields, lists inside cards).
    let well: VFColor
    /// Floating overlays on the viewport (nav pill, HUD, job capsule). Translucent; the live app adds a material.
    let floating: VFColor
    /// Border of floating overlays.
    let floatingStroke: VFColor
    /// 1 pt dividers.
    let hairline: VFColor
    /// Selected row in lists and the browser.
    let selection: VFColor

    // Viewport
    let viewportTop: VFColor
    let viewportBottom: VFColor
    /// Grid opacity multiplier for the Metal viewport.
    let gridOpacity: Double

    // Text
    let ink: VFColor
    let inkSecondary: VFColor
    let inkTertiary: VFColor

    // Accent (one for the whole app: primary buttons, focus, selection)
    let accent: VFColor
    /// Label on an accent fill (Done, Update, Re-run).
    let onAccent: VFColor
    /// Accent used as text or a 1 pt glyph on panels (links, "Update" in a row).
    let accentText: VFColor

    // Status
    let success: VFColor
    let warning: VFColor
    let danger: VFColor

    // Tool icons
    /// Light chip behind the satin-black jet icons in the dark variant. Clear in light.
    let toolChip: VFColor
    let toolChipStroke: VFColor
    /// Approximate ink of the rendered jet icons (they are near-black satin).
    let jetInk: VFColor
    /// SF Symbol colour inside a tool chip.
    let toolChipSymbol: VFColor

    let stageTones: [VFStage: VFStageTone]

    func tone(_ stage: VFStage) -> VFStageTone { stageTones[stage]! }

    func status(_ s: VFStatus) -> VFColor {
        switch s {
        case .current: success
        case .empty: inkTertiary
        case .stale: warning
        case .running: accentText
        case .failed: danger
        }
    }

    /// Opaque surfaces that text sits on, with the floating overlay composited over both viewport ends.
    var textSurfaces: [(name: String, color: VFColor)] {
        [("chrome", chrome), ("chromeDeep", chromeDeep), ("panel", panel), ("well", well),
         ("selection", selection.over(panel)),
         ("floating/viewportTop", floating.over(viewportTop)),
         ("floating/viewportBottom", floating.over(viewportBottom))]
    }

    // MARK: Light (default)

    static let light: VFPalette = {
        let darkLabel = VFColor(hex: 0x111215), lightLabel = VFColor(hex: 0xFFFFFF)
        func tone(_ hex: UInt32) -> VFStageTone {
            let fill = VFColor(hex: hex)
            return VFStageTone(fill: fill, label: fill.bestLabel(light: lightLabel, dark: darkLabel))
        }
        return VFPalette(
            chrome: VFColor(hex: 0xF5F5F5),
            chromeDeep: VFColor(hex: 0xEDEDED),
            panel: VFColor(hex: 0xFFFFFF),
            well: VFColor(hex: 0xF2F2F4),
            floating: VFColor(hex: 0xFFFFFF, alpha: 0.94),
            floatingStroke: VFColor(hex: 0x000000, alpha: 0.10),
            hairline: VFColor(hex: 0xDADADA),
            selection: VFColor(hex: 0x0A6CFF, alpha: 0.12),
            viewportTop: VFColor(hex: 0xEEF0F3),
            viewportBottom: VFColor(hex: 0xC8CDD4),
            gridOpacity: 1,
            ink: VFColor(hex: 0x1D1D1F),
            inkSecondary: VFColor(hex: 0x56565B),
            inkTertiary: VFColor(hex: 0x66666B),
            accent: VFColor(hex: 0x0A6CFF),
            onAccent: lightLabel,
            accentText: VFColor(hex: 0x0058D0),
            success: VFColor(hex: 0x15703A),
            warning: VFColor(hex: 0x9A5200),
            danger: VFColor(hex: 0xC4261D),
            toolChip: VFColor(hex: 0xFFFFFF, alpha: 0),
            toolChipStroke: VFColor(hex: 0x000000, alpha: 0),
            jetInk: VFColor(hex: 0x1A1B1E),
            toolChipSymbol: VFColor(hex: 0x1D1D1F),
            stageTones: [
                .design: tone(0x2F6FDE),
                .generate: tone(0xC42E83),
                .assemble: tone(0x7445D9),
                .electronics: tone(0xA35F00),
                .simulate: tone(0x0B7D63),
                .train: tone(0x4A7A0C),
                .render: tone(0xCC3B2E),
                .make: tone(0xB4500A),
                .robot: tone(0x0E7490),
            ])
    }()

    // MARK: Dark (#1C1E22)

    static let dark: VFPalette = {
        let darkLabel = VFColor(hex: 0x0B0C0E), lightLabel = VFColor(hex: 0xFFFFFF)
        func tone(_ hex: UInt32) -> VFStageTone {
            let fill = VFColor(hex: hex)
            return VFStageTone(fill: fill, label: fill.bestLabel(light: lightLabel, dark: darkLabel))
        }
        return VFPalette(
            chrome: VFColor(hex: 0x1C1E22),
            chromeDeep: VFColor(hex: 0x17191C),
            panel: VFColor(hex: 0x24262B),
            well: VFColor(hex: 0x1A1C20),
            floating: VFColor(hex: 0x1F2024, alpha: 0.92),
            floatingStroke: VFColor(hex: 0xFFFFFF, alpha: 0.10),
            hairline: VFColor(hex: 0x34373D),
            selection: VFColor(hex: 0x3D8BFF, alpha: 0.16),
            viewportTop: VFColor(hex: 0x2A2C31),
            viewportBottom: VFColor(hex: 0x17181B),
            gridOpacity: 0.55,
            ink: VFColor(hex: 0xF2F3F5),
            inkSecondary: VFColor(hex: 0xAEB2BA),
            inkTertiary: VFColor(hex: 0x9CA1AA),
            accent: VFColor(hex: 0x2A6BDA),
            onAccent: lightLabel,
            accentText: VFColor(hex: 0x6AA6FF),
            success: VFColor(hex: 0x3DD068),
            warning: VFColor(hex: 0xFFB020),
            danger: VFColor(hex: 0xFF7B70),
            toolChip: VFColor(hex: 0xE6E8EC),
            toolChipStroke: VFColor(hex: 0xFFFFFF, alpha: 0.55),
            jetInk: VFColor(hex: 0x1A1B1E),
            toolChipSymbol: VFColor(hex: 0x1D1D1F),
            stageTones: [
                .design: tone(0x3B82F6),
                .generate: tone(0xE0409B),
                .assemble: tone(0x8B5CF6),
                .electronics: tone(0xF5A524),
                .simulate: tone(0x14C9A0),
                .train: tone(0x84CC16),
                .render: tone(0xFF6B5A),
                .make: tone(0xF97316),
                .robot: tone(0x22D3EE),
            ])
    }()
}

// MARK: - Type scale

/// Point sizes of the type scale (SF Pro; numbers use monospaced digits). Mac first; Touch adds `touchBump`.
enum VFTypeScale {
    /// Badges, timeline numbers, legend ticks.
    static let micro: CGFloat = 10
    /// Capitalised group captions (ribbon legends, BROWSER, PIPELINE OUTPUTS). Semibold, tracking 0.5.
    static let caps: CGFloat = 11
    static let capsTracking: CGFloat = 0.5
    /// Secondary rows, status bar, chip labels.
    static let small: CGFloat = 12
    /// Default row text in the browser and inspector.
    static let row: CGFloat = 13
    /// Card and dialog titles.
    static let title: CGFloat = 15
    /// Window-level heading (empty states, stage overview).
    static let heading: CGFloat = 20
    /// Flight HUD readouts.
    static let hud: CGFloat = 28
    /// Added to every size on iPad.
    static let touchBump: CGFloat = 2

    static let all: [CGFloat] = [micro, caps, small, row, title, heading, hud]
}

// MARK: - Spacing, radii, sizes

/// 4 pt grid with a 2 pt half step.
enum VFSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 24
    /// Inset of floating overlays from the viewport edge.
    static let overlayInset: CGFloat = 16
    /// Inner padding of panels and cards.
    static let panelPadding: CGFloat = 12
}

enum VFRadius {
    static let chip: CGFloat = 5
    static let control: CGFloat = 6
    static let well: CGFloat = 8
    static let card: CGFloat = 10
    static let floating: CGFloat = 12
    static let sheet: CGFloat = 16
}

enum VFSize {
    /// Browser and inspector row height on Mac.
    static let macRow: CGFloat = 29
    /// Row height on iPad (oeil + cadenas rows).
    static let touchRow: CGFloat = 48
    /// Smallest hit target on iPad.
    static let touchTarget: CGFloat = 44
    /// Jet icon in the Design ribbon.
    static let ribbonIcon: CGFloat = 42
    /// Jet icon in dense secondary ribbons and menus.
    static let ribbonIconSmall: CGFloat = 20
    /// PipelineBar chip height.
    static let chip: CGFloat = 22
    /// Status dot.
    static let dot: CGFloat = 6
    static let sidebarMin: CGFloat = 230
    static let sidebarMax: CGFloat = 280
    static let inspector: CGFloat = 280
    /// iPad inspector card.
    static let touchInspector: CGFloat = 320
    /// iPad tool rail.
    static let touchRail: CGFloat = 44
    /// Hairline width.
    static let hairline: CGFloat = 1
}

/// Motion: every transition in the app is short or absent, so a click never waits on a fade.
/// `fast` for pops, toggles and overlays; `standard` for panels that slide. Nothing reaches
/// 200 ms (the efficiency pass, 2026-11-06).
enum VFMotion {
    static let fast: Double = 0.12
    static let standard: Double = 0.16
    /// The longest any animation may run.
    static let ceiling: Double = 0.2
}
