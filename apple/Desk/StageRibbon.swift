#if os(macOS)
import SwiftUI

/// The ribbon of the open stage, under the toolbar. The design workspaces (Design, Assemble,
/// Render) show the engine registry as tabs of panels with big jet icons and a capitalised
/// legend whose chevron lists every command of the panel; the panels fold into MORE when the
/// window is narrow. The other stages show their verbs from the flow catalog as dense labelled
/// buttons. The stage's primary actions sit on the trailing edge ("Re-run on Frame v12" first
/// when the stage is stale), and Done closes an open sketch.
struct StageRibbon: View {
    @Environment(\.viaFormTheme) private var theme
    let workspace: Workspace
    @Bindable var model: DesignModel
    let flow: FlowModel
    @Binding var tab: String
    let actions: StageActions
    let primary: [StageScreen.PrimaryAction]
    /// The command dialog sits in the inspector with its own Done: no second one here.
    var dialogDocked = false

    private var designLike: Bool { StageActions.designLike.contains(workspace) }

    var body: some View {
        if designLike { fusionBody } else { stageBody }
    }

    /// Design, Assemble and Render: Fusion's toolbar, tabs over panels, no trailing buttons (a
    /// command finishes from its dialog, a sketch from FINISH SKETCH).
    private var fusionBody: some View {
        let f = theme.fusion
        return VStack(alignment: .leading, spacing: 0) {
            FusionTabs(tabs: tabs, tab: $tab)
            FusionPanelStrip(model: model, panels: FusionRibbon.panels(tab: tab, commands: model.commands), tab: tab)
                .frame(height: FusionTokens.panelRow, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(f.surface)
        .onAppear(perform: fixTab)
        .onChange(of: workspace) { _, _ in fixTab() }
        .onChange(of: model.sketchOpen) { _, open in
            if open { tab = "SKETCH" } else if tab == "SKETCH" { tab = tabs.first ?? "SOLID" }
        }
    }

    private var stageBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: VFSpace.s) {
                if designLike {
                    EmptyView()
                } else {
                    // Labelled verbs, then icons only, then the last groups folded into MORE
                    // one by one (P2-7): never wider than the window, every verb reachable.
                    let groups = verbGroups
                    ViewThatFits(in: .horizontal) {
                        ForEach(RibbonFold.steps(groups.count), id: \.self) { step in
                            let r = RibbonFold.fold(groups, visible: step.visible, perGroup: CompactLayout.verbsPerGroup)
                            HStack(spacing: VFSpace.s) {
                                VerbStrip(groups: r.strip, actions: actions, labels: step.labels)
                                if !r.more.isEmpty { VerbMoreMenu(groups: r.more, actions: actions) }
                            }
                            .fixedSize()
                        }
                    }
                    .layoutPriority(-1)
                }
                Spacer(minLength: VFSpace.m)
                trailing
            }
            .padding(.horizontal, VFSpace.m)
            .padding(.vertical, VFSpace.xs)
            .frame(height: designLike ? 60 : 42)
        }
        .vfSurface(.ribbon)
        .overlay(alignment: .bottom) { VFHairline() }
        .onAppear(perform: fixTab)
        .onChange(of: workspace) { _, _ in fixTab() }
        .onChange(of: model.sketchOpen) { _, open in
            if open { tab = "SKETCH" } else if tab == "SKETCH" { tab = tabs.first ?? "SOLID" }
        }
    }

    @ViewBuilder private var trailing: some View {
        let done = designLike && ((commandRunning && !dialogDocked) || model.sketchOpen)
        HStack(spacing: VFSpace.s) {
            ForEach(Array(primary.enumerated()), id: \.offset) { _, p in
                let reason = p.command == "flow.update" ? nil : actions.unavailableReason(p.command)
                // One accent per context (FRONTEND 7.1): the canvas stale banner carries the
                // update, and Done owns the accent while a sketch or command is open.
                if p.prominent && p.command != "flow.update" && !done {
                    // Command-Return runs it (the Workspace menu's Run item): shown on the button.
                    Button { perform(p) } label: {
                        HStack(spacing: VFSpace.s) {
                            Text(p.label)
                            Text("\u{2318}\u{21A9}").font(VFFont.micro).opacity(0.75).accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.vfPrimary)
                    .disabled(reason != nil)
                    .accessibilityHint(reason ?? "")
                    .help(reason ?? String(localized: "\(p.label) (Command-Return)"))
                } else {
                    Button(p.label) { perform(p) }
                        .buttonStyle(.vfSecondary)
                        .disabled(reason != nil)
                    .accessibilityHint(reason ?? "")
                        .help(reason ?? (p.command == "flow.update"
                            ? String(localized: "Rebuild in order: \(p.plan.map { flow.node($0)?.name ?? $0 }.joined(separator: ", "))")
                            : p.label))
                }
            }
            if designLike && commandRunning && !dialogDocked {
                // A running command finishes from the ribbon too: accent, with Return.
                DoneButton(help: String(localized: "Finish \(StageLabels.command(model.genericCommand?.label ?? model.tool.label)) (Return)")) { CommandDialog.finish(model) }
            } else if designLike && model.sketchOpen {
                // The armed tool's own Done (Return ends the chain), then Finish Sketch.
                if SketchRibbonTools.toolDoneShown(model) { SketchToolDoneButton(model: model) }
                DoneButton { model.finishSketch() }
                    .keyboardShortcut(model.tool == .select && model.genericCommand == nil ? KeyboardShortcut(.return, modifiers: []) : nil)
            }
        }
        .fixedSize()
    }

    /// A command with a dialog is running (not a sketch tool, which Done on the sketch ends).
    private var commandRunning: Bool {
        model.genericCommand == nil && model.tool != .select && !model.tool.isSketchTool
    }

    private func perform(_ p: StageScreen.PrimaryAction) {
        if p.command == "flow.update" { actions.update(p.plan) } else { actions.run(p.command) }
    }

    // MARK: Design registry

    /// The tabs this stage shows: Fusion's Design tabs (Render and Assemble keep their own).
    private var tabs: [String] {
        if workspace != .assemble { return FusionRibbon.tabs(workspace: workspace, commands: model.commands, sketchOpen: model.sketchOpen) }
        return registryTabs
    }

    /// The raw registry tabs (Assemble's own tab first).
    private var registryTabs: [String] {
        var seen: [String] = []
        for c in model.commands where !c.tab.isEmpty && !seen.contains(c.tab) { seen.append(c.tab) }
        let order = ["SOLID", "SURFACE", "SHEET METAL", "PLASTIC", "WELDMENTS", "INSERT", "INSPECT", "RENDER", "RENDER SCENE"]
        let all = order.filter(seen.contains) + seen.filter { !order.contains($0) && $0 != "SKETCH" }
        var list: [String]
        switch workspace {
        case .render:
            list = all.filter { $0.hasPrefix("RENDER") }
        case .assemble:
            list = [Self.assemblyTab] + all.filter { $0 == "INSPECT" || $0 == "INSERT" }
        default:
            list = all.filter { !$0.hasPrefix("RENDER") }
        }
        if list.isEmpty { list = all }
        return list + (model.sketchOpen ? ["SKETCH"] : [])
    }

    /// The Assemble stage's own tab: every registry panel about components, joints and position.
    static let assemblyTab = "ASSEMBLY"

    private static func isAssemblyPanel(_ c: CommandInfo) -> Bool {
        let p = c.panel.uppercased()
        return p.contains("ASSEMBL") || p.contains("POSITION") || p.contains("JOINT") || p.contains("COMPONENT") || c.id.hasPrefix("assembly.") || c.id.hasPrefix("joint.")
    }

    private var panels: [RibbonPanelModel] { Self.panels(tab: tab, commands: model.commands) }

    /// The panels of one ribbon tab, in registry order (also read by the self tests).
    static func panels(tab: String, commands: [CommandInfo]) -> [RibbonPanelModel] {
        var order: [String] = []
        var by: [String: [CommandInfo]] = [:]
        let pool = tab == assemblyTab ? commands.filter(isAssemblyPanel) : commands.filter { $0.tab == tab }
        for c in pool where c.panel != "FINISH SKETCH" {
            if by[c.panel] == nil { order.append(c.panel) }
            by[c.panel, default: []].append(c)
        }
        let list = order.map { RibbonPanelModel(name: $0, commands: by[$0] ?? []) }
            .map { $0.name.isEmpty ? RibbonPanelModel(name: "OTHER", commands: $0.commands) : $0 }
        // B-11: every click-to-draw sketch tool sits in CREATE or MODIFY, registry-listed or not.
        return tab == "SKETCH" ? SketchRibbonTools.merge(list, commands: commands) : list
    }

    private func fixTab() {
        guard designLike else { return }
        if !tabs.contains(tab) { tab = tabs.first ?? "SOLID" }
    }

    // MARK: Stage verbs

    private var verbGroups: [RibbonFold.Group<FlowModel.Command>] {
        // The primary actions sit on the trailing edge; the strip keeps the other verbs. Every
        // verb of a group comes here: the fold sends the ones past the cap to MORE.
        let primaryIDs = Set(primary.map(\.command))
        return StageScreen.ribbon(flow.commands(stage: workspace.stage).filter { $0.source == "app" && !primaryIDs.contains($0.id) }, perGroup: .max)
            .map { RibbonFold.Group(name: $0.name, commands: $0.commands) }
    }
}

