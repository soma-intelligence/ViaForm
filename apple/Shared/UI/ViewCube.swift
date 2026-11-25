import SwiftUI
import simd

/// The orientation cube: it turns with the view. A click on a face gives that standard view, a
/// click near an edge or a corner gives the view along that edge or corner, and a drag orbits.
/// On the Mac, looking square at a face shows arrows that turn the view 90 degrees (through
/// `view.navigate`), and a right-click offers Go Home, Set Current View as Home and the
/// projection.
/// Colours come from the theme (light faces in light mode, panel grey in dark mode); a caller may
/// still override them.
struct ViewCube: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    var size: CGFloat = 96
    var faceColor: Color? = nil
    var edgeColor: Color? = nil
    var textColor: Color? = nil
    var hoverColor: Color? = nil

    private var face: Color { faceColor ?? theme.panel }
    private var edge: Color { edgeColor ?? theme.inkTertiary }
    private var ink: Color { textColor ?? theme.inkSecondary }
    private var hover: Color { hoverColor ?? theme.accent }

    @State private var hovered: StandardView?
    @State private var dragLast: CGPoint?
    @State private var dragged = false
    @State private var inside = false

    private struct Face {
        let view: StandardView
        let normal: SIMD3<Double>
        let label: String
    }

    private static let faces: [Face] = [
        .init(view: .top, normal: [0, 0, 1], label: String(localized: "TOP")),
        .init(view: .bottom, normal: [0, 0, -1], label: String(localized: "BOTTOM")),
        .init(view: .front, normal: [0, -1, 0], label: String(localized: "FRONT")),
        .init(view: .back, normal: [0, 1, 0], label: String(localized: "BACK")),
        .init(view: .right, normal: [1, 0, 0], label: String(localized: "RIGHT")),
        .init(view: .left, normal: [-1, 0, 0], label: String(localized: "LEFT")),
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
        cube
        #if os(macOS)
            .overlay { if inside && aligned { arrows } }
            .onHover { inside = $0 }
            .contextMenu {
                Button("Go Home") { ViewCubeHome.go(model) }
                Button("Set Current View as Home") { ViewCubeHome.set(model) }
                if ViewCubeHome.custom(model) {
                    Button("Reset Home") { ViewCubeHome.reset(model) }
                }
                Divider()
                Button("Orthographic") { model.camera.fov = 0; model.cameraChanged(final: true) }
                    .disabled(model.camera.fov == 0)
                Button("Perspective") { model.camera.fov = 0.7; model.cameraChanged(final: true) }
                    .disabled(model.camera.fov > 0)
                Divider()
                Button("Fit to View") { model.zoomToFit() }
            }
        #endif
    }

    /// True when the view looks square at one face: then the 90 degree arrows show.
    private var aligned: Bool {
        let back = model.camera.basis.back
        return Self.faces.contains { simd_dot($0.normal, back) > 0.999 }
    }

    #if os(macOS)
    /// Fusion's turn arrows around a face: left, right, up and down turn the view 90 degrees to
    /// the next face, the two curved ones roll it a quarter turn.
    private var arrows: some View {
        let r = size * 0.43
        return ZStack {
            arrow("arrowtriangle.left.fill", String(localized: "Turn left 90 degrees"), "left").offset(x: -r)
            arrow("arrowtriangle.right.fill", String(localized: "Turn right 90 degrees"), "right").offset(x: r)
            arrow("arrowtriangle.up.fill", String(localized: "Turn up 90 degrees"), "up").offset(y: -r)
            arrow("arrowtriangle.down.fill", String(localized: "Turn down 90 degrees"), "down").offset(y: r)
            arrow("arrow.counterclockwise", String(localized: "Roll 90 degrees counterclockwise"), "counterclockwise").offset(x: r * 0.62, y: -r)
            arrow("arrow.clockwise", String(localized: "Roll 90 degrees clockwise"), "clockwise").offset(x: r, y: -r * 0.62)
        }
        .frame(width: size, height: size)
    }

    private func arrow(_ symbol: String, _ label: String, _ action: String) -> some View {
        Button { ViewCubeHome.turn(model, action) } label: {
            Image(systemName: symbol)
                .font(VFFont.glyph(8, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }
    #endif

    @ViewBuilder private var cube: some View {
        let shown = visible()
        let faceFill = face, edgeLine = edge, label = ink, hoverFill = hover
        // Fixed size from the cube, never Dynamic Type: a scaled label overflows its face and
        // collides with the next one on the small iPad cube.
        let labelSize = min(size * 0.13, 10)
        Canvas { ctx, _ in
            let back = model.camera.basis.back
            for (f, pts) in shown {
                let path = polygon(pts)
                let shade = 0.82 + 0.18 * simd_dot(f.normal, back)
                ctx.fill(path, with: .color(hovered == f.view ? hoverFill.opacity(0.35) : faceFill.opacity(shade)))
                ctx.stroke(path, with: .color(edgeLine), lineWidth: 1)
                let centre = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4) }
                let facing = simd_dot(f.normal, back)
                if facing > 0.42 {
                    // Shrink the word to fit its face (FRONT and RIGHT sit side by side at the
                    // home view); leave the face blank when it would be too small to read.
                    let xs = pts.map(\.x)
                    let room = ((xs.max() ?? 0) - (xs.min() ?? 0)) * 0.8
                    let natural = ctx.resolve(Text(f.label).font(VFFont.icon(labelSize, weight: .semibold)))
                        .measure(in: CGSize(width: 1000, height: 100)).width
                    let fitted = natural > room ? labelSize * room / max(natural, 1) : labelSize
                    if fitted >= 5 {
                        ctx.draw(Text(f.label).font(VFFont.icon(fitted, weight: .semibold)).foregroundStyle(label), at: centre)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("View orientation"))
        .accessibilityHint(Text("Choose a standard view from the actions"))
        .accessibilityActions {
            ForEach(StandardView.allCases, id: \.self) { v in
                Button(v == .iso ? String(localized: "Home view") : String(localized: "\(v.rawValue.capitalized) view")) { model.flyTo(v) }
            }
        }
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
        #if os(macOS)
        // On the iPad a 44 pt home button would cover the cube: Home View is in the view menu.
        .overlay(alignment: .topTrailing) {
            VFIconButton("arrow.counterclockwise", label: String(localized: "Home view"), size: 10, tint: ink) { ViewCubeHome.go(model) }
                .offset(x: VFSpace.s, y: -VFSpace.xs)
        }
        #endif
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
        guard abs(det) > 1e-6 else { model.flyTo(f.view); return }
        let alpha = (px * m11 - m01 * py) / det, beta = (m00 * py - px * m10) / det
        var dir = n
        if abs(alpha) > 0.3 { dir += a * (alpha > 0 ? 1 : -1) }
        if abs(beta) > 0.3 { dir += b * (beta > 0 ? 1 : -1) }
        if dir == n { model.flyTo(f.view) } else { model.fly(along: simd_normalize(dir)) }
    }

    private func face(at p: CGPoint, _ shown: [(Face, [CGPoint])]) -> StandardView? {
        for (f, pts) in shown.reversed() where polygon(pts).contains(p) { return f.view }
        return nil
    }
}

/// The Home view the cube's home button goes to: the standard isometric orientation, or the
/// camera saved with Set Current View as Home. Kept per open design for this run (the engine
/// has no command that stores a Home view in the design yet).
@MainActor
enum ViewCubeHome {
    private static var homes: [ObjectIdentifier: OrbitCamera] = [:]

    static func custom(_ model: DesignModel) -> Bool { homes[ObjectIdentifier(model)] != nil }

    static func set(_ model: DesignModel) { homes[ObjectIdentifier(model)] = model.camera }

    static func reset(_ model: DesignModel) { homes[ObjectIdentifier(model)] = nil }

    static func go(_ model: DesignModel) {
        if let home = homes[ObjectIdentifier(model)] {
            model.fly(to: home)
        } else {
            model.flyTo(.iso)
        }
    }

    /// `view.navigate` with a turn action (left, right, up, down, clockwise, counterclockwise).
    static func turn(_ model: DesignModel, _ action: String, degrees: Double = 90) {
        guard let r = (try? model.engine.execute("view.navigate", ["camera": model.camera.dictionary, "action": action, "degrees": degrees])) as? [String: Any],
              let c = r["camera"], let data = try? JSONSerialization.data(withJSONObject: c),
              var cam = try? JSONDecoder().decode(OrbitCamera.self, from: data) else { return }
        cam.up = model.camera.up
        model.fly(to: cam)
    }
}
