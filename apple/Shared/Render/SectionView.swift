import CoreGraphics
import Foundation
import Observation
import simd
import SwiftUI

/// A section plane in world millimetres. Like the engine's `inspect.section`, what lies on the
/// side the normal points to is hidden.
struct SectionPlane: Equatable {
    var origin: SIMD3<Double>
    /// Unit length.
    var normal: SIMD3<Double>

    init(origin: SIMD3<Double>, normal: SIMD3<Double>) {
        self.origin = origin
        let l = simd_length(normal)
        self.normal = l > 1e-12 ? normal / l : SIMD3(0, 0, 1)
    }

    /// Positive on the hidden side.
    func distance(_ p: SIMD3<Double>) -> Double { simd_dot(p - origin, normal) }

    /// The plane moved `by` millimetres along its normal.
    func offset(by d: Double) -> SectionPlane { SectionPlane(origin: origin + normal * d, normal: normal) }

    /// (normal, offset) as the shader takes it: hidden where dot(n, p) > w.
    var equation: SIMD4<Float> {
        SIMD4(Float(normal.x), Float(normal.y), Float(normal.z), Float(simd_dot(normal, origin)))
    }

    /// The `plane` parameter of `inspect.section`.
    var engineParam: [String: Any] {
        ["origin": [origin.x, origin.y, origin.z], "normal": [normal.x, normal.y, normal.z]]
    }
}

/// CPU side of the section: which bodies it crosses and the quads the caps are drawn with.
enum SectionClip {
    /// A square on the plane, centred on the box's centre (projected onto the plane) and wide
    /// enough to cover any cut through the box; `nil` when the plane misses the box. Corners in
    /// triangle-strip order.
    static func capQuad(plane: SectionPlane, lo: SIMD3<Float>, hi: SIMD3<Float>) -> [SIMD3<Float>]? {
        guard lo.x <= hi.x, crosses(plane: plane, lo: lo, hi: hi) else { return nil }
        let l = SIMD3<Double>(lo), h = SIMD3<Double>(hi)
        let centre = (l + h) / 2
        let half = max(simd_length(h - l), 1e-3) * 1.05
        let c = centre - plane.normal * plane.distance(centre)
        let (u, v) = basis(plane.normal)
        let corners = [c - u * half - v * half, c + u * half - v * half, c - u * half + v * half, c + u * half + v * half]
        return corners.map { SIMD3<Float>($0) }
    }

    /// The plane passes between the box's corners.
    static func crosses(plane: SectionPlane, lo: SIMD3<Float>, hi: SIMD3<Float>) -> Bool {
        var below = false, above = false
        for i in 0..<8 {
            let p = SIMD3<Double>(Double(i & 1 == 0 ? lo.x : hi.x), Double(i & 2 == 0 ? lo.y : hi.y), Double(i & 4 == 0 ? lo.z : hi.z))
            let d = plane.distance(p)
            if d < 0 { below = true } else if d > 0 { above = true }
        }
        return below && above
    }

    /// Two unit vectors across the plane.
    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let seed: SIMD3<Double> = abs(n.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(seed, n))
        return (u, simd_cross(n, u))
    }

    /// Triangles of the scene the section leaves on screen (at least one corner on the kept
    /// side), and the bodies that keep any: what the per-pixel clip shows.
    static func kept(_ scene: SceneData, plane: SectionPlane?) -> (meshes: Int, triangles: Int) {
        var meshes = 0, tris = 0
        for m in scene.meshes {
            var n = 0
            let idx = m.indices
            var t = 0
            while t + 2 < idx.count {
                guard let plane else { n += 1; t += 3; continue }
                for k in 0..<3 {
                    let i = Int(idx[t + k])
                    if i < m.positions.count, plane.distance(SIMD3<Double>(m.positions[i])) <= 0 { n += 1; break }
                }
                t += 3
            }
            if n > 0 { meshes += 1 }
            tris += n
        }
        return (meshes, tris)
    }
}

/// The section view of one design (B-15): the plane, the engine's `inspect.section`, and the
/// renderers that clip by it. Get it with `SectionController.of(model)`; every viewport of the
/// model binds its renderer once (`bind`), and dialogs or tool rows drive it.
///
/// Dragging the arrow moves the cut live on the GPU only (`drag(to:)`); the engine command runs
/// on release, so the section outline and the cap state follow.
@Observable
final class SectionController {
    /// The cut now, `nil` when the section is off.
    private(set) var plane: SectionPlane?
    /// Hatch the caps (default) or fill them plain.
    var hatch = true { didSet { push() } }
    /// Millimetres the arrow is dragged from `dragBase`, during a drag.
    private(set) var dragOffset: Double = 0
    /// The plane when the drag began.
    private(set) var dragBase: SectionPlane?

    @ObservationIgnored private var renderers: [WeakRenderer] = []

    var isOn: Bool { plane != nil }

    // MARK: One controller per design

    private struct Entry {
        weak var model: DesignModel?
        let controller: SectionController
    }

    nonisolated(unsafe) private static var registry: [ObjectIdentifier: Entry] = [:]

