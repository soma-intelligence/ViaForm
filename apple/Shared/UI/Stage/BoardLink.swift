import SwiftUI
import simd

// The board's link to the 3D design, drawn the same on the Mac and the iPad: the link card, the
// keep-in and clearance annotations, the rule-check capsule, the layer bar and the dot rail.

/// Where the board sits in the 3D design, read from the design itself: the component the link
/// built (`vf_link_push`, tagged by the link), its revision (`vf_link_revision`), the part it is
/// seated on (`vf_link_mount` puts the board's bottom face on a face of that part) and the room
/// around it on that part.
///
/// The host is the body under the board whose top meets the board's bottom (within half a
/// millimetre) and whose footprint holds the board's centre. Clearance is measured in the
/// board's plane from the board's outline to the host's outline, side by side. The board is
/// assumed square to the world axes (the link builds it that way; a board turned by a joint
/// afterwards reads its sides swapped).
struct BoardLinkInfo {
    /// The link built a board component in the design.
    var linked = false
    /// The PCB revision the 3D board was built from.
    var revision: Int?
    /// The board changed since.
    var outOfDate = false
    var boardBodies: Set<String> = []
    var host: String?
    /// Room from the board's edge to the host's edge, in mm, on the sheet's sides.
    var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0
    /// The board's size as built in 3D (x, y), in mm.
    var size3D = SIMD2<Double>(0, 0)

    var clearance: Double? { host == nil ? nil : min(left, right, top, bottom) }
    var fits: Bool { (clearance ?? 0) >= 0 }

    /// The side with the least room, for the clearance dimension.
    enum Side { case left, right, top, bottom }
    var tightest: Side {
        let m = min(left, right, top, bottom)
        return m == left ? .left : m == right ? .right : m == top ? .top : .bottom
    }

    @MainActor
    static func read(design: DesignModel, pcb: PCBModel) -> BoardLinkInfo {
        var info = BoardLinkInfo()
        info.revision = pcb.linkedRevision
        info.outOfDate = pcb.boardOutOfDate
        guard let part = design.assembly.first(where: \.linkedPCB) else { return info }
        info.linked = true
        info.boardBodies = Set(part.bodies)
        let scene = design.scene
        guard let board = AnchorLayout.bounds(of: info.boardBodies, in: scene) else { return info }
        info.size3D = SIMD2(board.max.x - board.min.x, board.max.y - board.min.y)
        let centre = SIMD2((board.min.x + board.max.x) / 2, (board.min.y + board.max.y) / 2)
        // Among the bodies whose top meets the board's bottom under its centre, the one that
        // covers most of the board, then the smallest (a plate before the arms crossing it).
        var best: (name: String, box: (min: SIMD3<Double>, max: SIMD3<Double>), cover: Double, area: Double)?
        let others = Set(scene.meshes.map(\.body)).subtracting(info.boardBodies).sorted()
        for name in others {
            guard let b = AnchorLayout.bounds(of: [name], in: scene) else { continue }
            let under = abs(b.max.z - board.min.z) < 0.5
            let holds = b.min.x <= centre.x && centre.x <= b.max.x && b.min.y <= centre.y && centre.y <= b.max.y
            guard under, holds else { continue }
            let ox = max(0, min(b.max.x, board.max.x) - max(b.min.x, board.min.x))
            let oy = max(0, min(b.max.y, board.max.y) - max(b.min.y, board.min.y))
            let cover = ox * oy, area = (b.max.x - b.min.x) * (b.max.y - b.min.y)
            if best == nil || cover > best!.cover + 1e-6 || (abs(cover - best!.cover) <= 1e-6 && area < best!.area) {
                best = (name, b, cover, area)
            }
        }
        guard let host = best else { return info }
        info.host = host.name
        info.left = board.min.x - host.box.min.x
        info.right = host.box.max.x - board.max.x
        // Sheet y runs down: its top is the world's +y side.
        info.top = host.box.max.y - board.max.y
        info.bottom = board.min.y - host.box.min.y
        return info
    }
}

