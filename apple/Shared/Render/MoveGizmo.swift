import SwiftUI
import simd

/// What the move gizmo has set so far (B-13): a translation, a turn about the pivot, and
/// whether the move copies. One `solid.move` applies it all, one undo step.
struct MoveGizmoState: Equatable {
    /// The point the gizmo turns about (the selection's centre to start with).
    var pivot: SIMD3<Double>
    var translate: SIMD3<Double> = .zero
    var rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    /// Keep the originals and move a copy (the engine's `copy`).
    var copy = false
    /// Drags move the pivot instead of the bodies.
    var editingPivot = false

    /// Where the gizmo is drawn: the pivot, carried by the translation.
    var centre: SIMD3<Double> { pivot + translate }

    /// The turn so far, in degrees, about `axis`.
    var angle: Double { rotation.angle * 180 / .pi }
    var axis: SIMD3<Double> { rotation.angle > 1e-12 ? simd_normalize(rotation.axis) : SIMD3(0, 0, 1) }

    var isIdentity: Bool { simd_length(translate) < 1e-9 && abs(rotation.angle) < 1e-9 }

    static let axes: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]

    /// The `solid.move` that applies this state to `bodies`. The engine turns about the world
    /// origin, then translates; turning about the pivot instead adds pivot - R(pivot) to the
    /// translation. `nil` for no bodies.
    func command(bodies: [String]) -> (id: String, params: [String: Any])? {
        guard !bodies.isEmpty else { return nil }
        var t = translate
        var params: [String: Any] = ["bodies": bodies, "copy": copy]
        let deg = angle
        if abs(deg) > 1e-9 {
            t += pivot - rotation.act(pivot)
            let a = axis
            params["axis"] = [a.x, a.y, a.z]
            params["angle"] = deg
        }
        params["translate"] = [Self.clean(t.x), Self.clean(t.y), Self.clean(t.z)]
        return ("solid.move", params)
    }

    private static func clean(_ v: Double) -> Double { abs(v) < 1e-9 ? 0 : (v * 1e6).rounded() / 1e6 }

    // MARK: Drags, as pure functions of the camera (the view and the self tests use them)

    /// After dragging world axis `i`'s arrow by `translation` points from `start`. The value
    /// snaps to `step` millimetres along the axis.
    static func draggingArrow(_ start: MoveGizmoState, axis i: Int, translation: CGSize, camera: OrbitCamera, size: CGSize, step: Double) -> MoveGizmoState {
        var s = start
        let axis = HandleMath.screenAxis(camera: camera, point: start.centre, direction: axes[i], size: size)
        let d = HandleMath.linearValue(start: 0, translation: translation, axis: axis, step: step)
        if s.editingPivot { s.pivot[i] = start.pivot[i] + d } else { s.translate[i] = start.translate[i] + d }
        return s
    }

    /// After dragging world axis `i`'s ring from `from` to `to` (view points), turning about
    /// the pivot. The added angle snaps to `step` degrees.
    static func draggingRing(_ start: MoveGizmoState, axis i: Int, from: CGPoint, to: CGPoint, camera: OrbitCamera, size: CGSize, step: Double) -> MoveGizmoState {
        let a = axes[i], ref = axes[(i + 1) % 3]
        let a0 = HandleMath.angle(at: from, center: start.centre, axis: a, reference: ref, camera: camera, size: size)
        let a1 = HandleMath.unwrap(HandleMath.angle(at: to, center: start.centre, axis: a, reference: ref, camera: camera, size: size), near: a0)
        return turned(start, axis: i, by: HandleMath.snap(a1 - a0, step: step))
    }

    /// `start` turned `degrees` more about world axis `i`.
    static func turned(_ start: MoveGizmoState, axis i: Int, by degrees: Double) -> MoveGizmoState {
        var s = start
        s.rotation = simd_normalize(simd_quatd(angle: degrees * .pi / 180, axis: axes[i]) * start.rotation)
        return s
    }

    /// After dragging the centre ball by `translation` points: free in the view's plane.
    static func draggingCentre(_ start: MoveGizmoState, translation: CGSize, camera: OrbitCamera, size: CGSize) -> MoveGizmoState {
        var s = start
        let k = HandleMath.worldPerPoint(camera: camera, at: start.centre, size: size)
        let b = camera.basis
        let d = b.right * Double(translation.width) * k - b.up * Double(translation.height) * k
        if s.editingPivot { s.pivot = start.pivot + d } else { s.translate = start.translate + d }
        return s
    }
}

