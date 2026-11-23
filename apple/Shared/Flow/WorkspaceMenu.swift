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
        let state = PipelineWords.describe(status)
        if let reason { return String(localized: "\(workspace.title), \(revision), \(state), \(reason)") }
        return String(localized: "\(workspace.title), \(revision), \(state)")
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
            revision = String(localized: "No robot connected")
        } else if let stage, stage.artifacts.isEmpty {
            revision = String(localized: "Not in this product")
        } else {
            revision = String(localized: "Not built yet")
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

    /// "Workspace, Assemble, 2 stages need an update".
    static func spoken(current: Workspace, badge: WorkspaceBadge) -> String {
        var parts = [String(localized: "Workspace, \(current.title)")]
        if badge.count > 0 { parts.append(inflected("^[\(badge.count) stage](inflect: true) need an update")) }
        if badge.running { parts.append(String(localized: "a job is running")) }
        return parts.joined(separator: ", ")
    }

    /// The badge's words: "2 stale", "1 failed", "3 to update" when both.
    static func badgeText(_ badge: WorkspaceBadge) -> String {
        if badge.failed > 0 && badge.stale > 0 { return String(localized: "\(badge.count) to update") }
        if badge.failed > 0 { return String(localized: "\(badge.failed) failed") }
        return String(localized: "\(badge.stale) stale")
    }

    /// A localized sentence with an inflected count ("^[2 stage](inflect: true)").
    static func inflected(_ key: String.LocalizationValue) -> String {
        String(AttributedString(localized: key).characters)
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

extension ViaFormTheme {
    /// The more legible label colour (ink or panel) on a status fill, for count badges.
    func label(onStatus s: VFStatus) -> Color {
        Color(vf: palette.status(s).bestLabel(light: palette.panel, dark: palette.ink))
    }
}

/// The status sign of a row: the shared `VFStatusDot` (filled dot current, triangle stale, cross
/// failed, turning ring running, hollow dot not built), so shape tells them apart, not colour.
struct WorkspaceStatusDot: View {
    let status: FlowModel.Status
    var size: CGFloat = 8
    /// Why, read as the dot's value and tooltip.
    var reason: String? = nil

    var body: some View {
        VFStatusDot(status: status.vfStatus, size: size, reason: reason)
            .modifier(Spinning(active: status == .running))
            .frame(width: size + 8, height: size + 8)
    }
}

/// The open dropdown: the nine rows, then "Update All Stale" and "Show Flow Graph". Arrows move
/// the highlight, Return opens it, Esc closes, typing filters, a digit opens that stage. The
/// pointer and the keyboard share one highlight, so two rows are never lit at once.
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
    @FocusState private var focused: Bool

    private var rows: [WorkspaceMenuRow] { WorkspaceMenu.filter(WorkspaceMenu.rows(flow), query) }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 0) {
            if !query.isEmpty {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(theme.inkTertiary)
                        .accessibilityHidden(true)
                    Text(query).font(VFFont.row).foregroundStyle(theme.ink)
                    Spacer()
                    Button("Clear") { query = "" }.buttonStyle(.borderless).font(VFFont.small)
                }
                .padding(.horizontal, VFSpace.l)
                .padding(.vertical, VFSpace.s)
                VFHairline()
            }
            VStack(spacing: VFSpace.xxs) {
                ForEach(rows) { r in rowView(r) }
                if rows.isEmpty {
                    Text("No stage matches \u{201C}\(query)\u{201D}").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                        .padding(VFSpace.l)
                }
            }
            .padding(VFSpace.s)
            VFHairline().padding(.horizontal, VFSpace.l)
            VStack(spacing: VFSpace.xxs) {
                if let updateAll, WorkspaceMenu.anyStale(flow) {
                    footerButton(String(localized: "Update All Stale"), symbol: "arrow.triangle.2.circlepath", shortcut: WorkspaceMenu.updateShortcut) {
                        close(); updateAll()
                    }
                }
                footerButton(String(localized: "Show Flow Graph"), symbol: "point.3.connected.trianglepath.dotted", shortcut: nil) {
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
            guard ch.count == 1, let c = ch.first else { return .ignored }
            // A digit opens that stage, as Command-digit does outside the menu.
            if let d = c.wholeNumberValue, d >= 1, d <= Workspace.allCases.count {
                open(Workspace.allCases[d - 1])
                return .handled
            }
            guard c.isLetter || c == " " else { return .ignored }
            query += ch
            highlighted = WorkspaceMenu.filter(WorkspaceMenu.rows(flow), query).first?.workspace
            return .handled
        }
    }

    private func rowView(_ r: WorkspaceMenuRow) -> some View {
        let on = r.workspace == current
        let lit = highlighted == r.workspace
        let primary = on ? theme.onAccent : theme.ink
        let secondary = on ? theme.onAccent.opacity(0.85) : theme.inkSecondary
        return Button { open(r.workspace) } label: {
            HStack(alignment: .center, spacing: VFSpace.l) {
                Image(systemName: r.workspace.symbol)
                    .font(VFFont.glyph(18))
                    .frame(width: 26)
                    .foregroundStyle(primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.workspace.title).font(VFFont.rowEmphasis).foregroundStyle(primary)
                    Text(r.revision).font(VFFont.small).foregroundStyle(secondary).lineLimit(1)
                    if let reason = r.reason {
                        Text(reason).font(VFFont.small).foregroundStyle(secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: VFSpace.m)
                if !on { WorkspaceStatusDot(status: r.status, reason: r.reason).accessibilityHidden(true) }
                Text(WorkspaceMenu.shortcut(r.workspace))
                    .font(VFFont.small)
                    .foregroundStyle(secondary)
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, VFSpace.m)
            .padding(.vertical, touch ? VFSpace.m : VFSpace.s)
            .frame(minHeight: touch ? VFSize.touchTarget : 40)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                    .fill(on ? theme.accent : (lit ? theme.well : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                    .strokeBorder(lit && !on ? theme.accent.opacity(0.6) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        // The pointer moves the one highlight (as in a system menu): never a second one.
        .onHover { if $0 { highlighted = r.workspace } }
        #endif
        .accessibilityLabel(r.spoken)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(String(localized: "Command \(r.workspace.index + 1)"))
    }

    private func footerButton(_ title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: VFSpace.l) {
                Image(systemName: symbol).font(VFFont.glyph(15)).frame(width: 26).foregroundStyle(theme.ink)
                    .accessibilityHidden(true)
                Text(title).font(VFFont.row).foregroundStyle(theme.ink)
                Spacer()
                if let shortcut { Text(shortcut).font(VFFont.small).foregroundStyle(theme.inkSecondary).accessibilityHidden(true) }
            }
            .padding(.horizontal, VFSpace.m)
            .frame(minHeight: touch ? VFSize.touchTarget : 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { if $0 { highlighted = nil } }
        #endif
    }
}

/// The attention badge: "2 stale" (warning, with the stale triangle) or "1 failed" (danger, with
/// the cross), a turning ring when a job runs in another stage. Nothing when all is current.
/// Text colour is the more legible of ink and panel on the status fill.
struct WorkspaceBadgeView: View {
    @Environment(\.viaFormTheme) private var theme
    let badge: WorkspaceBadge
    var size: CGFloat = 16

    var body: some View {
        if badge.count > 0 {
            let status: VFStatus = badge.failed > 0 ? .failed : .stale
            let ink = theme.label(onStatus: status)
            HStack(spacing: VFSpace.xxs) {
                Group {
                    if status == .failed {
                        Image(systemName: "xmark").font(VFFont.glyph(size * 0.45, weight: .heavy))
                    } else {
                        VFTriangle().frame(width: size * 0.42, height: size * 0.36)
                    }
                }
                .foregroundStyle(ink)
                Text(WorkspaceMenu.badgeText(badge))
                    .font(VFFont.micro.weight(.semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, VFSpace.s)
            .frame(minHeight: size)
            .background(Capsule().fill(theme.status(status)))
            .overlay {
                if badge.running {
                    Capsule().strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                        .padding(-2.5)
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

/// Turns its content forever (still under Reduce Motion).
struct Spinning: ViewModifier {
    var active = true
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(on && active ? 360 : 0))
            .vfAnimation(.linear(duration: 1).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}
