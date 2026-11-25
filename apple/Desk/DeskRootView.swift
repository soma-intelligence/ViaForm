#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The desktop front end: a ribbon of tabs and panels over the viewport, a browser tree on the
/// left, a command dialog on the right, the navigation bar and the timeline along the bottom.
/// The ribbon is built from the engine's command registry, so every command has a place.
struct DeskRootView: View {
    @Bindable var model: DesignModel
    let pcb: PCBModel
    @State private var workspace = Workspace.design
    @State private var sim = SimModel()
    @State private var generate = GenerateModel()
    @State private var tab = "SOLID"
    @State private var showBrowser = true
    @State private var perspective = false
    @State private var showData = false
    @State private var library = LibraryModel()
    @State private var showLibrary = false
    @State private var bom = BomModel()
    @State private var showBom = BomModel.launchRequested
    @State private var flow = FlowModel()
    @State private var flowCard: Workspace?

    private func openStage(_ stage: String) {
        if let w = Workspace(stage: stage) { workspace = w }
    }

    @Environment(\.viaFormTheme) private var theme

    /// The workspaces in pipeline order (`Workspace`, shared with the iPad app); each one is a
    /// stage of the product flow (`FlowModel`).
    typealias Workspace = ViaFormWorkspace

    var body: some View {
        VStack(spacing: 0) {
            AppBar(model: model, showData: $showData)
                .disabled(EngineGate.shared.shut)
            HStack(spacing: 0) {
                PipelineBar(flow: flow, workspace: $workspace, card: $flowCard, showsJobs: true)
                    .disabled(EngineGate.shared.shut)
                Divider().frame(height: VFSpace.xl)
                Button { showBom.toggle() } label: {
                    Label("BOM", systemImage: "list.bullet.rectangle").font(VFFont.caps)
                }
                .buttonStyle(.vfGhost(tint: showBom ? theme.accentText : theme.ink))
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .help("Bill of materials: design parts, PCB components and component files, priced for N builds (Shift-Command-B)")
                Button { showLibrary.toggle() } label: {
                    Label("Libraries", systemImage: "books.vertical").font(VFFont.caps)
                }
                .buttonStyle(.vfGhost(tint: showLibrary ? theme.accentText : theme.ink))
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Libraries: KiCad, standard hardware, distributors, marketplaces, saved parts (Shift-Command-L)")
                .padding(.horizontal, VFSpace.m)
            }
            .frame(height: LegacyMetrics.bar)
            .background(theme.chrome)
            switch workspace {
            case .electronics:
                DeskPCBView(model: pcb, design: model) { workspace = .design }
            case .simulation, .train:
                // Training lives in the simulation workspace for now (its Train panel).
                SimulationView(model: sim)
            case .generate:
                GenerateView(model: generate, design: model, theme: theme.viewportTheme)
            case .make:
                StageOverview(flow: flow, stage: "make", note: "Manufacturing gathers the frame, the board, the assembly and the flight policy. Exports available today:", open: openStage) {
                    Button("Export Design…") { FileActions.export(model) }
                    Button("Bill of Materials") { showBom = true }
                }
            case .robot:
                StageOverview(flow: flow, stage: "robot", note: "The robot stage connects the real robot, records demonstrations and runs a trained policy. No robot is connected.", open: openStage) {
                    EmptyView()
                }
            case .design, .assemble, .render:
                designBody
            }
            if showBom {
                Divider()
                BomPanel(model: bom, design: model, pcb: pcb) { showBom = false }.frame(height: LegacyMetrics.bomHeight)
            }
        }
        .background(theme.chrome)
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if showBom { bom.applyLaunchFlags(); BomSnapshot.runIfAsked(model: bom, design: model, pcb: pcb) }
            if args.contains("--electronics") { workspace = .electronics }
            if args.contains("--simulation") { workspace = .simulation }
            if args.contains("--generate") { workspace = .generate }
            generate.launchHooks(design: model)
            if args.contains("--board") { workspace = .electronics; pcb.sheet = .board }
            if args.contains("--library") { showLibrary = true }
            if let q = args.first(where: { $0.hasPrefix("--library=") })?.dropFirst(10) {
                showLibrary = true
                library.query = String(q)
                Task { await library.search() }
            }
            if args.contains("--pcb-3d") {
                // Demo for the docs: an enclosure, the sample board sent to 3D and mounted on it.
                model.newDesign()
                model.run("solid.box", ["length": 80, "width": 60, "height": 12, "corner": [-10, -50, 0], "body_name": "Enclosure"])
                pcb.sendTo3D(model)
                PCBLink.mount(pcb, in: model, body: "Enclosure", at: [30, -20, 12], normal: [0, 0, 1])
                model.setView(.iso)
                model.zoomToFit()
            }
        }
        .onChange(of: workspace) { _, w in
            pcb.syncLink(model)
            if w == .render, model.commands.contains(where: { $0.tab == "RENDER" }) { tab = "RENDER" }
        }
        // What each workspace builds, reported to the pipeline.
        .reportsToFlow(flow, design: model, pcb: pcb, generate: generate, sim: sim)
        .projectFilesContext(design: model, pcb: pcb, bom: bom, flow: flow)
        .focusedSceneValue(\.vfDesk, DeskFocus(workspace: workspace, open: { workspace = $0 }, search: { model.toolboxOpen = true }))
        .inspector(isPresented: $showLibrary) {
            LibraryView(model: library, design: model, pcb: pcb) { showLibrary = false }
                .inspectorColumnWidth(min: VFSize.sidePanel, ideal: LegacyMetrics.libraryIdeal, max: LegacyMetrics.libraryMax)
        }
    }

    @ViewBuilder private var designBody: some View {
        VStack(spacing: 0) {
            Ribbon(model: model, tab: $tab)
            Divider()
            ZStack {
                Viewport(model: model, theme: theme.viewportTheme)
                VStack {
                    HStack(alignment: .top) {
                        if showBrowser { BrowserPanel(model: model, shown: $showBrowser).frame(width: LegacyMetrics.browserWidth) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: VFSpace.m) {
                            // Face, edge and label colours come from the theme (ViewCube's defaults).
                            ViewCube(model: model, size: LegacyMetrics.viewCube)
                            if model.tool != .select || model.genericCommand != nil { CommandDialog(model: model).frame(width: LegacyMetrics.dialogWidth) }
                        }
                    }
                    Spacer()
                    PCBLinkBanner(design: model, pcb: pcb)
                    MessageBanner(model: model)
                    NavigationBar(model: model, perspective: $perspective)
                }
                .padding(VFSpace.m)
                if let at = model.markingMenu { MarkingMenu(model: model, at: at) }
                if model.toolboxOpen {
                    VStack { ToolboxSearch(model: model).padding(.top, VFSpace.paletteTop); Spacer() }
                }
            }
            .overlay(alignment: .leading) {
                if showData { DataPanel(model: model, shown: $showData).transition(.move(edge: .leading)) }
            }
            .vfAnimation(.easeOut(duration: VFMotion.standard), value: showData)
            Divider()
            TimelineBar(model: model)
        }
        .background(theme.chrome)
        .onAppear {
            // Screenshot hooks for the docs: open the marking menu or the toolbox at launch.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--show-marking") { model.markingMenu = CGPoint(x: 620, y: 300) }
            if args.contains("--show-toolbox") { model.toolboxOpen = true }
            if args.contains("--show-data") { showData = true }
        }
        .onChange(of: model.sketchOpen) { _, open in tab = open ? "SKETCH" : (tab == "SKETCH" ? "SOLID" : tab) }
        .onChange(of: perspective) { _, p in model.camera.fov = p ? 0.7 : 0; model.cameraChanged() }
    }
}

