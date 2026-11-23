#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The touch front end (iPad and iPhone), one shell for the nine stages of the pipeline. The
/// stage's view fills the screen (the 3D design, the study, the board, the flight); over it a
/// top capsule carries the title and revision, undo and redo, the workspace dropdown,
/// Items | History, the view cube, the jobs and share; on the left the two tool groups, on the
/// right the 320 point inspector card, under the selection the context pill, at the bottom the
/// summary capsule (or the transport bar in Simulate and Train). The browser, export and the
/// command palette open as sheets. Finger orbits, two fingers pan, pinch zooms, a two-finger tap
/// on the 3D view undoes, Pencil selects and sketches. Each window owns its models, so two iPad
/// windows never share a document.
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
    @State private var showShortcuts = false
    @State private var importing = false
    @State private var exporting: ExportKind?
    @State private var perspective = false
    @State private var sectionOn = false
    @State private var isolated: [String] = []
    /// The stage's inspector card (Option-Command-I hides it).
    @State private var inspectorShown = true
    /// The product pipeline, shared with the Mac window's (see `FlowModel`).
    @State private var flow = FlowModel()
    /// The workspace dropdown (popover on iPad, sheet on iPhone).
    @State private var showWorkspaces = ProcessInfo.processInfo.arguments.contains("--show-workspaces")
    @State private var toasts = ToastCenter()
    @State private var confirm: ConfirmRequest?
    /// Bumped on every undo or redo, for the haptic.
    @State private var undoTick = 0
    @State private var width: CGFloat = 1024
    @State private var restored = false
    @Environment(\.horizontalSizeClass) private var hSize

    // Kept per scene: a restored or second window comes back where it was (P2-9).
    @SceneStorage("viaform.touch.stage") private var storedStage = ""
    @SceneStorage("viaform.touch.side") private var storedSide = ""
    @SceneStorage("viaform.touch.perspective") private var storedPerspective = false
    @SceneStorage("viaform.touch.inspector") private var storedInspector = true
    @SceneStorage("viaform.touch.telemetry") private var storedTelemetry = false

    /// The phone layout: an iPhone, or an iPad window narrower than about 820 points (Split View,
    /// Stage Manager, Slide Over).
    private var compact: Bool { hSize == .compact || width < 820 }

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
            .background(TwoFingerTapUndo { undo(gesture: true) }.allowsHitTesting(false))
            .background(TouchKeyCommands(focus: focus))
            .focusedSceneValue(\.vfTouch, focus)
            .vfAnimation(.snappy(duration: VFMotion.standard), value: side)
            .vfAnimation(.snappy(duration: VFMotion.standard), value: inspectorShown)
            .vfAnimation(.snappy(duration: VFMotion.fast), value: model.tool)
            .sensoryFeedback(.impact(weight: .light), trigger: undoTick)
            .sensoryFeedback(.selection, trigger: model.tool)
            .pencilDoubleTapTogglesTool(model)
            .onChange(of: stage) { _, s in pcb.syncLink(model); storedStage = s.rawValue }
            .onChange(of: side) { _, s in storedSide = s?.rawValue ?? "" }
            .onChange(of: inspectorShown) { _, v in storedInspector = v }
            .onChange(of: telemetryOpen) { _, v in storedTelemetry = v }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .reportsToFlow(flow, design: model, pcb: pcb, generate: generate, sim: sim)
            .projectFilesContext(design: model, pcb: pcb, bom: bom, flow: flow, generate: generate)
            .overlay(alignment: .bottom) {
                StageIntro(workspace: stage)
                    .padding(.horizontal, VFSpace.l)
                    .padding(.bottom, compact ? 140 : 120)
            }
            .sheet(isPresented: $showBrowser) {
                TouchBrowserSheet(flow: flow, model: model, stage: stage, open: open, importFile: { importing = true },
                                  export: { exporting = $0 }, loadHand: loadHand, showBom: { showBom = true }, showLibrary: { showLibrary = true })
                    .viaFormTheme()
                    .presentationDetents([.medium, .large])
            }
            .overlay(alignment: .top) {
                if showPalette {
                    ZStack(alignment: .top) {
                        theme.chromeDeep.opacity(0.35).ignoresSafeArea()
                            .onTapGesture { showPalette = false }
                            .accessibilityLabel(Text("Close commands"))
                            .accessibilityAddTraits(.isButton)
                        TouchCommandPalette(flow: flow, stage: stage, run: run, canRun: canRun) { showPalette = false }
                            .padding(.horizontal, VFSpace.xl)
                            .padding(.top, 64)
                    }
                    .vfTransition(.opacity)
                }
            }
            .vfAnimation(.snappy(duration: VFMotion.fast), value: showPalette)
            .sheet(isPresented: $showCommands) { CommandBrowser(model: model).viaFormTheme() }
            .sheet(isPresented: $showShortcuts) { TouchShortcutsSheet().viaFormTheme().presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showLibrary) {
                LibraryView(model: library, design: model, pcb: pcb) { showLibrary = false }.presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showBom) {
                BomPanel(model: bom, design: model, pcb: pcb) { showBom = false }
                    .onAppear { if BomModel.launchRequested, bom.rows.isEmpty { bom.applyLaunchFlags() } }
            }
            // On iPhone (and a narrow iPad window) the Items and History cards come up as sheets.
            .sheet(isPresented: Binding(get: { compact && side != nil }, set: { if !$0 { side = nil } })) {
                Group {
                    if side == .history { HistorySidebar(model: model, floating: false) } else { ItemsPanel(model: model, floating: false) }
                }
                .environment(\.vfToasts, toasts)
                .viaFormTheme()
                .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { model.genericCommand }, set: { model.genericCommand = $0 })) { c in
                GenericCommandForm(model: model, command: c).viaFormTheme().presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { r in
                if case let .success(urls) = r, let url = urls.first { openFile(url) }
            }
            .sheet(item: $exporting) { kind in ExportFlow(model: model, kind: kind, pcb: pcb).viaFormTheme() }
            .confirmSheet($confirm)
            .onChange(of: perspective) { _, p in
                storedPerspective = p
                model.camera.fov = p ? 0.7 : 0
                model.cameraChanged()
            }
            .onAppear {
                restoreScene()
                applyLaunchFlags()
            }
            .toastHost(toasts)
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
                    VStack(spacing: VFSpace.m) {
                        // Leading side: the flight view keeps its own readout at the top trailing corner.
                        HStack {
                            if inspectorShown {
                                TouchScenarioCard(flow: flow, sim: sim, open: open) {
                                    if let c = flow.commands(stage: "simulate").first(where: { $0.id == "simulate.rerun" }) { run(c) }
                                    else { sim.reset(); sim.play() }
                                }
                            }
                            Spacer()
                        }
                        Spacer()
                        TouchTelemetryPanel(sim: sim, expanded: $telemetryOpen)
                            .frame(maxWidth: 760)
                    }
                    .padding(.horizontal, VFSpace.l)
                    .padding(.top, 64)
                    .padding(.bottom, 84)
                }
            }
        case .train:
            ZStack(alignment: .bottomTrailing) {
                SimulationView(model: sim, compact: true)
                if !compact, inspectorShown {
                    TouchTrainInspector(sim: sim, flow: flow, open: open)
                        .padding(.trailing, VFSpace.l).padding(.bottom, 84)
                }
            }
        case .robot:
            TouchRobotStage(flow: flow)
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
            .padding(.leading, VFSpace.l)
            .padding(.bottom, 40)
            VStack(spacing: VFSpace.m) {
                HStack(alignment: .top, spacing: VFSpace.m) {
                    Spacer(minLength: 0)
                    if inspectorShown || side != nil { rightCard }
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
            .padding(.horizontal, VFSpace.l)
            .padding(.top, VFSpace.m)
            .padding(.bottom, VFSpace.m)
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
        .vfTransition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// iPhone and narrow windows: one column, tools in a bottom strip.
    private var compactDesign: some View {
        ZStack {
            Viewport(model: model, theme: theme.viewportTheme).ignoresSafeArea()
            VStack(spacing: VFSpace.m) {
                HStack {
                    Spacer()
                    ViewCube(model: model, size: 70)
                }
                Spacer(minLength: 0)
                PCBLinkBanner(design: model, pcb: pcb)
                MessageBanner(model: model)
                if model.tool == .sketch { PlaneChooser(model: model) }
                if model.tool != .select, model.tool != .sketch { ToolSession(model: model, layout: .bar) }
                else if !model.suggestions.isEmpty { SuggestionBar(model: model) }
                ToolRail(model: model, compact: true, showCommands: $showCommands)
            }
            .padding(.horizontal, VFSpace.l)
            .padding(.vertical, VFSpace.m)
        }
    }

    /// The verbs that cross to another stage, offered with the selection.
    private var crossStageVerbs: [ContextAction] {
        guard !model.bodiesInSelection.isEmpty else { return [] }
        return [
            ContextAction(id: "stress", title: String(localized: "Stress Here"), symbol: "scope") { open(.generate) },
            ContextAction(id: "fly", title: String(localized: "Fly It"), symbol: "wind") { open(.simulation) },
        ]
    }

    private static func plain(_ s: AttributedString) -> String { String(s.characters) }

    private var summary: [(symbol: String, text: String)] {
        let bodies = model.snapshot.bodies.count, components = model.assembly.count
        var out: [(String, String)] = [
            ("cube", Self.plain(AttributedString(localized: "^[\(bodies) body](inflect: true)"))),
            ("square.stack.3d.up", Self.plain(AttributedString(localized: "^[\(components) component](inflect: true)"))),
        ]
        if flow.designJoints > 0 {
            let joints = flow.designJoints, motors = flow.designMotors
            out.append(("link", Self.plain(AttributedString(localized: "^[\(joints) joint](inflect: true)"))))
            if motors > 0 { out.append(("gearshape", Self.plain(AttributedString(localized: "^[\(motors) motor](inflect: true)")))) }
        } else {
            let steps = model.snapshot.timeline.count
            out.append(("clock.arrow.circlepath", Self.plain(AttributedString(localized: "^[\(steps) step](inflect: true)"))))
        }
        if let rev = flow.revisionName(of: stage.stage) { out.append(("tag", rev)) }
        return out
    }

    // MARK: - Top capsule

    private var topCapsule: some View {
        HStack(alignment: .center, spacing: VFSpace.m) {
            TouchTopCapsule(
                flow: flow, stage: stage, title: title,
                undoTarget: undoTarget,
                compact: compact, side: $side, showsSideSwitch: onDesign,
                open: open, undo: { undo() }, redo: redo,
                showBrowser: { showBrowser = true }, showPalette: { showPalette = true },
                share: AnyView(TouchShareMenu(export: { exporting = $0 }, showBom: { showBom = true }, showLibrary: { showLibrary = true })),
                workspacesOpen: $showWorkspaces
            )
            if onDesign, !compact { viewCluster }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.top, VFSpace.xs)
        .vfEngineGate()
    }

    private var title: String {
        ProjectTitle.of(flow: flow, design: model)
    }

    /// The view cube and the view menu (perspective, fit, standard views, section, isolate).
    private var viewCluster: some View {
        HStack(spacing: VFSpace.xxs) {
            ViewCube(model: model, size: 52)
                .frame(width: 56, height: 56)
            Menu {
                Button("Home View", systemImage: "house") { model.setView(.iso) }
                Toggle("Perspective", isOn: $perspective)
                Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.zoomToFit() }
                Section("Views") {
                    ForEach(StandardView.allCases, id: \.self) { v in
                        Button(v == .iso ? String(localized: "Isometric") : v.rawValue.capitalized) { model.setView(v) }
                    }
                }
                Toggle("Section View", isOn: Binding(get: { sectionOn }, set: { _ in toggleSection() }))
                Toggle("Isolate Selection", isOn: Binding(get: { !isolated.isEmpty }, set: { _ in toggleIsolate() }))
            } label: {
                Image(systemName: "eye").font(VFFont.glyph(17, weight: .medium)).foregroundStyle(theme.ink)
                    .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                    .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("View options"))
        }
        .padding(.horizontal, VFSpace.s)
        .frame(minHeight: 56)
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }

    // MARK: - Keyboard focus

    /// A sheet, cover, popover or the palette is up over the shell.
    private var presenting: Bool {
        showBrowser || showLibrary || showBom || showCommands || showShortcuts || exporting != nil
            || model.genericCommand != nil || (compact && side != nil) || showWorkspaces || confirm != nil
    }

    private var focus: TouchFocus {
        TouchFocus(
            stage: stage, open: open,
            workspaces: { showWorkspaces.toggle() },
            palette: { showPalette = true },
            shortcuts: { showShortcuts = true },
            undo: undoTarget,
            performUndo: { undo() }, performRedo: { redo() },
            primary: primary,
            stopJob: flow.queue.isEmpty ? nil : { _ = flow.stopJob(stage: stage.stage) },
            updateStale: flow.stages.contains(where: { $0.status == .stale }) ? { verb("flow.update") } : nil,
            toggleInspector: { inspectorShown.toggle() },
            showBom: { showBom = true },
            showLibrary: { showLibrary = true },
            escape: escapeAction
        )
    }

    /// Escape: palette, then the armed tool, then the selection. Never in Robot (Escape twice is
    /// the e-stop there), never while a job runs or a sheet is up.
    private var escapeAction: (() -> Void)? {
        guard stage != .robot, flow.queue.isEmpty, !presenting else { return nil }
        return {
            if showPalette { showPalette = false; return }
            if TouchResponder.isEditingText { TouchResponder.endEditing(); return }
            if stage == .electronics { pcb.tool = .select; return }
            if model.tool != .select { model.cancelTool(); return }
            model.selection = []
            model.selectedBodies = []
        }
    }

    /// Command-Return: the armed tool's Done, else the stage's main action.
    private var primary: (title: String, run: () -> Void)? {
        if onDesign, model.tool != .select, model.tool != .sketch {
            return (String(localized: "Finish \(model.tool.touchLabel)"), { ToolSession.finish(model) })
        }
        if onDesign, model.sketchOpen { return (String(localized: "Finish Sketch"), { model.finishSketch() }) }
        switch stage {
        case .generate: return generate.running ? nil : (String(localized: "Run Study"), { verb("generate.run") })
        case .simulation: return flow.isHandProduct ? nil : (String(localized: "Fly"), { verb("simulate.fly") })
        case .train: return sim.training.running ? nil : (String(localized: "Start Training"), { verb("train.start") })
        case .render: return (String(localized: "Render Shot"), { _ = model.run("render.start") })
        case .make: return (String(localized: "Export STEP"), { exporting = .step })
        default: return nil
        }
    }

    // MARK: - Undo

    /// What Command-Z, the capsule buttons and the two-finger tap undo in the open stage (P0-1):
    /// the design behind the 3D stages, the board in Electronics, the study in Generate. Other
    /// stages have no stack, so the buttons grey out instead of undoing an unseen design edit.
    private var undoTarget: TouchUndoTarget {
        switch stage {
        case .design, .assemble, .render, .make:
            TouchUndoTarget(canUndo: model.snapshot.undo > 0, canRedo: model.snapshot.redo > 0,
                            undoName: model.engine.undoNames(undo: model.snapshot.undo, redo: model.snapshot.redo).undo,
                            undo: { model.undo() }, redo: { model.redo() })
        case .electronics:
            TouchUndoTarget(canUndo: pcb.undoCount > 0, canRedo: pcb.redoCount > 0,
                            undoName: pcb.engine.undoNames(undo: pcb.undoCount, redo: pcb.redoCount).undo,
                            undo: { pcb.undo() }, redo: { pcb.redo() })
        case .generate:
            TouchUndoTarget(canUndo: generate.canUndo, canRedo: generate.canRedo, undoName: generate.undoName,
                            undo: { generate.undo() }, redo: { generate.redo() })
        default:
            .none
        }
    }

    /// Undo in the open stage. A text field that is editing keeps its own undo (the keyboard
    /// path); the two-finger tap confirms with a toast, since nothing else shows it happened.
    private func undo(gesture: Bool = false) {
        if !gesture, TouchResponder.isEditingText { TouchResponder.textUndo(redo: false); return }
        let t = undoTarget
        guard t.canUndo, !EngineGate.shared.shut else { return }
        let name = t.undoName
        t.undo()
        undoTick += 1
        if gesture {
            toasts.show(name.map { String(localized: "Undone: \($0)") } ?? String(localized: "Undone"),
                        systemImage: "arrow.uturn.backward", actionTitle: String(localized: "Redo")) { redo() }
        }
    }

    private func redo() {
        if TouchResponder.isEditingText { TouchResponder.textUndo(redo: true); return }
        let t = undoTarget
        guard t.canRedo, !EngineGate.shared.shut else { return }
        t.redo()
        undoTick += 1
    }

    // MARK: - Actions

    private func open(_ w: Workspace) {
        if stage == w { return }
        if ![.design, .assemble, .render, .make].contains(w) { side = nil }
        stage = w
    }

    private func loadHand() {
        TouchSampleHand.build(into: model)
        flow.newDocument(product: "Humanoid Hand", graph: "hand")
    }

    /// Opens or imports a picked file. Opening a project or a design replaces the open one, so
    /// unsaved changes are confirmed first.
    private func openFile(_ url: URL) {
        let perform = {
            let ok = url.startAccessingSecurityScopedResource()
            // A .viaform brings its board, BOM and pipeline too.
            ProjectFiles.open(url, design: model, in: ProjectFiles.context(for: model))
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        let replaces = ProjectFiles.isProject(url) || !ProjectFiles.knownInserts.contains(url.pathExtension.lowercased())
        if replaces, let c = ProjectFiles.context(for: model), ProjectFiles.isEdited(c) {
            confirm = ConfirmRequest(title: String(localized: "Discard changes to \(title)?"),
                                     message: String(localized: "Opening \(url.lastPathComponent) replaces the open design. The changes since the last save are lost."),
                                     verb: String(localized: "Discard and Open"), destructive: true, perform: perform)
        } else {
            perform()
        }
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
        case "generate.cancel": stage = .generate; generate.requestStop()
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
        guard !keep.isEmpty else { model.flash(String(localized: "Select a body to isolate.")); return }
        isolated = model.snapshot.bodies.map(\.name).filter { !keep.contains($0) }
        for b in isolated { model.toggleBodyVisibility(b, visible: false) }
    }

    /// The scene's last stage, card, perspective and panels, unless a launch flag asks otherwise.
    private func restoreScene() {
        guard !restored else { return }
        restored = true
        let args = ProcessInfo.processInfo.arguments
        if Workspace.fromLaunchArguments(args) == nil, !args.contains("--board"), let w = Workspace(rawValue: storedStage) { stage = w }
        if TouchShell.launchSide == nil { side = TouchSideCard(rawValue: storedSide) }
        perspective = storedPerspective
        inspectorShown = storedInspector
        telemetryOpen = storedTelemetry
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

// MARK: - Timeline

/// The actions of one timeline step, shared by the context menus and the visible menus of the
/// history list and the history bar (P1-28). Delete offers Undo in a toast (P0-10).
struct TimelineStepActions: View {
    let model: DesignModel
    let index: Int
    let feature: DesignSnapshot.Feature
    let toasts: ToastCenter?

    var body: some View {
        Button("Roll Back Here", systemImage: "backward.end") { model.rollTimeline(to: index) }
        Button(feature.suppressed == true ? String(localized: "Unsuppress") : String(localized: "Suppress"),
               systemImage: feature.suppressed == true ? "eye" : "eye.slash") {
            model.run("timeline.suppress", ["feature": feature.id])
        }
        Button(String(localized: "Delete \(feature.name)"), systemImage: "trash", role: .destructive) {
            Self.delete(feature, model: model, toasts: toasts)
        }
    }

    @MainActor static func delete(_ f: DesignSnapshot.Feature, model: DesignModel, toasts: ToastCenter?) {
        guard model.run("timeline.delete", ["feature": f.id]) != nil else { return }
        let step = DesignStep(model)
        toasts?.show(String(localized: "Deleted \(f.name)"), systemImage: "trash", actionTitle: String(localized: "Undo")) { step.undo() }
    }
}

/// Steps the roll marker with the arrow keys of a hardware keyboard.
private struct TimelineArrowKeys: ViewModifier {
    let model: DesignModel
    let keys: (back: KeyEquivalent, forward: KeyEquivalent)

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [keys.back, keys.forward]) { press in
                let count = model.snapshot.timeline.count
                guard count > 0 else { return .ignored }
                let now = min(max(model.snapshot.marker, 0), count)
                let next = press.key == keys.back ? max(0, now - 1) : min(count, now + 1)
                if next != now { model.rollTimeline(to: next) }
                return .handled
            }
    }
}

/// The parametric history as a vertical list; tap a step to roll the design back to it. Every
/// step has its actions in a visible menu, a long-press menu and swipe actions.
struct HistorySidebar: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel
    /// A card over the viewport (iPad); false inside a sheet (iPhone).
    var floating = true

    var body: some View {
        List {
            if model.snapshot.timeline.isEmpty {
                Text("No steps yet. Sketch and extrude to start the history.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(Array(model.snapshot.timeline.enumerated()), id: \.element.id) { i, f in
                let rolled = f.rolled_back ?? false
                HStack(spacing: VFSpace.s) {
                    Button { model.rollTimeline(to: i + 1) } label: {
                        HStack(spacing: VFSpace.m) {
                            Image(systemName: FeatureSymbol.of(f.type)).frame(width: 20).foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(VFFont.row).foregroundStyle(theme.ink)
                                Text(stateText(f)).font(VFFont.micro).foregroundStyle(f.error != nil ? theme.danger : theme.inkSecondary)
                            }
                            Spacer(minLength: 0)
                            if f.error != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: VFSize.touchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Text("Rolls the design back to this step"))
                    Menu {
                        TimelineStepActions(model: model, index: i, feature: f, toasts: toasts)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(VFFont.glyph(17)).foregroundStyle(theme.inkSecondary)
                            .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                            .contentShape(Rectangle())
                    }
                    .hoverEffect(.highlight)
                    .accessibilityLabel(String(localized: "Actions for \(f.name)"))
                }
                .opacity(rolled ? 0.5 : 1)
                .listRowBackground(Color.clear)
                .contextMenu { TimelineStepActions(model: model, index: i, feature: f, toasts: toasts) }
                .swipeActions {
                    Button(String(localized: "Delete"), role: .destructive) { TimelineStepActions.delete(f, model: model, toasts: toasts) }
                    Button(f.suppressed == true ? String(localized: "Unsuppress") : String(localized: "Suppress")) {
                        model.run("timeline.suppress", ["feature": f.id])
                    }
                }
            }
            .onMove { from, to in
                guard let i = from.first, i < model.snapshot.timeline.count else { return }
                model.run("timeline.reorder", ["feature": model.snapshot.timeline[i].name, "position": to > i ? to - 1 : to])
            }
            if !model.snapshot.timeline.isEmpty {
                Button("Roll to End", systemImage: "forward.end") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
                    .frame(minHeight: VFSize.touchTarget)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .modifier(TimelineArrowKeys(model: model, keys: (.upArrow, .downArrow)))
        .modifier(FloatingCard(on: floating))
    }

    /// The type and state in words (never colour alone): "Extrude · Rolled back".
    private func stateText(_ f: DesignSnapshot.Feature) -> String {
        if f.error != nil { return String(localized: "\(f.type) · Error") }
        if f.suppressed == true { return String(localized: "\(f.type) · Suppressed") }
        if f.rolled_back == true { return String(localized: "\(f.type) · Rolled back") }
        return f.type
    }
}

/// The iPad's floating content card (Items, History): opaque panel, sized to the window.
private struct FloatingCard: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .frame(width: 300)
                .frame(maxHeight: 460)
                .vfSurface(.floating, radius: VFRadius.touchFloating)
        } else {
            content
        }
    }
}

