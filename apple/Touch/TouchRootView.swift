#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The touch front end (iPad and iPhone), one shell for the eight stages of the pipeline. The
/// stage's view fills the screen (the 3D design, the study, the board, the flight); over it a
/// top capsule carries the title and revision, undo and redo, the pipeline strip with its
/// status dots, Items | History, the view cube, the jobs and share; on the left the two tool
/// groups, on the right the 320 point inspector card, under the selection the context pill, at
/// the bottom the summary capsule (or the transport bar in Simulate and Train). The browser,
/// export and the command palette open as sheets. Finger orbits, two fingers pan, pinch zooms,
/// a two-finger tap undoes, Pencil selects and sketches.
struct TouchRootView: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--landscape-render") {
            // Screenshots on a simulator nobody can turn: the shell laid out landscape and
            // drawn turned a quarter, the PNG is turned back afterwards. Debug only.
            GeometryReader { geo in
                TouchShell().viaFormTheme()
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(-90))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .ignoresSafeArea()
            .statusBarHidden()
        } else {
            TouchShell().viaFormTheme()
        }
    }
}

struct TouchShell: View {
    @Environment(\.viaFormTheme) private var theme
    @State private var model = DesignModel()
    @State private var pcb = PCBModel(sample: ProcessInfo.processInfo.arguments.contains("--sample"))
    @State private var sim = SimModel()
    @State private var generate = GenerateModel()
    @State private var stage: Workspace = TouchShell.launchStage
    @State private var side: TouchSideCard? = TouchShell.launchSide
    @State private var library = LibraryModel()
    @State private var showLibrary = ProcessInfo.processInfo.arguments.contains("--library")
    @State private var bom = BomModel()
    @State private var showBom = BomModel.launchRequested
    @State private var showBrowser = ProcessInfo.processInfo.arguments.contains("--browser")
    /// Folded: the flight view keeps its own readout in the corner, so the panel opens on demand.
    @State private var telemetryOpen = false
    @State private var showPalette = ProcessInfo.processInfo.arguments.contains("--palette")
    @State private var showCommands = false
    @State private var importing = false
    @State private var exporting: ExportKind?
    @State private var perspective = false
    @State private var sectionOn = false
    @State private var isolated: [String] = []
    /// The product pipeline, shared with the Mac window's (see `FlowModel`).
    @State private var flow = FlowModel()
    @Environment(\.horizontalSizeClass) private var hSize

    private var compact: Bool { hSize == .compact }

    /// `--design` ... `--make` or `--stage=<id>`; the older `--electronics`, `--board`,
    /// `--simulation` and `--generate` keep working through the same names.
    static var launchStage: Workspace {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--board") { return .electronics }
        return Workspace.fromLaunchArguments(args) ?? .design
    }