// MARK: App bar

struct AppBar: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @Binding var showData: Bool

    var body: some View {
        HStack(spacing: VFSpace.l) {
            Button { showData.toggle() } label: { Image(systemName: "square.grid.3x3") }.help("Data Panel")
            Menu {
                Button("New Design") { FileActions.newDesign(model) }.keyboardShortcut("n")
                Button("Open…") { FileActions.open(model) }.keyboardShortcut("o")
                Button("Sample Bracket") { model.loadSample() }
                Divider()
                Button("Save As…") { FileActions.saveAs(model) }.keyboardShortcut("s")
                Button("Export…") { FileActions.export(model) }.keyboardShortcut("e", modifiers: [.command, .shift])
            } label: { Image(systemName: "doc") }
            .menuStyle(.vfPlain)
            Button { FileActions.save(model) } label: { Image(systemName: "square.and.arrow.down") }.help("Save")
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.snapshot.undo == 0).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.snapshot.redo == 0).help("Redo")
            // Design tabs: one per open design, then the new design button.
            HStack(spacing: 0) {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: "cube").foregroundStyle(theme.inkSecondary)
                    Text(model.snapshot.name).font(VFFont.small.weight(.semibold)).lineLimit(1)
                    if model.snapshot.dirty { Circle().fill(theme.inkSecondary).frame(width: VFSize.dot, height: VFSize.dot) }
                }
                .padding(.horizontal, VFSpace.l).frame(height: LegacyMetrics.bar)
                .background(theme.chrome)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: VFRadius.control, topTrailingRadius: VFRadius.control))
                Button { FileActions.newDesign(model) } label: { Image(systemName: "plus").frame(width: LegacyMetrics.iconButton, height: LegacyMetrics.iconButton) }.help("New Design")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, VFSpace.xs)
            Button { model.toolboxOpen = true } label: { Image(systemName: "magnifyingglass") }.help("Search commands (S)")
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(theme.inkSecondary).help("Job status: \(model.snapshot.bodies.count) bodies, revision \(model.snapshot.revision)")
            Image(systemName: "bell").foregroundStyle(theme.inkSecondary)
            Menu {
                Link("SolidCraft engine", destination: URL(string: "https://github.com/tangency-labs/solidcraft")!)
                Link("PCBCraft engine", destination: URL(string: "https://github.com/tangency-labs/pcbcraft")!)
            } label: { Image(systemName: "questionmark.circle") }
            .menuStyle(.vfPlain)
            Image(systemName: "person.crop.circle").font(VFFont.glyph(17)).foregroundStyle(theme.inkSecondary)
        }
        .buttonStyle(.plain)
        .font(VFFont.row)
        .foregroundStyle(theme.ink)
        .padding(.horizontal, VFSpace.l)
        .frame(height: LegacyMetrics.appBar)
        .background(theme.chromeDeep)
    }
}

