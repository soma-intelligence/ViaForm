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
/// Command-8 come from the Workspace menu (`DeskWorkspaceCommands`), so they work in every fold
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
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                chips(.labels)
                chips(.shortLabels)
                chips(.activeLabel)
                chips(.icons)
                menu
            }
            .layoutPriority(1)
            if showsJobs {
                Spacer(minLength: 8)
                JobsButton(flow: flow)
            }
        }
        .padding(.horizontal, showsJobs ? 8 : 0)
    }

    /// Full labels, short labels (Design, Gen, Asm...), the active chip labelled, icons only.
    private enum Fold { case labels, shortLabels, activeLabel, icons }

    private func chips(_ fold: Fold) -> some View {
        // Chevrons read as flow only between labels; between icons they are noise.
        HStack(spacing: fold == .labels ? 1 : 6) {
            ForEach(Workspace.allCases) { w in
                chip(w, label: label(w, fold))
                if fold == .labels, w != Workspace.allCases.last {
                    Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(theme.inkTertiary)
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
                    Label("\(w.title)  ·  \(Self.describe(flow.stage(w)?.status ?? .empty))", systemImage: w.symbol)
                }
                .keyboardShortcut(w.shortcut, modifiers: .command)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: workspace.symbol)
                Text(workspace.title).font(.system(size: 12, weight: .semibold))
                StatusMark(status: flow.stage(workspace)?.status ?? .empty, stale: staleCount)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Workspaces (Command-1 to Command-8)")
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
                HStack(spacing: 5) {
                    Image(systemName: w.symbol).font(.system(size: 11, weight: .medium)).frame(width: 14)
                    if let label { Text(label).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1) }
                }
                .padding(.leading, label != nil ? 8 : 6)
                .padding(.trailing, 4)
                .frame(height: VFSize.chip)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help(w, stage))
            .accessibilityLabel("\(w.title), \(Self.describe(status))")
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityHint("Command \(w.index + 1)")
            Button { if fixable { offer = w } else if on { card = w } else { workspace = w } } label: {
                dot(status, stage: stage, on: on)
                    .frame(width: 14, height: VFSize.chip)
                    .padding(.trailing, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fixable ? "Why it is \(Self.describe(status)), and update it" : Self.describe(status))
            .accessibilityLabel(fixable ? "Update \(w.title), \(Self.describe(status))" : "\(w.title) status, \(Self.describe(status))")
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
            .padding(14).frame(width: 360)
        }
        .contextMenu {
            Button("Show Flow") { card = w }
            if fixable, let a = stage?.action { Button(a.label) { update(a.plan) } }
        }
    }

    @ViewBuilder private func dot(_ status: FlowModel.Status, stage: FlowModel.Stage?, on: Bool) -> some View {
        let progress = flow.queue.on(stage: stage?.id ?? "").flatMap { $0.determinate ? $0.progress : nil }
        if status == .running {
            if let p = progress, p > 0 {
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
            } else {
                ProgressView().controlSize(.mini)
            }
        } else if status == .stale, let s = stage, s.stale > 1 {
            Text("\(s.stale)")
                .font(.system(size: 9, weight: .bold)).monospacedDigit()
                .foregroundStyle(.black)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(theme.status(.stale)))
        } else if status == .empty {
            // Hollow ring: not built. Told from stale (filled ocre) by shape, not only by colour.
            Circle().strokeBorder(theme.inkTertiary, lineWidth: 1.25).frame(width: 7, height: 7)
        } else {
            Circle().fill(theme.color(status)).frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(theme.chrome, lineWidth: 1))
                .frame(width: 8, height: 8)
        }
    }

    private func help(_ w: Workspace, _ stage: FlowModel.Stage?) -> String {
        var s = "\(w.title): \(Self.describe(stage?.status ?? .empty))"
        if let r = stage?.reason, !r.isEmpty { s += ". \(r)" }
        s += " (Command-\(w.index + 1))"
        if workspace == w { s += ". Click again for its flow." }
        return s
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
                Image(systemName: workspace.symbol)
                Text("\(workspace.title) is \(stage?.status == .failed ? "failed" : "stale")").font(VFFont.title)
            }
            if let r = stage?.reason, !r.isEmpty {
                Text(r).font(VFFont.row).foregroundStyle(theme.ink)
            }
            ForEach(nodes) { n in
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.name + (n.revisionName.map { " · \($0)" } ?? "")).font(VFFont.rowEmphasis)
                    if !n.reason.isEmpty { Text(n.reason).font(VFFont.small).foregroundStyle(theme.inkSecondary) }
                    if let e = n.error { Text(e).font(VFFont.small).foregroundStyle(theme.danger) }
                }
            }
            if let a = stage?.action {
                Text("Rebuilds in order: " + a.plan.map(name).joined(separator: ", "))
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show Flow", action: showFlow).buttonStyle(.borderless)
                    Spacer()
                    Button(a.label.isEmpty ? "Update" : a.label) { update(a.plan) }
                        .buttonStyle(.vfPrimary)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Show Flow", action: showFlow)
            }
        }
        .padding(14)
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
            JobList(flow: flow).padding(12).frame(width: 340)
                .background(theme.panel)
        }
        .help("Long jobs: generation, simulation, training")
        .accessibilityLabel(flow.jobs.isEmpty ? "Jobs, none running" : "Jobs, \(flow.jobs.count) running")
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
                    .font(.system(size: 9, weight: .bold)).monospacedDigit()
                    .foregroundStyle(theme.onAccent)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(Circle().fill(theme.accent))
                    .offset(x: 6, y: -5)
            }
        }
        .help(flow.queue.headline ?? "Jobs")
    }

    private var full: some View {
            HStack(spacing: 5) {
                if flow.jobs.isEmpty {
                    Image(systemName: "clock.arrow.circlepath")
                } else if let j = flow.jobs.first, j.determinate {
                    ProgressView(value: j.progress).progressViewStyle(.circular).controlSize(.mini)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(flow.jobs.isEmpty ? "Jobs" : (flow.queue.headline ?? "Jobs")).lineLimit(1)
                if flow.jobs.count > 1 {
                    Text("\(flow.jobs.count)")
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(theme.onAccent)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Circle().fill(theme.accent))
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: compact ? 150 : 260)
    }
}

