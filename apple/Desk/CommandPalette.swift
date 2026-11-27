#if os(macOS)
import SwiftUI

/// Command-K: one search over the commands of all eight stages (the flow catalog: design
/// registry, board commands, stage verbs, "Go to stage"). The open stage's commands rank first,
/// a single letter that is a shortcut (E, F, M, J) goes straight to its command, the arrows
/// move, Return runs (or says why a command cannot run now), Escape closes. Rows are buttons;
/// the pointer and the arrows share one highlight. It replaces the old toolbox search, so S still opens it.
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
    /// The S bar's grid of the mode's likely tools (M-15), above the search field. Nil for Command-K.
    var header: AnyView? = nil
    var close: () -> Void
    @State private var query = ""
    @State private var cursor = 0
    /// Why the last command picked could not run.
    @State private var blocked: String?
    /// The pointer's last position, so a hover only counts when the pointer itself moved.
    @State private var lastPointer: CGPoint?
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
            if let header {
                header
                VFHairline()
            }
            HStack(spacing: VFSpace.m) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                TextField("Search commands, stages and panels", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if list.indices.contains(cursor) { run(list[cursor]) } }
                    .onExitCommand(perform: close)
                    .onKeyPress(.downArrow) { move(+1, count: list.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: list.count); return .handled }
                KeyCap(header == nil ? "\u{2318}K" : "S").accessibilityHidden(true)
            }
            .padding(.horizontal, VFSpace.l)
            .frame(height: 44)
            VFHairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty, !recents.isEmpty {
                            VFCaption("Recent").frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, VFSpace.l).padding(.top, VFSpace.s).padding(.bottom, VFSpace.xxs)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                            row(c, index: i, on: i == cursor)
                                .id(c.id)
                        }
                        if list.isEmpty {
                            VStack(spacing: VFSpace.xs) {
                                Text("No commands match \u{201C}\(query)\u{201D}")
                                    .font(VFFont.row).foregroundStyle(theme.ink)
                                Text("Try another word, or a stage name such as Generate.")
                                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                            }
                            .frame(maxWidth: .infinity).padding(VFSpace.xl)
                        }
                    }
                    .padding(.vertical, VFSpace.xs)
                }
                .frame(maxHeight: 380)
                .onChange(of: cursor) { _, c in if list.indices.contains(c) { proxy.scrollTo(list[c].id) } }
            }
            if let blocked {
                VFHairline()
                Label(blocked, systemImage: "info.circle")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.s)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(width: 560)
        .vfSurface(.floating)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in cursor = 0; blocked = nil }
    }

    /// Arrow keys move the one highlight; the pointer then has to move again to take it.
    private func move(_ step: Int, count: Int) {
        cursor = min(max(cursor + step, 0), max(count - 1, 0))
        blocked = nil
    }

    private func row(_ c: FlowModel.Command, index: Int, on: Bool) -> some View {
        let w = Workspace(stage: c.stage)
        let reason = c.source == "window" ? nil : actions.unavailableReason(c.id)
        let recent = query.isEmpty && recentIDs.split(separator: ",").contains(Substring(c.id))
        let title = StageLabels.command(c.label)
        return Button { run(c) } label: {
            HStack(spacing: VFSpace.m) {
                Group {
                    if c.source == "window" {
                        Image(systemName: c.icon).font(VFFont.glyph(13))
                    } else if c.source == "design" {
                        ToolChipIcon(icon: c.icon, id: c.id, size: 15, style: .never)
                    } else {
                        Image(systemName: StageLabels.symbol(forVerb: c.icon)).font(VFFont.glyph(13))
                    }
                }
                .foregroundStyle(reason == nil ? theme.ink : theme.inkTertiary)
                .frame(width: 22)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(VFFont.row).foregroundStyle(reason == nil ? theme.ink : theme.inkSecondary)
                    if let reason {
                        Text(reason).font(VFFont.micro).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    }
                }
                if recent {
                    Image(systemName: "clock.arrow.circlepath").font(VFFont.glyph(10)).foregroundStyle(theme.inkTertiary)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: VFSpace.m)
                if !c.group.isEmpty && c.group != "WORKSPACE" {
                    Text(StageLabels.group(c.group).capitalized).font(VFFont.micro).foregroundStyle(theme.inkTertiary).lineLimit(1)
                }
                if let w {
                    Text(w.title)
                        .font(VFFont.micro.weight(.semibold))
                        .foregroundStyle(theme.stageLabel(w.vfStage))
                        .padding(.horizontal, VFSpace.s).frame(height: 16)
                        .background(Capsule().fill(theme.stageFill(w.vfStage)))
                }
                if let k = c.key { KeyCap(DeskKeymap.glyph(k)) }
            }
            .padding(.horizontal, VFSpace.l)
            .padding(.vertical, VFSpace.xxs)
            .frame(minHeight: VFSize.macRow)
            .background(on ? theme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Only a real pointer move takes the highlight: rows sliding under a still pointer while
        // typing never move it.
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case let .active(p) = phase, p != lastPointer {
                lastPointer = p
                if cursor != index { cursor = index }
            }
        }
        .help(reason ?? (c.detail.isEmpty ? title : c.detail))
        .accessibilityLabel(recent ? String(localized: "\(title), recent") : title)
        .accessibilityHint(reason ?? "")
        .accessibilityValue(w?.title ?? "")
    }

    private func run(_ c: FlowModel.Command) {
        if c.source == "window" {
            remember(c.id)
            close()
            runExtra(c.id)
            return
        }
        if let reason = actions.unavailableReason(c.id) {
            // Say why instead of doing nothing.
            blocked = String(localized: "\(StageLabels.command(c.label)) is not available. \(reason)")
            return
        }
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
