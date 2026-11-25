import CoreGraphics
import Foundation
import simd

// Selection modes on the canvas (gaps M-8, M-9, M-10, M-16 chain select, T-7, T-8, T-11).
//
// Public API (the Mac and iPad surfaces code against these names):
//
//   enum SelectionFilter { case auto, body, face, edge, sketch }
//                                            what a click picks with Select. `title` and
//                                            `symbol` for a menu or segmented control.
//   model.selectionFilter                    the current filter (persisted). Auto picks edges
//                                            near the pointer, else faces, else sketch entities
//                                            in an open sketch; Body picks whole bodies.
//   model.boxSelect(_ rect: CGRect, crossing: Bool, size: CGSize)
//                                            selects what the box (viewport points) holds:
//                                            window (crossing false) takes items wholly inside,
//                                            crossing takes items it touches. In an open sketch it
//                                            selects sketch points and curves; otherwise bodies
//                                            (Auto, Body), faces or edges, by the filter.
//                                            `additive: true` adds to the selection.
//   model.selectionBox: SelectionBox?        the box being dragged (the viewport draws it);
//                                            `SelectionBox.crossing(from:to:)` reads the
//                                            direction rule (right to left = crossing).
//   model.pickCandidates(at: CGPoint, size: CGSize) -> [PickCandidate]
//                                            everything under the point, nearest first: sketch
//                                            entities, edges, faces along the ray, their bodies.
//   struct PickCandidate { id, label, kind }  kind is the SelectionFilter the item belongs to.
//   model.choose(_ candidate: PickCandidate) selects it (replacing the selection).
//   model.openPickList(at:) / model.pickList the press-and-hold pick list the viewport shows.
//   model.owningFeature(ofFace: Pick) -> (feature: String, sketch: Int?)?
//                                            the feature that made a picked face (its name, as
//                                            `timeline.inspect` and `FeatureSession.beginEdit`
//                                            take it) and the sketch it was built from, read
//                                            from the face's persistent name (`model.faces`).
//   model.editSketch(_ id: Int)              opens a finished sketch for editing (`sketch.edit`).
//   model.trimDrag(path: [CGPoint], size: CGSize)
//                                            M-16 trim along a drawn path (SketchDrawing.swift).
//   model.chainSelect(at:) -> Bool           M-16: a double click on a sketch curve selects the
//                                            chain it is part of (`sketch.chain`).
//   model.faceDoubleTap(at:)                 T-7: a double tap on a planar face with nothing armed
//                                            starts a sketch on it; elsewhere it selects the body.
//   model.profileTap(at:) -> Bool            T-8: a tap on a closed profile of a finished sketch
//                                            with Select starts Extrude on that profile.

/// What a click picks with Select (M-9).
enum SelectionFilter: String, CaseIterable, Identifiable, Sendable {
    case auto, body, face, edge, sketch

    static let storageKey = "viaform.selection.filter"
    static var stored: SelectionFilter { SelectionFilter(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .body: String(localized: "Bodies")
        case .face: String(localized: "Faces")
        case .edge: String(localized: "Edges")
        case .sketch: String(localized: "Sketch")
        }
    }

    var symbol: String {
        switch self {
        case .auto: "cursorarrow.rays"
        case .body: "cube"
        case .face: "square.fill.on.square"
        case .edge: "line.diagonal"
        case .sketch: "pencil.line"
        }
    }
}

/// A selection box being dragged on the canvas, in viewport points.
struct SelectionBox: Equatable {
    var rect: CGRect
    /// Right to left: crossing (takes what it touches); left to right: window (what is inside).
    var crossing: Bool

    static func from(_ a: CGPoint, to b: CGPoint) -> SelectionBox {
        SelectionBox(rect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)), crossing: b.x < a.x)
    }
}

/// One item under the pointer, for the pick list.
struct PickCandidate: Identifiable, Equatable {
    enum Target: Equatable {
        case body(String)
        case entity(Pick)
        case sketch(SketchPick)
    }

    let id: String
    let label: String
    let kind: SelectionFilter
    let target: Target
}

/// The pick list open on the canvas.
struct PickList: Equatable {
    var at: CGPoint
    var items: [PickCandidate]
}

extension DesignModel {
    // MARK: Filter (M-9)