    static var launchSide: TouchSideCard? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--touch-items") { return .items }
        if args.contains("--touch-history") { return .history }
        return nil
    }

    /// The stages drawn over the 3D design.
    private var onDesign: Bool { [.design, .assemble, .render, .make].contains(stage) }

    var body: some View {
        stageView
            .safeAreaInset(edge: .top, spacing: 0) { topCapsule }
            .background(TwoFingerTapUndo { undo() }.allowsHitTesting(false))
            .background(TouchKeyCommands(stage: stage, open: open, palette: { showPalette = true }, undo: undo, redo: redo))
            .animation(.snappy(duration: VFMotion.standard), value: side)
            .animation(.snappy(duration: VFMotion.fast), value: model.tool)
            .pencilDoubleTapTogglesTool(model)
            .onChange(of: stage) { _, _ in pcb.syncLink(model) }
            .reportsToFlow(flow, design: model, pcb: pcb, generate: generate, sim: sim)
            .projectFilesContext(design: model, pcb: pcb, bom: bom, flow: flow)
            .sheet(isPresented: $showBrowser) {
                TouchBrowserSheet(flow: flow, model: model, stage: stage, open: open, importFile: { importing = true },
                                  export: { exporting = $0 }, loadHand: loadHand, showBom: { showBom = true }, showLibrary: { showLibrary = true })
                    .viaFormTheme()
                    .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .top) {
                if showPalette {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.18).ignoresSafeArea()
                            .onTapGesture { showPalette = false }
                            .accessibilityLabel("Close commands")
                            .accessibilityAddTraits(.isButton)
                        TouchCommandPalette(flow: flow, stage: stage, run: run, canRun: canRun) { showPalette = false }
                            .padding(.horizontal, 16)
                            .padding(.top, 64)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: VFMotion.fast), value: showPalette)
            .sheet(isPresented: $showCommands) { CommandBrowser(model: model) }
            .sheet(isPresented: $showLibrary) {
                LibraryView(model: library, design: model, pcb: pcb) { showLibrary = false }.presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showBom) {
                BomPanel(model: bom, design: model, pcb: pcb) { showBom = false }
                    .onAppear { if BomModel.launchRequested, bom.rows.isEmpty { bom.applyLaunchFlags() } }
            }
            // On iPhone the Items and History cards come up as sheets.
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
                    // A .viaform brings its board, BOM and pipeline too.
                    ProjectFiles.open(url, design: model, in: ProjectFiles.current)
                    if ok { url.stopAccessingSecurityScopedResource() }
                }
            }
            .sheet(item: $exporting) { kind in ExportSheet(model: model, kind: kind, pcb: pcb) }
            .onChange(of: perspective) { _, p in
                model.camera.fov = p ? 0.7 : 0
                model.cameraChanged()
            }
            .onAppear(perform: applyLaunchFlags)
    }

    // MARK: - Stages

    @ViewBuilder private var stageView: some View {
        switch stage {
        case .generate:
            GenerateView(model: generate, design: model, theme: theme.viewportTheme, compact: true)
        case .electronics:
            TouchPCBView(model: pcb, design: model, showProject: $showBrowser) { open(.design) }
        case .simulation where flow.isHandProduct:
            // The hand flies nothing: its Simulation stage is the grasp test.
            HandGraspView(generate: generate, design: model, theme: theme.viewportTheme, compact: true)
        case .simulation:
            // The flight view, with the stage shell's scenario card and telemetry over it.
            ZStack {
                SimulationView(model: sim, compact: true)
                if !compact {
                    VStack(spacing: 10) {
                        // Leading side: the flight view keeps its own readout at the top trailing corner.
                        HStack {
                            TouchScenarioCard(flow: flow, sim: sim, open: open) {
                                if let c = flow.commands(stage: "simulate").first(where: { $0.id == "simulate.rerun" }) { run(c) }
                                else { sim.reset(); sim.play() }
                            }
                            Spacer()
                        }
                        Spacer()
                        TouchTelemetryPanel(sim: sim, expanded: $telemetryOpen)
                            .frame(maxWidth: 760)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 64)
                    .padding(.bottom, 84)
                }
            }
        case .train:
            ZStack(alignment: .bottomTrailing) {
                SimulationView(model: sim, compact: true)
                if !compact {
                    TouchTrainInspector(sim: sim, flow: flow, open: open)
                        .padding(.trailing, 12).padding(.bottom, 84)
                }
            }
        case .design, .assemble, .render, .make:
            if compact { compactDesign } else { designStage }
        }
    }

    /// Design, Assemble, Render and Make over the 3D view.
    private var designStage: some View {
        ZStack {
            Viewport(model: model, theme: theme.viewportTheme).ignoresSafeArea()
            if stage == .design || stage == .assemble {
                DesignAnchorLayer(model: model, stage: stage, extra: crossStageVerbs)
            }
            // The tool groups ride the leading edge at mid height, where a thumb rests on a
            // held iPad (they sat in the top corner, a reach across the glass).
            HStack(spacing: 0) {
                tools
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.bottom, 40)
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Spacer(minLength: 0)
                    rightCard
                }
                Spacer(minLength: 0)
                PCBLinkBanner(design: model, pcb: pcb)
                MessageBanner(model: model)
                if model.tool == .sketch { PlaneChooser(model: model) }
                if stage == .design, !model.snapshot.timeline.isEmpty, model.selection.isEmpty, model.selectedBodies.isEmpty {
                    // Hidden while the context pill shows: one bar near the thumbs, not three.
                    HistoryBar(model: model)
                }
                SummaryCapsule(items: summary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var tools: some View {
        switch stage {
        case .design:
            DesignToolGroups(model: model, showCommands: $showPalette)
        case .assemble, .render:
            CatalogToolGroups(ribbon: StageScreen.ribbon(flow.commands(stage: stage.stage), perGroup: 8), groups: stage == .render ? 1 : 2, run: run)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var rightCard: some View {
        Group {
            if side == .items {
                ItemsPanel(model: model)
            } else if side == .history {
                HistorySidebar(model: model)
            } else {
                switch stage {
                case .assemble: TouchAssembleInspector(model: model, pcb: pcb, flow: flow, open: open)
                case .render: TouchRenderInspector(model: model, flow: flow, open: open)
                case .make: TouchMakeInspector(flow: flow, open: open, export: { exporting = $0 }, showBom: { showBom = true })
                default: TouchDesignInspector(model: model, flow: flow, stage: stage, open: open)
                }
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// iPhone: the earlier one-column layout, tools in a bottom strip.
    private var compactDesign: some View {
        ZStack {
            Viewport(model: model, theme: theme.viewportTheme).ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    Spacer()
                    ViewCube(model: model, size: 70, faceColor: .white, edgeColor: Color(white: 0.6), textColor: Color(white: 0.3))
                }
                Spacer(minLength: 0)
                PCBLinkBanner(design: model, pcb: pcb)
                MessageBanner(model: model)
                if model.tool == .sketch { PlaneChooser(model: model) }
                if model.tool != .select, model.tool != .sketch { ToolCard(model: model) }
                else if !model.suggestions.isEmpty { SuggestionBar(model: model) }
                ToolRail(model: model, compact: true, showCommands: $showCommands)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// The verbs that cross to another stage, offered with the selection.
    private var crossStageVerbs: [ContextAction] {
        guard !model.bodiesInSelection.isEmpty else { return [] }
        return [
            ContextAction(id: "stress", title: "Stress Here", symbol: "scope") { open(.generate) },
            ContextAction(id: "fly", title: "Fly It", symbol: "wind") { open(.simulation) },
        ]
    }

    private var summary: [(symbol: String, text: String)] {
        var out: [(String, String)] = [
            ("cube", "\(model.snapshot.bodies.count) bodies"),
            ("square.stack.3d.up", "\(model.assembly.count) components"),
        ]
        if flow.designJoints > 0 {
            out.append(("link", "\(flow.designJoints) joint\(flow.designJoints == 1 ? "" : "s")"))
            if flow.designMotors > 0 { out.append(("gearshape", "\(flow.designMotors) motor\(flow.designMotors == 1 ? "" : "s")")) }
        } else {
            out.append(("clock.arrow.circlepath", "\(model.snapshot.timeline.count) steps"))
        }
        if let rev = flow.revisionName(of: stage.stage) { out.append(("tag", rev)) }
        return out
    }

    // MARK: - Top capsule

    private var topCapsule: some View {
        HStack(alignment: .center, spacing: 8) {
            TouchTopCapsule(
                flow: flow, stage: stage, title: title,
                canUndo: stage == .electronics ? pcb.undoCount > 0 : model.snapshot.undo > 0,
                canRedo: stage == .electronics ? pcb.redoCount > 0 : model.snapshot.redo > 0,
                compact: compact, side: $side, showsSideSwitch: onDesign,
                open: open, undo: undo, redo: redo,
                showBrowser: { showBrowser = true }, showPalette: { showPalette = true },
                share: AnyView(TouchShareMenu(export: { exporting = $0 }, showBom: { showBom = true }, showLibrary: { showLibrary = true }))
            )
            if onDesign, !compact { viewCluster }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .disabled(EngineGate.shared.shut)
    }

    private var title: String {
        ProjectTitle.of(flow: flow, design: model)
    }

    /// The view cube and the view menu (perspective, fit, standard views, section, isolate).
    private var viewCluster: some View {
        HStack(spacing: 2) {
            ViewCube(model: model, size: 52, faceColor: theme.isDark ? Color(white: 0.85) : .white, edgeColor: Color(white: 0.6), textColor: Color(white: 0.3))
                .frame(width: 56, height: 56)
            Menu {
                Toggle("Perspective", isOn: $perspective)
                Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.zoomToFit() }
                Section("Views") {
                    ForEach(StandardView.allCases, id: \.self) { v in Button(v.rawValue.capitalized) { model.setView(v) } }
                }
                Toggle("Section View", isOn: Binding(get: { sectionOn }, set: { _ in toggleSection() }))
                Toggle("Isolate Selection", isOn: Binding(get: { !isolated.isEmpty }, set: { _ in toggleIsolate() }))
            } label: {
                Image(systemName: "eye").font(.system(size: 17, weight: .medium)).foregroundStyle(theme.ink)
                    .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("View")
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 56)
        .vfSurface(.floating, radius: 28)
    }

    // MARK: - Actions

    private func open(_ w: Workspace) {
        if stage == w { return }
        if ![.design, .assemble, .render, .make].contains(w) { side = nil }
        stage = w
    }

    private func undo() {
        switch stage {
        case .electronics: pcb.undo()
        case .design, .assemble, .render, .make: model.undo()
        default: break
        }
    }

    private func redo() {
        switch stage {
        case .electronics: pcb.redo()
        case .design, .assemble, .render, .make: model.redo()
        default: break
        }
    }

    private func loadHand() {
        TouchSampleHand.build(into: model)
        flow.newDocument(product: "Humanoid Hand", graph: "hand")
    }

    /// Runs a command of the catalog (palette, catalog tool groups) by where it comes from.
    private func run(_ c: FlowModel.Command) {
        if c.id.hasPrefix("stage."), let w = Workspace(stage: String(c.id.dropFirst(6))) { open(w); return }
        switch c.source {
        case "design":
            if !onDesign { open(Workspace(stage: c.stage) ?? .design) }
            if let t = Tool.allCases.first(where: { $0.commandID == c.id && ![.union, .subtract, .intersect].contains($0) }) {
                model.tool = t
            } else if let info = model.commands.first(where: { $0.id == c.id }) {
                model.genericCommand = info
            }
        case "pcb":
            open(.electronics)
        default:
            verb(c.id)
        }
    }

    /// Whether a verb can run now: the same rules as the Mac's ribbon and palette.
    private func canRun(_ id: String) -> Bool {
        switch id {
        case "generate.run": !generate.running
        case "generate.cancel": generate.running
        case "generate.use_as_frame": generate.candidate != nil && !generate.building
        case "train.start": !sim.training.running
        case "train.stop": sim.training.running
        case "train.fly_policy": sim.training.brainJSON != nil
        case _ where id.hasPrefix("simulate.") && flow.isHandProduct: false
        default: true
        }
    }

    /// The pipeline's own verbs.
    private func verb(_ id: String) {
        switch id {
        case "generate.run": open(.generate); generate.run()
        case "generate.use_as_frame": generate.build(into: model)
        case "generate.stress_here": open(.generate)
        case "generate.cancel": generate.cancel()
        case "simulate.fly": open(.simulation); sim.play()
        case "simulate.rerun": open(.simulation); sim.reset(); sim.play()
        case "simulate.race": open(.simulation); sim.options.mission = "manual"
        case "simulate.stress": open(.simulation); sim.options.mission = "stress"
        case "simulate.wind", "simulate.record": open(.simulation)
        case "train.start": open(.train); sim.training.start()
        case "train.stop": sim.training.cancel()
        case "train.fly_policy":
            if let b = sim.training.brainJSON { sim.flyTrained(b) }
            open(.simulation)
        case "render.shots": open(.render); model.run("render.start")
        case "make.export": exporting = .step
        case "make.bom": showBom = true
        case "make.kicad", "electronics.drc": open(.electronics)
        case "electronics.send_to_3d": pcb.sendTo3D(model)
        case "library.open": showLibrary = true
        case "flow.update":
            if let s = flow.stages.first(where: { $0.status == .stale }), let w = Workspace(stage: s.id) { open(w) }
        case "flow.show": showBrowser = true
        default: break
        }
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

    /// Screenshot and test flags: `--hand` builds the sample hand, `--select=<body>` selects a
    /// body, `--tool=<tool>` arms a tool.
    private func applyLaunchFlags() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--board") { pcb.sheet = .board }
        if args.contains("--hand") {
            loadHand()
            if GenerateProject.launchSample == nil, generate.project?.name != "hand" { generate.openSample("hand") }
        }
        if args.contains("--drone") {
            // The same 3 inch racer as the Mac's --drone: the sample board on its frame.
            if pcb.project?.components.isEmpty ?? true { pcb.loadSample() }
            TouchSampleDrone.build(into: model, pcb: pcb)
            flow.newDocument(product: "Racer 3in")
            if GenerateProject.launchSample == nil, generate.project?.name != "drone" { generate.openSample("drone") }
        }
        if let s = args.first(where: { $0.hasPrefix("--select=") }) {
            model.selectedBodies = [String(s.dropFirst("--select=".count))]
        }
        if let s = args.first(where: { $0.hasPrefix("--tool=") }), let t = Tool(rawValue: String(s.dropFirst("--tool=".count))) {
            model.tool = t
        }
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
                    ForEach(Tool.sketchTools) { t in rail(t, active: model.tool == t) { activate(t) }.frame(width: 44) }
                    rail("checkmark", "Done") { model.finishSketch() }.frame(width: 44)
                } else {
                    ForEach(Tool.solidTools + Tool.primitiveTools) { t in rail(t, active: model.tool == t) { activate(t) }.frame(width: 44) }
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
            rail(t, active: model.tool == t) { activate(t) }
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

    private func rail(_ tool: Tool, active: Bool = false, action: @escaping () -> Void) -> some View {
        rail(tool.symbol, tool.touchLabel, art: ToolIcons.art(for: tool), active: active, action: action)
    }

    private func rail(_ symbol: String, _ label: String, art: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                CommandIcon(art: art, symbol: symbol, size: compact ? 17 : 19).frame(height: 28)
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
            Label(model.tool.touchLabel, systemImage: model.tool.symbol).font(.headline).labelStyle(.titleAndIcon)
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
                    Label { Text(t.touchLabel) } icon: { CommandIcon(tool: t, size: 15) }.font(.callout.weight(.medium)).padding(.horizontal, 10).frame(height: 36)
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
                    Section(tab.isEmpty ? "Other" : StageLabels.tab(tab).capitalized) {
                        ForEach(cmds) { c in
                            Button {
                                dismiss()
                                if let t = Tool.allCases.first(where: { $0.commandID == c.id && $0 != .union && $0 != .subtract && $0 != .intersect }) {
                                    model.tool = t
                                } else {
                                    model.genericCommand = c
                                }
                            } label: {
                                Label { VStack(alignment: .leading) { Text(StageLabels.command(c.label)); Text(c.id).font(.caption2.monospaced()).foregroundStyle(.secondary) } }
                                    icon: { CommandIcon(icon: c.icon, id: c.id, size: 16) }
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
        return Dictionary(grouping: list, by: \.tab).sorted { StageLabels.tab($0.key) < StageLabels.tab($1.key) }
    }
}

enum ExportKind: String, Identifiable {
    case design, step, stl, kicad
    var id: String { rawValue }
    var ext: String { switch self { case .design: "sc"; case .step: "step"; case .stl: "stl"; case .kicad: "kicad_pcb" } }
}

/// Writes the file to the app's documents, then hands it to the share sheet.
struct ExportSheet: View {
    let model: DesignModel
    let kind: ExportKind
    var pcb: PCBModel?
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
            let name = kind == .kicad ? (pcb?.project?.name ?? "board") : model.snapshot.name
            let base = name.replacingOccurrences(of: "/", with: "-")
            let target = dir.appendingPathComponent("\(base).\(kind.ext)")
            switch kind {
            case .design: model.save(to: target)
            case .kicad: pcb?.exportKiCad(to: target)
            default: model.export(to: target)
            }
            if FileManager.default.fileExists(atPath: target.path) { url = target } else { error = (kind == .kicad ? pcb?.message : model.message) ?? "Export failed" }
        }
    }
}

#endif
