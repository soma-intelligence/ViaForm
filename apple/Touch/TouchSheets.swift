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
    @State private var confirm: ConfirmRequest?
    /// The body being renamed (from its row's menu), the draft name and why a try was refused.
    @State private var renaming: String?
    @State private var draft = ""
    @State private var renameError: String?

    /// Sample entries are for screenshots and tests: debug builds, or `--samples`.
    static var showsSamples: Bool {
        #if DEBUG
        true
        #else
        ProcessInfo.processInfo.arguments.contains("--samples")
        #endif
    }

    var body: some View {
        let _ = flow.version
        NavigationStack {
            List {
                Section(stage.title) {
                    let rows = flow.tree(stage.stage)
                    if rows.isEmpty {
                        Text("Nothing in this stage yet.").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    }
                    ForEach(rows) { r in
                        row(r).contextMenu {
                            if r.id.hasPrefix("body:") {
                                Button("Rename", systemImage: "pencil") { startRename(String(r.id.dropFirst(5))) }
                            }
                        }
                    }
                }
                Section("Pipeline outputs") {
                    ForEach(flow.outputs()) { o in output(o) }
                }
                Section("Stages") {
                    ForEach(Workspace.allCases) { w in
                        Button { dismiss(); open(w) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: w.symbol).frame(width: 24).accessibilityHidden(true)
                                Text(w.title)
                                Spacer()
                                Text(PipelineWords.describe(flow.stage(w)?.status ?? .empty)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                                VFStatusDot(status: (flow.stage(w)?.status ?? .empty).vfStatus, size: 8)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: VFSize.touchTarget)
                            .foregroundStyle(w == stage ? theme.accentText : theme.ink)
                        }
                        .accessibilityAddTraits(w == stage ? .isSelected : [])
                    }
                }
                Section("Design") {
                    Button("New Design", systemImage: "plus") { guarded(String(localized: "Discard and Start New")) { ProjectFiles.newDesign(model, in: ProjectFiles.context(for: model)) } }
                    Button("Open or Import…", systemImage: "folder") { dismiss(); importFile() }
                }
                if Self.showsSamples {
                    Section("Samples") {
                        Button("Sample Bracket", systemImage: "wand.and.stars") { guarded(String(localized: "Discard and Open Sample")) { model.loadSample() } }
                        Button("Sample Hand", systemImage: "hand.raised") { guarded(String(localized: "Discard and Open Sample")) { loadHand() } }
                    }
                }
                Section("Files") {
                    Button("Save Design…", systemImage: "square.and.arrow.down") { dismiss(); export(.design) }
                    Button("STEP…", systemImage: "cube") { dismiss(); export(.step) }
                    Button("STL…", systemImage: "printer") { dismiss(); export(.stl) }
                    Button("Bill of Materials", systemImage: "list.bullet.rectangle") { dismiss(); showBom() }
                    Button("Libraries", systemImage: "books.vertical") { dismiss(); showLibrary() }
                }
                Section("Appearance") { ThemeModePicker() }
                TouchAppIconSection()
                UnitSettingsStoredSection()
                PrivacySettingsSections()
                Section {
                    NavigationLink { AboutCreditsView() } label: {
                        Label("About ViaForm", systemImage: "info.circle")
                    }
                    .frame(minHeight: VFSize.touchTarget)
                }
            }
            .navigationTitle(ProjectTitle.of(flow: flow, design: model))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .confirmSheet($confirm)
        .alert("Rename Body", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Body name", text: $draft)
                .autocorrectionDisabled()
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text(renameError ?? String(localized: "Features that use the body follow the new name."))
        }
    }

    private func startRename(_ name: String) {
        draft = name
        renameError = nil
        renaming = name
    }

    /// Renames through the engine (one undoable step); a refused name opens the prompt again with
    /// the reason.
    private func commitRename() {
        guard let old = renaming else { return }
        renaming = nil
        if let why = model.renameBody(old, to: draft) {
            renameError = why
            DispatchQueue.main.async { renaming = old }
        }
    }

    /// Replacing the open design asks first when it has changes since the last save.
    private func guarded(_ verb: String, _ action: @escaping () -> Void) {
        let run = { action(); dismiss() }
        guard let c = ProjectFiles.context(for: model), ProjectFiles.isEdited(c) else { run(); return }
        let name = ProjectTitle.of(flow: flow, design: model)
        confirm = ConfirmRequest(title: String(localized: "Discard changes to \(name)?"),
                                 message: String(localized: "The changes since the last save are lost. Save the design first to keep them."),
                                 verb: verb, destructive: true, perform: run)
    }

    /// A tree row: indent, kind icon, name and detail, then eye and lock, 48 points tall.
    private func row(_ r: FlowModel.TreeRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(r.kind)).foregroundStyle(theme.inkSecondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).foregroundStyle(r.shown ? theme.ink : theme.inkTertiary)
                if let d = r.detail { Text(d).font(VFFont.small).foregroundStyle(theme.inkSecondary) }
            }
            Spacer()
            if let s = r.status {
                VFStatusDot(status: s.vfStatus, size: 7).accessibilityLabel(s.vfStatus.word)
            }
            VFIconButton(r.visible ? "eye" : "eye.slash",
                         label: r.visible ? String(localized: "Hide \(r.name)") : String(localized: "Show \(r.name)"),
                         size: 16, tint: r.visible ? theme.ink : theme.inkTertiary) { setVisible(r, !r.visible) }
            VFIconButton(r.locked ? "lock.fill" : "lock.open",
                         label: r.locked ? String(localized: "Unlock \(r.name)") : String(localized: "Lock \(r.name)"),
                         size: 16, tint: r.locked ? theme.ink : theme.inkTertiary) { flow.setLocked(r.id, !r.locked) }
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
            VFStatusDot(status: o.status.vfStatus, size: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(o.revision_name ?? o.label).font(VFFont.rowEmphasis)
                Text(o.reason.isEmpty ? PipelineWords.describe(o.status) : o.reason).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if o.status == .stale || o.status == .failed || o.status == .empty, let w = Workspace(stage: o.stage) {
                // It takes you to the stage that rebuilds it; the label says so.
                Button(String(localized: "Go to \(w.title)")) { dismiss(); open(w) }
                    .buttonStyle(.vfSecondary)
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
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                TextField("Search the nine stages", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($focused)
                    .submitLabel(.go)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { if let c = results.first { pick(c) } }
                if !query.isEmpty {
                    VFIconButton("xmark.circle.fill", label: String(localized: "Clear search"), size: 16, tint: theme.inkTertiary) { query = "" }
                }
            }
            .padding(.horizontal, VFSpace.xl)
            .frame(height: 52)
            VFHairline()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Workspace.allCases) { w in
                        let on = w == stage
                        Button { pick(FlowModel.Command(id: "stage.\(w.stage)", label: w.title, stage: w.stage, group: "WORKSPACE", icon: "stage", source: "app")) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: w.symbol).font(VFFont.glyph(15, weight: .medium))
                                if on { Text(w.title).font(VFFont.rowEmphasis) }
                            }
                            .padding(.horizontal, on ? VFSpace.l : 0)
                            .frame(minWidth: VFSize.touchTarget, minHeight: VFSize.touchTarget)
                            .foregroundStyle(on ? theme.accentText : theme.ink)
                            .background(Capsule().fill(on ? theme.accent.opacity(0.14) : theme.well))
                        }
                        .buttonStyle(.vfTouch)
                        .accessibilityLabel(String(localized: "Go to \(w.title)"))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            VFHairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(query.isEmpty ? String(localized: "\(stage.title) commands") : String(localized: "Results")).font(VFFont.small.weight(.semibold))
                        .foregroundStyle(theme.inkSecondary).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                    ForEach(results) { c in
                        let runnable = canRun(c.id)
                        Button { pick(c) } label: {
                            HStack(spacing: 12) {
                                ToolChipIcon(icon: c.icon, id: c.id, size: 16).frame(width: 30).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(StageLabels.command(c.label)).foregroundStyle(theme.ink).lineLimit(1)
                                    Text(Self.where_(c)).font(.caption).foregroundStyle(theme.inkSecondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let k = c.key, k.count == 1 {
                                    Text(k).font(VFFont.mono.weight(.semibold))
                                        .foregroundStyle(theme.inkSecondary)
                                        .frame(minWidth: 26, minHeight: 26)
                                        .background(theme.well, in: RoundedRectangle(cornerRadius: VFRadius.control))
                                        .accessibilityLabel(String(localized: "Shortcut \(k)"))
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: VFSize.touchTarget)
                            .contentShape(Rectangle())
                            .opacity(runnable ? 1 : 0.4)
                        }
                        .buttonStyle(.vfTouch)
                        .vfDisabled(!runnable, reason: String(localized: "Not available right now"))
                    }
                    if results.isEmpty {
                        Text("No command matches. Try another word.").font(VFFont.small).foregroundStyle(theme.inkSecondary).padding(VFSpace.xl)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxHeight: 440)
        }
        .frame(maxWidth: 560)
        .vfSurface(.floating, radius: VFRadius.touchFloating)
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