/// The 3D link card over the board: a live view of the board in its part, the revision state
/// (Live, or how far behind), the part it is mounted on and the clearance, with the actions.
struct LinkCard: View {
    @Environment(\.viaFormTheme) private var theme
    let info: BoardLinkInfo
    let design: DesignModel
    let pcb: PCBModel
    let showIn3D: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack(spacing: VFSpace.s) {
                VFCaption("3D link")
                Spacer(minLength: 0)
                badge
            }
            if info.linked {
                SceneThumbnail(scene: design.scene, highlight: info.boardBodies, focus: info.boardBodies)
                    .frame(height: 128)
                    .background(RoundedRectangle(cornerRadius: VFRadius.well).fill(theme.isDark ? Color.black.opacity(0.25) : Color(white: 0.93)))
                    .clipShape(RoundedRectangle(cornerRadius: VFRadius.well))
                    .onTapGesture(perform: showIn3D)
                row("Mounted on", info.host ?? "Not mounted", accent: info.host != nil)
                if let c = info.clearance {
                    row("Clearance", String(format: "%.2f mm", c), warn: c < 0)
                }
                row("Board", String(format: "%.1f x %.1f mm", info.size3D.x, info.size3D.y))
            } else {
                Text("The board is not in the 3D design yet. Send it to place it on a part of the assembly.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: VFSpace.s) {
                Button(info.linked ? (info.outOfDate ? "Update 3D" : "Push to 3D") : "Send to 3D") { pcb.sendTo3D(design) }
                    .buttonStyle(.vfPrimary)
                    #if os(iOS)
                    .frame(minHeight: VFSize.touchTarget)
                    #endif
                Button(info.host == nil ? "Mount…" : "Remount…") { pcb.startMount(design, show: showIn3D) }
                    #if os(iOS)
                    .frame(minHeight: VFSize.touchTarget)
                    #else
                    .controlSize(.small)
                    #endif
            }
        }
        .padding(VFSpace.l)
        .frame(width: 264)
        .vfSurface(.floating, radius: VFRadius.floating)
        .overlay(RoundedRectangle(cornerRadius: VFRadius.floating).strokeBorder(theme.accent.opacity(info.linked ? 0.55 : 0), lineWidth: 1))
    }

    @ViewBuilder private var badge: some View {
        if info.linked {
            let behind = info.outOfDate
            HStack(spacing: 4) {
                Circle().fill(behind ? theme.warning : theme.success).frame(width: 6, height: 6)
                Text(behind ? "Board rev \(info.revision.map(String.init) ?? "?") in 3D" : "Live")
                    .font(.system(size: VFTypeScale.micro, weight: .semibold))
            }
            .foregroundStyle(behind ? theme.warning : theme.success)
            .padding(.horizontal, 7).frame(height: 18)
            .background(Capsule().fill((behind ? theme.warning : theme.success).opacity(0.14)))
            .help(behind ? "The board changed since it was sent to 3D" : "The 3D board is the board you are editing")
        }
    }

    private func row(_ k: String, _ v: String, accent: Bool = false, warn: Bool = false) -> some View {
        HStack {
            Text(k).foregroundStyle(theme.inkSecondary)
            Spacer(minLength: VFSpace.m)
            Text(v).foregroundStyle(warn ? theme.danger : (accent ? theme.accentText : theme.ink)).lineLimit(1).monospacedDigit()
        }
        .font(VFFont.small)
    }
}

/// Over the board: the keep-in from the host part (dashed), the board's width dimension, the
/// clearance dimension on the tightest side, and the leader from the link card to the board's
/// mount point. Drawn in the canvas's own coordinates (`PCBCanvasTransform`).
struct BoardLinkAnnotations: View {
    @Environment(\.viaFormTheme) private var theme
    let info: BoardLinkInfo
    let board: CGSize          // the sheet's board, mm
    let transform: PCBCanvasTransform
    /// The link card's frame in the same space, for the leader.
    let card: CGRect?

