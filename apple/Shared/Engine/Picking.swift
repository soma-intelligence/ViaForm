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

    /// The same face or edge in `scene`, found again by the point the pick landed on. A pick
    /// names a face or edge by its index in the scene it was made on; a preview or a rebuild
    /// renumbers them, and the old index then names another face or edge (a chamfer preview
    /// lit a different edge). Nil when the point is on no face or edge any more (the preview
    /// rounded that edge away).
    func resolved(in scene: SceneData) -> Pick? {
        let tol = Float(max(0.005, Double(scene.radius) * 1e-5))
        let q = SIMD3<Float>(point)
        switch self {
        case let .edge(m, e, p):
            func near(_ line: [SIMD3<Float>]) -> Bool {
                guard line.count > 1 else { return false }
                for i in 0..<(line.count - 1) where Self.distance(q, line[i], line[i + 1]) <= tol { return true }
                return false
            }
            if m < scene.meshes.count, e < scene.meshes[m].edges.count, near(scene.meshes[m].edges[e]) { return self }
            for (mi, mesh) in scene.meshes.enumerated() {
                if let ei = mesh.edges.firstIndex(where: near) { return .edge(mesh: mi, edge: ei, point: p) }
            }
            return nil
        case let .face(m, f, p, n):
            func faceAt(_ mesh: SceneData.Mesh, only: UInt32?) -> UInt32? {
                guard q.x >= mesh.lo.x - tol, q.y >= mesh.lo.y - tol, q.z >= mesh.lo.z - tol,
                      q.x <= mesh.hi.x + tol, q.y <= mesh.hi.y + tol, q.z <= mesh.hi.z + tol else { return nil }
                for t in 0..<min(mesh.triFace.count, mesh.indices.count / 3) {
                    if let only, mesh.triFace[t] != only { continue }
                    let a = mesh.positions[Int(mesh.indices[3 * t])]
                    let b = mesh.positions[Int(mesh.indices[3 * t + 1])]
                    let c = mesh.positions[Int(mesh.indices[3 * t + 2])]
                    if Self.onTriangle(q, a, b, c, tol: tol) { return mesh.triFace[t] }
                }
                return nil
            }
            if m < scene.meshes.count, faceAt(scene.meshes[m], only: f) != nil { return self }
            for (mi, mesh) in scene.meshes.enumerated() {
                if let g = faceAt(mesh, only: nil) { return .face(mesh: mi, face: g, point: p, normal: n) }
            }
            return nil
        }
    }

    /// Distance from `p` to the segment `a`-`b`.
    private static func distance(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let l = simd_length_squared(ab)
        let t = l > 0 ? simd_clamp(simd_dot(p - a, ab) / l, 0, 1) : 0
        return simd_distance(p, a + ab * t)
    }

    /// `p` lies on the triangle, within `tol` of its plane and inside its edges.
    private static func onTriangle(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, tol: Float) -> Bool {
        let n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        guard len > 0 else { return false }
        let u = n / len
        guard abs(simd_dot(p - a, u)) <= tol else { return false }
        // Inside, or within tol of an edge (a point picked right on a face's border).
        let inside = simd_dot(simd_cross(b - a, p - a), u) >= 0 && simd_dot(simd_cross(c - b, p - b), u) >= 0 && simd_dot(simd_cross(a - c, p - c), u) >= 0
        return inside || distance(p, a, b) <= tol || distance(p, b, c) <= tol || distance(p, c, a) <= tol
    }
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
        let inv = SIMD3<Double>(1 / d.x, 1 / d.y, 1 / d.z)
        var best: (t: Double, pick: Pick)?
        for (mi, m) in scene.meshes.enumerated() {
            // A body whose box the ray misses, or meets beyond the best hit, has no closer face.
            if m.lo.x <= m.hi.x {
                guard let near = slab(o, inv, SIMD3<Double>(m.lo), SIMD3<Double>(m.hi)), near <= (best?.t ?? .infinity) else { continue }
            }
            m.positions.withUnsafeBufferPointer { pos in
                m.indices.withUnsafeBufferPointer { idx in
                    var t = 0
                    while t + 2 < idx.count {
                        let ia = Int(idx[t]), ib = Int(idx[t + 1]), ic = Int(idx[t + 2])
                        if ia < pos.count, ib < pos.count, ic < pos.count {
                            let a = SIMD3<Double>(pos[ia]), b = SIMD3<Double>(pos[ib]), c = SIMD3<Double>(pos[ic])
                            if let hit = intersect(o, d, a, b, c), hit > 0, hit < (best?.t ?? .infinity) {
                                var n = simd_cross(b - a, c - a)
                                n = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 0, 1)
                                let face = m.triFace.indices.contains(t / 3) ? m.triFace[t / 3] : 0
                                best = (hit, .face(mesh: mi, face: face, point: o + d * hit, normal: n))
                            }
                        }
                        t += 3
                    }
                }
            }
        }
        return best?.pick
    }

    /// Every face the ray through `p` meets (the nearest hit of each), nearest first: what
    /// lies under the pointer for the pick list (M-9).
    static func faceHits(_ scene: SceneData, camera: OrbitCamera, at p: CGPoint, size: CGSize) -> [Pick] {
        let (o, d) = camera.ray(at: p, size: size)
        var best: [SIMD2<Int>: (t: Double, pick: Pick)] = [:]
        for (mi, m) in scene.meshes.enumerated() {
            var t = 0
            while t + 2 < m.indices.count {
                defer { t += 3 }
                let ia = Int(m.indices[t]), ib = Int(m.indices[t + 1]), ic = Int(m.indices[t + 2])
                guard ia < m.positions.count, ib < m.positions.count, ic < m.positions.count else { continue }
                let a = SIMD3<Double>(m.positions[ia]), b = SIMD3<Double>(m.positions[ib]), c = SIMD3<Double>(m.positions[ic])
                guard let hit = intersect(o, d, a, b, c), hit > 0 else { continue }
                let face = m.triFace.indices.contains(t / 3) ? m.triFace[t / 3] : 0
                let key = SIMD2(mi, Int(face))
                if let old = best[key], old.t <= hit { continue }
                var n = simd_cross(b - a, c - a)
                n = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 0, 1)
                best[key] = (hit, .face(mesh: mi, face: face, point: o + d * hit, normal: n))
            }
        }
        return best.values.sorted { $0.t < $1.t }.map(\.pick)
    }

    /// Every edge within `tolerance` points of `p`, nearest first (hidden ones too).
    static func edgeHits(_ scene: SceneData, camera: OrbitCamera, at p: CGPoint, size: CGSize, tolerance: CGFloat) -> [Pick] {
        let project = Projector(camera, size: size)
        var out: [(d: CGFloat, pick: Pick)] = []
        for (mi, m) in scene.meshes.enumerated() {
            for (ei, e) in m.edges.enumerated() where e.count > 1 {
                var near = CGFloat.infinity
                var sa = project(SIMD3<Double>(e[0])).0
                for i in 1..<e.count {
                    let sb = project(SIMD3<Double>(e[i])).0
                    near = min(near, segmentDistance(p, sa, sb).0)
                    sa = sb
                }
                if near <= tolerance { out.append((near, .edge(mesh: mi, edge: ei, point: midpoint(e)))) }
            }
        }
        return out.sorted { $0.d < $1.d }.map(\.pick)
    }

    /// Where a ray enters a box (0 when it starts inside), or nil when it misses it.
    private static func slab(_ o: SIMD3<Double>, _ inv: SIMD3<Double>, _ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> Double? {
        let pad = simd_reduce_max(hi - lo) * 1e-4 + 1e-6
        let t1 = (lo - pad - o) * inv, t2 = (hi + pad - o) * inv
        let tmin = simd_reduce_max(simd_min(t1, t2)), tmax = simd_reduce_min(simd_max(t1, t2))
        // NaN (a zero direction component on a slab face) keeps the box: never a wrong miss.
        if tmin.isNaN || tmax.isNaN { return 0 }
        guard tmax >= max(tmin, 0) else { return nil }
        return max(tmin, 0)
    }

    /// `OrbitCamera.project` with the camera's basis worked out once, for many points.
    private struct Projector {
        let r, u, b, eye: SIMD3<Double>
        let perspective: Bool
        let distance, sx, sy, w, h: Double

        init(_ c: OrbitCamera, size: CGSize) {
            (r, u, b) = c.basis
            eye = c.eye
            perspective = c.fov > 0
            distance = c.distance
            let aspect = Double(size.width / max(size.height, 1))
            sx = c.halfHeight * aspect
            sy = c.halfHeight
            w = Double(size.width)
            h = Double(size.height)
        }

        /// Screen point and depth along the view.
        func callAsFunction(_ p: SIMD3<Double>) -> (CGPoint, Double) {
            let d = p - eye
            var x = simd_dot(d, r), y = simd_dot(d, u)
            let z = -simd_dot(d, b)
            if perspective {
                let s = distance / max(z, 1e-6)
                x *= s; y *= s
            }
            return (CGPoint(x: (x / sx + 1) / 2 * w, y: (1 - y / sy) / 2 * h), z)
        }
    }

    static func pickEdge(_ scene: SceneData, camera: OrbitCamera, at p: CGPoint, size: CGSize, tolerance: CGFloat) -> Pick? {
        let project = Projector(camera, size: size)
        var best: (dist: CGFloat, pick: Pick)?
        for (mi, m) in scene.meshes.enumerated() where !m.edges.isEmpty {
            // Skip a body whose box, on screen, is farther than the tolerance from the cursor.
            // In perspective a corner behind the eye makes the box unbounded on screen: kept.
            if m.lo.x <= m.hi.x {
                var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
                var behind = false
                for k in 0..<8 {
                    let c = SIMD3<Double>(Double(k & 1 == 0 ? m.lo.x : m.hi.x), Double(k & 2 == 0 ? m.lo.y : m.hi.y), Double(k & 4 == 0 ? m.lo.z : m.hi.z))
                    let (q, z) = project(c)
                    if project.perspective, z <= 1e-6 { behind = true; break }
                    minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y)
                }
                if !behind, p.x < minX - tolerance || p.x > maxX + tolerance || p.y < minY - tolerance || p.y > maxY + tolerance { continue }
            }
            for (ei, e) in m.edges.enumerated() where e.count > 1 {
                var sa = project(SIMD3<Double>(e[0])).0
                for i in 0..<(e.count - 1) {
                    let a = SIMD3<Double>(e[i]), b = SIMD3<Double>(e[i + 1])
                    let sb = project(b).0
                    let (dist, s) = segmentDistance(p, sa, sb)
                    if dist < tolerance, dist < (best?.dist ?? .infinity) {
                        best = (dist, .edge(mesh: mi, edge: ei, point: a + (b - a) * Double(s)))
                    }
                    sa = sb
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

// MARK: Sketch entities (B-1)

/// Where each constraint glyph of an open sketch sits on screen: beside its engine anchor, and
/// glyphs that share an anchor laid side by side. Drawing and picking both read this, so a glyph
/// is picked exactly where it is drawn.
enum SketchGlyphLayout {
    /// The glyph square, in points.
    static let side: CGFloat = 16
    private static let gap: CGFloat = 2
    /// How far the first glyph sits from its anchor (up and to the right), in points.
    private static let offset = CGSize(width: 10, height: -10)

    static func spots(_ info: SketchInfo, camera: OrbitCamera, size: CGSize) -> [(glyph: SketchInfo.Glyph, at: CGPoint)] {
        var used: [SIMD2<Int>: Int] = [:]
        return info.glyphs.map { g in
            let a = camera.project(info.plane.toWorld(g.at), size: size)
            let cell = SIMD2(Int((a.x / 6).rounded()), Int((a.y / 6).rounded()))
            let n = used[cell, default: 0]
            used[cell] = n + 1
            return (g, CGPoint(x: a.x + offset.width + CGFloat(n) * (side + gap), y: a.y + offset.height))
        }
    }
}

/// 2D hit test on the open sketch, in screen space: a constraint glyph first, then a point,
/// then the nearest curve.
enum SketchPicker {
    static func pick(_ info: SketchInfo, camera: OrbitCamera, at p: CGPoint, size: CGSize,
                     glyphs: Bool, pointRadius: CGFloat = 8, curveTolerance: CGFloat = 6) -> SketchPick? {
        if glyphs {
            let half = SketchGlyphLayout.side / 2 + 1
            if let hit = SketchGlyphLayout.spots(info, camera: camera, size: size)
                .first(where: { abs($0.at.x - p.x) <= half && abs($0.at.y - p.y) <= half }) {
                return SketchPick(id: hit.glyph.id, kind: .constraint)
            }
        }
        if let pt = point(info, camera: camera, at: p, size: size, radius: pointRadius) {
            return SketchPick(id: pt.id, kind: .point)
        }
        var best: (d: CGFloat, c: SketchInfo.Curve)?
        for c in info.curves {
            let s = c.polyline.map { camera.project(info.plane.toWorld($0), size: size) }
            for i in 1..<s.count {
                let d = distance(p, s[i - 1], s[i])
                if d <= curveTolerance, d < (best?.d ?? .infinity) { best = (d, c) }
            }
        }
        return best.map { SketchPick(id: $0.c.id, kind: SketchPick.Kind(curveType: $0.c.kind)) }
    }

    /// The sketch point nearest `p` on screen within `radius` points.
    static func point(_ info: SketchInfo, camera: OrbitCamera, at p: CGPoint, size: CGSize, radius: CGFloat) -> SketchInfo.Point? {
        var best: (d: CGFloat, p: SketchInfo.Point)?
        for q in info.points {
            let s = camera.project(info.plane.toWorld(q.at), size: size)
            let d = hypot(s.x - p.x, s.y - p.y)
            if d <= radius, d < (best?.d ?? .infinity) { best = (d, q) }
        }
        return best?.p
    }

    /// Distance from `p` to the segment `a` `b`.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
