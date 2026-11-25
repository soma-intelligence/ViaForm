#if os(macOS)
import AppKit
import SwiftUI

// The Mac design window drawn after Fusion's newest desktop layout (docs/research/cad-ui/
// fusion-desktop.md, sections 1 and 2): grey application bar, a light toolbar with the DESIGN
// dropdown and the SOLID / SURFACE / MESH / SHEET METAL / PLASTIC / UTILITIES / MANAGE tabs (SKETCH
// while sketching), panels of big icons over a "CREATE ▾" legend, the floating BROWSER, the
// COMMENTS bar, the status text at the bottom right of the canvas and the timeline strip. Icons are
// SF Symbols and the name is ViaForm's; colours are the tokens below.

// MARK: - Tokens

/// Colours and sizes of the Fusion-like chrome, light and dark. Sizes are points in a window; the
/// reference was measured on 1280-wide frames and scaled by 1.25 (a 1600-point window).
struct FusionTokens {
    let isDark: Bool

    init(_ theme: ViaFormTheme) { isDark = theme.isDark }

    private func c(_ light: UInt32, _ dark: UInt32, _ alpha: Double = 1) -> Color {
        Color(vf: VFColor(hex: isDark ? dark : light, alpha: alpha))
    }

    /// Application bar (behind the document tab) and the window's title area.
    var appBar: Color { c(0xD4D4D4, 0x1E1E1E) }
    /// The open document's tab, the toolbar, the browser header and the timeline strip.
    var surface: Color { c(0xF4F4F4, 0x2D2D2D) }
    /// The canvas behind the model.
    var canvas: Color { c(0xFDFDFD, 0x3A3A3A) }
    /// Panels that float over the canvas (dialogs, palette): white.
    var card: Color { c(0xFFFFFF, 0x333333) }
    /// Thin borders and separators.
    var line: Color { c(0xD0D0D0, 0x4A4A4A) }
    var lineSoft: Color { c(0xE3E3E3, 0x3F3F3F) }
    /// Text and icons.
    var ink: Color { c(0x3C3C3C, 0xE6E6E6) }
    var inkSoft: Color { c(0x666666, 0xB4B4B4) }
    var inkFaint: Color { c(0x9A9A9A, 0x7E7E7E) }
    /// The reference's blue: active tab underline, the selected row, the active selection button.
    var blue: Color { c(0x0696D7, 0x38ABE0) }
    /// The SKETCH tab and the FINISH SKETCH panel wash.
    var sketchWash: Color { c(0xC9EEFB, 0x1F4A5E) }
    /// The FINISH SKETCH check.
    var finishGreen: Color { c(0x5EB82A, 0x6CC63A) }
    /// Glyphs on the blue and green fills.
    var onBlue: Color { c(0xFFFFFF, 0xFFFFFF) }
    /// The ribbon icons' second tone (hierarchical SF Symbols tinted toward the reference's blue).
    var iconTint: Color { c(0x1E7FB8, 0x5DB7E6) }
    /// Row label backdrop in the floating browser (the canvas shows through between rows).
    var rowWash: Color { c(0xF4F4F4, 0x2D2D2D, 0.86) }

    // Sizes
    static let tabRow: CGFloat = 20
    static let panelRow: CGFloat = 54
    static let ribbonHeight: CGFloat = tabRow + panelRow
    static let designBox = CGSize(width: 92, height: 50)
    static let icon: CGFloat = 21
    static let iconCell = CGSize(width: 30, height: 30)
    static let browserWidth: CGFloat = 244
    static let browserHeader: CGFloat = 20
    static let browserRow: CGFloat = 20
    static let timeline: CGFloat = 40
    static let bottomBar: CGFloat = 18
    static let dialogWidth: CGFloat = 260
    static let paletteWidth: CGFloat = 210
    static let cube: CGFloat = 66

    // Fonts
    static var tab: Font { VFFont.glyph(10) }
    static var caption: Font { VFFont.glyph(9.5) }
    static var row: Font { VFFont.glyph(11) }
    static var header: Font { VFFont.glyph(10) }
}

