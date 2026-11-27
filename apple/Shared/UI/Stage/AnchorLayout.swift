import SwiftUI
import simd

/// Where the selection is on screen, and where floating pieces go around it.
///
/// The anchor is a world point of the selection: the picked point of the last face or edge, or
/// the top centre of the selected bodies' bounds. It is projected through the orbit camera of
/// the viewport (`OrbitCamera.project`), the same camera the Metal view draws with, so the
/// pieces follow an orbit, a pan or a zoom. Shared by the Mac and the iPad windows.
enum AnchorLayout {
    /// The selection on screen.
    struct Anchor {
        /// The world point the pieces hang from.
        var point: SIMD3<Double>
        /// The picked face's normal, when a face was picked.
        var normal: SIMD3<Double>?
        /// The anchor on screen.
        var screen: CGPoint
        /// The selection's projected bounds (a small square around a face or edge pick).
        var rect: CGRect
        /// What is selected, in words ("Index Middle", "Face of Palm").
        var title: String
    }

    /// The selection's anchor in a view of `size`, or nil when nothing is selected.
    @MainActor
    static func anchor(_ model: DesignModel, size: CGSize) -> Anchor? {
        let scene = model.scene
        // Extrude hangs from the centre of the profiles it takes, on the sketch plane.
        if model.tool == .extrude, let axis = model.handleAxis {
            let p = model.camera.project(axis.point, size: size)
            let n = model.extrudedProfiles.count
            return Anchor(point: axis.point, normal: axis.normal, screen: p,
                          rect: CGRect(x: p.x - 36, y: p.y - 36, width: 72, height: 72), title: n == 1 ? String(localized: "Profile") : String(localized: "\(n) profiles"))
        }
        if let pick = model.selection.last {
            let p = model.camera.project(pick.point, size: size)
            var normal: SIMD3<Double>?
            var body = ""
            switch pick {
            case let .face(mesh, _, _, n):
                normal = n
                body = mesh < scene.meshes.count ? scene.meshes[mesh].body : ""
            case let .edge(mesh, _, _):
                body = mesh < scene.meshes.count ? scene.meshes[mesh].body : ""
            }
            let n = model.selection.count
            let title: String
            if n > 1 {
                title = WorkspaceMenu.inflected("^[\(n) pick](inflect: true)")
            } else if pick.isFace {
                title = body.isEmpty ? String(localized: "Face") : String(localized: "Face of \(body)")
            } else {
                title = body.isEmpty ? String(localized: "Edge") : String(localized: "Edge of \(body)")
            }
            return Anchor(point: pick.point, normal: normal, screen: p,
                          rect: CGRect(x: p.x - 36, y: p.y - 36, width: 72, height: 72), title: title)
        }
        guard !model.selectedBodies.isEmpty, let box = bounds(of: model.selectedBodies, in: scene) else { return nil }
        let rect = screenRect(box, camera: model.camera, size: size)
        let top = SIMD3((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2, box.max.z)
        let names = model.selectedBodies.sorted()
        let title = names.count == 1 ? names[0] : WorkspaceMenu.inflected("^[\(names.count) body](inflect: true)")
        return Anchor(point: top, normal: nil, screen: model.camera.project(top, size: size), rect: rect, title: title)
    }

    /// The world bounds of the meshes of `bodies`.
    static func bounds(of bodies: Set<String>, in scene: SceneData) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        var any = false
        for m in scene.meshes where bodies.contains(m.body) {
            for p in m.positions {
                let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
                lo = simd_min(lo, d); hi = simd_max(hi, d); any = true
            }
        }
        return any ? (lo, hi) : nil
    }

    /// A world box's projected bounds.
    static func screenRect(_ box: (min: SIMD3<Double>, max: SIMD3<Double>), camera: OrbitCamera, size: CGSize) -> CGRect {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for i in 0..<8 {
            let c = SIMD3(i & 1 == 0 ? box.min.x : box.max.x, i & 2 == 0 ? box.min.y : box.max.y, i & 4 == 0 ? box.min.z : box.max.z)
            let p = camera.project(c, size: size)
            xs.append(p.x); ys.append(p.y)
        }
        let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
        return CGRect(x: x0, y: y0, width: (xs.max() ?? 0) - x0, height: (ys.max() ?? 0) - y0)
    }

    /// Which side of the selection to try first.
    enum Side { case above, below }

