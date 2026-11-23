#if os(macOS)
import SwiftUI

/// Command-K: one search over the commands of all eight stages (the flow catalog: design
/// registry, board commands, stage verbs, "Go to stage"). The open stage's commands rank first,
/// a single letter that is a shortcut (E, F, M, J) goes straight to its command, the arrows
/// move, Return runs, Escape closes. It replaces the old toolbox search, so S still opens it.
///
/// It also reaches the window itself (`extras`: inspector, BOM, libraries, panels, views, the
/// keyboard sheet, the theme), and with an empty query the last commands run come first.
struct CommandPalette: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let workspace: Workspace
    let actions: StageActions
    /// Window commands (source "window"), run by `runExtra`.
    var extras: [FlowModel.Command] = []
    var runExtra: (String) -> Void = { _ in }
    var close: () -> Void
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool
    @AppStorage("viaform.palette.recent") private var recentIDs = ""

    private var recents: [FlowModel.Command] {
        let ids = recentIDs.split(separator: ",").map(String.init)
        guard !ids.isEmpty else { return [] }
        let pool = flow.commands() + extras
        return ids.compactMap { id in pool.first { $0.id == id } }
    }

    private var matches: [FlowModel.Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // The last commands run, the open stage's keyed commands, its verbs, then the stage jumps.
            let here = flow.commands(stage: workspace.stage)
            let keyed = here.filter { $0.key != nil && $0.group != "WORKSPACE" }
            let verbs = here.filter { $0.source == "app" && $0.key == nil }
            let jumps = flow.commands().filter { $0.group == "WORKSPACE" }
            var seen = Set<String>()
            return Array((recents + keyed + verbs + jumps).filter { seen.insert($0.id).inserted }.prefix(18))
        }
        let words = q.lowercased().split(separator: " ")
        let window = extras.filter { c in
            let hay = (c.label + " " + c.detail).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        let found = flow.search(q, stage: workspace.stage, limit: 16)
        // A window command whose name starts with the query goes first ("insp", "bom").
        let lead = window.filter { $0.label.lowercased().hasPrefix(q.lowercased()) }
        let rest = window.filter { !$0.label.lowercased().hasPrefix(q.lowercased()) }
        return Array((lead + found + rest).prefix(18))
    }

    var body: some View {
        let list = matches
        VStack(spacing: 0) {
            HStack(spacing: VFSpace.m) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSecondary)
                TextField("Search commands, stages and panels", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { if list.indices.contains(cursor) { run(list[cursor]) } }
                    .onExitCommand(perform: close)
                    .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
                Text("⌘K").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
            }
            .padding(.horizontal, VFSpace.l)
            .frame(height: 44)
            VFHairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                            row(c, on: i == cursor)
                                .id(c.id)
                                .onTapGesture { run(c) }
                                .onHover { if $0 { cursor = i } }
                        }
                        if list.isEmpty {
                            Text("No command matches \u{201C}\(query)\u{201D}")
                                .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                                .frame(maxWidth: .infinity).padding(VFSpace.l)
                        }
                    }
                    .padding(.vertical, VFSpace.xs)
                }
                .frame(maxHeight: 380)
                .onChange(of: cursor) { _, c in if list.indices.contains(c) { proxy.scrollTo(list[c].id) } }
            }
        }
        .frame(width: 560)
        .vfSurface(.floating)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in cursor = 0 }
    }

    private func row(_ c: FlowModel.Command, on: Bool) -> some View {
        let w = Workspace(stage: c.stage)
        let runnable = c.source == "window" || actions.canRun(c.id)
        let recent = query.isEmpty && recentIDs.split(separator: ",").contains(Substring(c.id))
        return HStack(spacing: VFSpace.m) {
            Group {
                if c.source == "window" {
                    Image(systemName: c.icon).font(.system(size: 13))
                } else if c.source == "design" {
                    ToolChipIcon(icon: c.icon, id: c.id, size: 15, style: .never)
                } else {
                    Image(systemName: StageLabels.symbol(forVerb: c.icon)).font(.system(size: 13))
                }
            }
            .frame(width: 22)
            Text(StageLabels.command(c.label)).font(VFFont.row).foregroundStyle(theme.ink)
            if recent {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10)).foregroundStyle(theme.inkTertiary)
                    .accessibilityLabel("Recent")
            }
            Spacer(minLength: VFSpace.m)
            if !c.group.isEmpty && c.group != "WORKSPACE" {
                Text(StageLabels.group(c.group).capitalized).font(VFFont.micro).foregroundStyle(theme.inkTertiary).lineLimit(1)
            }
            if let w {
                Text(w.title)
                    .font(VFFont.micro.weight(.semibold))
                    .foregroundStyle(theme.stageLabel(w.vfStage))
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(theme.stageFill(w.vfStage)))
            }
            if let k = c.key { KeyCap(DeskKeymap.glyph(k)) }
        }
        .opacity(runnable ? 1 : 0.45)
        .padding(.horizontal, VFSpace.l)
        .frame(height: 30)
        .background(on ? theme.selection : .clear)
        .contentShape(Rectangle())
    }

    private func run(_ c: FlowModel.Command) {
        if c.source == "window" {
            remember(c.id)
            close()
            runExtra(c.id)
            return
        }
        guard actions.canRun(c.id) else { return }
        remember(c.id)
        close()
        actions.run(c.id)
    }

    /// Keeps the last five commands run, newest first.
    private func remember(_ id: String) {
        var ids = recentIDs.split(separator: ",").map(String.init).filter { $0 != id }
        ids.insert(id, at: 0)
        recentIDs = ids.prefix(5).joined(separator: ",")
    }
}
#endif
