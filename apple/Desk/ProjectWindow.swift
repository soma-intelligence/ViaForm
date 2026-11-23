#if os(macOS)
import AppKit
import SwiftUI

/// The Mac project window: one product and its nine stages, switched from the workspace dropdown
/// at the far left of the ribbon (decision D-10).
///
/// Toolbar: the product and the open stage's revision, undo and redo, the job capsule while a job
/// runs, command search (Command-K), the flow graph, jobs, BOM, libraries and the inspector toggle. Sidebar: BROWSER over
/// PIPELINE OUTPUTS. Detail: the stage's ribbon, its workspace (3D model, generative study,
/// board, flight), its bottom panel and the status bar. Inspector: the selection, its flow and
/// the stage's section, or the libraries. Every workspace of the old window is embedded as is.
struct ProjectWindow: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    let pcb: PCBModel
    @State private var workspace = Workspace.fromLaunchArguments() ?? .design
    @State private var sim = SimModel()
    @State private var generate = GenerateModel()
    @State private var library = LibraryModel()
    @State private var bom = BomModel()
    @State private var flow = FlowModel()
    @State private var assemble = AssembleModel()
    @State private var armSim = ArmSimModel()
    @State private var safety = RobotSafety.shared
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var showInspector = !ProcessInfo.processInfo.arguments.contains("--no-inspector")
    @State private var inspectorMode = InspectorMode.inspector
    @State private var showPalette = false
    @State private var showShortcuts = ProcessInfo.processInfo.arguments.contains("--show-shortcuts")
    /// "Undone" or "Redone", shown a moment over the stage after an undo or a redo.
    @State private var undoFlash: String?
    @State private var flashToken = 0
    @AppStorage(ThemeMode.storageKey) private var themeMode: String = ThemeMode.default.rawValue
    @State private var showBottom = true
    @State private var showBom = BomModel.launchRequested
    @State private var showData = false
    /// The workspace dropdown is open (click or Command-0).
    @State private var showWorkspaces = ProcessInfo.processInfo.arguments.contains("--show-workspaces")
    /// The flow graph popover (dropdown footer, toolbar button, "Show Flow").
    @State private var showGraph = false
    /// The project start (templates, recent projects) instead of the project.
    @State private var showStart = StartLaunch.atLaunch
    /// Stale banners hidden for this session, by stage and reason.
    @State private var dismissedBanners: Set<String> = []
    @State private var tabs: [Workspace: String] = [:]
    @State private var detailWidth: CGFloat = 900
    @State private var hiddenLayers: Set<String> = []
    /// The window's toasts ("Deleted Frame", "Saved"), shown over the stage.
    @State private var toasts = ToastCenter()
    /// The BOM panel was edited last while open: Command-Z goes to it, not to the stage.
    @State private var undoOwner = UndoOwner.stage
    /// The design features before the last change, to name an undone or redone step.
    @State private var lastFeatures: [String] = []
    /// Layout kept with the window when it is restored (P2-9).
    @SceneStorage("viaform.desk.stage") private var storedStage = ""
    @SceneStorage("viaform.desk.inspector") private var storedInspector = true
    @SceneStorage("viaform.desk.bottom") private var storedBottom = true
    @SceneStorage("viaform.desk.bomHeight") private var bomHeight: Double = 360

    enum InspectorMode { case inspector, library }
    enum UndoOwner { case stage, bom }

    private var actions: StageActions {
        var a = StageActions(model: model, pcb: pcb, flow: flow, sim: sim, generate: generate,
                             open: { workspace = $0 },
                             openTab: { w, t in tabs[w] = t },
                             showBom: { showBom = true },
                             showLibrary: { inspectorMode = .library; showInspector = true },
                             showFlow: { _ in showGraph = true })
        a.current = workspace
        return a
    }

    private var screen: StageScreen { StageScreen.make(workspace, flow: flow) }

    private var title: String {
        ProjectTitle.of(flow: flow, design: model)
    }

    var body: some View {
        if showStart {
            startScreen
        } else {
            project
        }
    }

    // MARK: Start

    private var startScreen: some View {
        StartWindow(start: start, open: { url in
            if let url { FileActions.open(url, model) } else { FileActions.open(model) }
            showStart = false
        })
        .navigationTitle("ViaForm")
        .navigationSubtitle("Start")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showStart = false } label: { Label("Close Start", systemImage: "xmark") }
                    .help("Back to the open project")
            }
        }
        .focusedSceneValue(\.vfDesk, DeskFocus(workspace: workspace, open: { showStart = false; workspace = $0 }, search: {},
                                                start: { showStart = false }, design: model))
        .projectFilesContext(design: model, pcb: pcb, bom: bom, flow: flow)
        .background(WindowSizer())
    }

    /// Opens a template or a blank start: the product's design and its pipeline graph.
    private func start(_ t: StartTemplate) {
        if t.kind == .importFile {
            FileActions.open(model)
            showStart = false
            return
        }
        // A template replaces the open product: ask first when it has unsaved changes (P0-2).
        ProjectGuard.confirmDiscard(model, verb: String(localized: "New Project")) { applyTemplate(t) }
    }

    private func applyTemplate(_ t: StartTemplate) {
        let ctx = ProjectFiles.Context(design: model, pcb: pcb, bom: bom, flow: flow)
        switch t.preset {
        case "drone":
            if pcb.project?.components.isEmpty ?? true { pcb.loadSample() }
            DeskSamples.drone(model, pcb: pcb)
            flow.newDocument(product: t.product)
            generate.openSample("drone")
        case "hand":
            DeskSampleHand.build(into: model)
            flow.newDocument(product: t.product, graph: "hand")
            generate.openSample("hand")
            assemble.openHand(flow: flow)
        case "arm":
            // The Desk robot arm: graph arm(), the six-joint assembly and its BOM lines.
            model.newDesign()
            flow.newDocument(product: t.product, graph: "arm")
            assemble.openArm(flow: flow)
        case let preset?:
            // A preset with no sample model yet (the arm until phase 2): its graph and name.
            model.newDesign()
            flow.newDocument(product: t.product, graph: preset)
        case nil:
            ProjectFiles.newDesign(model, in: ctx)
            if t.kind == .board { pcb.newProject() }
        }
        if t.preset != "arm" && t.preset != "hand" { assemble.close() }
        workspace = t.stage
        showStart = false
    }

    private var project: some View {
        let actions = actions
        let screen = screen
        return NavigationSplitView(columnVisibility: $columns) {
            BrowserSidebar(workspace: workspace, model: model, flow: flow, actions: actions,
                           assemble: workspace == .assemble && assemble.isActive ? assemble : nil)
                .navigationSplitViewColumnWidth(min: VFSize.sidebarMin, ideal: 256, max: VFSize.sidebarMax)
        } detail: {
            VStack(spacing: 0) {
                content(actions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { staleBanner(actions) }
                    .overlay(alignment: .leading) {
                        if showData { DataPanel(model: model, shown: $showData).vfTransition(.move(edge: .leading)) }
                    }
                    .vfAnimation(.easeOut(duration: VFMotion.standard), value: showData)
                    .overlay(alignment: .bottomLeading) {
                        StageIntro(workspace: workspace).padding(VFSpace.l)
                    }
                    .overlay(alignment: .bottom) {
                        if let undoFlash {
                            Text(undoFlash).font(VFFont.small.weight(.medium)).foregroundStyle(theme.ink)
                                .padding(.horizontal, VFSpace.l).frame(minHeight: VFSize.toast)
                                .vfSurface(.floating, radius: VFRadius.floating)
                                .padding(.bottom, VFSpace.toastLift)
                                .allowsHitTesting(false)
                                .vfTransition(.opacity)
                        }
                    }
                    .vfAnimation(.easeOut(duration: VFMotion.fast), value: undoFlash)
                if showBottom { bottom }
                if showBom {
                    BomDivider(height: $bomHeight)
                    BomPanel(model: bom, design: model, pcb: pcb) { showBom = false }.frame(height: bomHeight)
                }
                StageStatusBar(leading: statusLine(screen), items: statusItems, coreOK: !EngineGate.shared.shut,
                               trailing: AnyView(bottomToggle), status: screen.status)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // The workspace dropdown at the far left, then the stage's ribbon. Electronics has
                // one ribbon, the board editor's own (with CHECK and 3D groups): the dropdown rides
                // at its left edge instead.
                if workspace == .assemble && assemble.isActive {
                    HStack(spacing: 0) {
                        dropdown(actions)
                        VFHairline(vertical: true)
                        AssembleRibbon(model: assemble, flow: flow, showBottom: { showBottom = true })
                            .vfEngineGate()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .vfSurface(.ribbon)
                    .overlay(alignment: .bottom) { VFHairline() }
                } else if workspace != .electronics {
                    HStack(spacing: 0) {
                        dropdown(actions)
                        VFHairline(vertical: true)
                        StageRibbon(workspace: workspace, model: model, flow: flow, tab: tabBinding, actions: actions, primary: screen.primary,
                                    dialogDocked: showInspector && inspectorMode == .inspector)
                            .vfEngineGate()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .vfSurface(.ribbon)
                    .overlay(alignment: .bottom) { VFHairline() }
                }
            }
            .background(theme.chrome)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { detailWidth = g.size.width }
                    .onChange(of: g.size.width) { _, w in detailWidth = w }
            })
            // Title, toolbar and inspector hang on the detail column, so the toolbar spans the
            // detail and the inspector instead of folding into the inspector's corner.
            .navigationTitle(title)
            .navigationSubtitle(screen.revision.map { "\(workspace.title) · \($0)" } ?? workspace.title)
            .toolbar { toolbar(actions) }
            .inspector(isPresented: $showInspector) {
            Group {
                switch inspectorMode {
                case .inspector:
                    if commandRunning {
                        // The transient command dialog replaces the inspector while it runs.
                        ScrollView { CommandDialog(model: model).padding(VFSpace.l) }
                            .background(theme.panel)
                    } else {
                        InspectorPanel(workspace: workspace, flow: flow, model: model, pcb: pcb, sim: sim, generate: generate, actions: actions,
                                       assemble: assemble.isActive ? assemble : nil, armSim: armSimActive ? armSim : nil,
                                       testInSimulation: { workspace = .simulation })
                    }
                case .library:
                    LibraryView(model: library, design: model, pcb: pcb) { inspectorMode = .inspector }
                }
            }
            .inspectorColumnWidth(min: VFSize.inspectorMin, ideal: inspectorMode == .library ? 380 : VFSize.inspector, max: 560)
            }
        }
        // While the palette or the shortcut sheet is up, VoiceOver and clicks stay on it (P1-16).
        .accessibilityHidden(showPalette || showShortcuts)
        .toastHost(toasts)
        .overlay(alignment: .top) {
            if showPalette {
                ZStack(alignment: .top) {
                    theme.ink.opacity(0.04).ignoresSafeArea().onTapGesture { closePalette() }
                        .accessibilityHidden(true)
                    CommandPalette(flow: flow, workspace: workspace, actions: actions, extras: windowCommands,
                                   runExtra: runWindowCommand, close: closePalette)
                        .accessibilityAddTraits(.isModal)
                        .padding(.top, VFSpace.paletteTop)
                }
            }
        }
        .overlay {
            if showShortcuts {
                ZStack {
                    theme.ink.opacity(0.08).ignoresSafeArea().onTapGesture { showShortcuts = false }
                        .accessibilityHidden(true)
                    ShortcutSheet(workspace: workspace, model: model) { showShortcuts = false }
                        .padding(VFSpace.xxl)
                }
            }
        }
        .background(DeskKeyMonitor(handle: handleKey, urgent: urgentKey))
        .background(ProjectWindowGuard(context: projectContext, edited: ProjectFiles.isEdited(projectContext)))
        .onChange(of: UndoDepth(undo: model.snapshot.undo, redo: model.snapshot.redo)) { old, new in
            let now = model.snapshot.timeline.filter { $0.rolled_back != true }.map(\.name)
            if new.undo == old.undo - 1, new.redo == old.redo + 1 {
                let gone = lastFeatures.last { !now.contains($0) }
                flash(gone.map { String(localized: "Undid \($0)") } ?? String(localized: "Undone. Shift-Command-Z redoes."))
            } else if new.undo == old.undo + 1, new.redo == old.redo - 1, old.redo > 0 {
                let back = now.last { !lastFeatures.contains($0) }
                flash(back.map { String(localized: "Redid \($0)") } ?? String(localized: "Redone. Command-Z undoes."))
            }
            lastFeatures = now
            undoOwner = .stage
        }
        .onChange(of: BomUndoState(canUndo: bom.canUndo, canRedo: bom.canRedo, name: bom.undoName)) { _, _ in
            if showBom { undoOwner = .bom }
        }
        .onChange(of: showBom) { _, open in if !open { undoOwner = .stage } }
        .onChange(of: pcb.revision) { _, _ in undoOwner = .stage }
        .onChange(of: showInspector) { _, v in storedInspector = v }
        .onChange(of: showBottom) { _, v in storedBottom = v }
        .onChange(of: model.toolboxOpen) { _, open in
            // S in the viewport asked for the old toolbox: the palette replaces it.
            if open { showPalette = true; model.toolboxOpen = false }
        }
        .onChange(of: workspace) { _, w in
            pcb.syncLink(model)
            if w == .render { tabs[.render] = "RENDER" }
            storedStage = w.stage
            undoOwner = .stage
        }
        .focusedSceneValue(\.vfDesk, focus(screen, actions))
        .reportsToFlow(flow, design: model, pcb: pcb, generate: generate, sim: sim)
        .projectFilesContext(design: model, pcb: pcb, bom: bom, flow: flow)
        .background(WindowSizer())
        .onAppear(perform: launchHooks)
    }

    private func closePalette() { showPalette = false }

    private var projectContext: ProjectFiles.Context {
        ProjectFiles.Context(design: model, pcb: pcb, bom: bom, flow: flow)
    }

    /// What this window lends the menu bar: every File, Edit, View and Workspace item acts here.
    private func focus(_ screen: StageScreen, _ actions: StageActions) -> DeskFocus {
        var f = DeskFocus(workspace: workspace, open: { workspace = $0 }, search: { showPalette = true },
                          openWorkspaces: { showWorkspaces.toggle() },
                          start: { showStart = true },
                          toggleInspector: { inspectorMode = .inspector; showInspector.toggle() },
                          toggleBottom: { showBottom.toggle() },
                          shortcuts: { showShortcuts.toggle() },
                          primary: primaryAction(screen, actions),
                          updateStale: flow.outputs().contains { $0.status == .stale || $0.status == .failed } ? { actions.updateAll() } : nil)
        f.design = model
        f.undo = undoTarget
        f.stopJob = stopJobAction
        f.toggleSidebar = { columns = columns == .detailOnly ? .all : .detailOnly }
        f.showBom = { showBom.toggle() }
        f.showLibraries = {
            if showInspector && inspectorMode == .library { showInspector = false } else { inspectorMode = .library; showInspector = true }
        }
        f.showFlowGraph = { showGraph.toggle() }
        if StageActions.designLike.contains(workspace) && !(workspace == .assemble && assemble.isActive) {
            f.setView = { model.setView($0) }
            f.zoomToFit = { model.zoomToFit() }
        }
        return f
    }

    /// What Command-Z undoes in this window: the BOM when it was edited last while open, else the
    /// open stage's own document. Stages with nothing to undo answer `.none` (disabled).
    private var undoTarget: UndoTarget {
        if showBom && undoOwner == .bom {
            return UndoTarget(canUndo: bom.canUndo, canRedo: bom.canRedo, undoName: bom.undoName, redoName: bom.redoName,
                              undo: { bom.undo() }, redo: { bom.redo() })
        }
        switch workspace {
        case .assemble where assemble.isActive:
            return UndoTarget(canUndo: assemble.canUndo, canRedo: assemble.canRedo, undoName: assemble.undoName,
                              redoName: assemble.redoName, undo: { assemble.undo() }, redo: { assemble.redo() })
        case .generate:
            return UndoTarget(canUndo: generate.canUndo, canRedo: generate.canRedo, undoName: generate.undoName,
                              redoName: generate.redoName, undo: { generate.undo() }, redo: { generate.redo() })
        case .electronics:
            return UndoTarget(canUndo: pcb.undoCount > 0, canRedo: pcb.redoCount > 0,
                              undo: { pcb.undo() }, redo: { pcb.redo() })
        case .design, .assemble, .render, .make:
            return UndoTarget(canUndo: model.snapshot.undo > 0, canRedo: model.snapshot.redo > 0,
                              undo: { model.undo() }, redo: { model.redo() })
        case .simulation, .train, .robot:
            return .none
        }
    }

    /// Command-. and the Stop buttons: the open stage's own work first (study sampling, arm run,
    /// generative study), else the running job of this stage, else the last job. Nil when idle.
    private var stopJobAction: (() -> Void)? {
        if workspace == .assemble && assemble.isBusy { return { assemble.stopWork() } }
        if workspace == .simulation && armSim.isBusy { return { armSim.stopWork() } }
        if generate.running { return { workspace = .generate; generate.requestStop() } }
        if armSim.isBusy { return { armSim.stopWork() } }
        if assemble.isBusy { return { assemble.stopWork() } }
        guard flow.stoppableJob(stage: workspace.stage) != nil else { return nil }
        return { flow.stopJob(stage: workspace.stage) }
    }

    /// A job or a long solve is running in this window.
    private var jobRunning: Bool { stopJobAction != nil }

    /// Keys taken even while a field is edited: in the Robot stage, Esc twice is the e-stop.
    private func urgentKey(_ e: NSEvent) -> Bool {
        guard workspace == .robot, e.keyCode == 53,
              e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        return safety.escape()
    }

    // MARK: Keys

    /// The stage's main action for Command-Return: the prominent primary of the ribbon.
    private func primaryAction(_ screen: StageScreen, _ actions: StageActions) -> (title: String, run: () -> Void)? {
        guard let p = screen.primary.first(where: \.prominent) ?? screen.primary.first else { return nil }
        guard p.command == "flow.update" || actions.canRun(p.command) else { return nil }
        return (p.label, { if p.command == "flow.update" { actions.update(p.plan) } else { actions.run(p.command) } })
    }

    /// The window's own keys, before the focused view sees them: ? opens the keyboard sheet, and
    /// in the 3D stages every registry letter runs its command whatever has focus. The board and
    /// the flight keep their letters. Answers true when the key was taken.
    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let ch = e.charactersIgnoringModifiers ?? ""
        if showShortcuts {
            if e.keyCode == 53 || ch == "?" { showShortcuts = false; return true }
            return false
        }
        if showPalette { return false }
        if ch == "?" && mods.isSubset(of: [.shift]) { showShortcuts = true; return true }
        // Robot stage: Space, or Esc twice within 0.6 s, is the e-stop (VIAFORM-SPEC 6.4).
        if workspace == .robot, mods.isEmpty {
            if e.keyCode == 49 { safety.stop(source: RobotSafety.StopSource.space.rawValue); return true }
            // Esc twice is handled by `urgentKey`, before this, even from a field.
            if e.keyCode == 53 { return false }
        }
        if workspace == .assemble && assemble.isActive {
            if e.window?.firstResponder is NSTextView { return false }
            if mods.isEmpty {
                switch ch.uppercased() {
                case "T" where assemble.product == .arm: assemble.tab = .motion; assemble.tool = .dragTip; return true
                case "G" where assemble.product == .hand: assemble.tab = .motion; assemble.tool = .grasp; return true
                case "J": assemble.tab = .joints; assemble.tool = .rotateJoint; return true
                default: break
                }
                if e.keyCode == 53, !assemble.ik.dragging, assemble.tool != .select { assemble.tool = .select; return true }
                if e.keyCode == 53, jobRunning { hintStop(); return true }
            }
            return false
        }
        guard StageActions.designLike.contains(workspace), !EngineGate.shared.shut else { return false }
        if mods == .control, let d = Int(ch), let v = DeskKeymap.view(d) { model.setView(v); return true }
        if e.keyCode == 97, mods.isEmpty { model.zoomToFit(); return true }
        let viewportFocused = e.window?.firstResponder is CADView
        // Escape off the viewport: cancel the armed command, else clear the selection. It never
        // stops a job: while one runs, Esc says how to stop it (Command-.) and keeps the selection.
        if e.keyCode == 53, mods.isEmpty, !viewportFocused {
            if model.markingMenu != nil { model.markingMenu = nil }
            else if model.tool != .select || model.genericCommand != nil { model.genericCommand = nil; model.cancelTool() }
            else if jobRunning { hintStop() }
            else { model.selection = []; model.selectedBodies = [] }
            return true
        }
        guard mods.isSubset(of: [.shift]), ch.count == 1 else { return false }
        let letter = ch.uppercased()
        if mods.isEmpty {
            switch letter {
            case "S": showPalette = true; return true
            case "6": model.setView(.iso); return true
            case "K":
                if model.sketchOpen { return false }
                if model.selection.contains(where: \.isFace) { model.sketchOnSelectedFace() } else { model.tool = .sketch }
                return true
            default: break
            }
        }
        let key = mods.contains(.shift) ? "Shift+" + letter : letter
        guard DeskKeymap.isLetterKey(key), let c = DeskKeymap.command(for: key, in: workspace, model: model) else { return false }
        if !c.tab.isEmpty, tabs[workspace] != c.tab, workspace != .assemble { tabs[workspace] = c.tab }
        CommandRouter.run(c, model)
        return true
    }

    private func flash(_ text: String) {
        flashToken += 1
        let token = flashToken
        undoFlash = text
        AccessibilityNotification.Announcement(text).post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if flashToken == token { undoFlash = nil }
        }
    }

    /// Esc while a job runs: Esc keeps the selection and never stops work; say what does.
    private func hintStop() {
        toasts.show(String(localized: "A job is running. Stop it with Command-period."), systemImage: "stop.circle",
                    actionTitle: String(localized: "Stop")) { stopJobAction?() }
    }

    // MARK: Window commands

    /// What the palette reaches beyond the flow catalog: the window's panels, views and sheets.
    private var windowCommands: [FlowModel.Command] {
        func c(_ id: String, _ label: String, _ icon: String, _ key: String? = nil, _ detail: String = "") -> FlowModel.Command {
            FlowModel.Command(id: "window." + id, label: label, stage: "", group: "WINDOW", icon: icon, key: key, source: "window", detail: detail)
        }
        var out = [
            c("inspector", showInspector ? "Hide Inspector" : "Show Inspector", "sidebar.right", "Cmd+Alt+I", "panel"),
            c("sidebar", "Toggle Sidebar", "sidebar.left", "Ctrl+Cmd+S", "browser panel"),
            c("bottom", showBottom ? "Hide Bottom Panel" : "Show Bottom Panel", "rectangle.bottomthird.inset.filled", "Alt+Cmd+B", "timeline history"),
            c("bom", "Bill of Materials", "list.bullet.rectangle", "Shift+Cmd+B", "bom parts cost"),
            c("library", "Libraries", "books.vertical", "Shift+Cmd+L", "parts kicad hardware"),
            c("shortcuts", "Keyboard Shortcuts", "keyboard", "Cmd+/", "keys help"),
            c("next", "Next Stage", "chevron.right", "Cmd+]"),
            c("previous", "Previous Stage", "chevron.left", "Cmd+["),
            c("undo", undoTarget.undoName.map { String(localized: "Undo \($0)") } ?? String(localized: "Undo"), "arrow.uturn.backward", "Cmd+Z"),
            c("redo", undoTarget.redoName.map { String(localized: "Redo \($0)") } ?? String(localized: "Redo"), "arrow.uturn.forward", "Shift+Cmd+Z"),
            c("theme", theme.isDark ? "Light Appearance" : "Dark Appearance", "circle.lefthalf.filled", nil, "theme dark light mode"),
        ]
        if jobRunning { out.append(c("stop", String(localized: "Stop Job"), "stop.fill", "Cmd+.", "cancel stop job run")) }
        if StageActions.designLike.contains(workspace) {
            out.append(c("fit", "Zoom to Fit", "arrow.up.left.and.down.right.magnifyingglass", "F6", "view"))
            for (i, v) in [StandardView.front, .back, .left, .right, .top, .bottom, .iso].enumerated() {
                out.append(c("view." + v.rawValue, (v == .iso ? "Isometric" : v.rawValue.capitalized) + " View", "cube", "Ctrl+\(i + 1)", "camera"))
            }
        }
        return out
    }

    private func runWindowCommand(_ id: String) {
        switch id.dropFirst("window.".count) {
        case "inspector": inspectorMode = .inspector; showInspector.toggle()
        case "sidebar": columns = columns == .detailOnly ? .all : .detailOnly
        case "bottom": showBottom.toggle()
        case "bom": showBom.toggle()
        case "library": inspectorMode = .library; showInspector = true
        case "shortcuts": showShortcuts = true
        case "next": workspace = Workspace.allCases[(workspace.index + 1) % Workspace.allCases.count]
        case "previous": workspace = Workspace.allCases[(workspace.index + Workspace.allCases.count - 1) % Workspace.allCases.count]
        case "undo": if undoTarget.canUndo { undoTarget.undo() }
        case "redo": if undoTarget.canRedo { undoTarget.redo() }
        case "stop": stopJobAction?()
        case "theme": themeMode = theme.isDark ? "light" : "dark"
        case "fit": model.zoomToFit()
        case let v where v.hasPrefix("view."):
            if let sv = StandardView(rawValue: String(v.dropFirst(5))) { model.setView(sv) }
        default: break
        }
    }

    private var commandRunning: Bool {
        StageActions.designLike.contains(workspace) && (model.tool != .select || model.genericCommand != nil)
    }

    /// The embedded study and flight views fold their own side panel when the inspector is open
    /// or the detail column is narrow, so the window never grows past the screen.
    private var embeddedCompact: Bool { showInspector || detailWidth < 1000 }

    /// The toolbar is narrow: icon-only search and jobs.
    private var compactToolbar: Bool { detailWidth < 1150 }

    private func statusLine(_ screen: StageScreen) -> String {
        // The 3D stages name what is picked in the viewport itself ("Face of Middle Distal"),
        // the same words as the selection card, never a stale flow selection.
        if workspace == .assemble && assemble.isActive {
            var parts = [flow.node("assemble.assembly")?.revisionName ?? String(localized: "Assembly"),
                         WorkspaceMenu.inflected("^[\(assemble.joints.count) joint](inflect: true)")]
            if let i = assemble.interference {
                parts.append(i.isEmpty ? String(localized: "No interference")
                                       : WorkspaceMenu.inflected("^[\(i.count) interfering pair](inflect: true)"))
            }
            if assemble.tool == .dragTip {
                parts.append(assemble.ik.reached ? String(localized: "Tip on target")
                                                 : String(localized: "\(VFFormat.length(assemble.ik.shortBy)) out of reach"))
            }
            return parts.joined(separator: " · ")
        }
        if StageActions.designLike.contains(workspace) {
            let size = CGSize(width: max(detailWidth, 1), height: 600)
            if let a = AnchorLayout.anchor(model, size: size) {
                var line = String(localized: "\(a.title) selected")
                if let job = screen.job { line += " · " + job.caption }
                return line
            }
            let stage = flow.stage(workspace)
            var line = stage.map { "\($0.name) \(PipelineWords.describe($0.status))" } ?? workspace.title
            if let job = screen.job { line += " · " + job.caption }
            return line
        }
        // Flow ids carry a kind prefix ("body:Frame"): show the name.
        return screen.statusLine.replacingOccurrences(of: #"\b[a-z]+:"#, with: "", options: .regularExpression)
    }

    private var tabBinding: Binding<String> {
        Binding(get: { tabs[workspace] ?? (workspace == .render ? "RENDER" : (workspace == .assemble ? StageRibbon.assemblyTab : "SOLID")) },
                set: { tabs[workspace] = $0 })
    }

    private var statusItems: [String] {
        switch workspace {
        case .design, .assemble, .render:
            [String(localized: "Units: \(model.snapshot.units)"),
             WorkspaceMenu.inflected("^[\(model.snapshot.bodies.count) body](inflect: true)")]
        case .electronics:
            [WorkspaceMenu.inflected("^[\(pcb.project?.components.count ?? 0) part](inflect: true)"),
             WorkspaceMenu.inflected("^[\(pcb.project?.nets.count ?? 0) net](inflect: true)")]
        default: []
        }
    }

    /// Simulate shows the articulated simulation for an arm assembly.
    private var armSimActive: Bool { assemble.isActive && assemble.product == .arm }

    private var hasBottom: Bool { [.design, .assemble, .electronics, .train, .robot].contains(workspace) }

    private var bottomToggle: some View {
        Button { showBottom.toggle() } label: {
            Image(systemName: showBottom ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomhalf.inset.filled")
                .foregroundStyle(showBottom && hasBottom ? theme.accentText : theme.inkSecondary)
                .frame(minWidth: VFSize.minTarget, minHeight: VFSize.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .vfDisabled(!hasBottom, reason: String(localized: "This stage has no bottom panel."))
        .help(showBottom ? String(localized: "Hide the bottom panel") : String(localized: "Show the bottom panel"))
        .accessibilityLabel(showBottom ? String(localized: "Hide the bottom panel") : String(localized: "Show the bottom panel"))
    }

    // MARK: Stage content

    @ViewBuilder private func content(_ actions: StageActions) -> some View {
        switch workspace {
        case .assemble where assemble.isActive:
            AssembleCanvas(model: assemble)
        case .simulation where armSimActive:
            ArmSimulationView(sim: armSim, assemble: assemble, flow: flow,
                              openGenerate: { workspace = .generate },
                              addLoadCases: { generate.addSimulatedCases($0) })
        case .design, .assemble, .render:
            DesignCanvas(model: model, pcb: pcb, flow: flow, workspace: workspace, actions: actions,
                         dialogInInspector: showInspector && inspectorMode == .inspector)
        case .generate:
            // Compact folds the study's own side panel into a sheet while the inspector is open.
            GenerateView(model: generate, design: model, theme: theme.viewportTheme, compact: embeddedCompact)
        case .electronics:
            DeskPCBView(model: pcb, design: model, embedded: true, hiddenLayers: hiddenLayers,
                        runChecks: { actions.run("electronics.drc") },
                        ribbonLeading: AnyView(dropdown(actions))) { workspace = .assemble }
        case .simulation where flow.isHandProduct:
            // The hand flies nothing: its Simulation stage is the grasp test.
            HandGraspView(generate: generate, design: model, theme: theme.viewportTheme, compact: embeddedCompact)
        case .simulation, .train:
            SimulationView(model: sim, compact: embeddedCompact)
        case .make:
            MakeStage(flow: flow, actions: actions)
        case .robot:
            RobotStage(flow: flow, actions: actions)
        }
    }

    /// The workspace dropdown, sized to the ribbon beside it.
    private func dropdown(_ actions: StageActions) -> some View {
        WorkspaceDropdown(flow: flow, workspace: $workspace, isOpen: $showWorkspaces, showGraph: $showGraph,
                          short: !StageActions.designLike.contains(workspace) && workspace != .electronics,
                          updateAll: { actions.updateAll() })
            .padding(.leading, VFSpace.s)
            .padding(.trailing, VFSpace.xs)
            .vfEngineGate()
    }

    /// The canvas banner of a stale or failed stage, until dismissed for the session.
    @ViewBuilder private func staleBanner(_ actions: StageActions) -> some View {
        if let c = StaleBanner.content(flow, workspace), !dismissedBanners.contains(workspace.stage + "|" + c.text) {
            StaleBanner(flow: flow, workspace: workspace, update: { actions.update($0) },
                        dismiss: { dismissedBanners.insert(workspace.stage + "|" + c.text) })
                .padding(.top, VFSpace.l)
                .padding(.horizontal, VFSpace.bannerInset)
                .vfTransition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var bottom: some View {
        switch workspace {
        case .assemble where assemble.isActive:
            VFHairline()
            MotionStudyPanel(model: assemble)
        case .design, .assemble:
            VFHairline()
            FeatureTimeline(model: model)
        case .electronics:
            VFHairline()
            ElectronicsBottomPanel(pcb: pcb, design: model, flow: flow, hidden: $hiddenLayers, actions: actions)
        case .train:
            VFHairline()
            TrainingCurve(training: sim.training)
        case .robot:
            VFHairline()
            RobotTelemetryPanel()
        default:
            EmptyView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private func toolbar(_ actions: StageActions) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { showData.toggle() } label: { Label("Projects", systemImage: "folder") }
                .help("Projects: designs, samples and recent files")
            let u = undoTarget
            Button { u.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .vfDisabled(!u.canUndo || EngineGate.shared.shut,
                            reason: EngineGate.shared.shut ? EngineGate.reason : String(localized: "Nothing to undo in \(workspace.title)."))
                .help(u.undoName.map { String(localized: "Undo \($0) (Command-Z)") } ?? String(localized: "Undo (Command-Z)"))
            Button { u.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .vfDisabled(!u.canRedo || EngineGate.shared.shut,
                            reason: EngineGate.shared.shut ? EngineGate.reason : String(localized: "Nothing to redo in \(workspace.title)."))
                .help(u.redoName.map { String(localized: "Redo \($0) (Shift-Command-Z)") } ?? String(localized: "Redo (Shift-Command-Z)"))
        }
        // No stage chips in the toolbar (D-10): the principal slot holds the job capsule while a
        // job runs, and nothing otherwise.
        ToolbarItem(placement: .principal) {
            ToolbarJobCapsule(flow: flow)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            CommandSearchField(compact: compactToolbar) { showPalette = true }
            Button { showGraph.toggle() } label: { Label("Flow Graph", systemImage: "point.3.connected.trianglepath.dotted") }
                .help("Show the flow graph: what each stage builds from")
            JobsButton(flow: flow, compact: true)
            Button { showBom.toggle() } label: { Label("BOM", systemImage: "list.bullet.rectangle") }
                .help("Bill of materials (Shift-Command-B)")
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button {
                if showInspector && inspectorMode == .library { showInspector = false } else { inspectorMode = .library; showInspector = true }
            } label: { Label("Libraries", systemImage: "books.vertical") }
                .help("Libraries: KiCad, standard hardware, distributors, saved parts (Shift-Command-L)")
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button {
                if inspectorMode == .library { inspectorMode = .inspector; showInspector = true } else { showInspector.toggle() }
            } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector (Option-Command-I)")
        }
    }

    // MARK: Launch

    private func launchHooks() {
        let args = ProcessInfo.processInfo.arguments
        PerfScript.openWorkspace = { workspace = $0 }
        // Restore the window's layout, launch flags first (screenshots and tests set them).
        if Workspace.fromLaunchArguments() == nil, !storedStage.isEmpty,
           let w = Workspace.allCases.first(where: { $0.stage == storedStage }) { workspace = w }
        if !args.contains("--no-inspector") && !args.contains("--library") { showInspector = storedInspector }
        showBottom = storedBottom
        lastFeatures = model.snapshot.timeline.filter { $0.rolled_back != true }.map(\.name)
        if showBom { bom.applyLaunchFlags(); BomSnapshot.runIfAsked(model: bom, design: model, pcb: pcb) }
        generate.launchHooks(design: model)
        if args.contains("--hand") {
            DeskSampleHand.build(into: model)
            flow.newDocument(product: "Humanoid Hand", graph: "hand")
            // Generate opens the product's own project, not another product's studies.
            if GenerateProject.launchSample == nil, generate.project?.name != "hand" { generate.openSample("hand") }
        }
        if args.contains("--drone") {
            if pcb.project?.components.isEmpty ?? true { pcb.loadSample() }
            DeskSamples.drone(model, pcb: pcb)
            if !args.contains("--flow-sample") { flow.newDocument(product: "Racer 3in") }
            if GenerateProject.launchSample == nil, generate.project?.name != "drone" { generate.openSample("drone") }
        }
        if args.contains("--board") { workspace = .electronics; pcb.sheet = .board }
        if args.contains("--hand") { assemble.openHand(flow: flow) }
        if args.contains("--sample=arm") || args.contains("--arm") {
            model.newDesign()
            flow.newDocument(product: "Desk Arm", graph: "arm")
            assemble.openArm(flow: flow)
        }
        AssembleLaunch.apply(args, assemble: assemble, sim: armSim, flow: flow, open: { workspace = $0 }, showBottom: { showBottom = $0 })
        if args.contains(where: { $0.hasPrefix("--select=") || $0.hasPrefix("--pick-top=") || $0.hasPrefix("--tool=") }) {
            DispatchQueue.main.async { DeskSamples.applySelectionFlags(model) }
        }
        if args.contains("--library") { inspectorMode = .library; showInspector = true }
        if let q = args.first(where: { $0.hasPrefix("--library=") })?.dropFirst(10) {
            inspectorMode = .library
            showInspector = true
            library.query = String(q)
            Task { await library.search() }
        }
        if let arg = args.first(where: { $0.hasPrefix("--project-roundtrip=") }) {
            // Check for the docs and the review: save the open project as a .viaform, start a
            // new design, open the file again, and print the pipeline before and after.
            let url = URL(fileURLWithPath: String(arg.dropFirst("--project-roundtrip=".count)))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let c = ProjectFiles.Context(design: model, pcb: pcb, bom: bom, flow: flow)
                let before = flow.nodes.map { "\($0.id)=\($0.revision)" }.joined(separator: " ")
                let saved = await ProjectFiles.save(url, in: c)
                ProjectFiles.newDesign(model, in: c)
                let fresh = flow.nodes.map { "\($0.id)=\($0.revision)" }.joined(separator: " ")
                await ProjectFiles.open(url, in: c)
                let after = flow.nodes.map { "\($0.id)=\($0.revision)" }.joined(separator: " ")
                print("roundtrip saved=\(saved)\n before: \(before)\n new:    \(fresh)\n after:  \(after)\n product: \(flow.product) key: \(flow.documentKey ?? "-")")
                print("roundtrip \(before == after && saved ? "PASSED" : "FAILED")")
                fflush(stdout)
            }
        }
        if args.contains("--show-palette") { showPalette = true }
        if args.contains("--show-marking") { model.markingMenu = CGPoint(x: 620, y: 300) }
        if args.contains("--show-data") { showData = true }
        if args.contains("--show-flow-card") || args.contains("--show-flow-graph") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showGraph = true }
        }
        if showWorkspaces {
            // The popover needs its anchor on screen: open it once the window has laid out.
            showWorkspaces = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showWorkspaces = true }
        }
        if args.contains("--no-sidebar") { columns = .detailOnly }
        if args.contains("--pcb-3d") {
            model.newDesign()
            model.run("solid.box", ["length": 80, "width": 60, "height": 12, "corner": [-10, -50, 0], "body_name": "Enclosure"])
            pcb.sendTo3D(model)
            PCBLink.mount(pcb, in: model, body: "Enclosure", at: [30, -20, 12], normal: [0, 0, 1])
            model.setView(.iso)
            model.zoomToFit()
        }
    }
}

/// The command search in the toolbar: a field-looking button that opens the palette.
struct CommandSearchField: View {
    @Environment(\.viaFormTheme) private var theme
    var compact = false
    var open: () -> Void

    var body: some View {
        if compact {
            Button(action: open) { Label("Search Commands", systemImage: "magnifyingglass") }
                .help("Search the commands of every stage (Command-K)")
        } else {
            field
        }
    }

    private var field: some View {
        Button(action: open) {
            HStack(spacing: VFSpace.s) {
                Image(systemName: "magnifyingglass")
                Text("Search commands").lineLimit(1)
                Spacer(minLength: VFSpace.s)
                Text("⌘K").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
            }
            .font(VFFont.row)
            .foregroundStyle(theme.inkSecondary)
            .padding(.horizontal, VFSpace.m)
            .frame(width: 180, height: VFSize.buttonHeight)
            .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.well))
            .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search the commands of every stage (Command-K)")
    }
}

/// The undo and redo depths, watched together to tell an undo from a new edit.
struct UndoDepth: Equatable {
    var undo: Int
    var redo: Int
}

/// The BOM's undo state, watched to know the BOM was edited last.
struct BomUndoState: Equatable {
    var canUndo: Bool
    var canRedo: Bool
    var name: String?
}

/// The drag handle above the BOM panel: drag to resize between 200 pt and 720 pt, double-click
/// for the default height. The height is kept with the window (P1-18).
struct BomDivider: View {
    @Environment(\.viaFormTheme) private var theme
    @Binding var height: Double
    @State private var start: Double?
    @State private var hovered = false

    var body: some View {
        ZStack {
            Rectangle().fill(hovered ? theme.accent.opacity(0.5) : theme.hairline).frame(height: hovered ? 2 : 1)
        }
        .frame(height: 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { h in
            hovered = h
            if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { v in
                let s = start ?? height
                start = s
                height = min(720, max(200, s - v.translation.height))
            }
            .onEnded { _ in start = nil })
        .onTapGesture(count: 2) { height = 360 }
        .accessibilityElement()
        .accessibilityLabel("Bill of materials height")
        .accessibilityValue(Text("\(Int(height)) points"))
        .accessibilityAdjustableAction { d in
            height = min(720, max(200, height + (d == .increment ? 40 : -40)))
        }
    }
}

/// `--window-size=1440x900` sizes the window in points at launch (screenshots, layout checks).
struct WindowSizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--window-size=") }),
                  let window = v.window else { return }
            let parts = arg.dropFirst("--window-size=".count).split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            let top = window.screen?.visibleFrame.maxY ?? 900
            if parts[1] > (window.screen?.visibleFrame.height ?? 0) { Self.unconstrain(window) }
            window.setFrame(NSRect(x: 0, y: top - parts[1], width: parts[0], height: parts[1]), display: true)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Lets a window taller than the screen keep its size (a 2560 x 1440 capture on a laptop):
    /// the window's class answers the frame constraint with the frame unchanged. Only ever
    /// done under --window-size; the class is the one in use (a KVO subclass included).
    private static func unconstrain(_ window: NSWindow) {
        guard let cls = object_getClass(window) else { return }
        let sel = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        let keep: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { _, r, _ in r }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(keep), method_getTypeEncoding(m))
    }
}
#endif
