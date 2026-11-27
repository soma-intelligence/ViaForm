#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The touch front end (iPad and iPhone), one shell for the nine stages of the pipeline. The
/// stage's view fills the screen (the 3D design, the study, the board, the flight). On the iPad
/// the 3D stages use the Shapr3D zones (see `designStage`): Items slides in from the left,
/// History from the right; the other stages and the iPhone keep the top capsule. The browser, export and the
/// command palette open as sheets. Finger orbits, two fingers pan, pinch zooms, a two-finger tap
/// on the 3D view undoes, Pencil selects and sketches. Each window owns its models, so two iPad
/// windows never share a document.
struct TouchRootView: View {
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--landscape-render") {
            // Screenshots on a simulator nobody can turn: the shell laid out landscape and
            // drawn turned a quarter, the PNG is turned back afterwards. Debug only.
            GeometryReader { geo in
                TouchShell().viaFormTheme().touchNumberKeypad()
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(-90))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .ignoresSafeArea()
            .statusBarHidden()
        } else {
            TouchShell().viaFormTheme().touchNumberKeypad()
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
    /// Items slides in from the left, History from the right (T-6): two panels, both can be open.
    @State private var panels = TouchPanels(TouchShell.launchSide)
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
    /// The stage's inspector card (Option-Command-I hides it). The design itself has none on
    /// the iPad: its details open from the readout's (i).
    @State private var inspectorShown = true
    /// The selection's details, from the readout's (i).
    @State private var selectionInfo = false
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
    /// The left-handed layout mirrors the zones (agent D's setting, per device).
    @AppStorage(TouchHandedness.key) private var leftHanded = false
    /// The snapping rail's grid switch.
    @AppStorage(SketchDisplaySettings.gridKey) private var gridVisible = true
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
            .safeAreaInset(edge: .top, spacing: 0) {
                // The 3D stages on the iPad draw their own top zones (designStage).
                if !(onDesign && !compact) { topCapsule }
            }
            .background(TwoFingerTapUndo { undo(gesture: true) }.allowsHitTesting(false))
            .background(TouchKeyCommands(focus: focus))
            .background(TouchToolKeys(model: model, enabled: !presenting && !showPalette && stage == .design,
                                      showPalette: { showPalette = true }))
            .vfParameterLinks(model)
            .focusedSceneValue(\.vfTouch, focus)
            .vfAnimation(.snappy(duration: VFMotion.standard), value: panels)
            .vfAnimation(.snappy(duration: VFMotion.standard), value: inspectorShown)
            .vfAnimation(.snappy(duration: VFMotion.fast), value: model.tool)
            .sensoryFeedback(.impact(weight: .light), trigger: undoTick)
            .sensoryFeedback(.selection, trigger: model.tool)
            .pencilDoubleTapTogglesTool(model)
            .task { TouchSketchUISelfTest.runIfAsked(); TouchSketchToolsSelfTest.runIfAsked() }
            .onChange(of: stage) { _, s in pcb.syncLink(model); storedStage = s.rawValue }
            .onChange(of: panels) { _, p in storedSide = p.stored }
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
            .sheet(isPresented: $showShortcuts) { TouchShortcutsSheet(toolRows: TouchKeymap.rows(model)).viaFormTheme().presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showLibrary) {
                LibraryView(model: library, design: model, pcb: pcb) { showLibrary = false }.presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showBom) {
                BomPanel(model: bom, design: model, pcb: pcb) { showBom = false }
                    .onAppear { if BomModel.launchRequested, bom.rows.isEmpty { bom.applyLaunchFlags() } }
            }
            // On iPhone (and a narrow iPad window) the Items and History cards come up as sheets.
            .sheet(isPresented: Binding(get: { compact && panels.any }, set: { if !$0 { panels = TouchPanels() } })) {
                Group {
                    if panels.history { HistorySidebar(model: model, floating: false) } else { ItemsPanel(model: model, floating: false) }
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

    /// Design, Assemble, Render and Make over the 3D view, in the reference tablet zones (T-6,
    /// docs/research/cad-ui/shapr3d-ipad.md 1.1): Modeling and Items top left, the title pill
    /// and the tool mode pill top centre, the view cube, the mini rail and History top right;
    /// the tool column under Items, centred between them and the view modes and undo tiles;
    /// the constraint column under History while sketching; the selection readout bottom
    /// centre. Icons sit on white tiles at the screen edge, labels float (`TouchRail`). Items
    /// slides in from the tool edge and pushes everything on that side over; History slides in
    /// from the panel edge and pushes the rail. Both panels run the full height. The
    /// left-handed setting mirrors the sides.
    private var designStage: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                // The sketch state is the readout's business here (TouchSketchStateChip is off).
                Viewport(model: model, theme: theme.viewportTheme.touchGrid(gridVisible), sketchStatus: false)
                if stage == .design || stage == .assemble {
                    DesignAnchorLayer(model: model, stage: stage, extra: crossStageVerbs)
                }
                HStack(alignment: .top, spacing: 0) {
                    if leftHanded {
                        panelSide(height: h).environment(\.touchRailEdge, .leading)
                        Spacer(minLength: 0)
                        toolSide(height: h).environment(\.touchRailEdge, .trailing)
                    } else {
                        toolSide(height: h).environment(\.touchRailEdge, .leading)
                        Spacer(minLength: 0)
                        panelSide(height: h).environment(\.touchRailEdge, .trailing)
                    }
                }
                centre
            }
            .vfEngineGate()
        }
        .ignoresSafeArea()
        // The reference runs edge to edge with no status bar.
        .statusBarHidden()
    }

    /// The title pill, the tool mode pill and Normal to Sketch at the top centre; banners and
    /// the selection readout at the bottom centre.
    private var centre: some View {
        VStack(spacing: VFSpace.s) {
            TouchTitlePill(flow: flow, stage: stage, title: title, compact: compact,
                           showBrowser: { showBrowser = true }, showPalette: { showPalette = true },
                           showShortcuts: { showShortcuts = true },
                           share: AnyView(TouchShareMenu(prominent: true, export: { exporting = $0 }, showBom: { showBom = true },
                                                         showLibrary: { showLibrary = true })))
            if model.tool != .select { TouchToolModePill(model: model) }
            NormalToSketchPill(model: model)
            Spacer(minLength: 0)
            bottomCentre
        }
        .padding(.top, TouchRail.top)
        .padding(.bottom, TouchRail.bottom)
        .frame(maxWidth: 560)
    }

    /// The left rail's rows: the column (no constraint slot), the footer tiles and the view modes.
    private func toolRows() -> (rows: Int, tiles: Int) {
        guard stage == .design else { return (8, 3) }
        let items = TouchColumnLayout.items(TouchColumnContext(model: model))
        let tiles = TouchColumnLayout.tiles(items)
        var rows = tiles.reduce(0) { $0 + $1.count }
        var count = tiles.count
        if model.sketchOpen { rows += 1; count += 1 }
        if runningTool && !model.tool.isSketchTool { rows = 3; count = 1 } else if runningTool { rows += 2; count += 1 }
        rows += TouchViewModeStack.rows(construction: constructionBinding != nil, isolate: showsIsolate)
        return (rows, count + 1)
    }

    /// A design tool runs (not a sketch tool that only draws): Done and Cancel stand by the column.
    private var runningTool: Bool {
        stage == .design && model.tool != .select && model.tool != .sketch
            && (!model.tool.isSketchTool || model.tool.takesSketchEntities)
    }

    private var showsIsolate: Bool {
        model.sketchOpen || !model.selection.isEmpty || !model.selectedBodies.isEmpty
    }

    /// Items (on the outer edge, full height), then the rail: Modeling and Items, the column
    /// centred under them, the view modes and the undo tiles at the foot.
    private func toolSide(height h: CGFloat) -> some View {
        let edge: Edge = leftHanded ? .trailing : .leading
        let (rows, tiles) = toolRows()
        let row = TouchRail.rowHeight(height: h, fixed: TouchRail.leftFixed, rows: rows, groups: tiles)
        let rail = VStack(alignment: TouchHandedness.toolAlignment(leftHanded: leftHanded), spacing: TouchRail.gap) {
            TouchWorkspaceZone(flow: flow, stage: stage, compact: compact, workspacesOpen: $showWorkspaces,
                               side: panels.sideBinding($panels), showsItems: onDesign, open: open)
            Spacer(minLength: 0)
            tools.environment(\.touchRailRow, row)
            Spacer(minLength: 0)
            if sectionOn {
                TouchSectionControl(model: model) { toggleSection() }
                    .vfTransition(.opacity)
            }
            TouchViewModeStack(sectionOn: sectionOn, isolateOn: !isolated.isEmpty, construction: constructionBinding,
                               showsIsolate: showsIsolate, toggleSection: toggleSection, toggleIsolate: toggleIsolate,
                               measure: model.measureSelection)
                .environment(\.touchRailRow, row)
            TouchUndoCircles(target: undoTarget, stageTitle: stage.title, undo: { undo() }, redo: redo)
        }
        .padding(.top, TouchRail.top)
        .padding(.bottom, TouchRail.bottom)
        .padding(edge == .leading ? .leading : .trailing, TouchRail.edge)
        return HStack(alignment: .top, spacing: 0) {
            if leftHanded { rail }
            if panels.items {
                ItemsPanel(model: model)
                    .padding(.vertical, 0)
                    .padding(.top, TouchRail.top)
                    .padding(.bottom, TouchRail.bottom)
                    .padding(edge == .leading ? .leading : .trailing, TouchRail.edge)
                    .vfTransition(.move(edge: edge).combined(with: .opacity))
            }
            if !leftHanded { rail }
        }
    }

    /// Construction mode while a sketch is open (the bottom-left stack's first row).
    private var constructionBinding: Binding<Bool>? {
        guard stage == .design, model.sketchOpen else { return nil }
        return Binding(get: { model.constructionMode }, set: { model.constructionMode = $0 })
    }

    /// The panel edge: the view cube and its rail, History, then the sketch's constraint column
    /// (T-2) or another stage's inspector card; History's panel beyond them, full height.
    private func panelSide(height h: CGFloat) -> some View {
        let edge: Edge = leftHanded ? .leading : .trailing
        let row = TouchRail.rowHeight(height: h, fixed: TouchRail.rightFixed, rows: TouchConstraintColumn.rowCount, groups: 2)
        let rail = VStack(alignment: TouchHandedness.panelAlignment(leftHanded: leftHanded), spacing: TouchRail.gap) {
            TouchViewZone(model: model, side: panels.sideBinding($panels), perspective: $perspective)
            if stage == .design, model.sketchOpen {
                TouchConstraintColumn(model: model)
                    .environment(\.touchRailRow, row)
                    .vfTransition(.move(edge: edge).combined(with: .opacity))
            } else if stage != .design, inspectorShown, !panels.history {
                rightCard
            }
            Spacer(minLength: 0)
        }
        .padding(.top, TouchRail.top)
        .padding(edge == .trailing ? .trailing : .leading, TouchRail.edge)
        return HStack(alignment: .top, spacing: 0) {
            if !leftHanded { rail }
            if panels.history {
                HistorySidebar(model: model)
                    .padding(.top, TouchRail.top)
                    .padding(.bottom, TouchRail.bottom)
                    .padding(edge == .trailing ? .trailing : .leading, TouchRail.edge)
                    .padding(edge == .trailing ? .leading : .trailing, TouchRail.gap)
                    .vfTransition(.move(edge: edge).combined(with: .opacity))
            }
            if leftHanded { rail }
        }
    }

    /// Banners, the plane chooser and the selection readout, bottom centre. The readout's (i)
    /// shows the selection's details (volume, mass, faces, material) in a popover.
    private var bottomCentre: some View {
        VStack(spacing: VFSpace.m) {
            PCBLinkBanner(design: model, pcb: pcb)
            MessageBanner(model: model)
            if model.tool == .sketch { PlaneChooser(model: model) }
            TouchSelectionReadout(model: model, showInspector: { selectionInfo = true })
                .popover(isPresented: $selectionInfo, arrowEdge: .bottom) {
                    TouchDesignInspector(model: model, flow: flow, stage: stage, open: open)
                        .padding(VFSpace.s)
                        .presentationCompactAdaptation(.popover)
                        .viaFormTheme()
                }
        }
    }

    @ViewBuilder private var tools: some View {
        switch stage {
        case .design where runningTool && !model.tool.isSketchTool:
            // The reference swaps the whole column for Done, the tool's options and Cancel.
            TouchToolRailFooter(model: model)
        case .design:
            TouchToolColumn(model: model, showPalette: { showPalette = true }, extra: crossStageVerbs, constraintSlot: nil,
                            footer: railFooter)
        case .assemble, .render:
            CatalogToolGroups(ribbon: StageScreen.ribbon(flow.commands(stage: stage.stage), perGroup: 8), groups: stage == .render ? 1 : 2, run: run)
        default:
            EmptyView()
        }
    }

    /// Under the column: Delete in a sketch; Done, the options and Cancel while a tool runs.
    private var railFooter: AnyView? {
        if runningTool { return AnyView(TouchToolRailFooter(model: model)) }
        if model.sketchOpen { return AnyView(TouchSketchDeleteTile(model: model)) }
        return nil
    }

    @ViewBuilder private var rightCard: some View {
        Group {
            switch stage {
            case .assemble: TouchAssembleInspector(model: model, pcb: pcb, flow: flow, open: open)
            case .render: TouchRenderInspector(model: model, flow: flow, open: open)
            case .make: TouchMakeInspector(flow: flow, open: open, export: { exporting = $0 }, showBom: { showBom = true })
            default: TouchDesignInspector(model: model, flow: flow, stage: stage, open: open)
            }
        }
        .vfTransition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// iPhone and narrow windows: one column, tools in a bottom strip.
    private var compactDesign: some View {
        ZStack {
            // The sketch's defined state sits beside the cube, under the bar: on the canvas's
            // top edge it ran under the Dynamic Island.
            Viewport(model: model, theme: theme.viewportTheme.touchGrid(gridVisible), sketchStatus: false).ignoresSafeArea()
            VStack(spacing: VFSpace.m) {
                HStack(alignment: .top) {
                    if model.sketchOpen { SketchStateBadge(model: model) }
                    Spacer()
                    ViewCube(model: model, size: 70)
                }
                Spacer(minLength: 0)
                PCBLinkBanner(design: model, pcb: pcb)
                MessageBanner(model: model)
                if model.tool == .sketch { PlaneChooser(model: model) }
                if model.tool != .select, model.tool != .sketch { ToolSession(model: model, layout: .bar) }
                else if !model.suggestions.isEmpty { SuggestionBar(model: model) }
                TouchToolColumn(model: model, showPalette: { showPalette = true }, axis: .horizontal, extra: crossStageVerbs,
                                constraintSlot: model.sketchOpen ? AnyView(TouchConstraintStripMenu(model: model)) : nil)
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

    // MARK: - Top capsule

    private var topCapsule: some View {
        HStack(alignment: .center, spacing: VFSpace.m) {
            TouchTopCapsule(
                flow: flow, stage: stage, title: title,
                undoTarget: undoTarget,
                compact: compact, side: panels.sideBinding($panels), showsSideSwitch: onDesign,
                open: open, undo: { undo() }, redo: redo,
                showBrowser: { showBrowser = true }, showPalette: { showPalette = true },
                share: AnyView(TouchShareMenu(export: { exporting = $0 }, showBom: { showBom = true }, showLibrary: { showLibrary = true })),
                workspacesOpen: $showWorkspaces
            )
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.top, VFSpace.xs)
        .vfEngineGate()
    }

    private var title: String {
        ProjectTitle.of(flow: flow, design: model)
    }

    // MARK: - Keyboard focus

    /// A sheet, cover, popover or the palette is up over the shell.
    private var presenting: Bool {
        showBrowser || showLibrary || showBom || showCommands || showShortcuts || exporting != nil
            || model.genericCommand != nil || (compact && panels.any) || showWorkspaces || confirm != nil
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
        if ![.design, .assemble, .render, .make].contains(w) { panels = TouchPanels() }
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

    /// Section View through agent C's `SectionController`: on cuts at XZ and shows the section
    /// control (plane, offset); off clears the cut.
    private func toggleSection() {
        let section = SectionController.of(model)
        if sectionOn || section.isOn {
            section.clear(model: model)
            sectionOn = false
        } else {
            sectionOn = section.set(named: "XZ", model: model)
        }
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
        if TouchShell.launchSide == nil { panels = TouchPanels(stored: storedSide) }
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
        #if DEBUG
        // The panels' own checks, before `--selftest` wires them (prints one line per check).
        if args.contains("--panels-selftest") {
            for (ok, what) in TouchPanelsSelfTest.checks() { print("\(ok ? "PASS" : "FAIL") \(what)") }
        }
        #endif
        if let s = args.first(where: { $0.hasPrefix("--select=") }) {
            model.selectedBodies = [String(s.dropFirst("--select=".count))]
        }
        // `--touch-sketch-line`: a sketch open on XY with a rectangle, one side picked (screenshots).
        if args.contains("--touch-sketch-line") {
            model.run("file.new", quiet: true)
            model.startSketch("XY")
            model.run("sketch.rectangle.two_point", ["p0": [-30, -20], "p1": [30, 20]], quiet: true)
            if let line = model.sketchInfo?.curves.first(where: { $0.kind == "line" }) {
                model.sketchSelection = [SketchPick(id: line.id, kind: .line)]
            }
        }
        // `--touch-tap-center`: one tap at the middle of the view once it has laid out (a face
        // picked, for screenshots of the readout and the selection column).
        if args.contains("--touch-tap-center") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                let size = model.viewSize
                if size.width > 0 { model.click(at: CGPoint(x: size.width / 2, y: size.height / 2), mode: .replace) }
            }
        }
        if let s = args.first(where: { $0.hasPrefix("--tool=") }), let t = Tool(rawValue: String(s.dropFirst("--tool=".count))) {
            model.tool = t
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
