import Foundation
import Observation
import ViaFormFFI

/// Generative design through the C bridge: `sc_generate_study` runs a 3D study (a JSON with
/// "min", "max" and "voxel") and answers `{"ok": Outcome}` or `{"error": message}`;
/// `sc_generate` builds one candidate into a design session. Shapes and names are those of
/// `generative/src/solid/mod.rs`. Units: mm, N, N·mm, MPa, g/mm³, s, Hz.
enum GenerateEngine {
    /// The study as the engine reads it.
    static func json(_ study: Study) throws -> String {
        String(decoding: try JSONEncoder().encode(study), as: UTF8.self)
    }

    /// Runs a study. Pure (no session), so it runs off the main actor; it can take minutes.
    static func study(_ study: Study) throws -> StudyOutcome {
        let text = try json(study)
        guard let p = sc_generate_study(text) else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(p) }
        // Read straight from the engine's buffer: replies with meshes run to tens of megabytes.
        let reply: JSONValue
        do {
            reply = try JSONValue.parse(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)))
        } catch {
            throw EngineError(message: "Unreadable study reply: \(error.localizedDescription)")
        }
        if let error = reply["error"].string { throw EngineError(message: error) }
        guard case .object = reply["ok"] else { throw EngineError(message: "The engine answered no outcome") }
        return StudyOutcome(reply["ok"])
    }

    /// Builds candidate `candidate` (nil: the study's best) of `study` into the design behind
    /// `session`, as one undo step. The engine reruns the study (it is deterministic), so this
    /// takes as long as the run did; the caller keeps every other use of the session away
    /// meanwhile ([`EngineGate`]). Answers the built body's name and the commands it took.
    static func build(_ study: Study, candidate: Int?, into session: SessionHandle) throws -> (body: String, commands: Int) {
        let text = try json(study)
        guard let p = sc_generate(session.pointer, text, Int64(candidate ?? -1)) else {
            throw EngineError(message: "No reply from the generative engine")
        }
        defer { sc_string_free(p) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]
        guard let obj else { throw EngineError(message: "Unreadable build reply") }
        if let error = obj["error"] as? String { throw EngineError(message: error) }
        let ok = obj["ok"] as? [String: Any] ?? [:]
        return (ok["body"] as? String ?? study.name, ok["commands"] as? Int ?? 0)
    }
}

extension GenerateEngine {
    /// Runs a study given as the engine's own JSON (a file written by the engine's examples) and
    /// builds its best candidate into the design. Answers the engine's reply text.
    static func buildRaw(_ text: String, into session: SessionHandle) throws -> String {
        guard let p = sc_generate(session.pointer, text, -1) else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(p) }
        return try okText(String(cString: p))
    }

    /// Inserts a generated assembly (parts, placements, joints); relative part files are read
    /// from the assembly file's folder. One undo step.
    static func assemble(path: String, into session: SessionHandle) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EngineError(message: "Unreadable assembly \(path)") }
        obj["base_dir"] = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let text = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        guard let p = sc_generate_assembly(session.pointer, text) else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(p) }
        return try okText(String(cString: p))
    }

    private static func okText(_ reply: String) throws -> String {
        let obj = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        if let error = obj?["error"] as? String { throw EngineError(message: error) }
        return reply
    }
}

/// The design session's pointer, handed to a background build while the gate is shut.
struct SessionHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Shut while a background task owns the design session (building a candidate): the front ends
/// disable everything that would reach the engine until it opens again.
@MainActor
@Observable
final class EngineGate {
    static let shared = EngineGate()
    /// What holds the session, for the busy banner; nil when open.
    var holder: String?
    var shut: Bool { holder != nil }
}

