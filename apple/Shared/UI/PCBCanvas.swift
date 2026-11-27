import SwiftUI

/// The schematic or board sheet, drawn from the project in millimetres.
/// Tap runs the current tool; drag on the selected part moves it, drag elsewhere pans;
/// pinch zooms.
struct PCBCanvas: View {
    @ObservedUnits private var units
    @Bindable var model: PCBModel
    /// The dense board style (soldermask, gold pads, silkscreen, mounting holes, dotted
    /// airwires) instead of the flat one. The Mac project window uses it.
    var dense = false
    /// Board layers not drawn ("F.Cu", "B.Cu", "Silk", "Edge", "Airwires").
    var hiddenLayers: Set<String> = []
    /// Called with the sheet-to-view mapping whenever it changes, for overlays drawn over the
    /// canvas (the 3D link's leader and clearance).
    var onTransform: ((PCBCanvasTransform) -> Void)?
    /// Room the board fit leaves free on the trailing edge (a card over the canvas), in points.
    var reserveTrailing: CGFloat = 0
    @State private var center = PCBPoint(x: 30, y: 20)
    @State private var scale = 12.0
    @State private var pinchBase: Double?
    @State private var drag: (id: Int?, last: CGPoint)?
    @State private var ghost: PCBPoint?
    @State private var fitted = false
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    /// The drawing colours for this sheet, the theme's light or dark and its increased contrast.
    private var palette: PCBPalette {
        model.sheet == .schematic
            ? .schematic(dark: theme.isDark, contrast: theme.highContrast, select: theme.accentText)
            : .board(contrast: theme.highContrast)
    }

