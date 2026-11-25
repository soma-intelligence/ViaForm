import SwiftUI
import simd
#if os(macOS)
import AppKit
#endif

// Reusable on-canvas handles (B-13): a linear arrow with a value chip (fillet and chamfer
// radius, shell thickness, section offset) and an arc with an angle (revolve). Each takes the
// camera and the overlay size and edits a binding, so a dialog attaches one by handing it its
// value; the dialog decides what a change does (a live preview, a command on release).

/// Screen mapping shared by the handles. Pure functions of the camera, for the self tests.
enum HandleMath {
    /// A world direction at `point` on screen: a unit direction and the points one millimetre
    /// spans along it. Looking straight down the direction, dragging up the screen adds.
    static func screenAxis(camera: OrbitCamera, point: SIMD3<Double>, direction: SIMD3<Double>, size: CGSize) -> (dir: CGVector, perUnit: Double) {
        let a = camera.project(point, size: size)
        let b = camera.project(point + simd_normalize(direction), size: size)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let flat = Double(size.height) / max(2 * camera.halfHeight, 1e-9)
        if len < max(0.15 * flat, 0.5) { return (CGVector(dx: 0, dy: -1), flat) }
        return (CGVector(dx: dx / len, dy: dy / len), Double(len))
    }

    /// Millimetres per screen point at `point` (for sizing rings in the world).
    static func worldPerPoint(camera: OrbitCamera, at point: SIMD3<Double>, size: CGSize) -> Double {
        var h = camera.halfHeight
        if camera.fov > 0 {
            let depth = -simd_dot(point - camera.eye, camera.basis.back)
            h *= max(depth, 1e-6) / max(camera.distance, 1e-9)
        }
        return 2 * h / max(Double(size.height), 1)
    }

    /// The value after a drag of `translation` points along `axis`, from `start`, snapped.
    static func linearValue(start: Double, translation: CGSize, axis: (dir: CGVector, perUnit: Double), step: Double) -> Double {
        let along = Double(translation.width * axis.dir.dx + translation.height * axis.dir.dy)
        return snap(start + along / max(axis.perUnit, 1e-9), step: step)
    }

    static func snap(_ v: Double, step: Double) -> Double { step > 0 ? (v / step).rounded() * step : v }

    /// The angle (degrees, -180...180) of the view point `p` around `axis` through `center`,
    /// measured from `reference` toward axis x reference (the right-hand turn the engine uses).
    /// Read on the plane through `center` across `axis`, or on screen when the plane is edge on.
    static func angle(at p: CGPoint, center: SIMD3<Double>, axis: SIMD3<Double>, reference: SIMD3<Double>, camera: OrbitCamera, size: CGSize) -> Double {
        let a = simd_normalize(axis)
        let x = simd_normalize(reference - a * simd_dot(reference, a))
        let y = simd_cross(a, x)
        let (o, d) = camera.ray(at: p, size: size)
        let denom = simd_dot(d, a)
        if abs(denom) > 0.12 {
            let t = simd_dot(center - o, a) / denom
            let v = o + d * t - center
            return atan2(simd_dot(v, y), simd_dot(v, x)) * 180 / .pi
        }
        // Edge on: the angle of the point around the centre on screen, against the reference.
        let c = camera.project(center, size: size)
        let rx = camera.project(center + x, size: size), ry = camera.project(center + y, size: size)
        let ex = CGVector(dx: rx.x - c.x, dy: rx.y - c.y), ey = CGVector(dx: ry.x - c.x, dy: ry.y - c.y)
        let q = CGVector(dx: p.x - c.x, dy: p.y - c.y)
        // Solve q = s ex + t ey in the least squares sense (ey may be degenerate edge on).
        let s = Double(q.dx * ex.dx + q.dy * ex.dy) / max(Double(ex.dx * ex.dx + ex.dy * ex.dy), 1e-9)
        let t = Double(q.dx * ey.dx + q.dy * ey.dy) / max(Double(ey.dx * ey.dx + ey.dy * ey.dy), 1e-9)
        return atan2(t, s) * 180 / .pi
    }

    /// `a` shifted by whole turns to lie within half a turn of `near`.
    static func unwrap(_ a: Double, near: Double) -> Double {
        var v = a
        while v - near > 180 { v -= 360 }
        while v - near < -180 { v += 360 }
        return v
    }

    /// The snapping step for the keys held now: Shift snaps coarse, Command drags freely.
    static func step(fine: Double, coarse: Double) -> Double {
        #if os(macOS)
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) { return fine / 50 }
        if mods.contains(.shift) { return coarse }
        #endif
        return fine
    }
}

