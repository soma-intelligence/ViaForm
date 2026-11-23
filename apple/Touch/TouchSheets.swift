#if os(iOS)
import SwiftUI

// The sheets of the iPad window: the browser (the stage's tree with eye and lock, the pipeline
// outputs, the stages, files and settings) and the command palette over the eight stages.

struct TouchBrowserSheet: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let flow: FlowModel
    let model: DesignModel
    let stage: Workspace
    let open: (Workspace) -> Void
    let importFile: () -> Void
    let export: (ExportKind) -> Void
    let loadHand: () -> Void
    let showBom: () -> Void
    let showLibrary: () -> Void

    var body: some View {
        let _ = flow.version
        NavigationStack {
            List {
                Section(stage.title) {
                    let rows = flow.tree(stage.stage)
                    if rows.isEmpty {
                        Text("Nothing in this stage yet.").foregroundStyle(theme.inkSecondary)
                    }
                    ForEach(rows) { r in row(r) }
                }
                Section("Pipeline outputs") {
                    ForEach(flow.outputs()) { o in output(o) }
                }
                Section("Stages") {
                    ForEach(Workspace.allCases) { w in
                        Button { dismiss(); open(w) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: w.symbol).frame(width: 24)
                                Text(w.title)
                                Spacer()
                                Text(PipelineWords.describe(flow.stage(w)?.status ?? .empty)).font(.footnote).foregroundStyle(theme.inkSecondary)
                                VFStatusDot(status: (flow.stage(w)?.status ?? .empty).vfStatus, size: 8)
                            }
                            .frame(minHeight: VFSize.touchRow - 8)
                            .foregroundStyle(w == stage ? theme.accentText : theme.ink)
                        }
                    }
                }
                Section("Design") {
                    Button("New Design", systemImage: "plus") { ProjectFiles.newDesign(model, in: ProjectFiles.current); dismiss() }
                    Button("Open or Import…", systemImage: "folder") { dismiss(); importFile() }
                    Button("Sample Bracket", systemImage: "wand.and.stars") { model.loadSample(); dismiss() }
                    Button("Sample Hand", systemImage: "hand.raised") { dismiss(); loadHand() }
                }
                Section("Files") {
                    Button("Save Design…", systemImage: "square.and.arrow.down") { dismiss(); export(.design) }
                    Button("STEP…", systemImage: "cube") { dismiss(); export(.step) }
                    Button("STL…", systemImage: "printer") { dismiss(); export(.stl) }
                    Button("Bill of Materials", systemImage: "list.bullet.rectangle") { dismiss(); showBom() }
                    Button("Libraries", systemImage: "books.vertical") { dismiss(); showLibrary() }
                }
                Section("Appearance") { ThemeModePicker() }
            }
            .navigationTitle(ProjectTitle.of(flow: flow, design: model))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    /// A tree row: indent, kind icon, name and detail, then eye and lock, 48 points tall.
    private func row(_ r: FlowModel.TreeRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(r.kind)).foregroundStyle(theme.inkSecondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).foregroundStyle(r.shown ? theme.ink : theme.inkTertiary)
                if let d = r.detail { Text(d).font(.caption).foregroundStyle(theme.inkSecondary) }
            }
            Spacer()
            if let s = r.status { VFStatusDot(status: s.vfStatus, size: 7) }
            Button { setVisible(r, !r.visible) } label: {
                Image(systemName: r.visible ? "eye" : "eye.slash").frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
            }
            .buttonStyle(.plain).foregroundStyle(r.visible ? theme.ink : theme.inkTertiary)
            .accessibilityLabel(r.visible ? "Hide \(r.name)" : "Show \(r.name)")
            Button { flow.setLocked(r.id, !r.locked) } label: {
                Image(systemName: r.locked ? "lock.fill" : "lock.open").frame(width: VFSize.touchTarget, height: VFSize.touchTarget)
            }
            .buttonStyle(.plain).foregroundStyle(r.locked ? theme.ink : theme.inkTertiary)
            .accessibilityLabel(r.locked ? "Unlock \(r.name)" : "Lock \(r.name)")
        }
        .padding(.leading, CGFloat(r.depth) * 18)
        .frame(minHeight: VFSize.touchRow)
        .listRowBackground(r.selected ? theme.selection : nil)
    }

    private func setVisible(_ r: FlowModel.TreeRow, _ on: Bool) {
        flow.setVisible(r.id, on)
        // A design body hides in the 3D view too.
        if r.id.hasPrefix("body:") { model.toggleBodyVisibility(String(r.id.dropFirst(5)), visible: on) }
    }

    private func output(_ o: FlowModel.Output) -> some View {
        HStack(spacing: 10) {
            VFStatusDot(status: o.status.vfStatus, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.revision_name ?? o.label).font(.body.weight(.medium))
                Text(o.reason.isEmpty ? PipelineWords.describe(o.status) : o.reason).font(.caption).foregroundStyle(theme.inkSecondary).lineLimit(1)
            }
            Spacer()
            if o.status == .stale || o.status == .failed || o.status == .empty, let w = Workspace(stage: o.stage) {
                // It takes you to the stage that rebuilds it; the label says so.
                Button("Go to \(w.title)") { dismiss(); open(w) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: VFSize.touchTarget)
            }
        }
        .frame(minHeight: VFSize.touchRow)
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "artifact": "shippingbox"
        case "body": "cube.fill"
        case "sketch": "pencil.and.outline"
        case "component", "occurrence": "square.stack.3d.up"
        case "joint": "link"
        case "part", "footprint": "cpu"
        case "net": "point.3.connected.trianglepath.dotted"
        default: "circle"
        }
    }
}