/// The floating tool column: what can be made from here.
struct ToolRail: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let compact: Bool
    @Binding var showCommands: Bool

    var body: some View {
        if compact { strip } else { column }
    }

    /// iPhone: one bottom row.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VFSpace.xxs) {
                if model.sketchOpen {
                    ForEach(Tool.sketchTools) { t in rail(t, active: model.tool == t) { activate(t) }.frame(width: VFSize.touchTarget) }
                    rail("checkmark", String(localized: "Finish Sketch")) { model.finishSketch() }.frame(width: VFSize.touchTarget)
                } else {
                    ForEach(Tool.solidTools + Tool.primitiveTools) { t in rail(t, active: model.tool == t) { activate(t) }.frame(width: VFSize.touchTarget) }
                }
                rail("ellipsis.circle", String(localized: "All Commands")) { showCommands = true }.frame(width: VFSize.touchTarget)
            }
            .padding(VFSpace.xs)
        }
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }

    private var column: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: VFSpace.xs) {
                if model.sketchOpen {
                    section(String(localized: "Sketch"), Tool.sketchTools)
                    Button { model.finishSketch() } label: {
                        Label("Finish", systemImage: "checkmark").frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
                    }
                    .buttonStyle(.vfPrimary)
                    .padding(.vertical, VFSpace.xs)
                } else {
                    section(String(localized: "Create"), Tool.solidTools)
                    section(String(localized: "Primitives"), Tool.primitiveTools)
                    section(String(localized: "Arrange"), Tool.combineTools)
                    section(String(localized: "Inspect"), [.measure])
                }
                Divider().padding(.vertical, VFSpace.xs)
                rail("ellipsis.circle", String(localized: "All Commands")) { showCommands = true }
            }
            .padding(VFSpace.s)
        }
        .frame(width: 72)
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .vfSurface(.control, radius: VFRadius.touchFloating)
    }

    @ViewBuilder
    private func section(_ title: String, _ tools: [Tool]) -> some View {
        VFCaption(title).padding(.top, VFSpace.s)
        ForEach(tools) { t in
            rail(t, active: model.tool == t) { activate(t) }
        }
    }

    private func activate(_ t: Tool) { TouchToolActions.activate(t, model) }

    private func rail(_ tool: Tool, active: Bool = false, action: @escaping () -> Void) -> some View {
        rail(tool.symbol, tool.touchLabel, art: ToolIcons.art(for: tool), active: active, action: action)
    }

    private func rail(_ symbol: String, _ label: String, art: String? = nil, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: VFSpace.xxs) {
                CommandIcon(art: art, symbol: symbol, size: compact ? 17 : 19).frame(height: 28)
                if !compact { Text(label).font(VFFont.micro).lineLimit(1).minimumScaleFactor(0.6) }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? VFSize.touchTarget : 52)
            .foregroundStyle(active ? theme.onAccent : theme.ink)
            .background(active ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.vfTouch)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Where a new sketch goes: a tapped face or a base plane.