/// The value chip beside a handle's grip: the live value, in the reader's units.
struct HandleValueChip: View {
    @Environment(\.viaFormTheme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(VFFont.micro)
            .foregroundStyle(theme.ink)
            .padding(.horizontal, VFSpace.s)
            .padding(.vertical, VFSpace.xxs)
            .background(Capsule().fill(theme.floating))
            .overlay(Capsule().strokeBorder(theme.floatingStroke, lineWidth: 1))
            .fixedSize()
    }
}

/// A grip disc with a glyph, the shared look of every handle's end.
struct HandleGrip: View {
    @Environment(\.viaFormTheme) private var theme
    let symbol: String
    var tint: Color?
    var touch = false
    var rotation: Angle = .zero

    var body: some View {
        let fill = tint ?? theme.accent
        let d: CGFloat = touch ? 28 : 18
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(theme.onAccent, lineWidth: 2))
            .overlay(Image(systemName: symbol).font(VFFont.icon(touch ? 13 : 9, weight: .bold)).foregroundStyle(theme.onAccent).rotationEffect(rotation))
            .frame(width: d, height: d)
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            .frame(width: touch ? VFSize.touchTarget : 30, height: touch ? VFSize.touchTarget : 30)
            .contentShape(Circle())
    }
}

/// An arrow from `anchor` along `direction` with a grip at its tip: dragging the grip sets
/// `value` (millimetres along the direction). Fillet and chamfer radius, shell thickness,
/// section offset. The grip sits at least 56 and at most 200 points out, so any value stays
/// reachable; a negative value points the other way.
///
/// Snapping: `step` (0.5 mm by default); Shift snaps to ten steps; Command drags freely.
struct LinearValueHandle: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let camera: OrbitCamera
    let size: CGSize
    let anchor: SIMD3<Double>
    let direction: SIMD3<Double>
    @Binding var value: Double
    /// Accessibility label, e.g. "Fillet radius".
    var label: String
    var range: ClosedRange<Double> = -1e6...1e6
    var step: Double = 0.5
    var touch = false
    var showsChip = true
    var tint: Color?
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var start: Double?

    var body: some View {
        let _ = units
        let a = camera.project(anchor, size: size)
        let t = tip
        let c = tint ?? theme.accent
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            Canvas { ctx, _ in
                var line = Path()
                line.move(to: a)
                line.addLine(to: t)
                ctx.stroke(line, with: .color(c), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                let r: CGFloat = 4.5
                ctx.fill(Path(ellipseIn: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2)), with: .color(theme.onAccent))
                ctx.fill(Path(ellipseIn: CGRect(x: a.x - r + 1.5, y: a.y - r + 1.5, width: (r - 1.5) * 2, height: (r - 1.5) * 2)), with: .color(c))
            }
            .allowsHitTesting(false)
            HandleGrip(symbol: "arrow.up", tint: tint, touch: touch, rotation: .radians(atan2(t.x - a.x, -(t.y - a.y))))
                .position(t)
                .gesture(drag)
                .help(String(localized: "Drag to set the value. Shift snaps coarser, Command drags freely"))
                .accessibilityLabel(label)
                .accessibilityValue(VFFormat.length(value))
                .accessibilityAdjustableAction { dir in
                    onBegin()
                    value = clamp(HandleMath.snap(value + (dir == .increment ? step : -step), step: step))
                    onEnd()
                }
            if showsChip {
                HandleValueChip(text: VFFormat.length(value))
                    .position(x: t.x + (t.x >= a.x ? 1 : -1) * 44, y: t.y - 18)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Where the grip sits on screen.
    var tip: CGPoint {
        let a = camera.project(anchor, size: size)
        let axis = HandleMath.screenAxis(camera: camera, point: anchor, direction: direction, size: size)
        let shown = min(max(abs(value) * axis.perUnit, 56), 200) * (value < 0 ? -1 : 1)
        return CGPoint(x: a.x + axis.dir.dx * shown, y: a.y + axis.dir.dy * shown)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                if start == nil { start = value; onBegin() }
                let axis = HandleMath.screenAxis(camera: camera, point: anchor, direction: direction, size: size)
                let v = clamp(HandleMath.linearValue(start: start ?? value, translation: g.translation, axis: axis,
                                                     step: HandleMath.step(fine: step, coarse: step * 10)))
                if abs(v - value) > 1e-9 { value = v }
            }
            .onEnded { _ in
                start = nil
                onEnd()
            }
    }
}