// MARK: Ribbon

/// Tabs and panels from the registry: each panel shows its main commands as big buttons and
/// all of them in its drop-down.
struct Ribbon: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @Binding var tab: String

    private var tabs: [String] {
        var seen: [String] = []
        for c in model.commands where !c.tab.isEmpty && !seen.contains(c.tab) { seen.append(c.tab) }
        let order = ["SOLID", "SURFACE", "SHEET METAL", "PLASTIC", "WELDMENTS", "INSERT", "INSPECT", "RENDER", "RENDER SCENE"]
        let rest = seen.filter { !order.contains($0) && $0 != "SKETCH" }
        return (order.filter(seen.contains) + rest).filter { model.sketchOpen || $0 != "SKETCH" } + (model.sketchOpen ? ["SKETCH"] : [])
    }

    private var panels: [(String, [CommandInfo])] {
        var order: [String] = []
        var by: [String: [CommandInfo]] = [:]
        for c in model.commands where c.tab == tab && c.panel != "FINISH SKETCH" {
            if by[c.panel] == nil { order.append(c.panel) }
            by[c.panel, default: []].append(c)
        }
        return order.map { ($0, by[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(StageLabels.tab(t)).font(VFFont.caps)
                            .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.s)
                            .foregroundStyle(tab == t ? theme.accentText : (t == "SKETCH" ? theme.accentText.opacity(0.8) : theme.ink))
                            .overlay(alignment: .bottom) { if tab == t { Rectangle().fill(theme.accent).frame(height: LegacyMetrics.tabUnderline) } }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(height: LegacyMetrics.tabStrip)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(panels, id: \.0) { name, cmds in
                        RibbonPanel(model: model, name: name, commands: cmds)
                        Divider().frame(height: LegacyMetrics.panelDivider)
                    }
                    if tab == "SKETCH" {
                        DoneButton { model.finishSketch() }.padding(.horizontal, VFSpace.l).frame(height: LegacyMetrics.ribbonButtons)
                    }
                }
                .padding(.horizontal, VFSpace.s)
            }
            .frame(height: LegacyMetrics.ribbonBody)
        }
        .background(theme.chrome)
    }
}

