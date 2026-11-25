#if os(iOS)
import SwiftUI

// What each stage puts in the iPad's inspector card, and the cards of the stages that share the
// design viewport (Assemble, Render, Make) or the flight scene (Train).

/// The design card: the armed tool with its live value, or the selection, or the design.
struct TouchDesignInspector: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    let flow: FlowModel
    let stage: Workspace
    let open: (Workspace) -> Void

    var body: some View {
        let _ = units
        Group {
            if model.tool != .select, model.tool != .sketch {
                toolCard
            } else if !model.bodiesInSelection.isEmpty {
                selectionCard
            } else {
                designCard
            }
        }
        // The card stays while the tool runs and after it ends: the feature session follows.
        .modifier(FeatureSessionSync(model: model))
    }

    // MARK: Tool

    private var toolCard: some View {
        let editing = FeatureSession.of(model).editing
        return TouchInspectorCard(title: editing.map { String(localized: "Edit \($0.name)") } ?? model.tool.touchLabel,
                                  symbol: model.tool.symbol, subtitle: ToolSession.hint(model)) {
            TouchToolModePill(model: model, compact: true)
            ToolSession(model: model, layout: .card)
        }
    }

    // MARK: Selection

    private var selectionCard: some View {
        let names = model.bodiesInSelection
        let bodies = model.snapshot.bodies.filter { names.contains($0.name) }
        let volume = bodies.compactMap(\.volume_mm3).reduce(0, +)
        let component = model.assembly.first { c in c.bodies.contains { names.contains($0) } }
        let none = String(localized: "None")
        return TouchInspectorCard(title: names.count == 1 ? names[0] : String(localized: "\(names.count) bodies"), symbol: "cube",
                                  subtitle: component.map { String(localized: "In \($0.occurrence ?? $0.name)") }) {
            TouchKVRow(label: String(localized: "Volume"), value: volume > 0 ? VFFormat.volume(volume) : none)
            TouchKVRow(label: String(localized: "Mass (PA12)"), value: volume > 0 ? VFFormat.mass(volume * 1.01e-3) : none)
            TouchKVRow(label: String(localized: "Faces"), value: "\(bodies.compactMap(\.faces).reduce(0, +))")
            TouchKVRow(label: String(localized: "Material"), value: bodies.first?.material ?? "PA12", divider: false)
            TouchFlowRows(flow: flow, stage: stage, open: open)
        }
    }

    private var designCard: some View {
        TouchInspectorCard(title: ProjectTitle.of(flow: flow, design: model), symbol: "cube.transparent", subtitle: flow.revisionName(of: stage.stage)) {
            TouchKVRow(label: String(localized: "Bodies"), value: "\(model.snapshot.bodies.count)")
            TouchKVRow(label: String(localized: "Components"), value: "\(model.assembly.count)")
            TouchKVRow(label: String(localized: "Sketches"), value: "\(model.snapshot.sketches.count)")
            TouchKVRow(label: String(localized: "Parameters"), value: "\(model.snapshot.params.count)", divider: false)
            TouchFlowRows(flow: flow, stage: stage, open: open)
        }
    }
}

