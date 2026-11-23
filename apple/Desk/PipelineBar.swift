#if os(macOS)
import SwiftUI

/// The product pipeline in the window's toolbar: the eight workspaces in build order, each with
/// its status from the Rust core (current, stale, running, failed, not built yet). Clicking a
/// stage opens its workspace; clicking the open one shows its flow card (what it consumes, what
/// it feeds, why it is stale and what to rebuild). A stale or failed stage's dot opens the update
/// popover: the reason and the one button that rebuilds it.
///
/// On a narrow window the bar folds: labelled chips, then icons with the active chip labelled,
/// then icons only, then a workspace menu whose rows carry their status. Command-1 to
/// Command-9 come from the Workspace menu (`DeskWorkspaceCommands`), so they work in every fold
/// and never collide with another menu item.
struct PipelineBar: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    @Binding var workspace: Workspace
    /// The stage whose flow card is open.
    @Binding var card: Workspace?
    /// The legacy layout keeps the jobs button on the bar; the new window has its own.
    var showsJobs = false
    /// Rebuilds a stale chain (the plan of the stage's action).
    var update: ([String]) -> Void = { _ in }
    @State private var showJobs = false
    @State private var offer: Workspace?
    @State private var hovered: Workspace?

    var body: some View {
        HStack(spacing: VFSpace.xs) {
            ViewThatFits(in: .horizontal) {
                chips(.labels)
                chips(.shortLabels)
                chips(.activeLabel)
                chips(.icons)
                menu
            }
            .layoutPriority(1)
            if showsJobs {
                Spacer(minLength: VFSpace.m)
                JobsButton(flow: flow)
            }
        }
        .padding(.horizontal, showsJobs ? VFSpace.m : 0)
    }

    /// Full labels, short labels (Design, Gen, Asm...), the active chip labelled, icons only.
    private enum Fold { case labels, shortLabels, activeLabel, icons }

    private func chips(_ fold: Fold) -> some View {
        // Chevrons read as flow only between labels; between icons they are noise.
        HStack(spacing: fold == .labels ? 1 : VFSpace.s) {
            ForEach(Workspace.allCases) { w in
                chip(w, label: label(w, fold))
                if fold == .labels, w != Workspace.allCases.last {
                    Image(systemName: "chevron.compact.right").font(VFFont.glyph(10)).foregroundStyle(theme.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .fixedSize()
    }

    private func label(_ w: Workspace, _ fold: Fold) -> String? {
        switch fold {
        case .labels: w.title
        case .shortLabels: w == workspace ? w.title : w.shortTitle
        case .activeLabel: w == workspace ? w.title : nil
        case .icons: nil
        }
    }

    /// The last fold: one menu, each row with its status.
    private var menu: some View {
        Menu {
            ForEach(Workspace.allCases) { w in
                Button { workspace = w } label: {
                    Label("\(w.title), \(Self.describe(flow.stage(w)?.status ?? .empty))", systemImage: w.symbol)
                }
                .keyboardShortcut(w.shortcut, modifiers: .command)
            }
        } label: {
            HStack(spacing: VFSpace.s) {
                Image(systemName: workspace.symbol)
                Text(workspace.title).font(VFFont.rowEmphasis)
                StatusMark(status: flow.stage(workspace)?.status ?? .empty, stale: staleCount, reason: flow.stage(workspace)?.reason)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Workspaces (Command-1 to Command-9)")
    }

    private var staleCount: Int { flow.stages.filter { $0.status == .stale || $0.status == .failed }.count }

    private func chip(_ w: Workspace, label: String?) -> some View {
        let stage = flow.stage(w)
        let on = workspace == w
        let status = stage?.status ?? .empty
        let fixable = status == .stale || status == .failed
        return HStack(spacing: 0) {
            Button {
                if on { card = w } else { workspace = w }
            } label: {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: w.symbol).font(VFFont.glyph(11, weight: .medium)).frame(width: 14)
                    if let label { Text(label).font(on ? VFFont.rowEmphasis : VFFont.row).lineLimit(1) }
                }
                .padding(.leading, label != nil ? VFSpace.m : VFSpace.s)
                .padding(.trailing, VFSpace.xs)
                .frame(height: VFSize.chip)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help(w, stage))
            .accessibilityLabel(String(localized: "\(w.title), \(Self.describe(status))"))
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityHint(String(localized: "Command \(w.index + 1)"))
            Button { if fixable { offer = w } else if on { card = w } else { workspace = w } } label: {
                dot(status, stage: stage)
                    .frame(minWidth: 14, minHeight: VFSize.chip)
                    .padding(.trailing, VFSpace.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fixable ? String(localized: "Why it is \(Self.describe(status)), and update it") : Self.describe(status))
            .accessibilityLabel(fixable ? String(localized: "Update \(w.title), \(Self.describe(status))") : String(localized: "\(w.title) status, \(Self.describe(status))"))
            .popover(isPresented: Binding(get: { offer == w }, set: { if !$0 { offer = nil } }), arrowEdge: .bottom) {
                UpdatePopover(flow: flow, workspace: w, update: { plan in offer = nil; update(plan) }, showFlow: { offer = nil; card = w })
            }
        }
        .foregroundStyle(theme.stageChipForeground(w.vfStage, active: on))
        .background(VFStageChipBackground(stage: w.vfStage, active: on, hovered: hovered == w))
        .onHover { hovered = $0 ? w : (hovered == w ? nil : hovered) }
        .popover(isPresented: Binding(get: { card == w }, set: { if !$0 { card = nil } }), arrowEdge: .bottom) {
            FlowCard(flow: flow, stage: w.stage, open: { target in
                card = nil
                if let t = Workspace(stage: target) { workspace = t }
            }, update: { plan in card = nil; update(plan) })
            .padding(VFSpace.panelPadding).frame(width: 360)
        }
        .contextMenu {
            Button("Show Flow") { card = w }
            if fixable, let a = stage?.action { Button(a.label) { update(a.plan) } }
        }
    }

    /// The stage's status mark, with the count of stale artifacts when more than one ("3").
    @ViewBuilder private func dot(_ status: FlowModel.Status, stage: FlowModel.Stage?) -> some View {
        HStack(spacing: VFSpace.xxs) {
            VFStatusDot(status: status.vfStatus, reason: stage.flatMap { $0.reason.isEmpty ? nil : $0.reason })
            if status == .stale, let s = stage, s.stale > 1 {
                Text("\(s.stale)").font(VFFont.micro).monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
    }

    private func help(_ w: Workspace, _ stage: FlowModel.Stage?) -> String {
        let state = Self.describe(stage?.status ?? .empty)
        var lines = [String(localized: "\(w.title): \(state) (Command-\(w.index + 1))")]
        if let r = stage?.reason, !r.isEmpty { lines.append(r) }
        if workspace == w { lines.append(String(localized: "Click again for its flow.")) }
        return lines.joined(separator: "\n")
    }

    static func describe(_ s: FlowModel.Status) -> String { PipelineWords.describe(s) }
}

/// Why a stage is stale or failed, what rebuilding it runs, and the button that does it.
struct UpdatePopover: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let workspace: Workspace
    var update: ([String]) -> Void
    var showFlow: () -> Void = {}

    private func name(_ id: String) -> String { flow.node(id)?.name ?? id }

    var body: some View {
        let stage = flow.stage(workspace)
        let nodes = flow.nodes(in: workspace.stage).filter { $0.status == .stale || $0.status == .failed }
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack(spacing: VFSpace.s) {
                Image(systemName: workspace.symbol).accessibilityHidden(true)
                (stage?.status == .failed ? Text("\(workspace.title) failed") : Text("\(workspace.title) is stale")).font(VFFont.title)
            }
            if let r = stage?.reason, !r.isEmpty {
                Text(r).font(VFFont.row).foregroundStyle(theme.ink)
            }
            ForEach(nodes) { n in
                VStack(alignment: .leading, spacing: VFSpace.xxs) {
                    Text(n.revisionName.map { "\(n.name) · \($0)" } ?? n.name).font(VFFont.rowEmphasis)
                    if !n.reason.isEmpty { Text(n.reason).font(VFFont.small).foregroundStyle(theme.inkSecondary) }
                    if let e = n.error { Text(e).font(VFFont.small).foregroundStyle(theme.danger) }
                }
            }
            if let a = stage?.action {
                Text("Rebuilds in order: \(a.plan.map(name).joined(separator: ", "))")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show Flow", action: showFlow).buttonStyle(.borderless)
                    Spacer()
                    Button(a.label.isEmpty ? String(localized: "Update") : a.label) { update(a.plan) }
                        .buttonStyle(.vfPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Show Flow", action: showFlow)
            }
        }
        .padding(VFSpace.panelPadding)
        .frame(width: 320, alignment: .leading)
    }
}

/// The jobs button: the headline of the running jobs and their queue in a popover, with pause,
/// resume and cancel.
struct JobsButton: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    var compact = false
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            if compact || flow.jobs.isEmpty {
                ring
            } else {
                full
            }
        }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            JobList(flow: flow).padding(VFSpace.l).frame(width: 340)
                .background(theme.panel)
        }
        .help("Long jobs: generation, simulation, training")
        .accessibilityLabel(flow.jobs.isEmpty ? String(localized: "Jobs, none running")
                            : WorkspaceMenu.inflected("Jobs, ^[\(flow.jobs.count) job](inflect: true) running"))
    }

    /// The jobs as an icon: a clock when idle, a progress ring with a count badge while running.
    private var ring: some View {
        ZStack(alignment: .topTrailing) {
            if let j = flow.jobs.first {
                ProgressView(value: j.determinate ? j.progress : 0.25).progressViewStyle(.circular).controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "clock.arrow.circlepath")
            }
            if flow.jobs.count > 0 {
                Text("\(flow.jobs.count)")
                    .font(VFFont.micro.weight(.bold)).monospacedDigit()
                    .foregroundStyle(theme.onAccent)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Circle().fill(theme.accent))
                    .offset(x: 6, y: -5)
            }
        }
        .help(flow.queue.headline ?? String(localized: "Jobs"))
    }

    private var full: some View {
            HStack(spacing: VFSpace.s) {
                if flow.jobs.isEmpty {
                    Image(systemName: "clock.arrow.circlepath")
                } else if let j = flow.jobs.first, j.determinate {
                    ProgressView(value: j.progress).progressViewStyle(.circular).controlSize(.mini)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(flow.jobs.isEmpty ? String(localized: "Jobs") : (flow.queue.headline ?? String(localized: "Jobs"))).lineLimit(1)
                if flow.jobs.count > 1 {
                    Text("\(flow.jobs.count)")
                        .font(VFFont.micro.weight(.bold)).monospacedDigit()
                        .foregroundStyle(theme.onAccent)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(theme.accent))
                }
            }
            .font(VFFont.small)
            .frame(maxWidth: compact ? 150 : 260)
    }
}

