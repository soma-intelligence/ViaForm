import Foundation
import ViaFormFFI
import simd

/// An error the engine answered with (bad parameters, a failed feature, an unknown command).
struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One command of the engine's registry, as `sc_commands` lists it.
struct CommandInfo: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let tab: String
    let panel: String
    let icon: String
    let key: String?
    let params: String
}

/// The engine's flattened scene, copied into Swift arrays so it outlives the Rust buffers. Plain
/// values only, so a scene built on the scene worker can be handed to the main thread.
struct SceneData: Sendable {
    struct Mesh: Sendable {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
        /// B-rep face per triangle.
        var triFace: [UInt32]
        /// B-rep edge polylines, for picking and highlight.
        var edges: [[SIMD3<Float>]]
        var color: SIMD4<Float>
        var body: String
        /// Axis-aligned bounds of `positions`, so picking can skip a body the ray misses.
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
    }

    struct Line: Sendable {
        var points: [SIMD3<Float>]
        var color: SIMD4<Float>
        var width: Float
        var onTop: Bool
    }

    var meshes: [Mesh] = []
    var lines: [Line] = []
    var grid: [Line] = []
    var radius: Float = 100
    var revision = 0
    /// Unique per build of the meshes: a renderer that already uploaded this scene's bodies
    /// (another viewport, a workspace switched back to) reuses its GPU buffers.
    var serial = 0
    nonisolated(unsafe) private static var lastSerial = 0
    private static let serialLock = NSLock()
    static func nextSerial() -> Int {
        serialLock.lock()
        defer { serialLock.unlock() }
        lastSerial += 1
        return lastSerial
    }
}

/// A sketch plane in world coordinates.
struct SketchPlane: Equatable {
    var origin: SIMD3<Double>
    var x: SIMD3<Double>
    var y: SIMD3<Double>
    var normal: SIMD3<Double> { simd_normalize(simd_cross(x, y)) }

    func toSketch(_ p: SIMD3<Double>) -> SIMD2<Double> {
        let d = p - origin
        return SIMD2(simd_dot(d, x), simd_dot(d, y))
    }

    func toWorld(_ p: SIMD2<Double>) -> SIMD3<Double> { origin + x * p.x + y * p.y }
}

/// The SolidCraft engine behind the C ABI: one open design.
///
/// The session is not thread safe, so every call holds `lock`. The main thread runs commands;
/// the scene worker (`DesignModel.rebuildScene`) builds big scenes off the main thread under the
/// same lock. Code outside this class that takes `session` for its own C calls (the board link,
/// the BOM, the generative engine) gets it on the main thread, which then holds the lock until
/// the end of the current run loop turn, so a background build never overlaps those calls.
final class CADEngine: @unchecked Sendable {
    private let raw: OpaquePointer
    private let lock = NSRecursiveLock()
    /// The main thread holds the lock for the rest of this run loop turn.
    private var mainHold = false

    /// The session pointer for direct C calls. On the main thread, blocks until a scene build
    /// on the worker is done and keeps the worker out until the run loop turns.
    var session: OpaquePointer {
        if Thread.isMainThread && !mainHold {
            lock.lock()
            mainHold = true
            DispatchQueue.main.async { [self] in
                mainHold = false
                lock.unlock()
            }
        }
        return raw
    }

    init() {
        guard let s = sc_session_new() else { fatalError("SolidCraft engine could not start") }
        raw = s
    }

    deinit { sc_session_free(raw) }

    /// Runs `body` with the session to itself, on any thread: a worker that hands the session to
    /// another engine (the BOM's project save and open) holds it for the whole call, and the main
    /// thread waits for it only if it touches the design meanwhile.
    func withSession<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T { try locked(body) }

