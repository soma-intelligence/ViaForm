#if os(macOS)
import SwiftUI

/// The sidebar of the project window: BROWSER (what the open stage holds) over PIPELINE OUTPUTS
/// (every artifact with its state, the reason when stale, and Update), pinned to the bottom.
/// The design workspaces list the 3D model (document, origin, components, bodies, sketches,
/// parameters) with their editing actions; the other stages list what they reported to the flow.
/// Both are real outline lists: arrows, type-select, Shift and Command multi-select, Return and
/// double-click for the row's main action, Delete, and context menus on the selection.
struct BrowserSidebar: View {
    @Environment(\.viaFormTheme) private var theme
    let workspace: Workspace
    let model: DesignModel
    let flow: FlowModel
    let actions: StageActions
    var assemble: AssembleModel?

    var body: some View {
        VStack(spacing: 0) {
            header(String(localized: "Browser"))
            Group {
                if let assemble {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            AssembleOutline(model: assemble, title: ProjectTitle.of(flow: flow, design: model))
                        }
                        .padding(.vertical, VFSpace.xs)
                        .padding(.horizontal, VFSpace.xs)
                    }
                } else if StageActions.designLike.contains(workspace) {
                    DesignOutline(model: model, title: ProjectTitle.of(flow: flow, design: model))
                } else {
                    FlowOutline(flow: flow, stage: workspace.stage)
                }
            }
            .frame(maxHeight: .infinity)
            VFHairline()
            PipelineOutputs(flow: flow, actions: actions)
        }
        .background(theme.panel)
    }

    private func header(_ title: String) -> some View {
        HStack {
            VFCaption(title)
            Spacer()
        }
        .padding(.horizontal, VFSpace.l)
        .frame(height: 28)
        .accessibilityAddTraits(.isHeader)
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
                    Button("Update All") { actions.updateAll() }
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
                actionTitle: { a in actions.rebuilds(a.plan) ? String(localized: "Update") : String(localized: "Open") })
            }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.bottom, VFSpace.m)
    }
}

