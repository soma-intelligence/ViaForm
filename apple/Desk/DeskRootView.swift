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
    @State private var tab = "SOLID"
    @State private var showBrowser = true
    @State private var perspective = false
    @State private var showData = false

    static let theme = ViewportTheme(
        backgroundTop: SIMD4(0.78, 0.83, 0.88, 1),
        backgroundBottom: SIMD4(0.98, 0.98, 0.99, 1),
        highlight: SIMD4(0.13, 0.55, 0.95, 1),
        hover: SIMD4(0.45, 0.72, 1.0, 1),
        edge: SIMD4(0.1, 0.1, 0.1, 1)
    )

    enum Workspace: String, CaseIterable { case design = "DESIGN", electronics = "ELECTRONICS" }

    var body: some View {
        VStack(spacing: 0) {
            AppBar(model: model, showData: $showData)
            HStack(spacing: 0) {
                Menu(workspace.rawValue) {
                    ForEach(Workspace.allCases, id: \.self) { w in
                        Button { workspace = w } label: { Label(w.rawValue.capitalized, systemImage: w == .design ? "cube" : "cpu") }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                Divider().frame(height: 16)
                if workspace == .electronics {
                    Text("Schematic and board on the PCBCraft engine, KiCad export").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10)
                }
                Spacer()
            }
            .frame(height: 24)
            .background(Color(nsColor: .windowBackgroundColor))
            if workspace == .electronics {
                DeskPCBView(model: pcb, design: model) { workspace = .design }
            } else {
                designBody
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--electronics") { workspace = .electronics }
            if args.contains("--board") { workspace = .electronics; pcb.sheet = .board }
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
        .onChange(of: workspace) { _, _ in pcb.syncLink(model) }
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
                            ViewCube(model: model, size: 104, faceColor: Color(white: 0.97), edgeColor: Color(white: 0.5), textColor: Color(white: 0.28))
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
                Button("New Design") { model.newDesign() }.keyboardShortcut("n")
                Button("Open…") { FileActions.open(model) }.keyboardShortcut("o")
                Button("Sample Bracket") { model.loadSample() }
                Divider()
                Button("Save As…") { FileActions.save(model) }.keyboardShortcut("s")
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
                Button { model.newDesign() } label: { Image(systemName: "plus").frame(width: 28, height: 28) }.help("New Design")
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
        for c in model.commands where c.tab == tab {
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
                        Text(t).font(.system(size: 11, weight: .semibold))
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
                        Button { model.finishSketch() } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
                                Text("FINISH SKETCH").font(.system(size: 9, weight: .bold))
                            }.frame(width: 90, height: 60)
                        }.buttonStyle(.plain)
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
                        Image(systemName: CommandSymbol.of(c.icon, id: c.id))
                            .font(.system(size: 20))
                            .frame(width: 40, height: 34)
                            .foregroundStyle(active(c) ? Color.white : Color.primary)
                            .background(active(c) ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(c.label + (c.key.map { "  (\($0))" } ?? ""))
                }
            }
            Menu {
                ForEach(commands) { c in
                    Button { CommandRouter.run(c, model) } label: {
                        Label(c.label, systemImage: CommandSymbol.of(c.icon, id: c.id))
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
    @Bindable var model: DesignModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: icon)
                Text(title.uppercased()).font(.system(size: 11, weight: .bold))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color.accentColor.opacity(0.85)).foregroundStyle(.white)
            if let c = model.genericCommand {
                GenericCommandForm(model: model, command: c)
            } else {
                VStack(alignment: .leading, spacing: 10) { rows }
                    .padding(12)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelTool() }
                    Button("OK") { ok() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
                .padding(10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.15)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }

    private var title: String { model.genericCommand?.label ?? model.tool.label }
    private var icon: String { model.genericCommand.map { CommandSymbol.of($0.icon, id: $0.id) } ?? model.tool.symbol }

    @ViewBuilder private var rows: some View {
        switch model.tool {
        case .extrude, .revolve:
            selectionRow("Profile", model.sketchOpen ? "open sketch" : "last sketch, all profiles")
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

    private func ok() {
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

// MARK: Files

enum FileActions {
    static func open(_ model: DesignModel) {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["sc", "solidcraft", "json", "step", "stp", "iges", "igs", "stl", "obj", "3mf", "dxf", "svg"].compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { model.open(url) }
    }

    static func save(_ model: DesignModel) {
        if let path = model.snapshot.path { model.run("file.save", ["path": path]); return }
        let p = NSSavePanel()
        p.nameFieldStringValue = model.snapshot.name + ".sc"
        if p.runModal() == .OK, let url = p.url { model.save(to: url) }
    }

    static func export(_ model: DesignModel) {
        let p = NSSavePanel()
        p.nameFieldStringValue = model.snapshot.name + ".step"
        p.allowedContentTypes = ["step", "stl", "obj", "3mf"].compactMap { UTType(filenameExtension: $0) }
        p.allowsOtherFileTypes = true
        if p.runModal() == .OK, let url = p.url { model.export(to: url) }
    }
}
#endif
