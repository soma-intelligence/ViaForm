import SwiftUI

/// Everything one workspace puts into the shared window.
struct StageScreen {
    var project: String
    var workspace: Workspace
    var states: PipelineStates
    var jobs = 3
    var groups: [RibbonGroupModel]
    var primary: [PrimaryAction]
    var ribbonTrailing: AnyView = AnyView(EmptyView())
    var rows: [BrowserRow]
    var outputs: [OutputRow]
    var inspector: AnyView
    var viewport: AnyView
    var bottom: AnyView? = nil
    var bottomHeight: CGFloat = 150
    var bottomFullWidth = false
    var status: StatusBar
}

/// The Mac window drawn in plain SwiftUI so ImageRenderer can capture it.
/// The live app uses ProjectWindow (NavigationSplitView + toolbar +
/// inspector) with the very same leaf views.
struct StaticMacWindow: View {
    let screen: StageScreen
    var body: some View {
        VStack(spacing: 0) {
            TitleBar(title: screen.project, active: screen.workspace, states: screen.states, jobs: screen.jobs)
            Ribbon(groups: screen.groups, primary: screen.primary) { screen.ribbonTrailing }
            HStack(spacing: 6) {
                BrowserPanel(rows: screen.rows, outputs: screen.outputs)
                    .frame(width: 264)
                VStack(spacing: 6) {
                    screen.viewport
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(VF.hairline))
                    if let b = screen.bottom, !screen.bottomFullWidth {
                        b.frame(height: screen.bottomHeight).panelWell()
                    }
                }
                screen.inspector.frame(width: 300)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            if let b = screen.bottom, screen.bottomFullWidth {
                b.frame(height: screen.bottomHeight).panelWell()
                    .padding(.horizontal, 6).padding(.bottom, 6)
            }
            screen.status
        }
        .foregroundStyle(VF.text)
        .background(VF.chrome)
        .environment(\.colorScheme, .dark)
    }
}

// Shared bits.
func flowAndLinked(consumes: String, produces: String, states: PipelineStates, current: Workspace) -> some View {
    Group {
        InspectorSection(title: "Flow") { FlowRows(consumes: consumes, produces: produces) }
        InspectorSection(title: "Linked selection") { LinkedSelection(states: states, current: current) }
    }
}

func statusLeading(_ text: String, _ status: StageStatus) -> AnyView {
    AnyView(HStack(spacing: 7) { StatusDot(status: status, size: 8); Text(text) })
}