    static func of(_ model: DesignModel) -> SectionController {
        let key = ObjectIdentifier(model)
        if let e = registry[key], e.model === model { return e.controller }
        registry = registry.filter { $0.value.model != nil }
        let c = SectionController()
        registry[key] = Entry(model: model, controller: c)
        return c
    }

    // MARK: Renderers

    private struct WeakRenderer {
        weak var renderer: Renderer?
    }

    /// Clips this renderer by the section from now on (the viewport calls it once).
    func bind(_ r: Renderer) {
        renderers.removeAll { $0.renderer == nil || $0.renderer === r }
        renderers.append(WeakRenderer(renderer: r))
        r.sectionPlane = plane
        r.sectionHatch = hatch
    }

    private func push() {
        renderers.removeAll { $0.renderer == nil }
        for w in renderers {
            w.renderer?.sectionPlane = plane
            w.renderer?.sectionHatch = hatch
        }
    }

    // MARK: Engine

    /// Cuts the design by `plane` through `inspect.section`. Returns false (and keeps the old
    /// state) when the engine refuses it.
    @discardableResult
    func set(_ plane: SectionPlane, model: DesignModel) -> Bool {
        apply(model.run("inspect.section", ["plane": plane.engineParam, "hatch": hatch], quiet: true))
    }

    /// Cuts by a named plane (XY, XZ, YZ) or a construction plane, `offset` along its normal.
    @discardableResult
    func set(named name: String, offset: Double = 0, flip: Bool = false, model: DesignModel) -> Bool {
        apply(model.run("inspect.section", ["plane": name, "offset": offset, "flip": flip, "hatch": hatch], quiet: true))
    }

    /// The cut through the face under a point of the view, facing out of it: the cut starts at
    /// the face and the arrow drags it into the body.
    @discardableResult
    func pick(at p: CGPoint, model: DesignModel) -> Bool {
        guard case let .face(_, _, point, normal)? = ScenePicker.pickFace(model.scene, camera: model.camera, at: p, size: model.viewSize) else { return false }
        return set(SectionPlane(origin: point, normal: normal), model: model)
    }

    /// Turns the section off.
    func clear(model: DesignModel) {
        model.run("inspect.section", ["clear": true], quiet: true)
        dragBase = nil
        dragOffset = 0
        plane = nil
        push()
    }

    /// Reads the plane back from the engine's reply (`section: {origin, normal, hatch}`).
    private func apply(_ reply: Any?) -> Bool {
        guard let r = reply as? [String: Any] else { return false }
        guard let s = r["section"] as? [String: Any],
              let o = (s["origin"] as? [Double]) ?? (s["origin"] as? [NSNumber])?.map(\.doubleValue),
              let n = (s["normal"] as? [Double]) ?? (s["normal"] as? [NSNumber])?.map(\.doubleValue),
              o.count == 3, n.count == 3 else {
            plane = nil
            push()
            return true
        }
        plane = SectionPlane(origin: SIMD3(o[0], o[1], o[2]), normal: SIMD3(n[0], n[1], n[2]))
        if let h = s["hatch"] as? Bool, h != hatch { hatch = h }
        push()
        return true
    }

    // MARK: Drag arrow

    func beginDrag() {
        guard dragBase == nil, let plane else { return }
        dragBase = plane
        dragOffset = 0
    }

    /// Moves the cut `offset` millimetres along the normal from where the drag began: the GPU
    /// clips there at once, the engine hears about it on `endDrag`.
    func drag(to offset: Double) {
        guard let base = dragBase else { return }
        dragOffset = offset
        plane = base.offset(by: offset)
        push()
    }

    func endDrag(model: DesignModel) {
        guard dragBase != nil else { return }
        dragBase = nil
        dragOffset = 0
        if let plane { set(plane, model: model) }
    }
}

/// The section's drag arrow and the plane's outline, for a viewport overlay of `size`. Drag the
/// arrow to move the cut along its normal; the value chip shows how far.
struct SectionHandle: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel
    let size: CGSize
    var touch = false

    var body: some View {
        let section = SectionController.of(model)
        if let shown = section.dragBase ?? section.plane {
            let cam = model.camera
            ZStack(alignment: .topLeading) {
                outline(section.plane ?? shown, camera: cam).allowsHitTesting(false)
                LinearValueHandle(
                    camera: cam, size: size, anchor: shown.origin, direction: shown.normal,
                    value: Binding(get: { section.dragOffset }, set: { section.drag(to: $0) }),
                    label: String(localized: "Section offset"),
                    touch: touch,
                    showsChip: section.dragBase != nil,
                    onBegin: { section.beginDrag() },
                    onEnd: { section.endDrag(model: model) })
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// A square on the plane around the design, dashed, so the cut's tilt reads at a glance.
    private func outline(_ plane: SectionPlane, camera: OrbitCamera) -> some View {
        Canvas { ctx, sz in
            let r = max(Double(model.scene.radius), 1)
            let (u, v) = SectionClip.basis(plane.normal)
            let c = plane.origin
            let pts = [c - u * r - v * r, c + u * r - v * r, c + u * r + v * r, c - u * r + v * r].map { camera.project($0, size: sz) }
            var path = Path()
            path.addLines(pts)
            path.closeSubpath()
            ctx.stroke(path, with: .color(theme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
        }
    }
}
