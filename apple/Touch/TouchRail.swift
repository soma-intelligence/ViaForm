#if os(iOS)
import SwiftUI

// The iPad design screen's chrome style, after the reference tablet layout
// (docs/research/cad-ui/shapr3d-ipad.md 1.1; frames FFeIJJ1pm70 @ 05:00 to @ 17:30, measured at
// 0.54 px per point): every control is an icon on a white tile that hugs the screen edge, its
// label floats on the canvas beside it with no capsule. Rows that belong together share one
// tile (the sketch tools, the constraints, the view modes); Search, Deselect All, Exit
// Sketching, More, Delete, History and the undo circles each have their own. The left side
// carries the labels on the right of the icons, the right side on their left.

/// Layout facts of the iPad design screen, in points.
enum TouchRail {
    /// Width of the icon tiles (and the height of a lone tile).
    static let tile: CGFloat = 44
    /// Gap between a tile and the screen edge.
    static let edge: CGFloat = 6
    /// Gap above the top tiles, the title pill and the side panels.
    static let top: CGFloat = 20
    /// Gap under the undo tiles and the side panels.
    static let bottom: CGFloat = 12
    /// Tallest and shortest row; under `rowTight` the label drops to one smaller line of text.
    static let rowMax: CGFloat = 44
    static let rowMin: CGFloat = 28
    static let rowTight: CGFloat = 36
    /// Rows of the Modeling and Items tile.
    static let topRow: CGFloat = 40
    /// Gap between two tiles.
    static let gap: CGFloat = 8
    static let radius: CGFloat = 12
    /// Gap between an icon tile and its floating label.
    static let labelGap: CGFloat = 4
    /// The view cube, beside the snapping rail.
    static let cube: CGFloat = 46
    /// The size `ViewCube` is drawn at so its face reads `cube` wide (it keeps room for its
    /// orbit arrows and home button around the face).
    static let cubeDraw: CGFloat = 72
    /// The snapping rail's rows (magnet, grid, view options).
    static let railRow: CGFloat = 40
    /// Side panels: Items on the tool edge, History on the panel edge.
    static let itemsWidth: CGFloat = 300
    static let historyWidth: CGFloat = 384
    static let panelRadius: CGFloat = 14
    /// The title pill and the tool mode pill under it.
    static let titleHeight: CGFloat = 44
    static let modeHeight: CGFloat = 28
    /// The (i) readout at the bottom centre.
    static let readoutHeight: CGFloat = 44

    /// Height the left side spends outside its rows: the insets, the Modeling and Items tile,
    /// the undo tiles and the gaps around the column.
    static let leftFixed: CGFloat = top + 2 * topRow + tile + bottom + 4 * gap
    /// Height the right side spends outside the constraint rows: the rail, History, the gaps.
    static let rightFixed: CGFloat = top + 3 * railRow + tile + bottom + 4 * gap

    /// The row height that fits `rows` rows in `groups` tiles in `height`, between `rowMin`
    /// and `rowMax`, so the sketch column never scrolls on a 768 point tall iPad.
    static func rowHeight(height: CGFloat, fixed: CGFloat, rows: Int, groups: Int) -> CGFloat {
        guard rows > 0 else { return rowMax }
        let free = height - fixed - CGFloat(max(0, groups - 1)) * gap
        return min(rowMax, max(rowMin, (free / CGFloat(rows)).rounded(.down)))
    }
}

extension EnvironmentValues {
    /// The height of one rail row (`TouchRail.rowHeight`), set by the root per side.
    @Entry var touchRailRow: CGFloat = TouchRail.rowMax
    /// The screen edge the rail hugs: labels float on the other side of the icon.
    @Entry var touchRailEdge: HorizontalEdge = .leading
}

/// Colours of the rail, from the theme.
struct TouchRailColors {
    let theme: ViaFormTheme
    /// The white tile under the icons.
    var tile: Color { theme.panel }
    /// The tile's soft drop shadow.
    var shadow: Color { .black.opacity(theme.isDark ? 0.35 : 0.08) }
    /// The grey square behind the armed tool's icon.
    var activeWell: Color { theme.well }
    /// A floating label.
    var label: Color { theme.ink }
    /// Opacity of the faint plate under a floating label.
    var labelPlate: Double { theme.isDark ? 0.25 : 0.35 }
    /// A grey (unavailable) entry.
    var disabled: Color { theme.inkTertiary }
}