/// Every command of the eight stages in a floating card near the top: a borderless search
/// field that takes the keyboard at once, the stages as icons (the current one labelled), and
/// 44 point rows with their single-key shortcut on the right. A single letter that is a
/// shortcut (E, F, M, J) comes first; Return runs the top result; Escape, a swipe down or a tap
/// outside closes it.
struct TouchCommandPalette: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: Workspace
    let run: (FlowModel.Command) -> Void
    /// Whether a verb can run now ("Stop Study" only while a study runs); greyed otherwise.
    var canRun: (String) -> Bool = { _ in true }
    let close: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [FlowModel.Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return flow.commands(stage: stage.stage).filter { $0.group != "WORKSPACE" } }
        return flow.search(q, stage: stage.stage, limit: 40)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSecondary)
                TextField("Search the eight stages", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .submitLabel(.go)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { if let c = results.first { pick(c) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(theme.inkTertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            VFHairline()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Workspace.allCases) { w in
                        let on = w == stage
                        Button { pick(FlowModel.Command(id: "stage.\(w.stage)", label: w.title, stage: w.stage, group: "WORKSPACE", icon: "stage", source: "app")) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: w.symbol).font(.system(size: 15, weight: .medium))
                                if on { Text(w.title).font(.system(size: 14, weight: .semibold)) }
                            }
                            .padding(.horizontal, on ? 12 : 0)
                            .frame(minWidth: VFSize.touchTarget, minHeight: 36)
                            .foregroundStyle(on ? theme.accentText : theme.ink)
                            .background(Capsule().fill(on ? theme.accent.opacity(0.14) : theme.well))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Go to \(w.title)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            VFHairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(query.isEmpty ? "\(stage.title) commands" : "Results").font(VFFont.small.weight(.semibold))
                        .foregroundStyle(theme.inkSecondary).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                    ForEach(results) { c in
                        let runnable = canRun(c.id)
                        Button { pick(c) } label: {
                            HStack(spacing: 12) {
                                ToolChipIcon(icon: c.icon, id: c.id, size: 16).frame(width: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(StageLabels.command(c.label)).foregroundStyle(theme.ink).lineLimit(1)
                                    Text(Self.where_(c)).font(.caption).foregroundStyle(theme.inkSecondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let k = c.key, k.count == 1 {
                                    Text(k).font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.inkSecondary)
                                        .frame(width: 26, height: 26)
                                        .background(theme.well, in: RoundedRectangle(cornerRadius: 6))
                                        .accessibilityLabel("Shortcut \(k)")
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: VFSize.touchTarget)
                            .contentShape(Rectangle())
                            .opacity(runnable ? 1 : 0.4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!runnable)
                    }
                    if results.isEmpty {
                        Text("No command matches.").font(VFFont.small).foregroundStyle(theme.inkSecondary).padding(16)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxHeight: 440)
        }
        .frame(maxWidth: 560)
        .vfSurface(.floating, radius: 20)
        .onAppear { focused = true }
        .onKeyPress(.escape) { close(); return .handled }
        .gesture(DragGesture(minimumDistance: 30).onEnded { g in if g.translation.height > 80 { close() } })
    }

    private func pick(_ c: FlowModel.Command) {
        guard canRun(c.id) else { return }
        close()
        run(c)
    }

    static func where_(_ c: FlowModel.Command) -> String {
        let s = Workspace(stage: c.stage)?.title ?? c.stage.capitalized
        return "\(s) · \(CatalogToolGroups.short(c.group))"
    }
}
#endif