struct RibbonPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let name: String
    let commands: [CommandInfo]

    /// The commands shown as big buttons: the ones with a shortcut first (the common ones).
    private var main: [CommandInfo] {
        let keyed = commands.filter { $0.key != nil }
        return Array((keyed + commands.filter { $0.key == nil }).prefix(name == "FINISH SKETCH" ? 1 : 4))
    }

    var body: some View {
        VStack(spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.xxs) {
                ForEach(main) { c in
                    Button { CommandRouter.run(c, model) } label: {
                        CommandIcon(icon: c.icon, id: c.id)
                            .frame(width: LegacyMetrics.commandButton.width, height: LegacyMetrics.commandButton.height)
                            .foregroundStyle(active(c) ? theme.onAccent : theme.ink)
                            .background(active(c) ? theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: VFRadius.chip, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(StageLabels.command(c.label) + (c.key.map { "  (\($0))" } ?? ""))
                }
            }
            Menu {
                ForEach(commands) { c in
                    Button { CommandRouter.run(c, model) } label: {
                        Label(StageLabels.command(c.label), systemImage: CommandSymbol.of(c.icon, id: c.id))
                    }
                }
            } label: {
                HStack(spacing: VFSpace.xxs) {
                    Text(name).font(VFFont.micro.weight(.bold))
                    Image(systemName: "chevron.down").font(VFFont.glyph(7, weight: .bold))
                }
                .foregroundStyle(theme.inkSecondary)
            }
            .menuStyle(.vfPlain)
        }
        .padding(.horizontal, VFSpace.m)
        .padding(.top, VFSpace.xs)
    }

    private func active(_ c: CommandInfo) -> Bool { model.tool.commandID == c.id && model.tool != .select }
}

/// A registry command to what runs it: a modelling tool, a direct action or the generic form.
enum CommandRouter {
    static func run(_ c: CommandInfo, _ m: DesignModel) {
        if m.routeSketchCommand(c.id) { return }
        switch c.id {
        case "sketch.finish": m.finishSketch(); return
        case "edit.undo": m.undo(); return
        case "edit.redo": m.redo(); return
        case "solid.combine": m.genericCommand = c; return
        case "solid.remove": m.deleteSelection(); return
        case "inspect.measure":
            // The mass properties report (M-21); the window presents it.
            NotificationCenter.default.post(name: .vfShowMassProperties, object: m)
            return
        default: break
        }
        if let t = Tool.allCases.first(where: { $0.commandID == c.id }), t != .union, t != .subtract, t != .intersect {
            m.genericCommand = nil
            if t == .sketch, m.selection.contains(where: \.isFace) { m.sketchOnSelectedFace() } else { m.tool = t }
        } else {
            m.tool = .select
            m.genericCommand = c
        }
    }
}

// MARK: Browser

