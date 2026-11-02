#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The touch front end (iPad and iPhone): the canvas fills the screen, tools float over it,
/// direct manipulation first. Finger orbits, two fingers pan, pinch zooms, Pencil draws.
/// Layout: project sidebar on the left, items and history sidebars on the right, all opened
/// from the top bar; tools in a column at the left edge; selection-driven suggestions below.
struct TouchRootView: View {
    @State private var model = DesignModel()
    @State private var pcb = PCBModel(sample: ProcessInfo.processInfo.arguments.contains("--sample"))
    @State private var space: Space = ProcessInfo.processInfo.arguments.contains("--electronics") ? .electronics : .modeling
    @State private var side: SideSheet?
    @State private var showProject = false
    @State private var showCommands = false
    @State private var importing = false
    @State private var exporting: ExportKind?
    @State private var perspective = false
    @State private var sectionOn = false
    @State private var isolated: [String] = []
    @Environment(\.horizontalSizeClass) private var hSize

    enum SideSheet { case items, history }
    enum Space: String, CaseIterable { case modeling = "Modeling", electronics = "Electronics" }

    private var compact: Bool { hSize == .compact }

    static let theme = ViewportTheme(
        backgroundTop: SIMD4(0.86, 0.88, 0.91, 1),
        backgroundBottom: SIMD4(0.97, 0.97, 0.98, 1),
        highlight: SIMD4(0.12, 0.47, 0.98, 1),
        hover: SIMD4(0.35, 0.65, 1.0, 1),
        edge: SIMD4(0.15, 0.16, 0.18, 1)
    )