/// A 3D study running in the engine on its own thread (`vf_generate_*`): progress to poll,
/// cancel, the outcome once done, and candidates built from it without running it again.
final class GenerateJob: @unchecked Sendable {
    /// Where the run is, as the engine reports it.
    struct Progress: Sendable, Equatable {
        var running = true
        var cancelled = false
        var variant = 0
        var variants = 1
        var iteration = 0
        var iterations = 1
        var objective: Double?
        var stage = "starting"
        /// 0...1 over every variant.
        var fraction = 0.0
        var seconds = 0.0
        var paused = false
        /// Seconds still to solve (the engine's pace times the iterations left), nil until two
        /// iterations ran.
        var eta: Double?
        var perIteration: Double?
        /// The latest live preview's version (0: none yet).
        var previewVersion = 0
    }

    /// One iteration's figures, as the convergence plot draws them.
    struct LiveStep: Sendable, Equatable, Identifiable {
        var variant: Int
        var iteration: Int
        var iterations: Int
        var objective: Double
        /// Weighted compliance, N·mm.
        var compliance: Double
        /// Volume fraction of the design voxels.
        var volume: Double
        /// Peak relaxed von Mises on the material, MPa.
        var maxStress: Double
        var seconds: Double
        var id: Int { variant * 100_000 + iteration }
    }

    /// The running shape: a coarse iso surface of the latest densities.
    struct LivePreview: Sendable {
        var version: Int
        var variant: Int
        var iteration: Int
        var mesh: StudyMesh
    }

    private let pointer: OpaquePointer
    private let lock = NSLock()