struct BrowserPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @Binding var shown: Bool
    @State private var open: Set<String> = ["Components", "Bodies", "Sketches"]
    @State private var hidden: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VFCaption("Browser")
                Spacer()
                Button { shown = false } label: { Image(systemName: "minus").font(VFFont.glyph(10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(theme.inkSecondary).help("Hide the browser")
            }
            .padding(.horizontal, VFSpace.m).frame(height: VFSize.macRow)
            .background(theme.chromeDeep)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(0, "doc.fill", "\(model.snapshot.name)", bold: true)
                    folder("Document Settings", "gearshape") {
                        row(2, "ruler", "Units: \(model.snapshot.units)")
                    }
                    folder("Origin", "scope") {
                        ForEach(["XY", "XZ", "YZ"], id: \.self) { p in
                            row(2, "square", p).onTapGesture(count: 2) { model.startSketch(p) }
                        }
                    }
                    if !model.assembly.isEmpty {
                        folder("Components", "square.stack.3d.up") {
                            ForEach(model.assembly) { c in
                                HStack(spacing: VFSpace.xs) {
                                    Image(systemName: c.linkedPCB ? "cpu" : "shippingbox").foregroundStyle(c.linkedPCB ? theme.accentText : theme.inkSecondary).frame(width: LegacyMetrics.rowIcon)
                                    Text(c.occurrence ?? c.name).lineLimit(1)
                                    if c.grounded { Image(systemName: "pin.fill").font(VFFont.glyph(9)).foregroundStyle(theme.inkSecondary).help("Grounded") }
                                    if c.linkedPCB { Image(systemName: "link").font(VFFont.glyph(9)).foregroundStyle(theme.accentText).help("Linked to the Electronics board") }
                                    Spacer()
                                }
                                .font(VFFont.small)
                                .foregroundStyle(theme.ink)
                                .padding(.leading, LegacyMetrics.indent(2)).frame(height: VFSize.macRow)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedBodies = Set(c.bodies) }
                            }
                        }
                    }
                    folder("Bodies", "cube.fill") {
                        ForEach(model.snapshot.bodies) { b in
                            row(2, "cube", b.name, selected: model.selectedBodies.contains(b.name), eye: b.name)
                                .onTapGesture {
                                    if model.selectedBodies.contains(b.name) { model.selectedBodies.remove(b.name) } else { model.selectedBodies.insert(b.name) }
                                }
                                .contextMenu {
                                    Button("Hide") { model.toggleBodyVisibility(b.name, visible: false) }
                                    Button("Show") { model.toggleBodyVisibility(b.name, visible: true) }
                                    Button("Delete") { model.selectedBodies = [b.name]; model.deleteSelection() }
                                }
                        }
                    }
                    folder("Sketches", "pencil.and.outline") {
                        ForEach(model.snapshot.sketches) { s in
                            row(2, "pencil.line", s.name)
                                .contextMenu { Button("Edit Sketch") { model.run("sketch.edit", ["sketch": s.id]); model.tool = .line } }
                                .onTapGesture(count: 2) { model.run("sketch.edit", ["sketch": s.id]); model.tool = .line }
                        }
                    }
                    if !model.snapshot.params.isEmpty {
                        folder("Parameters", "function") {
                            ForEach(model.snapshot.params) { p in row(2, "number", "\(p.name) = \(p.expression)") }
                        }
                    }
                }
                .padding(.vertical, VFSpace.xs)
            }
            .frame(maxHeight: LegacyMetrics.browserMaxHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous))
        .vfSurface(.floating)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func folder<Content: View>(_ name: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if open.contains(name) { open.remove(name) } else { open.insert(name) }
        } label: {
            HStack(spacing: VFSpace.xs) {
                Image(systemName: open.contains(name) ? "chevron.down" : "chevron.right").font(VFFont.glyph(8, weight: .bold)).frame(width: LegacyMetrics.chevron)
                Image(systemName: symbol).foregroundStyle(theme.inkSecondary)
                Text(name)
                Spacer()
            }
            .font(VFFont.small)
            .foregroundStyle(theme.ink)
            .padding(.leading, LegacyMetrics.indentStep).frame(height: VFSize.macRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open.contains(name) { content() }
    }

    private func row(_ indent: Int, _ symbol: String, _ text: String, bold: Bool = false, selected: Bool = false, eye body: String? = nil) -> some View {
        HStack(spacing: VFSpace.xs) {
            if let body {
                Button {
                    let show = hidden.contains(body)
                    if show { hidden.remove(body) } else { hidden.insert(body) }
                    model.toggleBodyVisibility(body, visible: show)
                } label: {
                    Image(systemName: hidden.contains(body) ? "eye.slash" : "eye").font(VFFont.glyph(10)).frame(width: LegacyMetrics.rowIcon)
                }
                .buttonStyle(.plain).foregroundStyle(theme.inkSecondary)
                .help(hidden.contains(body) ? "Show" : "Hide")
            }
            Image(systemName: symbol).foregroundStyle(theme.inkSecondary).frame(width: LegacyMetrics.rowIcon)
            Text(text).fontWeight(bold ? .semibold : .regular).lineLimit(1).opacity(body.map { hidden.contains($0) ? 0.45 : 1 } ?? 1)
            Spacer()
        }
        .font(VFFont.small)
        .foregroundStyle(theme.ink)
        .padding(.leading, LegacyMetrics.indent(indent)).frame(height: VFSize.macRow)
        .background(selected ? theme.selection : .clear)
        .contentShape(Rectangle())
    }
}

// MARK: Command dialog

