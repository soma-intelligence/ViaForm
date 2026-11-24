#if os(macOS)
import SwiftUI
import simd

/// One verb of the context pill.
struct PillAction: Identifiable {
    let id: String
    let title: String
    var symbol = "circle"
    var tool: Tool?
    var on = false
    let run: () -> Void
}

/// The selection's verbs, floating next to it: the tools it invites (jet icon over caption),
/// then the cross-stage verbs, under a small CONTEXT caption. A control, so Liquid Glass
/// (`vfSurface(.control)`), placed by `AnchorLayout` beside the selection, never over it.
struct StageContextPill: View {
    @Environment(\.viaFormTheme) private var theme
    let title: String
    let actions: [PillAction]
    var dismiss: (() -> Void)?

    /// The pill's size for `AnchorLayout.place` (it is laid out with `fixedSize`).
    static func size(count: Int) -> CGSize {
        CGSize(width: CGFloat(count) * (actionWidth + VFSpace.xxs) + 2 * VFSpace.s, height: 92)
    }
    private static let actionWidth: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.s) {
                VFCaption("Context", color: theme.inkTertiary)
                Text(title).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                Spacer(minLength: 0)
                if let dismiss {
                    VFIconButton("xmark", label: String(localized: "Clear Selection (Esc)"), size: 10, action: dismiss)
                }
            }
            .padding(.leading, VFSpace.xs)
            HStack(spacing: VFSpace.xxs) {
                ForEach(actions) { a in
                    Button(action: a.run) {
                        VStack(spacing: VFSpace.xxs) {
                            Group {
                                if let t = a.tool { ToolChipIcon(tool: t, size: 18) } else {
                                    Image(systemName: a.symbol).font(VFFont.glyph(15, weight: .medium)).foregroundStyle(theme.ink)
                                }
                            }
                            .frame(height: 24)
                            .accessibilityHidden(true)
                            Text(a.title).font(VFFont.micro).lineLimit(1).fixedSize()
                                .foregroundStyle(a.on ? theme.accentText : theme.ink)
                        }
                        .padding(.horizontal, VFSpace.s)
                        .frame(minWidth: Self.actionWidth, minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                            .fill(a.on ? theme.accent.opacity(0.14) : .clear))
                        .overlay(alignment: .bottom) {
                            if a.on { Capsule().fill(theme.accent).frame(width: 18, height: 2).offset(y: -1) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(a.title)
                    .accessibilityLabel(a.title)
                    .accessibilityAddTraits(a.on ? .isSelected : [])
                }
            }
        }
        .padding(VFSpace.s)
        .vfSurface(.control, radius: VFRadius.floating)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Actions for \(title)"))
    }
}

/// The value of the armed tool, in an accent badge at the gizmo's tip.
struct ValueBadge: View {
    @Environment(\.viaFormTheme) private var theme
    let text: String

    var body: some View {
        Text(text).font(VFFont.rowEmphasis)
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, VFSpace.m).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(theme.accent))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
    }
}

/// The armed tool's handle drawn from the anchor: a dimension arrow along the picked face's
/// normal for a distance (Push / Pull, extrude, shell), a swept arc for an angle (revolve), with
/// end ticks and the anchor dot.
struct GizmoArc: View {
    @Environment(\.viaFormTheme) private var theme
    enum Kind {
        /// From the anchor to the tip, on screen.
        case linear(CGPoint, CGPoint)
        /// Around a centre, radius, from a start angle, sweeping (radians, screen space).
        case arc(center: CGPoint, radius: CGFloat, start: Double, sweep: Double)
    }
    let kind: Kind

    var body: some View {
        Canvas { ctx, _ in
            let color = theme.accent
            switch kind {
            case let .linear(a, b):
                var line = Path()
                line.move(to: a); line.addLine(to: b)
                ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 1)
                let ux = dx / len, uy = dy / len
                // Arrow head at the tip, ticks across both ends.
                var head = Path()
                head.move(to: b)
                head.addLine(to: CGPoint(x: b.x - ux * 9 - uy * 4.5, y: b.y - uy * 9 + ux * 4.5))
                head.addLine(to: CGPoint(x: b.x - ux * 9 + uy * 4.5, y: b.y - uy * 9 - ux * 4.5))
                head.closeSubpath()
                ctx.fill(head, with: .color(color))
                var ticks = Path()
                for p in [a, b] {
                    ticks.move(to: CGPoint(x: p.x - uy * 7, y: p.y + ux * 7))
                    ticks.addLine(to: CGPoint(x: p.x + uy * 7, y: p.y - ux * 7))
                }
                ctx.stroke(ticks, with: .color(color), lineWidth: 1.2)
                dot(&ctx, a, color)
            case let .arc(c, r, start, sweep):
                var ring = Path()
                ring.addArc(center: c, radius: r, startAngle: .radians(0), endAngle: .radians(2 * .pi), clockwise: false)
                ctx.stroke(ring, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                var swept = Path()
                swept.addArc(center: c, radius: r, startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: sweep < 0)
                ctx.stroke(swept, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                var wedge = Path()
                wedge.move(to: c)
                wedge.addArc(center: c, radius: r, startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: sweep < 0)
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(color.opacity(0.10)))
                let tip = CGPoint(x: c.x + cos(start + sweep) * r, y: c.y + sin(start + sweep) * r)
                ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10)), with: .color(color))
                dot(&ctx, c, color)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dot(_ ctx: inout GraphicsContext, _ p: CGPoint, _ color: Color) {
        let r: CGFloat = 5
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(theme.onAccent))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r + 1.6, y: p.y - r + 1.6, width: (r - 1.6) * 2, height: (r - 1.6) * 2)), with: .color(color))
    }
}