    /// The centre of a piece of `size` next to `sel`: on the preferred side first, then the
    /// other sides; inside `bounds` less `margin`, clear of `avoid` when a place allows it, and
    /// never over the selection itself when any place inside the view keeps it uncovered.
    static func place(_ size: CGSize, near sel: CGRect, in bounds: CGSize, avoid: [CGRect] = [], prefer: Side = .above,
                      gap: CGFloat = 16, margin: CGFloat = 12) -> CGPoint {
        let above = CGPoint(x: sel.midX - size.width / 2, y: sel.minY - size.height - gap)
        let below = CGPoint(x: sel.midX - size.width / 2, y: sel.maxY + gap)
        let sides = [
            CGPoint(x: sel.maxX + gap, y: sel.midY - size.height / 2),
            CGPoint(x: sel.minX - size.width - gap, y: sel.midY - size.height / 2),
            CGPoint(x: sel.maxX + gap, y: sel.minY - size.height - gap),
            CGPoint(x: sel.minX - size.width - gap, y: sel.minY - size.height - gap),
        ]
        let candidates = (prefer == .above ? [above, below] : [below, above]) + sides
        let area = CGRect(x: margin, y: margin, width: max(0, bounds.width - 2 * margin), height: max(0, bounds.height - 2 * margin))
        func clamp(_ o: CGPoint) -> CGPoint {
            CGPoint(x: min(max(o.x, area.minX), max(area.minX, area.maxX - size.width)),
                    y: min(max(o.y, area.minY), max(area.minY, area.maxY - size.height)))
        }
        // The selection keeps a little air around it.
        let selection = sel.insetBy(dx: -4, dy: -4)
        let clear = candidates.first { o in
            let r = CGRect(origin: o, size: size)
            return area.contains(r) && !avoid.contains { $0.intersects(r) }
        }
        // No free place: slide a candidate into the view, keeping the selection uncovered first,
        // then the other chrome when possible.
        let slid = candidates.map(clamp)
        let pick = clear
            ?? slid.first { o in
                let r = CGRect(origin: o, size: size)
                return !r.intersects(selection) && !avoid.contains { $0.intersects(r) }
            }
            ?? slid.first { !CGRect(origin: $0, size: size).intersects(selection) }
            ?? slid[0]
        let o = clamp(pick)
        return CGPoint(x: o.x + size.width / 2, y: o.y + size.height / 2)
    }

    /// A unit direction on screen for a world direction leaving `point`, or nil when it points
    /// at the viewer.
    static func screenDirection(_ dir: SIMD3<Double>, at point: SIMD3<Double>, camera: OrbitCamera, size: CGSize, scale: Double) -> CGVector? {
        let a = camera.project(point, size: size)
        let b = camera.project(point + simd_normalize(dir) * scale, size: size)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 4 else { return nil }
        return CGVector(dx: dx / len, dy: dy / len)
    }
}

/// A small flat-shaded picture of the 3D scene, drawn on the CPU from the scene's meshes (no
/// second Metal view): the link card's live view of the board in its frame. `highlight` bodies
/// are tinted with the accent and drawn with an outline.
struct SceneThumbnail: View {
    @Environment(\.viaFormTheme) private var theme
    let scene: SceneData
    var highlight: Set<String> = []
    /// Bodies to frame; the whole scene when empty.
    var focus: Set<String> = []
    var yaw = -0.75
    var pitch = 0.62

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .accessibilityLabel("3D view of the board in the design")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let meshes = scene.meshes
        guard !meshes.isEmpty else { return }
        // Orthographic view: yaw about z, then pitch.
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        func view(_ p: SIMD3<Float>) -> SIMD3<Double> {
            let x = Double(p.x), y = Double(p.y), z = Double(p.z)
            let rx = cy * x - sy * y, ry = sy * x + cy * y
            return SIMD3(rx, cp * z - sp * ry, sp * z + cp * ry)   // screen x, screen up, depth
        }
        // Frame the focus bodies (with the scene around them) or everything.
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        let framed = focus.isEmpty ? meshes : meshes.filter { focus.contains($0.body) }
        for m in framed.isEmpty ? meshes : framed {
            for p in m.positions { let v = view(p); lo = simd_min(lo, SIMD2(v.x, v.y)); hi = simd_max(hi, SIMD2(v.x, v.y)) }
        }
        if !focus.isEmpty {
            // Context around the focus: three times its size.
            let c = (lo + hi) / 2, e = (hi - lo) * 1.6
            lo = c - e; hi = c + e
        }
        let span = max(hi.x - lo.x, hi.y - lo.y, 1e-6)
        let k = min(size.width, size.height) * 0.9 / span
        let mid = (lo + hi) / 2
        func screen(_ v: SIMD3<Double>) -> CGPoint {
            CGPoint(x: size.width / 2 + (v.x - mid.x) * k, y: size.height / 2 - (v.y - mid.y) * k)
        }
        let light = simd_normalize(SIMD3<Double>(0.35, 0.6, 0.72))
        struct Tri { var a, b, c: CGPoint; var depth: Double; var shade: Double; var hot: Bool; var color: SIMD4<Float> }
        var tris: [Tri] = []
        tris.reserveCapacity(meshes.reduce(0) { $0 + $1.indices.count / 3 })
        for m in meshes {
            let hot = highlight.contains(m.body)
            let vs = m.positions.map(view)
            var i = 0
            while i + 2 < m.indices.count {
                let a = vs[Int(m.indices[i])], b = vs[Int(m.indices[i + 1])], c = vs[Int(m.indices[i + 2])]
                i += 3
                let n = simd_cross(b - a, c - a)
                let len = simd_length(n)
                guard len > 1e-12 else { continue }
                let nn = n / len
                guard nn.z > 0 else { continue }   // back faces
                tris.append(Tri(a: screen(a), b: screen(b), c: screen(c), depth: (a.z + b.z + c.z) / 3,
                                shade: 0.45 + 0.55 * max(0, simd_dot(nn, light)), hot: hot, color: m.color))
            }
        }
        tris.sort { $0.depth < $1.depth }
        let accent = theme.accent
        for t in tris {
            var p = Path()
            p.move(to: t.a); p.addLine(to: t.b); p.addLine(to: t.c); p.closeSubpath()
            let base = t.hot ? accent : Color(SIMD4(t.color.x, t.color.y, t.color.z, 1))
            ctx.fill(p, with: .color(base))
            ctx.fill(p, with: .color(Color.black.opacity(1 - t.shade)))
            ctx.stroke(p, with: .color(base.opacity(0.5)), lineWidth: 0.4)
        }
    }
}
