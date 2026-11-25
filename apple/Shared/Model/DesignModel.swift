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
    var clicks: [SIMD2<Double>] = []
    /// What each click snapped to (B-6), in step with `clicks`.
    var clickSnaps: [SnapHit] = []
    /// Where the cursor is on the sketch plane, snapped.
    var cursor: SIMD2<Double>?
    var cursorSnap: String?
    /// The cursor's snap with its references, for the inference line (B-6).
    var cursorHit: SnapHit?

    // One selection space at a time (sketch entities or 3D picks): picking in one clears the
    // other, so Delete and the tools never act on a selection the canvas no longer shows.
    var selection: [Pick] = [] {
        didSet {
            pushHighlight()
            if !selection.isEmpty, !sketchSelection.isEmpty { sketchSelection = [] }
        }
    }
    var selectedBodies: Set<String> = [] {
        didSet {
            pushHighlight()
            if !selectedBodies.isEmpty, !sketchSelection.isEmpty { sketchSelection = [] }
        }
    }
    var hover: Pick? { didSet { if hover != oldValue { pushHighlight() } } }

    var message: String?
    var messageIsError = false
    /// The generic command form (any registry command, by its params doc).
    var genericCommand: CommandInfo? {
        // Sketch commands with a click flow (dimension, construction, constraints on the
        // sketch selection) run it instead of the JSON form, whatever surface asked.
        didSet { if let c = genericCommand, routeSketchCommand(c.id) { genericCommand = nil } }
    }
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
    /// The body names before a tool preview ran. Fusion creates nothing before OK, so the
    /// browser lists only these while a preview shows (`listedBodies`).
    @ObservationIgnored private var bodiesBeforePreview: Set<String>?
    /// The feature session's own preview is on (it sets this; see `FeatureSession.applied`).
    @ObservationIgnored var sessionPreviewApplied = false
    /// The engine's refusal of the tool's last preview (OK then keeps the dialog open).
    private(set) var previewError: String?

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

    // Sketch selection and constraints (B-1 to B-5, B-9): see SketchSelection.swift.
    /// Picked sketch entities and constraint glyphs of the open sketch, in pick order.
    var sketchSelection: [SketchPick] = [] {
        didSet {
            guard !sketchSelection.isEmpty else { return }
            if !selection.isEmpty { selection = [] }
            if !selectedBodies.isEmpty { selectedBodies = [] }
        }
    }
    /// The sketch entity or glyph under the pointer.
    var sketchHover: SketchPick?
    /// Draw constraint glyphs on the open sketch ("Show constraints").
    var showConstraints: Bool = SketchDisplaySettings.constraints {
        didSet { SketchDisplaySettings.set(showConstraints, for: SketchDisplaySettings.constraintsKey) }
    }
    /// Draw dimensions on the open sketch (Sketch Palette "Dimensions", shared by Mac and iPad:
    /// `SketchDisplaySettings.dimensionsKey`). The canvas reads the key live.
    var showDimensions: Bool {
        get { SketchDisplaySettings.dimensions }
        set { UserDefaults.standard.set(newValue, forKey: SketchDisplaySettings.dimensionsKey) }
    }
    /// New sketch curves are drawn as construction geometry.
    var constructionMode = false
    /// The Dimension tool's picks so far (one or two entities).
    var dimensionPicks: [SketchPick] = []
    /// The Dimension tool's cursor on the sketch plane (unsnapped), for its preview.
    var dimensionCursor: SIMD2<Double>?
    /// A dimension the sketch already determines: offered again as a driven one.
    var dimensionOffer: DimensionOffer?
    /// A dimension just placed: the canvas opens its value field once, then clears this.
    var dimensionToEdit: String?
    /// Symmetry applied with two picks waits for the line (or point) as a third pick.
    var symmetryPending: [SketchPick]?

    // Drawing (B-6, B-8, B-11, B-12, M-16): see SketchDrawing.swift.
    /// Sizes typed while drawing (B-8): the values, the active field and its text.
    var sizeEntry = SizeEntry()
    /// Mirror and the sketch patterns: the entities are picked, now the line or the place.
    var sketchOpTarget = false
    /// A tangent arc dragged from the end of a line chain (B-12).
    var tangentArc: TangentArcDrag?
    /// A trim path being dragged across curves (M-16), in sketch coordinates.
    var trimPath: [SIMD2<Double>] = []

    // Selection modes (M-8, M-9, T-11): see SelectionModes.swift.
    /// What a click picks with Select (persisted).
    var selectionFilter: SelectionFilter = SelectionFilter.stored {
        didSet { UserDefaults.standard.set(selectionFilter.rawValue, forKey: SelectionFilter.storageKey) }
    }
    /// The box being dragged, in viewport points, and whether it is a crossing box.
    var selectionBox: SelectionBox?
    /// The pick list of overlapping items open after a press and hold.
    var pickList: PickList?
    /// Taps come from a finger (iPad, iPhone): a tap on nothing clears the sketch selection even
    /// though taps toggle.
    @ObservationIgnored var touchTaps: Bool = {
        #if os(iOS)
        true
        #else
        false
        #endif
    }()
    /// The sketch Extrude takes when it is not the last one (a profile tapped, T-8).
    var extrudeSketch: Int?
    /// The sketch of the feature being edited, by feature id (read once per edit).
    @ObservationIgnored var editSketchCache: (feature: Int, sketch: Int?)?

    init() {
        Perf.watchMainThread()
        Perf.milestone("design model init")
        onMainActor { _ in SketchSelfTest.runIfAsked(); SketchCoreSelfTest.runIfAsked() }
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
        // The pick list names meshes and faces of the scene it was opened on.
        if pickList != nil { pickList = nil }
        if !previewApplied && !sessionPreviewApplied { bodiesBeforePreview = nil }
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
        if pickList != nil { pickList = nil }
        if final { exitSketchIfTurnedAway() }
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
        if sketchHoverHandled(at: p) { return }
        if tool.isSketchTool, sketchPlane != nil {
            sketchToolHover(at: p)
            return
        }
        if tool == .extrude, let info = sketchInfo {
            let q = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize)
            let i = q.flatMap { info.profile(at: $0)?.index }
            if i != hoverProfile { hoverProfile = i }
            return
        }
        hover = tool == .select ? filteredPick(at: p) : ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: wantsEdges)
    }

    var wantsEdges: Bool { tool == .select || tool == .fillet || tool == .chamfer }

    /// A click or tap. `additive` keeps the selection (Shift on a Mac, the default on touch).
    /// How a click changes the selection (FRONTEND-SPEC 7.3): click replaces, Shift adds,
    /// Command toggles. Touch taps toggle.
    enum SelectMode { case replace, add, toggle }

    func click(at p: CGPoint, additive: Bool) {
        click(at: p, mode: additive ? .toggle : .replace)
    }

    func click(at p: CGPoint, mode: SelectMode) {
        if sketchClickHandled(at: p, mode: mode) { return }
        let additive = mode != .replace
        if pickList != nil { pickList = nil }
        if tool.isSketchTool {
            sketchToolClick(at: p, mode: mode)
            return
        }
        if tool == .extrude, let info = sketchInfo, info.profiles.count > 1 {
            if let q = ScenePicker.onPlane(info.plane, camera: camera, at: p, size: viewSize), let prof = info.profile(at: q) {
                toggleProfile(prof.index)
            }
            return
        }
        let hit = tool == .select && facePick == nil ? filteredPick(at: p) : ScenePicker.pick(scene, camera: camera, at: p, size: viewSize, edges: wantsEdges)
        if tool == .select, facePick == nil, selectionFilter == .body {
            selectBody(of: hit, mode: mode)
            return
        }
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
            if !additive { replaceSelection() }
            return
        }
        let present = selection.firstIndex(where: { $0.sameEntity(hit) })
        switch mode {
        case .toggle:
            if let present { selection.remove(at: present) } else { selection.append(hit) }
        case .add:
            if present == nil { selection.append(hit) }
        case .replace:
            replaceSelection([hit])
        }
        if tool == .pressPull || tool == .fillet || tool == .chamfer || tool == .shell { applyPreview() }
    }

    /// A double click or tap selects the whole body; on a sketch curve with Select it selects the
    /// curve's chain (M-16).
    func doubleClick(at p: CGPoint) {
        if chainSelect(at: p) { return }
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
        clickSnaps = []
        run("sketch.finish", quiet: true)
        tool = .select
    }

    /// T-17: with `SketchDisplaySettings.exitOnOrbitKey` on, the open sketch finishes once the
    /// view rests more than 60 degrees away from square to its plane.
    private func exitSketchIfTurnedAway() {
        guard SketchDisplaySettings.exitOnOrbit, sketchOpen, let plane = sketchPlane,
              Self.turnedAway(back: camera.back, normal: plane.normal) else { return }
        finishSketch()
    }

    /// The view direction is more than 60 degrees from the plane's normal.
    static func turnedAway(back: SIMD3<Double>, normal: SIMD3<Double>) -> Bool {
        guard simd_length(back) > 1e-9, simd_length(normal) > 1e-9 else { return false }
        return abs(simd_dot(simd_normalize(back), simd_normalize(normal))) < 0.5
    }

    func look(along normal: SIMD3<Double>) {
        let n = simd_normalize(normal)
        camera.pitch = asin(min(max(n.z, -1), 1))
        camera.yaw = abs(n.z) > 0.9999 ? 0 : atan2(-n.x, -n.y)
        camera.roll = 0
        cameraChanged()
    }

    // Snapping, the sketch tools' clicks, the rubber band and typed sizes: SketchDrawing.swift.

    // MARK: Solid tools

    private func toolChanged(from old: Tool) {
        if pickList != nil { pickList = nil }
        previewError = nil
        // The typed-options session (FeatureSession) drops its own preview when its tool goes.
        defer { onMainActor { FeatureSession.of($0).sync() } }
        if previewCheckpoint != nil { cancelPreview() }
        clicks = []
        cursor = nil
        drawingToolChanged()
        sketchToolChanged()
        extrudeProfiles = []
        hoverProfile = nil
        if tool != .extrude { extrudeSketch = nil }
        if armingQuietly {
            toolValue = 0
            // Editing a feature arms its tool quietly: the canvas still shows that feature's
            // sketch (an extrude's own profiles, not the last sketch's).
            if tool == .extrude || old == .extrude { reloadSketchInfo() }
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
        // The dialog's session holds the preview (typed options, an edit): it runs the command
        // itself, so the model lays no second preview over it.
        let owned = onMainActorNow(false) { m -> Bool in
            let session = FeatureSession.of(m)
            guard session.ownsPreview else { return false }
            session.sync()
            return true
        }
        if owned { return }
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
            if let s = extrudeSketch { p["sketch"] = s }
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
            previewError = nil
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
            notePreviewBaseline()
            if previewCheckpoint == nil {
                let r = try engine.execute("edit.checkpoint") as? [String: Any]
                previewCheckpoint = r?["checkpoint"] as? Int
            }
            try engine.execute(id, params)
            previewApplied = true
            previewError = nil
            flash(nil)
        } catch {
            previewError = error.localizedDescription
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
        previewError = nil
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
        previewError = nil
        refresh()
    }

    var hasPreview: Bool { previewApplied }

    /// Notes the bodies there are before a preview runs; the first preview of a tool sets it,
    /// later values keep it (the snapshot may still show the last preview then).
    func notePreviewBaseline() {
        if bodiesBeforePreview == nil { bodiesBeforePreview = Set(snapshot.bodies.map(\.name)) }
    }

    /// The bodies the browser lists: all of them, less those a running preview made.
    var listedBodies: [DesignSnapshot.Body] {
        guard let before = bodiesBeforePreview, previewApplied || sessionPreviewApplied else { return snapshot.bodies }
        return snapshot.bodies.filter { before.contains($0.name) }
    }

    func cancelTool() {
        if cancelDrawingStep() { return }
        if !clicks.isEmpty { clicks = []; clickSnaps = []; return }
        if cancelSketchPicks() { return }
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
        if sketchOpen, !sketchSelection.isEmpty { deleteSketchSelection(); return }
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
            return "\(name)  V \(VFFormat.volume(v))  A \(VFFormat.area(a))  \(VFFormat.mass(m))"
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

    func undo() {
        abandonPreviews()
        run("edit.undo", quiet: true)
    }
    func redo() {
        abandonPreviews()
        run("edit.redo", quiet: true)
    }

    /// Before the history moves (undo, redo, new, open): an open dialog and its preview go first,
    /// so no checkpoint is restored over a history it no longer belongs to.
    func abandonPreviews() {
        let hasCheckpoint = previewCheckpoint != nil
        onMainActor { m in
            let session = FeatureSession.of(m)
            if session.holdsPreview || hasCheckpoint { session.cancel() }
        }
        if previewCheckpoint != nil { cancelPreview() }
    }

    func newDesign() {
        abandonPreviews()
        run("file.new", quiet: true)
        if let home = engine.homeCamera() { camera = home }
        cameraChanged()
    }

    func open(_ url: URL) {
        #if os(macOS)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        #endif
        abandonPreviews()
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

extension DesignModel {
    // The model is used from the main thread only, but is not marked @MainActor (the views and
    // helpers that read it are not all isolated yet). These hop explicitly instead of assuming
    // isolation, so a call off the main thread queues the work rather than trapping.

    /// Runs `body` on the main actor: now when this is the main thread, else queued there.
    func onMainActor(_ body: @escaping @MainActor (DesignModel) -> Void) {
        let me = UncheckedWeak(self)
        if Thread.isMainThread {
            MainActor.assumeIsolated { if let m = me.value { body(m) } }
        } else {
            DispatchQueue.main.async { if let m = me.value { body(m) } }
        }
    }

    /// The main actor's answer now when this is the main thread; `fallback` off it.
    func onMainActorNow<T: Sendable>(_ fallback: T, _ body: @MainActor (DesignModel) -> T) -> T {
        guard Thread.isMainThread else { return fallback }
        nonisolated(unsafe) let me = self
        return MainActor.assumeIsolated { body(me) }
    }
}

/// A weak reference handed to a main-queue callback. The model lives on the main thread; the
/// callback runs there too.
private final class UncheckedWeak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}