    /// Starts `json` (an engine study); throws when it does not read.
    init(json: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard let p = vf_generate_start(json, &err) else {
            var message = "The study could not start"
            if let err {
                if let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: err).utf8)) as? [String: Any], let e = obj["error"] as? String { message = e }
                sc_string_free(err)
            }
            throw EngineError(message: message)
        }
        pointer = p
    }

    deinit { vf_generate_free(pointer) }

    func cancel() { vf_generate_cancel(pointer) }

    var progress: Progress {
        guard let p = vf_generate_progress(pointer) else { return Progress() }
        defer { sc_string_free(p) }
        let o = (try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]) ?? [:]
        return Progress(running: o["running"] as? Bool ?? false, cancelled: o["cancelled"] as? Bool ?? false,
                        variant: o["variant"] as? Int ?? 0, variants: o["variants"] as? Int ?? 1,
                        iteration: o["iteration"] as? Int ?? 0, iterations: o["iterations"] as? Int ?? 1,
                        objective: o["objective"] as? Double, stage: o["stage"] as? String ?? "",
                        fraction: o["fraction"] as? Double ?? 0, seconds: o["seconds"] as? Double ?? 0,
                        paused: o["paused"] as? Bool ?? false, eta: o["eta"] as? Double, perIteration: o["per_iteration"] as? Double,
                        previewVersion: o["preview"] as? Int ?? 0)
    }

    /// Holds the run after its current iteration, or lets it go on.
    func setPaused(_ paused: Bool) { vf_generate_pause(pointer, paused) }

    /// The iterations from `from` on (never waits).
    func history(from: Int) -> [LiveStep] {
        guard let p = vf_generate_history(pointer, UInt64(max(from, 0))) else { return [] }
        defer { sc_string_free(p) }
        let rows = (try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [[String: Any]]) ?? []
        func num(_ v: Any?) -> Double { (v as? Double) ?? (v as? Int).map(Double.init) ?? .nan }
        return rows.map { r in
            LiveStep(variant: r["variant"] as? Int ?? 0, iteration: r["iteration"] as? Int ?? 0, iterations: r["iterations"] as? Int ?? 0,
                     objective: num(r["objective"]), compliance: num(r["compliance"]), volume: num(r["volume"]),
                     maxStress: num(r["max_stress"]), seconds: num(r["seconds"]))
        }
    }

    /// The live shape when newer than `since` (call off the main actor: the engine surfaces it
    /// on this thread). Never waits for the run.
    func preview(since: Int) -> LivePreview? {
        guard let m = vf_generate_preview(pointer, UInt64(max(since, 0))) else { return nil }
        defer { vf_generate_mesh_free(m) }
        let mesh = Self.copy(m.pointee)
        return LivePreview(version: Int(m.pointee.version), variant: Int(m.pointee.variant), iteration: Int(m.pointee.iteration), mesh: mesh)
    }

    /// Waits for the run, then candidate `candidate`'s final surface (nil: the best).
    func mesh(candidate: Int?) -> StudyMesh? {
        guard let m = vf_generate_mesh(pointer, Int64(candidate ?? -1)) else { return nil }
        defer { vf_generate_mesh_free(m) }
        return Self.copy(m.pointee)
    }

    private static func copy(_ m: VfGenMesh) -> StudyMesh {
        var out = StudyMesh()
        let nv = Int(m.vertex_count), ni = Int(m.index_count)
        if let p = m.positions, nv > 0 { out.positions = Array(UnsafeBufferPointer(start: p, count: 3 * nv)) }
        if let i = m.indices, ni > 0 { out.indices = Array(UnsafeBufferPointer(start: i, count: ni)) }
        if let s = m.stress, nv > 0 { out.stress = Array(UnsafeBufferPointer(start: s, count: nv)) }
        return out
    }

    /// Waits for the run (call off the main actor), then reads its candidates' figures (no
    /// densities) and their surfaces as flat arrays: the fast way to open results.
    func summary() throws -> StudyOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let p = vf_generate_summary(pointer) else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(p) }
        let reply: JSONValue
        do {
            reply = try JSONValue.parse(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)))
        } catch {
            throw EngineError(message: "Unreadable study reply: \(error.localizedDescription)")
        }
        if let error = reply["error"].string { throw EngineError(message: error) }
        guard case .object = reply["ok"] else { throw EngineError(message: "The engine answered no outcome") }
        var o = StudyOutcome(reply["ok"])
        for i in o.candidates.indices {
            if let m = mesh(candidate: i) { o.candidates[i].mesh = m }
        }
        return o
    }

    /// A variant of the study `base` (engine JSON): `variant` lays a volume fraction, material,
    /// process ("fdm", "sls", "cnc3") or any study field over it. Answers the variant's JSON.
    static func variant(base: String, variant: [String: Any]) throws -> String {
        let v = String(decoding: try JSONSerialization.data(withJSONObject: variant), as: UTF8.self)
        guard let p = vf_generate_variant(base, v) else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(p) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]
        if let e = obj?["error"] as? String { throw EngineError(message: e) }
        guard let ok = obj?["ok"] else { throw EngineError(message: "The engine answered no variant") }
        return String(decoding: try JSONSerialization.data(withJSONObject: ok), as: UTF8.self)
    }

    /// Waits for the run (call off the main actor), then reads its outcome.
    func outcome() throws -> StudyOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard let p = vf_generate_outcome(pointer) else { throw EngineError(message: "No reply from the generative engine") }
        defer { sc_string_free(p) }
        let reply: JSONValue
        do {
            reply = try JSONValue.parse(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)))
        } catch {
            throw EngineError(message: "Unreadable study reply: \(error.localizedDescription)")
        }
        if let error = reply["error"].string { throw EngineError(message: error) }
        guard case .object = reply["ok"] else { throw EngineError(message: "The engine answered no outcome") }
        return StudyOutcome(reply["ok"])
    }

    /// Builds candidate `candidate` (nil: the best) into the design as one mesh body, one undo
    /// step. The caller keeps the session to itself meanwhile ([`EngineGate`]).
    func build(candidate: Int?, into session: SessionHandle) throws -> (body: String, commands: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let p = vf_generate_build(session.pointer, pointer, Int64(candidate ?? -1)) else {
            throw EngineError(message: "No reply from the generative engine")
        }
        defer { sc_string_free(p) }
        let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]
        guard let obj else { throw EngineError(message: "Unreadable build reply") }
        if let error = obj["error"] as? String { throw EngineError(message: error) }
        let ok = obj["ok"] as? [String: Any] ?? [:]
        return (ok["body"] as? String ?? "Generated", ok["commands"] as? Int ?? 1)
    }
}
