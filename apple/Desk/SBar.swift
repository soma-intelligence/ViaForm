#if os(macOS)
import SwiftUI

/// The contextual S bar (M-15, after the SolidWorks S key): S opens the command palette with a
/// grid of the likely tools for the current mode above its search field. Command-K opens the
/// plain palette. A SolidWorks extra: shown only with Settings > SolidWorks extras on
/// (SolidWorksExtras); by default S opens Fusion's plain toolbox search.
@MainActor
enum SBar {
    enum Mode: String, CaseIterable { case sketch, solid, assemble, render, stage }

    static func mode(workspace: Workspace, sketchOpen: Bool) -> Mode {
        switch workspace {
        case .design: sketchOpen ? .sketch : .solid
        case .assemble: sketchOpen ? .sketch : .assemble
        case .render: .render
        default: .stage
        }
    }

    /// Registry ids per mode, in grid order. Ids the engine build lacks are skipped.
    static func ids(_ mode: Mode) -> [String] {
        switch mode {
        case .sketch:
            ["sketch.line", "sketch.rectangle.two_point", "sketch.circle.center", "sketch.arc.three_point",
             "sketch.polygon.inscribed", "sketch.slot.center_to_center", "sketch.spline.fit_point", "sketch.trim",
             "sketch.offset", "sketch.fillet", "sketch.point", "sketch.finish"]
        case .solid:
            ["sketch.create", "solid.extrude", "solid.revolve", "solid.press_pull", "solid.fillet", "solid.chamfer",
             "solid.shell", "solid.hole", "solid.combine", "solid.move", "solid.mirror", "inspect.measure"]
        case .assemble:
            ["solid.move", "inspect.measure", "solid.combine", "sketch.create", "solid.extrude", "solid.mirror"]
        case .render:
            []
        case .stage:
            []
        }
    }

    /// One tile of the grid.
    struct Tile: Identifiable {
        let id: String
        let title: String
        let icon: String
        let key: String?
        let source: String
        let run: () -> Void
    }

    /// The tiles for the window's mode: registry commands in the 3D stages, the stage's own verbs
    /// (and the render tab's commands) elsewhere. Twelve at most.
    static func tiles(workspace: Workspace, model: DesignModel, flow: FlowModel, actions: StageActions) -> [Tile] {
        let mode = mode(workspace: workspace, sketchOpen: model.sketchOpen)
        let wanted = ids(mode)
        if !wanted.isEmpty {
            return wanted.compactMap { id in
                guard let c = model.commands.first(where: { $0.id == id }) else { return nil }
                return Tile(id: c.id, title: StageLabels.command(c.label), icon: c.icon, key: c.key, source: "design") {
                    CommandRouter.run(c, model)
                }
            }
        }
        if mode == .render {
            return model.commands.filter { $0.tab.hasPrefix("RENDER") }.prefix(12).map { c in
                Tile(id: c.id, title: StageLabels.command(c.label), icon: c.icon, key: c.key, source: "design") { CommandRouter.run(c, model) }
            }
        }
        return flow.commands(stage: workspace.stage).filter { $0.source == "app" }.prefix(12).map { c in
            Tile(id: c.id, title: StageLabels.command(c.label), icon: c.icon, key: c.key, source: c.source) { actions.run(c.id) }
        }
    }
}

/// The grid of S-bar tiles, shown above the palette's search field.
struct SBarGrid: View {
    @Environment(\.viaFormTheme) private var theme
    let tiles: [SBar.Tile]
    var close: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: VFSpace.xs), count: 6)

    var body: some View {
        if tiles.isEmpty {
            EmptyView()
        } else {
            LazyVGrid(columns: columns, spacing: VFSpace.xs) {
                ForEach(tiles) { t in
                    Button { close(); t.run() } label: {
                        VStack(spacing: VFSpace.xxs) {
                            Group {
                                if t.source == "design" {
                                    ToolChipIcon(icon: t.icon, id: t.id, size: 20, style: .never)
                                } else {
                                    Image(systemName: StageLabels.symbol(forVerb: t.icon)).font(VFFont.glyph(16))
                                }
                            }
                            .frame(height: 24)
                            .accessibilityHidden(true)
                            Text(t.title).font(VFFont.micro).lineLimit(1).truncationMode(.tail)
                        }
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SBarTileStyle())
                    .help(t.key.map { "\(t.title) (\(DeskKeymap.glyph($0)))" } ?? t.title)
                    .accessibilityLabel(t.title)
                }
            }
            .padding(VFSpace.s)
        }
    }
}

private struct SBarTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SBarTileBody(configuration: configuration) }
}

private struct SBarTileBody: View {
    @Environment(\.viaFormTheme) private var theme
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                .fill(configuration.isPressed ? theme.selection : (hovered ? theme.well : .clear)))
            .onHover { hovered = $0 }
    }
}
#endif
