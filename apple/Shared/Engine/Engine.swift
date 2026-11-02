import Foundation
import SolidCraftFFI
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

/// The engine's flattened scene, copied into Swift arrays so it outlives the Rust buffers.
struct SceneData {
    struct Mesh {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var indices: [UInt32]
        /// B-rep face per triangle.
        var triFace: [UInt32]
        /// B-rep edge polylines, for picking and highlight.
        var edges: [[SIMD3<Float>]]
        var color: SIMD4<Float>
        var body: String
    }

    struct Line {
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
final class CADEngine {
    let session: OpaquePointer

    init() {
        guard let s = sc_session_new() else { fatalError("SolidCraft engine could not start") }
        session = s
    }

    deinit { sc_session_free(session) }

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
        let reply = Self.take(sc_execute(session, id, params))
        guard let obj = Self.parse(reply) as? [String: Any] else { throw EngineError(message: "No reply from \(id)") }
        if let error = obj["error"] as? String { throw EngineError(message: error) }
        return obj["ok"] ?? NSNull()
    }

    func runScript(_ script: Data) throws {
        let reply = Self.take(sc_run_script(session, String(decoding: script, as: UTF8.self)))
        if let obj = Self.parse(reply) as? [String: Any], let error = obj["error"] as? String {
            throw EngineError(message: error)
        }
    }

    static let commands: [CommandInfo] = {
        let text = take(sc_commands())
        return (try? JSONDecoder().decode([CommandInfo].self, from: Data(text.utf8))) ?? []
    }()

    func homeCamera() -> OrbitCamera? {
        let text = Self.take(sc_home_camera(session))
        return try? JSONDecoder().decode(OrbitCamera.self, from: Data(text.utf8))
    }

    func bounds() -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard let obj = Self.parse(Self.take(sc_bounds(session))) as? [String: [Double]],
              let lo = obj["min"], let hi = obj["max"], lo.count == 3, hi.count == 3 else { return nil }
        return (SIMD3(lo[0], lo[1], lo[2]), SIMD3(hi[0], hi[1], hi[2]))
    }

    func sketchPlane() -> SketchPlane? {
        guard let obj = Self.parse(Self.take(sc_sketch_plane(session))) as? [String: [Double]],
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
            (Int(offs[e])..<Int(offs[e + 1])).map { SIMD3(pts[$0 * 3], pts[$0 * 3 + 1], pts[$0 * 3 + 2]) }
        }
    }

    func scene(camera: OrbitCamera) -> SceneData {
        let camText = (try? String(decoding: JSONEncoder().encode(camera), as: UTF8.self)) ?? "null"
        guard let sc = sc_scene_build(session, camText) else { return SceneData() }
        defer { sc_scene_free(sc) }
        var out = SceneData()
        out.radius = sc_scene_radius(sc)
        for i in 0..<sc_scene_mesh_count(sc) {
            var v = ScMeshView()
            guard sc_scene_mesh(sc, i, &v) else { continue }
            let n = Int(v.vertex_count), k = Int(v.index_count)
            func vec3(_ p: UnsafePointer<Float>?) -> [SIMD3<Float>] {
                guard let p, n > 0 else { return [] }
                return (0..<n).map { SIMD3(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }
            }
            out.meshes.append(.init(
                positions: vec3(v.positions),
                normals: vec3(v.normals),
                indices: v.indices.map { Array(UnsafeBufferPointer(start: $0, count: k)) } ?? [],
                triFace: v.tri_face.map { Array(UnsafeBufferPointer(start: $0, count: k / 3)) } ?? [],
                edges: Self.edges(v),
                color: SIMD4(v.color.0, v.color.1, v.color.2, v.color.3),
                body: sc_scene_body_name(sc, i).map { String(cString: $0) } ?? "Body\(i + 1)"
            ))
        }
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
