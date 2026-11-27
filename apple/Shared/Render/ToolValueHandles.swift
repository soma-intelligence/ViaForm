import SwiftUI
import simd

/// Where a tool's on-canvas handle sits (B-13), from the model's picks: Fillet and Chamfer drag
/// off the last picked edge, Shell into the picked face, Revolve around the sketch axis. Display
/// only: the value still goes to the engine as the tool's own parameter.
enum ToolHandlePlacement {
    case linear(anchor: SIMD3<Double>, direction: SIMD3<Double>, label: String)
    case arc(center: SIMD3<Double>, axis: SIMD3<Double>, reference: SIMD3<Double>, radius: Double, label: String)

    static func of(_ model: DesignModel) -> ToolHandlePlacement? {
        switch model.tool {
        case .fillet, .chamfer:
            guard case let .edge(mi, ei, p)? = model.selection.last(where: \.isEdge), mi < model.scene.meshes.count else { return nil }
            let mesh = model.scene.meshes[mi]
            // Away from the body across the edge: the body's centre to the pick, less the
            // edge's own direction.
            let centre = (SIMD3<Double>(mesh.lo) + SIMD3<Double>(mesh.hi)) / 2
            var out = p - centre
            if ei < mesh.edges.count, let t = tangent(mesh.edges[ei], near: p) { out -= t * simd_dot(out, t) }
            guard simd_length(out) > 1e-9 else { return nil }
            let label = model.tool == .fillet ? String(localized: "Fillet radius") : String(localized: "Chamfer distance")
            return .linear(anchor: p, direction: simd_normalize(out), label: label)
        case .shell:
            guard case let .face(_, _, p, n)? = model.selection.last(where: \.isFace), simd_length(n) > 1e-9 else { return nil }
            return .linear(anchor: p, direction: -simd_normalize(n), label: String(localized: "Shell thickness"))
        case .revolve:
            guard let plane = model.sketchInfo?.plane else { return nil }
            let vertical = model.revolveAxis.lowercased() == "y"
            let axis = simd_normalize(vertical ? plane.y : plane.x)
            let reference = simd_normalize(vertical ? plane.x : plane.y)
            let r = max(Double(model.scene.radius) * 0.35, 1)
            return .arc(center: plane.origin, axis: axis, reference: reference, radius: r, label: String(localized: "Revolve angle"))
        default:
            return nil
        }
    }

    /// The unit direction of a polyline at its point nearest `p`.
    static func tangent(_ line: [SIMD3<Float>], near p: SIMD3<Double>) -> SIMD3<Double>? {
        guard line.count > 1 else { return nil }
        var best: (d: Double, t: SIMD3<Double>)?
        for i in 0..<(line.count - 1) {
            let a = SIMD3<Double>(line[i]), b = SIMD3<Double>(line[i + 1])
            let ab = b - a
            let l2 = simd_length_squared(ab)
            guard l2 > 1e-18 else { continue }
            let s = min(max(simd_dot(p - a, ab) / l2, 0), 1)
            let d = simd_distance(a + ab * s, p)
            if best == nil || d < best!.d { best = (d, ab / sqrt(l2)) }
        }
        return best?.t
    }
}

/// The armed tool's value handle (Fillet, Chamfer, Shell, Revolve), bound to the dialog's
/// `FeatureSession.value` (the tool value, or the edited feature's): each change runs one
/// preview, so the dialog's commit keeps one undo step. Nothing shows
/// for other tools or without a pick.
struct ToolValueHandle: View {
    let model: DesignModel
    let size: CGSize
    var touch = false

    var body: some View {
        // Through the dialog's session: while a feature is edited the value is the edit's, and a
        // session that owns the preview runs it once per change.
        let session = FeatureSession.of(model)
        let value = Binding(get: { session.value }, set: { session.value = $0 })
        switch ToolHandlePlacement.of(model) {
        case let .linear(anchor, direction, label)?:
            LinearValueHandle(camera: model.camera, size: size, anchor: anchor, direction: direction, value: value,
                              label: label, range: 0...1e5, step: 0.5, touch: touch)
                .frame(width: size.width, height: size.height)
        case let .arc(center, axis, reference, radius, label)?:
            AngleArcHandle(camera: model.camera, size: size, center: center, axis: axis, reference: reference, radius: radius,
                           degrees: value, label: label, range: -360...360, step: 1, touch: touch)
        case nil:
            EmptyView()
        }
    }
}
