#if os(macOS)
import SwiftUI

/// Electronics' bottom panel: the layer bar with the board revision, over the dot rail.
struct ElectronicsBottomPanel: View {
    @Environment(\.viaFormTheme) private var theme
    let pcb: PCBModel
    let design: DesignModel
    let flow: FlowModel
    @Binding var hidden: Set<String>
    let actions: StageActions

    var body: some View {
        let info = BoardLinkInfo.read(design: design, pcb: pcb)
        VStack(spacing: VFSpace.xs) {
            HStack(spacing: VFSpace.l) {
                PCBLayerBar(hidden: $hidden, active: pcb.layer) { pcb.layer = $0 }
                Spacer(minLength: VFSpace.m)
                if let r = flow.revisionName(of: "electronics") {
                    Text(r).font(VFFont.small.weight(.semibold)).foregroundStyle(theme.inkSecondary)
                }
            }
            DotRailTimeline(steps: steps(info))
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.vertical, VFSpace.s)
        .background(theme.chrome)
    }

    private func steps(_ info: BoardLinkInfo) -> [DotRailTimeline.Step] {
        let p = pcb.project
        let parts = p?.components.count ?? 0, wires = p?.wires.count ?? 0
        let fps = p?.board.footprints.count ?? 0, tracks = p?.board.tracks.count ?? 0
        let unrouted = pcb.checks?.airwires.count ?? 0
        let findings = pcb.findings.count
        return [
            .init(id: "parts", label: "Parts", symbol: "cpu", tint: theme.accent, done: parts > 0, detail: "\(parts) placed") {
                pcb.sheet = .schematic; pcb.tool = .select
            },
            .init(id: "wires", label: "Wires", symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: .teal, done: wires > 0, detail: "\(wires) wires") {
                pcb.sheet = .schematic; pcb.tool = .wire
            },
            .init(id: "board", label: "Board", symbol: "square.grid.3x3.square", tint: theme.success, done: fps > 0, detail: "\(fps) footprints") {
                pcb.updateBoard(); pcb.sheet = .board
            },
            .init(id: "route", label: "Route", symbol: "scribble", tint: PCBDense.front, done: tracks > 0 && unrouted == 0,
                  detail: unrouted > 0 ? "\(unrouted) left" : "\(tracks) tracks") {
                pcb.sheet = .board; pcb.tool = .route
            },
            .init(id: "rules", label: "Rules", symbol: "checkmark.shield", tint: theme.success, done: fps > 0 && findings == 0,
                  detail: findings == 0 ? "0 errors" : "\(findings) findings") { actions.run("electronics.drc") },
            .init(id: "3d", label: "In 3D", symbol: "cube", tint: .purple, done: info.linked && !info.outOfDate,
                  detail: info.revision.map { info.outOfDate ? "rev \($0), behind" : "rev \($0)" } ?? "not sent") { pcb.sendTo3D(design) },
            .init(id: "mount", label: "Mounted", symbol: "link", tint: .orange, done: info.host != nil, detail: info.host ?? "no part") {
                pcb.startMount(design) { actions.open(.assemble) }
            },
            .init(id: "fit", label: "Fits", symbol: "rectangle.dashed", tint: theme.success, done: info.host != nil && info.fits,
                  detail: info.clearance.map { String(format: "%.1f mm room", $0) } ?? "no keep-in") { actions.open(.assemble) },
        ]
    }
}
#endif