struct PlaneChooser: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        HStack(spacing: VFSpace.m) {
            Image(systemName: "hand.tap").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
            Text("Tap a face, or pick a plane").font(VFFont.row).foregroundStyle(theme.ink)
            ForEach(["XY", "XZ", "YZ"], id: \.self) { p in
                Button(p) { model.startSketch(p) }
                    .buttonStyle(.vfSecondary)
                    .accessibilityLabel(String(localized: "Sketch on the \(p) plane"))
            }
            VFIconButton("xmark", label: String(localized: "Cancel sketch"), size: 14) { model.tool = .select }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.vertical, VFSpace.xs)
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }
}

/// Tools the selection invites, as a floating strip.
struct SuggestionBar: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        HStack(spacing: VFSpace.xs) {
            ForEach(model.suggestions) { t in
                Button { TouchToolActions.activate(t, model) } label: {
                    Label { Text(t.touchLabel) } icon: { CommandIcon(tool: t, size: 15) }
                        .font(VFFont.row.weight(.medium))
                        .foregroundStyle(theme.ink)
                        .padding(.horizontal, VFSpace.m)
                        .frame(minHeight: VFSize.touchTarget)
                }
                .buttonStyle(.vfTouch)
            }
            VFHairline(vertical: true).frame(height: 22)
            VFIconButton("xmark.circle.fill", label: String(localized: "Clear selection"), size: 16, tint: theme.inkSecondary) {
                model.selection = []; model.selectedBodies = []
            }
        }
        .padding(.horizontal, VFSpace.s)
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }
}

