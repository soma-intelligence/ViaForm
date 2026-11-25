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

    @State private var hovered: String?
    @State private var dragLast: CGPoint?
    @State private var dragged = false
    @State private var inside = false

    /// One clickable facet of the bevelled cube: a face (a standard view, with its word), an
    /// edge strip or a corner triangle (the view along that edge or corner). The bevel shows
    /// even when the view looks square at a face, so the cube still reads as a cube in a
    /// sketch's top view instead of a flat square.
    struct Region {
        let id: String
        let normal: SIMD3<Double>
        let points: [SIMD3<Double>]
        var view: StandardView?
        var label: String?
        /// The word's right and up directions on a face.
        var right: SIMD3<Double> = .zero
        var up: SIMD3<Double> = .zero
    }

    /// Half the flat part of a face: the rest of the half side (0.5) is the bevel.
    static let flat = 0.35

    static let regions: [Region] = {
        let k = flat
        let axes: [(StandardView, SIMD3<Double>, String)] = [
            (.top, [0, 0, 1], String(localized: "TOP")),
            (.bottom, [0, 0, -1], String(localized: "BOTTOM")),
            (.front, [0, -1, 0], String(localized: "FRONT")),
            (.back, [0, 1, 0], String(localized: "BACK")),
            (.right, [1, 0, 0], String(localized: "RIGHT")),
            (.left, [-1, 0, 0], String(localized: "LEFT")),
        ]
        var out: [Region] = []
        for (v, n, word) in axes {
            let up: SIMD3<Double> = abs(n.z) > 0.5 ? [0, n.z > 0 ? 1 : -1, 0] : [0, 0, 1]
            let right = simd_cross(up, n)
            let pts = [n * 0.5 + right * k + up * k, n * 0.5 - right * k + up * k,
                       n * 0.5 - right * k - up * k, n * 0.5 + right * k - up * k]
            out.append(Region(id: v.rawValue, normal: n, points: pts, view: v, label: word, right: right, up: up))
        }
        let ns = axes.map(\.1)
        for i in 0..<ns.count {
            for j in (i + 1)..<ns.count where abs(simd_dot(ns[i], ns[j])) < 0.5 {
                let a = ns[i], b = ns[j], t = simd_cross(a, b)
                let pts = [a * 0.5 + b * k + t * k, a * 0.5 + b * k - t * k, b * 0.5 + a * k - t * k, b * 0.5 + a * k + t * k]
                out.append(Region(id: "edge\(i)\(j)", normal: simd_normalize(a + b), points: pts))
            }
        }
        for sx in [-1.0, 1.0] {
            for sy in [-1.0, 1.0] {
                for sz in [-1.0, 1.0] {
                    let pts: [SIMD3<Double>] = [[sx * 0.5, sy * k, sz * k], [sx * k, sy * 0.5, sz * k], [sx * k, sy * k, sz * 0.5]]
                    out.append(Region(id: "corner\(Int(sx))\(Int(sy))\(Int(sz))", normal: simd_normalize(SIMD3(sx, sy, sz)), points: pts))
                }
            }
        }
        return out
    }()

    /// Scale from cube units to points: the cube's corners stay inside the frame.
    static func scale(_ size: CGFloat) -> CGFloat { size * 0.52 }

    static func project(_ p: SIMD3<Double>, camera: OrbitCamera, size: CGFloat) -> CGPoint {
        let (r, u, _) = camera.basis
        let s = scale(size)
        return CGPoint(x: size / 2 + CGFloat(simd_dot(p, r)) * s, y: size / 2 - CGFloat(simd_dot(p, u)) * s)
    }

    /// The facets turned towards the camera, with their outlines on screen. The cube is
    /// convex, so these never overlap.
    static func visible(camera: OrbitCamera, size: CGFloat) -> [(Region, [CGPoint])] {
        let back = camera.basis.back
        return regions.filter { simd_dot($0.normal, back) > 1e-3 }
            .map { r in (r, r.points.map { project($0, camera: camera, size: size) }) }
    }

    /// The facet under `p`, nil off the cube.
    static func region(at p: CGPoint, camera: OrbitCamera, size: CGFloat) -> Region? {
        visible(camera: camera, size: size).first { polygon($0.1).contains(p) }?.0
    }

    static func polygon(_ pts: [CGPoint]) -> Path {
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
        return Self.regions.contains { $0.view != nil && simd_dot($0.normal, back) > 0.999 }
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
        let cam = model.camera
        let shown = Self.visible(camera: cam, size: size)
        let faceFill = face, edgeLine = edge, label = ink, hoverFill = hover, lit = hovered
        let s = Self.scale(size)
        // Fixed size from the cube, never Dynamic Type: a scaled label overflows its face.
        let labelSize = min(size * 0.14, 11)
        Canvas { ctx, _ in
            let (r, u, back) = cam.basis
            // A soft key light from the upper left of the view: facets shade as they turn.
            let toward: SIMD3<Double> = back + u * 0.6 - r * 0.35
            let light = simd_normalize(toward)
            for (reg, pts) in shown {
                let path = Self.polygon(pts)
                let isFace = reg.view != nil
                let base: Double = isFace ? 0.84 : 0.66
                let shade: Double = base + 0.20 * max(0, simd_dot(reg.normal, light))
                // Opaque, then darkened by the light: a see-through facet let the grid through.
                ctx.fill(path, with: .color(faceFill))
                ctx.fill(path, with: .color(lit == reg.id ? hoverFill.opacity(0.4) : Color.black.opacity((1 - shade) * 0.55)))
                ctx.stroke(path, with: .color(edgeLine.opacity(isFace ? 0.7 : 0.35)), style: StrokeStyle(lineWidth: 0.75, lineJoin: .round))
                guard let word = reg.label, simd_dot(reg.normal, back) > 0.3 else { continue }
                // The word lies on its face: drawn in the face's own axes, so it turns, tilts and
                // foreshortens with the cube.
                let centre = Self.project(reg.normal * 0.5, camera: cam, size: size)
                let room = CGFloat(2 * Self.flat) * s * 0.86
                let text = ctx.resolve(Text(word).font(VFFont.icon(labelSize, weight: .semibold)).foregroundStyle(label))
                let w = text.measure(in: CGSize(width: 1000, height: 100)).width
                let fit = w > room ? room / max(w, 1) : 1
                var layer = ctx
                layer.translateBy(x: centre.x, y: centre.y)
                let ax = CGFloat(simd_dot(reg.right, r)) * fit
                let ay = CGFloat(-simd_dot(reg.right, u)) * fit
                let cx = CGFloat(-simd_dot(reg.up, r)) * fit
                let cy = CGFloat(simd_dot(reg.up, u)) * fit
                layer.concatenate(CGAffineTransform(a: ax, b: ay, c: cx, d: cy, tx: 0, ty: 0))
                layer.draw(text, at: .zero)
            }
        }
        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
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
            if case let .active(p) = phase { hovered = Self.region(at: p, camera: model.camera, size: size)?.id } else { hovered = nil }
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
                if !dragged { click(g.location) }
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

    /// A face gives its standard view; an edge strip or a corner gives the view along it.
    private func click(_ p: CGPoint) {
        guard let reg = Self.region(at: p, camera: model.camera, size: size) else { return }
        if let v = reg.view { model.flyTo(v) } else { model.fly(along: reg.normal) }
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
