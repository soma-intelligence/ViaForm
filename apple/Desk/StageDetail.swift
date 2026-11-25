#if os(macOS)
import AppKit
import Charts
import SwiftUI

/// The 3D workspace of Design, Assemble and Render: the Metal viewport on the theme's gradient,
/// the view cube with its home button (top right), the transient command dialog under it, the
/// axis triad (bottom left), the navigation pill (bottom centre), the stage's running job, the
/// right-click marking menu and the board link banner.
struct DesignCanvas: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: DesignModel
    let pcb: PCBModel
    let flow: FlowModel
    let workspace: Workspace
    let actions: StageActions
    /// The running command's dialog sits in the inspector column (it replaces the inspector
    /// while the command runs); with the inspector hidden it floats under the view cube.
    var dialogInInspector = false
    /// The navigation bar's mode (Orbit, Pan, Zoom, Zoom Window, Look At): while one is on, a
    /// left drag on the canvas drives it through the overlay above the viewport.
    @State private var navMode: NavMode?
    /// Fusion's canvas chrome (browser top left, COMMENTS and status along the bottom); nil
    /// keeps the older ViaForm canvas.
    var fusion: FusionCanvasChrome?

    var body: some View {
        if let fusion { fusionBody(fusion) } else { classicBody }
    }

    /// Fusion's canvas (1.1): BROWSER top left, ViewCube top right with the command dialog or the
    /// Sketch Palette under it, COMMENTS, the navigation bar and the status text along the bottom.
    private func fusionBody(_ chrome: FusionCanvasChrome) -> some View {
        ZStack {
            Viewport(model: model, theme: theme.fusionViewport, sketchStatus: false)
                .id(theme.isDark)
            if navMode != nil {
                NavModeOverlay(model: model, mode: $navMode)
            }
            DesignAnchorOverlay(model: model, workspace: workspace, actions: actions, pcb: pcb, fusion: true)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: VFSpace.m) {
                    if let b = chrome.browser { b }
                    Spacer(minLength: 0)
                    if let job = flow.queue.on(stage: workspace.stage) {
                        JobCapsule(job: job,
                                   pause: { flow.pause(job: job.id) },
                                   resume: { flow.resume(job: job.id) },
                                   cancel: { flow.cancel(job: job.id) })
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .trailing, spacing: VFSpace.m) {
                        ViewCube(model: model, size: FusionTokens.cube,
                                 faceColor: theme.isDark ? Color(white: 0.30) : Color(white: 0.98),
                                 edgeColor: theme.isDark ? Color(white: 0.62) : Color(white: 0.62),
                                 textColor: theme.isDark ? Color(white: 0.88) : Color(white: 0.35),
                                 hoverColor: theme.fusion.blue)
                            .padding(.top, VFSpace.s)
                        if model.genericCommand != nil || (model.tool != .select && !model.tool.isSketchTool && model.tool != .sketch) {
                            CommandDialog(model: model).frame(width: FusionTokens.dialogWidth)
                                .vfTransition(.move(edge: .trailing).combined(with: .opacity))
                        } else if model.sketchOpen {
                            SketchPalette(model: model, fusion: true).frame(width: FusionTokens.paletteWidth)
                                .vfTransition(.move(edge: .trailing).combined(with: .opacity))
                        } else if model.tool == .sketch {
                            CommandDialog(model: model).frame(width: FusionTokens.dialogWidth)
                        }
                    }
                }
                Spacer(minLength: 0)
                PCBLinkBanner(design: model, pcb: pcb)
                if let m = model.message, model.messageIsError || toasts == nil {
                    ErrorBanner(message: m, severity: model.messageIsError ? .error : .warning, dismiss: { model.flash(nil) })
                }
                ZStack {
                    HStack(spacing: 0) {
                        FusionCommentsBar()
                        Spacer(minLength: VFSpace.m)
                        FusionStatusText(text: chrome.status, model: model)
                    }
                    NavPill(model: model, mode: $navMode, fusion: true)
                }
            }
            .padding(.horizontal, VFSpace.xs)
            .padding(.vertical, VFSpace.xs)
            .vfAnimation(.easeOut(duration: VFMotion.standard), value: model.tool != .select || model.genericCommand != nil)
            if let at = model.markingMenu { MarkingMenu(model: model, at: at) }
        }
        .background(theme.fusion.canvas)
        .onChange(of: model.message) { _, m in
            guard let m, !model.messageIsError, let toasts else { return }
            toasts.show(m)
            model.flash(nil)
        }
    }

    private var classicBody: some View {
        ZStack {
            Viewport(model: model, theme: theme.viewportTheme, sketchStatus: false)
                .id(theme.isDark)
            if navMode != nil {
                NavModeOverlay(model: model, mode: $navMode)
            }
            // The selection's context pill, or the armed tool's gizmo and value badge.
            DesignAnchorOverlay(model: model, workspace: workspace, actions: actions, pcb: pcb)
            VStack(spacing: VFSpace.m) {
                HStack(alignment: .top) {
                    if let job = flow.queue.on(stage: workspace.stage) {
                        Spacer()
                        JobCapsule(job: job,
                                   pause: { flow.pause(job: job.id) },
                                   resume: { flow.resume(job: job.id) },
                                   cancel: { flow.cancel(job: job.id) })
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: VFSpace.m) {
                        // The cube carries its own home button.
                        HStack(alignment: .top, spacing: VFSpace.xs) {
                            ViewCube(model: model, size: 92,
                                     faceColor: theme.isDark ? Color(white: 0.30) : Color(white: 0.97),
                                     edgeColor: theme.isDark ? Color(white: 0.62) : Color(white: 0.55),
                                     textColor: theme.isDark ? Color(white: 0.88) : Color(white: 0.28),
                                     hoverColor: theme.accent)
                        }
                        if !dialogInInspector, model.tool != .select || model.genericCommand != nil {
                            CommandDialog(model: model).frame(width: 300)
                                .vfTransition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                Spacer()
                PCBLinkBanner(design: model, pcb: pcb)
                // Errors stay until dismissed; confirmations go to a toast (below).
                if let m = model.message, model.messageIsError || toasts == nil {
                    ErrorBanner(message: m, severity: model.messageIsError ? .error : .warning, dismiss: { model.flash(nil) })
                }
                HStack(alignment: .bottom) {
                    AxisTriad(camera: model.camera)
                    Spacer()
                    NavPill(model: model, mode: $navMode)
                    Spacer()
                    Color.clear.frame(width: 78, height: 1)
                }
            }
            .padding(VFSpace.overlayInset)
            .vfAnimation(.easeOut(duration: VFMotion.standard), value: model.tool != .select || model.genericCommand != nil)
            if let at = model.markingMenu { MarkingMenu(model: model, at: at) }
        }
        .onChange(of: model.message) { _, m in
            guard let m, !model.messageIsError, let toasts else { return }
            toasts.show(m)
            model.flash(nil)
        }
    }
}

/// Orbit, pan, zoom, fit, look at, the standard views and the visual style, in a floating pill.
/// Orbit, Pan and Zoom are modes (a left drag on the canvas drives them until Esc); Zoom's menu
/// holds Zoom Window; Look At turns to the selected face, or waits for a click on one.
struct NavPill: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    @Binding var mode: NavMode?
    /// Fusion's navigation bar: small grey icons on a light strip, menus marked with a small ▾.
    var fusion = false

    private var perspective: Binding<Bool> {
        Binding(get: { model.camera.fov > 0 }, set: { p in model.camera.fov = p ? 0.7 : 0; model.cameraChanged(final: true) })
    }

    var body: some View {
        if fusion { fusionBar } else { pill }
    }

    /// Left to right as in the reference (1.7): Orbit ▾, Look At, Pan, Zoom, Fit ▾, Display
    /// Settings ▾, Grid and Snaps ▾, Viewports ▾.
    private var fusionBar: some View {
        let f = theme.fusion
        return HStack(spacing: 3) {
            HStack(spacing: 0) {
                modeItem(.orbit, "rotate.3d", "Orbit (drag to turn; also Shift and middle drag)")
                Menu {
                    Button("Free Orbit") { toggle(.orbit) }
                } label: { tri }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Orbit options")
            }
            VFIconButton("viewfinder", label: String(localized: "Look At"), size: 11, isOn: mode == .lookAt) { lookAt() }
            modeItem(.pan, "hand.raised", "Pan (drag to move; also middle drag)")
            modeItem(.zoom, "plus.magnifyingglass", "Zoom (drag up or down)")
            HStack(spacing: 0) {
                item("arrow.up.left.and.down.right.magnifyingglass", "Fit") { model.zoomToFit() }
                Menu {
                    Button("Zoom Window") { toggle(.zoomWindow) }
                    Button("Fit") { model.zoomToFit() }
                } label: { tri }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Zoom options")
            }
            Rectangle().fill(f.line).frame(width: 1, height: 12)
            Menu {
                Menu("Visual Style") {
                    Button("Shaded") { model.run("view.visual_style", ["style": "shaded"], quiet: true) }
                    Button("Shaded with Visible Edges Only") { model.run("view.visual_style", ["style": "shaded_with_edges"], quiet: true) }
                    Button("Wireframe") { model.run("view.visual_style", ["style": "wireframe"], quiet: true) }
                }
                Menu("Camera") {
                    Toggle("Perspective", isOn: perspective)
                    ForEach(StandardView.allCases, id: \.self) { v in Button(v.rawValue.capitalized) { model.setView(v) } }
                }
            } label: { glyph("display") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Display Settings").accessibilityLabel("Display Settings")
            Menu {
                Button("Layout Grid") { model.run("view.grid", quiet: true) }
            } label: { glyph("squareshape.split.3x3") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Grid and Snaps").accessibilityLabel("Grid and Snaps")
        }
        .foregroundStyle(f.inkSoft)
        .padding(.horizontal, VFSpace.s)
        .frame(height: FusionTokens.bottomBar + 2)
        .background(RoundedRectangle(cornerRadius: 2).fill(f.surface.opacity(0.85)))
    }

    private var tri: some View {
        Image(systemName: "arrowtriangle.down.fill").font(VFFont.glyph(5)).frame(width: 7, height: 16)
    }

    private func glyph(_ symbol: String) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol).font(VFFont.glyph(11))
            Image(systemName: "arrowtriangle.down.fill").font(VFFont.glyph(5))
        }
        .frame(height: 16)
    }

    private var pill: some View {
        HStack(spacing: 2) {
            modeItem(.orbit, "rotate.3d", "Orbit (drag to turn; also right drag or Option drag)")
            modeItem(.pan, "hand.raised", "Pan (drag to move; also middle drag or two fingers)")
            modeItem(.zoom, "plus.magnifyingglass", "Zoom (drag up or down)")
            Menu {
                Button("Zoom") { toggle(.zoom) }
                Button("Zoom Window") { toggle(.zoomWindow) }
                Divider()
                Button("Zoom In") { model.camera.zoom(1.25); model.cameraChanged(final: true) }
                Button("Zoom Out") { model.camera.zoom(0.8); model.cameraChanged(final: true) }
            } label: { Label("Zoom options", systemImage: "chevron.down").labelStyle(.iconOnly) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(minWidth: 18)
            .help("Zoom options")
            .accessibilityLabel("Zoom options")
            item("arrow.up.left.and.down.right.magnifyingglass", "Fit") { model.zoomToFit() }
            VFHairline(vertical: true).frame(height: 18)
            VFIconButton("viewfinder", label: String(localized: "Look At"), size: 13, isOn: mode == .lookAt) { lookAt() }
            Menu {
                Toggle("Perspective", isOn: perspective)
                ForEach(StandardView.allCases, id: \.self) { v in Button(v.rawValue.capitalized) { model.setView(v) } }
            } label: { Label("Views", systemImage: "cube.transparent").labelStyle(.iconOnly) }
            .menuStyle(.borderlessButton).fixedSize().frame(minWidth: 34)
            .help("Views")
            .accessibilityLabel("Views")
            Menu {
                Button("Shaded with Edges") { model.run("view.visual_style", ["style": "shaded_with_edges"], quiet: true) }
                Button("Shaded") { model.run("view.visual_style", ["style": "shaded"], quiet: true) }
                Button("Wireframe") { model.run("view.visual_style", ["style": "wireframe"], quiet: true) }
                Divider()
                Button("Toggle Grid") { model.run("view.grid", quiet: true) }
            } label: { Label("Visual Style", systemImage: "square.grid.3x3.square").labelStyle(.iconOnly) }
            .menuStyle(.borderlessButton).fixedSize().frame(minWidth: 34)
            .help("Visual style")
            .accessibilityLabel("Visual style")
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, VFSpace.m)
        .frame(minHeight: 36)
        .vfSurface(.control, radius: VFRadius.touchCapsule)
    }

    private func toggle(_ m: NavMode) { mode = mode == m ? nil : m }

    /// Look At the selected planar face (through `view.normal_to`), the open sketch's plane,
    /// or, with nothing to look at, wait for a click on a face.
    private func lookAt() {
        if mode == .lookAt { mode = nil; return }
        if case let .face(mi, _, pt, n)? = model.selection.first(where: \.isFace), model.scene.meshes.indices.contains(mi) {
            NavCamera.lookAt(model, body: model.scene.meshes[mi].body, point: pt, normal: n)
        } else if let pl = model.sketchPlane {
            model.look(along: pl.normal)
        } else {
            mode = .lookAt
        }
    }

    private func modeItem(_ m: NavMode, _ symbol: String, _ help: LocalizedStringResource) -> some View {
        VFIconButton(symbol, label: String(localized: help), size: 13, isOn: mode == m) { toggle(m) }
            .accessibilityAddTraits(mode == m ? .isSelected : [])
    }

    private func item(_ symbol: String, _ help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        VFIconButton(symbol, label: String(localized: help), size: 13, action: action)
    }
}

/// The Design timeline: every feature on a connected rail, built ones on a solid accent rail,
/// rolled back ones faded on a dashed rail after the playhead. The playhead is the history
/// marker: click a feature to roll to it, drag the playhead back to roll back. Command or Shift
/// click picks several; a slow second click renames; a double-click opens Edit Feature. Drag a
/// feature to reorder it (a refused move says why). Right-click for Edit Feature, Rename, Roll
/// History Marker Here, Find in Browser, Show Dependents, Create Group, Suppress and Delete.
/// Folders (feature groups) draw a tile that collapses their features into it. Failed features
/// are red, features with a warning (a lost reference) yellow, suppressed ones dashed.
struct FeatureTimeline: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    /// One feature icon per slot, side by side as in Fusion's timeline strip.
    private static let pitch: CGFloat = 22

    @State private var editing: FeatureEditRequest?
    @State private var folders: [TimelineFolder] = []
    /// Sketch defined states for the tiles (M-11), from the shared per-revision outline.
    @State private var sketchStates: [Int: SketchDefinedState] = [:]
    @State private var collapsed: Set<Int> = []
    /// Picked feature ids (Command or Shift click), for Create Group.
    @State private var picked: Set<Int> = []
    @State private var anchor: Int?
    /// Features the marking menu's Find in Timeline asked to show, highlighted until the next click.
    @State private var revealed: Set<Int> = []
    @State private var lastClick: (id: Int, at: Date)?
    /// The feature (positive id) or folder (negative id) being renamed, and its draft name.
    @State private var renaming: Int?
    @State private var draft = ""
    @State private var renameError: String?
    @State private var dependentsOf: Int?
    @State private var dependents: (deleted: [String], failing: [String]) = ([], [])

    var body: some View {
        content
            .sheet(item: $editing) { r in EditFeatureSheet(model: model, feature: r.feature) }
            .task(id: model.snapshot.revision) {
                let d = DesignOutlineCache.shared.data(model)
                folders = d.folders
                sketchStates = d.sketchStates
            }
    }

    /// The one way into Edit Feature (menu, double-click, VoiceOver): the feature's own dialog,
    /// or the generic sheet when it has none.
    private func editFeature(_ f: DesignSnapshot.Feature) {
        FeatureEditor.edit(model, feature: f.name) { editing = FeatureEditRequest(feature: f.name) }
    }

    /// Fusion's timeline strip (1.8): |< < > >| at the left, the feature icons in order with the
    /// marker after the last built one, the settings gear at the far right.
    @ViewBuilder private var content: some View {
        let s = model.snapshot
        let f = theme.fusion
        HStack(spacing: VFSpace.m) {
            HStack(spacing: 0) {
                control("backward.end.fill", "Go to the start") { model.rollTimeline(to: 0) }
                    .vfDisabled(s.marker == 0, reason: String(localized: "Already at the start"))
                control("backward.frame.fill", "Step back") { model.rollTimeline(to: max(0, s.marker - 1)) }
                    .vfDisabled(s.marker == 0, reason: String(localized: "Already at the start"))
                control("play.fill", "Play") { model.run("timeline.play", quiet: true) }
                control("forward.frame.fill", "Step forward") { model.rollTimeline(to: min(s.timeline.count, s.marker + 1)) }
                    .vfDisabled(s.marker >= s.timeline.count, reason: String(localized: "Already at the end"))
                control("forward.end.fill", "Go to the end") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
                    .vfDisabled(s.marker >= s.timeline.count, reason: String(localized: "Already at the end"))
            }
            let layout = TimelineLayout(features: s.timeline, folders: folders, collapsed: collapsed)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    rail(s, layout).padding(.horizontal, VFSpace.xs)
                }
                // Keep the marker in view: at the end, scroll to the room after the last icon.
                .onAppear { proxy.scrollTo(layout.scrollKey(marker: s.marker, count: s.timeline.count), anchor: .center) }
                .onChange(of: s.marker) { _, m in
                    vfWithAnimation(.easeOut(duration: VFMotion.fast)) { proxy.scrollTo(layout.scrollKey(marker: m, count: s.timeline.count), anchor: .center) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .vfRevealInTimeline)) { n in
                    guard (n.object as? DesignModel) === model else { return }
                    revealInTimeline(n.userInfo?["bodies"] as? [String] ?? [], proxy)
                }
            }
            Menu {
                Button("Compute All") { model.run("timeline.compute_all") }
                Button("Roll to the End") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
            } label: {
                Image(systemName: "gearshape.fill").font(VFFont.glyph(12)).foregroundStyle(f.inkSoft)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Timeline settings")
            .accessibilityLabel("Timeline settings")
        }
        .padding(.horizontal, VFSpace.s)
        .frame(height: FusionTokens.timeline)
        .background(f.surface)
        .overlay(alignment: .top) { Rectangle().fill(f.lineSoft).frame(height: 1) }
    }

    private func rail(_ s: DesignSnapshot, _ layout: TimelineLayout) -> some View {
        let count = s.timeline.count
        let marker = min(s.marker, count)
        let width = CGFloat(layout.slots.count) * Self.pitch
        let xm = layout.markerX(marker, pitch: Self.pitch)
        return ZStack(alignment: .topLeading) {
            // The rail behind the tiles: solid up to the playhead, dashed after it; a bracket
            // over each open folder's features.
            Canvas { ctx, _ in
                _ = xm
                for (k, slot) in layout.slots.enumerated() {
                    guard case let .folder(_, range, false) = slot, let last = layout.slotOf[range.upperBound] else { continue }
                    var p = Path()
                    let a = CGFloat(k) * Self.pitch + Self.pitch / 2, b = CGFloat(last + 1) * Self.pitch - 4
                    p.move(to: CGPoint(x: a, y: 0)); p.addLine(to: CGPoint(x: b, y: 0)); p.addLine(to: CGPoint(x: b, y: 4))
                    ctx.stroke(p, with: .color(theme.inkTertiary), lineWidth: 1)
                }
            }
            .frame(width: width, height: 24)
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                ForEach(Array(layout.slots.enumerated()), id: \.element.key) { _, slot in
                    switch slot {
                    case let .feature(i):
                        tile(s.timeline[i], index: i, built: i < marker, features: s.timeline).id(slot.key)
                    case let .folder(f, range, shut):
                        folderTile(f, range: range, collapsed: shut, features: s.timeline, marker: marker).id(slot.key)
                    }
                }
                // Room after the last tile, so the playhead at the end is never cut.
                Color.clear.frame(width: 24, height: 1).id(AnyHashable("end"))
            }
            playhead(marker: marker, count: count, layout: layout)
        }
        .frame(width: width + 24, height: 30, alignment: .topLeading)
    }

    // MARK: Tiles

    private func tile(_ f: DesignSnapshot.Feature, index i: Int, built: Bool, features: [DesignSnapshot.Feature]) -> some View {
        let failed = f.error != nil
        let warned = !failed && f.warning != nil
        let suppressed = f.suppressed ?? false
        let isPicked = (picked.contains(f.id) && picked.count > 1) || revealed.contains(f.id)
        let tint = failed ? theme.danger : (warned ? theme.warning : (suppressed ? theme.inkTertiary : (built ? theme.ink : theme.inkTertiary)))
        let fill = failed ? theme.danger.opacity(0.16) : (warned ? theme.warning.opacity(0.16) : (isPicked ? theme.accent.opacity(0.18) : (built ? theme.panel : theme.chrome)))
        let stroke = failed ? theme.danger : (warned ? theme.warning : (isPicked ? theme.accent : (built ? theme.accent.opacity(0.55) : theme.hairline)))
        let ft = theme.fusion
        let face = VStack(spacing: 0) {
            // The feature's own icon (Extrude, Fillet...) as an SF Symbol, tinted by its state.
            Image(systemName: FeatureSymbol.of(f.type))
                .font(VFFont.glyph(12))
                .foregroundStyle(failed || warned || suppressed ? tint : (built ? ft.iconTint : ft.inkFaint))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 2).fill(failed || warned || isPicked ? fill : .clear))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(failed || warned || isPicked || suppressed ? stroke : .clear,
                                  style: StrokeStyle(lineWidth: 1, dash: suppressed ? [2, 2] : [])))
                .overlay(alignment: .topTrailing) {
                    // M-11: a sketch tile carries its defined state (lock when fully defined).
                    if let st = SketchDefinedStates.state(model, feature: f, in: sketchStates), st.fullyConstrained || st.overConstrained {
                        Image(systemName: st.symbol)
                            .font(VFFont.glyph(7, weight: .bold))
                            .foregroundStyle(st.overConstrained ? theme.danger : theme.inkSecondary)
                            .offset(x: 3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
        }
        .frame(width: Self.pitch, height: 30)
        .opacity(built ? 1 : 0.5)
        .contentShape(Rectangle())
        .help(Self.describe(f, built: built))
        return tileActions(face, f, index: i, built: built, suppressed: suppressed, features: features)
    }

    private func tileActions(_ face: some View, _ f: DesignSnapshot.Feature, index i: Int, built: Bool, suppressed: Bool,
                             features: [DesignSnapshot.Feature]) -> some View {
        face
        // A double-click opens Edit Feature; a single click rolls to the feature and picks it
        // (Command toggles, Shift extends); a slow second click on it renames it.
        .onTapGesture(count: 2) { editFeature(f) }
        .onTapGesture { click(f, index: i, features: features) }
        .popover(isPresented: renameBinding(f.id), arrowEdge: .top) { renameField(String(localized: "Feature name")) }
        .popover(isPresented: dependentsBinding(f.id), arrowEdge: .top) { dependentsPopover(f) }
        // VoiceOver: one button per feature with its state; the menu's commands as actions, and
        // Move Earlier or Later as the drag's equivalent.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Feature \(i + 1), \(f.name)"))
        .accessibilityValue(Text(Self.state(f, built: built)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Rolls the history marker to this feature")
        .accessibilityAction { model.rollTimeline(to: i + 1) }
        .accessibilityAction(named: Text("Edit Feature")) { editFeature(f) }
        .accessibilityAction(named: Text("Rename")) { startRename(f.id, f.name) }
        .accessibilityAction(named: Text("Move Earlier")) { if i > 0 { reorder(f.name, to: i - 1) } }
        .accessibilityAction(named: Text("Move Later")) { reorder(f.name, to: i + 1) }
        .accessibilityAction(named: suppressed ? Text("Unsuppress") : Text("Suppress")) { model.run("timeline.suppress", ["feature": f.id]) }
        .accessibilityAction(named: Text("Delete")) { model.run("timeline.delete", ["feature": f.id]) }
        .draggable(f.name)
        .dropDestination(for: String.self) { names, _ in
            guard let n = names.first, n != f.name else { return false }
            reorder(n, to: i)
            return true
        }
        .contextMenu { tileMenu(f, index: i, suppressed: suppressed, features: features) }
    }

    @ViewBuilder private func tileMenu(_ f: DesignSnapshot.Feature, index i: Int, suppressed: Bool, features: [DesignSnapshot.Feature]) -> some View {
        Button("Edit Feature") { editFeature(f) }
        if f.type.lowercased() == "sketch", let sk = FeatureEditor.sketchID(model, feature: f.name) {
            SketchTileMenuItems(model: model, sketch: sk)
        }
        Button("Rename") { startRename(f.id, f.name) }
        Button("Roll History Marker Here") { model.rollTimeline(to: i + 1) }
        Button("Find in Browser") { BrowserReveal.shared.reveal(f, in: model) }
        Button("Show Dependents") { showDependents(f) }
        Divider()
        let group = picked.contains(f.id) ? features.filter { picked.contains($0.id) }.map(\.id) : [f.id]
        Button(group.count > 1 ? String(localized: "Create Group of \(group.count) Features") : String(localized: "Create Group")) {
            createGroup(group)
        }
        Button(suppressed ? "Unsuppress" : "Suppress") { model.run("timeline.suppress", ["feature": f.id]) }
        Divider()
        Button("Move Earlier") { reorder(f.name, to: i - 1) }
            .vfDisabled(i == 0, reason: String(localized: "Already the first feature"))
        Button("Move Later") { reorder(f.name, to: i + 1) }
        Divider()
        Button("Delete", role: .destructive) { model.run("timeline.delete", ["feature": f.id]) }
    }

    /// A folder's tile: click opens or collapses it. Collapsed, it takes its features' state
    /// (red when one failed, yellow when one has a warning).
    private func folderTile(_ g: TimelineFolder, range: ClosedRange<Int>, collapsed shut: Bool,
                            features: [DesignSnapshot.Feature], marker: Int) -> some View {
        let members = range.map { features[$0] }
        let failed = members.contains { $0.error != nil }
        let warned = !failed && members.contains { $0.warning != nil }
        let built = range.lowerBound < marker
        let tint = failed ? theme.danger : (warned ? theme.warning : (built ? theme.ink : theme.inkTertiary))
        return VStack(spacing: 0) {
            Image(systemName: shut ? "folder.fill" : "folder")
                .font(VFFont.glyph(12))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 2)
                    .fill(failed ? theme.danger.opacity(0.16) : (warned ? theme.warning.opacity(0.16) : .clear)))
                .overlay(alignment: .bottom) {
                    if shut { Image(systemName: "plus").font(VFFont.glyph(6, weight: .bold)).foregroundStyle(theme.fusion.inkSoft).offset(y: 7) }
                }
        }
        .frame(width: Self.pitch, height: 30)
        .opacity(built ? 1 : 0.5)
        .contentShape(Rectangle())
        .help(String(localized: "\(g.name): \(members.count) features. Click to \(shut ? String(localized: "open") : String(localized: "collapse")) it."))
        .onTapGesture(count: 2) { startRename(-g.id, g.name) }
        .onTapGesture { toggleFolder(g.id) }
        .popover(isPresented: renameBinding(-g.id), arrowEdge: .top) { renameField(String(localized: "Group name")) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Group \(g.name), \(members.count) features"))
        .accessibilityValue(shut ? Text("Collapsed") : Text("Expanded"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleFolder(g.id) }
        .accessibilityAction(named: Text("Rename Group")) { startRename(-g.id, g.name) }
        .accessibilityAction(named: Text("Ungroup")) { model.run("timeline.ungroup", ["group": g.id]) }
        .contextMenu {
            Button(shut ? "Expand Group" : "Collapse Group") { toggleFolder(g.id) }
            Button("Rename Group") { startRename(-g.id, g.name) }
            Button("Roll History Marker After Group") { model.rollTimeline(to: range.upperBound + 1) }
            Button("Suppress Group") { model.run("timeline.suppress", ["groups": [g.id]]) }
            Divider()
            Button("Ungroup") { model.run("timeline.ungroup", ["group": g.id]) }
            Button("Delete Group and Features", role: .destructive) { model.run("timeline.delete", ["groups": [g.id]]) }
        }
    }

    // MARK: Actions

    private func click(_ f: DesignSnapshot.Feature, index i: Int, features: [DesignSnapshot.Feature]) {
        let mods = NSEvent.modifierFlags
        revealed = []
        if mods.contains(.command) {
            if picked.contains(f.id) { picked.remove(f.id) } else { picked.insert(f.id) }
            anchor = f.id
            return
        }
        if mods.contains(.shift), let a = anchor, let ai = features.firstIndex(where: { $0.id == a }) {
            picked = Set(features[min(ai, i)...max(ai, i)].map(\.id))
            return
        }
        // A slow second click on the one picked feature renames it (as in Finder).
        if picked == [f.id], let last = lastClick, last.id == f.id, Date().timeIntervalSince(last.at) > 0.5 {
            lastClick = nil
            startRename(f.id, f.name)
            return
        }
        picked = [f.id]
        anchor = f.id
        lastClick = (f.id, Date())
        model.rollTimeline(to: i + 1)
    }

    /// Find in Timeline: the features that made these bodies are highlighted, their folders
    /// opened, and the first one scrolled into view.
    private func revealInTimeline(_ bodies: [String], _ proxy: ScrollViewProxy) {
        let made = DesignOutlineCache.shared.data(model).bodyFeature
        let ids = Set(bodies.compactMap { made[$0] })
        let features = model.snapshot.timeline
        guard let first = features.firstIndex(where: { ids.contains($0.id) }) else {
            model.flash(String(localized: "No feature in the timeline made the selection."))
            return
        }
        for g in folders where !Set(g.features).isDisjoint(with: ids) { collapsed.remove(g.id) }
        revealed = ids
        picked = ids
        DispatchQueue.main.async {
            vfWithAnimation(.easeOut(duration: VFMotion.fast)) { proxy.scrollTo(AnyHashable(first), anchor: .center) }
        }
    }

    private func toggleFolder(_ id: Int) {
        vfWithAnimation(.easeOut(duration: VFMotion.fast)) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    /// Reorder through the engine; a refused move (a feature that works would fail) says
    /// which feature and why, instead of the bare engine error.
    private func reorder(_ name: String, to position: Int) {
        guard position >= 0 else { return }
        if model.run("timeline.reorder", ["feature": name, "position": position]) == nil {
            let why = model.message ?? ""
            model.flash(String(localized: "\(name) cannot move to position \(position + 1): \(why)"), error: true)
        }
    }

    private func createGroup(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        let reply = model.run("timeline.group", ["features": ids])
        if let g = (reply as? [String: Any])?["group"] as? Int { DesignOutlineCache.shared.note(folder: g, of: model) }
        if reply == nil {
            let why = model.message ?? ""
            model.flash(String(localized: "Create Group needs features next to each other in the timeline. \(why)"), error: true)
        } else {
            picked = []
        }
    }

    private func showDependents(_ f: DesignSnapshot.Feature) {
        let r = (try? model.engine.execute("timeline.dependents", ["feature": f.id])) as? [String: Any]
        dependents = (r?["deleted_with_it"] as? [String] ?? [], r?["would_fail"] as? [String] ?? [])
        dependentsOf = f.id
    }

    // MARK: Rename

    private func startRename(_ key: Int, _ name: String) {
        draft = name
        renameError = nil
        renaming = key
    }

    private func commitRename() {
        guard let key = renaming else { return }
        let name = draft.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { renameError = String(localized: "A name cannot be empty."); return }
        let ok = key > 0
            ? model.run("timeline.rename", ["feature": key, "name": name], quiet: true) != nil
            : model.run("timeline.rename_group", ["group": -key, "name": name], quiet: true) != nil
        if !ok {
            renameError = model.message
            model.flash(nil)
            return
        }
        renaming = nil
    }

    private func renameBinding(_ key: Int) -> Binding<Bool> {
        Binding(get: { renaming == key }, set: { if !$0, renaming == key { renaming = nil } })
    }

    private func dependentsBinding(_ id: Int) -> Binding<Bool> {
        Binding(get: { dependentsOf == id }, set: { if !$0, dependentsOf == id { dependentsOf = nil } })
    }

    private func renameField(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            TextField(prompt, text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = nil }
                .onChange(of: draft) { _, _ in renameError = nil }
                .accessibilityLabel(Text(prompt))
            if let renameError { InlineError(renameError) }
        }
        .padding(VFSpace.m)
    }

    /// Parent/Child: what a feature takes with it, and what would fail without it.
    private func dependentsPopover(_ f: DesignSnapshot.Feature) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            Text("Dependents of \(f.name)").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
            if dependents.deleted.isEmpty && dependents.failing.isEmpty {
                Text("No other feature depends on it.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            if !dependents.deleted.isEmpty {
                VFCaption("Deleted with it")
                ForEach(dependents.deleted, id: \.self) { n in Label(n, systemImage: "arrow.turn.down.right").font(VFFont.small) }
            }
            if !dependents.failing.isEmpty {
                VFCaption("Would fail without it")
                ForEach(dependents.failing, id: \.self) { n in
                    Label(n, systemImage: "exclamationmark.triangle").font(VFFont.small).foregroundStyle(theme.danger)
                }
            }
        }
        .padding(VFSpace.l)
        .frame(minWidth: 220, alignment: .leading)
    }

    private static func state(_ f: DesignSnapshot.Feature, built: Bool) -> String {
        if f.error != nil { return String(localized: "Failed") }
        if f.warning != nil { return String(localized: "Warning") }
        if f.suppressed ?? false { return String(localized: "Suppressed") }
        return built ? String(localized: "Built") : String(localized: "Rolled back")
    }

    private static func describe(_ f: DesignSnapshot.Feature, built: Bool) -> String {
        var lines = ["\(f.name) (\(f.type))", state(f, built: built)]
        if let e = f.error { lines.append(e) }
        if let w = f.warning { lines.append(w) }
        return lines.joined(separator: "\n")
    }

    /// The history marker after the last built feature; drag it to roll back or forward.
    private func playhead(marker: Int, count: Int, layout: TimelineLayout) -> some View {
        let x = layout.markerX(marker, pitch: Self.pitch)
        return VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(VFFont.glyph(8)).foregroundStyle(theme.fusion.ink)
            Rectangle().fill(theme.fusion.ink).frame(width: 2, height: 18)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .offset(x: x - 6, y: 2)
        .gesture(DragGesture(minimumDistance: 2).onEnded { g in
            model.rollTimeline(to: min(max(0, layout.marker(at: x + g.translation.width, pitch: Self.pitch)), count))
        })
        .help("History marker: drag to roll the model back")
        .accessibilityElement()
        .accessibilityLabel("History marker")
        .accessibilityValue(Text("After feature \(marker) of \(count)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.rollTimeline(to: min(count, marker + 1))
            case .decrement: model.rollTimeline(to: max(0, marker - 1))
            @unknown default: break
            }
        }
    }

    private func control(_ symbol: String, _ help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        VFIconButton(symbol, label: String(localized: help), size: 9, tint: theme.fusion.ink, action: action)
    }
}

/// The Training stage's curve under the flight view: cost per iteration against the baseline.
struct TrainingCurve: View {
    @Environment(\.viaFormTheme) private var theme
    let training: SimTraining

    var body: some View {
        HStack(alignment: .top, spacing: VFSpace.l) {
            VStack(alignment: .leading, spacing: 4) {
                VFCaption("Training")
                Text(training.target.name).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Text(training.running ? String(localized: "\(training.stage) · \(training.history.count) of \(training.total)")
                                      : (training.history.isEmpty ? String(localized: "Not started") : String(localized: "\(training.history.count) iterations")))
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                if let last = training.history.last {
                    Text("Cost \(VFFormat.number(last.cost, digits: 3)) · baseline \(VFFormat.number(last.baseline, digits: 3))")
                        .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
            .frame(width: 200, alignment: .leading)
            if training.history.isEmpty {
                EmptyState(String(localized: "No training yet"), systemImage: "chart.xyaxis.line",
                           message: String(localized: "Start a training to see its cost fall, iteration by iteration."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let cost = String(localized: "Cost"), baseline = String(localized: "Baseline")
                Chart {
                    ForEach(training.history, id: \.self) { p in
                        LineMark(x: .value("Iteration", p.iteration), y: .value("Cost", p.cost), series: .value("Series", cost))
                            .foregroundStyle(by: .value("Series", cost))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("Iteration", p.iteration), y: .value("Cost", p.baseline), series: .value("Series", baseline))
                            .foregroundStyle(by: .value("Series", baseline))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                // The legend names both lines; the baseline is dashed, so it never rests on colour.
                .chartForegroundStyleScale([cost: theme.accent, baseline: theme.inkTertiary])
                .chartLegend(position: .top, alignment: .leading)
                .chartXAxisLabel("Iteration")
                .chartYAxisLabel("Cost")
                .accessibilityLabel("Training cost per iteration")
                .accessibilityValue(Text(training.history.last.map {
                    String(localized: "\(training.history.count) iterations, last cost \(VFFormat.number($0.cost, digits: 3)), baseline \(VFFormat.number($0.baseline, digits: 3))")
                } ?? ""))
            }
        }
        .padding(VFSpace.l)
        .frame(minHeight: 150, idealHeight: 170)
        .background(theme.chrome)
    }
}

/// Manufacture: what the package gathers (frame, board, assembly, policy) and the exports.
struct MakeStage: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let actions: StageActions

    var body: some View {
        let noDesign = actions.model.snapshot.bodies.isEmpty
        let noBoard = actions.pcb.project == nil
        ZStack {
            ViewportBackdrop()
            if noDesign && noBoard {
                // Nothing to export yet: say what to do, one action.
                EmptyState(String(localized: "Nothing to make yet"), systemImage: "shippingbox",
                           message: String(localized: "Model a part in Design or lay out a board in Electronics; its files and bill of materials are exported here."),
                           actionTitle: String(localized: "Open Design")) { actions.open(.design) }
                    .padding(VFSpace.xxl)
                    .frame(maxWidth: 520)
                    .vfSurface(.panel)
            } else {
                StageOverview(flow: flow, stage: "make",
                              note: String(localized: "The package gathers the frame, the board, the assembly and the flight policy at the revisions in use. Exports available today:"),
                              open: { s in if let w = Workspace(stage: s) { actions.open(w) } },
                              update: { actions.update($0) }) {
                    Button("Export Design…") { actions.run("make.export") }.buttonStyle(.vfPrimary)
                        .vfDisabled(noDesign, reason: String(localized: "The design has no body yet. Model a part in Design first."))
                    Button("Bill of Materials") { actions.run("make.bom") }.buttonStyle(.vfSecondary)
                    Button("Export KiCad Board…") { actions.run("make.kicad") }.buttonStyle(.vfSecondary)
                        .vfDisabled(!actions.canRun("make.kicad"), reason: actions.unavailableReason("make.kicad") ?? "")
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
    }
}
#endif
