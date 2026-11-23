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
    /// A one-shot face pick another workspace asked for (mounting the board): body, point, normal.
    var facePick: ((String, SIMD3<Double>, SIMD3<Double>) -> Void)?
    var facePickPrompt: String?
    /// Components of the assembly (not the root), refreshed with the snapshot.
    struct AssemblyPart: Identifiable, Hashable {
        var id: Int
        var name: String
        var occurrence: String?
        var grounded: Bool
        var bodies: [String]
        var linkedPCB: Bool
    }
    var assembly: [AssemblyPart] = []
    /// The command search (S on the desktop).
    var toolboxOpen = false

    /// Called when the picture must be redrawn (new scene, camera or highlight).
    @ObservationIgnored var onSceneChange: ((SceneData) -> Void)?
    @ObservationIgnored var onHighlightChange: ((Highlight) -> Void)?

    private var previewCheckpoint: Int?
    private var previewApplied = false

    /// The open sketch (or, while Extrude is armed, the sketch it extrudes) as the canvas draws
    /// it: points to drag, profiles to pick, dimensions to edit.
    var sketchInfo: SketchInfo?
    /// The profiles Extrude takes (indices of `sketchInfo.profiles`); empty takes them all.
    var extrudeProfiles: Set<Int> = []
    /// The profile under the pointer while Extrude is armed.
    var hoverProfile: Int?
    /// A sketch point being dragged: its id and where it was grabbed (sketch coordinates).
    @ObservationIgnored var sketchDrag: (entity: String, from: SIMD2<Double>)?
    /// A distance handle being dragged: the value it started from, and whether the drag armed
    /// Push / Pull itself (then releasing commits it).
    @ObservationIgnored var handleDrag: (start: Double, implicit: Bool)?
    /// Set while a tool is armed by a handle drag, so arming runs no preview of its own.
    @ObservationIgnored var armingQuietly = false

    init() {
        Perf.watchMainThread()
        Perf.milestone("design model init")
        refresh()
        if let home = engine.homeCamera() { camera = home }
        // `--sample hand` and `--sample drone` open a generative project, not the sample design.
        if ProcessInfo.processInfo.arguments.contains("--sample") && GenerateProject.launchSample == nil { loadSample() }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--design-demo=") }) {
            let me = UncheckedWeak(self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { me.value?.applyDesignDemoFlag() }
        }
    }

    // MARK: Engine

    /// The last registry command run, so other parts of the app (the pipeline) can follow
    /// what the design did without each command reporting itself.
    struct RunRecord: Equatable {
        var id: String
        var ok: Bool
        var serial: Int
    }
    private(set) var lastRun: RunRecord?

    @discardableResult
    func run(_ id: String, _ params: [String: Any] = [:], quiet: Bool = false) -> Any? {
        let serial = (lastRun?.serial ?? 0) + 1
        do {
            let r = try engine.execute(id, params)
            if !quiet { flash(nil) }
            refresh()
            lastRun = RunRecord(id: id, ok: true, serial: serial)
            return r
        } catch {
            flash(error.localizedDescription, error: true)
            refresh()
            lastRun = RunRecord(id: id, ok: false, serial: serial)
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
        Perf.measure("refresh") {
            snapshot = Perf.measure("refresh.inspect") { engine.inspect() }
            sketchPlane = engine.sketchPlane()
            reloadSketchInfo()
            Perf.measure("refresh.assembly") { refreshAssembly() }
            rebuildScene()
        }
    }

    func rebuildScene() {
        Perf.measure("rebuildScene") { rebuildSceneNow() }
    }

    private func rebuildSceneNow() {
        sceneRequest += 1
        // Small scenes build here, so a click sees its result at once (picking, the selection
        // flags, the self tests). A scene that took long last time builds on the worker while
        // the old one keeps drawing (double buffered), and only the latest request lands.
        if !SceneWorker.wantsBackground(lastSeconds: sceneSeconds) {
            let t0 = Perf.now()
            var built = engine.scene(camera: camera)
            sceneSeconds = Perf.now() - t0
            built.revision = snapshot.revision
            publish(built)
            return
        }
        let request = sceneRequest
        let revision = snapshot.revision
        let cam = camera
        let engine = engine
        let me = UncheckedWeak(self)
        let ticket = sceneTicket
        ticket.note(request)
        sceneBuilding = true
        SceneWorker.queue.async {
            // A newer request is queued behind this one: skip, it builds the latest design.
            guard ticket.isLatest(request) else { return }
            let t0 = Perf.now()
            var built = engine.scene(camera: cam)
            built.revision = revision
            let seconds = Perf.now() - t0
            let box = SceneBox(scene: built)
            DispatchQueue.main.async {
                guard let m = me.value, m.sceneRequest == request else { return }
                m.sceneSeconds = seconds
                m.sceneBuilding = false
                m.publish(box.scene)
                // The camera moved while building: the guides follow it now.
                if m.camera != cam { m.cameraChanged(final: true) }
            }
        }
    }

    /// Swaps the drawn scene for a new one (the front buffer changes only here).
    private func publish(_ built: SceneData) {
        scene = built
        // Drop picks that no longer exist. Only written when something went: every write of an
        // observed property invalidates the views that read it.
        let kept = selection.filter { $0.mesh < scene.meshes.count }
        if kept.count != selection.count { selection = kept }
        onSceneChange?(scene)
        pushHighlight()
    }

    /// The scene is being built on the worker; the old one is still on screen.
    private(set) var sceneBuilding = false
    @ObservationIgnored private var sceneRequest = 0
    @ObservationIgnored private let sceneTicket = SceneTicket()
    /// How long the last scene build took: past `SceneWorker.threshold`, the next one goes to
    /// the worker.
    @ObservationIgnored private(set) var sceneSeconds = 0.0

    /// Called with the camera-dependent lines (grid, axes, edges) after an orbit, pan or zoom.
    @ObservationIgnored var onGuidesChange: ((SceneData) -> Void)?

    /// Called with the new camera at once on every move, before the grid follows.
    @ObservationIgnored var onCameraMove: ((OrbitCamera) -> Void)?

    /// The camera moved: the bodies are drawn from it at once, and the grid and the axes follow
    /// it. The bodies do not depend on the camera, so they are neither copied nor uploaded
    /// again, and `scene` (which views observe) is left alone. Laying the grid out goes through
    /// the whole scene in the engine, so in a stream of moves (a drag of the view or the view
    /// cube) it runs only as often as it is cheap: every move for a small design, after the
    /// stream for a big assembly. `final` (the end of a gesture) lays it out now.
    func cameraChanged(final: Bool = false) {
        onCameraMove?(camera)
        cameraSerial += 1
        let now = Perf.now()
        defer { lastCameraMove = now }
        let cost = guidesSeconds
        let every: Double? = cost < 0.004 ? 1.0 / 60 : (cost < 0.008 ? cost * 10 : nil)
        let quietBefore = now - lastCameraMove > 0.25
        if final || quietBefore || every.map({ now - lastGuides >= $0 }) == true {
            layOutGuides()
            return
        }
        // Later, once the moves stop.
        let serial = cameraSerial
        let me = UncheckedWeak(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let m = me.value, m.cameraSerial == serial else { return }
            m.layOutGuides()
        }
    }

    private func layOutGuides() {
        let t0 = Perf.now()
        // The scene worker holds the engine: its scene brings the guides when it lands.
        guard let g = engine.guidesIfFree(camera: camera) else { return }
        guidesSeconds = Perf.now() - t0
        lastGuides = Perf.now()
        onGuidesChange?(g)
    }

    @ObservationIgnored private var cameraSerial = 0
    @ObservationIgnored private var lastCameraMove = 0.0
    @ObservationIgnored private var lastGuides = 0.0

    /// How long the last grid and axes layout took, so gestures know how often to ask for one.
    @ObservationIgnored private(set) var guidesSeconds = 0.0

    private func refreshAssembly() {
        let comps = ((try? engine.execute("component.list")) as? [String: Any])?["components"] as? [[String: Any]] ?? []
        assembly = comps.compactMap { c in
            guard let id = c["id"] as? Int, id != 0, let name = c["name"] as? String else { return nil }
            let occ = (c["occurrences"] as? [[String: Any]])?.first
            let meta = (try? engine.execute("component.metadata", ["component": id])) as? [String: Any]
            return AssemblyPart(id: id, name: name, occurrence: occ?["name"] as? String, grounded: occ?["grounded"] as? Bool ?? false,
                                bodies: c["bodies"] as? [String] ?? [], linkedPCB: (meta?["description"] as? String) == PCBLink.tag)
        }
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
        if tool == .extrude, let info = sketchInfo {
            let q = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize)
            let i = q.flatMap { info.profile(at: $0)?.index }
            if i != hoverProfile { hoverProfile = i }
            return
        }
        hover = ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: wantsEdges)
    }

    private var wantsEdges: Bool { tool == .select || tool == .fillet || tool == .chamfer }

    /// A click or tap. `additive` keeps the selection (Shift on a Mac, the default on touch).
    /// How a click changes the selection (FRONTEND-SPEC 7.3): click replaces, Shift adds,
    /// Command toggles. Touch taps toggle.
    enum SelectMode { case replace, add, toggle }

    func click(at p: CGPoint, additive: Bool) {
        click(at: p, mode: additive ? .toggle : .replace)
    }

    func click(at p: CGPoint, mode: SelectMode) {
        let additive = mode != .replace
        if tool.isSketchTool {
            guard let plane = sketchPlane, let q = ScenePicker.onPlane(plane, camera: camera, at: p, size: viewSize) else { return }
            sketchClick(snap(q).0, raw: q)
            return
        }
        if tool == .extrude, let info = sketchInfo, info.profiles.count > 1 {
            if let q = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize), let prof = info.profile(at: q) {
                toggleProfile(prof.index)
            }
            return
        }
        let hit = ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: wantsEdges)
        if let pick = facePick {
            if case let .face(mesh, _, point, normal)? = hit, mesh < scene.meshes.count {
                facePick = nil
                facePickPrompt = nil
                pick(scene.meshes[mesh].body, point, normal)
            }
            return
        }
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
        let present = selection.firstIndex(where: { $0.sameEntity(hit) })
        switch mode {
        case .toggle:
            if let present { selection.remove(at: present) } else { selection.append(hit) }
        case .add:
            if present == nil { selection.append(hit) }
        case .replace:
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
        extrudeProfiles = []
        hoverProfile = nil
        if armingQuietly {
            toolValue = 0
            return
        }
        if let v = tool.value { toolValue = v.initial }
        if tool == .extrude || tool == .revolve {
            // An open sketch is finished first: its profiles are what the feature takes.
            if sketchOpen { run("sketch.finish", quiet: true) }
            applyPreview()
        } else if tool == .pressPull || tool == .fillet || tool == .chamfer || tool == .shell {
            applyPreview()
        }
        if tool == .extrude || old == .extrude { reloadSketchInfo() }
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
            if !extrudeProfiles.isEmpty { p["profiles"] = extrudeProfiles.sorted() }
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
        guard let (id, params) = pendingCommand, toolValue != 0 || tool == .revolve else {
            // A value of zero shows no feature: take the last preview back.
            if previewApplied, let cp = previewCheckpoint {
                _ = try? engine.execute("edit.restore_checkpoint", ["checkpoint": cp])
                previewApplied = false
                previewCheckpoint = nil
                let keep = selection
                refresh()
                selection = keep.filter { $0.mesh < scene.meshes.count }
            }
            return
        }
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

/// Where big scenes are built: one serial queue, latest request wins.
enum SceneWorker {
    static let queue = DispatchQueue(label: "me.somalabs.viaform.scene", qos: .userInitiated)
    /// A build slower than this (seconds) moves the next ones off the main thread: past a
    /// quarter of a 60 Hz frame the UI would stutter.
    static let threshold = 0.004

    static func wantsBackground(lastSeconds: Double) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("--sync-scene") { return false }
        if ProcessInfo.processInfo.arguments.contains("--async-scene") { return true }
        return lastSeconds > threshold
    }
}

/// One model's newest scene request, read by the worker to drop stale builds.
final class SceneTicket: @unchecked Sendable {
    private var latest = 0
    private let lock = NSLock()

    func note(_ request: Int) {
        lock.lock(); defer { lock.unlock() }
        latest = max(latest, request)
    }

    func isLatest(_ request: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request >= latest
    }
}

/// A built scene crossing from the worker to the main thread.
private struct SceneBox: @unchecked Sendable {
    let scene: SceneData
}

/// A weak reference handed to a main-queue callback. The model lives on the main thread; the
/// callback runs there too.
private final class UncheckedWeak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}
