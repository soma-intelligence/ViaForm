import SceneKit
import simd
import SwiftUI
#if os(macOS)
import AppKit
typealias VFPlatformColor = NSColor
#else
import UIKit
typealias VFPlatformColor = UIColor
#endif

/// The Assemble canvas's SceneKit scene. Everything under `root` is in the assembly's frame:
/// millimetres, Z up, world at the home pose; `root` turns that into SceneKit's metres, Y up.
///
/// Per component a node whose transform is the component's pose (from the engine's poses, or
/// from kin's link matrices during a drag) and whose children are its home geometry: printed
/// parts as white boxes, servos as dark boxes, hand bones as capsules. On top: joint hubs
/// coloured by limit state, the selected joint's ring, the end effector gizmo, the IK target
/// and its gap, interference regions, the centre of mass and the grasp object with its
/// fingertip targets.
final class AssembleScene: NSObject, AssemblePoseSink {
    let scene = SCNScene()
    let root = SCNNode()
    let cameraNode = SCNNode()
    private var components: [String: SCNNode] = [:]
    private var hubs: [String: SCNNode] = [:]
    private let ring = SCNNode()
    let gizmo = SCNNode()
    private let targetNode = SCNNode()
    private let gapNode = SCNNode()
    private let clashNode = SCNNode()
    private let comNode = SCNNode()
    let graspNode = SCNNode()
    private var tipNodes: [String: SCNNode] = [:]
    private var normalNodes: [String: SCNNode] = [:]
    private(set) weak var model: AssembleModel?
    private var docRevision = -1
    var dark = false
    /// Hot path state, written by `apply` and read by the canvas overlay.
    private(set) var liveQ: [String: Double] = [:]
    private(set) var liveTarget: SIMD3<Double>?
    private(set) var liveShortBy = 0.0