/// The dialog of the running command, docked at the right of the viewport. Fusion's rows: the
/// selection buttons with their counts and a clear button, the typed options of the feature
/// tools (`FeatureDialogFields`), then Cancel and OK. OK stays greyed until the required picks
/// are made. Return in a field commits the field; the next Return accepts the feature.
struct CommandDialog: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    /// The main value field has the keyboard focus (Return then belongs to it).
    @State private var valueFocused = false
    /// ▸▸ folds the dialog to its header (Fusion).
    @State private var folded = false

    /// Header height, gap between rows and the label column of a selection row.
    private static let headerHeight: CGFloat = 34
    private static let rowGap: CGFloat = VFSpace.m + VFSpace.xxs
    private static let footerInset: CGFloat = VFSpace.m + VFSpace.xxs
    private static let labelWidth: CGFloat = 70

    var body: some View {
        let session = FeatureSession.of(model)
        VStack(alignment: .leading, spacing: 0) {
            // Fusion's dialog header: ⊖, the command in capitals, ▸▸ to fold.
            FusionCardHeader(title: title, folded: $folded, close: { close() })
            if folded {
                EmptyView()
            } else if let c = model.genericCommand {
                GenericCommandForm(model: model, command: c)
            } else {
                VStack(alignment: .leading, spacing: Self.rowGap) {
                    if FeatureOptions.tools.contains(session.tool) {
                        FeatureDialogFields(model: model, session: session, labelWidth: Self.labelWidth,
                                            valueFocus: $valueFocused, onValueReturn: Self.endFieldEditing)
                    } else {
                        rows
                    }
                }
                .font(FusionTokens.header)
                .controlSize(.small)
                .padding(.horizontal, VFSpace.m)
                .padding(.vertical, VFSpace.s)
                // Fusion's footer: (i) at the left, OK and Cancel at the right; OK greyed until
                // the required inputs are set.
                let missing = Self.missing(model)
                HStack(spacing: VFSpace.s) {
                    Image(systemName: "info.circle.fill").font(VFFont.glyph(11)).foregroundStyle(theme.fusion.ink)
                        .help(missing ?? String(localized: "Return accepts, Escape cancels."))
                        .accessibilityLabel("Help")
                    Spacer(minLength: 0)
                    Button { ok() } label: { Text("OK").frame(minWidth: 44) }
                        .buttonStyle(.vfPrimary)
                        .keyboardShortcut(valueFocused ? nil : .defaultAction)
                        .disabled(missing != nil)
                        .help(missing ?? String(localized: "Accept (Return)"))
                    Button { close() } label: { Text("Cancel").frame(minWidth: 44) }
                        .buttonStyle(.vfSecondary)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, VFSpace.m)
                .padding(.vertical, VFSpace.s)
            }
        }
        .background(theme.fusion.card)
        .overlay(Rectangle().strokeBorder(theme.fusion.line, lineWidth: 1))
        .modifier(FeatureSessionSync(model: model))
    }

    private var title: String {
        if let e = FeatureSession.of(model).editing { return String(localized: "Edit \(e.name)") }
        return model.genericCommand?.label ?? model.tool.label
    }
    private var icon: String { model.genericCommand.map { CommandSymbol.of($0.icon, id: $0.id) } ?? model.tool.symbol }

    @ViewBuilder private var rows: some View {
        switch model.tool {
        case .pressPull:
            pickRow("Faces", model.selection.filter(\.isFace).count) { model.selection = []; model.applyPreview() }
        case .move, .mirror:
            pickRow("Bodies", model.bodiesInSelection.count) { model.selection = []; model.selectedBodies = [] }
        case .box, .cylinder, .sphere, .torus:
            Text("Click in the viewport to place it.").font(.callout).foregroundStyle(theme.inkSecondary)
        default:
            if model.tool.isSketchTool { Text(sketchHint).font(.callout).foregroundStyle(theme.inkSecondary) }
        }
        if let v = model.tool.value {
            HStack {
                Text(v.label).font(.callout).foregroundStyle(theme.inkSecondary)
                Spacer(minLength: 0)
                NumberField(v.label, value: $model.toolValue, unit: VFUnit(symbol: v.unit), step: v.unit == "deg" ? 15 : 1, width: 82)
                    .labelHiddenVisually()
                    .focusBinding($valueFocused)
                    .submitNext(.done) { Self.endFieldEditing() }
            }
        }
        if model.tool == .move {
            MoveDialogRows(session: FeatureSession.of(model), labelWidth: Self.labelWidth)
        }
        if model.tool == .mirror {
            VFSegmented("Plane", selection: $model.mirrorPlane, items: ["XY", "XZ", "YZ"], title: { $0 })
        }
        if model.tool == .sketch {
            Text("Click a planar face, or a plane:").font(.callout).foregroundStyle(theme.inkSecondary)
            HStack { ForEach(["XY", "XZ", "YZ"], id: \.self) { p in Button(p) { model.startSketch(p) } } }.buttonStyle(.vfSecondary)
        }
    }

    private var sketchHint: String {
        switch model.tool {
        case .line: "Click points. Return or Escape ends the chain."
        case .spline: "Click fit points. Return ends the curve."
        case .trim: "Click the piece to remove."
        case .offset: "Click a curve to offset."
        case .sketchFillet: "Click a corner."
        default: "Click on the sketch plane."
        }
    }

    private func pickRow(_ label: String, _ count: Int, clear: @escaping () -> Void) -> some View {
        let l = String(localized: String.LocalizationValue(label))
        return SelectionButtonRow(label: l, text: count == 0 ? String(localized: "Select") : String(localized: "\(count) selected"),
                                  count: count, active: count == 0, labelWidth: Self.labelWidth, activate: {}, clear: clear)
    }

    private func ok() { Self.finish(model) }

    /// Return in a field: the field has committed; leave it, so the next Return accepts.
    static func endFieldEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// What the running command still needs before OK, or nil.
    static func missing(_ model: DesignModel) -> String? {
        if model.genericCommand != nil { return nil }
        return FeatureSession.of(model).missingInput()
    }

    /// OK can run now (for the dialog, the ribbon's Done and the marking menu).
    static func canFinish(_ model: DesignModel) -> Bool {
        model.genericCommand == nil && model.tool != .select && missing(model) == nil
    }

    /// What OK does for the running command, from the dialog, the ribbon or the marking menu.
    static func finish(_ model: DesignModel) {
        if model.genericCommand != nil { return }
        if let why = missing(model) {
            model.flash(why, error: true)
            return
        }
        switch model.tool {
        case .move: FeatureSession.of(model).commitMove()
        case .mirror: model.mirrorSelected(); model.tool = .select
        case .line, .spline: model.endChain(); model.tool = .select
        default: FeatureSession.of(model).commit()
        }
    }

    /// Cancel: the preview (or the edit) goes back and the tool ends.
    static func cancel(_ model: DesignModel) {
        if model.genericCommand != nil { model.genericCommand = nil } else { FeatureSession.of(model).cancel() }
    }

    private func close() { Self.cancel(model) }
}