    var body: some View {
        Group {
            if space == .electronics {
                ZStack(alignment: .topLeading) {
                    TouchPCBView(model: pcb, design: model, showProject: $showProject) { space = .modeling }
                    if showProject, !compact {
                        ProjectSidebar(model: model, space: $space, importing: $importing, exporting: $exporting)
                            .padding(.top, 66).padding(.leading, 12)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
            } else {
                modeling
            }
        }
        .animation(.snappy(duration: 0.25), value: showProject)
        .sheet(isPresented: Binding(get: { compact && showProject }, set: { showProject = $0 })) {
            ProjectSidebar(model: model, space: $space, importing: $importing, exporting: $exporting).presentationDetents([.medium, .large])
        }
        .onChange(of: space) { _, _ in showProject = false; pcb.syncLink(model) }
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--board") { space = .electronics; pcb.sheet = .board } }
    }

    private var modeling: some View {
        ZStack {
            Viewport(model: model, theme: Self.theme).ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                HStack(alignment: .top, spacing: 10) {
                    if showProject, !compact {
                        ProjectSidebar(model: model, space: $space, importing: $importing, exporting: $exporting)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    if !compact { ToolRail(model: model, compact: compact, showCommands: $showCommands) }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 10) {
                        ViewCube(model: model, size: compact ? 70 : 92, faceColor: .white, edgeColor: Color(white: 0.6), textColor: Color(white: 0.3))
                        if !compact, side == .items { ItemsPanel(model: model).transition(.move(edge: .trailing).combined(with: .opacity)) }
                        if !compact, side == .history { HistorySidebar(model: model).transition(.move(edge: .trailing).combined(with: .opacity)) }
                    }
                }
                Spacer(minLength: 0)
                PCBLinkBanner(design: model, pcb: pcb)
                MessageBanner(model: model)
                if model.tool == .sketch { PlaneChooser(model: model) }
                if model.tool != .select, model.tool != .sketch { ToolCard(model: model) }
                else if !model.suggestions.isEmpty { SuggestionBar(model: model) }
                if compact { ToolRail(model: model, compact: compact, showCommands: $showCommands) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .animation(.snappy(duration: 0.25), value: side)
        .animation(.snappy(duration: 0.25), value: model.tool)
        .sheet(isPresented: $showCommands) { CommandBrowser(model: model) }
        // On iPhone the sidebars come up as sheets.
        .sheet(isPresented: Binding(get: { compact && side != nil }, set: { if !$0 { side = nil } })) {
            Group { if side == .history { HistorySidebar(model: model) } else { ItemsPanel(model: model) } }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { model.genericCommand }, set: { model.genericCommand = $0 })) { c in
            GenericCommandForm(model: model, command: c).presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { r in
            if case let .success(urls) = r, let url = urls.first {
                let ok = url.startAccessingSecurityScopedResource()
                model.open(url)
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
        .sheet(item: $exporting) { kind in ExportSheet(model: model, kind: kind) }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            bar("sidebar.left", "Project", on: showProject) { showProject.toggle() }
            Text(model.snapshot.name).font(.headline).lineLimit(1).padding(.horizontal, 6)
            Spacer()
            Group {
                bar("arrow.uturn.backward", "Undo") { model.undo() }.disabled(model.snapshot.undo == 0)
                bar("arrow.uturn.forward", "Redo") { model.redo() }.disabled(model.snapshot.redo == 0)
            }
            Divider().frame(height: 22)
            bar("square.split.diagonal", "Section view", on: sectionOn) { toggleSection() }
            bar("scope", "Isolate", on: !isolated.isEmpty) { toggleIsolate() }
            Menu {
                Toggle("Perspective", isOn: $perspective)
                Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.zoomToFit() }
                ForEach(StandardView.allCases, id: \.self) { v in Button(v.rawValue.capitalized) { model.setView(v) } }
            } label: { Image(systemName: "eye").font(.system(size: 17, weight: .medium)).frame(width: 40, height: 40) }
            Divider().frame(height: 22)
            bar("square.3.layers.3d", "Items", on: side == .items) { side = side == .items ? nil : .items }
            bar("clock.arrow.circlepath", "History", on: side == .history) { side = side == .history ? nil : .history }
            bar("square.and.arrow.up", "Export") { exporting = .step }
        }
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .onChange(of: perspective) { _, p in
            model.camera.fov = p ? 0.7 : 0
            model.cameraChanged()
        }
    }

    private func bar(_ symbol: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .background(on ? Color.accentColor.opacity(0.14) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func toggleSection() {
        sectionOn.toggle()
        if sectionOn { model.run("inspect.section", ["plane": "XZ", "at": 0], quiet: true) }
        else { model.run("inspect.section", ["clear": true], quiet: true) }
    }

    /// Isolate hides every body outside the selection; a second tap shows them again.
    private func toggleIsolate() {
        if !isolated.isEmpty {
            for b in isolated { model.toggleBodyVisibility(b, visible: true) }
            isolated = []
            return
        }
        let keep = model.bodiesInSelection
        guard !keep.isEmpty else { model.message = "Select a body to isolate"; return }
        isolated = model.snapshot.bodies.map(\.name).filter { !keep.contains($0) }
        for b in isolated { model.toggleBodyVisibility(b, visible: false) }
    }
}

/// Spaces and designs: Modeling and Electronics are live; Visualization and Drawings are
/// placeholders for now.
struct ProjectSidebar: View {
    let model: DesignModel
    @Binding var space: TouchRootView.Space
    @Binding var importing: Bool
    @Binding var exporting: ExportKind?

    var body: some View {
        List {
            Section("Spaces") {
                Button { space = .modeling } label: { Label("Modeling", systemImage: "cube") }
                    .foregroundStyle(space == .modeling ? Color.accentColor : .primary)
                Button { space = .electronics } label: { Label("Electronics", systemImage: "cpu") }
                    .foregroundStyle(space == .electronics ? Color.accentColor : .primary)
                Label("Visualization", systemImage: "sparkles").foregroundStyle(.secondary)
                Label("Drawings", systemImage: "doc.richtext").foregroundStyle(.secondary)
            }
            Section("Design") {
                Button("New Design", systemImage: "plus") { model.newDesign() }
                Button("Open or Import…", systemImage: "folder") { importing = true }
                Button("Sample Bracket", systemImage: "wand.and.stars") { model.loadSample() }
            }
            Section("Export") {
                Button("Save Design…", systemImage: "square.and.arrow.down") { exporting = .design }
                Button("STEP…", systemImage: "cube") { exporting = .step }
                Button("STL…", systemImage: "printer") { exporting = .stl }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .frame(width: 260, height: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

/// The parametric history as a vertical list; tap a step to roll the design back to it.
struct HistorySidebar: View {
    let model: DesignModel

    var body: some View {
        List {
            ForEach(Array(model.snapshot.timeline.enumerated()), id: \.element.id) { i, f in
                let rolled = f.rolled_back ?? false
                Button { model.rollTimeline(to: i + 1) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: FeatureSymbol.of(f.type)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name)
                            Text(f.type).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if f.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                    .opacity(rolled ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Delete", role: .destructive) { model.run("timeline.delete", ["feature": f.id]) }
                    Button("Suppress") { model.run("timeline.suppress", ["feature": f.id]) }
                }
            }
            .onMove { from, to in
                guard let i = from.first, i < model.snapshot.timeline.count else { return }
                model.run("timeline.reorder", ["feature": model.snapshot.timeline[i].name, "position": to > i ? to - 1 : to])
            }
            Button("Roll to End", systemImage: "forward.end") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(width: 280, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

/// The floating tool column: what can be made from here.
struct ToolRail: View {
    let model: DesignModel
    let compact: Bool
    @Binding var showCommands: Bool

    var body: some View {
        if compact { strip } else { column }
    }

    /// iPhone: one bottom row.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if model.sketchOpen {
                    ForEach(Tool.sketchTools) { t in rail(t.symbol, t.label, active: model.tool == t) { activate(t) }.frame(width: 44) }
                    rail("checkmark", "Done") { model.finishSketch() }.frame(width: 44)
                } else {
                    ForEach(Tool.solidTools + Tool.primitiveTools) { t in rail(t.symbol, t.label, active: model.tool == t) { activate(t) }.frame(width: 44) }
                }
                rail("ellipsis.circle", "All Commands") { showCommands = true }.frame(width: 44)
            }
            .padding(4)
        }
        .background(.regularMaterial, in: Capsule())
    }

    private var column: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                if model.sketchOpen {
                    section("Sketch", Tool.sketchTools)
                    Button { model.finishSketch() } label: {
                        Label("Done", systemImage: "checkmark").font(.callout.bold()).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.vertical, 4)
                } else {
                    section("Create", Tool.solidTools)
                    section("Primitives", Tool.primitiveTools)
                    section("Arrange", Tool.combineTools)
                    section("Inspect", [.measure])
                }
                Divider().padding(.vertical, 4)
                rail("ellipsis.circle", "All Commands") { showCommands = true }
            }
            .padding(6)
        }
        .frame(width: compact ? 52 : 64)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    @ViewBuilder
    private func section(_ title: String, _ tools: [Tool]) -> some View {
        Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).padding(.top, 6)
        ForEach(tools) { t in
            rail(t.symbol, t.label, active: model.tool == t) { activate(t) }
        }
    }

    private func activate(_ t: Tool) {
        switch t {
        case .union: model.combine("join")
        case .subtract: model.combine("cut")
        case .intersect: model.combine("intersect")
        case .delete: model.deleteSelection()
        case .measure: model.measureSelection()
        case .sketch where model.selection.contains(where: \.isFace): model.sketchOnSelectedFace()
        default: model.tool = model.tool == t ? .select : t
        }
    }

    private func rail(_ symbol: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: compact ? 17 : 19, weight: .regular)).frame(height: 24)
                if !compact { Text(label).font(.system(size: 8.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7) }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 40 : 48)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(active ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Where a new sketch goes: a tapped face or a base plane.
struct PlaneChooser: View {
    let model: DesignModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap").foregroundStyle(.secondary)
            Text("Tap a face, or pick a plane").font(.callout)
            ForEach(["XY", "XZ", "YZ"], id: \.self) { p in
                Button(p) { model.startSketch(p) }.buttonStyle(.bordered)
            }
            Button { model.tool = .select } label: { Image(systemName: "xmark") }.buttonStyle(.bordered)
        }
        .padding(10)
        .background(.regularMaterial, in: Capsule())
    }
}

/// The active tool's numbers and its done/cancel, floating above the history.
struct ToolCard: View {
    @Bindable var model: DesignModel

    var body: some View {
        HStack(spacing: 12) {
            Label(model.tool.label, systemImage: model.tool.symbol).font(.headline).labelStyle(.titleAndIcon)
            if let v = model.tool.value {
                ValueField(label: v.label, unit: v.unit, value: $model.toolValue, step: v.unit == "deg" ? 15 : 1)
            }
            if model.tool == .extrude || model.tool == .revolve {
                Picker("Operation", selection: $model.toolOperation) {
                    Text("Auto").tag("auto"); Text("New").tag("new_body"); Text("Join").tag("join"); Text("Cut").tag("cut")
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .onChange(of: model.toolOperation) { _, _ in model.applyPreview() }
            }
            if model.tool == .revolve {
                Picker("Axis", selection: $model.revolveAxis) { ForEach(["x", "y", "X", "Y", "Z"], id: \.self) { Text($0) } }
                    .onChange(of: model.revolveAxis) { _, _ in model.applyPreview() }
            }
            if model.tool == .move {
                ForEach(0..<3, id: \.self) { i in
                    ValueField(label: ["X", "Y", "Z"][i], unit: "", value: Binding(get: { model.moveVector[i] }, set: { model.moveVector[i] = $0 }))
                }
            }
            if model.tool == .mirror {
                Picker("Plane", selection: $model.mirrorPlane) { ForEach(["XY", "XZ", "YZ"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 140)
            }
            hint
            Spacer(minLength: 0)
            Button { model.cancelTool() } label: { Image(systemName: "xmark").frame(width: 34, height: 34) }
                .buttonStyle(.bordered)
            Button { done() } label: { Image(systemName: "checkmark").frame(width: 34, height: 34) }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .frame(maxWidth: 900)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    @ViewBuilder private var hint: some View {
        let text: String? = switch model.tool {
        case .pressPull: model.selection.contains(where: \.isFace) ? nil : "Tap a face"
        case .fillet, .chamfer: model.selection.contains(where: \.isEdge) ? nil : "Tap edges"
        case .shell: model.selection.contains(where: \.isFace) ? nil : "Tap faces to open"
        case .box, .cylinder, .sphere, .torus: "Tap where it goes"
        case .line: "Tap points; double-tap ends"
        case .spline: "Tap fit points; double-tap ends"
        case .trim: "Tap the piece to remove"
        case .offset: "Tap a curve"
        case .sketchFillet: "Tap a corner"
        default: nil
        }
        if let text { Text(text).font(.callout).foregroundStyle(.secondary) }
    }

    private func done() {
        switch model.tool {
        case .move: model.moveSelected(); model.tool = .select
        case .mirror: model.mirrorSelected(); model.tool = .select
        case .line, .spline: model.endChain()
        default:
            if model.hasPreview { model.commitTool() } else { model.tool = .select }
        }
    }
}

/// Tools the selection invites, as a floating strip.
struct SuggestionBar: View {
    let model: DesignModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.suggestions) { t in
                Button {
                    switch t {
                    case .union: model.combine("join")
                    case .subtract: model.combine("cut")
                    case .intersect: model.combine("intersect")
                    case .delete: model.deleteSelection()
                    case .measure: model.measureSelection()
                    case .sketch: model.sketchOnSelectedFace()
                    default: model.tool = t
                    }
                } label: {
                    Label(t.label, systemImage: t.symbol).font(.callout.weight(.medium)).padding(.horizontal, 10).frame(height: 36)
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 22)
            Button { model.selection = []; model.selectedBodies = [] } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).padding(.horizontal, 6)
        }
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
    }
}

/// Bodies and sketches, with visibility.
struct ItemsPanel: View {
    let model: DesignModel

    var body: some View {
        List {
            if !model.assembly.isEmpty {
                Section("Components") {
                    ForEach(model.assembly) { c in
                        HStack {
                            Image(systemName: c.linkedPCB ? "cpu" : "shippingbox").foregroundStyle(c.linkedPCB ? Color.accentColor : .secondary)
                            Text(c.occurrence ?? c.name)
                            Spacer()
                            if c.linkedPCB { Image(systemName: "link").foregroundStyle(Color.accentColor) }
                            if c.grounded { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedBodies = Set(c.bodies) }
                    }
                }
            }
            Section("Bodies") {
                ForEach(model.snapshot.bodies) { b in
                    HStack {
                        Image(systemName: "cube.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(b.name)
                            if let v = b.volume_mm3 { Text(String(format: "%.0f mm³", v)).font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { model.toggleBodyVisibility(b.name, visible: !(b.visible ?? true)) } label: {
                            Image(systemName: (b.visible ?? true) ? "eye" : "eye.slash")
                        }.buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.selectedBodies.contains(b.name) { model.selectedBodies.remove(b.name) } else { model.selectedBodies.insert(b.name) }
                    }
                    .listRowBackground(model.selectedBodies.contains(b.name) ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            Section("Sketches") {
                ForEach(model.snapshot.sketches) { s in
                    HStack {
                        Image(systemName: "pencil.and.outline").foregroundStyle(.secondary)
                        Text(s.name)
                        Spacer()
                        Button("Edit") { model.run("sketch.edit", ["sketch": s.id]); if let pl = model.sketchPlane { model.look(along: pl.normal) }; model.tool = .line }
                            .font(.caption).buttonStyle(.bordered)
                    }
                }
            }
            if !model.snapshot.params.isEmpty {
                Section("Parameters") {
                    ForEach(model.snapshot.params) { p in
                        HStack { Text(p.name); Spacer(); Text(p.expression).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .frame(width: 280, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }
}

/// The parametric history: one chip per step; tapping one rolls the design back to it.
struct HistoryBar: View {
    let model: DesignModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(model.snapshot.timeline.enumerated()), id: \.element.id) { i, f in
                    let rolled = f.rolled_back ?? false
                    Button { model.rollTimeline(to: i + 1) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: FeatureSymbol.of(f.type))
                            Text(f.name).font(.caption.weight(.medium))
                            if f.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(rolled ? Color.clear : Color.accentColor.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.accentColor.opacity(rolled ? 0.25 : 0)))
                        .opacity(rolled ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Roll Back Here") { model.rollTimeline(to: i) }
                        Button("Delete", role: .destructive) { model.run("timeline.delete", ["feature": f.id]) }
                    }
                }
                Button { model.run("timeline.roll_to", ["position": "end"], quiet: true) } label: {
                    Image(systemName: "forward.end.fill").frame(width: 30, height: 30)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 44)
        .frame(maxWidth: 900)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Every command of the engine, searchable.
struct CommandBrowser: View {
    let model: DesignModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.0) { tab, cmds in
                    Section(tab.isEmpty ? "Other" : tab.capitalized) {
                        ForEach(cmds) { c in
                            Button {
                                dismiss()
                                if let t = Tool.allCases.first(where: { $0.commandID == c.id && $0 != .union && $0 != .subtract && $0 != .intersect }) {
                                    model.tool = t
                                } else {
                                    model.genericCommand = c
                                }
                            } label: {
                                Label { VStack(alignment: .leading) { Text(c.label); Text(c.id).font(.caption2.monospaced()).foregroundStyle(.secondary) } }
                                    icon: { Image(systemName: CommandSymbol.of(c.icon, id: c.id)) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Commands")
            .toolbar { Button("Close") { dismiss() } }
        }
    }

    private var groups: [(String, [CommandInfo])] {
        let q = query.lowercased()
        let list = model.commands.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.id.contains(q) }
        return Dictionary(grouping: list, by: \.tab).sorted { $0.key < $1.key }
    }
}

enum ExportKind: String, Identifiable {
    case design, step, stl
    var id: String { rawValue }
    var ext: String { switch self { case .design: "sc"; case .step: "step"; case .stl: "stl" } }
}

/// Writes the file to the app's documents, then hands it to the share sheet.
struct ExportSheet: View {
    let model: DesignModel
    let kind: ExportKind
    @State private var url: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            if let url {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text(url.lastPathComponent).font(.headline)
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .padding(30)
        .presentationDetents([.height(220)])
        .task {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let base = model.snapshot.name.replacingOccurrences(of: "/", with: "-")
            let target = dir.appendingPathComponent("\(base).\(kind.ext)")
            if kind == .design { model.save(to: target) } else { model.export(to: target) }
            if FileManager.default.fileExists(atPath: target.path) { url = target } else { error = model.message ?? "Export failed" }
        }
    }
}
#endif
