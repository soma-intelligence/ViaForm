import SwiftUI

/// The project's dependency graph: every artifact as a card (stage icon, revision, status),
/// layered top to bottom by how far it sits from the sources, with a line from each input to
/// what it feeds. A stale input line is drawn in the stale colour. Tapping a card opens its
/// stage. Opened from the workspace dropdown footer and the toolbar's flow button.
struct FlowGraphView: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    var current: Workspace?
    var open: (Workspace) -> Void
    /// Rebuilds a stale chain; shown when anything is stale.
    var updateAll: (() -> Void)?

    private let cardSize = CGSize(width: 148, height: 46)
    private let gap = CGSize(width: 16, height: 30)

    /// Depth of each artifact: 0 for a source, else one more than its deepest input.
    private var layers: [[FlowModel.Node]] {
        var depth: [String: Int] = [:]
        let byID = Dictionary(flow.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func d(_ id: String, _ seen: Set<String> = []) -> Int {
            if let v = depth[id] { return v }
            guard let n = byID[id], !seen.contains(id) else { return 0 }
            let v = n.consumes.map { d($0.id, seen.union([id])) + 1 }.max() ?? 0
            depth[id] = v
            return v
        }
        var out: [[FlowModel.Node]] = []
        for n in flow.nodes {
            let k = d(n.id)
            while out.count <= k { out.append([]) }
            out[k].append(n)
        }
        return out
    }

    var body: some View {
        let layers = layers
        let columns = max(1, layers.map(\.count).max() ?? 1)
        let width = CGFloat(columns) * cardSize.width + CGFloat(columns - 1) * gap.width
        let height = CGFloat(layers.count) * cardSize.height + CGFloat(max(0, layers.count - 1)) * gap.height
        let frames = positions(layers, width: width)
        VStack(alignment: .leading, spacing: VFSpace.l) {
            HStack {
                Text("Flow graph").font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
                if let updateAll, WorkspaceMenu.anyStale(flow) {
                    Button("Update all stale", action: updateAll).buttonStyle(.vfPrimary)
                }
            }
            if flow.nodes.isEmpty {
                Text("Nothing built yet. Each stage adds its outputs here as it builds.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary)
            } else {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for n in flow.nodes {
                            guard let to = frames[n.id] else { continue }
                            for i in n.consumes {
                                guard let from = frames[i.id] else { continue }
                                var p = Path()
                                let a = CGPoint(x: from.midX, y: from.maxY)
                                let b = CGPoint(x: to.midX, y: to.minY)
                                p.move(to: a)
                                p.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + gap.height * 0.8), control2: CGPoint(x: b.x, y: b.y - gap.height * 0.8))
                                let color = i.current ? theme.inkTertiary.opacity(0.7) : theme.color(.stale)
                                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: i.current ? 1.2 : 1.8, dash: i.current ? [] : [4, 3]))
                            }
                        }
                    }
                    .frame(width: width, height: height)
                    .accessibilityHidden(true)
                    ForEach(flow.nodes) { n in
                        if let f = frames[n.id] { card(n).frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY) }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                legend
            }
        }
        .padding(VFSpace.xl)
    }

    private func positions(_ layers: [[FlowModel.Node]], width: CGFloat) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for (row, list) in layers.enumerated() {
            let w = CGFloat(list.count) * cardSize.width + CGFloat(max(0, list.count - 1)) * gap.width
            let x0 = (width - w) / 2
            for (i, n) in list.enumerated() {
                out[n.id] = CGRect(x: x0 + CGFloat(i) * (cardSize.width + gap.width),
                                   y: CGFloat(row) * (cardSize.height + gap.height),
                                   width: cardSize.width, height: cardSize.height)
            }
        }
        return out
    }

    private func card(_ n: FlowModel.Node) -> some View {
        let w = Workspace(stage: n.stage)
        let here = w == current
        let warn = n.status == .stale || n.status == .failed
        return Button { if let w { open(w) } } label: {
            HStack(spacing: VFSpace.s) {
                Image(systemName: w?.symbol ?? "circle").font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(theme.inkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.revisionName ?? n.label).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).lineLimit(1)
                    Text(w?.title ?? n.stage).font(.system(size: 10)).foregroundStyle(theme.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                WorkspaceStatusDot(status: n.status, size: 7)
            }
            .padding(.horizontal, VFSpace.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.panel))
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.control)
                    .strokeBorder(here ? theme.accent : (warn ? theme.color(n.status) : theme.hairline), lineWidth: here || warn ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(n.reason.isEmpty ? "\(n.name): \(PipelineWords.describe(n.status))" : n.reason)
        .accessibilityLabel("\(n.name), \(n.revisionName ?? "not built"), \(PipelineWords.describe(n.status))")
    }

    private var legend: some View {
        HStack(spacing: VFSpace.l) {
            ForEach([FlowModel.Status.current, .stale, .failed, .running, .empty], id: \.self) { s in
                HStack(spacing: VFSpace.xs) {
                    WorkspaceStatusDot(status: s, size: 7)
                    Text(s == .empty ? "not built" : (s == .stale ? "stale" : PipelineWords.describe(s)))
                        .font(.system(size: 10)).foregroundStyle(theme.inkSecondary)
                }
            }
        }
    }
}

/// The canvas banner of a stale or failed stage: what is out of date, and the one action that
/// fixes it ("Assembly v4 uses Frame v11", "Re-run on Frame v12"). Dismissed for the session.
struct StaleBanner: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let workspace: Workspace
    var update: ([String]) -> Void
    var dismiss: () -> Void

    /// The text and the action, or nil when the stage is fine.
    @MainActor
    static func content(_ flow: FlowModel, _ w: Workspace) -> (text: String, action: FlowModel.Action?, failed: Bool)? {
        let nodes = flow.nodes(in: w.stage).filter { $0.status == .stale || $0.status == .failed }
        guard let n = nodes.first else { return nil }
        if n.status == .failed {
            return ("\(n.name) failed" + (n.error.map { ": \($0)" } ?? ""), n.action, true)
        }
        let mine = n.revisionName ?? n.label
        if let old = n.consumes.first(where: { !$0.current }), let seen = old.seen_name {
            return ("\(mine) uses \(seen)", n.action, false)
        }
        return (n.reason.isEmpty ? "\(mine) is out of date" : n.reason, n.action, false)
    }

    var body: some View {
        if let c = Self.content(flow, workspace) {
            HStack(spacing: VFSpace.m) {
                Image(systemName: c.failed ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.color(c.failed ? .failed : .stale))
                Text(c.text).font(VFFont.row).foregroundStyle(theme.ink).lineLimit(1)
                if let a = c.action {
                    Button(a.label.isEmpty ? (c.failed ? "Retry" : "Update") : a.label) { update(a.plan) }
                        .buttonStyle(.vfPrimary)
                }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.inkSecondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide for this session")
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, VFSpace.l)
            .padding(.trailing, VFSpace.s)
            .padding(.vertical, VFSpace.s)
            .vfSurface(.floating, radius: VFRadius.floating)
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.floating)
                    .strokeBorder(theme.color(c.failed ? .failed : .stale).opacity(0.55), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
        }
    }
}
