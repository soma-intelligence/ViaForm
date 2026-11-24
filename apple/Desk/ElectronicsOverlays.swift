#if os(macOS)
import SwiftUI

/// Electronics' bottom panel: the layer bar with the board revision, over the dot rail.
struct ElectronicsBottomPanel: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let pcb: PCBModel
    let design: DesignModel
    let flow: FlowModel
    @Binding var hidden: Set<String>
    let actions: StageActions

    var body: some View {
        let _ = units
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
            .init(id: "parts", label: String(localized: "Parts"), symbol: "cpu", tint: theme.accent, done: parts > 0,
                  detail: String(localized: "\(parts) placed")) {
                pcb.sheet = .schematic; pcb.tool = .select
            },
            .init(id: "wires", label: String(localized: "Wires"), symbol: "point.topleft.down.to.point.bottomright.curvepath",
                  tint: theme.stageFill(.electronics), done: wires > 0, detail: String(localized: "\(wires) wires")) {
                pcb.sheet = .schematic; pcb.tool = .wire
            },
            .init(id: "board", label: String(localized: "Board"), symbol: "square.grid.3x3.square", tint: theme.success, done: fps > 0,
                  detail: String(localized: "\(fps) footprints")) {
                pcb.updateBoard(); pcb.sheet = .board
            },
            .init(id: "route", label: String(localized: "Route"), symbol: "scribble", tint: theme.stageFill(.electronics), done: tracks > 0 && unrouted == 0,
                  detail: unrouted > 0 ? String(localized: "\(unrouted) left") : String(localized: "\(tracks) tracks")) {
                pcb.sheet = .board; pcb.tool = .route
            },
            .init(id: "rules", label: String(localized: "Rules"), symbol: "checkmark.shield", tint: theme.success, done: fps > 0 && findings == 0,
                  detail: findings == 0 ? String(localized: "0 errors") : String(localized: "\(findings) findings")) { actions.run("electronics.drc") },
            .init(id: "3d", label: String(localized: "In 3D"), symbol: "cube", tint: theme.stageFill(.design), done: info.linked && !info.outOfDate,
                  detail: info.revision.map { info.outOfDate ? String(localized: "rev \($0), behind") : String(localized: "rev \($0)") } ?? String(localized: "not sent")) {
                pcb.sendTo3D(design)
            },
            .init(id: "mount", label: String(localized: "Mounted"), symbol: "link", tint: theme.stageFill(.assemble), done: info.host != nil,
                  detail: info.host ?? String(localized: "no part")) {
                pcb.startMount(design) { actions.open(.assemble) }
            },
            .init(id: "fit", label: String(localized: "Fits"), symbol: "rectangle.dashed", tint: theme.success, done: info.host != nil && info.fits,
                  detail: info.clearance.map { String(localized: "\(VFFormat.length($0)) room") } ?? String(localized: "no keep-in")) { actions.open(.assemble) },
        ]
    }
}
#endif