extension ViaFormTheme {
    /// The Fusion chrome's tokens for this theme.
    var fusion: FusionTokens { FusionTokens(self) }

    /// The viewport on Fusion's canvas: near white in light (the theme's gradient in dark), the
    /// reference's blue for picks.
    var fusionViewport: ViewportTheme {
        var v = viewportTheme
        guard !isDark else { return v }
        let canvas = VFColor(hex: 0xFDFDFD).simd, blue = VFColor(hex: 0x0696D7)
        v.backgroundTop = canvas
        v.backgroundBottom = canvas
        v.highlight = blue.simd
        v.hover = blue.opacity(0.55).simd
        return v
    }
}

/// What the Fusion layout adds to the 3D canvas: the floating browser and the status text.
struct FusionCanvasChrome {
    var browser: AnyView?
    var status: String
}

// MARK: - Ribbon layout

/// Which Fusion tab and panel each registry command sits in, and each panel's icon row.
@MainActor
enum FusionRibbon {
    /// Fusion's Design tabs in its order; SKETCH is added while a sketch is open.
    static let designTabs = ["SOLID", "SURFACE", "MESH", "SHEET METAL", "PLASTIC", "UTILITIES", "MANAGE"]

    /// Panels shared by every Design tab, after the tab's own (reference frames gKGP1iFhd1s @ 3:30:00).
    static let sharedPanels = ["CONSTRUCT", "INSPECT", "INSERT", "SELECT"]

    /// The tab a registry command belongs to in the reference.
    static func tab(of c: CommandInfo) -> String {
        switch c.id {
        case "file.save_mesh", "file.send_to_slicer", "timeline.play": return "UTILITIES"
        default: break
        }
        switch c.tab {
        case "INSPECT", "INSERT", "WELDMENTS", "": return "SOLID"
        default: return c.tab
        }
    }

    /// The panel a registry command belongs to in the reference.
    static func panel(of c: CommandInfo) -> String {
        switch c.id {
        case "file.save_mesh", "file.send_to_slicer": return "MAKE"
        case "timeline.play": return "UTILITY"
        case "joint.origin": return "ASSEMBLE"
        default: break
        }
        switch c.tab {
        case "INSPECT": return "INSPECT"
        case "INSERT": return "INSERT"
        case "WELDMENTS": return "CREATE"
        default: return c.panel.isEmpty ? "CREATE" : c.panel.uppercased()
        }
    }

    /// The tabs of the ribbon for a stage: Fusion's Design tabs, Render's own, or Assemble's.
    static func tabs(workspace: Workspace, commands: [CommandInfo], sketchOpen: Bool) -> [String] {
        switch workspace {
        case .render:
            var seen: [String] = []
            for c in commands where c.tab.hasPrefix("RENDER") && !seen.contains(c.tab) { seen.append(c.tab) }
            return seen.isEmpty ? ["RENDER"] : seen
        default:
            return designTabs + (sketchOpen ? ["SKETCH"] : [])
        }
    }