/// An arc around `axis` through `center`, from `reference` over `degrees`, with a grip at its
/// end: dragging the grip around the axis sets `degrees` (revolve angle). The arc's radius is
/// in millimetres, at least 48 points on screen.
///
/// Snapping: `step` (1 degree by default); Shift snaps to 15 degrees; Command drags freely.
struct AngleArcHandle: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let camera: OrbitCamera
    let size: CGSize
    let center: SIMD3<Double>
    let axis: SIMD3<Double>
    /// Where zero degrees points, across the axis.
    let reference: SIMD3<Double>
    var radius: Double
    @Binding var degrees: Double
    var label: String
    var range: ClosedRange<Double> = -360...360
    var step: Double = 1
    var touch = false
    var showsChip = true
    var tint: Color?
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var drag: (start: Double, last: Double, turned: Double)?
    private static let space = "vf.angleArcHandle"

    var body: some View {
        let _ = units
        let c = tint ?? theme.accent
        let r = shownRadius
        let full = arc(from: 0, to: 360, radius: r)
        let swept = arc(from: 0, to: degrees, radius: r)
        let end = point(at: degrees, radius: r)
        let centre = camera.project(center, size: size)
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            Canvas { ctx, _ in
                ctx.stroke(polyline(full), with: .color(c.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                var wedge = polyline(swept)
                wedge.addLine(to: centre)
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(c.opacity(0.12)))
                ctx.stroke(polyline(swept), with: .color(c), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                var spoke = Path()
                spoke.move(to: centre)
                spoke.addLine(to: point(at: 0, radius: r))
                ctx.stroke(spoke, with: .color(c.opacity(0.6)), lineWidth: 1)
            }
            .allowsHitTesting(false)
            HandleGrip(symbol: "arrow.clockwise", tint: tint, touch: touch)
                .position(end)
                .gesture(gesture)
                .help(String(localized: "Drag around the axis to set the angle. Shift snaps to 15°, Command drags freely"))
                .accessibilityLabel(label)
                .accessibilityValue(VFFormat.angle(degrees))
                .accessibilityAdjustableAction { dir in
                    onBegin()
                    degrees = clamp(HandleMath.snap(degrees + (dir == .increment ? step : -step), step: step))
                    onEnd()
                }
            if showsChip {
                HandleValueChip(text: VFFormat.angle(degrees))
                    .position(x: end.x + 40, y: end.y - 18)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.space)
    }

    /// The world radius drawn: the asked radius, or 48 points on screen if that is larger.
    private var shownRadius: Double {
        max(radius, 48 * HandleMath.worldPerPoint(camera: camera, at: center, size: size))
    }

    private var frame: (x: SIMD3<Double>, y: SIMD3<Double>) {
        let a = simd_normalize(axis)
        let x = simd_normalize(reference - a * simd_dot(reference, a))
        return (x, simd_cross(a, x))
    }

    private func point(at deg: Double, radius r: Double) -> CGPoint {
        let (x, y) = frame
        let t = deg * .pi / 180
        return camera.project(center + (x * cos(t) + y * sin(t)) * r, size: size)
    }

    private func arc(from a: Double, to b: Double, radius r: Double) -> [CGPoint] {
        let n = max(Int(abs(b - a) / 4), 2)
        return (0...n).map { point(at: a + (b - a) * Double($0) / Double(n), radius: r) }
    }

    private func polyline(_ pts: [CGPoint]) -> Path {
        var p = Path()
        if let f = pts.first { p.move(to: f); for q in pts.dropFirst() { p.addLine(to: q) } }
        return p
    }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { g in
                let now = HandleMath.angle(at: g.location, center: center, axis: axis, reference: reference, camera: camera, size: size)
                if drag == nil {
                    let begun = HandleMath.angle(at: g.startLocation, center: center, axis: axis, reference: reference, camera: camera, size: size)
                    drag = (degrees, begun, 0)
                    onBegin()
                }
                guard var d = drag else { return }
                let u = HandleMath.unwrap(now, near: d.last)
                d.turned += u - d.last
                d.last = u
                drag = d
                let v = clamp(HandleMath.snap(d.start + d.turned, step: HandleMath.step(fine: step, coarse: 15)))
                if abs(v - degrees) > 1e-9 { degrees = v }
            }
            .onEnded { _ in
                drag = nil
                onEnd()
            }
    }
}