/// Assemble: the components, what is grounded and what carries the board.
struct TouchAssembleInspector: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let pcb: PCBModel
    let flow: FlowModel
    let open: (Workspace) -> Void

    var body: some View {
        let _ = units
        TouchInspectorCard(title: String(localized: "Assembly"), symbol: "gearshape.2",
                           subtitle: flow.revisionName(of: "assemble") ?? String(localized: "Not built yet")) {
            if model.assembly.isEmpty {
                Text("No components yet. Make components in Design, or send the board to 3D from Electronics.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary).padding(.vertical, VFSpace.m)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.assembly.prefix(6)) { c in
                Button { model.selectedBodies = Set(c.bodies) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: c.linkedPCB ? "cpu" : "square.stack.3d.up").foregroundStyle(c.linkedPCB ? theme.accentText : theme.inkSecondary)
                            .accessibilityHidden(true)
                        Text(c.occurrence ?? c.name).foregroundStyle(theme.ink)
                        Spacer()
                        if c.grounded {
                            Image(systemName: "pin.fill").foregroundStyle(theme.inkSecondary).accessibilityLabel(Text("Grounded"))
                        }
                        Text("^[\(c.bodies.count) body](inflect: true)").foregroundStyle(theme.inkSecondary)
                    }
                    .font(VFFont.row)
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .accessibilityHint(Text("Selects its bodies"))
            }
            if model.assembly.count > 6 {
                Text("\(model.assembly.count - 6) more in Items").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            TouchKVRow(label: String(localized: "Board"), value: pcb.linkedRevision.map { String(localized: "Revision \($0) in 3D") } ?? String(localized: "Not in 3D"), divider: false)
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
        TouchInspectorCard(title: String(localized: "Render"), symbol: "camera.aperture",
                           subtitle: flow.revisionName(of: "render") ?? String(localized: "No shots yet")) {
            TouchKVRow(label: String(localized: "Subject"), value: ProjectTitle.of(flow: flow, design: model))
            TouchKVRow(label: String(localized: "Bodies"), value: "\(model.snapshot.bodies.count)", divider: false)
            HStack(spacing: VFSpace.m) {
                Button("Check Scene") { model.run("render.preflight") }
                    .buttonStyle(.vfSecondary).frame(minHeight: VFSize.touchTarget)
                    .vfEngineGate()
                Spacer()
                Button("Render Shot") { model.run("render.start") }
                    .buttonStyle(.vfPrimary).frame(minHeight: VFSize.touchTarget)
                    .vfEngineGate()
            }
            .padding(.vertical, VFSpace.m)
            if let m = model.message {
                if model.messageIsError {
                    InlineError(m, retryTitle: String(localized: "Check Scene"), retry: { model.run("render.preflight") }, dismiss: { model.flash(nil) })
                } else {
                    Text(m).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
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
        TouchInspectorCard(title: String(localized: "Make"), symbol: "shippingbox",
                           subtitle: flow.revisionName(of: "make") ?? String(localized: "Bundle not built yet")) {
            VFCaption("Inputs").padding(.top, VFSpace.m)
            // What this product's bundle is built from (the hand has no generated frame).
            let inputs = Set(flow.node("make.bundle")?.consumes.map(\.id) ?? [])
            ForEach(flow.outputs().filter { inputs.contains($0.id) }) { o in
                Button { if let w = Workspace(stage: o.stage) { open(w) } } label: {
                    HStack(spacing: 8) {
                        VFStatusDot(status: o.status.vfStatus, size: 7)
                        Text(o.revision_name ?? o.label).foregroundStyle(theme.ink)
                        Spacer()
                        Text(o.status == .current ? String(localized: "Ready") : PipelineWords.describe(o.status)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                        Image(systemName: "chevron.right").font(VFFont.small).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
                    }
                    .font(VFFont.row)
                    .frame(minHeight: VFSize.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .accessibilityElement(children: .combine)
            }
            VFCaption("Export").padding(.top, VFSpace.m)
            exportRow(String(localized: "STEP"), String(localized: "Solid model for any CAD"), "doc") { export(.step) }
            exportRow(String(localized: "STL"), String(localized: "Mesh for printing"), "doc") { export(.stl) }
            exportRow(String(localized: "Design"), String(localized: "This design, to open again"), "doc.richtext") { export(.design) }
            exportRow(String(localized: "KiCad Board"), String(localized: "The board, for KiCad"), "cpu") { export(.kicad) }
            exportRow(String(localized: "Bill of Materials"), String(localized: "Parts, quantities and prices"), "list.bullet.rectangle") { showBom() }
        }
    }

    private func exportRow(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(VFFont.glyph(17)).foregroundStyle(theme.accentText).frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(theme.ink)
                    Text(detail).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                Spacer()
                Image(systemName: "square.and.arrow.up").font(VFFont.small).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
            }
            .font(VFFont.row)
            .frame(minHeight: VFSize.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.vfTouch)
        .accessibilityLabel(String(localized: "Export \(title)"))
        .accessibilityHint(detail)
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
                Image(systemName: "brain").font(VFFont.glyph(19)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Training").font(VFFont.title)
                    Text(flow.revisionName(of: "train") ?? String(localized: "No policy yet")).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .foregroundStyle(theme.ink)
            .frame(minHeight: 52)
            .padding(.horizontal, VFSpace.xl)
            Form { SimTrainingSection(model: sim, training: sim.training) }
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220, idealHeight: 340, maxHeight: 340)
        }
        .padding(.vertical, VFSpace.m)
        .frame(width: VFSize.touchInspector)
        .vfSurface(.floating, radius: VFRadius.touchFloating)
    }
}
// MARK: - Tool session

/// The armed tool's numbers with Cancel and Done: one view for the iPad inspector card and the
/// iPhone bar (P1-27). Done commits one command; Command-Return does the same from a keyboard
/// (plain Return only commits the field being typed in).
struct ToolSession: View {
    @ObservedUnits private var units
    /// `card`: fields and Cancel / Done (the inspector cards); `bar`: the iPhone bar;
    /// `fields`: the fields alone (the iPad rail's option card between Done and Cancel).
    enum Layout { case card, bar, fields }
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    var layout: Layout = .card

    var body: some View {
        let _ = units
        switch layout {
        case .card:
            VStack(alignment: .leading, spacing: VFSpace.m) {
                fields
                buttons.padding(.vertical, VFSpace.m)
            }
            .padding(.top, VFSpace.s)
        case .fields:
            VStack(alignment: .leading, spacing: VFSpace.xs) { fields }
        case .bar:
            VStack(alignment: .leading, spacing: VFSpace.m) {
                HStack(spacing: VFSpace.m) {
                    TouchToolModePill(model: model, compact: true)
                    if let h = Self.hint(model) { Text(h).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1) }
                    Spacer(minLength: 0)
                }
                fields
                buttons
            }
            .padding(VFSpace.m)
            .frame(maxWidth: 900)
            .vfSurface(.floating, radius: VFRadius.touchFloating)
        }
    }

    @ViewBuilder private var fields: some View {
        let session = FeatureSession.of(model)
        if FeatureOptions.tools.contains(session.tool) {
            FeatureDialogFields(model: model, session: session, touch: true, onValueReturn: { TouchResponder.endEditing() })
        } else {
            plainFields
        }
    }

    @ViewBuilder private var plainFields: some View {
        if let v = model.tool.value {
            let unit = VFUnit(symbol: v.unit)
            HStack {
                Text(v.label).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                Spacer()
                NumberField(v.label, value: $model.toolValue, unit: unit, range: v.unit == "mm" ? nil : Self.range(v.unit, v.initial, model.toolValue),
                            step: v.unit == "deg" ? 15 : 1, width: 82)
                    .labelHiddenVisually()
            }
            .frame(minHeight: VFSize.touchTarget)
            if layout == .card {
                Slider(value: $model.toolValue, in: Self.range(v.unit, v.initial, model.toolValue)) {
                    Text(v.label)
                }
                .frame(minHeight: VFSize.touchTarget)
                .accessibilityValue(VFFormat.value(model.toolValue, unit))
            }
        }
        if model.tool == .move {
            MoveDialogRows(session: FeatureSession.of(model), touch: true)
        }
        if model.tool == .mirror {
            VFSegmented(String(localized: "Plane"), selection: $model.mirrorPlane, items: ["XY", "XZ", "YZ"], title: { $0 })
                .frame(minHeight: VFSize.touchTarget)
        }
    }

    private var buttons: some View {
        HStack(spacing: VFSpace.m) {
            Button { FeatureSession.of(model).cancel() } label: {
                Text("Cancel").frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
            }
            .buttonStyle(.vfSecondary)
            Button { Self.finish(model) } label: {
                Text("Done").frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
            }
            .buttonStyle(.vfPrimary)
            .disabled(FeatureSession.of(model).missingInput() != nil)
            .help(String(localized: "Command-Return"))
            .accessibilityHint(Text("Commits the tool. Command-Return on a keyboard."))
            .vfEngineGate()
        }
    }

    /// The armed tool has fields to show (a value, the feature dialog, Move's rows, Mirror's plane).
    @MainActor static func hasFields(_ model: DesignModel) -> Bool {
        FeatureOptions.tools.contains(FeatureSession.of(model).tool) || model.tool.value != nil || model.tool == .move || model.tool == .mirror
    }

    static func range(_ unit: String, _ initial: Double, _ current: Double) -> ClosedRange<Double> {
        if unit == "deg" { return 0...360 }
        if unit.isEmpty { return 3...24 }
        return 0...max(100, initial * 4, current * 1.5)
    }

    static func hint(_ model: DesignModel) -> String? {
        if model.tool.isSketchTool { return TouchSketchHint.text(model) }
        return switch model.tool {
        case .pressPull: model.selection.contains(where: \.isFace) ? nil : String(localized: "Tap a face")
        case .fillet, .chamfer: model.selection.contains(where: \.isEdge) ? nil : String(localized: "Tap edges")
        case .shell: model.selection.contains(where: \.isFace) ? nil : String(localized: "Tap faces to open")
        case .box, .cylinder, .sphere, .torus: String(localized: "Tap where it goes")
        default: nil
        }
    }

    /// Done: one commit. A field still being typed in commits first (focus leaves it), then the
    /// tool finishes on the next turn of the run loop.
    @MainActor static func finish(_ model: DesignModel) {
        if TouchResponder.isEditingText {
            TouchResponder.endEditing()
            Task { @MainActor in
                await Task.yield()
                commit(model)
            }
        } else {
            commit(model)
        }
    }

    @MainActor private static func commit(_ model: DesignModel) {
        let session = FeatureSession.of(model)
        if let why = session.missingInput() {
            model.flash(why, error: true)
            return
        }
        switch model.tool {
        case .move: session.commitMove()
        case .mirror: model.mirrorSelected(); model.tool = .select
        case let t where t.isSketchTool: TouchSketchDone.run(model)
        default: session.commit()
        }
    }
}

/// Done, the tool's options and Cancel next to the tool column on the iPad (the reference's
/// blue check, option rows and red X), for a running tool. Done says what is still missing.
struct TouchToolRailFooter: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    @State private var options = false

    var body: some View {
        let session = FeatureSession.of(model)
        let missing = model.tool.isSketchTool ? nil : session.missingInput()
        // One tile, as in the reference: Done, the tool's options behind a gear, Cancel.
        TouchRailGroup {
            Button { ToolSession.finish(model) } label: {
                TouchRailRow(symbol: "checkmark", title: String(localized: "Done"), subtitle: missing == nil ? nil : ToolSession.hint(model),
                             active: missing == nil, enabled: missing == nil, tint: theme.accentText)
            }
            .buttonStyle(.touchRail)
            .vfDisabled(missing != nil, reason: missing ?? "")
            .help(String(localized: "Command-Return"))
            .accessibilityLabel(Text("Done"))
            .accessibilityHint(Text("Commits the tool. Command-Return on a keyboard."))
            .vfEngineGate()
            ForEach(ToolOptionRows.rows(model)) { row in optionRow(row) }
            if !model.tool.isSketchTool, ToolSession.hasFields(model) {
                Button { options = true } label: {
                    TouchRailRow(symbol: "slider.horizontal.3", title: String(localized: "More Options"))
                }
                .buttonStyle(.touchRail)
                .accessibilityLabel(Text("Options"))
                .popover(isPresented: $options, arrowEdge: .leading) {
                    ToolSession(model: model, layout: .fields)
                        .padding(VFSpace.m)
                        .frame(width: 268, alignment: .leading)
                        .presentationCompactAdaptation(.popover)
                }
            }
            Button {
                if model.tool.isSketchTool { model.tool = .select } else { session.cancel() }
            } label: {
                TouchRailRow(symbol: "xmark", title: String(localized: "Cancel"), tint: theme.danger)
            }
            .buttonStyle(.touchRail)
            .accessibilityLabel(Text("Cancel"))
        }
        .modifier(FeatureSessionSync(model: model))
    }

    /// A choice opens a menu of its values; a switch flips on tap.
    @ViewBuilder private func optionRow(_ row: ToolOptionRow) -> some View {
        if row.choices.isEmpty {
            Button { row.toggle?() } label: {
                TouchRailRow(symbol: row.symbol, title: row.title, subtitle: row.value, active: row.isOn)
            }
            .buttonStyle(.touchRail)
            .accessibilityLabel(Text(row.title))
            .accessibilityValue(Text(row.value))
            .accessibilityAddTraits(row.isOn ? .isSelected : [])
        } else {
            Menu {
                ForEach(row.choices) { c in
                    Toggle(c.title, isOn: Binding(get: { c.on }, set: { if $0 { c.pick() } }))
                }
            } label: {
                TouchRailRow(symbol: row.symbol, title: row.title, subtitle: row.value)
            }
            .menuStyle(.button)
            .modifier(TouchRailPress(rail: true))
            .accessibilityLabel(Text(row.title))
            .accessibilityValue(Text(row.value))
        }
    }
}
#endif
