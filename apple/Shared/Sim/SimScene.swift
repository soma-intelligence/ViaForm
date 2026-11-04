import SceneKit
import SwiftUI
#if os(macOS)
import AppKit
typealias SimColor = NSColor
#else
import UIKit
typealias SimColor = UIColor
#endif

/// The flight in 3D with SceneKit. The simulation is z-up in metres; everything hangs under one
/// root turned a quarter turn about x, so SceneKit's y-up view shows it the right way up and the
/// sim's coordinates go in unchanged.
@MainActor
final class SimScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let root = SCNNode()
    private let courseNode = SCNNode()
    private let drone = SCNNode()
    private var rotors: [SCNNode] = []
    private let trailNode = SCNNode()
    private let raysNode = SCNNode()
    private let targetNode = SCNNode()
    private var builtVersion = -1
    private var trailCount = 0

    init() {
        root.simdEulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(root)
        [courseNode, trailNode, raysNode, targetNode, drone].forEach(root.addChildNode)
        scene.background.contents = SimColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1)

        let camera = SCNCamera()
        camera.zNear = 0.02
        camera.zFar = 400
        camera.fieldOfView = 55
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.light?.castsShadow = true
        sun.simdEulerAngles = SIMD3(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(sun)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 380
        scene.rootNode.addChildNode(fill)

        buildDrone()
        let target = SCNSphere(radius: 0.025)
        target.firstMaterial = material(SimColor(red: 1, green: 0.62, blue: 0.1, alpha: 0.9), emissive: true)
        targetNode.geometry = target
    }

    /// Brings the scene up to date with the model: the course when it changed, then the drone,
    /// its trail, its sensor rays and the planner's target.
    func update(_ model: SimModel) {
        if builtVersion != model.worldVersion, let world = model.world {
            buildCourse(world)
            builtVersion = model.worldVersion
            trailCount = 0
        }
        guard let f = model.frame else { return }
        drone.simdPosition = vec(f.p)
        drone.orientation = SCNQuaternion(Float(f.q[1]), Float(f.q[2]), Float(f.q[3]), Float(f.q[0]))
        let idle = f.omega.allSatisfy { $0 < 600 }
        for (i, r) in rotors.enumerated() where !idle {
            r.simdEulerAngles.z += (i % 2 == 0 ? 1 : -1) * 0.9
        }
        targetNode.simdPosition = vec(f.target)
        if model.trail.count != trailCount {
            trailNode.geometry = polyline(model.trail, color: SimColor(red: 0.35, green: 0.7, blue: 1, alpha: 1))
            trailCount = model.trail.count
        }
        raysNode.geometry = rays(from: f.p, f.rays)
        placeCamera(model, frame: f)
    }

    private func placeCamera(_ model: SimModel, frame f: SimFrame) {
        let p = scenePoint(f.p)
        switch model.camera {
        case .follow:
            // Behind and above the drone along its velocity, eased so turns stay readable.
            let v = SIMD2(f.v[0], f.v[1])
            let dir = simd_length(v) > 0.4 ? simd_normalize(v) : SIMD2(1, 0)
            let want = p + SIMD3(Float(-dir.x) * 1.6, 0.8, Float(dir.y) * 1.6)
            cameraNode.simdPosition = simd_mix(cameraNode.simdPosition, want, SIMD3(repeating: 0.12))
            cameraNode.simdLook(at: p)
        case .overview:
            guard let w = model.world else { return }
            let lo = scenePoint(w.bounds.min), hi = scenePoint(w.bounds.max)
            let c = (lo + hi) / 2
            let span = simd_length(hi - lo)
            cameraNode.simdPosition = c + SIMD3(-span * 0.15, span * 0.55, span * 0.55)
            cameraNode.simdLook(at: SIMD3(c.x, 0, c.z))
        }
    }

    // MARK: Building

    private func buildDrone() {
        let carbon = material(SimColor(white: 0.12, alpha: 1))
        let plate = SCNBox(width: 0.06, height: 0.04, length: 0.012, chamferRadius: 0.004)
        plate.firstMaterial = carbon
        drone.addChildNode(SCNNode(geometry: plate))
        let battery = SCNBox(width: 0.055, height: 0.03, length: 0.017, chamferRadius: 0.003)
        battery.firstMaterial = material(SimColor(red: 0.85, green: 0.25, blue: 0.2, alpha: 1))
        let batteryNode = SCNNode(geometry: battery)
        batteryNode.simdPosition.z = 0.015
        drone.addChildNode(batteryNode)
        // Arms and rotors at the motor angles the physics uses (-45, 45, 135, -135 degrees).
        let arm = 0.0602
        for (i, deg) in [-45.0, 45, 135, -135].enumerated() {
            let a = deg * .pi / 180
            let tip = SIMD3(Float(cos(a) * arm), Float(sin(a) * arm), 0)
            let bar = SCNBox(width: CGFloat(arm), height: 0.008, length: 0.004, chamferRadius: 0.001)
            bar.firstMaterial = carbon
            let barNode = SCNNode(geometry: bar)
            barNode.simdPosition = tip / 2
            barNode.simdEulerAngles.z = Float(a)
            drone.addChildNode(barNode)
            let disc = SCNCylinder(radius: 0.0381, height: 0.002)
            disc.firstMaterial = material(i < 2 ? SimColor(red: 0.3, green: 0.75, blue: 1, alpha: 0.55) : SimColor(white: 0.85, alpha: 0.5))
            let rotor = SCNNode(geometry: disc)
            rotor.simdEulerAngles.x = .pi / 2
            let hub = SCNNode()
            hub.simdPosition = tip + SIMD3(0, 0, 0.012)
            hub.addChildNode(rotor)
            drone.addChildNode(hub)
            rotors.append(hub)
        }
    }

    private func buildCourse(_ world: SimWorld) {
        courseNode.childNodes.forEach { $0.removeFromParentNode() }
        // Ground with a one-metre grid.
        let lo = world.bounds.min, hi = world.bounds.max
        let ground = SCNBox(width: hi[0] - lo[0] + 10, height: hi[1] - lo[1] + 10, length: 0.02, chamferRadius: 0)
        ground.firstMaterial = material(SimColor(red: 0.19, green: 0.21, blue: 0.23, alpha: 1))
        let groundNode = SCNNode(geometry: ground)
        groundNode.simdPosition = SIMD3(Float(lo[0] + hi[0]) / 2, Float(lo[1] + hi[1]) / 2, -0.011)
        courseNode.addChildNode(groundNode)
        courseNode.addChildNode(grid(lo: lo, hi: hi))

        for o in world.obstacles {
            let color = SimColor(hex: o.color)
            if o.kind == "box", let mn = o.min, let mx = o.max {
                let box = SCNBox(width: mx[0] - mn[0], height: mx[1] - mn[1], length: mx[2] - mn[2], chamferRadius: 0.005)
                box.firstMaterial = material(color)
                let n = SCNNode(geometry: box)
                n.simdPosition = (vec(mn) + vec(mx)) / 2
                courseNode.addChildNode(n)
            } else if let c = o.c, let r = o.r, let z0 = o.z0, let z1 = o.z1 {
                let post = SCNCylinder(radius: r, height: z1 - z0)
                post.firstMaterial = material(color)
                let n = SCNNode(geometry: post)
                n.simdEulerAngles.x = .pi / 2
                n.simdPosition = SIMD3(Float(c[0]), Float(c[1]), Float(z0 + z1) / 2)
                courseNode.addChildNode(n)
            }
        }
        for (i, w) in world.waypoints.enumerated() {
            let last = i == world.waypoints.count - 1
            let dot = last ? SCNCylinder(radius: 0.45, height: 0.01) : SCNSphere(radius: 0.05)
            dot.firstMaterial = material(last ? SimColor(red: 0.2, green: 0.8, blue: 0.45, alpha: 1) : SimColor(white: 1, alpha: 0.5), emissive: !last)
            let n = SCNNode(geometry: dot)
            if last { n.simdEulerAngles.x = .pi / 2 }
            n.simdPosition = vec(w)
            courseNode.addChildNode(n)
        }
        let route = SCNNode(geometry: polyline(world.waypoints, color: SimColor(white: 1, alpha: 0.22)))
        courseNode.addChildNode(route)
    }

    private func grid(lo: [Double], hi: [Double]) -> SCNNode {
        var pts: [SIMD3<Float>] = []
        let x0 = floor(lo[0]) - 4, x1 = ceil(hi[0]) + 4, y0 = floor(lo[1]) - 4, y1 = ceil(hi[1]) + 4
        var x = x0
        while x <= x1 { pts += [SIMD3(Float(x), Float(y0), 0.001), SIMD3(Float(x), Float(y1), 0.001)]; x += 1 }
        var y = y0
        while y <= y1 { pts += [SIMD3(Float(x0), Float(y), 0.001), SIMD3(Float(x1), Float(y), 0.001)]; y += 1 }
        return SCNNode(geometry: lines(pts, color: SimColor(white: 1, alpha: 0.07)))
    }

    private func rays(from p: [Double], _ rays: [SimFrame.Ray]) -> SCNGeometry? {
        guard !rays.isEmpty else { return nil }
        let o = vec(p)
        let hits = rays.filter(\.hit)
        guard !hits.isEmpty else { return nil }
        return lines(hits.flatMap { [o, vec($0.point)] }, color: SimColor(red: 1, green: 0.35, blue: 0.3, alpha: 0.85))
    }

    private func polyline(_ points: [[Double]], color: SimColor) -> SCNGeometry? {
        guard points.count > 1 else { return nil }
        var pts: [SIMD3<Float>] = []
        for i in 1..<points.count { pts += [vec(points[i - 1]), vec(points[i])] }
        return lines(pts, color: color)
    }

    private func lines(_ pts: [SIMD3<Float>], color: SimColor) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: pts.map { SCNVector3($0) })
        let element = SCNGeometryElement(indices: Array(0..<Int32(pts.count)), primitiveType: .line)
        let g = SCNGeometry(sources: [source], elements: [element])
        g.firstMaterial = material(color, emissive: true)
        return g
    }

    private func material(_ color: SimColor, emissive: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = emissive ? .constant : .physicallyBased
        m.roughness.contents = 0.7
        m.metalness.contents = 0.05
        if color.cgColor.alpha < 1 { m.transparency = color.cgColor.alpha; m.blendMode = .alpha }
        return m
    }

    private func vec(_ a: [Double]) -> SIMD3<Float> { SIMD3(Float(a[0]), Float(a[1]), Float(a[2])) }
    /// A sim point in SceneKit's world (y-up), for the camera.
    private func scenePoint(_ a: [Double]) -> SIMD3<Float> { SIMD3(Float(a[0]), Float(a[2]), Float(-a[1])) }
}

extension SimColor {
    /// `#rrggbb`, grey when it does not parse.
    convenience init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0x8b93a1
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
