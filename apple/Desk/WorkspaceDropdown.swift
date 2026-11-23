#if os(macOS)
import SwiftUI

/// The stage switcher at the far left of the ribbon (VIAFORM-SPEC 6.0, decision D-10): one large
/// button with the active stage's icon in its accent, its name in capitals and a chevron, and a
/// badge counting the other stages that need attention. Click or Command-0 opens the menu of the
/// nine stages; its footer updates every stale stage or opens the flow graph.
struct WorkspaceDropdown: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    @Binding var workspace: Workspace
    @Binding var isOpen: Bool
    /// The flow graph popover, anchored on the button.
    @Binding var showGraph: Bool
    /// A short ribbon (non-design stages): icon and name side by side.
    var short = false
    var updateAll: () -> Void
    @State private var hovered = false
    /// "Show Flow Graph" was picked: the graph opens once the menu's popover has gone.
    @State private var graphAfterClose = false

    var body: some View {
        let badge = WorkspaceMenu.badge(flow, current: workspace)
        Button { isOpen.toggle() } label: {
            label(badge)
        }
        .buttonStyle(.plain)
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, VFSpace.xs)
        .help("Workspaces (Command-0). Command-1 to Command-9 open a stage.")
        .accessibilityLabel(WorkspaceMenu.spoken(current: workspace, badge: badge))
        .accessibilityHint("Opens the list of stages")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            WorkspaceMenuList(flow: flow, current: workspace,
                              open: { w in isOpen = false; workspace = w },
                              updateAll: updateAll,
                              showFlow: {
                                  graphAfterClose = true
                                  isOpen = false
                              },
                              close: { isOpen = false })
                .background(theme.panel)
                // Hand off to the graph when the menu has really left the screen (no fixed delay).
                .onDisappear {
                    if graphAfterClose {
                        graphAfterClose = false
                        showGraph = true
                    }
                }
        }
        .background(
            Color.clear.popover(isPresented: $showGraph, arrowEdge: .bottom) {
                FlowGraphView(flow: flow, current: workspace, open: { w in showGraph = false; workspace = w },
                              updateAll: { showGraph = false; updateAll() })
                    .background(theme.panel)
            }
        )
    }

    private func label(_ badge: WorkspaceBadge) -> some View {
        let tone = workspace.vfStage
        let content = Group {
            if short {
                HStack(spacing: VFSpace.s) {
                    Image(systemName: workspace.symbol).font(VFFont.glyph(18))
                        .foregroundStyle(theme.stageFill(tone))
                    Text(workspace.title.uppercased()).font(VFFont.caps).tracking(VFTypeScale.capsTracking)
                        .foregroundStyle(theme.ink).lineLimit(1).fixedSize()
                    chevron
                }
            } else {
                VStack(spacing: VFSpace.xxs) {
                    Image(systemName: workspace.symbol).font(VFFont.glyph(24))
                        .foregroundStyle(theme.stageFill(tone))
                        .frame(height: 28)
                    HStack(spacing: VFSpace.xxs) {
                        Text(workspace.title.uppercased()).font(VFFont.caps).tracking(VFTypeScale.capsTracking)
                            .foregroundStyle(theme.ink).lineLimit(1).fixedSize()
                        chevron
                    }
                }
            }
        }
        return content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                    .fill(isOpen ? theme.accent.opacity(0.10) : (hovered ? theme.well : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                    .strokeBorder(isOpen ? theme.accent : theme.hairline, lineWidth: isOpen ? 1.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                WorkspaceBadgeView(badge: badge).offset(x: VFSpace.s, y: -VFSpace.s)
            }
            .padding(.vertical, short ? VFSpace.xs : VFSpace.s)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(VFFont.glyph(9, weight: .bold)).foregroundStyle(theme.inkSecondary)
            .accessibilityHidden(true)
    }
}

/// The job capsule in the toolbar while a job runs: verb, progress ring, count and time left
/// ("Generating 74 of 120 · 3 min left"), pause when the job can pause, and Stop; a click opens
/// the jobs list. Liquid Glass: it is a control.
struct ToolbarJobCapsule: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    @State private var shown = false
    private static let height: CGFloat = 26

    var body: some View {
        if let j = flow.queue.jobs.first {
            HStack(spacing: VFSpace.xs) {
                Button { shown.toggle() } label: {
                    HStack(spacing: VFSpace.s) {
                        if j.determinate {
                            ProgressView(value: j.progress).progressViewStyle(.circular).controlSize(.mini)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(j.caption.isEmpty ? j.verb : j.caption).font(VFFont.small).foregroundStyle(theme.ink).lineLimit(1)
                        if flow.jobs.count > 1 {
                            Text("+\(flow.jobs.count - 1)").font(VFFont.micro).foregroundStyle(theme.inkSecondary)
                                .accessibilityLabel(WorkspaceMenu.inflected("^[\(flow.jobs.count - 1) more job](inflect: true)"))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the jobs")
                if j.pausable {
                    VFIconButton(j.paused ? "play.fill" : "pause.fill",
                                 label: j.paused ? String(localized: "Resume \(j.label)") : String(localized: "Pause \(j.label)"),
                                 size: 9) {
                        j.paused ? flow.resume(job: j.id) : flow.pause(job: j.id)
                    }
                }
                VFIconButton("stop.fill", label: String(localized: "Stop \(j.label) (Command-.)"), size: 9) {
                    flow.cancel(job: j.id)
                }
            }
            .padding(.leading, VFSpace.m)
            .padding(.trailing, VFSpace.xxs)
            .frame(height: Self.height)
            .frame(maxWidth: 380)
            .vfSurface(.control, radius: Self.height / 2)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                JobList(flow: flow).padding(VFSpace.l).frame(width: 340).background(theme.panel)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Job, \(j.caption.isEmpty ? j.verb : j.caption)"))
        }
    }
}
#endif
