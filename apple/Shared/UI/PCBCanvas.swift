import SwiftUI

/// The schematic or board sheet, drawn from the project in millimetres.
/// Tap runs the current tool; drag on the selected part moves it, drag elsewhere pans;
/// pinch zooms.
struct PCBCanvas: View {
    @Bindable var model: PCBModel
    @State private var center = PCBPoint(x: 30, y: 20)
    @State private var scale = 12.0
    @State private var pinchBase: Double?
    @State private var drag: (id: Int?, last: CGPoint)?
    @State private var ghost: PCBPoint?
    @State private var fitted = false
    @Environment(\.colorScheme) private var colorScheme

    private struct Palette {
        let paper, grid, ink, pin, wire, select, board, edge, front, back, pad, air: Color
    }

    private var palette: Palette {
        model.sheet == .schematic && colorScheme == .dark
            ? Palette(paper: Color(red: 0.11, green: 0.12, blue: 0.14), grid: Color.white.opacity(0.06), ink: Color(white: 0.85),
                      pin: Color(red: 0.95, green: 0.42, blue: 0.4), wire: Color(red: 0.3, green: 0.8, blue: 0.55), select: .accentColor,
                      board: .clear, edge: .clear, front: .clear, back: .clear, pad: .clear, air: .clear)
            : model.sheet == .schematic
            ? Palette(paper: Color(red: 0.97, green: 0.97, blue: 0.95), grid: Color.black.opacity(0.07), ink: Color(red: 0.2, green: 0.22, blue: 0.27),
                      pin: Color(red: 0.75, green: 0.2, blue: 0.2), wire: Color(red: 0.1, green: 0.5, blue: 0.35), select: .accentColor,
                      board: .clear, edge: .clear, front: .clear, back: .clear, pad: .clear, air: .clear)
            : Palette(paper: Color(red: 0.07, green: 0.08, blue: 0.1), grid: Color.white.opacity(0.05), ink: Color(white: 0.85),
                      pin: .clear, wire: .clear, select: Color(red: 1, green: 0.85, blue: 0.3),
                      board: Color(red: 0.11, green: 0.2, blue: 0.16), edge: Color(red: 0.95, green: 0.85, blue: 0.4),
                      front: Color(red: 0.85, green: 0.3, blue: 0.25), back: Color(red: 0.3, green: 0.5, blue: 0.9),
                      pad: Color(red: 0.8, green: 0.68, blue: 0.3), air: Color.white.opacity(0.55))
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size) }
                .background(palette.paper)
                .contentShape(Rectangle())
                .gesture(dragGesture(geo.size))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        if pinchBase == nil { pinchBase = scale }
                        scale = min(200, max(1, (pinchBase ?? scale) * v.magnification))
                    }
                    .onEnded { _ in pinchBase = nil })
                .onAppear { if !fitted { fit(geo.size); fitted = true } }
                .onChange(of: model.sheet) { _, _ in fit(geo.size) }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 2) {
                        zoomButton("minus.magnifyingglass") { scale = max(1, scale / 1.3) }
                        zoomButton("plus.magnifyingglass") { scale = min(200, scale * 1.3) }
                        zoomButton("arrow.up.left.and.down.right.magnifyingglass") { fit(geo.size) }
                    }
                    .padding(4)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                }
        }
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 30, height: 28) }.buttonStyle(.plain)
    }

    // MARK: Coordinates

    private func toView(_ p: PCBPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x - center.x) * scale, y: size.height / 2 + (p.y - center.y) * scale)
    }

    private func toSheet(_ v: CGPoint, _ size: CGSize) -> PCBPoint {
        PCBPoint(x: center.x + (v.x - size.width / 2) / scale, y: center.y + (v.y - size.height / 2) / scale)
    }

    private func fit(_ size: CGSize) {
        guard let p = model.project, size.width > 10 else { return }
        var pts: [PCBPoint] = []
        if model.sheet == .board {
            pts = [PCBPoint(x: 0, y: 0), PCBPoint(x: p.board.width, y: p.board.height)]
        } else {
            for c in p.components { pts.append(c.position); pts += c.pins.map(c.pinPosition) }
        }
        guard !pts.isEmpty else { center = PCBPoint(x: 0, y: 0); scale = 12; return }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        center = PCBPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        scale = min(size.width / max(maxX - minX + 12, 10), size.height / max(maxY - minY + 12, 10))
    }

    private func dragGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil {
                    let hit = model.object(at: toSheet(g.startLocation, size))
                    drag = (hit != nil && hit == model.selection && model.tool == .select ? hit : nil, g.startLocation)
                }
                guard let d = drag else { return }
                if let id = d.id {
                    ghost = toSheet(g.location, size)
                    _ = id
                } else if hypot(g.translation.width, g.translation.height) > 3 {
                    center = PCBPoint(x: center.x - (g.location.x - d.last.x) / scale, y: center.y - (g.location.y - d.last.y) / scale)
                }
                drag = (d.id, g.location)
            }
            .onEnded { g in
                defer { drag = nil; ghost = nil }
                let moved = hypot(g.translation.width, g.translation.height) > 3
                if let id = drag?.id, moved {
                    model.move(id, to: toSheet(g.location, size))
                } else if !moved {
                    model.click(at: toSheet(g.location, size), scale: scale)
                }
            }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        guard let p = model.project else { return }
        drawGrid(&ctx, size)
        if model.sheet == .schematic { drawSchematic(&ctx, size, p) } else { drawBoard(&ctx, size, p) }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let step = model.sheet == .schematic ? 2.54 : 1.0
        let every = step * scale < 8 ? step * 5 : step
        let a = toSheet(.zero, size), b = toSheet(CGPoint(x: size.width, y: size.height), size)
        var path = Path()
        var x = (a.x / every).rounded(.down) * every
        while x <= b.x { let v = toView(PCBPoint(x: x, y: 0), size).x; path.move(to: CGPoint(x: v, y: 0)); path.addLine(to: CGPoint(x: v, y: size.height)); x += every }
        var y = (a.y / every).rounded(.down) * every
        while y <= b.y { let v = toView(PCBPoint(x: 0, y: y), size).y; path.move(to: CGPoint(x: 0, y: v)); path.addLine(to: CGPoint(x: size.width, y: v)); y += every }
        ctx.stroke(path, with: .color(palette.grid), lineWidth: 1)
    }

    private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint, size: CGFloat, color: Color, weight: Font.Weight = .regular) {
        ctx.draw(Text(text).font(.system(size: size, weight: weight)).foregroundStyle(color), at: p)
    }

    private func drawSchematic(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: PCBProject) {
        let nets = model.nets
        // Wires as right-angled runs between pins, with the net name at the bend.
        for w in p.wires {
            guard let c1 = model.component(w.from.component), let c2 = model.component(w.to.component),
                  let pin1 = c1.pins.first(where: { $0.number == w.from.pin }), let pin2 = c2.pins.first(where: { $0.number == w.to.pin }) else { continue }
            let a = toView(c1.pinPosition(pin1), size), b = toView(c2.pinPosition(pin2), size)
            var path = Path()
            path.move(to: a)
            path.addLine(to: CGPoint(x: b.x, y: a.y))
            path.addLine(to: b)
            ctx.stroke(path, with: .color(model.selection == w.id ? palette.select : palette.wire), lineWidth: 2)
            if let n = nets[w.net] { label(&ctx, n, at: CGPoint(x: b.x + 4, y: a.y - 9), size: 10, color: palette.wire, weight: .semibold) }
        }
        for c in p.components {
            let selected = model.selection == c.id
            var ink = selected ? palette.select : palette.ink
            let at = ghost != nil && selected ? toView(ghost!, size) : toView(c.position, size)
            let s = scale
            var body = ctx
            body.translateBy(x: at.x, y: at.y)
            body.rotate(by: .degrees(c.rotation))
            symbol(&body, kind: c.kind, s: s, ink: ink)
            // Leads out to the pins.
            for pin in c.pins {
                let end = CGPoint(x: pin.offset.x * s, y: pin.offset.y * s)
                var lead = Path()
                lead.move(to: CGPoint(x: end.x * 0.55, y: end.y * 0.55))
                lead.addLine(to: end)
                body.stroke(lead, with: .color(ink), lineWidth: 1.6)
            }
            for pin in c.pins {
                let pt = toView(c.pinPosition(pin), size)
                let pendingHere = model.pending?.object == c.id && model.pending?.pin == pin.number
                let r: CGFloat = pendingHere ? 5 : 3
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)), with: .color(pendingHere ? palette.select : palette.pin))
            }
            ink = selected ? palette.select : palette.ink
            label(&ctx, c.reference, at: CGPoint(x: at.x, y: at.y - 2.6 * s - 6), size: 11, color: ink, weight: .bold)
            label(&ctx, c.value, at: CGPoint(x: at.x, y: at.y + 2.6 * s + 6), size: 10, color: ink.opacity(0.75))
        }
    }

    /// Original symbol drawings, in a component frame where one unit is one millimetre.
    private func symbol(_ ctx: inout GraphicsContext, kind: String, s: Double, ink: Color) {
        var path = Path()
        switch kind {
        case "resistor":
            path.addRoundedRect(in: CGRect(x: -2.75 * s, y: -1 * s, width: 5.5 * s, height: 2 * s), cornerSize: CGSize(width: 0.3 * s, height: 0.3 * s))
        case "capacitor":
            path.move(to: CGPoint(x: -0.6 * s, y: -2 * s)); path.addLine(to: CGPoint(x: -0.6 * s, y: 2 * s))
            path.move(to: CGPoint(x: 0.6 * s, y: -2 * s)); path.addLine(to: CGPoint(x: 0.6 * s, y: 2 * s))
            path.move(to: CGPoint(x: -2.75 * s, y: 0)); path.addLine(to: CGPoint(x: -0.6 * s, y: 0))
            path.move(to: CGPoint(x: 0.6 * s, y: 0)); path.addLine(to: CGPoint(x: 2.75 * s, y: 0))
        case "led":
            path.move(to: CGPoint(x: -1.5 * s, y: -1.6 * s)); path.addLine(to: CGPoint(x: 1.2 * s, y: 0)); path.addLine(to: CGPoint(x: -1.5 * s, y: 1.6 * s)); path.closeSubpath()
            path.move(to: CGPoint(x: 1.2 * s, y: -1.6 * s)); path.addLine(to: CGPoint(x: 1.2 * s, y: 1.6 * s))
            path.move(to: CGPoint(x: -0.2 * s, y: -2 * s)); path.addLine(to: CGPoint(x: 0.8 * s, y: -3 * s))
            path.move(to: CGPoint(x: 0.7 * s, y: -1.9 * s)); path.addLine(to: CGPoint(x: 1.7 * s, y: -2.9 * s))
        default:
            path.addRoundedRect(in: CGRect(x: -2.75 * s, y: -1.8 * s, width: 5.5 * s, height: 3.6 * s), cornerSize: CGSize(width: 0.5 * s, height: 0.5 * s))
        }
        ctx.stroke(path, with: .color(ink), lineWidth: 1.8)
    }

    private func drawBoard(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: PCBProject) {
        let o = toView(PCBPoint(x: 0, y: 0), size)
        let outline = Path(roundedRect: CGRect(x: o.x, y: o.y, width: p.board.width * scale, height: p.board.height * scale), cornerRadius: 0)
        ctx.fill(outline, with: .color(palette.board))
        ctx.stroke(outline, with: .color(palette.edge), lineWidth: 1.5)
        for cut in p.board.cutouts {
            let c = toView(cut.center, size), r = cut.radius * scale
            let hole = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(hole, with: .color(palette.paper))
            ctx.stroke(hole, with: .color(palette.edge), lineWidth: 1.2)
        }
        // Back copper under front copper.
        for layer in ["B.Cu", "F.Cu"] {
            for t in p.board.tracks where t.layer == layer {
                var path = Path()
                path.move(to: toView(t.start, size))
                path.addLine(to: toView(t.end, size))
                let color = model.selection == t.id ? palette.select : (layer == "F.Cu" ? palette.front : palette.back)
                ctx.stroke(path, with: .color(color.opacity(model.layer == layer ? 1 : 0.55)), style: StrokeStyle(lineWidth: max(1, t.width * scale), lineCap: .round))
            }
        }
        let nets = model.nets
        for f in p.board.footprints {
            let selected = model.selection == f.id
            let shift = ghost != nil && selected ? PCBPoint(x: ghost!.x - f.position.x, y: ghost!.y - f.position.y) : PCBPoint(x: 0, y: 0)
            // Courtyard: a box around the pads.
            let pads = f.pads.map { f.padPosition($0) + shift }
            if let minX = pads.map(\.x).min(), let maxX = pads.map(\.x).max(), let minY = pads.map(\.y).min(), let maxY = pads.map(\.y).max() {
                let a = toView(PCBPoint(x: minX - 1.6, y: minY - 1.6), size), b = toView(PCBPoint(x: maxX + 1.6, y: maxY + 1.6), size)
                ctx.stroke(Path(roundedRect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y), cornerRadius: 3),
                           with: .color(selected ? palette.select : palette.ink.opacity(0.45)), lineWidth: selected ? 2 : 1)
                if let c = model.component(f.component) {
                    label(&ctx, c.reference, at: CGPoint(x: (a.x + b.x) / 2, y: a.y - 8), size: 10, color: palette.ink, weight: .semibold)
                }
            }
            for pad in f.pads {
                let c = toView(f.padPosition(pad) + shift, size), r = pad.diameter / 2 * scale
                let pendingHere = model.pending?.object == f.id && model.pending?.pin == pad.number
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(pendingHere ? palette.select : palette.pad))
                let hole = r * 0.45
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)), with: .color(palette.paper))
                if scale > 9, let n = pad.net.flatMap({ nets[$0] }) {
                    label(&ctx, n, at: CGPoint(x: c.x, y: c.y + r + 7), size: 8, color: palette.ink.opacity(0.7))
                }
            }
        }
        for a in model.checks?.airwires ?? [] {
            var path = Path()
            path.move(to: toView(a.from, size))
            path.addLine(to: toView(a.to, size))
            ctx.stroke(path, with: .color(palette.air), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
}