// MARK: Navigation bar and timeline

struct NavigationBar: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @Binding var perspective: Bool

    var body: some View {
        HStack(spacing: VFSpace.xxs) {
            item("rotate.3d", "Orbit (right drag or Option drag)") { model.camera.orbit(dx: 40, dy: 0); model.cameraChanged() }
            item("hand.raised", "Pan (middle drag or two fingers)") {}
            item("plus.magnifyingglass", "Zoom in") { model.camera.zoom(1.25); model.cameraChanged() }
            item("arrow.up.left.and.down.right.magnifyingglass", "Fit") { model.zoomToFit() }
            Divider().frame(height: LegacyMetrics.navDivider)
            item("viewfinder", "Look At") {
                if case let .face(_, _, _, n)? = model.selection.first(where: \.isFace) { model.look(along: n) }
                else if let pl = model.sketchPlane { model.look(along: pl.normal) }
            }
            Menu {
                Toggle("Perspective", isOn: $perspective)
                ForEach(StandardView.allCases, id: \.self) { v in Button(v.rawValue.capitalized) { model.setView(v) } }
            } label: { Image(systemName: "cube.transparent") }
            .menuStyle(.vfPlain).frame(width: LegacyMetrics.navMenu)
            Menu {
                Button("Shaded with Edges") { model.run("view.visual_style", ["style": "shaded_with_edges"], quiet: true) }
                Button("Shaded") { model.run("view.visual_style", ["style": "shaded"], quiet: true) }
                Button("Wireframe") { model.run("view.visual_style", ["style": "wireframe"], quiet: true) }
                Divider()
                Button("Toggle Grid") { model.run("view.grid", quiet: true) }
            } label: { Image(systemName: "square.grid.3x3.square") }
            .menuStyle(.vfPlain).frame(width: LegacyMetrics.navMenu)
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, VFSpace.s).frame(height: LegacyMetrics.navBar)
        .vfSurface(.control)
    }

    private func item(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: LegacyMetrics.navItem.width, height: LegacyMetrics.navItem.height) }
            .buttonStyle(.plain).help(help)
    }
}