    /// Runs `body` with the session to itself.
    private func locked<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(raw)
    }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "null" }
        defer { sc_string_free(p) }
        return String(cString: p)
    }

    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// Runs one command and returns its reply.
    @discardableResult
    func execute(_ id: String, _ params: [String: Any] = [:]) throws -> Any {
        try executeJSON(id, Self.json(params))
    }

    /// Runs one command with parameters given as JSON text (the generic command dialog).
    @discardableResult
    func executeJSON(_ id: String, _ params: String) throws -> Any {
        let reply = locked { Self.take(sc_execute($0, id, params)) }
        guard let obj = Self.parse(reply) as? [String: Any] else { throw EngineError(message: "No reply from \(id)") }
        if let error = obj["error"] as? String { throw EngineError(message: error) }
        let ok = obj["ok"] ?? NSNull()
        note(id, params, ok)
        return ok
    }

    /// The names of the undo and redo steps (`UndoLabels`): "Undo Extrude" in the Edit menu.
    let undoLabels = UndoLabels(limit: 200)

    /// The top undo and redo step names for the depths the snapshot reports.
    func undoNames(undo: Int, redo: Int) -> (undo: String?, redo: String?) { undoLabels.labels(undo: undo, redo: redo) }

    private static let labels: [String: String] = Dictionary(commands.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })

    /// Commands that only read (or save a copy) leave the undo stack alone.
    private static func reads(_ id: String) -> Bool {
        id.hasSuffix(".list") || id.hasSuffix(".inspect") || id.hasSuffix(".metadata") || id.hasSuffix(".revision")
            || id.contains("snap") || id.contains("measure") || id.hasPrefix("select.") || id.hasPrefix("view.")
            || id.hasPrefix("ui.") || id.hasPrefix("file.save") || id.hasPrefix("file.export") || id.hasPrefix("export.")
            || id.hasPrefix("render.") || id == "edit.checkpoint" || id == "edit.restore_checkpoint"
            || id.hasPrefix("inspect.") || id == "component.properties" || id == "timeline.dependents" || id == "sketch.chain"
    }

    private func note(_ id: String, _ params: String, _ ok: Any) {
        let reply = ok as? [String: Any]
        switch id {
        case "edit.undo": undoLabels.undid(reply?["undone"] as? String)
        case "edit.redo": undoLabels.redid(reply?["redone"] as? String)
        case "edit.checkpoint": if let c = reply?["checkpoint"] as? Int { undoLabels.checkpoint(c) }
        case "edit.restore_checkpoint":
            let p = Self.parse(params) as? [String: Any]
            if let c = p?["checkpoint"] as? Int { undoLabels.restored(c, forget: p?["forget"] as? Bool ?? false) }
        case "file.new", "file.open": undoLabels.reset()
        default:
            if !Self.reads(id) { undoLabels.ran(Self.labels[id] ?? "") }
        }
    }

    func runScript(_ script: Data) throws {
        let text = String(decoding: script, as: UTF8.self)
        let reply = locked { Self.take(sc_run_script($0, text)) }
        if let obj = Self.parse(reply) as? [String: Any], let error = obj["error"] as? String {
            throw EngineError(message: error)
        }
    }

    static let commands: [CommandInfo] = {
        let text = take(sc_commands())
        return (try? JSONDecoder().decode([CommandInfo].self, from: Data(text.utf8))) ?? []
    }()

    func homeCamera() -> OrbitCamera? {
        let text = locked { Self.take(sc_home_camera($0)) }
        return try? JSONDecoder().decode(OrbitCamera.self, from: Data(text.utf8))
    }

    func bounds() -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard let obj = Self.parse(locked { Self.take(sc_bounds($0)) }) as? [String: [Double]],
              let lo = obj["min"], let hi = obj["max"], lo.count == 3, hi.count == 3 else { return nil }
        return (SIMD3(lo[0], lo[1], lo[2]), SIMD3(hi[0], hi[1], hi[2]))
    }

    func sketchPlane() -> SketchPlane? {
        guard let obj = Self.parse(locked { Self.take(sc_sketch_plane($0)) }) as? [String: [Double]],
              let o = obj["origin"], let x = obj["x_dir"], let y = obj["y_dir"] else { return nil }
        return SketchPlane(origin: SIMD3(o[0], o[1], o[2]), x: SIMD3(x[0], x[1], x[2]), y: SIMD3(y[0], y[1], y[2]))
    }

    /// The design as the engine describes it: bodies, sketches, timeline and parameters.
    func inspect() -> DesignSnapshot {
        guard let reply = try? execute("document.inspect", ["measure": true]),
              let data = try? JSONSerialization.data(withJSONObject: reply),
              let snap = try? JSONDecoder().decode(DesignSnapshot.self, from: data) else { return DesignSnapshot() }
        return snap
    }

    private static func edges(_ v: ScMeshView) -> [[SIMD3<Float>]] {
        guard let pts = v.edge_points, let offs = v.edge_offsets, v.edge_count > 0 else { return [] }
        return (0..<Int(v.edge_count)).map { e in
            let a = Int(offs[e]), b = Int(offs[e + 1])
            return [SIMD3<Float>](unsafeUninitializedCapacity: max(b - a, 0)) { buf, count in
                for j in a..<max(a, b) { buf[j - a] = SIMD3(pts[j * 3], pts[j * 3 + 1], pts[j * 3 + 2]) }
                count = max(b - a, 0)
            }
        }
    }

    /// The whole scene. Safe from any thread (the scene worker calls it); `Perf` timings are
    /// only taken on the main thread.
    func scene(camera: OrbitCamera) -> SceneData {
        if Thread.isMainThread { return Perf.measure("scene.build") { buildScene(camera: camera, meshes: true) } }
        return buildScene(camera: camera, meshes: true)
    }

    /// The camera-dependent part of the scene only (grid, axes and lines, the view radius): what
    /// an orbit, a pan or a zoom changes. The bodies are not copied.
    func guides(camera: OrbitCamera) -> SceneData {
        Perf.measure("scene.guides") { buildScene(camera: camera, meshes: false) }
    }

    /// The guides, unless the scene worker holds the session (nil): a camera move never waits
    /// for a build, the build brings its own guides.
    func guidesIfFree(camera: OrbitCamera) -> SceneData? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return guides(camera: camera)
    }

    private func buildScene(camera: OrbitCamera, meshes: Bool) -> SceneData {
        let camText = (try? String(decoding: JSONEncoder().encode(camera), as: UTF8.self)) ?? "null"
        lock.lock()
        defer { lock.unlock() }
        let built: OpaquePointer?
        if Thread.isMainThread { built = Perf.measure("scene.ffi", { sc_scene_build(raw, camText) }) } else { built = sc_scene_build(raw, camText) }
        guard let sc = built else { return SceneData() }
        defer { sc_scene_free(sc) }
        var out = SceneData()
        out.radius = sc_scene_radius(sc)
        for i in 0..<(meshes ? sc_scene_mesh_count(sc) : 0) {
            var v = ScMeshView()
            guard sc_scene_mesh(sc, i, &v) else { continue }
            let n = Int(v.vertex_count), k = Int(v.index_count)
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            func vec3(_ p: UnsafePointer<Float>?, bounds: Bool) -> [SIMD3<Float>] {
                guard let p, n > 0 else { return [] }
                return [SIMD3<Float>](unsafeUninitializedCapacity: n) { buf, count in
                    for j in 0..<n {
                        let q = SIMD3(p[j * 3], p[j * 3 + 1], p[j * 3 + 2])
                        if bounds { lo = simd_min(lo, q); hi = simd_max(hi, q) }
                        buf[j] = q
                    }
                    count = n
                }
            }
            var mesh = SceneData.Mesh(
                positions: vec3(v.positions, bounds: true),
                normals: vec3(v.normals, bounds: false),
                indices: v.indices.map { Array(UnsafeBufferPointer(start: $0, count: k)) } ?? [],
                triFace: v.tri_face.map { Array(UnsafeBufferPointer(start: $0, count: k / 3)) } ?? [],
                edges: Self.edges(v),
                color: SIMD4(v.color.0, v.color.1, v.color.2, v.color.3),
                body: sc_scene_body_name(sc, i).map { String(cString: $0) } ?? "Body\(i + 1)"
            )
            mesh.lo = lo
            mesh.hi = hi
            out.meshes.append(mesh)
        }
        if meshes { out.serial = SceneData.nextSerial() }
        for grid in [false, true] {
            for i in 0..<sc_scene_line_count(sc, grid) {
                var l = ScLineView()
                guard sc_scene_line(sc, grid, i, &l), let p = l.points else { continue }
                let pts = (0..<Int(l.point_count)).map { SIMD3(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }
                let line = SceneData.Line(points: pts, color: SIMD4(l.color.0, l.color.1, l.color.2, l.color.3), width: l.width, onTop: l.on_top)
                if grid { out.grid.append(line) } else { out.lines.append(line) }
            }
        }
        return out
    }
}