    /// The panels of one tab, in the reference's order. SOLID: CREATE, AUTOMATE, MODIFY, ASSEMBLE,
    /// CONFIGURE, CONSTRUCT, INSPECT, INSERT, SELECT, then POSITION. Panels with no command are left out.
    static func panels(tab: String, commands: [CommandInfo]) -> [RibbonPanelModel] {
        if tab == "SKETCH" {
            // CREATE, MODIFY, CONSTRAINTS, CONFIGURE, INSPECT, INSERT, SELECT (FINISH SKETCH after).
            let sketch = StageRibbon.panels(tab: tab, commands: commands)
            let configure = commands.filter { $0.tab == "SOLID" && $0.panel.uppercased() == "CONFIGURE" }
            var list: [RibbonPanelModel] = []
            for name in ["CREATE", "MODIFY", "CONSTRAINTS", "CONFIGURE", "INSPECT", "INSERT"] {
                if name == "CONFIGURE" {
                    if !configure.isEmpty { list.append(RibbonPanelModel(name: name, commands: configure)) }
                } else if let p = sketch.first(where: { $0.name.uppercased() == name }) {
                    list.append(p)
                }
            }
            // Any other registry panel of the sketch (PATTERN) folds into CREATE, as in the reference.
            let known = Set(["CREATE", "MODIFY", "CONSTRAINTS", "CONFIGURE", "INSPECT", "INSERT"])
            let extra = sketch.filter { !known.contains($0.name.uppercased()) }.flatMap(\.commands)
            if !extra.isEmpty, let i = list.firstIndex(where: { $0.name.uppercased() == "CREATE" }) {
                list[i] = RibbonPanelModel(name: list[i].name, commands: list[i].commands + extra)
            }
            return list + [RibbonPanelModel(name: "SELECT", commands: [])]
        }
        if tab.hasPrefix("RENDER") || tab == StageRibbon.assemblyTab {
            return StageRibbon.panels(tab: tab, commands: commands)
        }
        let own: [String]
        switch tab {
        case "SOLID": own = ["CREATE", "AUTOMATE", "MODIFY", "ASSEMBLE", "CONFIGURE"]
        case "SURFACE", "SHEET METAL", "MESH": own = ["CREATE", "MODIFY", "ASSEMBLE"]
        case "PLASTIC": own = ["CREATE", "SETUP", "MODIFY", "ASSEMBLE"]
        case "UTILITIES": own = ["MAKE", "ADD-INS", "UTILITY"]
        case "MANAGE": own = ["CONFIGURE"]
        default: own = []
        }
        var order = own + sharedPanels
        if tab == "SOLID" { order.append("POSITION") }
        var by: [String: [CommandInfo]] = [:]
        for c in commands where c.panel != "FINISH SKETCH" && c.tab != "SKETCH" && !c.tab.hasPrefix("RENDER") {
            let t = Self.tab(of: c), p = Self.panel(of: c)
            let sharedHere = sharedPanels.contains(p) && t != tab
            // A shared panel (INSPECT, INSERT...) shows its SOLID commands on every tab.
            if t == tab || (sharedHere && t == "SOLID") {
                by[p, default: []].append(c)
            } else if tab == "MANAGE", p == "CONFIGURE" || c.id == "parameters.change" {
                by["CONFIGURE", default: []].append(c)
            } else if tab != "SOLID", p == "ASSEMBLE", t == "SOLID" {
                by["ASSEMBLE", default: []].append(c)
            }
        }
        // MODIFY keeps Change Parameters in SOLID; MANAGE lists it under CONFIGURE.
        return order.compactMap { name in
            if name == "SELECT" { return RibbonPanelModel(name: "SELECT", commands: []) }
            guard let list = by[name], !list.isEmpty else { return nil }
            return RibbonPanelModel(name: name, commands: dedupe(list))
        }
    }

    private static func dedupe(_ list: [CommandInfo]) -> [CommandInfo] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// The reference's icon row for a panel (frame 7lKpzGtoQX0 @ 0:40); else the keyed commands first.
    static func row(_ panel: RibbonPanelModel, tab: String) -> [CommandInfo] {
        if let sketch = SketchRibbonTools.mainRow(panel) { return sketch }
        let ids: [String]
        switch (tab, panel.name) {
        case ("SOLID", "CREATE"): ids = ["sketch.create", "solid.extrude", "solid.revolve", "solid.hole", "solid.pattern.rectangular", "solid.mirror"]
        case ("SOLID", "MODIFY"): ids = ["solid.press_pull", "solid.fillet", "solid.chamfer", "solid.shell", "solid.combine", "solid.move"]
        case (_, "ASSEMBLE"): ids = ["component.create", "joint.create", "joint.as_built"]
        case (_, "CONFIGURE"): ids = ["config.configure", "config.table"]
        case (_, "CONSTRUCT"): ids = ["construct.plane.offset"]
        case (_, "INSPECT"): ids = ["inspect.measure"]
        case (_, "INSERT"): ids = ["file.insert_step", "parts.fastener", "file.insert_mesh"]
        case (_, "POSITION"): ids = ["component.capture_position", "component.revert_position"]
        case ("SURFACE", "CREATE"): ids = ["sketch.create", "surface.extrude", "surface.revolve", "surface.patch", "surface.offset", "surface.thicken"]
        case ("SURFACE", "MODIFY"): ids = ["surface.trim", "surface.untrim", "surface.extend", "surface.stitch", "surface.unstitch"]
        case ("SHEET METAL", "CREATE"): ids = ["sketch.create", "sheet.flange", "sheet.convert", "sheet.flat_pattern"]
        case ("SHEET METAL", "MODIFY"): ids = ["sheet.unfold", "sheet.refold", "sheet.manage_rules"]
        default: ids = []
        }
        var picked = ids.compactMap { id in panel.commands.first { $0.id == id } }
        if picked.isEmpty {
            let keyed = panel.commands.filter { $0.key != nil }
            picked = Array((keyed + panel.commands.filter { $0.key == nil }).prefix(panel.commands.count <= 3 ? 3 : 2))
        }
        // Pinned commands ("Pin to Toolbar") join their own panel's row, as in the reference.
        let pins = RibbonPins.pinned(in: .standard)
        for c in panel.commands where pins.contains(c.id) && !picked.contains(where: { $0.id == c.id }) { picked.append(c) }
        return picked
    }

