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

    static let theme = ViewportTheme(
        backgroundTop: SIMD4(0.28, 0.30, 0.34, 1),
        backgroundBottom: SIMD4(0.13, 0.145, 0.165, 1),
        highlight: SIMD4(0.24, 0.55, 1.0, 1),
        hover: SIMD4(0.5, 0.74, 1.0, 1),
        edge: SIMD4(0.05, 0.06, 0.07, 1),
        gridOpacity: 0.3
    )

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
                Divider().frame(height: 16)
                Button { showBom.toggle() } label: {
                    Label("BOM", systemImage: "list.bullet.rectangle").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showBom ? Color.accentColor : Color.primary)
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .help("Bill of materials: design parts, PCB components and component files, priced for N builds (Shift-Command-B)")
                Button { showLibrary.toggle() } label: {
                    Label("Libraries", systemImage: "books.vertical").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showLibrary ? Color.accentColor : Color.primary)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .help("Libraries: KiCad, standard hardware, distributors, marketplaces, saved parts (Shift-Command-L)")
                .padding(.horizontal, 10)
            }
            .frame(height: 30)
            .background(Color(nsColor: .windowBackgroundColor))
            switch workspace {
            case .electronics:
                DeskPCBView(model: pcb, design: model) { workspace = .design }
            case .simulation, .train:
                // Training lives in the simulation workspace for now (its Train panel).
                SimulationView(model: sim)
            case .generate:
                GenerateView(model: generate, design: model, theme: Self.theme)
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
                BomPanel(model: bom, design: model, pcb: pcb) { showBom = false }.frame(height: 460)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
        }
    }

    @ViewBuilder private var designBody: some View {
        VStack(spacing: 0) {
            Ribbon(model: model, tab: $tab)
            Divider()
            ZStack {
                Viewport(model: model, theme: Self.theme)
                VStack {
                    HStack(alignment: .top) {
                        if showBrowser { BrowserPanel(model: model, shown: $showBrowser).frame(width: 250) }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 10) {
                            ViewCube(model: model, size: 104, faceColor: Color(red: 0.29, green: 0.31, blue: 0.35), edgeColor: Color(white: 0.65), textColor: Color(white: 0.86))
                            if model.tool != .select || model.genericCommand != nil { CommandDialog(model: model).frame(width: 300) }
                        }
                    }
                    Spacer()
                    PCBLinkBanner(design: model, pcb: pcb)
                    MessageBanner(model: model)
                    NavigationBar(model: model, perspective: $perspective)
                }
                .padding(10)
                if let at = model.markingMenu { MarkingMenu(model: model, at: at) }
                if model.toolboxOpen {
                    VStack { ToolboxSearch(model: model).padding(.top, 60); Spacer() }
                }
            }
            .overlay(alignment: .leading) {
                if showData { DataPanel(model: model, shown: $showData).transition(.move(edge: .leading)) }
            }
            .animation(.easeOut(duration: 0.18), value: showData)
            Divider()
            TimelineBar(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
    let model: DesignModel
    @Binding var showData: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button { showData.toggle() } label: { Image(systemName: "square.grid.3x3") }.help("Data Panel")
            Menu {
                Button("New Design") { FileActions.newDesign(model) }.keyboardShortcut("n")
                Button("Open…") { FileActions.open(model) }.keyboardShortcut("o")
                Button("Sample Bracket") { model.loadSample() }
                Divider()
                Button("Save As…") { FileActions.saveAs(model) }.keyboardShortcut("s")
                Button("Export…") { FileActions.export(model) }.keyboardShortcut("e", modifiers: [.command, .shift])
            } label: { Image(systemName: "doc") }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            Button { FileActions.save(model) } label: { Image(systemName: "square.and.arrow.down") }.help("Save")
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.snapshot.undo == 0).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.snapshot.redo == 0).help("Redo")
            // Design tabs: one per open design, then the new design button.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "cube").foregroundStyle(.secondary)
                    Text(model.snapshot.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if model.snapshot.dirty { Circle().fill(.secondary).frame(width: 6, height: 6) }
                }
                .padding(.horizontal, 14).frame(height: 30)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                Button { FileActions.newDesign(model) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }.help("New Design")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            Button { model.toolboxOpen = true } label: { Image(systemName: "magnifyingglass") }.help("Search commands (S)")
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).help("Job status: \(model.snapshot.bodies.count) bodies, revision \(model.snapshot.revision)")
            Image(systemName: "bell").foregroundStyle(.secondary)
            Menu {
                Link("SolidCraft engine", destination: URL(string: "https://github.com/tangency-labs/solidcraft")!)
                Link("PCBCraft engine", destination: URL(string: "https://github.com/tangency-labs/pcbcraft")!)
            } label: { Image(systemName: "questionmark.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Image(systemName: "person.crop.circle").font(.system(size: 17)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: Ribbon

/// Tabs and panels from the registry: each panel shows its main commands as big buttons and
/// all of them in its drop-down.
struct Ribbon: View {
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
                        Text(StageLabels.tab(t)).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(tab == t ? Color.accentColor : (t == "SKETCH" ? Color.accentColor.opacity(0.8) : .primary))
                            .overlay(alignment: .bottom) { if tab == t { Rectangle().fill(Color.accentColor).frame(height: 2) } }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(height: 28)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(panels, id: \.0) { name, cmds in
                        RibbonPanel(model: model, name: name, commands: cmds)
                        Divider().frame(height: 54)
                    }
                    if tab == "SKETCH" {
                        DoneButton { model.finishSketch() }.padding(.horizontal, 12).frame(height: 60)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 70)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RibbonPanel: View {
    let model: DesignModel
    let name: String
    let commands: [CommandInfo]

    /// The commands shown as big buttons: the ones with a shortcut first (the common ones).
    private var main: [CommandInfo] {
        let keyed = commands.filter { $0.key != nil }
        return Array((keyed + commands.filter { $0.key == nil }).prefix(name == "FINISH SKETCH" ? 1 : 4))
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(main) { c in
                    Button { CommandRouter.run(c, model) } label: {
                        CommandIcon(icon: c.icon, id: c.id)
                            .frame(width: 40, height: 34)
                            .foregroundStyle(active(c) ? Color.white : Color.primary)
                            .background(active(c) ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
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
                Text(name).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func active(_ c: CommandInfo) -> Bool { model.tool.commandID == c.id && model.tool != .select }
}

/// A registry command to what runs it: a modelling tool, a direct action or the generic form.
enum CommandRouter {
    static func run(_ c: CommandInfo, _ m: DesignModel) {
        switch c.id {
        case "sketch.finish": m.finishSketch(); return
        case "edit.undo": m.undo(); return
        case "edit.redo": m.redo(); return
        case "solid.combine": m.genericCommand = c; return
        case "solid.remove": m.deleteSelection(); return
        case "inspect.measure": m.measureSelection(); return
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
    let model: DesignModel
    @Binding var shown: Bool
    @State private var open: Set<String> = ["Components", "Bodies", "Sketches"]
    @State private var hidden: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BROWSER").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Button { shown = false } label: { Image(systemName: "minus").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Color(nsColor: .controlBackgroundColor))
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
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
                                HStack(spacing: 5) {
                                    Image(systemName: c.linkedPCB ? "cpu" : "shippingbox").foregroundStyle(c.linkedPCB ? Color.accentColor : .secondary).frame(width: 14)
                                    Text(c.occurrence ?? c.name).lineLimit(1)
                                    if c.grounded { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Grounded") }
                                    if c.linkedPCB { Image(systemName: "link").font(.system(size: 9)).foregroundStyle(Color.accentColor).help("Linked to the Electronics board") }
                                    Spacer()
                                }
                                .font(.system(size: 12))
                                .padding(.leading, 36).frame(height: 20)
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
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 380)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func folder<Content: View>(_ name: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if open.contains(name) { open.remove(name) } else { open.insert(name) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: open.contains(name) ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 10)
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(name)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.leading, 14).frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open.contains(name) { content() }
    }

    private func row(_ indent: Int, _ symbol: String, _ text: String, bold: Bool = false, selected: Bool = false, eye body: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let body {
                Button {
                    let show = hidden.contains(body)
                    if show { hidden.remove(body) } else { hidden.insert(body) }
                    model.toggleBodyVisibility(body, visible: show)
                } label: {
                    Image(systemName: hidden.contains(body) ? "eye.slash" : "eye").font(.system(size: 10)).frame(width: 14)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 14)
            Text(text).fontWeight(bold ? .semibold : .regular).lineLimit(1).opacity(body.map { hidden.contains($0) ? 0.45 : 1 } ?? 1)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(8 + indent * 14)).frame(height: 20)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear)
        .contentShape(Rectangle())
    }
}

// MARK: Command dialog

/// The dialog of the running command, docked at the right of the viewport.
struct CommandDialog: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(theme.accentText)
                Text(title.uppercased()).font(VFFont.caps).tracking(VFTypeScale.capsTracking).foregroundStyle(theme.ink)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(theme.inkSecondary).help("Cancel (Escape)")
            }
            .padding(.horizontal, 12).frame(height: 34)
            .overlay(alignment: .bottom) { VFHairline() }
            if let c = model.genericCommand {
                GenericCommandForm(model: model, command: c)
            } else {
                VStack(alignment: .leading, spacing: 10) { rows }
                    .padding(12)
                Divider()
                HStack(spacing: VFSpace.s) {
                    Button { model.cancelTool() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button { ok() } label: { Text("Done").frame(maxWidth: .infinity) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.vfPrimary)
                }
                .padding(10)
            }
        }
        .vfSurface(.floating)
    }

    private var title: String { StageLabels.command(model.genericCommand?.label ?? model.tool.label) }
    private var icon: String { model.genericCommand.map { CommandSymbol.of($0.icon, id: $0.id) } ?? model.tool.symbol }

    @ViewBuilder private var rows: some View {
        switch model.tool {
        case .extrude, .revolve:
            selectionRow("Profile", model.sketchOpen ? "open sketch" : model.extrudeProfileSummary)
        case .pressPull, .shell:
            selectionRow("Faces", "\(model.selection.filter(\.isFace).count) selected")
        case .fillet, .chamfer:
            selectionRow("Edges", "\(model.selection.filter(\.isEdge).count) selected")
        case .move, .mirror:
            selectionRow("Bodies", "\(model.bodiesInSelection.count) selected")
        case .box, .cylinder, .sphere, .torus:
            Text("Click in the viewport to place it.").font(.callout).foregroundStyle(.secondary)
        default:
            if model.tool.isSketchTool { Text(sketchHint).font(.callout).foregroundStyle(.secondary) }
        }
        if let v = model.tool.value {
            ValueField(label: v.label, unit: v.unit, value: $model.toolValue, step: v.unit == "deg" ? 15 : 1)
        }
        if model.tool == .extrude || model.tool == .revolve {
            Picker("Operation", selection: $model.toolOperation) {
                Text("Automatic").tag("auto"); Text("New Body").tag("new_body"); Text("Join").tag("join"); Text("Cut").tag("cut"); Text("Intersect").tag("intersect")
            }
            .onChange(of: model.toolOperation) { _, _ in model.applyPreview() }
        }
        if model.tool == .revolve {
            Picker("Axis", selection: $model.revolveAxis) {
                Text("Sketch X").tag("x"); Text("Sketch Y").tag("y"); Text("X").tag("X"); Text("Y").tag("Y"); Text("Z").tag("Z")
            }
            .onChange(of: model.revolveAxis) { _, _ in model.applyPreview() }
        }
        if model.tool == .move {
            HStack {
                ForEach(0..<3, id: \.self) { i in
                    TextField(["X", "Y", "Z"][i], value: Binding(get: { model.moveVector[i] }, set: { model.moveVector[i] = $0 }), format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        if model.tool == .mirror {
            Picker("Plane", selection: $model.mirrorPlane) { ForEach(["XY", "XZ", "YZ"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
        }
        if model.tool == .sketch {
            Text("Click a planar face, or a plane:").font(.callout).foregroundStyle(.secondary)
            HStack { ForEach(["XY", "XZ", "YZ"], id: \.self) { p in Button(p) { model.startSketch(p) } } }
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

    private func selectionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Image(systemName: "cursorarrow.click").foregroundStyle(Color.accentColor)
            Text(value).font(.callout)
        }
    }

    private func ok() { Self.finish(model) }

    /// What Done does for the running command, from the dialog or the ribbon.
    static func finish(_ model: DesignModel) {
        if model.genericCommand != nil { return }
        switch model.tool {
        case .move: model.moveSelected(); model.tool = .select
        case .mirror: model.mirrorSelected(); model.tool = .select
        case .line, .spline: model.endChain(); model.tool = .select
        default: if model.hasPreview { model.commitTool() } else { model.tool = .select }
        }
    }

    private func close() {
        if model.genericCommand != nil { model.genericCommand = nil } else { model.cancelTool() }
    }
}

// MARK: Navigation bar and timeline

struct NavigationBar: View {
    let model: DesignModel
    @Binding var perspective: Bool

    var body: some View {
        HStack(spacing: 2) {
            item("rotate.3d", "Orbit (right drag or Option drag)") { model.camera.orbit(dx: 40, dy: 0); model.cameraChanged() }
            item("hand.raised", "Pan (middle drag or two fingers)") {}
            item("plus.magnifyingglass", "Zoom in") { model.camera.zoom(1.25); model.cameraChanged() }
            item("arrow.up.left.and.down.right.magnifyingglass", "Fit") { model.zoomToFit() }
            Divider().frame(height: 18)
            item("viewfinder", "Look At") {
                if case let .face(_, _, _, n)? = model.selection.first(where: \.isFace) { model.look(along: n) }
                else if let pl = model.sketchPlane { model.look(along: pl.normal) }
            }
            Menu {
                Toggle("Perspective", isOn: $perspective)
                ForEach(StandardView.allCases, id: \.self) { v in Button(v.rawValue.capitalized) { model.setView(v) } }
            } label: { Image(systemName: "cube.transparent") }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 34)
            Menu {
                Button("Shaded with Edges") { model.run("view.visual_style", ["style": "shaded_with_edges"], quiet: true) }
                Button("Shaded") { model.run("view.visual_style", ["style": "shaded"], quiet: true) }
                Button("Wireframe") { model.run("view.visual_style", ["style": "wireframe"], quiet: true) }
                Divider()
                Button("Toggle Grid") { model.run("view.grid", quiet: true) }
            } label: { Image(systemName: "square.grid.3x3.square") }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 34)
        }
        .padding(.horizontal, 6).frame(height: 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.12)))
    }

    private func item(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 26) }
            .buttonStyle(.plain).help(help)
    }
}

struct TimelineBar: View {
    let model: DesignModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                control("backward.end.fill") { model.rollTimeline(to: 0) }
                control("backward.frame.fill") { model.rollTimeline(to: max(0, model.snapshot.marker - 1)) }
                control("play.fill") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
                control("forward.frame.fill") { model.rollTimeline(to: min(model.snapshot.timeline.count, model.snapshot.marker + 1)) }
                control("forward.end.fill") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
            }
            Divider().frame(height: 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(model.snapshot.timeline.enumerated()), id: \.element.id) { i, f in
                        let rolled = f.rolled_back ?? false
                        Image(systemName: FeatureSymbol.of(f.type))
                            .font(.system(size: 15))
                            .frame(width: 30, height: 26)
                            .background(f.error != nil ? Color.red.opacity(0.25) : (rolled ? Color.clear : Color.accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 4))
                            .opacity(rolled ? 0.4 : 1)
                            .help("\(f.name) (\(f.type))" + (f.error.map { "\n\($0)" } ?? ""))
                            .onTapGesture { model.rollTimeline(to: i + 1) }
                            .draggable(f.name)
                            .dropDestination(for: String.self) { names, _ in
                                guard let n = names.first, n != f.name else { return false }
                                model.run("timeline.reorder", ["feature": n, "position": i])
                                return true
                            }
                            .contextMenu {
                                Button("Roll History Marker Here") { model.rollTimeline(to: i + 1) }
                                Button("Edit Feature") { model.run("timeline.edit", ["feature": f.name]) }
                                Button("Suppress") { model.run("timeline.suppress", ["feature": f.id]) }
                                Button("Delete") { model.run("timeline.delete", ["feature": f.id]) }
                            }
                        if i + 1 == model.snapshot.marker, model.snapshot.marker < model.snapshot.timeline.count {
                            Rectangle().fill(Color.orange).frame(width: 3, height: 26)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 24) }.buttonStyle(.plain)
    }
}

#endif
