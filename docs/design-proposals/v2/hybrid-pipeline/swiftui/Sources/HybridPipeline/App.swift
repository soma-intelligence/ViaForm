import SwiftUI

extension Renderer { static var extraScreens: [(name: String, size: CGSize, view: AnyView)] { [
        ("2-generative", CGSize(width: 1600, height: 1000), AnyView(StaticMacWindow(screen: GenerativeStage.screen))),
        ("3-simulation", CGSize(width: 1600, height: 1000), AnyView(StaticMacWindow(screen: SimulationStage.screen))),
        ("4-electronics", CGSize(width: 1600, height: 1000), AnyView(StaticMacWindow(screen: ElectronicsStage.screen))),
        ("5-ipad", CGSize(width: 1366, height: 1024), AnyView(IPadScreen())),
    ] } }

struct HybridPipelineApp: App {
    var body: some Scene {
        WindowGroup("ViaForm") {
            ProjectWindow().frame(minWidth: 1280, minHeight: 800)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}

/// The live Mac window: real NavigationSplitView, unified toolbar and
/// .inspector, built from the same leaf views the static renders use.
/// ImageRenderer cannot capture window chrome, so the PNGs come from
/// StaticMacWindow instead.
struct ProjectWindow: View {
    @State private var workspace: Workspace = .design
    @State private var showInspector = true
    @State private var showBottom = true

    private var screen: StageScreen {
        switch workspace {
        case .generative: GenerativeStage.screen
        case .simulation, .training: SimulationStage.screen
        case .electronics: ElectronicsStage.screen
        default: DesignStage.screen
        }
    }

    var body: some View {
        let s = screen
        NavigationSplitView {
            BrowserPanel(rows: s.rows, outputs: s.outputs)
                .navigationSplitViewColumnWidth(min: 230, ideal: 264, max: 280)
        } detail: {
            VStack(spacing: 6) {
                s.viewport
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if showBottom, let b = s.bottom {
                    b.frame(height: s.bottomHeight).panelWell()
                }
                s.status
            }
            .padding(6)
            .safeAreaInset(edge: .top, spacing: 0) {
                Ribbon(groups: s.groups, primary: s.primary) { s.ribbonTrailing }
            }
            .background(VF.chrome)
        }
        .inspector(isPresented: $showInspector) {
            s.inspector.inspectorColumnWidth(300)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(s.project).font(.system(size: 13, weight: .semibold))
            }
            ToolbarItem(placement: .principal) {
                PipelineBar(active: workspace, states: s.states, onSelect: { workspace = $0 })
            }
            ToolbarItemGroup(placement: .primaryAction) {
                JobsButton(count: s.jobs)
                Button { } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .background {
            // Cmd+1 to Cmd+8 switch workspace.
            ForEach(Workspace.allCases) { ws in
                Button("") { workspace = ws }
                    .keyboardShortcut(KeyEquivalent(Character("\(ws.rawValue + 1)")), modifiers: .command)
                    .hidden()
            }
        }
        .foregroundStyle(VF.text)
        .preferredColorScheme(.dark)
    }
}
