import CoreGraphics
import simd

/// What a click or a tap lands on. Engine commands take world points as references (a point on a
/// face, a point on an edge), so a pick carries the point it hit.
enum Pick: Equatable {
    case face(mesh: Int, face: UInt32, point: SIMD3<Double>, normal: SIMD3<Double>)
    case edge(mesh: Int, edge: Int, point: SIMD3<Double>)

    var point: SIMD3<Double> {
        switch self {
        case let .face(_, _, p, _), let .edge(_, _, p): p
        }
    }

    var mesh: Int {
        switch self {
        case let .face(m, _, _, _), let .edge(m, _, _): m
        }
    }

    var isEdge: Bool { if case .edge = self { true } else { false } }
    var isFace: Bool { if case .face = self { true } else { false } }

    /// Same entity (face or edge), wherever on it the pick landed.
    func sameEntity(_ o: Pick) -> Bool {
        switch (self, o) {
        case let (.face(a, f, _, _), .face(b, g, _, _)): a == b && f == g
        case let (.edge(a, e, _), .edge(b, f, _)): a == b && e == f
        default: false
        }
    }

    var points: [Double] { [point.x, point.y, point.z] }
}

enum ScenePicker {
    /// Edges win within `edgeTolerance` points of the cursor; otherwise the nearest face.
    static func pick(_ scene: SceneData, camera: OrbitCamera, at p: CGPoint, size: CGSize, edgeTolerance: CGFloat = 7, edges: Bool = true) -> Pick? {
        let face = pickFace(scene, camera: camera, at: p, size: size)
        if edges, let e = pickEdge(scene, camera: camera, at: p, size: size, tolerance: edgeTolerance) {
            // An edge hidden behind the hit face does not count.
            if let f = face {
                let eye = camera.eye
                if simd_distance(e.point, eye) > simd_distance(f.point, eye) + max(camera.halfHeight * 0.02, 0.05) {
                    return f
                }
            }
            return e
        }
        return face
    }

    static func pickFace(_ scene: SceneData, camera: OrbitCamera, at p: CGPoint, size: CGSize) -> Pick? {
        let (o, d) = camera.ray(at: p, size: size)
        var best: (t: Double, pick: Pick)?
        for (mi, m) in scene.meshes.enumerated() {
            let idx = m.indices
            var t = 0
            while t + 2 < idx.count {
                let a = SIMD3<Double>(m.positions[Int(idx[t])]), b = SIMD3<Double>(m.positions[Int(idx[t + 1])]), c = SIMD3<Double>(m.positions[Int(idx[t + 2])])
                if let hit = intersect(o, d, a, b, c), hit > 0, hit < (best?.t ?? .infinity) {
                    var n = simd_cross(b - a, c - a)
                    n = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 0, 1)
                    let face = m.triFace.indices.contains(t / 3) ? m.triFace[t / 3] : 0
                    best = (hit, .face(mesh: mi, face: face, point: o + d * hit, normal: n))
                }
                t += 3
            }
        }
        return best?.pick
    }

    static func pickEdge(_ scene: SceneData, camera: OrbitCamera, at p: CGPoint, size: CGSize, tolerance: CGFloat) -> Pick? {
        var best: (dist: CGFloat, pick: Pick)?
        for (mi, m) in scene.meshes.enumerated() {
            for (ei, e) in m.edges.enumerated() where e.count > 1 {
                for i in 0..<(e.count - 1) {
                    let a = SIMD3<Double>(e[i]), b = SIMD3<Double>(e[i + 1])
                    let sa = camera.project(a, size: size), sb = camera.project(b, size: size)
                    let (dist, s) = segmentDistance(p, sa, sb)
                    if dist < tolerance, dist < (best?.dist ?? .infinity) {
                        best = (dist, .edge(mesh: mi, edge: ei, point: a + (b - a) * Double(s)))
                    }
                }
            }
        }
        // A point mid-edge is the most robust reference for the engine.
        if case let .edge(mi, ei, _)? = best?.pick {
            let e = scene.meshes[mi].edges[ei]
            return .edge(mesh: mi, edge: ei, point: midpoint(e))
        }
        return best?.pick
    }

    static func midpoint(_ e: [SIMD3<Float>]) -> SIMD3<Double> {
        guard e.count > 1 else { return e.first.map(SIMD3<Double>.init) ?? .zero }
        var total = 0.0
        for i in 0..<(e.count - 1) { total += Double(simd_distance(e[i], e[i + 1])) }
        var walked = 0.0
        for i in 0..<(e.count - 1) {
            let l = Double(simd_distance(e[i], e[i + 1]))
            if walked + l >= total / 2, l > 0 {
                let s = (total / 2 - walked) / l
                return SIMD3<Double>(e[i]) + (SIMD3<Double>(e[i + 1]) - SIMD3<Double>(e[i])) * s
            }
            walked += l
        }
        return SIMD3<Double>(e[e.count / 2])
    }

    /// Ray and sketch plane.
    static func onPlane(_ plane: SketchPlane, camera: OrbitCamera, at p: CGPoint, size: CGSize) -> SIMD2<Double>? {
        let (o, d) = camera.ray(at: p, size: size)
        let n = plane.normal
        let den = simd_dot(d, n)
        guard abs(den) > 1e-9 else { return nil }
        let t = simd_dot(plane.origin - o, n) / den
        return plane.toSketch(o + d * t)
    }

    private static func intersect(_ o: SIMD3<Double>, _ d: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double? {
        let e1 = b - a, e2 = c - a
        let h = simd_cross(d, e2)
        let det = simd_dot(e1, h)
        if abs(det) < 1e-12 { return nil }
        let f = 1 / det
        let s = o - a
        let u = f * simd_dot(s, h)
        if u < 0 || u > 1 { return nil }
        let q = simd_cross(s, e1)
        let v = f * simd_dot(d, q)
        if v < 0 || u + v > 1 { return nil }
        return f * simd_dot(e2, q)
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGFloat, CGFloat) {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let l2 = ab.x * ab.x + ab.y * ab.y
        var s = l2 > 0 ? ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2 : 0
        s = min(max(s, 0), 1)
        let q = CGPoint(x: a.x + ab.x * s, y: a.y + ab.y * s)
        return (hypot(p.x - q.x, p.y - q.y), s)
    }
}
