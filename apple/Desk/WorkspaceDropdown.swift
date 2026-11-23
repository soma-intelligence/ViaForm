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

    var body: some View {
        let badge = WorkspaceMenu.badge(flow, current: workspace)
        Button { isOpen.toggle() } label: {
            label(badge)
        }
        .buttonStyle(.plain)
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, VFSpace.xs)
        .help("Workspaces (Command-0), Command-1 to Command-9 open a stage")
        .accessibilityLabel(WorkspaceMenu.spoken(current: workspace, badge: badge))
        .accessibilityHint("Opens the list of stages")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            WorkspaceMenuList(flow: flow, current: workspace,
                              open: { w in isOpen = false; workspace = w },
                              updateAll: updateAll,
                              showFlow: {
                                  isOpen = false
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { showGraph = true }
                              },
                              close: { isOpen = false })
                .background(theme.panel)
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
                    Image(systemName: workspace.symbol).font(.system(size: 18, weight: .regular))
                        .foregroundStyle(theme.stageFill(tone))
                    Text(workspace.title.uppercased()).font(VFFont.caps).tracking(VFTypeScale.capsTracking)
                        .foregroundStyle(theme.ink).lineLimit(1).fixedSize()
                    chevron
                }
            } else {
                VStack(spacing: 3) {
                    Image(systemName: workspace.symbol).font(.system(size: 24, weight: .regular))
                        .foregroundStyle(theme.stageFill(tone))
                        .frame(height: 28)
                    HStack(spacing: 3) {
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
                RoundedRectangle(cornerRadius: VFRadius.card)
                    .fill(isOpen ? theme.accent.opacity(0.10) : (hovered ? theme.well : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VFRadius.card)
                    .strokeBorder(isOpen ? theme.accent : theme.hairline, lineWidth: isOpen ? 1.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                WorkspaceBadgeView(badge: badge).offset(x: 5, y: -5)
            }
            .padding(.vertical, short ? VFSpace.xs : VFSpace.s)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.inkSecondary)
    }
}

/// The job capsule in the toolbar while a job runs: verb, progress ring, count and time left
/// ("Generating 74 of 120 · 3 min left"), pause and stop; a click opens the jobs list.
struct ToolbarJobCapsule: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    @State private var shown = false

    var body: some View {
        if let j = flow.queue.jobs.first {
            HStack(spacing: VFSpace.s) {
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
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jobs: pause, resume or cancel")
                if j.pausable {
                    Button { j.paused ? flow.resume(job: j.id) : flow.pause(job: j.id) } label: {
                        Image(systemName: j.paused ? "play.fill" : "pause.fill").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help(j.paused ? "Resume" : "Pause")
                    .accessibilityLabel(j.paused ? "Resume \(j.label)" : "Pause \(j.label)")
                }
                Button { flow.cancel(job: j.id) } label: { Image(systemName: "stop.fill").font(.system(size: 9)) }
                    .buttonStyle(.borderless)
                    .help("Stop (Command-.)")
                    .accessibilityLabel("Stop \(j.label)")
            }
            .padding(.horizontal, VFSpace.m)
            .frame(height: 24)
            .frame(maxWidth: 380)
            .background(Capsule().fill(theme.well))
            .overlay(Capsule().strokeBorder(theme.hairline))
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                JobList(flow: flow).padding(12).frame(width: 340).background(theme.panel)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Job, \(j.caption)")
        }
    }
}
#endif