    override init() {
        super.init()
        root.simdTransform = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))) * simd_float4x4(diagonal: SIMD4(0.001, 0.001, 0.001, 1))
        scene.rootNode.addChildNode(root)
        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.zNear = 0.01
        camera.zFar = 50
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowColor = VFPlatformColor.black.withAlphaComponent(0.25)
        key.simdEulerAngles = SIMD3(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 520
        scene.rootNode.addChildNode(fill)
        for n in [ring, gizmo, targetNode, gapNode, clashNode, comNode, graspNode] { root.addChildNode(n) }
        buildGizmo()
        buildFloor()
    }

    func attach(_ m: AssembleModel) {
        model = m
        m.sink = self
    }

    // MARK: Document

    /// The Simulate canvas: poses come from the physics run, no editing decorations.
    var poseSource: (() -> [String: simd_float4x4])?
    private var objectNodes: [String: SCNNode] = [:]

    /// Rebuilds the component nodes when the document changed, then poses everything.
    func sync() {
        guard let m = model else { return }
        if m.documentRevision != docRevision {
            docRevision = m.documentRevision
            rebuild(m)
            frame(m)
        }
        if let src = poseSource {
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            let p = src()
            applyPoses(p.isEmpty ? m.poses : p)
            for (id, n) in objectNodes { n.simdTransform = p[id] ?? matrix_identity_float4x4 }
            gizmo.isHidden = true
            ring.removeFromParentNode()
            SCNTransaction.commit()
            return
        }
        applyPoses(m.poses)
        decorate(m)
    }

    /// A scenario object drawn at its home position (mm); its pose comes with the links.
    func addObject(_ id: String, box size: Double, at p: SIMD3<Double>, hex: UInt32) {
        guard objectNodes[id] == nil else { return }
        let holder = SCNNode()
        let half = Float(size / 2)
        let c = SIMD3(Float(p.x), Float(p.y), Float(p.z))
        holder.addChildNode(box(c - half, c + half, mat: material(hex, rough: 0.45), chamfer: 1.5))
        root.addChildNode(holder)
        objectNodes[id] = holder
    }

    private func rebuild(_ m: AssembleModel) {
        components.values.forEach { $0.removeFromParentNode() }
        components = [:]
        hubs = [:]
        let white = material(dark ? 0xD9DCE2 : 0xF4F5F7, rough: 0.55)
        let servo = material(0x1E2024, rough: 0.35)
        let bone = material(dark ? 0xD0D3D9 : 0xEEEFF2, rough: 0.5)
        for c in m.components {
            let node = SCNNode()
            node.name = "comp:" + c.id
            if m.product == .hand {
                let pts = m.boneTips[c.id] ?? []
                let origin = m.joints.first { $0.child == c.id }.map { SIMD3($0.origin[0], $0.origin[1], $0.origin[2]) }
                    ?? pts.first ?? .zero
                let r: Double = c.id == "palm" ? 9 : (c.id.contains("forearm") ? 16 : 6.5)
                for p in pts where simd_length(p - origin) > 1 {
                    node.addChildNode(capsule(from: origin, to: p, radius: r, mat: bone))
                }
                if pts.isEmpty || c.id == "palm" {
                    let s = SCNSphere(radius: CGFloat(r * 1.2))
                    s.materials = [bone]
                    let n = SCNNode(geometry: s)
                    n.simdPosition = SIMD3(Float(origin.x), Float(origin.y), Float(origin.z))
                    node.addChildNode(n)
                }
            } else if let p = c.proxy {
                let lo = SIMD3(p.min_mm.map(Float.init)), hi = SIMD3(p.max_mm.map(Float.init))
                node.addChildNode(box(lo, hi, mat: white, chamfer: 4))
                for part in c.parts ?? [] {
                    guard let at = part.at_mm, let d = part.dims_mm, at.count == 3, d.count == 3 else { continue }
                    let ctr = SIMD3(at.map(Float.init)), half = SIMD3(Float(d[0]), Float(d[2]), Float(d[1])) / 2
                    // Servo housings: their 35 mm face across the link, slightly proud of it.
                    node.addChildNode(box(ctr - half, ctr + half, mat: servo, chamfer: 2))
                }
            }
            root.addChildNode(node)
            components[c.id] = node
        }
        for j in m.joints {
            guard let child = components[j.child] else { continue }
            let hub = SCNNode()
            let cyl = SCNCylinder(radius: m.product == .hand ? 5 : 9, height: m.product == .hand ? 4 : 30)
            cyl.materials = [material(0x2A2D33, rough: 0.4)]
            hub.geometry = cyl
            hub.name = "joint:" + j.id
            hub.simdTransform = Self.aligned(y: SIMD3(j.axis.map(Float.init)), at: SIMD3(j.origin.map(Float.init)))
            child.addChildNode(hub)
            hubs[j.id] = hub
        }
    }

    /// Frames the camera on the assembly's home bounds, three-quarter view.
    func frame(_ m: AssembleModel) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for c in m.components {
            if let p = c.proxy { lo = simd_min(lo, SIMD3(p.min_mm.map(Float.init))); hi = simd_max(hi, SIMD3(p.max_mm.map(Float.init))) }
        }
        if !lo.x.isFinite { lo = SIMD3(-100, -100, 0); hi = SIMD3(100, 100, 300) }
        if m.product == .arm {
            // The arm stands upright at home: frame its reach in front of it too, so a drag
            // out to the side stays in view.
            let reach = hi.z * 0.9
            hi.x = max(hi.x, reach)
            lo.y = min(lo.y, -reach * 0.35)
            hi.y = max(hi.y, reach * 0.35)
        }
        let center = (lo + hi) / 2
        let size = max(simd_length(hi - lo), 150)
        let dir = m.product == .hand ? simd_normalize(SIMD3<Float>(0.35, -1.0, 0.25)) : simd_normalize(SIMD3<Float>(0.95, -1.15, 0.55))
        let eyeMM = center + dir * size * (m.product == .hand ? 1.55 : 1.5)
        let eye = root.simdConvertPosition(eyeMM, to: nil)
        let look = root.simdConvertPosition(center + SIMD3(0, 0, m.product == .hand ? 0 : -10), to: nil)
        cameraNode.simdPosition = eye
        cameraNode.simdLook(at: look, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    // MARK: Poses

    private func applyPoses(_ poses: [String: simd_float4x4]) {
        for (id, n) in components { n.simdTransform = poses[id] ?? matrix_identity_float4x4 }
    }

    /// The 60 fps drag: nodes move here, SwiftUI sees the numbers at 30 Hz.
    func apply(poses: [String: simd_float4x4], q: [String: Double], target: SIMD3<Double>, shortByMM: Double) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        applyPoses(poses)
        liveQ = q
        liveTarget = target
        liveShortBy = shortByMM
        if let m = model {
            colourHubs(m, q: q)
            placeGizmo(m)
            placeGap(m, target: target, short: shortByMM)
        }
        SCNTransaction.commit()
    }

    // MARK: Decorations

    private func decorate(_ m: AssembleModel) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        colourHubs(m, q: m.q)
        // The selected joint's ring, in the child component so it follows the motion.
        ring.removeFromParentNode()
        if let j = m.selected, m.tool != .dragTip, m.tool != .grasp, let child = components[j.child] {
            ring.geometry = SCNTorus(ringRadius: m.product == .hand ? 14 : 34, pipeRadius: m.product == .hand ? 1.2 : 2.2)
            ring.geometry?.materials = [flat(Self.accent)]
            ring.name = "jring:" + j.id
            ring.simdTransform = Self.aligned(y: SIMD3(j.axis.map(Float.init)), at: SIMD3(j.origin.map(Float.init)))
            child.addChildNode(ring)
        }
        gizmo.isHidden = !(m.tool == .dragTip && m.product == .arm)
        placeGizmo(m)
        placeGap(m, target: m.ik.target, short: m.tool == .dragTip ? m.ik.shortBy : 0)
        // Interference regions, red.
        clashNode.childNodes.forEach { $0.removeFromParentNode() }
        for p in m.interference ?? [] {
            let b = box(SIMD3(Float(p.regionMin.x), Float(p.regionMin.y), Float(p.regionMin.z)) - 1,
                        SIMD3(Float(p.regionMax.x), Float(p.regionMax.y), Float(p.regionMax.z)) + 1, mat: flat(VFPlatformColor(hex: 0xE5251B, alpha: 0.55)), chamfer: 0)
            clashNode.addChildNode(b)
        }
        let clashing = Set((m.interference ?? []).flatMap { [$0.a, $0.b] })
        for (id, n) in components { tint(n, red: clashing.contains(id)) }
        // Centre of mass on the CHECK tab.
        comNode.childNodes.forEach { $0.removeFromParentNode() }
        if m.tab == .check, let c = m.mass?.comMM {
            let s = SCNSphere(radius: 7)
            s.materials = [flat(VFPlatformColor(hex: 0xE08A00))]
            let n = SCNNode(geometry: s)
            n.simdPosition = SIMD3(Float(c.x), Float(c.y), Float(c.z))
            comNode.addChildNode(n)
        }
        decorateGrasp(m)
        SCNTransaction.commit()
    }

    private func colourHubs(_ m: AssembleModel, q: [String: Double]) {
        for j in m.joints {
            guard let hub = hubs[j.id] else { continue }
            var state = AssembleModel.LimitState.free
            if let r = j.range, let v = q[j.id] {
                let edge = min(v - r.lowerBound, r.upperBound - v)
                state = edge <= 0.5 ? .at : (edge <= max((r.upperBound - r.lowerBound) * 0.06, 4) ? .near : .free)
            }
            let hex: UInt32 = state == .at ? 0xE5251B : (state == .near ? 0xF0A020 : 0x2A2D33)
            hub.geometry?.firstMaterial?.diffuse.contents = VFPlatformColor(hex: hex)
            hub.geometry?.firstMaterial?.emission.contents = state == .free ? VFPlatformColor.black : VFPlatformColor(hex: hex, alpha: 0.6)
        }
    }

    /// The tool tip now: the tool component's pose times its home tip.
    func tipNow(_ m: AssembleModel) -> SIMD3<Double> {
        let t = components[m.toolComponent]?.simdTransform ?? matrix_identity_float4x4
        let p = t * SIMD4(Float(m.tipHomeMM.x), Float(m.tipHomeMM.y), Float(m.tipHomeMM.z), 1)
        return SIMD3(Double(p.x), Double(p.y), Double(p.z))
    }

    private func placeGizmo(_ m: AssembleModel) {
        let p = tipNow(m)
        gizmo.simdPosition = SIMD3(Float(p.x), Float(p.y), Float(p.z))
    }

    /// The dashed line from the tip to an unreached target, with a ring at the target.
    private func placeGap(_ m: AssembleModel, target: SIMD3<Double>, short: Double) {
        gapNode.childNodes.forEach { $0.removeFromParentNode() }
        guard short > 0.5, m.tool == .dragTip else { targetNode.isHidden = true; return }
        let a = tipNow(m), b = target
        let len = simd_length(b - a)
        let n = max(2, Int(len / 6))
        let mat = flat(VFPlatformColor(hex: 0x6B7280))
        for i in stride(from: 0, to: n, by: 2) {
            let p0 = a + (b - a) * Double(i) / Double(n), p1 = a + (b - a) * Double(i + 1) / Double(n)
            gapNode.addChildNode(capsule(from: p0, to: p1, radius: 0.9, mat: mat))
        }
        targetNode.isHidden = false
        if targetNode.geometry == nil {
            let s = SCNSphere(radius: 4)
            s.materials = [flat(VFPlatformColor(hex: 0x6B7280))]
            targetNode.geometry = s
        }
        targetNode.simdPosition = SIMD3(Float(b.x), Float(b.y), Float(b.z))
    }

    private func decorateGrasp(_ m: AssembleModel) {
        graspNode.childNodes.forEach { $0.removeFromParentNode() }
        tipNodes = [:]
        normalNodes = [:]
        guard m.product == .hand, m.tool == .grasp, !m.grasp.fingers.isEmpty else { return }
        let g = m.grasp
        let obj: SCNGeometry
        switch g.shape {
        case "sphere": obj = SCNSphere(radius: CGFloat(g.size.x / 2))
        case "box": obj = SCNBox(width: CGFloat(g.size.x), height: CGFloat(g.size.y), length: CGFloat(g.size.z), chamferRadius: 2)
        default: obj = SCNCylinder(radius: CGFloat(g.size.x / 2), height: CGFloat(g.size.y))
        }
        let blue = material(0x2F6BFF, rough: 0.45)
        obj.materials = [blue]
        let o = SCNNode(geometry: obj)
        o.name = "object"
        o.simdTransform = g.shape == "box" ? Self.translation(g.center) : Self.aligned(y: SIMD3(Float(g.axis.x), Float(g.axis.y), Float(g.axis.z)), at: SIMD3(Float(g.center.x), Float(g.center.y), Float(g.center.z)))
        graspNode.addChildNode(o)
        for f in g.fingers {
            let c = Self.fingerColour(f.priority)
            let s = SCNSphere(radius: 5.5)
            s.materials = [flat(c)]
            let n = SCNNode(geometry: s)
            n.name = "tip:" + f.frame
            n.simdPosition = SIMD3(Float(f.point.x), Float(f.point.y), Float(f.point.z))
            n.renderingOrder = 10
            graspNode.addChildNode(n)
            tipNodes[f.frame] = n
            let line = capsule(from: f.point, to: f.point + f.normal * 18, radius: 0.8, mat: flat(c))
            graspNode.addChildNode(line)
            normalNodes[f.frame] = line
        }
    }

    /// Live move of a fingertip target while dragging (the solve follows on release or throttled).
    func moveTip(_ frame: String, to p: SIMD3<Double>, normal: SIMD3<Double>) {
        tipNodes[frame]?.simdPosition = SIMD3(Float(p.x), Float(p.y), Float(p.z))
        if let old = normalNodes[frame], let parent = old.parent {
            old.removeFromParentNode()
            let mat = old.childNodes.first?.geometry?.firstMaterial ?? flat(Self.accent)
            let line = capsule(from: p, to: p + normal * 18, radius: 0.8, mat: mat)
            parent.addChildNode(line)
            normalNodes[frame] = line
        }
    }

    static func fingerColour(_ priority: Int) -> VFPlatformColor {
        switch priority {
        case 1: VFPlatformColor(hex: 0x2F6BFF)
        case 2: VFPlatformColor(hex: 0x2EA44F)
        case 3: VFPlatformColor(hex: 0xE0A000)
        case 4: VFPlatformColor(hex: 0xD93025)
        default: VFPlatformColor(hex: 0x8B3FD9)
        }
    }

    // MARK: Gizmo

    private func buildGizmo() {
        gizmo.name = "gizmo"
        let axes: [(String, SIMD3<Float>, UInt32)] = [("x", SIMD3(1, 0, 0), 0xE5251B), ("y", SIMD3(0, 1, 0), 0x2EA44F), ("z", SIMD3(0, 0, 1), 0x2F6BFF)]
        for (name, dir, hex) in axes {
            let mat = flat(VFPlatformColor(hex: hex))
            let shaft = SCNCylinder(radius: 0.022, height: 0.78)
            shaft.materials = [mat]
            let s = SCNNode(geometry: shaft)
            s.simdTransform = Self.aligned(y: dir, at: dir * 0.39)
            s.name = "gizmo.axis." + name
            let cone = SCNCone(topRadius: 0, bottomRadius: 0.07, height: 0.2)
            cone.materials = [mat]
            let c = SCNNode(geometry: cone)
            c.simdTransform = Self.aligned(y: dir, at: dir * 0.88)
            c.name = "gizmo.axis." + name
            // A fat invisible grip so the arrow is easy to catch.
            let grip = SCNCylinder(radius: 0.09, height: 1.0)
            grip.materials = [flat(.clear)]
            let g = SCNNode(geometry: grip)
            g.simdTransform = Self.aligned(y: dir, at: dir * 0.5)
            g.name = "gizmo.axis." + name
            g.opacity = 0.001
            let torus = SCNTorus(ringRadius: 0.62, pipeRadius: 0.018)
            torus.materials = [flat(VFPlatformColor(hex: hex, alpha: 0.9))]
            let r = SCNNode(geometry: torus)
            r.simdTransform = Self.aligned(y: dir, at: .zero)
            r.name = "gizmo.ring." + name
            for n in [s, c, g, r] { n.renderingOrder = 20; n.geometry?.firstMaterial?.readsFromDepthBuffer = false; gizmo.addChildNode(n) }
        }
        let center = SCNSphere(radius: 0.09)
        center.materials = [flat(VFPlatformColor(white: 1, alpha: 0.95))]
        let cn = SCNNode(geometry: center)
        cn.name = "gizmo.center"
        cn.renderingOrder = 21
        cn.geometry?.firstMaterial?.readsFromDepthBuffer = false
        gizmo.addChildNode(cn)
        gizmo.isHidden = true
    }

    /// Keeps the gizmo about `pixels` long on screen.
    func scaleGizmo(viewHeight: CGFloat, pixels: CGFloat = 92) {
        guard !gizmo.isHidden, let cam = cameraNode.camera else { return }
        let d = simd_distance(cameraNode.simdWorldPosition, gizmo.simdWorldPosition)
        let perPixel = 2 * d * Float(tan(cam.fieldOfView * .pi / 360)) / Float(max(viewHeight, 1))
        let mm = Float(pixels) * perPixel * 1000
        gizmo.simdScale = SIMD3(repeating: mm)
    }

    // MARK: Floor

    private func buildFloor() {
        let grid = SCNNode()
        let mat = flat(VFPlatformColor(hex: 0x9AA3AF, alpha: 0.28))
        for i in -10...10 {
            let v = Double(i) * 50
            grid.addChildNode(capsule(from: SIMD3(v, -500, 0), to: SIMD3(v, 500, 0), radius: i == 0 ? 0.7 : 0.4, mat: mat))
            grid.addChildNode(capsule(from: SIMD3(-500, v, 0), to: SIMD3(500, v, 0), radius: i == 0 ? 0.7 : 0.4, mat: mat))
        }
        grid.name = "floor"
        root.addChildNode(grid)
        floorNode = grid
    }

    private var floorNode: SCNNode?

    func showFloor(_ on: Bool) { floorNode?.isHidden = !on }

    // MARK: Builders

    private func tint(_ n: SCNNode, red: Bool) {
        for c in n.childNodes where !(c.name ?? "").hasPrefix("joint:") && !(c.name ?? "").hasPrefix("jring:") {
            c.geometry?.firstMaterial?.multiply.contents = red ? VFPlatformColor(hex: 0xFF9A93) : VFPlatformColor.white
        }
    }

    private func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, mat: SCNMaterial, chamfer: CGFloat) -> SCNNode {
        let s = hi - lo
        let g = SCNBox(width: CGFloat(s.x), height: CGFloat(s.y), length: CGFloat(s.z), chamferRadius: min(chamfer, CGFloat(min(s.x, s.y, s.z)) / 2.5))
        g.materials = [mat.copy() as? SCNMaterial ?? mat]
        let n = SCNNode(geometry: g)
        n.simdPosition = (lo + hi) / 2
        return n
    }

    private func capsule(from a: SIMD3<Double>, to b: SIMD3<Double>, radius: Double, mat: SCNMaterial) -> SCNNode {
        let d = b - a
        let len = simd_length(d)
        let g = SCNCapsule(capRadius: CGFloat(radius), height: CGFloat(len + 2 * radius))
        g.materials = [mat]
        let n = SCNNode(geometry: g)
        let mid = (a + b) / 2
        n.simdTransform = Self.aligned(y: SIMD3(Float(d.x), Float(d.y), Float(d.z)), at: SIMD3(Float(mid.x), Float(mid.y), Float(mid.z)))
        return n
    }

    private func material(_ hex: UInt32, rough: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = VFPlatformColor(hex: hex)
        m.roughness.contents = rough
        m.metalness.contents = 0.0
        return m
    }

    private func flat(_ c: VFPlatformColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = c
        return m
    }

    static let accent = VFPlatformColor(hex: 0x2F6BFF)

    /// A transform whose local +Y is `dir`, at `p`.
    static func aligned(y dir: SIMD3<Float>, at p: SIMD3<Float>) -> simd_float4x4 {
        let d = simd_length(dir) > 1e-6 ? simd_normalize(dir) : SIMD3(0, 1, 0)
        let q = simd_quatf(from: SIMD3(0, 1, 0), to: d)
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4(p, 1)
        return m
    }

    static func translation(_ p: SIMD3<Double>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(Float(p.x), Float(p.y), Float(p.z), 1)
        return m
    }
}

extension SIMD3 where Scalar == Float {
    init(_ a: [Float]) { self.init(a.count > 0 ? a[0] : 0, a.count > 1 ? a[1] : 0, a.count > 2 ? a[2] : 0) }
}

extension VFPlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