/// One tile of rows: the white tile is drawn behind the icon column only, the labels float.
struct TouchRailGroup<Content: View>: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.touchRailEdge) private var edge
    @ViewBuilder var content: () -> Content

    var body: some View {
        let lead = edge == .leading
        VStack(alignment: lead ? .leading : .trailing, spacing: 0) { content() }
            .background(alignment: lead ? .leading : .trailing) {
                RoundedRectangle(cornerRadius: TouchRail.radius, style: .continuous)
                    .fill(TouchRailColors(theme: theme).tile)
                    .shadow(color: TouchRailColors(theme: theme).shadow, radius: 4, y: 1)
                    .frame(width: TouchRail.tile)
            }
    }
}

/// One row: the icon in the tile, the label (and a grey subtitle) floating beside it.
struct TouchRailRow: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.touchRailRow) private var row
    @Environment(\.touchRailEdge) private var edge
    let symbol: String
    let title: String
    var subtitle: String?
    /// The armed tool: a grey square behind its icon.
    var active = false
    var enabled = true
    var destructive = false
    /// The icon's own colour (the workspace's, Done's blue, Cancel's red).
    var tint: Color?
    /// The running tool: its label sits on a light plate.
    var plate = false
    /// Icon only (the snapping rail).
    var iconOnly = false

    var body: some View {
        let colors = TouchRailColors(theme: theme)
        let tight = row < TouchRail.rowTight
        let ink = !enabled ? colors.disabled : (destructive ? theme.danger : colors.label)
        let icon = Image(systemName: symbol)
            .font(VFFont.icon(tight ? 15 : 17, weight: .medium))
            .foregroundStyle(enabled ? (tint ?? ink) : colors.disabled)
            .frame(width: TouchRail.tile - 10, height: min(row, TouchRail.tile) - 8)
            .background(active ? colors.activeWell : .clear, in: RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous))
            .frame(width: TouchRail.tile, height: row)
        let lead = edge == .leading
        HStack(spacing: TouchRail.labelGap) {
            if lead { icon }
            if !iconOnly {
                VStack(alignment: lead ? .leading : .trailing, spacing: 0) {
                    Text(title).font(tight ? VFFont.small.weight(.medium) : VFFont.row.weight(.medium)).lineLimit(1)
                    // Under 30 points a second line no longer fits: the mode stays in the long-press menu.
                    if let subtitle, row >= 30 {
                        Text(subtitle).font(VFFont.micro.weight(.regular)).foregroundStyle(enabled ? theme.inkSecondary : colors.disabled).lineLimit(1)
                    }
                }
                .foregroundStyle(ink)
                // A faint plate keeps the label legible over the model (the reference's labels
                // carry one); the running tool's is near opaque.
                .padding(.horizontal, VFSpace.xs)
                .padding(.vertical, VFSpace.xxs)
                .background(colors.tile.opacity(plate ? 0.92 : colors.labelPlate),
                            in: RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous))
                .fixedSize()
            }
            if !lead { icon }
        }
        .frame(height: row)
        .contentShape(Rectangle())
    }
}

/// A lone square tile with one icon (undo, redo).
struct TouchRailSquare: View {
    @Environment(\.viaFormTheme) private var theme
    let symbol: String
    var enabled = true

    var body: some View {
        let colors = TouchRailColors(theme: theme)
        Image(systemName: symbol)
            .font(VFFont.icon(16, weight: .medium))
            .foregroundStyle(enabled ? colors.label : colors.disabled)
            .frame(width: TouchRail.tile, height: TouchRail.tile)
            .background(colors.tile, in: RoundedRectangle(cornerRadius: TouchRail.radius, style: .continuous))
            .shadow(color: colors.shadow, radius: 4, y: 1)
            .contentShape(Rectangle())
    }
}

/// An opaque side panel from the top to the bottom of the screen (Items, History).
struct TouchSidePanel: ViewModifier {
    @Environment(\.viaFormTheme) private var theme
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: TouchRail.panelRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: TouchRail.panelRadius, style: .continuous))
            .shadow(color: TouchRailColors(theme: theme).shadow, radius: 8, y: 2)
    }
}
#endif

#if os(iOS)
/// The rail's press feedback: a light dim and shrink, no minimum size (the rail sets each
/// row's height; `vfTouch` would grow short rows back to 44 points).
struct TouchRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Press(configuration: configuration) }

    private struct Press: View {
        @Environment(\.accessibilityReduceMotion) private var reduce
        let configuration: Configuration

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : 1)
                .scaleEffect(configuration.isPressed && !reduce ? 0.97 : 1)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
    }
}

extension ButtonStyle where Self == TouchRailButtonStyle {
    static var touchRail: TouchRailButtonStyle { TouchRailButtonStyle() }
}
#endif

#if os(iOS)
/// The rail's press style where a control is on the rail, the touch style elsewhere.
struct TouchRailPress: ViewModifier {
    let rail: Bool
    func body(content: Content) -> some View {
        if rail { content.buttonStyle(.touchRail) } else { content.buttonStyle(.vfTouch) }
    }
}
#endif