/// What a non-design stage reported to the flow: its artifacts and their items, with eye and
/// lock. A list with the flow's selection: click replaces, Shift extends, Command toggles.
struct FlowOutline: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: String

    var body: some View {
        let rows = flow.tree(stage)
        List(selection: selection(rows)) {
            ForEach(rows) { r in
                row(r)
                    .tag(r.id)
                    .typeSelectEquivalent(Text(r.name))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, VFSize.macRow)
        .contextMenu(forSelectionType: String.self) { ids in
            menu(rows.filter { ids.contains($0.id) })
        }
        .overlay {
            if rows.isEmpty {
                Text("Nothing built in this stage yet.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .padding(VFSpace.m)
            }
        }
    }

    private func selection(_ rows: [FlowModel.TreeRow]) -> Binding<Set<String>> {
        Binding(get: { Set(rows.filter(\.selected).map(\.id)) },
                set: { ids in
                    // Keep the tree's order, so the flow sees the rows top to bottom.
                    flow.select(rows.map(\.id).filter(ids.contains), in: stage)
                })
    }

    @ViewBuilder private func menu(_ picked: [FlowModel.TreeRow]) -> some View {
        if !picked.isEmpty {
            // Only the relevant one of Hide and Show, Lock and Unlock.
            if picked.contains(where: \.visible) {
                Button("Hide") { for r in picked { flow.setVisible(r.id, false) } }
            } else {
                Button("Show") { for r in picked { flow.setVisible(r.id, true) } }
            }
            if picked.contains(where: { !$0.locked }) {
                Button("Lock") { for r in picked { flow.setLocked(r.id, true) } }
            } else {
                Button("Unlock") { for r in picked { flow.setLocked(r.id, false) } }
            }
        }
    }

    private func row(_ r: FlowModel.TreeRow) -> some View {
        HStack(spacing: VFSpace.s) {
            Image(systemName: symbol(r.kind)).foregroundStyle(theme.inkSecondary).frame(width: 16)
                .accessibilityHidden(true)
            Text(r.name).lineLimit(1).opacity(r.shown ? 1 : 0.55)
            if let d = r.detail, !d.isEmpty { Text(d).foregroundStyle(theme.inkTertiary).lineLimit(1) }
            Spacer(minLength: VFSpace.xs)
            if let s = r.status { VFStatusDot(status: s.vfStatus) }
            VFIconButton(r.locked ? "lock.fill" : "lock.open",
                         label: r.locked ? String(localized: "Unlock \(r.name)") : String(localized: "Lock \(r.name)"),
                         size: 10, tint: r.locked ? theme.ink : theme.inkTertiary) {
                flow.setLocked(r.id, !r.locked)
            }
            VFIconButton(r.visible ? "eye" : "eye.slash",
                         label: r.visible ? String(localized: "Hide \(r.name)") : String(localized: "Show \(r.name)"),
                         size: 10) {
                flow.setVisible(r.id, !r.visible)
            }
        }
        .font(VFFont.row)
        .foregroundStyle(theme.ink)
        .padding(.leading, CGFloat(r.depth) * 14)
        .accessibilityElement(children: .combine)
        .accessibilityValue(r.shown ? Text("") : Text("Hidden"))
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

/// A row of the 3D model's tree, as the list's selection value.
enum BrowserItem: Hashable {
    case document
    case units
    case plane(String)
    case component(Int)
    case body(String)
    case sketch(Int)
    case parameter(String)
}

/// The 3D model's tree as an outline list. Selecting bodies selects them in the model
/// (`model.selectedBodies`, the same set the viewport shows): click replaces, Shift extends,
/// Command toggles. Return or a double-click runs a row's main action (sketch on a plane, edit a
/// sketch, select a component's bodies, rename a body in place); the context menu holds Rename,
/// Hide or Show, Delete (undoable, with Undo in the toast) and the row's verbs. A rename commits on
/// Return, Esc cancels it, and a refused name says why under the field.
struct DesignOutline: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel
    /// The product's name, the same as the window title.
    var title: String = ""
    @State private var open: Set<String> = ["Components", "Bodies", "Sketches"]
    /// Bodies hidden from here, while the snapshot does not report visibility.
    @State private var hidden: Set<String> = []
    /// The selected rows that are not bodies (planes, sketches, components...).
    @State private var others: Set<BrowserItem> = []
    /// The body being renamed in place, its draft name and why the last try was refused.
    @State private var renaming: String?
    @State private var draft = ""
    @State private var renameError: String?
    @FocusState private var renameFocused: Bool

    private static let planes = ["XY", "XZ", "YZ"]

    var body: some View {
        List(selection: selection) {
            Label {
                Text(title.isEmpty ? model.snapshot.name : title).fontWeight(.semibold)
            } icon: {
                Image(systemName: "doc.fill").foregroundStyle(theme.inkSecondary)
            }
            .tag(BrowserItem.document)
            folder("Settings", String(localized: "Settings"), "gearshape") {
                Label { Text("Units: \(model.snapshot.units)") } icon: { Image(systemName: "ruler").foregroundStyle(theme.inkSecondary) }
                    .tag(BrowserItem.units)
            }
            folder("Origin", String(localized: "Origin"), "scope") {
                ForEach(Self.planes, id: \.self) { p in
                    Label { Text("\(p) Plane") } icon: { Image(systemName: "square").foregroundStyle(theme.inkSecondary) }
                        .tag(BrowserItem.plane(p))
                        .typeSelectEquivalent(Text("\(p) Plane"))
                        .help("Return or double-click to sketch on \(p)")
                        .accessibilityAction(named: Text("Sketch on \(p)")) { model.startSketch(p) }
                }
            }
            if !model.assembly.isEmpty {
                folder("Components", String(localized: "Components"), "square.stack.3d.up") {
                    ForEach(model.assembly) { c in componentRow(c).tag(BrowserItem.component(c.id)) }
                }
            }
            folder("Bodies", String(localized: "Bodies"), "cube.fill") {
                ForEach(model.snapshot.bodies) { b in
                    bodyRow(b)
                        .tag(BrowserItem.body(b.name))
                        .typeSelectEquivalent(Text(b.name))
                        .help("Return to rename")
                }
            }
            folder("Sketches", String(localized: "Sketches"), "pencil.and.outline") {
                ForEach(model.snapshot.sketches) { s in
                    Label { Text(s.name).lineLimit(1) } icon: { Image(systemName: "pencil.line").foregroundStyle(theme.inkSecondary) }
                        .tag(BrowserItem.sketch(s.id))
                        .typeSelectEquivalent(Text(s.name))
                        .help("Return or double-click to edit the sketch")
                        .accessibilityAction(named: Text("Edit Sketch")) { editSketch(s.id) }
                }
            }
            if !model.snapshot.params.isEmpty {
                folder("Parameters", String(localized: "Parameters"), "function") {
                    ForEach(model.snapshot.params) { p in
                        Label { Text("\(p.name) = \(p.expression)").lineLimit(1) } icon: {
                            Image(systemName: "number").foregroundStyle(theme.inkSecondary)
                        }
                        .tag(BrowserItem.parameter(p.name))
                        .typeSelectEquivalent(Text(p.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, VFSize.macRow)
        .font(VFFont.row)
        .contextMenu(forSelectionType: BrowserItem.self) { items in
            menu(items)
        } primaryAction: { items in
            primary(items)
        }
        .onDeleteCommand { delete(bodies(in: selection.wrappedValue)) }
        .onAppear {
            // Screenshot hook: --rename=Body opens the in-place rename field on that body.
            if let name = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--rename=") })?.dropFirst(9) {
                startRename(String(name))
            }
        }
    }

    // MARK: Selection

    /// The list's selection: the model's selected bodies plus the other rows picked here. A
    /// component counts as selected while all its bodies are.
    private var selection: Binding<Set<BrowserItem>> {
        Binding(get: {
            var s = others.filter { item in
                guard case let .component(id) = item else { return true }
                guard let c = model.assembly.first(where: { $0.id == id }), !c.bodies.isEmpty else { return false }
                return Set(c.bodies).isSubset(of: model.selectedBodies)
            }
            for b in model.selectedBodies { s.insert(.body(b)) }
            return s
        }, set: { apply($0) })
    }

    private func apply(_ new: Set<BrowserItem>) {
        let old = selection.wrappedValue
        var picked = bodies(in: new)
        // A component picked here brings its bodies; one dropped takes them away.
        let was = components(in: old), now = components(in: new)
        for c in model.assembly where now.contains(c.id) && !was.contains(c.id) { picked.formUnion(c.bodies) }
        for c in model.assembly where was.contains(c.id) && !now.contains(c.id) { picked.subtract(c.bodies) }
        others = new.filter { if case .body = $0 { false } else { true } }
        if picked != model.selectedBodies {
            // Picking in the browser replaces the viewport's face and edge picks.
            if !picked.isEmpty { model.selection = [] }
            model.selectedBodies = picked
        }
    }

    private func bodies(in items: Set<BrowserItem>) -> Set<String> {
        Set(items.compactMap { if case let .body(n) = $0 { n } else { nil } })
    }

    private func components(in items: Set<BrowserItem>) -> Set<Int> {
        Set(items.compactMap { if case let .component(id) = $0 { id } else { nil } })
    }

    // MARK: Actions

    @ViewBuilder private func menu(_ items: Set<BrowserItem>) -> some View {
        let names = bodies(in: items)
        if items.count == 1, let item = items.first {
            switch item {
            case let .plane(p):
                Button("Sketch on \(p)") { model.startSketch(p) }
            case let .sketch(id):
                Button("Edit Sketch") { editSketch(id) }
            case let .component(id):
                Button("Select Bodies") { selectComponent(id) }
            default:
                EmptyView()
            }
        }
        if !names.isEmpty {
            // Only the relevant one of Hide and Show.
            if names.contains(where: { !isHidden($0) }) {
                Button(names.count == 1 ? String(localized: "Hide") : String(localized: "Hide \(names.count) Bodies")) {
                    setVisible(names, false)
                }
            } else {
                Button(names.count == 1 ? String(localized: "Show") : String(localized: "Show \(names.count) Bodies")) {
                    setVisible(names, true)
                }
            }
            if names.count == 1, let name = names.first {
                Button("Rename") { startRename(name) }
            }
            Divider()
            Button(role: .destructive) { delete(names) } label: {
                Text(names.count == 1 ? String(localized: "Delete") : String(localized: "Delete \(names.count) Bodies"))
            }
        }
    }

    /// Return or a double-click on a single row.
    private func primary(_ items: Set<BrowserItem>) {
        guard items.count == 1, let item = items.first else { return }
        switch item {
        case let .plane(p): model.startSketch(p)
        case let .sketch(id): editSketch(id)
        case let .component(id): selectComponent(id)
        case let .body(name): startRename(name)
        default: break
        }
    }

    // MARK: Rename

    private func startRename(_ name: String) {
        draft = name
        renameError = nil
        renaming = name
        DispatchQueue.main.async { renameFocused = true }
    }

    /// Return: rename through the engine (one undoable step); a refused name keeps the field
    /// open with the reason under it.
    private func commitRename() {
        guard let old = renaming else { return }
        if let why = model.renameBody(old, to: draft) {
            renameError = why
            renameFocused = true
            return
        }
        endRename()
    }

    private func endRename() {
        renaming = nil
        renameError = nil
        draft = ""
    }

    private func editSketch(_ id: Int) {
        model.run("sketch.edit", ["sketch": id])
        model.tool = .line
    }

    private func selectComponent(_ id: Int) {
        guard let c = model.assembly.first(where: { $0.id == id }) else { return }
        model.selection = []
        model.selectedBodies = Set(c.bodies)
    }

    private func isHidden(_ name: String) -> Bool {
        if let v = model.snapshot.bodies.first(where: { $0.name == name })?.visible { return !v }
        return hidden.contains(name)
    }

    private func setVisible(_ names: Set<String>, _ visible: Bool) {
        for n in names {
            if visible { hidden.remove(n) } else { hidden.insert(n) }
            model.toggleBodyVisibility(n, visible: visible)
        }
    }

    /// Deletes bodies through the design engine (one undoable step), with Undo in the toast.
    private func delete(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        model.selection = []
        model.selectedBodies = names
        model.deleteSelection()
        let step = DesignStep(model)
        let text = names.count == 1
            ? String(localized: "Deleted \(names.first ?? "")")
            : WorkspaceMenu.inflected("Deleted ^[\(names.count) body](inflect: true)")
        toasts?.show(text, systemImage: "trash", actionTitle: String(localized: "Undo")) { step.undo() }
    }

    // MARK: Rows

    @ViewBuilder
    private func folder<Content: View>(_ key: String, _ name: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        let body = content()
        DisclosureGroup(isExpanded: Binding(get: { open.contains(key) },
                                            set: { if $0 { open.insert(key) } else { open.remove(key) } })) {
            body
        } label: {
            Label { Text(name) } icon: { Image(systemName: symbol).foregroundStyle(theme.inkSecondary) }
        }
    }

    private func componentRow(_ c: DesignModel.AssemblyPart) -> some View {
        HStack(spacing: VFSpace.s) {
            Label {
                Text(occurrenceName(c)).lineLimit(1)
            } icon: {
                Image(systemName: c.linkedPCB ? "cpu" : "shippingbox").foregroundStyle(c.linkedPCB ? theme.accentText : theme.inkSecondary)
            }
            if c.grounded {
                Image(systemName: "pin.fill").font(VFFont.glyph(9)).foregroundStyle(theme.inkSecondary)
                    .help("Grounded").accessibilityLabel("Grounded")
            }
            if c.linkedPCB {
                Image(systemName: "link").font(VFFont.glyph(9)).foregroundStyle(theme.accentText)
                    .help("Linked to the Electronics board").accessibilityLabel("Linked to the Electronics board")
            }
            Spacer(minLength: 0)
        }
        .typeSelectEquivalent(Text(occurrenceName(c)))
        .accessibilityElement(children: .combine)
    }

    private func bodyRow(_ b: DesignSnapshot.Body) -> some View {
        let off = isHidden(b.name)
        return HStack(spacing: VFSpace.s) {
            Label {
                if renaming == b.name {
                    VStack(alignment: .leading, spacing: VFSpace.xxs) {
                        TextField("Body name", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { endRename() }
                            .onChange(of: draft) { _, _ in renameError = nil }
                            .onChange(of: renameFocused) { _, focused in
                                // Clicking away commits, as in Finder; a refused name stays open.
                                if !focused, renaming == b.name, renameError == nil { commitRename() }
                            }
                            .accessibilityLabel(Text("New name for \(b.name)"))
                        if let renameError {
                            InlineError(renameError)
                        }
                    }
                } else {
                    Text(b.name).lineLimit(1).opacity(off ? 0.55 : 1)
                }
            } icon: {
                Image(systemName: "cube").foregroundStyle(theme.inkSecondary)
            }
            Spacer(minLength: 0)
            VFIconButton(off ? "eye.slash" : "eye",
                         label: off ? String(localized: "Show \(b.name)") : String(localized: "Hide \(b.name)"),
                         size: 10) {
                setVisible([b.name], off)
            }
        }
        .accessibilityValue(off ? Text("Hidden") : Text(""))
        .accessibilityAction(named: Text("Rename")) { startRename(b.name) }
    }

    /// "Palm", or "Palm (2)" for a component placed more than once: never the ":1" suffix.
    private func occurrenceName(_ c: DesignModel.AssemblyPart) -> String {
        let count = model.assembly.filter { $0.name == c.name }.count
        guard count > 1 else { return c.name }
        let index = c.occurrence?.split(separator: ":").last.flatMap { Int($0) } ?? 1
        return "\(c.name) (\(index))"
    }
}
#endif