    var body: some View {
        Canvas { ctx, _ in
            let t = transform
            let accent = theme.accent
            let b0 = t.view(PCBPoint(x: 0, y: 0)), b1 = t.view(PCBPoint(x: board.width, y: board.height))
            // Board width dimension above the board, and above the keep-in when there is one.
            let keepTop = info.host != nil ? t.view(PCBPoint(x: 0, y: -info.top)).y : b0.y
            let dy = min(b0.y, keepTop) - 22
            var dim = Path()
            dim.move(to: CGPoint(x: b0.x, y: dy)); dim.addLine(to: CGPoint(x: b1.x, y: dy))
            dim.move(to: CGPoint(x: b0.x, y: dy - 6)); dim.addLine(to: CGPoint(x: b0.x, y: dy + 6))
            dim.move(to: CGPoint(x: b1.x, y: dy - 6)); dim.addLine(to: CGPoint(x: b1.x, y: dy + 6))
            ctx.stroke(dim, with: .color(accent), lineWidth: 1.2)
            label(&ctx, String(format: "%.2f", board.width), CGPoint(x: (b0.x + b1.x) / 2, y: dy - 9), accent)

            if info.host != nil {
                let k0 = t.view(PCBPoint(x: -info.left, y: -info.top))
                let k1 = t.view(PCBPoint(x: board.width + info.right, y: board.height + info.bottom))
                let keep = CGRect(x: k0.x, y: k0.y, width: k1.x - k0.x, height: k1.y - k0.y)
                ctx.stroke(Path(keep), with: .color(info.fits ? accent : theme.danger), style: StrokeStyle(lineWidth: 1.3, dash: [6, 4]))
                let host = info.host ?? ""
                ctx.draw(Text(String(format: "Keep-in %.0f x %.0f from %@", board.width + info.left + info.right, board.height + info.top + info.bottom, host))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(accent),
                         at: CGPoint(x: keep.minX, y: keep.maxY + 6), anchor: .topLeading)
                // Clearance on the tightest side.
                var c = Path()
                let tl: CGPoint
                switch info.tightest {
                case .left:
                    let y = (b0.y + b1.y) / 2
                    c.move(to: CGPoint(x: keep.minX, y: y)); c.addLine(to: CGPoint(x: b0.x, y: y))
                    tl = CGPoint(x: (keep.minX + b0.x) / 2, y: y - 12)
                case .right:
                    let y = (b0.y + b1.y) / 2
                    c.move(to: CGPoint(x: b1.x, y: y)); c.addLine(to: CGPoint(x: keep.maxX, y: y))
                    tl = CGPoint(x: (keep.maxX + b1.x) / 2, y: y - 12)
                case .top:
                    let x = (b0.x + b1.x) / 2 + 40
                    c.move(to: CGPoint(x: x, y: keep.minY)); c.addLine(to: CGPoint(x: x, y: b0.y))
                    tl = CGPoint(x: x + 46, y: (keep.minY + b0.y) / 2)
                case .bottom:
                    let x = (b0.x + b1.x) / 2 + 40
                    c.move(to: CGPoint(x: x, y: b1.y)); c.addLine(to: CGPoint(x: x, y: keep.maxY))
                    tl = CGPoint(x: x + 46, y: (keep.maxY + b1.y) / 2)
                }
                ctx.stroke(c, with: .color(info.fits ? theme.success : theme.danger), style: StrokeStyle(lineWidth: 1.4))
                label(&ctx, String(format: "%.2f mm", info.clearance ?? 0), tl, info.fits ? theme.success : theme.danger)
            }

            // Leader from the card to the mount point (the board's centre, where it is seated).
            if let card, info.linked {
                let anchor = CGPoint(x: (b0.x + b1.x) / 2, y: (b0.y + b1.y) / 2)
                let from = CGPoint(x: card.minX + 24, y: card.maxY)
                var leader = Path()
                leader.move(to: from)
                leader.addLine(to: CGPoint(x: from.x, y: from.y + 18))
                leader.addLine(to: anchor)
                ctx.stroke(leader, with: .color(accent.opacity(0.9)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: anchor.x - 4, y: anchor.y - 4, width: 8, height: 8)), with: .color(accent))
                ctx.stroke(Path(ellipseIn: CGRect(x: anchor.x - 7, y: anchor.y - 7, width: 14, height: 14)), with: .color(accent.opacity(0.5)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func label(_ ctx: inout GraphicsContext, _ s: String, _ p: CGPoint, _ color: Color) {
        let text = ctx.resolve(Text(s).font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(color))
        let sz = text.measure(in: CGSize(width: 300, height: 30))
        let r = CGRect(x: p.x - sz.width / 2 - 5, y: p.y - sz.height / 2 - 2, width: sz.width + 10, height: sz.height + 4)
        ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(theme.isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.85)))
        ctx.draw(text, at: p)
    }
}

/// The rule checks in one capsule: "DRC passed · 2 layers · 36 x 36 mm · 12 nets", or the count
/// of findings. Clicking runs the checks again.
struct DRCCapsule: View {
    @Environment(\.viaFormTheme) private var theme
    let pcb: PCBModel
    let run: () -> Void

    var body: some View {
        let n = pcb.findings.count
        let unrouted = pcb.checks?.airwires.count ?? 0
        let ok = n == 0
        Button(action: run) {
            HStack(spacing: VFSpace.s) {
                Image(systemName: ok ? "checkmark" : "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ok ? theme.success : theme.warning)
                Text(ok ? "DRC passed" : "\(n) finding\(n == 1 ? "" : "s")").fontWeight(.semibold)
                ForEach(facts(unrouted: unrouted), id: \.self) { f in
                    Text("·").foregroundStyle(theme.inkTertiary)
                    Text(f)
                }
            }
            .font(VFFont.small)
            .monospacedDigit()
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.l)
            .frame(height: 28)
            .vfSurface(.floating, radius: 14)
        }
        .buttonStyle(.plain)
        .help("Run the electrical and design rule checks")
    }

    private func facts(unrouted: Int) -> [String] {
        guard let p = pcb.project else { return [] }
        let layers = max(2, Set(p.board.tracks.map(\.layer)).count)
        var out = ["\(layers) layers", String(format: "%.0f x %.0f mm", p.board.width, p.board.height), "\(p.nets.count) nets"]
        if unrouted > 0 { out.append("\(unrouted) unrouted") }
        return out
    }
}

/// The board's layers as toggles: copper by layer, silkscreen, edge cuts, airwires.
struct PCBLayerBar: View {
    @Environment(\.viaFormTheme) private var theme
    @Binding var hidden: Set<String>
    let active: String
    let pick: (String) -> Void

    static let layers: [(String, Color)] = [("F.Cu", PCBDense.front), ("B.Cu", PCBDense.back), ("Silk", PCBDense.silk),
                                             ("Edge", PCBDense.edge), ("Airwires", Color(white: 0.6))]

    var body: some View {
        HStack(spacing: VFSpace.s) {
            VFCaption("Layers")
            ForEach(Self.layers, id: \.0) { name, color in
                let on = !hidden.contains(name)
                Button {
                    if on { hidden.insert(name) } else { hidden.remove(name) }
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(on ? color : color.opacity(0.22)).frame(width: 11, height: 11)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.15)))
                        Text(name).font(VFFont.small).foregroundStyle(on ? theme.ink : theme.inkTertiary)
                        if name == active { Circle().fill(theme.accent).frame(width: 4, height: 4) }
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(on ? theme.panel : .clear))
                    .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(theme.hairline))
                }
                .buttonStyle(.plain)
                .help(on ? "Hide \(name)" : "Show \(name)")
                .contextMenu {
                    if name.hasSuffix(".Cu") { Button("Route on \(name)") { pick(name) } }
                }
            }
        }
    }
}