    /// Fusion's spelling for a command label (ViaForm's registry already uses it; this keeps
    /// the Mac ribbon off the Touch app's renamed words).
    static func label(_ raw: String) -> String { raw }
}

// MARK: - Tabs

/// The toolbar's tab row: small capitals, the active tab underlined in blue, SKETCH washed blue.
struct FusionTabs: View {
    @Environment(\.viaFormTheme) private var theme
    let tabs: [String]
    @Binding var tab: String

    var body: some View {
        let f = theme.fusion
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                let on = tab == t
                let sketch = t == "SKETCH"
                Button { tab = t } label: {
                    Text(t)
                        .font(FusionTokens.tab)
                        .foregroundStyle(sketch ? f.blue : f.ink)
                        .padding(.horizontal, 14)
                        .frame(height: FusionTokens.tabRow)
                        .background(sketch ? f.sketchWash : .clear)
                        .overlay(alignment: .bottom) { if on { Rectangle().fill(f.blue).frame(height: 2) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.capitalized)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .frame(height: FusionTokens.tabRow)
    }
}

// MARK: - Panels

/// One ribbon panel: a row of big icons over its legend; the legend's ▾ lists every command.
struct FusionPanelView: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let panel: RibbonPanelModel
    let tab: String

    var body: some View {
        let f = theme.fusion
        VStack(spacing: 2) {
            HStack(spacing: 1) {
                ForEach(FusionRibbon.row(panel, tab: tab)) { c in
                    FusionIconButton(command: c, model: model)
                }
            }
            Menu {
                if let entries = SketchRibbonTools.entries(panel) {
                    ForEach(entries) { e in
                        switch e {
                        case .command(let c): RibbonMenuRow(model: model, command: c)
                        case .submenu(let title, let cs):
                            Menu {
                                ForEach(cs) { c in RibbonMenuRow(model: model, command: c) }
                            } label: {
                                Label(title, systemImage: CommandSymbol.of(cs[0].icon, id: cs[0].id))
                            }
                        }
                    }
                } else {
                    ForEach(panel.commands) { c in RibbonMenuRow(model: model, command: c) }
                }
                Divider()
                PinMenu(commands: panel.commands)
            } label: {
                FusionLegend(text: panel.name)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(f.ink)
        }
        .padding(.horizontal, 5)
        .frame(height: FusionTokens.panelRow)
    }
}

/// "CREATE ▾": the panel's legend under its icons.
struct FusionLegend: View {
    @Environment(\.viaFormTheme) private var theme
    let text: String

    var body: some View {
        Text(text.uppercased() + " \u{25BE}")
            .font(FusionTokens.caption)
            .foregroundStyle(theme.fusion.ink)
            .fixedSize()
    }
}

/// A big ribbon icon: the command's SF Symbol in two tones, lit while its tool is armed.
struct FusionIconButton: View {
    @Environment(\.viaFormTheme) private var theme
    let command: CommandInfo
    let model: DesignModel
    @State private var hover = false

    var body: some View {
        let f = theme.fusion
        let on = model.tool.commandID == command.id && model.tool != .select
        Button { CommandRouter.run(command, model) } label: {
            Image(systemName: CommandSymbol.of(command.icon, id: command.id))
                .symbolRenderingMode(.palette)
                .foregroundStyle(on ? f.onBlue : f.iconTint, on ? f.onBlue.opacity(0.7) : f.inkSoft)
                .font(VFFont.glyph(FusionTokens.icon))
                .frame(width: FusionTokens.iconCell.width, height: FusionTokens.iconCell.height)
                .background(RoundedRectangle(cornerRadius: 2).fill(on ? f.blue : (hover ? f.lineSoft : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(RibbonPins.tooltip(command))
        .accessibilityLabel(command.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// SELECT: the selection tool's icon over "SELECT ▾" (Select, the filters).
struct FusionSelectPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel

    var body: some View {
        let f = theme.fusion
        VStack(spacing: 2) {
            Button { model.genericCommand = nil; model.cancelTool() } label: {
                Image(systemName: "cursorarrow.square")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(f.iconTint, f.inkSoft)
                    .font(VFFont.glyph(FusionTokens.icon))
                    .frame(width: FusionTokens.iconCell.width, height: FusionTokens.iconCell.height)
                    .background(RoundedRectangle(cornerRadius: 2).fill(model.tool == .select && model.genericCommand == nil ? f.lineSoft : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Select\nHold Command to add or remove objects from the selection."))
            .accessibilityLabel("Select")
            Menu {
                Button("Select") { model.genericCommand = nil; model.cancelTool() }
                Divider()
                Menu("Selection Filters") { SelectFilterMenuItems(model: model) }
            } label: {
                FusionLegend(text: "Select")
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 5)
        .frame(height: FusionTokens.panelRow)
    }
}

/// FINISH SKETCH: the big green check on a blue wash, its ▾ with Finish Sketch.
struct FusionFinishSketchPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        let f = theme.fusion
        VStack(spacing: 2) {
            Button { model.finishSketch() } label: {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(f.onBlue, f.finishGreen)
                    .font(VFFont.glyph(24))
                    .frame(width: FusionTokens.iconCell.width + 10, height: FusionTokens.iconCell.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(model.tool == .select && model.genericCommand == nil ? KeyboardShortcut(.return, modifiers: []) : nil)
            .help("Finish Sketch (Return)")
            .accessibilityLabel("Finish Sketch")
            Menu {
                Button("Finish Sketch") { model.finishSketch() }
            } label: {
                FusionLegend(text: "Finish Sketch")
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: FusionTokens.panelRow)
        .background(f.sketchWash.opacity(0.7))
    }
}

/// The panels of the open tab, separated by thin rules; the last ones fold into a ▾ menu when the
/// window is too narrow for all of them.
struct FusionPanelStrip: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let panels: [RibbonPanelModel]
    let tab: String

    var body: some View {
        let f = theme.fusion
        ViewThatFits(in: .horizontal) {
            ForEach((0...panels.count).reversed(), id: \.self) { k in
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(panels.prefix(k).enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Rectangle().fill(f.line).frame(width: 1, height: 44) }
                        panelView(p)
                    }
                    if k < panels.count { MorePanel(model: model, panels: Array(panels.dropFirst(k))) }
                    if tab == "SKETCH" {
                        Rectangle().fill(f.line).frame(width: 1, height: 44)
                        FusionFinishSketchPanel(model: model)
                    }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder private func panelView(_ p: RibbonPanelModel) -> some View {
        if p.name == "SELECT" {
            FusionSelectPanel(model: model)
        } else if p.name == "CONSTRAINTS" && model.sketchOpen {
            ConstraintRibbonPanel(model: model, panel: p, fusion: true)
                .frame(height: FusionTokens.panelRow)
        } else {
            FusionPanelView(model: model, panel: p, tab: tab)
        }
    }
}

// MARK: - Application bar

/// The open document's tab in the application bar: the design icon, the name with its version
/// and `*` while unsaved, and the close cross; the running job rides at its right.
struct FusionDocTab: View {
    @Environment(\.viaFormTheme) private var theme
    let title: String
    let edited: Bool
    let flow: FlowModel

    var body: some View {
        let f = theme.fusion
        HStack(spacing: VFSpace.s) {
            Spacer(minLength: 0)
            Image(systemName: "cube.fill").font(VFFont.glyph(11)).foregroundStyle(f.blue)
                .accessibilityHidden(true)
            Text(DocTabTitle.text(title, edited: edited)).font(FusionTokens.row).foregroundStyle(f.ink).lineLimit(1)
            ToolbarJobCapsule(flow: flow)
            Spacer(minLength: 0)
            Button { NSApp.keyWindow?.performClose(nil) } label: {
                Image(systemName: "xmark").font(VFFont.glyph(9, weight: .medium)).foregroundStyle(f.inkSoft)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close Document")
        }
        .padding(.horizontal, VFSpace.m)
        .frame(minWidth: 320, idealWidth: 720, maxWidth: 900)
        .frame(height: 26)
        .background(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4).fill(f.surface))
        .accessibilityElement(children: .contain)
    }
}

/// The profile avatar's menu: Preferences, then ViaForm's panels the reference has no button for.
struct FusionProfileMenu: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SolidWorksExtras.storageKey) private var swExtras = false
    var showInspector: () -> Void
    var inspectorShown: Bool
    var showBom: () -> Void

    var body: some View {
        Menu {
            Button("Preferences\u{2026}") { openSettings() }
            Divider()
            Button(inspectorShown ? "Hide Inspector" : "Show Inspector", action: showInspector)
            Button("Bill of Materials", action: showBom)
            Divider()
            Toggle("SolidWorks extras", isOn: $swExtras)
            ThemeModePicker(inMenu: true)
        } label: {
            Label("Profile", systemImage: "person.crop.circle.fill")
        }
        .menuIndicator(.hidden)
        .help("Profile: preferences and panels")
    }
}

// MARK: - Floating cards (command dialog, sketch palette)

/// The header of a floating card: ⊖, the title in capitals, and ▸▸ that folds the card.
struct FusionCardHeader: View {
    @Environment(\.viaFormTheme) private var theme
    let title: String
    @Binding var folded: Bool
    var close: (() -> Void)?

    var body: some View {
        let f = theme.fusion
        HStack(spacing: VFSpace.s) {
            Button { close?() } label: {
                Image(systemName: "minus.circle.fill").font(VFFont.glyph(10)).foregroundStyle(f.inkSoft)
            }
            .buttonStyle(.plain)
            .disabled(close == nil)
            .help(close == nil ? "" : String(localized: "Cancel (Escape)"))
            .accessibilityLabel("Cancel")
            .accessibilityHidden(close == nil)
            Text(title.uppercased()).font(FusionTokens.header).foregroundStyle(f.ink).lineLimit(1)
            Spacer(minLength: 0)
            Button { folded.toggle() } label: {
                Image(systemName: folded ? "chevron.left.2" : "chevron.right.2").font(VFFont.glyph(8, weight: .semibold)).foregroundStyle(f.inkSoft)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(folded ? "Expand" : "Collapse")
            .accessibilityLabel(folded ? "Expand" : "Collapse")
        }
        .padding(.horizontal, VFSpace.s)
        .frame(height: FusionTokens.browserHeader)
        .background(f.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(f.line).frame(height: 1) }
        .accessibilityAddTraits(.isHeader)
    }
}

/// "▾ Options": a section title inside a floating card.
struct FusionSection: View {
    @Environment(\.viaFormTheme) private var theme
    let title: LocalizedStringResource

    var body: some View {
        HStack(spacing: VFSpace.xs) {
            Image(systemName: "arrowtriangle.down.fill").font(VFFont.glyph(6))
            Text(title).font(FusionTokens.header.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.fusion.ink)
        .padding(.horizontal, VFSpace.s)
        .frame(height: 20)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Bottom of the canvas

/// The status text's wording, after the reference: "1 Face | Area : 20.2 cm²".
enum FusionStatus {
    static func format(_ line: String) -> String {
        var out = line.replacingOccurrences(of: " · ", with: " | ")
        for word in ["Area", "Volume", "Length", "Distance", "Angle", "Radius", "Diameter"] {
            out = out.replacingOccurrences(of: word + " ", with: word + " : ")
        }
        return out.replacingOccurrences(of: " :  : ", with: " : ").replacingOccurrences(of: ": : ", with: ": ")
    }
}

/// COMMENTS, bottom left of the canvas: a collapsed bar with its dot (the reference's comments
/// panel; ViaForm keeps no comments yet, so it only shows the bar).
struct FusionCommentsBar: View {
    @Environment(\.viaFormTheme) private var theme

    var body: some View {
        let f = theme.fusion
        HStack(spacing: VFSpace.xs) {
            Text("COMMENTS").font(FusionTokens.header).foregroundStyle(f.inkSoft)
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill").font(VFFont.glyph(9)).foregroundStyle(f.inkSoft)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, VFSpace.s)
        .frame(width: FusionTokens.browserWidth, height: FusionTokens.bottomBar)
        .background(f.surface)
        .overlay(Rectangle().strokeBorder(f.line, lineWidth: 1))
        .help("Comments")
        .accessibilityElement(children: .combine)
    }
}

/// The status text at the bottom right of the canvas ("1 Face | Area : 20.2 cm²"), with the
/// selection filter's glyph at its end.
struct FusionStatusText: View {
    @Environment(\.viaFormTheme) private var theme
    let text: String
    @Bindable var model: DesignModel

    var body: some View {
        let f = theme.fusion
        HStack(spacing: VFSpace.s) {
            Text(text).font(FusionTokens.header).foregroundStyle(f.ink).lineLimit(1)
            Menu {
                SelectFilterMenuItems(model: model)
            } label: {
                Image(systemName: SelectFilterUI.symbol(model.selectionFilter)).font(VFFont.glyph(10)).foregroundStyle(f.inkSoft)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(SelectFilterUI.help(model.selectionFilter))
            .accessibilityLabel(String(localized: "Selection filter"))
        }
        .frame(height: FusionTokens.bottomBar)
    }
}

// MARK: - Browser

/// The floating BROWSER at the top left of the canvas: a header with « (collapse) and a dot
/// (hide), then the tree over the canvas.
struct FusionBrowserPanel<Content: View>: View {
    @Environment(\.viaFormTheme) private var theme
    @Binding var shown: Bool
    @State private var folded = false
    @ViewBuilder var content: Content

    var body: some View {
        let f = theme.fusion
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: VFSpace.s) {
                Button { folded.toggle() } label: {
                    Image(systemName: folded ? "chevron.right.2" : "chevron.left.2").font(VFFont.glyph(8, weight: .semibold))
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(folded ? "Expand the browser" : "Collapse the browser")
                .accessibilityLabel(folded ? "Expand Browser" : "Collapse Browser")
                Text("BROWSER").font(FusionTokens.header)
                Spacer(minLength: 0)
                Button { shown = false } label: {
                    Image(systemName: "minus.circle.fill").font(VFFont.glyph(10)).frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide the browser (Control-Command-S shows it again)")
                .accessibilityLabel("Hide Browser")
            }
            .foregroundStyle(f.inkSoft)
            .padding(.horizontal, VFSpace.s)
            .frame(height: FusionTokens.browserHeader)
            .background(f.surface)
            .overlay(Rectangle().strokeBorder(f.line, lineWidth: 1))
            if !folded {
                content
                    .font(FusionTokens.row)
                    .controlSize(.small)
                    .environment(\.sidebarRowSize, .small)
                    .environment(\.defaultMinListRowHeight, FusionTokens.browserRow)
                    .scrollContentBackground(.hidden)
            }
        }
        .frame(width: FusionTokens.browserWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser")
    }
}
// MARK: - Window

/// Gives the project window Fusion's slim application bar: the compact unified toolbar.
struct FusionWindowStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            DispatchQueue.main.async { w.toolbarStyle = .unifiedCompact }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