/// The move gizmo (B-13): three arrows along X, Y and Z, three rings about them, a centre ball
/// that moves freely in the view's plane, a Copy badge and a Pivot badge. It edits `state`;
/// the hosting dialog previews and commits `state.command(bodies:)`.
///
/// Snapping: arrows 0.5 mm (Shift 5 mm), rings 5 degrees (Shift 15), Command drags freely.
struct MoveGizmo: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let camera: OrbitCamera
    let size: CGSize
    @Binding var state: MoveGizmoState
    var touch = false
    /// A drag began and ended (preview on change, keep the undo step for the end).
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}

    @State private var start: MoveGizmoState?
    @State private var active: String?
    private static let space = "vf.moveGizmo"
    private static let arrowLength: CGFloat = 92
    private static let ringRadius: CGFloat = 62

    var body: some View {
        let _ = units
        let c = camera.project(state.centre, size: size)
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(0..<3, id: \.self) { i in ring(i) }
            ForEach(0..<3, id: \.self) { i in arrow(i, from: c) }
            Circle()
                .fill(state.editingPivot ? theme.warning : theme.onAccent)
                .overlay(Circle().strokeBorder(theme.ink.opacity(0.6), lineWidth: 1.5))
                .frame(width: touch ? 22 : 14, height: touch ? 22 : 14)
                .frame(width: touch ? VFSize.touchTarget : 26, height: touch ? VFSize.touchTarget : 26)
                .contentShape(Circle())
                .position(c)
                .gesture(centreDrag)
                .accessibilityLabel(String(localized: "Move freely"))
            badges(at: c)
            if let readout {
                HandleValueChip(text: readout).position(x: c.x, y: c.y + Self.arrowLength + 22).allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.space)
    }

    private func colour(_ i: Int) -> Color { [theme.danger, theme.success, theme.accent][i] }
    private static let names = ["X", "Y", "Z"]

    /// What the last drag did, while dragging.
    private var readout: String? {
        guard let start else { return nil }
        if active?.hasPrefix("ring") == true { return VFFormat.angle(state.angle) }
        let d = state.editingPivot ? state.pivot - start.pivot : state.translate
        return VFFormat.lengths([d.x, d.y, d.z], separator: ", ", digits: 2)
    }

    // MARK: Arrows

    private func tip(_ i: Int, from c: CGPoint) -> CGPoint {
        let axis = HandleMath.screenAxis(camera: camera, point: state.centre, direction: MoveGizmoState.axes[i], size: size)
        return CGPoint(x: c.x + axis.dir.dx * Self.arrowLength, y: c.y + axis.dir.dy * Self.arrowLength)
    }

    private func arrow(_ i: Int, from c: CGPoint) -> some View {
        let t = tip(i, from: c)
        var line = Path()
        line.move(to: c)
        line.addLine(to: t)
        let on = active == "arrow\(i)"
        return ZStack(alignment: .topLeading) {
            line.stroke(colour(i), style: StrokeStyle(lineWidth: on ? 3.2 : 2.2, lineCap: .round))
            HandleGrip(symbol: "arrow.up", tint: colour(i), touch: touch, rotation: .radians(atan2(t.x - c.x, -(t.y - c.y))))
                .position(t)
        }
        .contentShape(line.strokedPath(StrokeStyle(lineWidth: touch ? VFSize.touchTarget : 14, lineCap: .round)))
        .gesture(arrowDrag(i))
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Move along \(Self.names[i])"))
        .accessibilityValue(VFFormat.length(state.editingPivot ? state.pivot[i] : state.translate[i]))
        .accessibilityAdjustableAction { dir in
            onBegin()
            var s = state
            if s.editingPivot { s.pivot[i] += dir == .increment ? 1 : -1 } else { s.translate[i] += dir == .increment ? 1 : -1 }
            state = s
            onEnd()
        }
    }

    private func arrowDrag(_ i: Int) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if start == nil { start = state; active = "arrow\(i)"; onBegin() }
                guard let s0 = start else { return }
                let s = MoveGizmoState.draggingArrow(s0, axis: i, translation: g.translation, camera: camera, size: size,
                                                     step: HandleMath.step(fine: 0.5, coarse: 5))
                if s != state { state = s }
            }
            .onEnded { _ in finish() }
    }

    // MARK: Rings

    private func ringPoints(_ i: Int) -> [CGPoint] {
        let a = MoveGizmoState.axes[i], x = MoveGizmoState.axes[(i + 1) % 3], y = simd_cross(a, x)
        let r = Double(Self.ringRadius) * HandleMath.worldPerPoint(camera: camera, at: state.centre, size: size)
        return (0...72).map { k in
            let t = Double(k) / 72 * 2 * .pi
            return camera.project(state.centre + (x * cos(t) + y * sin(t)) * r, size: size)
        }
    }

    private func ring(_ i: Int) -> some View {
        var path = Path()
        let pts = ringPoints(i)
        if let f = pts.first { path.move(to: f); for p in pts.dropFirst() { path.addLine(to: p) } }
        let on = active == "ring\(i)"
        return path
            .stroke(colour(i).opacity(on ? 1 : 0.75), lineWidth: on ? 3 : 1.8)
            .contentShape(path.strokedPath(StrokeStyle(lineWidth: touch ? 24 : 10)))
            .gesture(ringDrag(i))
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Rotate about \(Self.names[i])"))
            .accessibilityValue(VFFormat.angle(state.angle))
            .accessibilityAdjustableAction { dir in
                onBegin()
                state = MoveGizmoState.turned(state, axis: i, by: dir == .increment ? 15 : -15)
                onEnd()
            }
    }

    private func ringDrag(_ i: Int) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if start == nil { start = state; active = "ring\(i)"; onBegin() }
                guard let s0 = start, !s0.editingPivot else { return }
                let s = MoveGizmoState.draggingRing(s0, axis: i, from: g.startLocation, to: g.location, camera: camera, size: size,
                                                    step: HandleMath.step(fine: 5, coarse: 15))
                if s != state { state = s }
            }
            .onEnded { _ in finish() }
    }

    // MARK: Centre and badges

    private var centreDrag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { g in
                if start == nil { start = state; active = "centre"; onBegin() }
                guard let s0 = start else { return }
                let s = MoveGizmoState.draggingCentre(s0, translation: g.translation, camera: camera, size: size)
                if s != state { state = s }
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        start = nil
        active = nil
        onEnd()
    }

    private func badges(at c: CGPoint) -> some View {
        HStack(spacing: VFSpace.xs) {
            badge(String(localized: "Copy"), symbol: "plus.square.on.square", on: state.copy) { state.copy.toggle() }
            badge(String(localized: "Pivot"), symbol: "scope", on: state.editingPivot) { state.editingPivot.toggle() }
        }
        .fixedSize()
        .position(x: c.x + 70, y: c.y - Self.arrowLength - 18)
    }

    private func badge(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(VFFont.micro)
                .foregroundStyle(on ? theme.onAccent : theme.ink)
                .padding(.horizontal, VFSpace.s)
                .padding(.vertical, VFSpace.xxs)
                .frame(minHeight: touch ? VFSize.touchTarget : 0)
                .background(Capsule().fill(on ? theme.accent : theme.floating))
                .overlay(Capsule().strokeBorder(theme.floatingStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