/// The small status sign after a stage or an artifact name: the shared `VFStatusDot` (shape per
/// state, the reason as tooltip and VoiceOver value), with the stale count when more than one.
struct StatusMark: View {
    @Environment(\.viaFormTheme) private var theme
    let status: FlowModel.Status
    var stale = 0
    var progress: Double?
    var reason: String?

    var body: some View {
        HStack(spacing: VFSpace.xxs) {
            VFStatusDot(status: status.vfStatus, reason: why)
            if status == .stale, stale > 1 {
                Text("\(stale) stale").font(VFFont.micro).foregroundStyle(theme.inkSecondary).monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
    }

    /// The reason, or the progress of a running job ("42 %").
    private var why: String? {
        if let reason, !reason.isEmpty { return reason }
        if status == .running, let p = progress, p > 0 { return VFFormat.value(p * 100, .percent) }
        return nil
    }
}

/// What one stage builds, what it is built from, what it feeds, why it is stale and the one
/// action that fixes it ("Re-run on Frame v12"), with the artifact's revisions.
struct FlowCard: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: String
    /// Opens another stage's workspace.
    var open: (String) -> Void = { _ in }
    /// Rebuilds the plan; without it the action only opens the first stage of the plan.
    var update: (([String]) -> Void)?
    @State private var showRevisions: String?

    private func name(_ id: String) -> String { flow.node(id)?.name ?? id }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            if let s = flow.stage(stage) {
                HStack {
                    Text(s.name).font(VFFont.title)
                    Spacer()
                    StatusMark(status: s.status, stale: s.stale, reason: s.reason)
                    Text(PipelineBar.describe(s.status)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
            ForEach(flow.nodes(in: stage)) { n in node(n) }
        }
    }

    private func node(_ n: FlowModel.Node) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack(spacing: VFSpace.s) {
                StatusMark(status: n.status, progress: n.job.flatMap { $0.determinate ? $0.progress : nil }, reason: n.reason)
                Text(n.name).font(VFFont.rowEmphasis)
                Spacer()
                Button(n.revisionName ?? String(localized: "Not built yet")) { showRevisions = showRevisions == n.id ? nil : n.id }
                    .buttonStyle(.borderless)
                    .font(VFFont.small)
                    .disabled(n.revisions == 0)
                    .help(n.revisions == 0 ? String(localized: "No revision yet") : String(localized: "Show the revisions"))
            }
            if let job = n.job { Text(job.caption).font(VFFont.small).foregroundStyle(theme.inkSecondary) }
            if let e = n.error { Label(e, systemImage: "xmark.octagon").font(VFFont.small).foregroundStyle(theme.danger) }
            if let note = n.note { Text(note).font(VFFont.small).foregroundStyle(theme.inkSecondary) }
            if !n.summary.isEmpty { Text(n.summary).font(VFFont.small).foregroundStyle(theme.inkSecondary) }
            if showRevisions == n.id { RevisionList(flow: flow, artifact: n.id) }
            if !n.consumes.isEmpty {
                section(String(localized: "Built from")) {
                    ForEach(n.consumes, id: \.id) { i in
                        let now = i.now_name ?? String(localized: "rev \(i.now)")
                        let seen = i.seen_name ?? String(localized: "rev \(i.seen)")
                        row(name(i.id), detail: i.current ? now : String(localized: "built on \(seen), now \(now)"),
                            warn: !i.current, target: flow.node(i.id)?.stage)
                    }
                }
            }
            if !n.feeds.isEmpty {
                section(String(localized: "Feeds")) {
                    ForEach(n.feeds, id: \.self) { f in
                        row(name(f), detail: PipelineBar.describe(flow.node(f)?.status ?? .empty), warn: flow.node(f)?.status == .stale, target: flow.node(f)?.stage)
                    }
                }
            }
            if let a = n.action, n.status == .stale || n.status == .failed {
                VStack(alignment: .leading, spacing: VFSpace.xs) {
                    if !n.reason.isEmpty { Text(n.reason).font(VFFont.small.weight(.semibold)) }
                    Text("Rebuild in order: \(a.plan.map(name).joined(separator: ", "))").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    Button(a.label) {
                        if let update { update(a.plan) } else if let first = a.plan.first, let s = flow.node(first)?.stage { open(s) }
                    }
                    .buttonStyle(.vfPrimary)
                }
                .padding(VFSpace.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(theme.warning.opacity(0.12)))
            }
        }
        .padding(VFSpace.panelPadding)
        .vfSurface(.well)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            VFCaption(title)
            content()
        }
    }

    private func row(_ title: String, detail: String, warn: Bool, target: String?) -> some View {
        Button { if let target { open(target) } } label: {
            HStack(spacing: VFSpace.s) {
                Text(title).font(VFFont.small).foregroundStyle(theme.ink)
                Spacer()
                if warn { VFTriangle().fill(theme.warning).frame(width: 8, height: 7).accessibilityHidden(true) }
                Text(detail).font(VFFont.small).foregroundStyle(warn ? theme.warning : theme.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An artifact's revisions, newest first: which is in use, where each came from, and a way back
/// to an older one. The eight newest show; Show All lists the rest.
struct RevisionList: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let artifact: String
    @State private var showAll = false
    private static let shortCount = 8

    var body: some View {
        let list = Array(flow.revisions(artifact).reversed())
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            if let d = flow.diff(artifact), d.from != d.to {
                Text(d.summary.changed ? "\(d.from) to \(d.to): \(d.summary.to)" : "\(d.from) to \(d.to): same summary")
                    .font(VFFont.micro).foregroundStyle(theme.inkSecondary)
            }
            ForEach(showAll ? list : Array(list.prefix(Self.shortCount))) { r in
                HStack(spacing: VFSpace.s) {
                    Image(systemName: r.active ? "largecircle.fill.circle" : "circle").font(VFFont.glyph(9))
                        .foregroundStyle(r.active ? theme.accentText : theme.inkTertiary)
                        .accessibilityHidden(true)
                    Text(r.name).font(r.active ? VFFont.small.weight(.semibold) : VFFont.small).foregroundStyle(theme.ink)
                    Text(r.from ?? r.summary).font(VFFont.micro).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    Spacer()
                    if r.active {
                        Text("In use").font(VFFont.micro).foregroundStyle(theme.accentText)
                    } else {
                        Button("Use") { flow.activate(artifact, revision: r.number) }
                            .controlSize(.mini)
                            .accessibilityLabel(String(localized: "Use \(r.name)"))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if list.count > Self.shortCount {
                Button(showAll ? String(localized: "Show Fewer") : String(localized: "Show All \(list.count)")) {
                    vfWithAnimation { showAll.toggle() }
                }
                .buttonStyle(.borderless)
                .font(VFFont.small)
            }
        }
        .padding(VFSpace.s)
        .vfSurface(.well, radius: VFRadius.chip)
    }
}

/// The running jobs: what each does, how far along, the time left, pause and resume when the job
/// can pause, and Stop.
struct JobList: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            Text("Jobs").font(VFFont.title)
            if flow.jobs.isEmpty {
                Text("Nothing running. Generation, simulation and training runs show here.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(flow.jobs) { j in
                VStack(alignment: .leading, spacing: VFSpace.xs) {
                    HStack {
                        Text(flow.node(j.artifact)?.name ?? j.artifact).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                        Spacer()
                        Text(flow.stage(j.stage)?.name ?? j.stage).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    }
                    if j.determinate { ProgressView(value: j.progress) } else { ProgressView().progressViewStyle(.linear) }
                    HStack(spacing: VFSpace.xs) {
                        Text(j.paused ? String(localized: "Paused. \(j.caption)") : j.caption)
                            .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                        Spacer()
                        if j.pausable {
                            VFIconButton(j.paused ? "play.fill" : "pause.fill",
                                         label: j.paused ? String(localized: "Resume \(j.label)") : String(localized: "Pause \(j.label)"),
                                         size: 11) {
                                j.paused ? flow.resume(job: j.id) : flow.pause(job: j.id)
                            }
                        }
                        VFIconButton("stop.fill", label: String(localized: "Stop \(j.label)"), size: 11) {
                            flow.cancel(job: j.id)
                        }
                    }
                }
            }
        }
    }
}

/// A workspace that has no editor of its own yet: its place in the flow, and what it can do today.
struct StageOverview<Actions: View>: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let stage: String
    let note: String
    var open: (String) -> Void
    var update: (([String]) -> Void)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VFSpace.xl) {
                Text(note).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                HStack(spacing: VFSpace.m) { actions }
                FlowCard(flow: flow, stage: stage, open: open, update: update)
            }
            .padding(VFSpace.xxl)
            .frame(maxWidth: 520, alignment: .leading)
            .vfSurface(.panel)
            .padding(VFSpace.xxl)
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