/// The small status sign after a stage or an artifact name.
struct StatusMark: View {
    let status: FlowModel.Status
    var stale = 0
    var progress: Double?

    var body: some View {
        switch status {
        case .current:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(.green)
        case .empty:
            Image(systemName: "circle.dotted").font(.system(size: 9)).foregroundStyle(.tertiary)
        case .stale:
            Text(stale > 1 ? "\(stale)" : "!")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                .frame(minWidth: 13, minHeight: 13)
                .background(Capsule().fill(.orange))
        case .running:
            if let p = progress, p > 0 {
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini)
            } else {
                ProgressView().controlSize(.mini)
            }
        case .failed:
            Image(systemName: "xmark.octagon.fill").font(.system(size: 9)).foregroundStyle(.red)
        }
    }
}

/// What one stage builds, what it is built from, what it feeds, why it is stale and the one
/// action that fixes it ("Re-run on Frame v12"), with the artifact's revisions.
struct FlowCard: View {
    let flow: FlowModel
    let stage: String
    /// Opens another stage's workspace.
    var open: (String) -> Void = { _ in }
    /// Rebuilds the plan; without it the action only opens the first stage of the plan.
    var update: (([String]) -> Void)?
    @State private var showRevisions: String?

    private func name(_ id: String) -> String { flow.node(id)?.name ?? id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = flow.stage(stage) {
                HStack {
                    Text(s.name).font(.headline)
                    Spacer()
                    StatusMark(status: s.status, stale: s.stale)
                    Text(PipelineBar.describe(s.status)).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(flow.nodes(in: stage)) { n in node(n) }
        }
    }

    private func node(_ n: FlowModel.Node) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusMark(status: n.status, progress: n.job.flatMap { $0.determinate ? $0.progress : nil })
                Text(n.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(n.revisionName ?? "not built") { showRevisions = showRevisions == n.id ? nil : n.id }
                    .buttonStyle(.borderless)
                    .font(.caption.monospacedDigit())
                    .disabled(n.revisions == 0)
                    .help("Revisions")
            }
            if let job = n.job { Text(job.caption).font(.caption).foregroundStyle(.secondary) }
            if let e = n.error { Text(e).font(.caption).foregroundStyle(.red) }
            if let note = n.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if !n.summary.isEmpty { Text(n.summary).font(.caption).foregroundStyle(.secondary) }
            if showRevisions == n.id { RevisionList(flow: flow, artifact: n.id) }
            if !n.consumes.isEmpty {
                section("Built from") {
                    ForEach(n.consumes, id: \.id) { i in
                        row(name(i.id), detail: i.current ? (i.now_name ?? "rev \(i.now)") : "built on \(i.seen_name ?? "rev \(i.seen)"), now \(i.now_name ?? "rev \(i.now)")",
                            warn: !i.current, target: flow.node(i.id)?.stage)
                    }
                }
            }
            if !n.feeds.isEmpty {
                section("Feeds") {
                    ForEach(n.feeds, id: \.self) { f in
                        row(name(f), detail: PipelineBar.describe(flow.node(f)?.status ?? .empty), warn: flow.node(f)?.status == .stale, target: flow.node(f)?.stage)
                    }
                }
            }
            if let a = n.action, n.status == .stale || n.status == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    if !n.reason.isEmpty { Text(n.reason).font(.caption.weight(.semibold)) }
                    Text("Rebuild in order: " + a.plan.map(name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    Button(a.label) {
                        if let update { update(a.plan) } else if let first = a.plan.first, let s = flow.node(first)?.stage { open(s) }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ title: String, detail: String, warn: Bool, target: String?) -> some View {
        Button { if let target { open(target) } } label: {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(warn ? Color.orange : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An artifact's revisions, newest first: which is in use, where each came from, and a way back
/// to an older one.
struct RevisionList: View {
    let flow: FlowModel
    let artifact: String

    var body: some View {
        let list = flow.revisions(artifact).reversed()
        VStack(alignment: .leading, spacing: 3) {
            if let d = flow.diff(artifact), d.from != d.to {
                Text("\(d.from) to \(d.to): " + (d.summary.changed ? d.summary.to : "same summary")).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(list.prefix(8))) { r in
                HStack(spacing: 6) {
                    Image(systemName: r.active ? "largecircle.fill.circle" : "circle").font(.system(size: 9))
                    Text(r.name).font(.caption.monospacedDigit().weight(r.active ? .semibold : .regular))
                    Text(r.from ?? r.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !r.active { Button("Use") { flow.activate(artifact, revision: r.number) }.controlSize(.mini) }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
    }
}

/// The running jobs: what each does, how far along, the time left, pause, resume and cancel.
struct JobList: View {
    let flow: FlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jobs").font(.headline)
            if flow.jobs.isEmpty {
                Text("Nothing running. Generation, simulation and training runs show here.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(flow.jobs) { j in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(flow.node(j.artifact)?.name ?? j.artifact).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(flow.stage(j.stage)?.name ?? j.stage).font(.caption).foregroundStyle(.secondary)
                    }
                    if j.determinate { ProgressView(value: j.progress) } else { ProgressView().progressViewStyle(.linear) }
                    HStack {
                        Text(j.caption).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if j.pausable {
                            Button { j.paused ? flow.resume(job: j.id) : flow.pause(job: j.id) } label: {
                                Image(systemName: j.paused ? "play.fill" : "pause.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(j.paused ? "Resume" : "Pause")
                            .accessibilityLabel(j.paused ? "Resume \(j.label)" : "Pause \(j.label)")
                        }
                        Button { flow.cancel(job: j.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Cancel")
                            .accessibilityLabel("Cancel \(j.label)")
                    }
                }
            }
        }
    }
}

/// A workspace that has no editor of its own yet: its place in the flow, and what it can do today.
struct StageOverview<Actions: View>: View {
    let flow: FlowModel
    let stage: String
    let note: String
    var open: (String) -> Void
    var update: (([String]) -> Void)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(note).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) { actions }
                FlowCard(flow: flow, stage: stage, open: open, update: update)
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .vfSurface(.panel)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