/// The layer over the 3D viewport that follows the selection: the context pill beside it while
/// nothing is armed, and the armed tool's gizmo with its value badge. Everything is placed by
/// `AnchorLayout` from the selection's world anchor and the orbit camera, and keeps clear of the
/// view cube, the command dialog and the navigation pill (`avoid`).
struct DesignAnchorOverlay: View {
    @ObservedUnits private var units
    let model: DesignModel
    let workspace: Workspace
    let actions: StageActions
    let pcb: PCBModel
    var avoid: [CGRect] = []

    var body: some View {
        let _ = units
        GeometryReader { geo in
            let size = geo.size
            // Read the revision and the camera so the overlay follows edits and orbits.
            let _ = (model.scene.revision, model.camera.yaw, model.camera.pitch, model.camera.distance, model.camera.target)
            let avoid = self.avoid + Self.chrome(size, dialog: model.tool != .select || model.genericCommand != nil)
            if let a = AnchorLayout.anchor(model, size: size) {
                ZStack(alignment: .topLeading) {
                    Color.clear.allowsHitTesting(false)
                    if let v = model.tool.value, model.tool != .select, !model.tool.isSketchTool {
                        gizmo(a, value: v, size: size)
                    } else if model.tool == .select, model.facePick == nil {
                        // The picked face's Push / Pull handle, kept clear of the pill.
                        let handle = model.showsFaceHandle ? model.handleAxis : nil
                        let keepClear = avoid + (handle.map { [handleRect($0, a, size: size)] } ?? [])
                        if let axis = handle {
                            DesignDistanceHandle(model: model, point: axis.point, normal: axis.normal, size: size)
                        }
                        let list = pillActions(a)
                        if !list.isEmpty {
                            StageContextPill(title: a.title, actions: list, dismiss: clear)
                                .position(AnchorLayout.place(StageContextPill.size(count: list.count), near: a.rect, in: size, avoid: keepClear, prefer: .above))
                        }
                    }
                }
            }
        }
    }

    /// The screen box of a face handle, from its anchor to its grip.
    private func handleRect(_ axis: (point: SIMD3<Double>, normal: SIMD3<Double>), _ a: AnchorLayout.Anchor, size: CGSize) -> CGRect {
        let tip = DesignDistanceHandle.tip(model: model, point: axis.point, normal: axis.normal, size: size)
        return CGRect(x: min(tip.x, a.screen.x) - 18, y: min(tip.y, a.screen.y) - 18,
                      width: abs(tip.x - a.screen.x) + 36, height: abs(tip.y - a.screen.y) + 36)
    }

    /// The viewport's own pieces: the view cube (and the command dialog under it), the triad
    /// and the navigation pill.
    static func chrome(_ size: CGSize, dialog: Bool) -> [CGRect] {
        let inset = VFSpace.overlayInset
        return [
            CGRect(x: size.width - 130 - inset, y: 0, width: 130 + inset, height: 130),
            dialog ? CGRect(x: size.width - 320 - inset, y: 110, width: 320 + inset, height: 420) : .null,
            CGRect(x: 0, y: size.height - 96, width: 110, height: 96),
            CGRect(x: size.width / 2 - 170, y: size.height - 64, width: 340, height: 64),
        ].filter { !$0.isNull }
    }

    // MARK: Gizmo

