#if os(macOS)
import SwiftUI

/// The docked inspector on the right of the project window: the selection, its place in the
/// flow (what the stage consumes and produces, with revisions), the other stages where the
/// selection also lives (one line, folded), then the stage's own section (parameters, study,
/// board, scenario, training, outputs).
struct InspectorPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let workspace: Workspace
    let flow: FlowModel
    let model: DesignModel
    let pcb: PCBModel
    let sim: SimModel
    let generate: GenerateModel
    let actions: StageActions
    var assemble: AssembleModel?
    var armSim: ArmSimModel?
    var testInSimulation: (() -> Void)?
    @State private var linkedOpen = false
    @State private var revisionsOf: String?
    @State private var confirm: ConfirmRequest?
    @Bindable private var safety = RobotSafety.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VFSpace.l) {
                selectionCard
                flowSection
                linkedSection
                stageSection
            }
            .padding(VFSpace.l)
        }
        .background(theme.panel)
        .confirmSheet($confirm)
    }

    // MARK: Selection

    private var selectionTitle: (String, String)? {
        if workspace == .assemble, let a = assemble {
            if a.tool == .grasp { return ("Grasp", "Object \(a.grasp.shape), \(a.grasp.fingers.count) fingertips") }
            if a.tool == .dragTip { return ("Tool tip", "Drag tip, \(a.ik.solver.lowercased()) solver") }
            if let j = a.selected { return (j.title + " joint", j.kind.capitalized + String(format: ", %.1f %@", a.q[j.id] ?? 0, j.unit)) }
            return nil
        }
        if StageActions.designLike.contains(workspace) {
            let bodies = model.selectedBodies.sorted()
            if let b = bodies.first, let info = model.snapshot.bodies.first(where: { $0.name == b }) {
                let extra = bodies.count > 1 ? " and \(bodies.count - 1) more" : ""
                return (b + extra, "Body" + (info.material.map { ", \($0)" } ?? ""))
            }
            // A face or an edge: named by its body, the words of the selection card.
            if !model.selection.isEmpty, let a = AnchorLayout.anchor(model, size: CGSize(width: 1000, height: 700)) {
                let picks = model.selection.count
                return (a.title, picks == 1 ? (model.selection[0].isFace ? "Face" : "Edge") : "\(picks) faces or edges")
            }
        }
        if workspace == .generate {
            // The candidate picked in the outcomes, else the region picked in the setup.
            if let i = generate.selected, let c = generate.candidate {
                let sf = formatFactor(c.analysis.safetyFactor)
                return ("Candidate \(i + 1)" + (i == generate.outcome?.best ? ", best" : ""),
                        String(format: "%.1f g, safety factor %@, %@", c.massG, sf, c.feasible ? "feasible" : "over a limit"))
            }
            if let key = generate.selection {
                let kind = switch key { case .support: "Support"; case .load: "Load"; case .keepOut: "Keep-out"; case .keepIn: "Keep-in" }
                return (kind, "Region of \(generate.study.name)")
            }
        }
        let s = flow.selection
        if s.stage == workspace.stage, !s.isEmpty {
            let title = s.title.replacingOccurrences(of: #"\b[a-z]+:"#, with: "", options: .regularExpression)
            return (title, flow.stage(s.stage)?.name ?? s.stage)
        }
        return nil
    }

    /// One header for the panel: the SELECTION caption with the stage chip on its right, then the
    /// selection card, or a single hint line when nothing is picked (no empty card).
    private var selectionCard: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack {
                VFCaption("Selection")
                Spacer()
                // Neutral: the stage accent lives only on the workspace dropdown icon (spec 6.4).
                Text(workspace.title).font(VFFont.micro.weight(.semibold))
                    .foregroundStyle(theme.inkSecondary)
                    .padding(.horizontal, VFSpace.s).padding(.vertical, VFSpace.xxs)
                    .background(Capsule().fill(theme.well))
                    .overlay(Capsule().strokeBorder(theme.hairline))
                    .accessibilityLabel(Text("Stage \(workspace.title)"))
            }
            if let t = selectionTitle {
                HStack(spacing: VFSpace.m) {
                    Image(systemName: workspace.symbol).foregroundStyle(theme.inkSecondary).frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: VFSpace.xxs) {
                        Text(t.0).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).lineLimit(2)
                        Text(t.1).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
                    }
                    .help("\(t.0)\n\(t.1)")
                    Spacer(minLength: 0)
                }
                .padding(VFSpace.m)
                .vfSurface(.well)
                .accessibilityElement(children: .combine)
            } else {
                Text(hint).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(hint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hint: String {
        switch workspace {
        case .design, .assemble: String(localized: "Nothing selected. Click a body, a face or an edge.")
        case .electronics: String(localized: "Nothing selected. Click a part or a net.")
        case .generate: String(localized: "Nothing selected. Pick a candidate.")
        default: String(localized: "Nothing selected")
        }
    }

    // MARK: Flow

    private var flowSection: some View {
        let nodes = flow.nodes(in: workspace.stage)
        return section("Flow") {
            ForEach(nodes) { n in
                VStack(alignment: .leading, spacing: VFSpace.xs) {
                    ForEach(n.consumes, id: \.id) { i in
                        let input = flow.node(i.id)
                        // Stale when this stage was built on an older revision, else the input's own state.
                        let status: FlowModel.Status = !i.current ? .stale : (input?.status ?? .empty)
                        flowRow(role: "Consumes", artifact: input?.name ?? i.id,
                                revision: i.now > 0 ? (i.now_name ?? input?.revisionName) : nil,
                                status: status, help: i.current ? nil : "Built on \(i.seen_name ?? "an earlier revision")") {
                            if let s = input?.stage, let w = Workspace(stage: s) { actions.open(w) }
                        }
                    }
                    flowRow(role: "Produces", artifact: n.name, revision: n.revisionName, status: n.status, help: "Revisions") {
                        revisionsOf = revisionsOf == n.id ? nil : n.id
                    }
                    if let why = n.job?.caption ?? (n.reason.isEmpty ? nil : n.reason) {
                        Text(why).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(why)
                            .padding(.leading, 15)
                    }
                    if let a = n.action, n.status == .stale || n.status == .failed {
                        // Bordered: the canvas banner carries the primary for this action (P1-17).
                        Button { actions.update(a.plan) } label: { Text(a.label).lineLimit(2).frame(maxWidth: .infinity) }
                            .buttonStyle(.vfSecondary).controlSize(.small)
                            .help(a.label)
                            .vfEngineGate()
                    }
                    if revisionsOf == n.id { RevisionList(flow: flow, artifact: n.id) }
                }
            }
            if nodes.isEmpty {
                EmptyState(String(localized: "Nothing to build here"), systemImage: "square.dashed",
                           message: String(localized: "This stage builds nothing yet."))
            }
        }
    }

    private var linkedSection: some View {
        let linked = flow.selection.linked.filter { $0.count > 0 }
        return Group {
            if linked.isEmpty && StageActions.designLike.contains(workspace) {
                // Folded presence row, as in Electronics: where the selection also lives.
                HStack(spacing: VFSpace.s) {
                    VFCaption("Linked")
                    Text(model.selectedBodies.isEmpty && model.selection.isEmpty ? "Select a body to see its other stages" : "Only in this design")
                        .font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !linked.isEmpty {
                DisclosureGroup(isExpanded: $linkedOpen) {
                    ForEach(linked) { p in
                        Button {
                            if let w = Workspace(stage: p.stage) { actions.open(w) }
                        } label: {
                            HStack {
                                Text(flow.stage(p.stage)?.name ?? p.stage)
                                Spacer()
                                Text(p.names.prefix(2).joined(separator: ", ")).foregroundStyle(theme.inkSecondary).lineLimit(1)
                                    .help(p.names.joined(separator: ", "))
                            }
                            .font(VFFont.small)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    HStack(spacing: VFSpace.s) {
                        VFCaption("Linked")
                        Text(linked.compactMap { flow.stage($0.stage)?.name }.joined(separator: " · "))
                            .font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: Stage sections

    @ViewBuilder private var stageSection: some View {
        switch workspace {
        case .assemble where assemble != nil:
            AssembleInspector(model: assemble!, testInSimulation: testInSimulation)
        case .simulation where armSim != nil:
            ArmSimInspector(sim: armSim!, flow: flow)
        case .design, .assemble, .render:
            let s = model.snapshot
            section(workspace == .assemble ? "Assembly" : "Document") {
                kv("Units", s.units)
                kv("Bodies", "\(s.bodies.count)")
                kv("Sketches", "\(s.sketches.count)")
                kv("Features", "\(s.timeline.count)")
                if workspace == .assemble { kv("Components", "\(model.assembly.count)") }
            }
            if let b = physicalBody, let info = s.bodies.first(where: { $0.name == b }) {
                section("Physical") {
                    kv("Body", b)
                    kv("Material", info.material ?? "Not set")
                    if let v = info.volume_mm3 {
                        kv("Volume", String(format: "%.1f cm³", v / 1000))
                        if let rho = Self.density(info.material) { kv("Mass", VFFormat.mass(v / 1000 * rho)) }
                    }
                    if let f = info.faces { kv("Faces", "\(f)") }
                    if let e = info.edges { kv("Edges", "\(e)") }
                }
            }
            if !s.params.isEmpty {
                section("Parameters") {
                    ForEach(s.params) { p in kv(p.name, p.expression) }
                }
            }
        case .generate:
            section("Study") {
                kv("State", generate.running ? "Running" : (generate.stale ? "Setup changed since the last run" : (generate.outcome == nil ? "Not run yet" : "Up to date")))
                if generate.expected > 0 { kv("Expected", String(format: "%.0f s", generate.expected)) }
                if let o = generate.outcome { kv("Candidates", "\(o.candidates.count)") }
                if let i = generate.selected { kv("Selected", "Candidate \(i + 1)") }
                if let e = generate.error { Text(e).font(VFFont.small).foregroundStyle(theme.danger) }
            }
        case .electronics:
            section("Board") {
                kv("Parts", "\(pcb.project?.components.count ?? 0)")
                kv("Nets", "\(pcb.project?.nets.count ?? 0)")
                kv("Rule findings", "\(pcb.findings.count)", warn: !pcb.findings.isEmpty)
                if let b = pcb.project?.board { kv("Outline", "\(VFFormat.length(b.width)) x \(VFFormat.length(b.height))") }
            }
            let link = BoardLinkInfo.read(design: model, pcb: pcb)
            section("3D link") {
                kv("State", link.linked ? (link.outOfDate ? "Behind the board" : "Live") : "Not in 3D", warn: link.outOfDate)
                if link.revision != nil {
                    // The pipeline's name for the board ("Board rev D"); the engine's link counter on hover.
                    kv("Built from", flow.node("electronics.board")?.revisionName ?? "Board")
                        .help(link.revision.map { "Link revision \($0)" } ?? "")
                }
                kv("Mounted on", link.host ?? "Not mounted")
                if let c = link.clearance { kv("Clearance", String(format: "%.2f mm", c), warn: c < 0) }
            }
            section("Checks") {
                let drc = pcb.checks?.drc.count ?? 0, erc = pcb.checks?.erc.count ?? 0
                kv("Design rules", drc == 0 ? "0 errors" : "\(drc) findings", warn: drc > 0)
                kv("Electrical rules", erc == 0 ? "0 errors" : "\(erc) findings", warn: erc > 0)
                kv("Unrouted", "\(pcb.checks?.airwires.count ?? 0)", warn: (pcb.checks?.airwires.count ?? 0) > 0)
                if link.host != nil { kv("Fits keep-in", link.fits ? "Yes" : "No", warn: !link.fits) }
            }
        case .simulation where flow.isHandProduct:
            section("Scenario") {
                ForEach(flow.nodes(in: "simulate").flatMap(\.consumes), id: \.id) { i in
                    kv(flow.node(i.id)?.label.isEmpty == false ? flow.node(i.id)!.label : (flow.node(i.id)?.name ?? i.id),
                       i.now_name ?? "rev \(i.now)", warn: !i.current)
                }
                kv("Mission", "Grasp test, joint drive")
                kv("Hand assembly", generate.assemblyLoaded ? "Inserted" : (generate.project?.name == "hand" && generate.project?.assembly != nil ? "Not inserted" : "None on disk"))
                kv("Movable joints", "\(generate.joints.filter(\.movable).count)")
                Text("Kinematic: the joints are driven within their limits; contact and grip force are not simulated.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        case .simulation:
            section("Scenario") {
                ForEach(flow.nodes(in: "simulate").flatMap(\.consumes), id: \.id) { i in
                    kv(flow.node(i.id)?.label.isEmpty == false ? flow.node(i.id)!.label : (flow.node(i.id)?.name ?? i.id),
                       i.now_name ?? "rev \(i.now)", warn: !i.current)
                }
                kv("Mission", sim.catalog?.missions.first { $0.id == sim.options.mission }?.name ?? sim.options.mission)
                if let o = sim.outcome { kv("Last flight", o) }
            }
        case .train:
            let t = sim.training
            section("Training") {
                kv("Target", t.target.name)
                kv("Iterations", "\(t.history.count) of \(max(t.total, t.iterations))")
                kv("Population", "\(t.population)")
                kv("Episodes", "\(t.episodes)")
                if let h = t.heldOut { kv("Held-out cost", String(format: "%.3f to %.3f", h.before, h.after)) }
                if let e = t.error { Text(e).font(VFFont.small).foregroundStyle(theme.danger) }
            }
        case .make:
            section("Package") {
                ForEach(flow.outputs()) { o in
                    kv(o.label.isEmpty ? o.name : o.label, (o.revision_name ?? "not built") + " · " + o.status.vfStatus.word,
                       warn: o.status == .stale || o.status == .failed)
                }
            }
        case .robot:
            section("Device") {
                HStack(spacing: VFSpace.s) {
                    VFStatusDot(status: safety.connected ? .current : .empty,
                                reason: safety.connected ? String(localized: "Robot connected") : String(localized: "No robot connected"))
                    kv(String(localized: "Robot"), safety.connected ? String(localized: "Connected") : String(localized: "Not connected"))
                }
                kv(String(localized: "Link"), safety.linkKind?.title ?? String(localized: "USB bus adapter or ViaForm bridge"))
                kv(String(localized: "Latency"), safety.linkKind == .simulated ? String(localized: "None, simulated")
                    : (safety.connected ? String(localized: "Measuring") : String(localized: "Not measured, no robot")))
                kv(String(localized: "Session"), safety.sessionConfirmed ? String(localized: "Motion confirmed")
                    : String(localized: "Asks before the first motion"))
            }
            section("Safety") {
                EStopButton()
                NumberRow(String(localized: "Teleop speed cap"), value: $safety.speedCap, unit: "%",
                          range: RobotSafety.speedCapRange, step: 5)
                    .font(VFFont.row)
                    .vfDisabled(safety.moving, reason: String(localized: "Stop the robot to change its limits"))
                NumberRow(String(localized: "Torque limit"), value: $safety.torqueLimit, unit: "%",
                          range: RobotSafety.torqueLimitRange, step: 5)
                    .font(VFFont.row)
                    .vfDisabled(safety.moving, reason: String(localized: "Stop the robot to change its limits"))
                Toggle(String(localized: "Workspace fence from Assemble joint limits"), isOn: $safety.fenceEnabled)
                    .font(VFFont.row)
                    .toggleStyle(.checkbox)
                    .vfDisabled(safety.moving, reason: String(localized: "Stop the robot to change its limits"))
                if !safety.connected {
                    Text("Not applied, no robot. These limits apply once a robot is connected.")
                        .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            section("Policy") {
                let policy = flow.revisionName(of: "train")
                if let policy {
                    kv(String(localized: "Policy"), policy)
                } else {
                    EmptyState(String(localized: "No policy yet"), systemImage: "brain",
                               message: String(localized: "Train a policy, then run it on the robot here."),
                               actionTitle: String(localized: "Open Train")) { actions.open(.train) }
                }
                // Through the gate: confirmed once per session, capped, blocked by the e-stop.
                RobotRunPolicyButton(confirm: $confirm, policy: policy, fullWidth: true)
            }
        }
    }

    /// The stage's verbs, stacked full width. Not shown since the efficiency pass: the ribbon
    /// carries every verb and Command-Return runs the main one, so the inspector only describes.
    private func actionRow(_ ids: [String]) -> some View {
        let cmds = ids.compactMap { id in flow.commands(stage: workspace.stage).first { $0.id == id } ?? flow.commands().first { $0.id == id } }
        return VStack(spacing: VFSpace.xs) {
            ForEach(cmds) { c in
                Button { actions.run(c.id) } label: {
                    Label(StageLabels.command(c.label), systemImage: StageLabels.symbol(forVerb: c.icon))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
                .disabled(!actions.canRun(c.id))
                .vfEngineGate()
            }
        }
    }

    /// The body the Physical section describes: a picked body, or the body of a picked face.
    private var physicalBody: String? {
        if let b = model.selectedBodies.sorted().first { return b }
        for p in model.selection {
            switch p {
            case let .face(m, _, _, _), let .edge(m, _, _):
                if m < model.scene.meshes.count { return model.scene.meshes[m].body }
            }
        }
        return nil
    }

    /// g/cm³ for the common materials, by name.
    static func density(_ material: String?) -> Double? {
        guard let m = material?.lowercased() else { return nil }
        let table: [(String, Double)] = [("alumin", 2.70), ("steel", 7.85), ("stainless", 8.00), ("titan", 4.43), ("brass", 8.50),
                                         ("copper", 8.96), ("carbon", 1.60), ("abs", 1.04), ("pla", 1.24), ("petg", 1.27),
                                         ("nylon", 1.14), ("pa12", 1.01), ("tpu", 1.21), ("resin", 1.18), ("wood", 0.70)]
        return table.first { m.contains($0.0) }?.1
    }

    /// One flow row on two lines: the revision ("Frame v12", or "Not built yet") over its role
    /// and artifact ("Consumes · Generated frame"), with the artifact's status dot.
    private func flowRow(role: String, artifact: String, revision: String?, status: FlowModel.Status, help: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: VFSpace.s) {
                VFStatusDot(status: status.vfStatus, reason: help)
                VStack(alignment: .leading, spacing: VFSpace.xxs) {
                    Text(revision ?? String(localized: "Not built yet")).font(VFFont.rowEmphasis)
                        .foregroundStyle(status == .stale ? theme.warning : theme.ink).lineLimit(1)
                    Text("\(role) · \(artifact)").font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(VFFont.glyph(8, weight: .bold)).foregroundStyle(theme.inkTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([revision ?? String(localized: "Not built yet"), "\(role) · \(artifact)", help].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel("\(role) \(artifact), \(revision ?? "not built yet"), \(PipelineWords.describe(status))")
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            VFCaption(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A label and a value; the value wraps to two lines with the full text in the tooltip.
    /// A warning carries a triangle, never colour alone; a tappable value carries a chevron.
    @ViewBuilder
    private func kv(_ k: String, _ v: String, warn: Bool = false, action: (() -> Void)? = nil) -> some View {
        if let action {
            HStack(alignment: .firstTextBaseline) {
                Text(k).foregroundStyle(theme.inkSecondary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: VFSpace.m)
                Button(action: action) {
                    HStack(spacing: VFSpace.xxs) {
                        Text(v).lineLimit(2).multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.right").font(VFFont.glyph(8, weight: .bold)).accessibilityHidden(true)
                    }
                    .foregroundStyle(warn ? theme.warning : theme.accentText)
                }
                .buttonStyle(.plain)
                .help(v)
            }
            .font(VFFont.row)
            .frame(minHeight: VFSize.macRow - 8)
        } else if warn {
            HStack(alignment: .firstTextBaseline, spacing: VFSpace.m) {
                Text(k).foregroundStyle(theme.inkSecondary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: VFSpace.m)
                HStack(spacing: VFSpace.xxs) {
                    Image(systemName: "exclamationmark.triangle.fill").font(VFFont.glyph(9, weight: .semibold))
                        .accessibilityLabel(Text("Warning"))
                    Text(v).lineLimit(2).multilineTextAlignment(.trailing).monospacedDigit()
                }
                .foregroundStyle(theme.warning)
                .help(v)
            }
            .font(VFFont.row)
            .frame(minHeight: VFSize.macRow - 8)
            .accessibilityElement(children: .combine)
        } else {
            KVRow(k, v)
        }
    }
}
#endif
