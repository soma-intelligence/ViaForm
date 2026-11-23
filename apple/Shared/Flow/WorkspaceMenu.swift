import SwiftUI

/// The workspace dropdown's content (VIAFORM-SPEC 6.0), shared by the Mac ribbon, the iPad
/// popover and the iPhone sheet: one row per stage in pipeline order with its icon, name, the
/// active revision of its main artifact, its status and, on a stale or failed stage, the reason.
/// The button's badge counts the other stages that need attention.
struct WorkspaceMenuRow: Identifiable, Equatable {
    let workspace: Workspace
    /// "Assembly v4", "not built".
    let revision: String
    let status: FlowModel.Status
    /// Second line, on stale and failed rows only ("Frame v12 replaced v11").
    let reason: String?
    var id: Workspace { workspace }

    /// What VoiceOver reads for the row.
    var spoken: String {
        var s = "\(workspace.title), \(revision), \(PipelineWords.describe(status))"
        if let reason { s += ", \(reason)" }
        return s
    }
}

/// The attention badge on the dropdown button: other stages that are stale or failed, and
/// whether a job runs in another stage.
struct WorkspaceBadge: Equatable {
    var stale = 0
    var failed = 0
    var running = false

    /// Stages that need an update (stale or failed).
    var count: Int { stale + failed }
    var isEmpty: Bool { count == 0 && !running }
}

enum WorkspaceMenu {
    @MainActor
    static func rows(_ flow: FlowModel) -> [WorkspaceMenuRow] {
        Workspace.allCases.map { row($0, flow: flow) }
    }

    @MainActor
    static func row(_ w: Workspace, flow: FlowModel) -> WorkspaceMenuRow {
        let stage = flow.stage(w)
        let status = stage?.status ?? .empty
        let revision: String
        if let r = flow.revisionName(of: w.stage) {
            revision = r
        } else if w == .robot {
            revision = "No robot connected"
        } else if let stage, stage.artifacts.isEmpty {
            revision = "Not in this product"
        } else {
            revision = "not built"
        }
        let reason = (status == .stale || status == .failed) ? stage.flatMap { $0.reason.isEmpty ? nil : $0.reason } : nil
        return WorkspaceMenuRow(workspace: w, revision: revision, status: status, reason: reason)
    }

    @MainActor
    static func badge(_ flow: FlowModel, current: Workspace) -> WorkspaceBadge {
        var b = WorkspaceBadge()
        for s in flow.stages where s.id != current.stage {
            if s.status == .stale { b.stale += 1 }
            if s.status == .failed { b.failed += 1 }
        }
        b.running = flow.jobs.contains { $0.stage != current.stage }
        return b
    }

    /// "Workspace, Assemble, 2 stages need update".
    static func spoken(current: Workspace, badge: WorkspaceBadge) -> String {
        var s = "Workspace, \(current.title)"
        if badge.count == 1 { s += ", 1 stage needs update" } else if badge.count > 1 { s += ", \(badge.count) stages need update" }
        if badge.running { s += ", a job is running" }
        return s
    }

    /// Rows whose name starts with, then contains, the typed text.
    static func filter(_ rows: [WorkspaceMenuRow], _ query: String) -> [WorkspaceMenuRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        let starts = rows.filter { $0.workspace.title.lowercased().hasPrefix(q) }
        let contains = rows.filter { !$0.workspace.title.lowercased().hasPrefix(q) && $0.workspace.title.lowercased().contains(q) }
        return starts + contains
    }

    @MainActor
    static func anyStale(_ flow: FlowModel) -> Bool {
        flow.stages.contains { $0.status == .stale || $0.status == .failed }
    }

    /// "⌘1".
    static func shortcut(_ w: Workspace) -> String { "\u{2318}\(w.index + 1)" }
    static let updateShortcut = "\u{21E7}\u{2318}U"
}

/// The status sign of a row: green current, orange stale, red failed, a spinner when running,
/// a hollow ring when not built. Shape tells them apart as well as colour.
struct WorkspaceStatusDot: View {
    @Environment(\.viaFormTheme) private var theme
    let status: FlowModel.Status
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch status {
            case .running:
                Circle().trim(from: 0, to: 0.7)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: size + 2, height: size + 2)
                    .modifier(Spinning())
            case .empty:
                Circle().strokeBorder(theme.inkTertiary, lineWidth: 1.25).frame(width: size, height: size)
            case .failed:
                Image(systemName: "xmark.circle.fill").font(.system(size: size + 3, weight: .bold)).foregroundStyle(theme.color(.failed))
            default:
                Circle().fill(theme.color(status)).frame(width: size, height: size)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .accessibilityHidden(true)
    }
}