    @ViewBuilder private func gizmo(_ a: AnchorLayout.Anchor, value v: (label: String, unit: String, initial: Double), size: CGSize) -> some View {
        let text = Self.format(model.toolValue, v.unit)
        if v.unit == "deg" {
            let r: CGFloat = 46
            let sweep = -min(max(model.toolValue, -360), 360) * .pi / 180
            let tip = CGPoint(x: a.screen.x + cos(-.pi / 2 + sweep) * r, y: a.screen.y + sin(-.pi / 2 + sweep) * r)
            GizmoArc(kind: .arc(center: a.screen, radius: r, start: -.pi / 2, sweep: sweep))
            ValueBadge(text: text).position(x: tip.x + 34, y: tip.y - 14)
        } else if let axis = model.handleAxis {
            // A draggable handle along the face or profile normal.
            let tip = DesignDistanceHandle.tip(model: model, point: axis.point, normal: axis.normal, size: size)
            let base = model.camera.project(axis.point, size: size)
            DesignDistanceHandle(model: model, point: axis.point, normal: axis.normal, size: size)
            let dx = tip.x - base.x, dy = tip.y - base.y, len = max(hypot(dx, dy), 1)
            ValueBadge(text: text).position(x: (base.x + tip.x) / 2 - dy / len * 46, y: (base.y + tip.y) / 2 + dx / len * 24)
                .allowsHitTesting(false)
        } else {
            let tip = linearTip(a, size: size)
            GizmoArc(kind: .linear(a.screen, tip))
            let dx = tip.x - a.screen.x, dy = tip.y - a.screen.y, len = max(hypot(dx, dy), 1)
            // The badge beside the arrow, off its side, never on the anchor.
            ValueBadge(text: text).position(x: (a.screen.x + tip.x) / 2 - dy / len * 42, y: (a.screen.y + tip.y) / 2 + dx / len * 22)
        }
    }

    /// The arrow's tip: the value along the face normal (or up), projected; at least 48 points
    /// long so a small value stays readable.
    private func linearTip(_ a: AnchorLayout.Anchor, size: CGSize) -> CGPoint {
        let n = a.normal ?? SIMD3(0, 0, 1)
        let world = model.camera.project(a.point + simd_normalize(n) * max(abs(model.toolValue), 0.001) * (model.toolValue < 0 ? -1 : 1), size: size)
        var dx = world.x - a.screen.x, dy = world.y - a.screen.y
        var len = hypot(dx, dy)
        if len < 1 {
            // Looking down the normal: draw it up the screen.
            dx = 0; dy = -1; len = 1
        }
        let shown = min(max(len, 48), 160)
        return CGPoint(x: a.screen.x + dx / len * shown, y: a.screen.y + dy / len * shown)
    }

    static func format(_ v: Double, _ unit: String) -> String {
        VFFormat.value(v, VFUnit(symbol: unit))
    }

    // MARK: Pill

    private func clear() {
        model.selection = []
        model.selectedBodies = []
    }

    private func pillActions(_ a: AnchorLayout.Anchor) -> [PillAction] {
        var out: [PillAction] = model.suggestions.prefix(4).map { t in
            PillAction(id: t.rawValue, title: StageLabels.command(t.label), tool: t, on: model.tool == t) { activate(t) }
        }
        // Cross-stage verbs: what the selection leads to in the other stages.
        let bodies = selectedBodyNames
        if workspace != .assemble, !model.assembly.isEmpty {
            out.append(PillAction(id: "joint", title: String(localized: "Joint"), symbol: "link") { actions.open(.assemble) })
        }
        if model.assembly.contains(where: { $0.linkedPCB && !Set($0.bodies).isDisjoint(with: bodies) }) {
            out.append(PillAction(id: "board", title: String(localized: "Show Board"), symbol: "cpu") { pcb.sheet = .board; actions.open(.electronics) })
        }
        if actions.canRun("simulate.stress") {
            out.append(PillAction(id: "stress", title: String(localized: "Stress Here"), symbol: "waveform.path.ecg") { actions.run("simulate.stress") })
        }
        out.append(PillAction(id: "more", title: String(localized: "More"), symbol: "ellipsis") {
            model.markingMenu = CGPoint(x: a.screen.x, y: a.screen.y)
        })
        return out
    }

    /// The bodies the selection touches (picked faces' bodies included).
    private var selectedBodyNames: Set<String> {
        var s = model.selectedBodies
        for p in model.selection {
            switch p {
            case let .face(m, _, _, _), let .edge(m, _, _):
                if m < model.scene.meshes.count { s.insert(model.scene.meshes[m].body) }
            }
        }
        return s
    }

    private func activate(_ t: Tool) {
        switch t {
        case .union: model.combine("join")
        case .subtract: model.combine("cut")
        case .intersect: model.combine("intersect")
        case .delete: model.deleteSelection()
        case .measure: model.measureSelection()
        case .sketch where model.selection.contains(where: \.isFace): model.sketchOnSelectedFace()
        default: model.tool = model.tool == t ? .select : t
        }
    }
}
#endif