/// Bodies and sketches, with visibility. Every row has a long-press menu.
struct ItemsPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    var floating = true

    var body: some View {
        List {
            if !model.assembly.isEmpty {
                Section("Components") {
                    ForEach(model.assembly) { c in
                        HStack {
                            Image(systemName: c.linkedPCB ? "cpu" : "shippingbox").foregroundStyle(c.linkedPCB ? theme.accentText : theme.inkSecondary)
                                .accessibilityHidden(true)
                            Text(c.occurrence ?? c.name).foregroundStyle(theme.ink)
                            Spacer()
                            if c.linkedPCB { Image(systemName: "link").foregroundStyle(theme.accentText).accessibilityLabel(Text("Linked to the board")) }
                            if c.grounded { Image(systemName: "pin.fill").foregroundStyle(theme.inkSecondary).accessibilityLabel(Text("Grounded")) }
                        }
                        .font(VFFont.row)
                        .frame(minHeight: VFSize.touchTarget)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedBodies = Set(c.bodies) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text("Selects its bodies"))
                        .contextMenu {
                            Button("Select Bodies", systemImage: "cursorarrow") { model.selectedBodies = Set(c.bodies) }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            Section("Bodies") {
                if model.snapshot.bodies.isEmpty {
                    Text("No bodies yet.").font(VFFont.row).foregroundStyle(theme.inkSecondary).listRowBackground(Color.clear)
                }
                ForEach(model.snapshot.bodies) { b in
                    let visible = b.visible ?? true
                    let selected = model.selectedBodies.contains(b.name)
                    HStack {
                        Image(systemName: "cube.fill").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                        VStack(alignment: .leading) {
                            Text(b.name).foregroundStyle(visible ? theme.ink : theme.inkTertiary)
                            if let v = b.volume_mm3 { Text("\(VFFormat.number(v, digits: 0)) mm³").font(VFFont.micro).foregroundStyle(theme.inkSecondary) }
                        }
                        Spacer()
                        VFIconButton(visible ? "eye" : "eye.slash",
                                     label: visible ? String(localized: "Hide \(b.name)") : String(localized: "Show \(b.name)"),
                                     size: 15, tint: visible ? theme.ink : theme.inkTertiary) {
                            model.toggleBodyVisibility(b.name, visible: !visible)
                        }
                    }
                    .font(VFFont.row)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(b.name) }
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .contextMenu {
                        Button(selected ? String(localized: "Deselect") : String(localized: "Select"), systemImage: "cursorarrow") { toggle(b.name) }
                        Button(visible ? String(localized: "Hide") : String(localized: "Show"), systemImage: visible ? "eye.slash" : "eye") {
                            model.toggleBodyVisibility(b.name, visible: !visible)
                        }
                    }
                    .listRowBackground(selected ? theme.selection : Color.clear)
                }
            }
            Section("Sketches") {
                ForEach(model.snapshot.sketches) { s in
                    HStack {
                        Image(systemName: "pencil.and.outline").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                        Text(s.name).foregroundStyle(theme.ink)
                        Spacer()
                        Button("Edit") { edit(s) }
                            .buttonStyle(.vfSecondary)
                            .accessibilityLabel(String(localized: "Edit \(s.name)"))
                    }
                    .font(VFFont.row)
                    .frame(minHeight: VFSize.touchTarget)
                    .contextMenu { Button("Edit Sketch", systemImage: "pencil") { edit(s) } }
                    .listRowBackground(Color.clear)
                }
            }
            if !model.snapshot.params.isEmpty {
                Section("Parameters") {
                    ForEach(model.snapshot.params) { p in
                        HStack { Text(p.name).foregroundStyle(theme.ink); Spacer(); Text(p.expression).foregroundStyle(theme.inkSecondary).monospacedDigit() }
                            .font(VFFont.row)
                            .accessibilityElement(children: .combine)
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .modifier(FloatingCard(on: floating))
    }

    private func toggle(_ name: String) {
        if model.selectedBodies.contains(name) { model.selectedBodies.remove(name) } else { model.selectedBodies.insert(name) }
    }

    private func edit(_ s: DesignSnapshot.Sketch) {
        model.run("sketch.edit", ["sketch": s.id])
        if let pl = model.sketchPlane { model.look(along: pl.normal) }
        model.tool = .line
    }
}

/// The parametric history: one chip per step; tapping one rolls the design back to it. Each
/// step's actions are in its long-press menu and in the Steps menu at the end of the bar.
struct HistoryBar: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VFSpace.s) {
                    ForEach(Array(model.snapshot.timeline.enumerated()), id: \.element.id) { i, f in
                        let rolled = f.rolled_back ?? false
                        Button { model.rollTimeline(to: i + 1) } label: {
                            HStack(spacing: VFSpace.xs) {
                                Image(systemName: FeatureSymbol.of(f.type)).accessibilityHidden(true)
                                Text(f.name).font(VFFont.small.weight(.medium))
                                if f.error != nil {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                                        .accessibilityLabel(Text("Error"))
                                }
                            }
                            .foregroundStyle(theme.ink)
                            .padding(.horizontal, VFSpace.m).frame(minHeight: 32)
                            .background(rolled ? Color.clear : theme.accent.opacity(0.12), in: Capsule())
                            // Rolled back steps are outlined and dimmed, and say so to VoiceOver.
                            .overlay(Capsule().strokeBorder(theme.accent.opacity(rolled ? 0.35 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .opacity(rolled ? 0.55 : 1)
                            .frame(minHeight: VFSize.touchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.vfTouch)
                        .accessibilityValue(rolled ? String(localized: "Rolled back") : "")
                        .accessibilityHint(Text("Rolls the design back to this step"))
                        .contextMenu { TimelineStepActions(model: model, index: i, feature: f, toasts: toasts) }
                    }
                }
                .padding(.horizontal, VFSpace.m)
            }
            VFIconButton("forward.end.fill", label: String(localized: "Roll to End"), size: 14) {
                model.run("timeline.roll_to", ["position": "end"], quiet: true)
            }
            Menu {
                ForEach(Array(model.snapshot.timeline.enumerated()).reversed(), id: \.element.id) { i, f in
                    Menu(f.name) { TimelineStepActions(model: model, index: i, feature: f, toasts: toasts) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(VFFont.glyph(16)).foregroundStyle(theme.inkSecondary)
                    .frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
                    .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .accessibilityLabel(Text("Step actions"))
            .padding(.trailing, VFSpace.xs)
        }
        .frame(minHeight: 52)
        .frame(maxWidth: 900)
        .modifier(TimelineArrowKeys(model: model, keys: (.leftArrow, .rightArrow)))
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }
}

/// Every command of the engine, searchable (a viewer: Done in the toolbar).
struct CommandBrowser: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: DesignModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.0) { tab, cmds in
                    Section(tab.isEmpty ? String(localized: "Other") : StageLabels.tab(tab).capitalized) {
                        ForEach(cmds) { c in
                            Button {
                                dismiss()
                                if let t = Tool.allCases.first(where: { $0.commandID == c.id && $0 != .union && $0 != .subtract && $0 != .intersect }) {
                                    model.tool = t
                                } else {
                                    model.genericCommand = c
                                }
                            } label: {
                                Label { Text(StageLabels.command(c.label)).foregroundStyle(theme.ink) }
                                    icon: { CommandIcon(icon: c.icon, id: c.id, size: 16) }
                                    .frame(minHeight: VFSize.touchTarget)
                            }
                        }
                    }
                }
                if groups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query)
            .navigationTitle(Text("Commands"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var groups: [(String, [CommandInfo])] {
        let q = query.lowercased()
        let list = model.commands.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.id.contains(q) }
        return Dictionary(grouping: list, by: \.tab).sorted { StageLabels.tab($0.key) < StageLabels.tab($1.key) }
    }
}

// MARK: - Export

enum ExportKind: String, Identifiable {
    case design, step, stl, kicad
    var id: String { rawValue }
    var ext: String { switch self { case .design: "sc"; case .step: "step"; case .stl: "stl"; case .kicad: "kicad_pcb" } }

    var title: String {
        switch self {
        case .design: String(localized: "Design")
        case .step: String(localized: "STEP")
        case .stl: String(localized: "STL")
        case .kicad: String(localized: "KiCad Board")
        }
    }
}

/// The one export flow on touch (P0-5), for the design files and the KiCad board: asks before
/// replacing a file of the same name, shows what it is writing, then Share, or the reason with
/// Try Again. Cancel while it has not written; Done after.
struct ExportFlow: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: DesignModel
    let kind: ExportKind
    var pcb: PCBModel?

    private enum Phase: Equatable {
        case checking
        case running
        case done(URL)
        case failed(String)
    }

    @State private var phase: Phase = .checking
    @State private var confirm: ConfirmRequest?

    var body: some View {
        NavigationStack {
            VStack(spacing: VFSpace.xl) {
                switch phase {
                case .checking, .running:
                    ProgressView { Text("Exporting \(kind.title)…").font(VFFont.row).foregroundStyle(theme.inkSecondary) }
                        .controlSize(.large)
                case .done(let url):
                    Image(systemName: "checkmark.circle.fill").font(VFFont.glyph(44)).foregroundStyle(theme.success)
                        .accessibilityHidden(true)
                    VStack(spacing: VFSpace.xs) {
                        Text("Exported").font(VFFont.title).foregroundStyle(theme.ink)
                        Text(url.lastPathComponent).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .combine)
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up").frame(minWidth: 160)
                    }
                    .buttonStyle(.vfPrimary)
                case .failed(let message):
                    InlineError(message, retryTitle: String(localized: "Try Again"), retry: { start(replacing: true) })
                }
            }
            .padding(VFSpace.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.panel)
            .navigationTitle(Text("Export \(kind.title)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .done = phase {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(phase == .running)
        .sensoryFeedback(.success, trigger: phase) { _, new in if case .done = new { true } else { false } }
        .sensoryFeedback(.error, trigger: phase) { _, new in if case .failed = new { true } else { false } }
        .confirmSheet($confirm)
        .task { start(replacing: false) }
    }

    private var target: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = kind == .kicad ? (pcb?.project?.name ?? String(localized: "Board")) : model.snapshot.name
        let base = name.replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("\(base).\(kind.ext)")
    }

    /// Asks first when a file of that name is there (VIAFORM-SPEC 6.4), then writes.
    private func start(replacing: Bool) {
        let url = target
        if !replacing, FileManager.default.fileExists(atPath: url.path) {
            confirm = ConfirmRequest(
                title: String(localized: "Replace \(url.lastPathComponent)?"),
                message: String(localized: "A file with this name is already in ViaForm's documents. Replacing it overwrites it."),
                verb: String(localized: "Replace"), destructive: true,
                perform: { start(replacing: true) },
                alternate: (title: String(localized: "Keep Both"), perform: { write(to: uniqueURL(url)) }),
                cancel: { dismiss() })
            return
        }
        write(to: url)
    }

    private func write(to url: URL) {
        phase = .running
        Task { @MainActor in
            // Let the progress draw before the engine writes.
            await Task.yield()
            if kind == .kicad { pcb?.message = nil } else { model.flash(nil) }
            let before = Self.modified(url)
            switch kind {
            case .design: model.save(to: url)
            case .kicad: pcb?.exportKiCad(to: url)
            default: model.export(to: url)
            }
            let failed = kind == .kicad ? (pcb?.messageIsError ?? true) : model.messageIsError
            // Written now: the file is there and, when one was replaced, newer than it was.
            let after = Self.modified(url)
            if after != nil, before == nil || after != before, !failed {
                phase = .done(url)
            } else {
                let reason = (kind == .kicad ? pcb?.message : model.message) ?? String(localized: "The file was not written.")
                phase = .failed(String(localized: "Could not export the \(kind.title) file. \(reason)"))
            }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// "Bracket 2.step", "Bracket 3.step": the first free name.
    private func uniqueURL(_ url: URL) -> URL {
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        var candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
        while FileManager.default.fileExists(atPath: candidate.path) {
            n += 1
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
        }
        return candidate
    }
}

#endif
