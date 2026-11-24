import SwiftUI
import simd

/// UI-UX-AUDIT P2-12: the Metal viewport as VoiceOver sees it. One element per body of the
/// browser list, at the body's projected bounds on screen (stacked at the top left when it has
/// no mesh, for example while hidden), with its visibility, its selected state and a short value.
struct ViewportBodyElement: Identifiable, Equatable {
    var name: String
    var visible: Bool
    var selected: Bool
    /// "7,200 mm³, 30 by 20 by 12 mm" or "Hidden".
    var value: String
    /// Projected screen bounds, in the view's points (origin top left).
    var frame: CGRect
    /// World bounds of the body's meshes, for Frame (nil without a mesh).
    var bounds: (lo: SIMD3<Double>, hi: SIMD3<Double>)?
    var id: String { name }

    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.visible == b.visible && a.selected == b.selected && a.value == b.value && a.frame == b.frame
    }
}

enum ViewportAccessibility {
    /// Size of a stacked element when a body has no projected bounds.
    private static let stacked = CGSize(width: 160, height: 24)
    /// Smallest frame a projected body gets, so a far body stays reachable by touch exploration.
    private static let minSide: CGFloat = 24

    /// Pure: the elements for a snapshot, its scene and a camera. `camera` nil stacks every
    /// element (no projection), which the view uses while no assistive technology runs.
    static func elements(snapshot: DesignSnapshot, scene: SceneData, selected: Set<String>,
                         camera: OrbitCamera?, size: CGSize) -> [ViewportBodyElement] {
        var boxes: [String: (lo: SIMD3<Float>, hi: SIMD3<Float>)] = [:]
        for m in scene.meshes where m.lo.x <= m.hi.x {
            if let b = boxes[m.body] {
                boxes[m.body] = (simd_min(b.lo, m.lo), simd_max(b.hi, m.hi))
            } else {
                boxes[m.body] = (m.lo, m.hi)
            }
        }
        let view = CGRect(origin: .zero, size: size)
        return snapshot.bodies.enumerated().map { i, b in
            let visible = b.visible ?? true
            let box = boxes[b.name].map { (lo: SIMD3<Double>($0.lo), hi: SIMD3<Double>($0.hi)) }
            var parts: [String] = []
            if !visible { parts.append(String(localized: "Hidden")) }
            if let v = b.volume_mm3, v.isFinite, v > 0 {
                parts.append(VFFormat.value(v, .custom("mm³")))
            }
            if let box {
                let d = box.hi - box.lo
                let x = VFFormat.value(d.x, .length, withUnit: false)
                let y = VFFormat.value(d.y, .length, withUnit: false)
                let z = VFFormat.value(d.z, .length, withUnit: false)
                parts.append(String(localized: "\(x) by \(y) by \(z) mm"))
            }
            if let m = b.material, !m.isEmpty { parts.append(m) }
            let fallback = CGRect(x: VFSpace.m, y: VFSpace.m + CGFloat(i) * (stacked.height + VFSpace.xs),
                                  width: stacked.width, height: stacked.height)
            var frame = fallback
            if visible, let box, let camera, size.width > 0, size.height > 0 {
                frame = project(lo: box.lo, hi: box.hi, camera: camera, size: size).intersection(view)
                if frame.isNull || frame.isEmpty { frame = fallback }
                if frame.width < minSide { frame = frame.insetBy(dx: (frame.width - minSide) / 2, dy: 0) }
                if frame.height < minSide { frame = frame.insetBy(dx: 0, dy: (frame.height - minSide) / 2) }
            }
            return ViewportBodyElement(name: b.name, visible: visible, selected: selected.contains(b.name),
                                       value: parts.joined(separator: ", "), frame: frame, bounds: box)
        }
    }

    /// The screen rectangle around a world box's eight corners.
    static func project(lo: SIMD3<Double>, hi: SIMD3<Double>, camera: OrbitCamera, size: CGSize) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for k in 0..<8 {
            let c = SIMD3(k & 1 == 0 ? lo.x : hi.x, k & 2 == 0 ? lo.y : hi.y, k & 4 == 0 ? lo.z : hi.z)
            let p = camera.project(c, size: size)
            guard p.x.isFinite, p.y.isFinite else { continue }
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        guard minX <= maxX, minY <= maxY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// An invisible layer over the viewport that carries the body elements. It takes no hits, so
/// the Metal view keeps every click and gesture.
struct ViewportAccessibilityLayer: View {
    let model: DesignModel
    /// Projection follows the camera only while an assistive technology runs, so orbiting does
    /// not rebuild this layer for nothing.
    @Environment(\.accessibilityEnabled) private var assistive

    var body: some View {
        GeometryReader { g in
            let items = ViewportAccessibility.elements(snapshot: model.snapshot, scene: model.scene,
                                                       selected: model.selectedBodies,
                                                       camera: assistive ? model.camera : nil, size: g.size)
            Canvas { _, _ in }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("3D view"))
                .accessibilityValue(items.isEmpty ? Text("No bodies") : Text("^[\(items.count) body](inflect: true)"))
                .accessibilityChildren {
                    ZStack(alignment: .topLeading) {
                        ForEach(items) { e in element(e) }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                }
        }
        .allowsHitTesting(false)
    }

    private func element(_ e: ViewportBodyElement) -> some View {
        Rectangle()
            .frame(width: e.frame.width, height: e.frame.height)
            .position(x: e.frame.midX, y: e.frame.midY)
            .accessibilityLabel(Text(e.name))
            .accessibilityValue(Text(e.value))
            .accessibilityHint(Text("Selects the body."))
            .accessibilityAddTraits(e.selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(e.name) }
            .accessibilityAction(named: Text("Frame")) { frame(e) }
            .accessibilityAction(named: e.visible ? Text("Hide") : Text("Show")) {
                model.toggleBodyVisibility(e.name, visible: !e.visible)
            }
    }

    /// The browser's rule: picking a body replaces the face and edge picks.
    private func select(_ name: String) {
        model.selection = []
        model.selectedBodies = [name]
    }

    private func frame(_ e: ViewportBodyElement) {
        guard let b = e.bounds else { model.zoomToFit(); return }
        let size = model.viewSize
        model.camera.fit(min: b.lo, max: b.hi, aspect: Double(size.width / max(size.height, 1)))
        model.cameraChanged(final: true)
    }
}

/// `--selftest`: the sample project's viewport has one element per visible body, framed on screen;
/// the heat map legend checks (P2-26) ride on the same line of SelfTest.swift.
@MainActor
enum ViewportAccessibilitySelfTest {
    static func checks() -> [(Bool, String)] {
        let d = DesignModel()
        d.viewSize = CGSize(width: 1200, height: 800)
        d.loadSample()
        d.zoomToFit()
        let items = ViewportAccessibility.elements(snapshot: d.snapshot, scene: d.scene, selected: [],
                                                   camera: d.camera, size: d.viewSize)
        let visibleBodies = d.snapshot.bodies.filter { $0.visible ?? true }
        let shown = items.filter(\.visible)
        let view = CGRect(origin: .zero, size: d.viewSize)
        let onScreen = shown.allSatisfy { view.contains($0.frame) && $0.frame.width >= 24 && !$0.value.isEmpty }
        return HeatMapLegendSelfTest.checks() + [
            (!visibleBodies.isEmpty && shown.count == visibleBodies.count && items.count == d.snapshot.bodies.count,
             "P2-12 design viewport exposes one element per visible body (\(shown.count) of \(visibleBodies.count))"),
            (onScreen, "P2-12 body elements sit inside the view with a size value"),
        ]
    }
}
