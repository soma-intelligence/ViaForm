#if os(macOS)
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
    @State private var perspective = false

    var body: some View {
        ZStack {
            Viewport(model: model, theme: theme.viewportTheme)
                .id(theme.isDark)
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
                    NavPill(model: model, perspective: $perspective)
                    Spacer()
                    Color.clear.frame(width: 78, height: 1)
                }
            }
            .padding(VFSpace.overlayInset)
            .vfAnimation(.easeOut(duration: VFMotion.standard), value: model.tool != .select || model.genericCommand != nil)
            if let at = model.markingMenu { MarkingMenu(model: model, at: at) }
        }
        .onChange(of: perspective) { _, p in model.camera.fov = p ? 0.7 : 0; model.cameraChanged() }
        .onChange(of: model.message) { _, m in
            guard let m, !model.messageIsError, let toasts else { return }
            toasts.show(m)
            model.flash(nil)
        }
    }
}

/// Orbit, pan, zoom, fit, look at, the standard views and the visual style, in a floating pill.
struct NavPill: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel
    @Binding var perspective: Bool

    var body: some View {
        HStack(spacing: 2) {
            item("rotate.3d", "Orbit (right drag or Option drag)") { model.camera.orbit(dx: 40, dy: 0); model.cameraChanged() }
            item("hand.raised", "Pan (middle drag or two fingers)") {
                toasts?.show(String(localized: "Pan: drag with the middle button, or two fingers on the trackpad"), systemImage: "hand.raised")
            }
            item("plus.magnifyingglass", "Zoom in") { model.camera.zoom(1.25); model.cameraChanged() }
            item("arrow.up.left.and.down.right.magnifyingglass", "Fit") { model.zoomToFit() }
            VFHairline(vertical: true).frame(height: 18)
            item("viewfinder", "Look At") {
                if case let .face(_, _, _, n)? = model.selection.first(where: \.isFace) { model.look(along: n) }
                else if let pl = model.sketchPlane { model.look(along: pl.normal) }
            }
            Menu {
                Toggle("Perspective", isOn: $perspective)
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

    private func item(_ symbol: String, _ help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        VFIconButton(symbol, label: String(localized: help), size: 13, action: action)
    }
}

/// The Design timeline: every feature on a connected rail, built ones on a solid accent rail,
/// rolled back ones faded on a dashed rail after the playhead. The playhead is the history
/// marker: click a feature to roll to it, drag the playhead back to roll back. Drag a feature to
/// reorder it, right-click to edit, suppress or delete it.
struct FeatureTimeline: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    private static let pitch: CGFloat = 40

    var body: some View {
        let s = model.snapshot
        HStack(spacing: VFSpace.l) {
            VStack(alignment: .leading, spacing: 2) {
                VFCaption("History")
                Text(s.timeline.isEmpty ? String(localized: "No features") : String(localized: "\(min(s.marker, s.timeline.count)) of \(s.timeline.count) built"))
                    .font(VFFont.micro).foregroundStyle(theme.inkTertiary).monospacedDigit()
            }
            .frame(width: 92, alignment: .leading)
            HStack(spacing: 4) {
                control("backward.end.fill", "Roll back to the start") { model.rollTimeline(to: 0) }
                    .vfDisabled(s.marker == 0, reason: String(localized: "Already at the start"))
                control("backward.frame.fill", "Step back") { model.rollTimeline(to: max(0, s.marker - 1)) }
                    .vfDisabled(s.marker == 0, reason: String(localized: "Already at the start"))
                Button { model.run("timeline.roll_to", ["position": "end"], quiet: true) } label: {
                    Image(systemName: "play.fill").font(VFFont.glyph(12)).foregroundStyle(theme.onAccent)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous).fill(theme.accent))
                        .frame(minWidth: VFSize.minTarget, minHeight: VFSize.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Play to the end")
                .accessibilityLabel("Play to the end")
                control("forward.frame.fill", "Step forward") { model.rollTimeline(to: min(s.timeline.count, s.marker + 1)) }
                    .vfDisabled(s.marker >= s.timeline.count, reason: String(localized: "Already at the end"))
                control("forward.end.fill", "Roll to the end") { model.run("timeline.roll_to", ["position": "end"], quiet: true) }
                    .vfDisabled(s.marker >= s.timeline.count, reason: String(localized: "Already at the end"))
            }
            VFHairline(vertical: true).frame(height: 34)
            if s.timeline.isEmpty {
                Text("Features you add appear here, in order.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        rail(s).padding(.vertical, VFSpace.xs).padding(.horizontal, VFSpace.s)
                    }
                    // Keep the playhead in view: at the end, scroll to the room after the last tile.
                    .onAppear { proxy.scrollTo(s.marker >= s.timeline.count ? "end" : AnyHashable(max(0, s.marker - 1)), anchor: .center) }
                    .onChange(of: s.marker) { _, m in
                        vfWithAnimation(.easeOut(duration: VFMotion.fast)) { proxy.scrollTo(m >= s.timeline.count ? "end" : AnyHashable(max(0, m - 1)), anchor: .center) }
                    }
                }
            }
        }
        .padding(.horizontal, VFSpace.l)
        .frame(minHeight: 64)
        .background(theme.chrome)
    }

    private func rail(_ s: DesignSnapshot) -> some View {
        let count = s.timeline.count
        let marker = min(s.marker, count)
        return ZStack(alignment: .topLeading) {
            // The rail behind the tiles: solid up to the playhead, dashed after it.
            Canvas { ctx, size in
                let y: CGFloat = 15
                let x0 = Self.pitch / 2, xm = CGFloat(marker) * Self.pitch, x1 = CGFloat(count) * Self.pitch - Self.pitch / 2
                if marker > 0 {
                    var a = Path(); a.move(to: CGPoint(x: x0, y: y)); a.addLine(to: CGPoint(x: min(xm, x1), y: y))
                    ctx.stroke(a, with: .color(theme.accent.opacity(0.75)), lineWidth: 2)
                }
                if marker < count {
                    var b = Path(); b.move(to: CGPoint(x: max(xm, x0), y: y)); b.addLine(to: CGPoint(x: x1, y: y))
                    ctx.stroke(b, with: .color(theme.inkTertiary.opacity(0.6)), style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                }
            }
            .frame(width: CGFloat(count) * Self.pitch, height: 30)
            .allowsHitTesting(false)
            HStack(spacing: 0) {
                ForEach(Array(s.timeline.enumerated()), id: \.element.id) { i, f in
                    tile(f, index: i, built: i < marker).id(AnyHashable(i))
                }
                // Room after the last tile, so the playhead at the end is never cut.
                Color.clear.frame(width: 24, height: 1).id(AnyHashable("end"))
            }
            playhead(marker: marker, count: count)
        }
        .frame(width: CGFloat(count) * Self.pitch + 24, height: 46, alignment: .topLeading)
    }

    private func tile(_ f: DesignSnapshot.Feature, index i: Int, built: Bool) -> some View {
        let failed = f.error != nil
        let suppressed = f.suppressed ?? false
        return VStack(spacing: 3) {
            // The feature's own command icon (Extrude, Fillet...), tinted when failed or suppressed.
            CommandIcon(art: f.type.lowercased(), symbol: FeatureSymbol.of(f.type), size: 13)
                .frame(width: 20, height: 20)
                .foregroundStyle(failed ? theme.danger : (suppressed ? theme.warning : (built ? theme.ink : theme.inkTertiary)))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                    .fill(failed ? theme.danger.opacity(0.16) : (suppressed ? theme.warning.opacity(0.12) : (built ? theme.panel : theme.chrome))))
                .overlay(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                    .strokeBorder(failed ? theme.danger : (built ? theme.accent.opacity(0.55) : theme.hairline),
                                  style: StrokeStyle(lineWidth: 1, dash: suppressed ? [2, 2] : [])))
            Text("\(i + 1)").font(VFFont.micro).monospacedDigit().foregroundStyle(built ? theme.inkSecondary : theme.inkTertiary)
        }
        .frame(width: Self.pitch)
        .opacity(built ? 1 : 0.5)
        .contentShape(Rectangle())
        .help(Self.describe(f, built: built))
        .onTapGesture { model.rollTimeline(to: i + 1) }
        // VoiceOver: one button per feature with its state; the menu's commands as actions, and
        // Move Earlier or Later as the drag's equivalent.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Feature \(i + 1), \(f.name)"))
        .accessibilityValue(Text(Self.state(f, built: built)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Rolls the history marker to this feature")
        .accessibilityAction { model.rollTimeline(to: i + 1) }
        .accessibilityAction(named: Text("Edit Feature")) { model.run("timeline.edit", ["feature": f.name]) }
        .accessibilityAction(named: Text("Move Earlier")) { if i > 0 { model.run("timeline.reorder", ["feature": f.name, "position": i - 1]) } }
        .accessibilityAction(named: Text("Move Later")) { model.run("timeline.reorder", ["feature": f.name, "position": i + 1]) }
        .accessibilityAction(named: suppressed ? Text("Unsuppress") : Text("Suppress")) { model.run("timeline.suppress", ["feature": f.id]) }
        .accessibilityAction(named: Text("Delete")) { model.run("timeline.delete", ["feature": f.id]) }
        .draggable(f.name)
        .dropDestination(for: String.self) { names, _ in
            guard let n = names.first, n != f.name else { return false }
            model.run("timeline.reorder", ["feature": n, "position": i])
            return true
        }
        .contextMenu {
            Button("Roll History Marker Here") { model.rollTimeline(to: i + 1) }
            Button("Edit Feature") { model.run("timeline.edit", ["feature": f.name]) }
            Button(suppressed ? "Unsuppress" : "Suppress") { model.run("timeline.suppress", ["feature": f.id]) }
            Divider()
            Button("Move Earlier") { model.run("timeline.reorder", ["feature": f.name, "position": i - 1]) }
                .vfDisabled(i == 0, reason: String(localized: "Already the first feature"))
            Button("Move Later") { model.run("timeline.reorder", ["feature": f.name, "position": i + 1]) }
            Divider()
            Button("Delete", role: .destructive) { model.run("timeline.delete", ["feature": f.id]) }
        }
    }

    private static func state(_ f: DesignSnapshot.Feature, built: Bool) -> String {
        if f.error != nil { return String(localized: "Failed") }
        if f.suppressed ?? false { return String(localized: "Suppressed") }
        return built ? String(localized: "Built") : String(localized: "Rolled back")
    }

    private static func describe(_ f: DesignSnapshot.Feature, built: Bool) -> String {
        var lines = ["\(f.name) (\(f.type))", state(f, built: built)]
        if let e = f.error { lines.append(e) }
        return lines.joined(separator: "\n")
    }

    /// The history marker after the last built feature; drag it to roll back or forward.
    private func playhead(marker: Int, count: Int) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(theme.accent).frame(width: 10, height: 12)
            Rectangle().fill(theme.accent).frame(width: 2, height: 32)
        }
        .frame(width: 14)
        .contentShape(Rectangle())
        .offset(x: CGFloat(marker) * Self.pitch - 7, y: -3)
        .gesture(DragGesture(minimumDistance: 2).onEnded { g in
            let to = Int((CGFloat(marker) * Self.pitch + g.translation.width) / Self.pitch + 0.5)
            model.rollTimeline(to: min(max(0, to), count))
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
        VFIconButton(symbol, label: String(localized: help), size: 11, tint: theme.ink, action: action)
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
