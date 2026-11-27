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
                        .buttonStyle(.vfGhost(tint: theme.accentText))
                        .font(VFFont.micro.weight(.semibold))
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
    case namedView(String)
    case plane(String)
    case construction(String)
    case component(Int)
    case body(String)
    case sketch(Int)
    case parameter(String)
}

/// The 3D model's tree as an outline list, in Fusion's order: Document Settings, Named Views,
/// Origin, Construction, Components, Bodies, Sketches, Parameters. Selecting bodies selects them
/// in the model (`model.selectedBodies`, the same set the viewport shows): click replaces, Shift
/// extends, Command toggles. Return or a double-click runs a row's main action (sketch on a
/// plane, edit a sketch, select a component's bodies, rename a body in place, restore a named
/// view); the context menu holds Rename, Hide or Show, Delete (undoable, with Undo in the toast)
/// and the row's verbs. Origin planes, construction items, components, bodies and sketches have
/// an eye; a folder's eye hides or shows everything in it. A rename commits on Return, Esc
/// cancels it, and a refused name says why under the field.
struct DesignOutline: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    let model: DesignModel
    /// The product's name, the same as the window title.
    var title: String = ""
    /// Fusion's floating browser: eye before the icon, folder icons, small rows, no Parameters
    /// folder (Change Parameters lives in MODIFY).
    var fusion = false
    @State private var open: Set<String> = ["Components", "Bodies", "Sketches"]
    /// Bodies hidden from here, while the snapshot does not report visibility.
    @State private var hidden: Set<String> = []
    /// Components hidden from here (their placement's eye).
    @State private var hiddenComponents: Set<Int> = []
    /// The selected rows that are not bodies (planes, sketches, components...).
    @State private var others: Set<BrowserItem> = []
    /// The body being renamed in place, its draft name and why the last try was refused.
    @State private var renaming: String?
    @State private var draft = ""
    @State private var renameError: String?
    @FocusState private var renameFocused: Bool
    /// The named view being renamed in place.
    @State private var renamingView: String?
    /// Named views, hidden origin items, body origins, placements and sketch states, read per
    /// revision from the shared cache (the timeline reads the same entry).
    @State private var data = DesignOutlineData()

    private static let planes = ["XY", "XZ", "YZ"]
    private static let units = ["mm", "cm", "m", "in", "ft"]

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: BrowserReveal.shared.request) { _, r in reveal(r, proxy) }
                .onReceive(NotificationCenter.default.publisher(for: .vfRevealInBrowser)) { n in
                    guard (n.object as? DesignModel) === model, let bodies = n.userInfo?["bodies"] as? [String], !bodies.isEmpty else { return }
                    reveal(BrowserReveal.Request(model: ObjectIdentifier(model), folder: "Bodies", item: nil, bodies: Set(bodies), serial: 0), proxy)
                }
        }
        .task(id: model.snapshot.revision) { data = DesignOutlineCache.shared.data(model) }
    }

    private var construction: [DesignSnapshot.Feature] {
        model.snapshot.timeline.filter { DesignOutlineData.constructionTypes.contains($0.type) }
    }

    private var list: some View {
        List(selection: selection) {
            if fusion {
                fusionRoot.tag(BrowserItem.document)
            } else {
                Label {
                    Text(title.isEmpty ? model.snapshot.name : title).fontWeight(.semibold)
                } icon: {
                    Image(systemName: "doc.fill").foregroundStyle(theme.inkSecondary)
                }
                .tag(BrowserItem.document)
            }
            folder("Settings", String(localized: "Document Settings"), "gearshape") {
                HStack {
                    Label { Text("Units: \(model.snapshot.units)") } icon: { Image(systemName: "ruler").foregroundStyle(theme.inkSecondary) }
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(Self.units, id: \.self) { u in
                            Button(u) { model.run("document.units", ["units": u]) }.disabled(u == model.snapshot.units)
                        }
                    } label: { Image(systemName: "chevron.up.chevron.down").font(VFFont.glyph(9)) }
                    .menuStyle(.vfPlain)
                    .help("Change the design's units")
                    .accessibilityLabel("Change units")
                }
                .tag(BrowserItem.units)
            }
            folder("Views", String(localized: "Named Views"), "camera",
                   add: (String(localized: "Save the current view as a named view"), { saveView() })) {
                ForEach(data.views) { v in
                    namedViewRow(v)
                        .tag(BrowserItem.namedView(v.name))
                        .typeSelectEquivalent(Text(v.name))
                        .help("Return or double-click to restore this view")
                }
            }
            folder("Origin", String(localized: "Origin"), "scope",
                   eye: eye(Self.planes.contains { !data.hiddenOrigin.contains($0) }) { v in run(["folder": "origin"], v) }) {
                ForEach(Self.planes, id: \.self) { p in
                    eyeRow(String(localized: "\(p) Plane"), "square", visible: !data.hiddenOrigin.contains(p)) { v in run(["items": [p]], v) }
                        .tag(BrowserItem.plane(p))
                        .typeSelectEquivalent(Text("\(p) Plane"))
                        .help("Return or double-click to sketch on \(p)")
                        .accessibilityAction(named: Text("Sketch on \(p)")) { model.startSketch(p) }
                }
            }
            if !construction.isEmpty {
                folder("Construction", String(localized: "Construction"), "square.on.square.dashed",
                       eye: eye(construction.contains { !data.hiddenOrigin.contains($0.name) }) { v in run(["folder": "construction"], v) }) {
                    ForEach(construction) { c in
                        eyeRow(c.name, Self.constructionSymbol(c.type), visible: !data.hiddenOrigin.contains(c.name)) { v in run(["items": [c.name]], v) }
                            .tag(BrowserItem.construction(c.name))
                            .id(BrowserItem.construction(c.name))
                            .typeSelectEquivalent(Text(c.name))
                    }
                }
            }
            if !model.assembly.isEmpty {
                folder("Components", String(localized: "Components"), "square.stack.3d.up") {
                    ForEach(model.assembly) { c in componentRow(c).tag(BrowserItem.component(c.id)) }
                }
            }
            folder("Bodies", String(localized: "Bodies"), "cube.fill",
                   eye: eye(model.listedBodies.contains { !isHidden($0.name) }) { v in
                       run(["folder": "bodies"], v)
                       if v { hidden.removeAll() } else { hidden.formUnion(model.listedBodies.map(\.name)) }
                   }) {
                ForEach(model.listedBodies) { b in
                    bodyRow(b)
                        .tag(BrowserItem.body(b.name))
                        .id(BrowserItem.body(b.name))
                        .typeSelectEquivalent(Text(b.name))
                        .help("Return to rename")
                }
            }
            folder("Sketches", String(localized: "Sketches"), "pencil.and.outline",
                   eye: eye(model.snapshot.sketches.contains { $0.visible ?? true }) { v in run(["folder": "sketches"], v) }) {
                ForEach(model.snapshot.sketches) { s in
                    // M-11: a lock on a fully defined sketch, the pencil while it is under defined.
                    let state = SketchDefinedStates.state(model, sketch: s.id, in: data.sketchStates)
                    eyeRow(s.name, SketchDefinedStates.rowSymbol(state), visible: s.visible ?? true) { v in run(["items": [s.id]], v) }
                        .accessibilityValue(Text([(s.visible ?? true) ? nil : String(localized: "Hidden"), state.map(SketchStatusText.text)]
                            .compactMap { $0 }.joined(separator: ", ")))
                        .tag(BrowserItem.sketch(s.id))
                        .id(BrowserItem.sketch(s.id))
                        .typeSelectEquivalent(Text(s.name))
                        .help("Return or double-click to edit the sketch")
                        .accessibilityAction(named: Text("Edit Sketch")) { editSketch(s.id) }
                }
            }
            if !model.snapshot.params.isEmpty && !fusion {
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
        .environment(\.defaultMinListRowHeight, fusion ? FusionTokens.browserRow : VFSize.macRow)
        .font(fusion ? FusionTokens.row : VFFont.row)
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

    /// The timeline's Find in Browser: open the row's folder, select it and scroll to it.
    private func reveal(_ r: BrowserReveal.Request?, _ proxy: ScrollViewProxy) {
        guard let r, r.model == ObjectIdentifier(model) else { return }
        open.insert(r.folder)
        if !r.bodies.isEmpty {
            others = []
            model.selection = []
            model.selectedBodies = r.bodies
            if let first = model.snapshot.bodies.first(where: { r.bodies.contains($0.name) }) {
                DispatchQueue.main.async { proxy.scrollTo(BrowserItem.body(first.name), anchor: .center) }
            }
        } else if let item = r.item {
            model.selectedBodies = []
            others = [item]
            DispatchQueue.main.async { proxy.scrollTo(item, anchor: .center) }
        }
    }

    // MARK: Actions

    @ViewBuilder private func menu(_ items: Set<BrowserItem>) -> some View {
        let names = bodies(in: items)
        if items.count == 1, let item = items.first {
            switch item {
            case .units:
                Menu("Units") {
                    ForEach(Self.units, id: \.self) { u in
                        Button(u) { model.run("document.units", ["units": u]) }.disabled(u == model.snapshot.units)
                    }
                }
            case let .namedView(name):
                Button("Restore View") { applyView(name) }
                Button("Update to Current View") { model.run("view.save", ["name": name, "camera": model.camera.dictionary], quiet: true) }
                Button("Rename") { renamingView = name; draft = name; renameError = nil; DispatchQueue.main.async { renameFocused = true } }
                Divider()
                Button("Delete", role: .destructive) { model.run("view.delete", ["view": name]) }
            case let .plane(p):
                Button("Sketch on \(p)") { model.startSketch(p) }
                let shown = !data.hiddenOrigin.contains(p)
                Button(shown ? "Hide" : "Show") { run(["items": [p]], !shown) }
            case let .construction(name):
                let shown = !data.hiddenOrigin.contains(name)
                Button(shown ? "Hide" : "Show") { run(["items": [name]], !shown) }
            case let .sketch(id):
                Button("Edit Sketch") { editSketch(id) }
                let shown = model.snapshot.sketches.first { $0.id == id }?.visible ?? true
                Button(shown ? "Hide" : "Show") { run(["items": [id]], !shown) }
            case let .component(id):
                Button("Select Bodies") { selectComponent(id) }
                let off = componentHidden(id)
                Button(off ? "Show" : "Hide") { setComponentVisible(id, off) }
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
        case let .namedView(name): applyView(name)
        default: break
        }
    }

    /// `browser.visibility` with these params and `visible` (one undo step).
    private func run(_ params: [String: Any], _ visible: Bool) {
        var p = params
        p["visible"] = visible
        model.run("browser.visibility", p, quiet: true)
    }

    // MARK: Named views

    private func saveView() {
        model.run("view.save", ["camera": model.camera.dictionary], quiet: true)
        open.insert("Views")
    }

    private func applyView(_ name: String) {
        CameraReply.run(model, "view.apply", ["view": name])
    }

    private func commitViewRename() {
        guard let old = renamingView else { return }
        let name = draft.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name == old { endViewRename(); return }
        if model.run("view.rename", ["view": old, "name": name], quiet: true) == nil {
            renameError = model.message
            model.flash(nil)
            renameFocused = true
            return
        }
        endViewRename()
    }

    private func endViewRename() {
        renamingView = nil
        renameError = nil
        draft = ""
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

    /// A component is hidden when its placement was hidden here, or when all its bodies are.
    private func componentHidden(_ id: Int) -> Bool {
        if hiddenComponents.contains(id) { return true }
        guard let c = model.assembly.first(where: { $0.id == id }), !c.bodies.isEmpty else { return false }
        return c.bodies.allSatisfy(isHidden)
    }

    /// Hides or shows a component's placement and everything under it (`browser.visibility`
    /// paths).
    private func setComponentVisible(_ id: Int, _ visible: Bool) {
        guard let occ = data.placement[id] else {
            // No placement id: hide or show its bodies one by one.
            if let c = model.assembly.first(where: { $0.id == id }) { setVisible(Set(c.bodies), visible) }
            return
        }
        if visible { hiddenComponents.remove(id) } else { hiddenComponents.insert(id) }
        run(["paths": [[occ]]], visible)
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

    /// A folder's eye: shown while anything in it is visible; a click hides or shows it all.
    private struct FolderEye {
        var visible: Bool
        var set: (Bool) -> Void
    }

    private func eye(_ visible: Bool, _ set: @escaping (Bool) -> Void) -> FolderEye {
        FolderEye(visible: visible, set: set)
    }

    @ViewBuilder
    private func folder<Content: View>(_ key: String, _ name: String, _ symbol: String, eye: FolderEye? = nil,
                                       add: (String, () -> Void)? = nil,
                                       @ViewBuilder content: () -> Content) -> some View {
        let body = content()
        DisclosureGroup(isExpanded: Binding(get: { open.contains(key) },
                                            set: { if $0 { open.insert(key) } else { open.remove(key) } })) {
            body
        } label: {
            if fusion {
                fusionRow(name, folderIcon: key != "Settings", symbol: symbol, eye: eye.map { ($0.visible, $0.set) })
            } else {
            HStack(spacing: VFSpace.s) {
                Label { Text(name).opacity(eye?.visible == false ? 0.55 : 1) } icon: { Image(systemName: symbol).foregroundStyle(theme.inkSecondary) }
                Spacer(minLength: 0)
                if let add {
                    VFIconButton("plus", label: add.0, size: 10) { add.1() }
                }
                if let eye {
                    VFIconButton(eye.visible ? "eye" : "eye.slash",
                                 label: eye.visible ? String(localized: "Hide everything in \(name)") : String(localized: "Show everything in \(name)"),
                                 size: 10) { eye.set(!eye.visible) }
                }
            }
            }
        }
    }

    /// The document row of Fusion's browser: eye, document icon, the name on a grey tag, and the
    /// radio dot that marks the active component.
    private var fusionRoot: some View {
        let f = theme.fusion
        return HStack(spacing: VFSpace.s) {
            Image(systemName: "eye").font(VFFont.glyph(10)).foregroundStyle(f.inkSoft).accessibilityHidden(true)
            Image(systemName: "doc").font(VFFont.glyph(11)).foregroundStyle(f.inkSoft).accessibilityHidden(true)
            Text(title.isEmpty ? model.snapshot.name : title)
                .font(FusionTokens.row.weight(.semibold)).foregroundStyle(f.onBlue)
                .padding(.horizontal, VFSpace.s).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 2).fill(f.inkFaint))
                .lineLimit(1)
            Image(systemName: "smallcircle.filled.circle").font(VFFont.glyph(10)).foregroundStyle(f.ink)
                .help("Active").accessibilityLabel("Active")
            Spacer(minLength: 0)
        }
    }

    /// A Fusion browser row: the eye first (when the row has one), the folder or type icon, the name
    /// on the browser's light wash.
    private func fusionRow(_ name: String, folderIcon: Bool, symbol: String, eye: (Bool, (Bool) -> Void)?) -> some View {
        let f = theme.fusion
        let visible = eye?.0 ?? true
        return HStack(spacing: VFSpace.s) {
            if let eye {
                Button { eye.1(!eye.0) } label: {
                    Image(systemName: eye.0 ? "eye" : "eye.slash").font(VFFont.glyph(10))
                        .foregroundStyle(eye.0 ? f.inkSoft : f.inkFaint).frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(eye.0 ? String(localized: "Hide \(name)") : String(localized: "Show \(name)"))
                .accessibilityLabel(eye.0 ? String(localized: "Hide \(name)") : String(localized: "Show \(name)"))
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Image(systemName: folderIcon ? "folder.fill" : symbol).font(VFFont.glyph(11))
                .foregroundStyle(f.inkFaint).accessibilityHidden(true)
            Text(name).foregroundStyle(f.ink).lineLimit(1).opacity(visible ? 1 : 0.55)
                .padding(.horizontal, VFSpace.xs)
                .background(RoundedRectangle(cornerRadius: 2).fill(f.rowWash))
            Spacer(minLength: 0)
        }
    }

    /// A row with an eye (origin plane, construction item, sketch).
    @ViewBuilder
    private func eyeRow(_ name: String, _ symbol: String, visible: Bool, set: @escaping (Bool) -> Void) -> some View {
        if fusion {
            fusionRow(name, folderIcon: false, symbol: symbol, eye: (visible, set))
                .accessibilityValue(visible ? Text("") : Text("Hidden"))
        } else {
        HStack(spacing: VFSpace.s) {
            Label { Text(name).lineLimit(1).opacity(visible ? 1 : 0.55) } icon: { Image(systemName: symbol).foregroundStyle(theme.inkSecondary) }
            Spacer(minLength: 0)
            VFIconButton(visible ? "eye" : "eye.slash",
                         label: visible ? String(localized: "Hide \(name)") : String(localized: "Show \(name)"),
                         size: 10) { set(!visible) }
        }
        .accessibilityValue(visible ? Text("") : Text("Hidden"))
        }
    }

    private static func constructionSymbol(_ type: String) -> String {
        switch type {
        case "ConstructionAxis": "line.diagonal"
        case "ConstructionPoint": "smallcircle.filled.circle"
        default: "square.dashed"
        }
    }

    private func namedViewRow(_ v: DesignOutlineData.NamedView) -> some View {
        HStack(spacing: VFSpace.s) {
            Label {
                if renamingView == v.name {
                    VStack(alignment: .leading, spacing: VFSpace.xxs) {
                        TextField("View name", text: $draft)
                            .focused($renameFocused)
                            .vfField()
                            .onSubmit { commitViewRename() }
                            .onExitCommand { endViewRename() }
                            .onChange(of: draft) { _, _ in renameError = nil }
                            .accessibilityLabel(Text("New name for \(v.name)"))
                        if let renameError { InlineError(renameError) }
                    }
                } else {
                    Text(v.name).lineLimit(1)
                }
            } icon: {
                Image(systemName: "camera.viewfinder").foregroundStyle(theme.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityAction(named: Text("Restore View")) { applyView(v.name) }
    }

    private func componentRow(_ c: DesignModel.AssemblyPart) -> some View {
        let off = componentHidden(c.id)
        return HStack(spacing: VFSpace.s) {
            Label {
                Text(occurrenceName(c)).lineLimit(1).opacity(off ? 0.55 : 1)
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
            VFIconButton(off ? "eye.slash" : "eye",
                         label: off ? String(localized: "Show \(occurrenceName(c))") : String(localized: "Hide \(occurrenceName(c))"),
                         size: 10) {
                setComponentVisible(c.id, off)
            }
        }
        .typeSelectEquivalent(Text(occurrenceName(c)))
        .accessibilityElement(children: .combine)
        .accessibilityValue(off ? Text("Hidden") : Text(""))
    }

    @ViewBuilder
    private func bodyRow(_ b: DesignSnapshot.Body) -> some View {
        let off = isHidden(b.name)
        if fusion && renaming != b.name {
            fusionRow(b.name, folderIcon: false, symbol: "cube", eye: (!off, { v in setVisible([b.name], v) }))
                .accessibilityValue(off ? Text("Hidden") : Text(""))
                .accessibilityAction(named: Text("Rename")) { startRename(b.name) }
        } else {
        HStack(spacing: VFSpace.s) {
            Label {
                if renaming == b.name {
                    VStack(alignment: .leading, spacing: VFSpace.xxs) {
                        TextField("Body name", text: $draft)
                            .focused($renameFocused)
                            .vfField()
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