/// Tabs of the design ribbon, with the product's own names.
struct RibbonTabs: View {
    @Environment(\.viaFormTheme) private var theme
    let tabs: [String]
    @Binding var tab: String
    var sketchOpen = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                let on = tab == t
                Button { tab = t } label: {
                    Text(StageLabels.tab(t))
                        .font(VFFont.caps)
                        .tracking(VFTypeScale.capsTracking)
                        .padding(.horizontal, VFSpace.l)
                        .frame(height: 24)
                        .foregroundStyle(on ? theme.accentText : (t == "SKETCH" ? theme.accentText.opacity(0.8) : theme.inkSecondary))
                        .overlay(alignment: .bottom) { if on { Rectangle().fill(theme.accent).frame(height: 2) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(StageLabels.tab(t).capitalized)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, VFSpace.xs)
        .frame(height: 24)
        .overlay(alignment: .bottom) { VFHairline() }
    }
}

struct RibbonPanelModel: Identifiable {
    let name: String
    let commands: [CommandInfo]
    var id: String { name }
}

/// The panels of a tab, folding the last ones into MORE until they fit.
struct PanelStrip: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let panels: [RibbonPanelModel]

    var body: some View {
        if panels.isEmpty {
            Text("No commands in this tab").font(VFFont.small).foregroundStyle(theme.inkSecondary)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach((1...panels.count).reversed(), id: \.self) { k in
                    HStack(alignment: .top, spacing: VFSpace.xs) {
                        ForEach(panels.prefix(k)) { p in
                            // M-1: the constraints on the sketch selection, invalid ones greyed.
                            if p.name == "CONSTRAINTS" && model.sketchOpen {
                                ConstraintRibbonPanel(model: model, panel: p)
                            } else {
                                RibbonPanelView(model: model, panel: p)
                            }
                            VFHairline(vertical: true).frame(height: 42)
                        }
                        if k < panels.count { MorePanel(model: model, panels: Array(panels.dropFirst(k))) }
                    }
                    .fixedSize()
                }
                MorePanel(model: model, panels: panels)
            }
        }
    }
}