    var body: some View {
        let _ = units
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
                .onAppear { if !fitted { fit(geo.size); fitted = true }; report(geo.size) }
                .onChange(of: fitted) { _, f in if !f { fit(geo.size); fitted = true } }
                .onChange(of: model.sheet) { _, _ in fit(geo.size) }
                .onChange(of: PCBCanvasTransform(center: center, scale: scale, size: geo.size)) { _, t in onTransform?(t) }
                .contextMenu { contextMenu }
                // VoiceOver reads the parts on the sheet, each one selectable.
                .accessibilityElement(children: .contain)
                .accessibilityLabel(model.sheet == .schematic ? Text("Schematic") : Text("Board"))
                .accessibilityChildren { accessibilityParts(geo.size) }
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: VFSpace.xxs) {
                        VFIconButton("minus.magnifyingglass", label: String(localized: "Zoom out"), size: 13) { scale = max(1, scale / 1.3) }
                        VFIconButton("plus.magnifyingglass", label: String(localized: "Zoom in"), size: 13) { scale = min(200, scale * 1.3) }
                        VFIconButton("arrow.up.left.and.down.right.magnifyingglass", label: String(localized: "Fit the sheet"), size: 13) { fit(geo.size) }
                    }
                    .padding(VFSpace.xs)
                    .vfSurface(.control, radius: VFRadius.touchCapsule)
                    .padding(VFSpace.overlayInset)
                }
        }
    }

    /// The selection's commands, also reachable without a drag (P2-18).
    @ViewBuilder private var contextMenu: some View {
        if let id = model.selection, model.component(id) != nil || model.footprint(id) != nil {
            let n = PCBNudge.step
            Button(String(localized: "Rotate \(AsmFormat.deg(90))"), systemImage: "rotate.right") { model.rotateSelection() }
            Menu(String(localized: "Move by \(PCBNudge.label())")) {
                Button("Left", systemImage: "arrow.left") { model.nudgeSelection(dx: -n, dy: 0) }
                Button("Right", systemImage: "arrow.right") { model.nudgeSelection(dx: n, dy: 0) }
                Button("Up", systemImage: "arrow.up") { model.nudgeSelection(dx: 0, dy: -n) }
                Button("Down", systemImage: "arrow.down") { model.nudgeSelection(dx: 0, dy: n) }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSelection() }
        } else {
            Button("Fit the Sheet", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { fitted = false }
        }
    }

    /// One accessibility element per part, at its place on the sheet.
    @ViewBuilder private func accessibilityParts(_ size: CGSize) -> some View {
        if let p = model.project {
            if model.sheet == .schematic {
                ForEach(p.components) { c in
                    partElement(id: c.id, label: "\(c.reference), \(c.value)", at: toView(c.position, size))
                }
            } else {
                ForEach(p.board.footprints) { f in
                    let c = model.component(f.component)
                    partElement(id: f.id, label: c.map { "\($0.reference), \($0.value)" } ?? String(localized: "Footprint"), at: toView(f.position, size))
                }
            }
        }
    }

    private func partElement(id: Int, label: String, at p: CGPoint) -> some View {
        let n = PCBNudge.step, by = PCBNudge.label()
        return Rectangle()
            .frame(width: 24, height: 24)
            .position(p)
            .accessibilityLabel(label)
            .accessibilityAddTraits(model.selection == id ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.selection = id }
            .accessibilityAction(named: Text("Move left \(by)")) { model.selection = id; model.nudgeSelection(dx: -n, dy: 0) }
            .accessibilityAction(named: Text("Move right \(by)")) { model.selection = id; model.nudgeSelection(dx: n, dy: 0) }
            .accessibilityAction(named: Text("Move up \(by)")) { model.selection = id; model.nudgeSelection(dx: 0, dy: -n) }
            .accessibilityAction(named: Text("Move down \(by)")) { model.selection = id; model.nudgeSelection(dx: 0, dy: n) }
            .accessibilityAction(named: Text("Rotate")) { model.selection = id; model.rotateSelection() }
    }

    private func report(_ size: CGSize) { onTransform?(PCBCanvasTransform(center: center, scale: scale, size: size)) }

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
        // The dense board keeps room around it for the keep-in and the dimensions.
        let pad = dense && model.sheet == .board ? max(maxX - minX, maxY - minY) * 0.45 : 12
        let usable = max(size.width - reserveTrailing, size.width * 0.4)
        scale = min(usable / max(maxX - minX + pad, 10), size.height / max(maxY - minY + pad, 10))
        // Centred in the part of the canvas the card leaves free.
        center = PCBPoint(x: (minX + maxX) / 2 + (size.width - usable) / 2 / scale, y: (minY + maxY) / 2)
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
        if model.sheet == .schematic { drawSchematic(&ctx, size, p) } else if dense { drawDenseBoard(&ctx, size, p) } else { drawBoard(&ctx, size, p) }
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

    /// A label on a paper-coloured backing, so it reads over wires, tracks and other labels.
    private func label(_ ctx: inout GraphicsContext, _ text: String, at p: CGPoint, size: CGFloat, color: Color,
                       weight: Font.Weight = .regular, backing: Color? = nil, anchor: UnitPoint = .center) {
        let t = ctx.resolve(Text(text).font(VFFont.glyph(size, weight: weight)).foregroundStyle(color))
        let m = t.measure(in: CGSize(width: 400, height: 100))
        let origin = CGPoint(x: p.x - m.width * anchor.x, y: p.y - m.height * anchor.y)
        let box = CGRect(origin: origin, size: m).insetBy(dx: -2.5, dy: -1)
        ctx.fill(Path(roundedRect: box, cornerRadius: 2.5), with: .color(backing ?? palette.backing))
        ctx.draw(t, at: p, anchor: anchor)
    }

    /// Track stroke: B.Cu is dashed when colour must not carry the layer alone.
    private func trackStyle(_ layer: String, width: CGFloat) -> StrokeStyle {
        if differentiate && layer == "B.Cu" {
            return StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round, dash: [max(3, width * 1.6), max(2, width)])
        }
        return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
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
            if let n = nets[w.net] { label(&ctx, n, at: CGPoint(x: b.x + 6, y: a.y - 11), size: 10, color: palette.wire, weight: .semibold, anchor: .leading) }
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
            label(&ctx, c.reference, at: CGPoint(x: at.x, y: at.y - 2.6 * s - 8), size: 11, color: ink, weight: .bold)
            label(&ctx, c.value, at: CGPoint(x: at.x, y: at.y + 2.6 * s + 8), size: 10, color: ink.opacity(0.8))
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

    /// The dense board: soldermask over the outline, B.Cu under F.Cu with round caps, gold pads
    /// with their drills, plated mounting holes, the parts' silkscreen outlines and references,
    /// the dotted airwires still to route, the board's name in the corner.
    private func drawDenseBoard(_ ctx: inout GraphicsContext, _ size: CGSize, _ p: PCBProject) {
        let o = toView(PCBPoint(x: 0, y: 0), size)
        let rect = CGRect(x: o.x, y: o.y, width: p.board.width * scale, height: p.board.height * scale)
        let corner = min(1.2 * scale, rect.width / 8)
        let outline = Path(roundedRect: rect, cornerRadius: corner)
        let mask = palette
        ctx.fill(outline, with: .linearGradient(Gradient(colors: [mask.maskTop, mask.maskBottom]),
                                                startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        if !hiddenLayers.contains("Edge") {
            ctx.stroke(outline, with: .color(mask.maskEdge), lineWidth: 1.6)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.35 * scale, dy: 0.35 * scale), cornerRadius: max(0, corner - 0.35 * scale)),
                       with: .color(mask.silk.opacity(0.06)), lineWidth: 1)
        }
        for cut in p.board.cutouts {
            let c = toView(cut.center, size), r = cut.radius * scale
            let ring = r + max(0.6 * scale, 2)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)), with: .color(mask.gold))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(mask.drill))
        }
        let nets = model.nets
        for layer in ["B.Cu", "F.Cu"] where !hiddenLayers.contains(layer) {
            for t in p.board.tracks where t.layer == layer {
                var path = Path()
                path.move(to: toView(t.start, size))
                path.addLine(to: toView(t.end, size))
                let base = layer == "F.Cu" ? mask.front : mask.back
                let color = model.selection == t.id ? palette.select : base.opacity(model.layer == layer ? 1 : 0.7)
                ctx.stroke(path, with: .color(color), style: trackStyle(layer, width: max(1.2, t.width * scale)))
            }
        }
        for f in p.board.footprints {
            let selected = model.selection == f.id
            let shift = ghost != nil && selected ? PCBPoint(x: ghost!.x - f.position.x, y: ghost!.y - f.position.y) : PCBPoint(x: 0, y: 0)
            let pads = f.pads.map { f.padPosition($0) + shift }
            if !hiddenLayers.contains("Silk"),
               let minX = pads.map(\.x).min(), let maxX = pads.map(\.x).max(), let minY = pads.map(\.y).min(), let maxY = pads.map(\.y).max() {
                let a = toView(PCBPoint(x: minX - 1.2, y: minY - 1.2), size), b = toView(PCBPoint(x: maxX + 1.2, y: maxY + 1.2), size)
                let box = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                // Package body between the pads, then the silkscreen outline and pin-1 dot.
                ctx.fill(Path(roundedRect: box.insetBy(dx: box.width * 0.18, dy: box.height * 0.18), cornerRadius: 2), with: .color(mask.package))
                ctx.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(selected ? palette.select : mask.silk.opacity(0.85)), lineWidth: selected ? 2 : 1)
                if let first = pads.first {
                    let d = toView(first, size)
                    ctx.fill(Path(ellipseIn: CGRect(x: box.minX + 2, y: d.y - 2, width: 4, height: 4)), with: .color(mask.silk))
                }
                if let c = model.component(f.component) {
                    label(&ctx, c.reference, at: CGPoint(x: box.midX, y: box.minY - 9), size: max(8, min(13, scale * 1.1)),
                          color: mask.silk, weight: .bold, backing: mask.maskBottom.opacity(0.85))
                }
            }
            for pad in f.pads {
                let c = toView(f.padPosition(pad) + shift, size), r = pad.diameter / 2 * scale
                let pendingHere = model.pending?.object == f.id && model.pending?.pin == pad.number
                ctx.fill(Path(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), cornerRadius: r * 0.45),
                         with: .color(pendingHere ? palette.select : mask.gold))
                let hole = r * 0.42
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)), with: .color(mask.drill))
                if scale > 14, let n = pad.net.flatMap({ nets[$0] }) {
                    label(&ctx, n, at: CGPoint(x: c.x, y: c.y + r + 8), size: 7.5, color: mask.silk.opacity(0.85),
                          weight: .medium, backing: mask.maskBottom.opacity(0.85))
                }
            }
        }
        if !hiddenLayers.contains("Airwires") {
            for a in model.checks?.airwires ?? [] {
                var path = Path()
                path.move(to: toView(a.from, size))
                path.addLine(to: toView(a.to, size))
                ctx.stroke(path, with: .color(mask.denseAir), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        if !hiddenLayers.contains("Silk"), rect.width > 120 {
            let name = (p.name ?? "Board").uppercased()
            ctx.draw(Text(name).font(VFFont.glyph(max(8, min(12, scale * 0.9)), weight: .heavy)).foregroundStyle(mask.silk.opacity(0.9)),
                     at: CGPoint(x: rect.minX + 8, y: rect.maxY - 8), anchor: .bottomLeading)
        }
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
                ctx.stroke(path, with: .color(color.opacity(model.layer == layer ? 1 : 0.55)), style: trackStyle(layer, width: max(1, t.width * scale)))
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
                    label(&ctx, c.reference, at: CGPoint(x: (a.x + b.x) / 2, y: a.y - 9), size: 10, color: palette.ink, weight: .semibold, backing: palette.board)
                }
            }
            for pad in f.pads {
                let c = toView(f.padPosition(pad) + shift, size), r = pad.diameter / 2 * scale
                let pendingHere = model.pending?.object == f.id && model.pending?.pin == pad.number
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(pendingHere ? palette.select : palette.pad))
                let hole = r * 0.45
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)), with: .color(palette.paper))
                if scale > 9, let n = pad.net.flatMap({ nets[$0] }) {
                    label(&ctx, n, at: CGPoint(x: c.x, y: c.y + r + 8), size: 8, color: palette.ink.opacity(0.8), backing: palette.board)
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

/// The canvas's sheet-to-view mapping, for overlays: a sheet point (millimetres) to a view point.
/// One nudge of a PCB part (arrow keys, the context menu, VoiceOver). The board data stays in
/// millimetres; with inches the step is the 0.05 in (50 mil) grid of inch boards, else 1 mm.
/// Shift moves ten steps.
enum PCBNudge {
    static var step: Double { UnitSettings.current.length == .inch ? 1.27 : 1 }
    /// "1 mm", "0.050 in" (ten steps with `times: 10`).
    static func label(times: Double = 1) -> String { VFFormat.lengths([step * times]) }
}

struct PCBCanvasTransform: Equatable {
    var center: PCBPoint
    var scale: Double
    var size: CGSize

    func view(_ p: PCBPoint) -> CGPoint {
        CGPoint(x: size.width / 2 + (p.x - center.x) * scale, y: size.height / 2 + (p.y - center.y) * scale)
    }
}

/// The sheet's drawing colours (the canvas content, not the UI chrome): paper and ink of the
/// schematic in light and dark, the board's soldermask, copper by layer, gold, silk and drills,
/// each with an increased-contrast variant. The canvas picks one from the theme.
struct PCBPalette {
    var paper, grid, ink, pin, wire, select: Color
    /// Behind labels, so they read over wires and tracks.
    var backing: Color
    // Flat board
    var board, edge, front, back, pad, air: Color
    // Dense board
    var maskTop, maskBottom, maskEdge, gold, drill, silk, package, denseAir: Color
    var inner1, inner2: Color

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b) }

    /// Board colours shared by both board styles.
    private static func boardBase(contrast: Bool) -> PCBPalette {
        PCBPalette(
            paper: rgb(0.07, 0.08, 0.10), grid: Color(.sRGB, white: 1, opacity: contrast ? 0.10 : 0.05),
            ink: Color(.sRGB, white: contrast ? 0.97 : 0.85), pin: .clear, wire: .clear,
            select: rgb(1, 0.85, 0.3), backing: rgb(0.07, 0.08, 0.10).opacity(0.85),
            board: rgb(0.11, 0.20, 0.16), edge: rgb(0.95, 0.85, 0.4),
            front: contrast ? rgb(1.0, 0.30, 0.26) : rgb(0.86, 0.22, 0.20),
            back: contrast ? rgb(0.42, 0.62, 1.0) : rgb(0.24, 0.45, 0.95),
            pad: rgb(0.8, 0.68, 0.3), air: Color(.sRGB, white: 1, opacity: contrast ? 0.85 : 0.55),
            maskTop: rgb(0.08, 0.42, 0.22), maskBottom: rgb(0.05, 0.29, 0.15), maskEdge: rgb(0.93, 0.86, 0.55),
            gold: rgb(0.85, 0.70, 0.36), drill: rgb(0.05, 0.05, 0.06), silk: Color(.sRGB, white: contrast ? 1 : 0.95),
            package: rgb(0.11, 0.12, 0.13).opacity(0.85), denseAir: Color(.sRGB, white: 1, opacity: contrast ? 0.9 : 0.7),
            inner1: rgb(0.95, 0.62, 0.22), inner2: rgb(0.62, 0.36, 0.92))
    }

    static func board(contrast: Bool) -> PCBPalette { boardBase(contrast: contrast) }

    static func schematic(dark: Bool, contrast: Bool, select: Color) -> PCBPalette {
        var p = boardBase(contrast: contrast)
        if dark {
            p.paper = rgb(0.11, 0.12, 0.14)
            p.grid = Color(.sRGB, white: 1, opacity: contrast ? 0.12 : 0.06)
            p.ink = Color(.sRGB, white: contrast ? 0.98 : 0.85)
            p.pin = contrast ? rgb(1.0, 0.55, 0.52) : rgb(0.95, 0.42, 0.40)
            p.wire = contrast ? rgb(0.45, 0.92, 0.66) : rgb(0.30, 0.80, 0.55)
        } else {
            p.paper = rgb(0.97, 0.97, 0.95)
            p.grid = Color(.sRGB, white: 0, opacity: contrast ? 0.14 : 0.07)
            p.ink = contrast ? rgb(0.05, 0.06, 0.08) : rgb(0.20, 0.22, 0.27)
            p.pin = contrast ? rgb(0.60, 0.10, 0.10) : rgb(0.75, 0.20, 0.20)
            p.wire = contrast ? rgb(0.02, 0.38, 0.24) : rgb(0.10, 0.50, 0.35)
        }
        p.backing = p.paper.opacity(0.9)
        p.select = select
        return p
    }
}

/// The dense board's standard colours, for the layer bar and the stage rail.
enum PCBDense {
    private static let p = PCBPalette.board(contrast: false)
    static var maskTop: Color { p.maskTop }
    static var maskBottom: Color { p.maskBottom }
    static var edge: Color { p.maskEdge }
    static var front: Color { p.front }
    static var back: Color { p.back }
    static var gold: Color { p.gold }
    static var drill: Color { p.drill }
    static var silk: Color { p.silk }
    static var package: Color { p.package }
    static var air: Color { p.denseAir }
    static var inner1: Color { p.inner1 }
    static var inner2: Color { p.inner2 }
}
