#if os(macOS)
import SwiftUI

/// The sidebar of the project window: BROWSER (what the open stage holds) over PIPELINE OUTPUTS
/// (every artifact with its state, the reason when stale, and Update), pinned to the bottom.
/// The design workspaces list the 3D model (document, origin, components, bodies, sketches,
/// parameters) with their editing actions; the other stages list what they reported to the flow.
struct BrowserSidebar: View {
    @Environment(\.viaFormTheme) private var theme
    let workspace: Workspace
    let model: DesignModel
    let flow: FlowModel
    let actions: StageActions
    var assemble: AssembleModel?

    var body: some View {
        VStack(spacing: 0) {
            header("Browser")
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if let assemble {
                        AssembleOutline(model: assemble, title: ProjectTitle.of(flow: flow, design: model))
                    } else if StageActions.designLike.contains(workspace) {
                        DesignOutline(model: model, title: ProjectTitle.of(flow: flow, design: model))
                    } else {
                        FlowOutline(flow: flow, stage: workspace.stage)
                    }
                }
                .padding(.vertical, VFSpace.xs)
                .padding(.horizontal, VFSpace.xs)
            }
            VFHairline()
            PipelineOutputs(flow: flow, actions: actions)
        }
        .background(theme.panel)
    }

    private func header(_ title: String, trailing: AnyView? = nil) -> some View {
        HStack {
            VFCaption(title)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, VFSpace.l)
        .frame(height: 28)
    }
}

/// PIPELINE OUTPUTS: every artifact of the product, its revision and state, the reason and the
/// update when it is stale or failed. A row opens its stage.
struct PipelineOutputs: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let actions: StageActions

    var body: some View {
        let outputs = flow.outputs()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VFCaption("Pipeline outputs")
                Spacer()
                let n = outputs.filter { $0.status == .stale || $0.status == .failed }.count
                if n > 0 {
                    Button("Update all") { actions.updateAll() }
                        .buttonStyle(.borderless)
                        .font(VFFont.micro.weight(.semibold))
                        .foregroundStyle(theme.accentText)
                        .help("Rebuild the stale stages, upstream first")
                }
            }
            .frame(height: 28)
            ForEach(outputs) { o in
                OutputRow(output: o, onOpen: {
                    if let w = Workspace(stage: o.stage) { actions.open(w) }
                }, onAction: { a in actions.update(a.plan) },
                actionTitle: { a in actions.rebuilds(a.plan) ? "Update" : "Open" })
            }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.bottom, VFSpace.m)
    }
}

/// What a non-design stage reported to the flow: its artifacts and their items, with eye and lock.
struct FlowOutline: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: String

    var body: some View {
        let rows = flow.tree(stage)
        if rows.isEmpty {
            Text("Nothing built in this stage yet.")
                .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                .padding(VFSpace.m)
        }
        ForEach(rows) { r in
            HStack(spacing: VFSpace.s) {
                Image(systemName: symbol(r.kind)).foregroundStyle(theme.inkSecondary).frame(width: 16)
                Text(r.name).lineLimit(1).opacity(r.shown ? 1 : 0.45)
                if let d = r.detail, !d.isEmpty { Text(d).foregroundStyle(theme.inkTertiary).lineLimit(1) }
                Spacer(minLength: VFSpace.xs)
                if let s = r.status { VFStatusDot(status: s.vfStatus) }
                Button { flow.setLocked(r.id, !r.locked) } label: {
                    Image(systemName: r.locked ? "lock.fill" : "lock.open").font(.system(size: 10))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(r.locked ? theme.ink : theme.inkTertiary)
                .opacity(r.locked ? 1 : 0.6)
                .help(r.locked ? "Unlock" : "Lock")
                .accessibilityLabel(r.locked ? "Unlock \(r.name)" : "Lock \(r.name)")
                Button { flow.setVisible(r.id, !r.visible) } label: {
                    Image(systemName: r.visible ? "eye" : "eye.slash").font(.system(size: 10))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.inkSecondary)
                .help(r.visible ? "Hide" : "Show")
                .accessibilityLabel(r.visible ? "Hide \(r.name)" : "Show \(r.name)")
            }
            .font(VFFont.row)
            .foregroundStyle(theme.ink)
            .padding(.leading, CGFloat(VFSpace.m + CGFloat(r.depth) * 14))
            .padding(.trailing, VFSpace.m)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(r.selected ? theme.selection : .clear))
            .contentShape(Rectangle())
            .onTapGesture { flow.select([r.id], in: stage) }
            .accessibilityAddTraits(r.selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { flow.select([r.id], in: stage) }
        }
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "artifact": "shippingbox"
        case "component": "memorychip"
        case "net": "point.topleft.down.to.point.bottomright.curvepath"
        case "body": "cube"
        case "sketch": "pencil.and.outline"
        case "occurrence": "square.stack.3d.up"
        case "grounded": "pin"
        case "run", "flight": "wind"
        case "policy": "brain"
        case "shot", "render": "photo"
        case "file", "export": "doc"
        default: "circle.grid.2x1"
        }
    }
}

