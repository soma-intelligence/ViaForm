import Foundation
import Observation
import simd
#if os(macOS)
import AppKit
#endif

/// One open design and everything the front ends show about it. Both front ends (touch and
/// desktop) drive the same model; they only differ in layout and gestures.
@Observable
final class DesignModel {
    let engine = CADEngine()
    let commands = CADEngine.commands

    private(set) var snapshot = DesignSnapshot()
    private(set) var scene = SceneData()
    private(set) var sketchPlane: SketchPlane?

    var camera = OrbitCamera()
    var viewSize: CGSize = .init(width: 1000, height: 700)

    var tool: Tool = .select { didSet { if tool != oldValue { if oldValue != .select { lastTool = oldValue }; toolChanged(from: oldValue) } } }
    /// The last tool used, for Repeat.
    var lastTool: Tool?
    /// The tool's number (distance, radius, angle…), in its unit.
    var toolValue: Double = 0 { didSet { if toolValue != oldValue { valueChanged() } } }
    var toolOperation: String = "auto"
    var revolveAxis: String = "x"
    var mirrorPlane: String = "YZ"
    var moveVector: SIMD3<Double> = .init(10, 0, 0)

    /// Clicks gathered on the sketch plane for the current sketch tool.
    private(set) var clicks: [SIMD2<Double>] = []
    /// Where the cursor is on the sketch plane, snapped.
    private(set) var cursor: SIMD2<Double>?
    private(set) var cursorSnap: String?

    var selection: [Pick] = [] { didSet { pushHighlight() } }
    var selectedBodies: Set<String> = [] { didSet { pushHighlight() } }
    var hover: Pick? { didSet { if hover != oldValue { pushHighlight() } } }

    var message: String?
    var messageIsError = false
    /// The generic command form (any registry command, by its params doc).
    var genericCommand: CommandInfo?
    /// Where the desktop marking menu is open, in viewport points.
    var markingMenu: CGPoint?
    /// The command search (S on the desktop).
    var toolboxOpen = false

    /// Called when the picture must be redrawn (new scene, camera or highlight).
    var onSceneChange: ((SceneData) -> Void)?
    var onHighlightChange: ((Highlight) -> Void)?

    private var previewCheckpoint: Int?
    private var previewApplied = false

    init() {
        refresh()
        if let home = engine.homeCamera() { camera = home }
        if ProcessInfo.processInfo.arguments.contains("--sample") { loadSample() }
    }

    // MARK: Engine

    @discardableResult
    func run(_ id: String, _ params: [String: Any] = [:], quiet: Bool = false) -> Any? {
        do {
            let r = try engine.execute(id, params)
            if !quiet { flash(nil) }
            refresh()
            return r
        } catch {
            flash(error.localizedDescription, error: true)
            refresh()
            return nil
        }
    }

    func runJSON(_ id: String, _ json: String) {
        do {
            try engine.executeJSON(id, json)
            flash("\(id) done")
        } catch {
            flash(error.localizedDescription, error: true)
        }
        refresh()
    }

    func refresh() {
        snapshot = engine.inspect()
        sketchPlane = engine.sketchPlane()
        rebuildScene()
    }

    func rebuildScene() {
        scene = engine.scene(camera: camera)
        scene.revision = snapshot.revision
        // Drop picks that no longer exist.
        selection = selection.filter { $0.mesh < scene.meshes.count }
        onSceneChange?(scene)
        pushHighlight()
    }

    /// The camera moved: the grid follows it, so the scene is laid out again.
    func cameraChanged() {
        rebuildScene()
    }

    func flash(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
    }

    // MARK: Highlight