/// One ribbon panel: its main commands as big jet icons, its legend opening all of them.
struct RibbonPanelView: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let panel: RibbonPanelModel

    private var main: [CommandInfo] {
        // Sketch CREATE and MODIFY: the reference's row (Line, Rectangle, Circle, Spline, ...).
        if let row = SketchRibbonTools.mainRow(panel) { return row }
        let keyed = panel.commands.filter { $0.key != nil }
        return Array((keyed + panel.commands.filter { $0.key == nil }).prefix(4))
    }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: VFSpace.xxs) {
                ForEach(main) { c in
                    let on = model.tool.commandID == c.id && model.tool != .select
                    Button { CommandRouter.run(c, model) } label: {
                        ToolChipIcon(icon: c.icon, id: c.id, size: 22)
                            .frame(width: 36, height: 32)
                            .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(on ? theme.accent.opacity(0.22) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).strokeBorder(on ? theme.accent.opacity(0.7) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(RibbonPins.tooltip(c))
                    .accessibilityLabel(StageLabels.command(c.label))
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Menu {
                if let entries = SketchRibbonTools.entries(panel) {
                    // Sketch CREATE and MODIFY: the reference's order, with its submenus.
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
                    ForEach(panel.commands) { c in
                        RibbonMenuRow(model: model, command: c)
                    }
                }
                Divider()
                PinMenu(commands: panel.commands)
            } label: {
                HStack(spacing: VFSpace.xxs) {
                    VFCaption(StageLabels.panel(panel.name))
                    Image(systemName: "chevron.down").font(VFFont.glyph(7, weight: .bold)).foregroundStyle(theme.inkSecondary)
                }
            }
            .menuStyle(.vfPlain)
        }
        .padding(.horizontal, VFSpace.xs)
    }
}

extension RibbonPanelView {
    /// A registry key as a menu equivalent, so the panel menus print it (single letters only:
    /// the key monitor runs them, the menu only shows them).
    static func menuKey(_ key: String?) -> KeyboardShortcut? {
        guard let key, DeskKeymap.isLetterKey(key), let ch = key.split(separator: "+").last?.lowercased().first else { return nil }
        return KeyboardShortcut(KeyEquivalent(ch), modifiers: key.lowercased().hasPrefix("shift") ? .shift : [])
    }
}

/// One row of a ribbon dropdown (M-19): the command, its key at the right edge (a single letter as
/// the menu's key equivalent, anything else printed in the title), the registry summary on hover.
struct RibbonMenuRow: View {
    let model: DesignModel
    let command: CommandInfo

    var body: some View {
        let title = StageLabels.command(command.label)
        Button { CommandRouter.run(command, model) } label: {
            Label(RibbonPins.rowKey(command.key).map { "\(title)   \($0)" } ?? title,
                  systemImage: CommandSymbol.of(command.icon, id: command.id))
        }
        .keyboardShortcut(RibbonPanelView.menuKey(command.key))
        .help(RibbonPins.tooltip(command))
    }
}

/// "Pin to Toolbar" for each command of a panel, ticked when pinned; kept per user.
struct PinMenu: View {
    let commands: [CommandInfo]
    @AppStorage(RibbonPins.storageKey) private var pins = ""

    var body: some View {
        Menu("Pin to Toolbar") {
            ForEach(commands) { c in
                Toggle(StageLabels.command(c.label), isOn: Binding(
                    get: { RibbonPins.isPinned(pins, c.id) },
                    set: { _ in pins = RibbonPins.toggled(pins, c.id) }))
            }
        }
    }
}

/// The panels that did not fit, in one menu.
struct MorePanel: View {
    let model: DesignModel
    let panels: [RibbonPanelModel]

    var body: some View {
        Menu {
            ForEach(panels) { p in
                Section(StageLabels.panel(p.name)) {
                    ForEach(p.commands) { c in
                        RibbonMenuRow(model: model, command: c)
                    }
                }
            }
        } label: {
            VStack(spacing: VFSpace.xxs) {
                Image(systemName: "ellipsis.circle").font(VFFont.glyph(18)).frame(width: 36, height: 32)
                VFCaption("More")
            }
        }
        .menuStyle(.vfPlain)
        .help(panels.map { StageLabels.panel($0.name) }.joined(separator: ", "))
        .accessibilityLabel("More Commands")
    }
}

/// A non-design stage's verbs as dense labelled buttons, grouped with a legend.
struct VerbStrip: View {
    @Environment(\.viaFormTheme) private var theme
    let groups: [RibbonFold.Group<FlowModel.Command>]
    let actions: StageActions
    var labels = true

    var body: some View {
        HStack(spacing: VFSpace.s) {
            ForEach(groups) { g in
                HStack(spacing: VFSpace.xxs) {
                    VFCaption(g.name).padding(.trailing, VFSpace.xs)
                    ForEach(g.commands) { c in
                        Button { actions.run(c.id) } label: {
                            Label(StageLabels.command(c.label), systemImage: StageLabels.symbol(forVerb: c.icon))
                                .font(VFFont.small)
                                .labelStyle(VerbLabelStyle(labels: labels))
                                .padding(.horizontal, VFSpace.s)
                                .frame(height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.vfGhost)
                        .disabled(!actions.canRun(c.id))
                        .help(actions.unavailableReason(c.id) ?? (c.detail.isEmpty ? c.label : c.detail))
                        .accessibilityHint(actions.unavailableReason(c.id) ?? "")
                        .accessibilityLabel(StageLabels.command(c.label))
                    }
                }
                .padding(.horizontal, VFSpace.s)
                .frame(height: 30)
                .vfSurface(.well)
            }
        }
        .fixedSize()
    }
}

private struct VerbLabelStyle: LabelStyle {
    let labels: Bool
    func makeBody(configuration: Configuration) -> some View {
        if labels {
            HStack(spacing: VFSpace.s) { configuration.icon; configuration.title }
        } else {
            configuration.icon
        }
    }
}

/// Closes a sketch or finishes the running command: the accent button, never a green check. The
/// Return glyph is a visual hint only (VoiceOver reads "Done" and the tooltip names the key);
/// the caller attaches the real `.keyboardShortcut`.
struct DoneButton: View {
    var help = String(localized: "Finish the sketch (Return)")
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VFSpace.s) {
                Text("Done")
                Image(systemName: "return").font(VFFont.glyph(10, weight: .semibold)).opacity(0.85)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.vfPrimary)
        .help(help)
        .accessibilityLabel("Done")
        .accessibilityHint(help)
    }
}
#endif