/// The 3D model's tree, with the actions of the old floating browser (sketch on a plane, edit a
/// sketch, hide, show, delete a body, select a component's bodies).
struct DesignOutline: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    /// The product's name, the same as the window title.
    var title: String = ""
    @State private var open: Set<String> = ["Components", "Bodies", "Sketches"]
    @State private var hidden: Set<String> = []

    var body: some View {
        row(0, "doc.fill", title.isEmpty ? model.snapshot.name : title, bold: true)
        folder("Settings", "gearshape") {
            row(2, "ruler", "Units: \(model.snapshot.units)")
        }
        folder("Axes", "scope") {
            ForEach(["XY", "XZ", "YZ"], id: \.self) { p in
                row(2, "square", "\(p) plane").onTapGesture(count: 2) { model.startSketch(p) }.help("Double-click to sketch on \(p)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Sketch on \(p)") { model.startSketch(p) }
            }
        }
        if !model.assembly.isEmpty {
            folder("Components", "square.stack.3d.up") {
                ForEach(model.assembly) { c in
                    HStack(spacing: VFSpace.s) {
                        Image(systemName: c.linkedPCB ? "cpu" : "shippingbox").foregroundStyle(c.linkedPCB ? theme.accentText : theme.inkSecondary).frame(width: 16)
                        Text(occurrenceName(c)).lineLimit(1)
                        if c.grounded { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(theme.inkSecondary).help("Grounded") }
                        if c.linkedPCB { Image(systemName: "link").font(.system(size: 9)).foregroundStyle(theme.accentText).help("Linked to the Electronics board") }
                        Spacer()
                    }
                    .font(VFFont.row).foregroundStyle(theme.ink)
                    .padding(.leading, 38).frame(height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedBodies = Set(c.bodies) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.selectedBodies = Set(c.bodies) }
                }
            }
        }
        folder("Bodies", "cube.fill") {
            ForEach(model.snapshot.bodies) { b in
                row(2, "cube", b.name, selected: model.selectedBodies.contains(b.name), eye: b.name)
                    .onTapGesture { toggle(b.name) }
                    .accessibilityAddTraits(model.selectedBodies.contains(b.name) ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { toggle(b.name) }
                    .contextMenu {
                        Button("Hide") { model.toggleBodyVisibility(b.name, visible: false) }
                        Button("Show") { model.toggleBodyVisibility(b.name, visible: true) }
                        Button("Delete") { model.selectedBodies = [b.name]; model.deleteSelection() }
                    }
            }
        }
        folder("Sketches", "pencil.and.outline") {
            ForEach(model.snapshot.sketches) { s in
                row(2, "pencil.line", s.name)
                    .accessibilityAction(named: "Edit sketch") { model.run("sketch.edit", ["sketch": s.id]); model.tool = .line }
                    .contextMenu { Button("Edit Sketch") { model.run("sketch.edit", ["sketch": s.id]); model.tool = .line } }
                    .onTapGesture(count: 2) { model.run("sketch.edit", ["sketch": s.id]); model.tool = .line }
            }
        }
        if !model.snapshot.params.isEmpty {
            folder("Parameters", "function") {
                ForEach(model.snapshot.params) { p in row(2, "number", "\(p.name) = \(p.expression)") }
            }
        }
    }

    private func toggle(_ body: String) {
        if model.selectedBodies.contains(body) { model.selectedBodies.remove(body) } else { model.selectedBodies.insert(body) }
    }

    /// "Palm", or "Palm (2)" for a component placed more than once: never the ":1" suffix.
    private func occurrenceName(_ c: DesignModel.AssemblyPart) -> String {
        let count = model.assembly.filter { $0.name == c.name }.count
        guard count > 1 else { return c.name }
        let index = c.occurrence?.split(separator: ":").last.flatMap { Int($0) } ?? 1
        return "\(c.name) (\(index))"
    }

    @ViewBuilder
    private func folder<Content: View>(_ name: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if open.contains(name) { open.remove(name) } else { open.insert(name) }
        } label: {
            HStack(spacing: VFSpace.s) {
                Image(systemName: open.contains(name) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold)).frame(width: 10)
                    .foregroundStyle(theme.inkTertiary)
                Image(systemName: symbol).foregroundStyle(theme.inkSecondary).frame(width: 16)
                Text(name)
                Spacer()
            }
            .font(VFFont.row).foregroundStyle(theme.ink)
            .padding(.leading, 14).frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open.contains(name) { content() }
    }

    private func row(_ indent: Int, _ symbol: String, _ text: String, bold: Bool = false, selected: Bool = false, eye body: String? = nil) -> some View {
        HStack(spacing: VFSpace.s) {
            Image(systemName: symbol).foregroundStyle(selected ? theme.onAccent : theme.inkSecondary).frame(width: 16)
            Text(text).fontWeight(bold ? .semibold : .regular).lineLimit(1)
                .opacity(body.map { hidden.contains($0) ? 0.45 : 1 } ?? 1)
            Spacer()
            if let body {
                Button {
                    let show = hidden.contains(body)
                    if show { hidden.remove(body) } else { hidden.insert(body) }
                    model.toggleBodyVisibility(body, visible: show)
                } label: {
                    Image(systemName: hidden.contains(body) ? "eye.slash" : "eye").font(.system(size: 10)).frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? theme.onAccent : theme.inkSecondary)
                .help(hidden.contains(body) ? "Show" : "Hide")
                .accessibilityLabel(hidden.contains(body) ? "Show \(body)" : "Hide \(body)")
            }
        }
        .font(VFFont.row)
        .foregroundStyle(selected ? theme.onAccent : theme.ink)
        .padding(.leading, CGFloat(10 + indent * 14)).padding(.trailing, VFSpace.s)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(selected ? theme.accent : .clear))
        .contentShape(Rectangle())
    }
}
#endif