    private func pushHighlight() {
        var h = Highlight()
        for p in selection {
            switch p {
            case let .face(m, f, _, _): h.faces[m, default: []].append(Int(f))
            case let .edge(m, e, _): h.edges[m, default: []].append(e)
            }
        }
        for (i, m) in scene.meshes.enumerated() where selectedBodies.contains(m.body) { h.bodies.insert(i) }
        switch hover {
        case let .face(m, f, _, _)?: h.hoverFace = (m, Int(f))
        case let .edge(m, e, _)?: h.hoverEdge = (m, e)
        case nil: break
        }
        onHighlightChange?(h)
    }

    // MARK: Pointer

    func hover(at p: CGPoint) {
        if tool.isSketchTool, let plane = sketchPlane {
            guard let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
            (cursor, cursorSnap) = snap(q)
            hover = nil
            return
        }
        hover = ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: wantsEdges)
    }

    private var wantsEdges: Bool { tool == .select || tool == .fillet || tool == .chamfer }

    /// A click or tap. `additive` keeps the selection (Shift on a Mac, the default on touch).
    func click(at p: CGPoint, additive: Bool) {
        if tool.isSketchTool {
            guard let plane = sketchPlane, let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
            sketchClick(snap(q).0, raw: q)
            return
        }
        let hit = ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: wantsEdges)
        switch tool {
        case .sketch:
            if case let .face(_, _, point, _)? = hit {
                startSketch(["face": [point.x, point.y, point.z]])
            }
            return
        case .box, .cylinder, .sphere, .torus:
            placePrimitive(at: groundPoint(p, hit: hit))
            return
        default:
            break
        }
        guard let hit else {
            if !additive { selection = []; selectedBodies = [] }
            return
        }
        if let i = selection.firstIndex(where: { $0.sameEntity(hit) }) {
            selection.remove(at: i)
        } else if additive {
            selection.append(hit)
        } else {
            selection = [hit]
            selectedBodies = []
        }
        if tool == .pressPull || tool == .fillet || tool == .chamfer || tool == .shell { applyPreview() }
    }

    /// A double click or tap selects the whole body.
    func doubleClick(at p: CGPoint) {
        guard let hit = ScenePicker.pickFace(scene, camera: camera, at: p, size: viewSize) else { return }
        let name = scene.meshes[hit.mesh].body
        if selectedBodies.contains(name) { selectedBodies.remove(name) } else { selectedBodies.insert(name) }
        selection = []
    }

    private func groundPoint(_ p: CGPoint, hit: Pick?) -> SIMD3<Double> {
        if let hit { return hit.point }
        let ground = SketchPlane(origin: .zero, x: SIMD3(1, 0, 0), y: SIMD3(0, 1, 0))
        guard let q = ScenePicker.onPlane(ground, camera: camera, at: p, size: viewSize) else { return .zero }
        let step = gridStep
        return SIMD3((q.x / step).rounded() * step, (q.y / step).rounded() * step, 0)
    }

    var gridStep: Double {
        let h = camera.halfHeight
        let raw = h / 20
        let p = pow(10, floor(log10(max(raw, 1e-6))))
        for m in [1.0, 2.0, 5.0, 10.0] where p * m >= raw { return p * m }
        return p * 10
    }

    // MARK: Sketching

    var sketchOpen: Bool { snapshot.active_sketch != nil }

    func startSketch(_ plane: Any) {
        guard run("sketch.create", ["plane": plane]) != nil else { return }
        if let pl = sketchPlane { look(along: pl.normal) }
        tool = .line
    }

    func finishSketch() {
        clicks = []
        run("sketch.finish", quiet: true)
        tool = .select
    }

    func look(along normal: SIMD3<Double>) {
        let n = simd_normalize(normal)
        camera.pitch = asin(min(max(n.z, -1), 1))
        camera.yaw = abs(n.z) > 0.9999 ? 0 : atan2(-n.x, -n.y)
        camera.roll = 0
        cameraChanged()
    }

    private func snap(_ q: SIMD2<Double>) -> (SIMD2<Double>, String?) {
        let radius = camera.halfHeight * 0.03
        if let r = try? engine.execute("sketch.snap", ["at": [q.x, q.y], "radius": radius]) as? [String: Any],
           let snaps = r["snaps"] as? [[String: Any]],
           let best = snaps.first(where: { ($0["type"] as? String) != "on_curve" }),
           let at = best["at"] as? [Double], at.count == 2 {
            return (SIMD2(at[0], at[1]), best["type"] as? String)
        }
        let s = gridStep / 2
        return (SIMD2((q.x / s).rounded() * s, (q.y / s).rounded() * s), nil)
    }

    private func curve(at q: SIMD2<Double>) -> String? {
        let radius = camera.halfHeight * 0.03
        guard let r = try? engine.execute("sketch.snap", ["at": [q.x, q.y], "radius": radius]) as? [String: Any],
              let snaps = r["snaps"] as? [[String: Any]] else { return nil }
        return snaps.compactMap { $0["curve"] as? String }.first
    }

    private func pointRef(at q: SIMD2<Double>) -> String? {
        let radius = camera.halfHeight * 0.03
        guard let r = try? engine.execute("sketch.snap", ["at": [q.x, q.y], "radius": radius]) as? [String: Any],
              let snaps = r["snaps"] as? [[String: Any]] else { return nil }
        return snaps.compactMap { $0["point"] as? String }.first
    }

    private func pt(_ p: SIMD2<Double>) -> [Double] { [p.x, p.y] }

    private func sketchClick(_ q: SIMD2<Double>, raw: SIMD2<Double>) {
        switch tool {
        case .line:
            if let last = clicks.last {
                let closing = clicks.count > 1 && simd_distance(q, clicks[0]) < 1e-9
                run("sketch.line", ["points": [pt(last), pt(q)]], quiet: true)
                clicks = closing ? [] : [q]
            } else {
                clicks = [q]
            }
        case .spline:
            clicks.append(q)
        case .trim:
            if let c = curve(at: raw) { run("sketch.trim", ["curve": c, "at": pt(raw)]) }
        case .offset:
            if let c = curve(at: raw) { run("sketch.offset", ["curves": [c], "distance": toolValue]) }
        case .sketchFillet:
            if let p = pointRef(at: raw) { run("sketch.fillet", ["point": p, "radius": toolValue]) }
        default:
            clicks.append(q)
            if clicks.count >= tool.clicks { commitSketchShape() }
        }
    }

    private func commitSketchShape() {
        let c = clicks
        clicks = []
        switch tool {
        case .rectangle:
            run("sketch.rectangle.two_point", ["p0": pt(c[0]), "p1": pt(c[1])], quiet: true)
        case .centerRectangle:
            run("sketch.rectangle.center", ["center": pt(c[0]), "corner": pt(c[1])], quiet: true)
        case .circle:
            let r = simd_distance(c[0], c[1])
            if r > 0 { run("sketch.circle.center", ["center": pt(c[0]), "radius": r], quiet: true) }
        case .polygon:
            let r = simd_distance(c[0], c[1])
            let a = atan2(c[1].y - c[0].y, c[1].x - c[0].x) * 180 / .pi
            if r > 0 { run("sketch.polygon.inscribed", ["center": pt(c[0]), "radius": r, "sides": max(3, Int(toolValue)), "angle": a], quiet: true) }
        case .arc:
            run("sketch.arc.three_point", ["start": pt(c[0]), "end": pt(c[1]), "through": pt(c[2])], quiet: true)
        case .slot:
            let d = c[1] - c[0]
            let len = simd_length(d)
            guard len > 0 else { return }
            let n = SIMD2(-d.y, d.x) / len
            let w = abs(simd_dot(c[2] - c[0], n)) * 2
            if w > 0 { run("sketch.slot.center_to_center", ["p0": pt(c[0]), "p1": pt(c[1]), "width": w], quiet: true) }
        case .point:
            run("sketch.point", ["point": pt(c[0])], quiet: true)
        default:
            break
        }
    }

    /// Ends an open-ended tool (line chain, spline), as Escape or Done does.
    func endChain() {
        if tool == .spline, clicks.count >= 2 {
            run("sketch.spline.fit_point", ["points": clicks.map(pt)], quiet: true)
        }
        clicks = []
    }

    /// The preview of the shape being drawn, in sketch coordinates: polylines.
    var rubberBand: [[SIMD2<Double>]] {
        guard let cur = cursor, !clicks.isEmpty else { return [] }
        let c = clicks
        switch tool {
        case .line: return [[c[c.count - 1], cur]]
        case .spline: return [c + [cur]]
        case .rectangle:
            let a = c[0], b = cur
            return [[a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y), a]]
        case .centerRectangle:
            let d = cur - c[0], a = c[0] - d, b = cur
            return [[a, SIMD2(b.x, a.y), b, SIMD2(a.x, b.y), a]]
        case .circle, .polygon:
            let r = simd_distance(c[0], cur)
            let n = tool == .polygon ? max(3, Int(toolValue)) : 64
            let a0 = atan2(cur.y - c[0].y, cur.x - c[0].x)
            return [(0...n).map { i in
                let a = a0 + Double(i) / Double(n) * 2 * .pi
                return c[0] + SIMD2(cos(a), sin(a)) * r
            }]
        case .arc: return c.count == 1 ? [[c[0], cur]] : [[c[0], cur, c[1]]]
        case .slot: return c.count == 1 ? [[c[0], cur]] : [[c[0], c[1]], [c[1], cur]]
        default: return []
        }
    }

    // MARK: Solid tools

    private func toolChanged(from old: Tool) {
        if previewCheckpoint != nil { cancelPreview() }
        clicks = []
        cursor = nil
        if let v = tool.value { toolValue = v.initial }
        if tool == .extrude || tool == .revolve {
            // An open sketch is finished first: its profiles are what the feature takes.
            if sketchOpen { run("sketch.finish", quiet: true) }
            applyPreview()
        } else if tool == .pressPull || tool == .fillet || tool == .chamfer || tool == .shell {
            applyPreview()
        }
    }

    private func valueChanged() {
        switch tool {
        case .extrude, .revolve, .pressPull, .fillet, .chamfer, .shell: applyPreview()
        default: break
        }
    }

    /// The command (id and parameters) the current tool would run now, if it has what it needs.
    private var pendingCommand: (String, [String: Any])? {
        let faces = selection.filter(\.isFace).map(\.points)
        let edges = selection.filter(\.isEdge).map(\.points)
        switch tool {
        case .extrude:
            var p: [String: Any] = ["distance": toolValue]
            if toolOperation != "auto" { p["operation"] = toolOperation }
            return ("solid.extrude", p)
        case .revolve:
            var p: [String: Any] = ["axis": revolveAxis, "angle": "\(toolValue) deg"]
            if toolOperation != "auto" { p["operation"] = toolOperation }
            return ("solid.revolve", p)
        case .pressPull:
            guard let f = faces.first else { return nil }
            return ("solid.press_pull", ["face": f, "distance": toolValue])
        case .fillet:
            guard !edges.isEmpty else { return nil }
            return ("solid.fillet", ["edges": edges, "radius": toolValue])
        case .chamfer:
            guard !edges.isEmpty else { return nil }
            return ("solid.chamfer", ["edges": edges, "distance": toolValue])
        case .shell:
            guard !faces.isEmpty else { return nil }
            return ("solid.shell", ["faces": faces, "thickness": toolValue])
        default:
            return nil
        }
    }

    /// Runs the tool's command on a checkpoint, so each new value replaces the last preview.
    func applyPreview() {
        guard let (id, params) = pendingCommand, toolValue != 0 || tool == .revolve else { return }
        do {
            // Restoring a checkpoint uses it up: take a fresh one for the next value.
            if previewApplied, let cp = previewCheckpoint {
                try engine.execute("edit.restore_checkpoint", ["checkpoint": cp])
                previewApplied = false
                previewCheckpoint = nil
            }
            if previewCheckpoint == nil {
                let r = try engine.execute("edit.checkpoint") as? [String: Any]
                previewCheckpoint = r?["checkpoint"] as? Int
            }
            try engine.execute(id, params)
            previewApplied = true
            flash(nil)
        } catch {
            flash(error.localizedDescription, error: true)
        }
        let keep = selection
        refresh()
        selection = keep.filter { $0.mesh < scene.meshes.count }
    }

    /// Keeps the previewed feature.
    func commitTool() {
        if let cp = previewCheckpoint {
            _ = try? engine.execute("edit.restore_checkpoint", ["checkpoint": cp, "forget": true])
        }
        previewCheckpoint = nil
        previewApplied = false
        selection = []
        tool = .select
        refresh()
    }

    func cancelPreview() {
        if let cp = previewCheckpoint {
            _ = try? engine.execute("edit.restore_checkpoint", ["checkpoint": cp])
        }
        previewCheckpoint = nil
        previewApplied = false
        refresh()
    }

    var hasPreview: Bool { previewApplied }

    func cancelTool() {
        if !clicks.isEmpty { clicks = []; return }
        tool = .select
    }

    private func placePrimitive(at c: SIMD3<Double>) {
        let v = max(toolValue, 0.1)
        let at = [c.x, c.y, c.z]
        switch tool {
        case .box: run("solid.box", ["length": v, "width": v, "height": v, "corner": [c.x - v / 2, c.y - v / 2, c.z]])
        case .cylinder: run("solid.cylinder", ["diameter": v, "height": v, "base": at])
        case .sphere: run("solid.sphere", ["diameter": v, "center": [c.x, c.y, c.z + v / 2]])
        case .torus: run("solid.torus", ["major": v / 2, "minor": v / 8, "center": [c.x, c.y, c.z + v / 8]])
        default: break
        }
    }

    /// Bodies the selection names: whole bodies, or the bodies of picked faces and edges.
    var bodiesInSelection: [String] {
        var out = Array(selectedBodies).sorted()
        for p in selection where p.mesh < scene.meshes.count {
            let n = scene.meshes[p.mesh].body
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    func combine(_ op: String) {
        let b = bodiesInSelection
        guard b.count >= 2 else { flash("Select two or more bodies (double-tap a body)", error: true); return }
        run("solid.combine", ["target": b[0], "tools": Array(b.dropFirst()), "operation": op])
        selectedBodies = []
    }

    func moveSelected() {
        let b = bodiesInSelection
        guard !b.isEmpty else { flash("Select a body to move", error: true); return }
        run("solid.move", ["bodies": b, "translate": [moveVector.x, moveVector.y, moveVector.z]])
    }

    func mirrorSelected() {
        let b = bodiesInSelection
        guard !b.isEmpty else { flash("Select a body to mirror", error: true); return }
        run("solid.mirror", ["bodies": b, "plane": mirrorPlane])
    }

    func deleteSelection() {
        let faces = selection.filter(\.isFace).map(\.points)
        if !selectedBodies.isEmpty {
            run("solid.remove", ["bodies": Array(selectedBodies)])
        } else if !faces.isEmpty {
            run("face.delete", ["faces": faces])
        } else {
            flash("Select bodies or faces to delete", error: true)
        }
        selection = []
        selectedBodies = []
    }

    func measureSelection() {
        let b = bodiesInSelection
        guard let r = run("inspect.measure", b.isEmpty ? [:] : ["bodies": b], quiet: true) as? [String: Any],
              let bodies = r["bodies"] as? [[String: Any]] else { return }
        let lines = bodies.map { body -> String in
            let name = body["name"] as? String ?? "?"
            let v = body["volume_mm3"] as? Double ?? 0
            let a = body["area_mm2"] as? Double ?? 0
            let m = body["mass_g"] as? Double ?? 0
            return String(format: "%@  V %.1f mm³  A %.1f mm²  %.1f g", name, v, a, m)
        }
        flash(lines.joined(separator: "\n"))
    }

    // MARK: Suggestions (what the selection invites)

    var suggestions: [Tool] {
        if sketchOpen { return [.extrude, .revolve] }
        let faces = selection.filter(\.isFace).count, edges = selection.filter(\.isEdge).count
        if !selectedBodies.isEmpty { return selectedBodies.count > 1 ? [.union, .subtract, .intersect, .move, .delete] : [.move, .mirror, .shell, .delete, .measure] }
        if edges > 0, faces == 0 { return [.fillet, .chamfer] }
        if faces == 1, edges == 0 { return [.pressPull, .sketch, .shell, .delete] }
        if faces > 1 { return [.shell, .delete] }
        return []
    }

    func sketchOnSelectedFace() {
        guard case let .face(_, _, p, _)? = selection.first(where: \.isFace) else { tool = .sketch; return }
        selection = []
        startSketch(["face": [p.x, p.y, p.z]])
    }

    // MARK: Document

    func undo() { run("edit.undo", quiet: true) }
    func redo() { run("edit.redo", quiet: true) }

    func newDesign() {
        run("file.new", quiet: true)
        if let home = engine.homeCamera() { camera = home }
        cameraChanged()
    }

    func open(_ url: URL) {
        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif
        let ext = url.pathExtension.lowercased()
        let path = url.path
        switch ext {
        case "step", "stp", "iges", "igs", "3dm", "fcstd":
            run("file.insert_step", ["path": path])
        case "stl", "obj", "3mf", "ply", "glb", "gltf":
            run("file.insert_mesh", ["path": path])
        case "json":
            if let data = try? Data(contentsOf: url) {
                do { try engine.runScript(data); flash("Script ran") } catch { flash(error.localizedDescription, error: true) }
                refresh()
            }
        default:
            run("doc.open", ["path": path])
        }
        zoomToFit()
    }

    func save(to url: URL) {
        run("file.save_as", ["path": url.path])
    }

    func export(to url: URL) {
        run("file.export", ["path": url.path])
    }

    func zoomToFit() {
        if let b = engine.bounds() {
            camera.fit(min: b.min, max: b.max, aspect: Double(viewSize.width / max(viewSize.height, 1)))
        } else if let home = engine.homeCamera() {
            camera = home
        }
        cameraChanged()
    }

    func setView(_ v: StandardView) {
        camera.standard(v)
        cameraChanged()
    }

    func rollTimeline(to position: Int) {
        run("timeline.roll_to", ["position": position], quiet: true)
    }

    func toggleBodyVisibility(_ name: String, visible: Bool) {
        run("browser.visibility", ["visible": visible, "items": [name]], quiet: true)
    }

    func loadSample() {
        let steps: [(String, [String: Any])] = [
            ("parameters.change", ["name": "width", "expression": "60 mm"]),
            ("sketch.create", ["plane": "XZ", "name": "Profile"]),
            ("sketch.line", ["points": [[0, 0], [40, 0], [40, 6], [6, 6], [6, 30], [0, 30]], "closed": true]),
            ("sketch.finish", [:]),
            ("solid.extrude", ["distance": "width", "direction": "negative", "body_name": "Bracket"]),
            ("solid.fillet", ["edges": [[40, -30, -6]], "radius": 2]),
            ("sketch.create", ["plane": "XY", "name": "Holes"]),
            ("sketch.circle.center", ["center": [25, -15], "diameter": 8]),
            ("sketch.circle.center", ["center": [25, -45], "diameter": 8]),
            ("sketch.finish", [:]),
            ("solid.extrude", ["distance": 6, "direction": "negative", "operation": "cut"]),
        ]
        do {
            for (id, p) in steps { try engine.execute(id, p) }
        } catch {
            flash(error.localizedDescription, error: true)
        }
        refresh()
        zoomToFit()
    }
}
