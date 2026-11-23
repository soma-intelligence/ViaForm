#if os(iOS)
import SwiftUI

// What each stage puts in the iPad's inspector card, and the cards of the stages that share the
// design viewport (Assemble, Render, Make) or the flight scene (Train).

/// The design card: the armed tool with its live value, or the selection, or the design.
struct TouchDesignInspector: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    let flow: FlowModel
    let stage: Workspace
    let open: (Workspace) -> Void

    var body: some View {
        if model.tool != .select, model.tool != .sketch {
            toolCard
        } else if !model.bodiesInSelection.isEmpty {
            selectionCard
        } else {
            designCard
        }
    }

    // MARK: Tool

    private var toolCard: some View {
        TouchInspectorCard(title: model.tool.touchLabel, symbol: model.tool.symbol, subtitle: hint) {
            if let v = model.tool.value {
                TouchKVRow(label: v.label, value: DesignAnchorLayer.format(model.toolValue, v.unit))
                HStack(spacing: 12) {
                    Slider(value: $model.toolValue, in: range(v.unit, v.initial))
                    Stepper("", value: $model.toolValue, step: v.unit == "deg" ? 15 : 1).labelsHidden()
                }
                .frame(minHeight: 48)
            }
            if model.tool == .extrude || model.tool == .revolve {
                Picker("Operation", selection: $model.toolOperation) {
                    Text("Auto").tag("auto"); Text("New").tag("new_body"); Text("Join").tag("join"); Text("Cut").tag("cut")
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .onChange(of: model.toolOperation) { _, _ in model.applyPreview() }
            }
            if model.tool == .revolve {
                Picker("Axis", selection: $model.revolveAxis) { ForEach(["x", "y", "X", "Y", "Z"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).frame(minHeight: 44)
                    .onChange(of: model.revolveAxis) { _, _ in model.applyPreview() }
            }
            if model.tool == .move {
                ForEach(0..<3, id: \.self) { i in
                    ValueField(label: ["X", "Y", "Z"][i], unit: "mm", value: Binding(get: { model.moveVector[i] }, set: { model.moveVector[i] = $0 }))
                        .frame(minHeight: 44)
                }
            }
            if model.tool == .mirror {
                Picker("Plane", selection: $model.mirrorPlane) { ForEach(["XY", "XZ", "YZ"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).frame(minHeight: 44)
            }
            HStack(spacing: 10) {
                // Same width and weight; Cancel in ink on the neutral bordered style (readable
                // in dark mode), Done the accent.
                Button { model.cancelTool() } label: {
                    Text("Cancel").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, minHeight: VFSize.touchTarget - 8)
                }
                .buttonStyle(.bordered).tint(theme.inkSecondary)
                Button { done() } label: {
                    Text("Done").font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: VFSize.touchTarget - 8)
                }
                .buttonStyle(.vfPrimary)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.vertical, 10)
        }
    }

    private func range(_ unit: String, _ initial: Double) -> ClosedRange<Double> {
        if unit == "deg" { return 0...360 }
        if unit.isEmpty { return 3...24 }
        return 0...max(100, initial * 4, model.toolValue * 1.5)
    }

    private var hint: String? {
        switch model.tool {
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

    // MARK: Selection

    private var selectionCard: some View {
        let names = model.bodiesInSelection
        let bodies = model.snapshot.bodies.filter { names.contains($0.name) }
        let volume = bodies.compactMap(\.volume_mm3).reduce(0, +)
        let component = model.assembly.first { c in c.bodies.contains { names.contains($0) } }
        return TouchInspectorCard(title: names.count == 1 ? names[0] : "\(names.count) bodies", symbol: "cube",
                                  subtitle: component.map { "In \($0.occurrence ?? $0.name)" }) {
            TouchKVRow(label: "Volume", value: volume > 0 ? String(format: "%.0f mm³", volume) : "None")
            TouchKVRow(label: "Mass (PA12)", value: volume > 0 ? String(format: "%.1f g", volume * 1.01e-3) : "None")
            TouchKVRow(label: "Faces", value: "\(bodies.compactMap(\.faces).reduce(0, +))")
            TouchKVRow(label: "Material", value: bodies.first?.material ?? "PA12", divider: false)
            TouchFlowRows(flow: flow, stage: stage, open: open)
        }
    }

    private var designCard: some View {
        TouchInspectorCard(title: ProjectTitle.of(flow: flow, design: model), symbol: "cube.transparent", subtitle: flow.revisionName(of: stage.stage)) {
            TouchKVRow(label: "Bodies", value: "\(model.snapshot.bodies.count)")
            TouchKVRow(label: "Components", value: "\(model.assembly.count)")
            TouchKVRow(label: "Sketches", value: "\(model.snapshot.sketches.count)")
            TouchKVRow(label: "Parameters", value: "\(model.snapshot.params.count)", divider: false)
            TouchFlowRows(flow: flow, stage: stage, open: open)
        }
    }
}

/// Assemble: the components, what is grounded and what carries the board.
struct TouchAssembleInspector: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let pcb: PCBModel
    let flow: FlowModel
    let open: (Workspace) -> Void

    var body: some View {
        TouchInspectorCard(title: "Assembly", symbol: "gearshape.2", subtitle: flow.revisionName(of: "assemble") ?? "Not built yet") {
            if model.assembly.isEmpty {
                Text("No components yet. Make components in Design, or send the board to 3D from Electronics.")
                    .font(.system(size: 14)).foregroundStyle(theme.inkSecondary).padding(.vertical, 10)
            }
            ForEach(model.assembly.prefix(6)) { c in
                Button { model.selectedBodies = Set(c.bodies) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: c.linkedPCB ? "cpu" : "square.stack.3d.up").foregroundStyle(c.linkedPCB ? theme.accentText : theme.inkSecondary)
                        Text(c.occurrence ?? c.name).foregroundStyle(theme.ink)
                        Spacer()
                        if c.grounded { Image(systemName: "pin.fill").foregroundStyle(theme.inkSecondary) }
                        Text("\(c.bodies.count)").monospacedDigit().foregroundStyle(theme.inkSecondary)
                    }
                    .font(.system(size: 15))
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.assembly.count > 6 {
                Text("\(model.assembly.count - 6) more in Items").font(.footnote).foregroundStyle(theme.inkSecondary)
            }
            TouchKVRow(label: "Board", value: pcb.linkedRevision.map { "Revision \($0) in 3D" } ?? "Not in 3D", divider: false)
            TouchFlowRows(flow: flow, stage: .assemble, open: open)
        }
    }
}

/// Render: shots of the current design through the engine's renderer.
struct TouchRenderInspector: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let flow: FlowModel
    let open: (Workspace) -> Void

    var body: some View {
        TouchInspectorCard(title: "Render", symbol: "camera.aperture", subtitle: flow.revisionName(of: "render") ?? "No shots yet") {
            TouchKVRow(label: "Subject", value: ProjectTitle.of(flow: flow, design: model))
            TouchKVRow(label: "Bodies", value: "\(model.snapshot.bodies.count)", divider: false)
            HStack(spacing: 10) {
                Button("Check Scene") { model.run("render.preflight") }
                    .buttonStyle(.bordered).frame(minHeight: VFSize.touchTarget)
                Spacer()
                Button("Render Shot") { model.run("render.start") }
                    .buttonStyle(.vfPrimary).frame(minHeight: VFSize.touchTarget)
            }
            .padding(.vertical, 8)
            if let m = model.message {
                Text(m).font(.footnote).foregroundStyle(model.messageIsError ? theme.danger : theme.inkSecondary)
            }
            TouchFlowRows(flow: flow, stage: .render, open: open)
        }
    }
}

/// Make: what the build bundle needs, the stale inputs, and the exports.
struct TouchMakeInspector: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let open: (Workspace) -> Void
    let export: (ExportKind) -> Void
    let showBom: () -> Void

    var body: some View {
        let _ = flow.version
        TouchInspectorCard(title: "Make", symbol: "shippingbox", subtitle: flow.revisionName(of: "make") ?? "Bundle not built yet") {
            VFCaption("Inputs").padding(.top, 10)
            // What this product's bundle is built from (the hand has no generated frame).
            let inputs = Set(flow.node("make.bundle")?.consumes.map(\.id) ?? [])
            ForEach(flow.outputs().filter { inputs.contains($0.id) }) { o in
                Button { if let w = Workspace(stage: o.stage) { open(w) } } label: {
                    HStack(spacing: 8) {
                        VFStatusDot(status: o.status.vfStatus, size: 7)
                        Text(o.revision_name ?? o.label).foregroundStyle(theme.ink)
                        Spacer()
                        Text(o.status == .current ? "Ready" : PipelineWords.describe(o.status)).font(.footnote).foregroundStyle(theme.inkSecondary)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(theme.inkTertiary)
                    }
                    .font(.system(size: 15))
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            VFCaption("Export").padding(.top, 8)
            exportRow("STEP", "Solid model for any CAD", "doc") { export(.step) }
            exportRow("STL", "Mesh for printing", "doc") { export(.stl) }
            exportRow("Design", "This design, to open again", "doc.richtext") { export(.design) }
            exportRow("KiCad Board", "The board, as a .kicad_pcb", "cpu") { export(.kicad) }
            exportRow("Bill of Materials", "Parts, quantities and prices", "list.bullet.rectangle") { showBom() }
        }
    }

    private func exportRow(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(theme.accentText).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(theme.ink)
                    Text(detail).font(.footnote).foregroundStyle(theme.inkSecondary)
                }
                Spacer()
                Image(systemName: "square.and.arrow.up").font(.footnote).foregroundStyle(theme.inkTertiary)
            }
            .font(.system(size: 15))
            .frame(minHeight: VFSize.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Export \(title)")
    }
}

/// Train: the trainer's settings and curve beside the flight it learns from.
struct TouchTrainInspector: View {
    @Environment(\.viaFormTheme) private var theme
    let sim: SimModel
    let flow: FlowModel
    let open: (Workspace) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "brain").font(.system(size: 19))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Training").font(.system(size: 18, weight: .semibold))
                    Text(flow.revisionName(of: "train") ?? "No policy yet").font(.system(size: 13)).foregroundStyle(theme.inkSecondary)
                }
                Spacer()
            }
            .foregroundStyle(theme.ink)
            .frame(minHeight: 52)
            .padding(.horizontal, 18)
            Form { SimTrainingSection(model: sim, training: sim.training) }
                .scrollContentBackground(.hidden)
                .frame(height: 340)
        }
        .padding(.vertical, 8)
        .frame(width: VFSize.touchInspector)
        .vfSurface(.floating, radius: 18)
    }
}
#endif