/// The open dropdown: the nine rows, then "Update all stale" and "Show flow graph". Arrows move
/// the highlight, Return opens it, Esc closes, typing filters.
struct WorkspaceMenuList: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let current: Workspace
    /// Taller rows and no hover on touch.
    var touch = false
    let open: (Workspace) -> Void
    var updateAll: (() -> Void)?
    var showFlow: () -> Void
    var close: () -> Void
    @State private var highlighted: Workspace?
    @State private var query = ""
    @State private var hovered: Workspace?
    @FocusState private var focused: Bool

    private var rows: [WorkspaceMenuRow] { WorkspaceMenu.filter(WorkspaceMenu.rows(flow), query) }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            if !query.isEmpty {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(theme.inkTertiary)
                    Text(query).font(VFFont.row).foregroundStyle(theme.ink)
                    Spacer()
                    Button("Clear") { query = "" }.buttonStyle(.borderless).font(VFFont.small)
                }
                .padding(.horizontal, VFSpace.l)
                .padding(.vertical, VFSpace.s)
                VFHairline()
            }
            VStack(spacing: 2) {
                ForEach(rows) { r in rowView(r) }
                if rows.isEmpty {
                    Text("No stage matches \u{201C}\(query)\u{201D}").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                        .padding(VFSpace.l)
                }
            }
            .padding(VFSpace.s)
            VFHairline().padding(.horizontal, VFSpace.l)
            VStack(spacing: 2) {
                if let updateAll, WorkspaceMenu.anyStale(flow) {
                    footerButton("Update all stale", symbol: "arrow.triangle.2.circlepath", shortcut: WorkspaceMenu.updateShortcut) {
                        close(); updateAll()
                    }
                }
                footerButton("Show flow graph", symbol: "point.3.connected.trianglepath.dotted", shortcut: nil) {
                    showFlow()
                }
            }
            .padding(VFSpace.s)
        }
        .frame(width: touch ? nil : 340)
        .frame(maxWidth: touch ? .infinity : nil)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handle(press, rows: rows) }
        .onAppear {
            highlighted = current
            focused = true
        }
    }

    private func handle(_ press: KeyPress, rows: [WorkspaceMenuRow]) -> KeyPress.Result {
        let list = rows.map(\.workspace)
        switch press.key {
        case .downArrow, .upArrow:
            guard !list.isEmpty else { return .handled }
            let i = highlighted.flatMap { list.firstIndex(of: $0) } ?? -1
            let n = press.key == .downArrow ? min(i + 1, list.count - 1) : max(i - 1, 0)
            highlighted = list[n]
            return .handled
        case .return:
            if let w = highlighted.flatMap({ list.contains($0) ? $0 : nil }) ?? list.first { open(w) }
            return .handled
        case .escape:
            if query.isEmpty { close() } else { query = "" }
            return .handled
        case .delete:
            if !query.isEmpty { query.removeLast() }
            return .handled
        default:
            guard press.modifiers.subtracting([.shift]).isEmpty else { return .ignored }
            let ch = press.characters
            guard ch.count == 1, let c = ch.first, c.isLetter || c == " " else { return .ignored }
            query += ch
            highlighted = WorkspaceMenu.filter(WorkspaceMenu.rows(flow), query).first?.workspace
            return .handled
        }
    }

    private func rowView(_ r: WorkspaceMenuRow) -> some View {
        let on = r.workspace == current
        let lit = highlighted == r.workspace || hovered == r.workspace
        let primary = on ? theme.onAccent : theme.ink
        let secondary = on ? theme.onAccent.opacity(0.85) : theme.inkSecondary
        return Button { open(r.workspace) } label: {
            HStack(alignment: .center, spacing: VFSpace.l) {
                Image(systemName: r.workspace.symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 26)
                    .foregroundStyle(primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.workspace.title).font(VFFont.rowEmphasis).foregroundStyle(primary)
                    Text(r.revision).font(VFFont.small).foregroundStyle(secondary).lineLimit(1)
                    if let reason = r.reason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: VFSpace.m)
                if !on { WorkspaceStatusDot(status: r.status) }
                Text(WorkspaceMenu.shortcut(r.workspace))
                    .font(VFFont.small)
                    .foregroundStyle(secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, VFSpace.m)
            .padding(.vertical, touch ? VFSpace.m : VFSpace.s)
            .frame(minHeight: touch ? VFSize.touchTarget : 40)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.control)
                    .fill(on ? theme.accent : (lit ? theme.well : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.control)
                    .strokeBorder(highlighted == r.workspace && !on ? theme.accent.opacity(0.6) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { hovered = $0 ? r.workspace : (hovered == r.workspace ? nil : hovered) }
        #endif
        .accessibilityLabel(r.spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint("Command \(r.workspace.index + 1)")
    }

    private func footerButton(_ title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: VFSpace.l) {
                Image(systemName: symbol).font(.system(size: 15)).frame(width: 26).foregroundStyle(theme.ink)
                Text(title).font(VFFont.row).foregroundStyle(theme.ink)
                Spacer()
                if let shortcut { Text(shortcut).font(VFFont.small).foregroundStyle(theme.inkSecondary) }
            }
            .padding(.horizontal, VFSpace.m)
            .frame(minHeight: touch ? VFSize.touchTarget : 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The attention badge: an orange count for stale stages, red when one failed, a spinner ring
/// when a job runs in another stage. Nothing when all is current.
struct WorkspaceBadgeView: View {
    @Environment(\.viaFormTheme) private var theme
    let badge: WorkspaceBadge
    var size: CGFloat = 16

    var body: some View {
        if badge.count > 0 {
            Text("\(badge.count)")
                .font(.system(size: size * 0.66, weight: .bold)).monospacedDigit()
                .foregroundStyle(badge.failed > 0 ? Color.white : Color.black)
                .frame(minWidth: size, minHeight: size)
                .background(Circle().fill(theme.color(badge.failed > 0 ? .failed : .stale)))
                .overlay {
                    if badge.running {
                        Circle().trim(from: 0, to: 0.7).stroke(theme.accent, lineWidth: 1.5)
                            .frame(width: size + 5, height: size + 5)
                            .modifier(Spinning())
                    }
                }
                .accessibilityHidden(true)
        } else if badge.running {
            Circle().trim(from: 0, to: 0.7).stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size - 4, height: size - 4)
                .modifier(Spinning())
                .accessibilityHidden(true)
        }
    }
}

/// Turns its content forever (off with Reduce Motion).
struct Spinning: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(on ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
