import SwiftUI
import simd

/// The orientation cube: it turns with the view. A click on a face gives that standard view, a
/// click near an edge or a corner gives the view along that edge or corner, and a drag orbits.
struct ViewCube: View {
    let model: DesignModel
    var size: CGFloat = 96
    var faceColor: Color = Color(white: 0.96)
    var edgeColor: Color = Color(white: 0.55)
    var textColor: Color = Color(white: 0.25)
    var hoverColor: Color = .accentColor

    @State private var hovered: StandardView?
    @State private var dragLast: CGPoint?
    @State private var dragged = false

    private struct Face {
        let view: StandardView
        let normal: SIMD3<Double>
        let label: String
    }

    private static let faces: [Face] = [
        .init(view: .top, normal: [0, 0, 1], label: "TOP"),
        .init(view: .bottom, normal: [0, 0, -1], label: "BOTTOM"),
        .init(view: .front, normal: [0, -1, 0], label: "FRONT"),
        .init(view: .back, normal: [0, 1, 0], label: "BACK"),
        .init(view: .right, normal: [1, 0, 0], label: "RIGHT"),
        .init(view: .left, normal: [-1, 0, 0], label: "LEFT"),
    ]

    private func corners(_ n: SIMD3<Double>) -> [SIMD3<Double>] {
        // The two axes across the face, ordered so the outline runs around it.
        let a: SIMD3<Double> = abs(n.z) > 0.5 ? [1, 0, 0] : [0, 0, 1]
        let b = simd_cross(n, a)
        return [n + a + b, n - a + b, n - a - b, n + a - b].map { $0 * 0.5 }
    }

    private func project(_ p: SIMD3<Double>, _ c: CGPoint, _ s: CGFloat) -> CGPoint {
        let (r, u, _) = model.camera.basis
        return CGPoint(x: c.x + CGFloat(simd_dot(p, r)) * s, y: c.y - CGFloat(simd_dot(p, u)) * s)
    }

    private func visible() -> [(Face, [CGPoint])] {
        let back = model.camera.basis.back
        let c = CGPoint(x: size / 2, y: size / 2), s = size * 0.52
        return Self.faces
            .filter { simd_dot($0.normal, back) > 0.02 }
            .sorted { simd_dot($0.normal, back) < simd_dot($1.normal, back) }
            .map { f in (f, corners(f.normal).map { project($0, c, s) }) }
    }

    private func polygon(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }

    var body: some View {
        let shown = visible()
        Canvas { ctx, _ in
            let back = model.camera.basis.back
            for (f, pts) in shown {
                let path = polygon(pts)
                let shade = 0.82 + 0.18 * simd_dot(f.normal, back)
                ctx.fill(path, with: .color(hovered == f.view ? hoverColor.opacity(0.35) : faceColor.opacity(shade)))
                ctx.stroke(path, with: .color(edgeColor), lineWidth: 1)
                let centre = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4) }
                let facing = simd_dot(f.normal, back)
                if facing > 0.42 {
                    ctx.draw(Text(f.label).font(.system(size: size * 0.082, weight: .semibold)).foregroundStyle(textColor), at: centre)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case let .active(p) = phase { hovered = face(at: p, shown) } else { hovered = nil }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let last = dragLast ?? g.startLocation
                if dragged || hypot(g.location.x - g.startLocation.x, g.location.y - g.startLocation.y) > 3 {
                    dragged = true
                    model.camera.orbit(dx: Double(g.location.x - last.x) * 2, dy: Double(g.location.y - last.y) * 2)
                    model.cameraChanged()
                }
                dragLast = g.location
            }
            .onEnded { g in
                if !dragged { click(g.location, shown) }
                dragged = false
                dragLast = nil
            })
        .overlay(alignment: .topTrailing) {
            Button { model.setView(.iso) } label: {
                Image(systemName: "house").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(textColor)
            .offset(x: 6, y: -4)
            .help("Home view")
        }
    }

    /// A click on the outer band of a face picks the neighbouring edge or corner too.
    private func click(_ p: CGPoint, _ shown: [(Face, [CGPoint])]) {
        guard let f = shown.reversed().first(where: { polygon($0.1).contains(p) })?.0 else { return }
        let n = f.normal
        let a: SIMD3<Double> = abs(n.z) > 0.5 ? [1, 0, 0] : [0, 0, 1]
        let b = simd_cross(n, a)
        // Solve p = c + s * (proj(n/2) + alpha * proj(a) + beta * proj(b)) for alpha and beta.
        let (r, u, _) = model.camera.basis
        let s = Double(size * 0.52), c = Double(size / 2)
        let px = (Double(p.x) - c) / s - simd_dot(n * 0.5, r)
        let py = -(Double(p.y) - c) / s - simd_dot(n * 0.5, u)
        let m00 = simd_dot(a, r), m01 = simd_dot(b, r), m10 = simd_dot(a, u), m11 = simd_dot(b, u)
        let det = m00 * m11 - m01 * m10
        guard abs(det) > 1e-6 else { model.setView(f.view); return }
        let alpha = (px * m11 - m01 * py) / det, beta = (m00 * py - px * m10) / det
        var dir = n
        if abs(alpha) > 0.3 { dir += a * (alpha > 0 ? 1 : -1) }
        if abs(beta) > 0.3 { dir += b * (beta > 0 ? 1 : -1) }
        if dir == n { model.setView(f.view) } else { model.look(along: simd_normalize(dir)) }
    }

    private func face(at p: CGPoint, _ shown: [(Face, [CGPoint])]) -> StandardView? {
        for (f, pts) in shown.reversed() where polygon(pts).contains(p) { return f.view }
        return nil
    }
}