/// The Electronics timeline: the board's steps on a rail of dots, each with a small tinted icon
/// and its legend, done ones on the solid rail, the playhead at the first step still to do.
/// Clicking a step does it (or opens where it is done).
struct DotRailTimeline: View {
    @Environment(\.viaFormTheme) private var theme
    let steps: [Step]
    var trailing: String?

    struct Step: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let tint: Color
        let done: Bool
        var detail: String = ""
        let run: () -> Void
    }

    var body: some View {
        let next = steps.firstIndex { !$0.done } ?? steps.count
        GeometryReader { geo in
            let w = geo.size.width
            let pitch = steps.isEmpty ? 0 : w / CGFloat(steps.count)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    let y: CGFloat = 42
                    let x0 = pitch / 2, x1 = w - pitch / 2
                    let xm = next >= steps.count ? x1 : CGFloat(next) * pitch + pitch / 2
                    var done = Path(); done.move(to: CGPoint(x: x0, y: y)); done.addLine(to: CGPoint(x: xm, y: y))
                    ctx.stroke(done, with: .color(theme.accent.opacity(0.7)), lineWidth: 2)
                    var todo = Path(); todo.move(to: CGPoint(x: xm, y: y)); todo.addLine(to: CGPoint(x: x1, y: y))
                    ctx.stroke(todo, with: .color(theme.hairline), lineWidth: 2)
                    for (i, s) in steps.enumerated() {
                        let x = CGFloat(i) * pitch + pitch / 2
                        let r: CGFloat = s.done ? 3.5 : 3
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(s.done ? theme.accent : theme.inkTertiary))
                    }
                }
                .allowsHitTesting(false)
                HStack(spacing: 0) {
                    ForEach(steps) { s in
                        Button(action: s.run) {
                            VStack(spacing: 2) {
                                HStack(spacing: 5) {
                                    Image(systemName: s.symbol).font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(s.done ? s.tint : theme.inkTertiary)
                                        .frame(width: 20, height: 20)
                                        .background(RoundedRectangle(cornerRadius: 5).fill((s.done ? s.tint : theme.inkTertiary).opacity(0.14)))
                                    Text(s.label).font(VFFont.small).foregroundStyle(s.done ? theme.ink : theme.inkSecondary).lineLimit(1)
                                }
                                Text(s.detail).font(VFFont.micro).foregroundStyle(theme.inkTertiary).lineLimit(1).monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(s.done ? "\(s.label): done" : "\(s.label): to do")
                    }
                }
                // The playhead on the first step still to do.
                if next < steps.count {
                    let x = CGFloat(next) * pitch + pitch / 2
                    VStack(spacing: 0) {
                        Circle().fill(theme.accent).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    }
                    .position(x: x, y: 42)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 52)
    }
}