struct TimelineBar: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    @State private var editing: FeatureEditRequest?

    var body: some View {
        content.sheet(item: $editing) { r in EditFeatureSheet(model: model, feature: r.feature) }
    }

    @ViewBuilder private var content: some View {
        HStack(spacing: VFSpace.m) {
            HStack(spacing: VFSpace.xxs) {
                control("backward.end.fill") { model.rollTimeline(to: 0) }
                control("backward.frame.fill") { model.rollTimeline(to: max(0, model.snapshot.marker - 1)) }
                control("play.fill") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
                control("forward.frame.fill") { model.rollTimeline(to: min(model.snapshot.timeline.count, model.snapshot.marker + 1)) }
                control("forward.end.fill") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
            }
            Divider().frame(height: LegacyMetrics.timelineDivider)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VFSpace.xxs) {
                    ForEach(Array(model.snapshot.timeline.enumerated()), id: \.element.id) { i, f in
                        let rolled = f.rolled_back ?? false
                        Image(systemName: FeatureSymbol.of(f.type))
                            .font(VFFont.glyph(15))
                            .foregroundStyle(theme.ink)
                            .frame(width: LegacyMetrics.navItem.width, height: LegacyMetrics.navItem.height)
                            .background(f.error != nil ? theme.danger.opacity(0.25) : (rolled ? Color.clear : theme.accent.opacity(0.12)),
                                        in: RoundedRectangle(cornerRadius: VFRadius.chip, style: .continuous))
                            .opacity(rolled ? 0.4 : 1)
                            .help("\(f.name) (\(f.type))" + (f.error.map { "\n\($0)" } ?? ""))
                            .onTapGesture(count: 2) { FeatureEditor.edit(model, feature: f.name) { editing = FeatureEditRequest(feature: f.name) } }
                            .onTapGesture { model.rollTimeline(to: i + 1) }
                            .draggable(f.name)
                            .dropDestination(for: String.self) { names, _ in
                                guard let n = names.first, n != f.name else { return false }
                                model.run("timeline.reorder", ["feature": n, "position": i])
                                return true
                            }
                            .contextMenu {
                                Button("Roll History Marker Here") { model.rollTimeline(to: i + 1) }
                                if f.type.lowercased() == "sketch", let sk = FeatureEditor.sketchID(model, feature: f.name) {
                                    SketchTileMenuItems(model: model, sketch: sk)
                                } else {
                                    Button("Edit Feature") { FeatureEditor.edit(model, feature: f.name) { editing = FeatureEditRequest(feature: f.name) } }
                                }
                                Button("Suppress") { model.run("timeline.suppress", ["feature": f.id]) }
                                Button("Delete") { model.run("timeline.delete", ["feature": f.id]) }
                            }
                        if i + 1 == model.snapshot.marker, model.snapshot.marker < model.snapshot.timeline.count {
                            Rectangle().fill(theme.warning).frame(width: LegacyMetrics.marker, height: LegacyMetrics.navItem.height)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, VFSpace.m)
        .frame(height: LegacyMetrics.timeline)
        .background(theme.chromeDeep)
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(VFFont.glyph(11)).frame(width: LegacyMetrics.timelineControl, height: LegacyMetrics.timelineControl) }
            .buttonStyle(.plain).foregroundStyle(theme.ink)
    }
}

/// Geometry of the legacy layout's own bars and panels (`--legacy-ui`). Colours, type, spacing
/// and radii come from the theme tokens; these are the few fixed sizes this layout alone uses.
private enum LegacyMetrics {
    /// Pipeline row and design tab height.
    static let bar: CGFloat = 30
    static let appBar: CGFloat = 36
    static let iconButton: CGFloat = 28
    static let tabStrip: CGFloat = 28
    static let tabUnderline: CGFloat = 2
    static let ribbonBody: CGFloat = 70
    static let ribbonButtons: CGFloat = 60
    static let panelDivider: CGFloat = 54
    static let commandButton = CGSize(width: 40, height: 34)
    static let bomHeight: CGFloat = 460
    static let libraryIdeal: CGFloat = 380
    static let libraryMax: CGFloat = 560
    static let browserWidth: CGFloat = 250
    static let browserMaxHeight: CGFloat = 380
    static let viewCube: CGFloat = 104
    static let dialogWidth: CGFloat = 300
    /// Browser tree: icon column, disclosure chevron and the indent of each level.
    static let rowIcon: CGFloat = 14
    static let chevron: CGFloat = 10
    static let indentStep: CGFloat = 14
    static func indent(_ level: Int) -> CGFloat { VFSpace.m + CGFloat(level) * indentStep }
    static let navBar: CGFloat = 32
    static let navItem = CGSize(width: 30, height: 26)
    static let navMenu: CGFloat = 34
    static let navDivider: CGFloat = 18
    static let timeline: CGFloat = 38
    static let timelineDivider: CGFloat = 22
    static let timelineControl: CGFloat = 24
    /// The history marker between two features.
    static let marker: CGFloat = 3
}

#endif