    /// The 3D pick under `p` as the filter allows it (Select).
    func filteredPick(at p: CGPoint) -> Pick? {
        switch selectionFilter {
        case .auto: return ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: wantsEdges)
        case .face, .body: return ScenePicker.pickFace(scene, camera: camera, at: p, size: viewSize)
        case .edge:
            let h = ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: true)
            return h?.isEdge == true ? h : nil
        case .sketch: return nil
        }
    }

    /// The Body filter: a click selects the body of the face it lands on.
    func selectBody(of hit: Pick?, mode: SelectMode) {
        guard let hit, hit.mesh < scene.meshes.count else {
            if mode == .replace { selectedBodies = []; selection = [] }
            return
        }
        let name = scene.meshes[hit.mesh].body
        switch mode {
        case .replace: selectedBodies = [name]
        case .add: selectedBodies.insert(name)
        case .toggle: if selectedBodies.contains(name) { selectedBodies.remove(name) } else { selectedBodies.insert(name) }
        }
        if !selection.isEmpty { selection = [] }
    }

    // MARK: One selection space

    /// Replaces the whole selection with 3D picks and bodies: the sketch selection goes.
    func replaceSelection(_ picks: [Pick] = [], bodies: Set<String> = []) {
        if !sketchSelection.isEmpty { sketchSelection = [] }
        selection = picks
        selectedBodies = bodies
    }

    /// Replaces the whole selection with sketch picks: faces, edges and bodies go.
    func replaceSelection(sketch picks: [SketchPick]) {
        if !selection.isEmpty { selection = [] }
        if !selectedBodies.isEmpty { selectedBodies = [] }
        sketchSelection = picks
    }

    /// Nothing selectable under `p` (where a drag draws a selection box). `grab` is the radius a
    /// drag from `p` would grab a sketch point within (a Pencil's is wider than the pick's).
    func emptyCanvas(at p: CGPoint, grab: CGFloat? = nil) -> Bool {
        if sketchOpen, let info = sketchInfo {
            let r = sketchPickRadii
            if SketchPicker.pick(info, camera: camera, at: p, size: viewSize, glyphs: showConstraints,
                                 pointRadius: r.point, curveTolerance: r.curve) != nil { return false }
            if let grab, sketchPointGrabbable(at: p, radius: grab) { return false }
        }
        return ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: true) == nil
    }

    /// A press at `p` would drag a sketch point (within `radius`): `beginSketchDrag` would take
    /// it. Reads only; the drag does not start.
    func sketchPointGrabbable(at p: CGPoint, radius: CGFloat) -> Bool {
        guard sketchOpen, tool == .select, symmetryPending == nil, let info = sketchInfo,
              let pt = SketchPicker.point(info, camera: camera, at: p, size: viewSize, radius: radius) else { return false }
        return !pt.fixed
    }

    // MARK: Box selection (M-8, T-11)

    func boxSelect(_ rect: CGRect, crossing: Bool, size: CGSize, additive: Bool = false) {
        selectionBox = nil
        let r = rect.standardized
        guard r.width > 0 || r.height > 0 else { return }
        func takes(_ pts: [CGPoint]) -> Bool {
            guard !pts.isEmpty else { return false }
            if !crossing { return pts.allSatisfy { r.contains($0) } }
            if pts.contains(where: { r.contains($0) }) { return true }
            for i in 1..<max(pts.count, 1) where Self.segment(pts[i - 1], pts[i], hits: r) { return true }
            return false
        }
        if sketchOpen, let info = sketchInfo, selectionFilter == .auto || selectionFilter == .sketch {
            func s(_ q: SIMD2<Double>) -> CGPoint { camera.project(info.plane.toWorld(q), size: size) }
            var picks: [SketchPick] = additive ? sketchSelection : []
            for c in info.curves where takes(c.polyline.map(s)) {
                let k = SketchPick(id: c.id, kind: SketchPick.Kind(curveType: c.kind))
                if !picks.contains(k) { picks.append(k) }
            }
            for q in info.points where r.contains(s(q.at)) && q.id != "origin" {
                let k = SketchPick(id: q.id, kind: .point)
                if !picks.contains(k) { picks.append(k) }
            }
            replaceSelection(sketch: picks)
            return
        }
        if selectionFilter == .sketch { return }
        if !additive, !sketchSelection.isEmpty { sketchSelection = [] }
        func project(_ v: SIMD3<Float>) -> CGPoint { camera.project(SIMD3<Double>(v), size: size) }
        switch selectionFilter {
        case .face:
            var picks: [Pick] = additive ? selection : []
            for (mi, m) in scene.meshes.enumerated() {
                let screen = m.positions.map(project)
                var byFace: [UInt32: [Int]] = [:]
                var t = 0
                while t + 2 < m.indices.count {
                    byFace[m.triFace.indices.contains(t / 3) ? m.triFace[t / 3] : 0, default: []].append(t)
                    t += 3
                }
                for (f, tris) in byFace.sorted(by: { $0.key < $1.key }) {
                    let corners = tris.flatMap { t in (0..<3).map { screen[Int(m.indices[t + $0])] } }
                    let hit = crossing
                        ? tris.contains { t in takes((0..<4).map { screen[Int(m.indices[t + $0 % 3])] }) || Self.triangle(t, m, screen, contains: CGPoint(x: r.midX, y: r.midY)) }
                        : takes(corners)
                    guard hit, let t0 = tris.first else { continue }
                    let a = m.positions[Int(m.indices[t0])], b = m.positions[Int(m.indices[t0 + 1])], c = m.positions[Int(m.indices[t0 + 2])]
                    var n = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
                    n = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 0, 1)
                    let pick = Pick.face(mesh: mi, face: f, point: SIMD3<Double>((a + b + c) / 3), normal: n)
                    if !picks.contains(where: { $0.sameEntity(pick) }) { picks.append(pick) }
                }
            }
            selection = picks
            if !additive { selectedBodies = [] }
        case .edge:
            var picks: [Pick] = additive ? selection : []
            for (mi, m) in scene.meshes.enumerated() {
                for (ei, e) in m.edges.enumerated() where e.count > 1 && takes(e.map(project)) {
                    let pick = Pick.edge(mesh: mi, edge: ei, point: ScenePicker.midpoint(e))
                    if !picks.contains(where: { $0.sameEntity(pick) }) { picks.append(pick) }
                }
            }
            selection = picks
            if !additive { selectedBodies = [] }
        case .auto, .body, .sketch:
            var bodies: Set<String> = additive ? selectedBodies : []
            for m in scene.meshes where !m.positions.isEmpty {
                let screen = m.positions.map(project)
                var hit = takes(screen)
                if crossing, !hit {
                    hit = m.edges.contains { takes($0.map(project)) }
                    if !hit {
                        var t = 0
                        while !hit, t + 2 < m.indices.count {
                            hit = Self.triangle(t, m, screen, contains: CGPoint(x: r.midX, y: r.midY))
                            t += 3
                        }
                    }
                }
                if hit { bodies.insert(m.body) }
            }
            selectedBodies = bodies
            if !additive { selection = [] }
        }
    }

    private static func triangle(_ t: Int, _ m: SceneData.Mesh, _ s: [CGPoint], contains p: CGPoint) -> Bool {
        let a = s[Int(m.indices[t])], b = s[Int(m.indices[t + 1])], c = s[Int(m.indices[t + 2])]
        func side(_ u: CGPoint, _ v: CGPoint) -> CGFloat { (v.x - u.x) * (p.y - u.y) - (v.y - u.y) * (p.x - u.x) }
        let d1 = side(a, b), d2 = side(b, c), d3 = side(c, a)
        let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
        return !(neg && pos)
    }

    /// The segment meets the rectangle (Liang-Barsky clipping).
    static func segment(_ a: CGPoint, _ b: CGPoint, hits r: CGRect) -> Bool {
        var t0: CGFloat = 0, t1: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
        }
        return true
    }

    // MARK: Pick list (M-9)

    func pickCandidates(at p: CGPoint, size: CGSize) -> [PickCandidate] {
        var out: [PickCandidate] = []
        let f = selectionFilter
        if sketchOpen, let info = sketchInfo, f == .auto || f == .sketch {
            #if os(iOS)
            let (pr, cr): (CGFloat, CGFloat) = (16, 12)
            #else
            let (pr, cr): (CGFloat, CGFloat) = (8, 6)
            #endif
            func s(_ q: SIMD2<Double>) -> CGPoint { camera.project(info.plane.toWorld(q), size: size) }
            for q in info.points where hypot(s(q.at).x - p.x, s(q.at).y - p.y) <= pr {
                out.append(PickCandidate(id: "sketch:" + q.id, label: String(localized: "Point \(q.id)"), kind: .sketch,
                                         target: .sketch(SketchPick(id: q.id, kind: .point))))
            }
            for c in info.curves {
                let pts = c.polyline.map(s)
                guard pts.count > 1, (1..<pts.count).contains(where: { SketchPicker.distance(p, pts[$0 - 1], pts[$0]) <= cr }) else { continue }
                let kind = SketchPick.Kind(curveType: c.kind)
                out.append(PickCandidate(id: "sketch:" + c.id, label: String(localized: "\(c.kind.capitalized) \(c.id)"), kind: .sketch,
                                         target: .sketch(SketchPick(id: c.id, kind: kind))))
            }
        }
        if f == .auto || f == .edge {
            for e in ScenePicker.edgeHits(scene, camera: camera, at: p, size: size, tolerance: 7) {
                guard case let .edge(mi, ei, _) = e else { continue }
                out.append(PickCandidate(id: "edge:\(mi):\(ei)", label: String(localized: "Edge \(ei + 1) of \(scene.meshes[mi].body)"),
                                         kind: .edge, target: .entity(e)))
            }
        }
        let faces = ScenePicker.faceHits(scene, camera: camera, at: p, size: size)
        if f == .auto || f == .face {
            for h in faces {
                guard case let .face(mi, fi, _, _) = h else { continue }
                out.append(PickCandidate(id: "face:\(mi):\(fi)", label: String(localized: "Face \(Int(fi) + 1) of \(scene.meshes[mi].body)"),
                                         kind: .face, target: .entity(h)))
            }
        }
        if f == .auto || f == .body {
            var seen: Set<String> = []
            for h in faces where h.mesh < scene.meshes.count {
                let name = scene.meshes[h.mesh].body
                guard seen.insert(name).inserted else { continue }
                out.append(PickCandidate(id: "body:" + name, label: name, kind: .body, target: .body(name)))
            }
        }
        return out
    }

    /// Selects a candidate from the pick list, replacing the selection (both spaces). A
    /// candidate the scene or the sketch no longer holds is ignored.
    func choose(_ candidate: PickCandidate) {
        pickList = nil
        switch candidate.target {
        case let .body(name):
            guard scene.meshes.contains(where: { $0.body == name }) else { return }
            replaceSelection(bodies: [name])
        case let .entity(pick):
            guard pick.mesh < scene.meshes.count else { return }
            let mesh = scene.meshes[pick.mesh]
            switch pick {
            case let .edge(_, e, _): guard e < mesh.edges.count else { return }
            case let .face(_, f, _, _): guard mesh.triFace.isEmpty || mesh.triFace.contains(f) else { return }
            }
            replaceSelection([pick])
            if tool == .pressPull || tool == .fillet || tool == .chamfer || tool == .shell { applyPreview() }
        case let .sketch(pick):
            guard sketchOpen, let info = sketchInfo,
                  info.points.contains(where: { $0.id == pick.id }) || info.curves.contains(where: { $0.id == pick.id })
                    || info.glyphs.contains(where: { $0.id == pick.id }) else { return }
            replaceSelection(sketch: [pick])
        }
    }

    /// Opens the pick list at `p` when something is there. True when it opened.
    @discardableResult
    func openPickList(at p: CGPoint) -> Bool {
        let items = pickCandidates(at: p, size: viewSize)
        guard !items.isEmpty else { pickList = nil; return false }
        pickList = PickList(at: p, items: items)
        return true
    }

    // MARK: Owning feature (M-10)

    /// The feature that made a picked face, and the sketch it was built from.
    func owningFeature(ofFace pick: Pick) -> (feature: String, sketch: Int?)? {
        guard case let .face(mesh, face, _, _) = pick, mesh < scene.meshes.count else { return nil }
        let body = scene.meshes[mesh].body
        guard let r = (try? engine.execute("model.faces", ["body": body])) as? [String: Any],
              let faces = r["faces"] as? [[String: Any]],
              let entry = faces.first(where: { ($0["index"] as? Int) == Int(face) }) ?? (faces.indices.contains(Int(face)) ? faces[Int(face)] : nil),
              let name = entry["name"] as? String,
              let id = Self.madeBy(faceName: name) else { return nil }
        guard let f = (try? engine.execute("timeline.inspect", ["feature": id])) as? [String: Any] else { return nil }
        let def = f["definition"] as? [String: Any]
        let sketch = (def?["sketch"] as? Int) ?? (def?["sketch"] as? [String: Any])?["id"] as? Int
        return (f["name"] as? String ?? String(id), sketch)
    }

    /// The feature id in a persistent face name (`F<feature>:<role>`, after any prefix).
    static func madeBy(faceName name: String) -> Int? {
        for part in name.split(whereSeparator: { $0 == "|" || $0 == "~" || $0 == "/" }) {
            guard part.first == "F" else { continue }
            let digits = part.dropFirst().prefix { $0.isNumber }
            if !digits.isEmpty, part.dropFirst(digits.count + 1).first == ":", let id = Int(digits) { return id }
        }
        return nil
    }

    /// Opens a finished sketch for editing.
    func editSketch(_ id: Int) {
        guard run("sketch.edit", ["sketch": id]) != nil else { return }
        if let pl = sketchPlane { look(along: pl.normal) }
        tool = .select
    }

    // MARK: Chain select (M-16)

    /// A double click on a sketch curve with Select selects its chain. True when it did.
    @discardableResult
    func chainSelect(at p: CGPoint) -> Bool {
        guard sketchOpen, tool == .select, let info = sketchInfo,
              let hit = SketchPicker.pick(info, camera: camera, at: p, size: viewSize, glyphs: false), hit.isCurve,
              let r = (try? engine.execute("sketch.chain", ["curve": hit.id])) as? [String: Any],
              let curves = r["curves"] as? [String], !curves.isEmpty else { return false }
        sketchSelection = curves.map { id in SketchPick(id: id, kind: SketchPick.Kind(curveType: info.curves.first { $0.id == id }?.kind ?? "")) }
        return true
    }

    // MARK: Touch (T-7, T-8)

    /// A double tap: ends a line chain, selects a sketch chain, starts a sketch on a planar face
    /// (nothing armed), else selects the body.
    func faceDoubleTap(at p: CGPoint) {
        if tool.isSketchTool { endChain(); return }
        if chainSelect(at: p) { return }
        guard tool == .select, !sketchOpen, facePick == nil else { doubleClick(at: p); return }
        guard let hit = ScenePicker.pickFace(scene, camera: camera, at: p, size: viewSize),
              case let .face(mesh, face, point, _) = hit, mesh < scene.meshes.count else { return }
        if facePlanar(mesh: mesh, face: face) {
            selection = []
            selectedBodies = []
            startSketch(["face": [point.x, point.y, point.z]])
            if sketchOpen { return }
        }
        selection = []
        selectedBodies = [scene.meshes[mesh].body]
    }

    /// Every triangle of the face looks the same way (as drawn).
    func facePlanar(mesh: Int, face: UInt32) -> Bool {
        let m = scene.meshes[mesh]
        var first: SIMD3<Float>?
        var t = 0
        while t + 2 < m.indices.count {
            defer { t += 3 }
            guard m.triFace.indices.contains(t / 3), m.triFace[t / 3] == face else { continue }
            let a = m.positions[Int(m.indices[t])], b = m.positions[Int(m.indices[t + 1])], c = m.positions[Int(m.indices[t + 2])]
            let n = simd_cross(b - a, c - a)
            guard simd_length(n) > 1e-9 else { continue }
            let u = simd_normalize(n)
            if let f = first { if simd_dot(f, u) < 0.9995 { return false } } else { first = u }
        }
        return first != nil
    }

    /// A tap with Select on a closed profile of a finished sketch starts Extrude on it. True when
    /// it did. A face in front of the profile wins.
    @discardableResult
    func profileTap(at p: CGPoint) -> Bool {
        guard tool == .select, !sketchOpen, facePick == nil else { return false }
        let face = ScenePicker.pickFace(scene, camera: camera, at: p, size: viewSize)
        for s in snapshot.sketches.reversed().prefix(8) where s.visible != false && (s.profiles ?? 1) > 0 {
            guard let info = SketchInfo.load(engine, sketch: s.id, plane: nil), !info.profiles.isEmpty,
                  let q = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize),
                  let prof = info.profile(at: q) else { continue }
            let w = info.plane.toWorld(q)
            if let f = face, simd_distance(f.point, camera.eye) < simd_distance(w, camera.eye) - max(camera.halfHeight * 0.01, 1e-3) { return false }
            selection = []
            selectedBodies = []
            extrudeSketch = s.id
            tool = .extrude
            if (sketchInfo?.profiles.count ?? 0) > 1 {
                extrudeProfiles = [prof.index]
                applyPreview()
            }
            return true
        }
        return false
    }
}
