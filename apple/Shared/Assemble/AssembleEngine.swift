import Foundation
import simd
import ViaFormFFI

/// The two engines behind the Assemble stage: the assembly document (`vf_asm_*`, viaform-asm v1)
/// and the kinematic model built from it (`vf_kin_*`). JSON for the document ops; the binary
/// `vf_kin_drag_move` for the end effector drag, called on the main thread per pointer event.
final class AssembleEngine {
    private var asm: OpaquePointer?
    private let kin: OpaquePointer?

    init() {
        asm = vf_asm_new()
        kin = vf_kin_new()
    }

    deinit {
        vf_asm_free(asm)
        vf_kin_free(kin)
    }

    /// Replaces the document with an `assembly.json` text. False when it does not read.
    func open(json: String) -> Bool {
        guard let h = vf_asm_open(json) else { return false }
        vf_asm_free(asm)
        asm = h
        return true
    }

    /// One `vf_asm_call`. Throws the engine's error message.
    @discardableResult
    func call(_ op: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        guard let asm else { throw AssembleError("the assembly engine did not start") }
        let text = Self.encode(params)
        let reply = RustFlow.take(vf_asm_call(asm, nil, op, text))
        return try Self.unwrap(reply)
    }

    /// One `vf_kin_call`.
    @discardableResult
    func kinCall(_ op: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        guard let kin else { throw AssembleError("the kinematics engine did not start") }
        let reply = RustFlow.take(vf_kin_call(kin, op, Self.encode(params)))
        return try Self.unwrap(reply)
    }

    /// One drag move (60 fps path): target `[x, y, z, qw, qx, qy, qz]` in metres. Fills `q` (rad)
    /// and `links` (column-major 4x4 per link, metres). 0 reached, 1 stretching, -1 error.
    func dragMove(_ target: [Double], q: inout [Double], links: inout [Float]) -> Int32 {
        guard let kin, target.count == 7 else { return -1 }
        let n = Int32(q.count), nl = Int32(links.count / 16)
        return target.withUnsafeBufferPointer { t in
            q.withUnsafeMutableBufferPointer { qb in
                links.withUnsafeMutableBufferPointer { lb in
                    vf_kin_drag_move(kin, t.baseAddress, qb.baseAddress, n, lb.baseAddress, nl)
                }
            }
        }
    }

    /// Distance left (m) and orientation error (rad) of the last drag move.
    func dragError() -> (distance: Double, angle: Double)? {
        guard let kin else { return nil }
        var out = [0.0, 0.0]
        let r = out.withUnsafeMutableBufferPointer { vf_kin_drag_error(kin, $0.baseAddress) }
        return r == 0 ? (out[0], out[1]) : nil
    }

    // MARK: JSON

    static func encode(_ params: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: params) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func unwrap(_ reply: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any] else {
            throw AssembleError("unreadable engine reply")
        }
        if let e = object["error"] as? String { throw AssembleError(e) }
        if let ok = object["ok"] as? [String: Any] { return ok }
        return object
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value) || value is [Any],
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

struct AssembleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Document types (viaform-asm v1, the fields the screens use)

struct AsmProxy: Codable, Equatable {
    var min_mm: [Double]
    var max_mm: [Double]
    var mass_kg: Double?
}

struct AsmPartRef: Codable, Equatable {
    var part: String
    var at_mm: [Double]?
    var dims_mm: [Double]?
}

struct AsmComponent: Codable, Identifiable, Equatable {
    var id: String
    var name: String?
    var proxy: AsmProxy?
    var parts: [AsmPartRef]?
    var title: String { (name?.isEmpty == false ? name : nil) ?? id.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct AsmLimits: Codable, Equatable {
    var lower_deg: Double?
    var upper_deg: Double?
    var lower_mm: Double?
    var upper_mm: Double?
    var velocity_dps: Double?
    var effort_nm: Double?
}

struct AsmMotor: Codable, Equatable {
    var part: String
    var gear_ratio: Double?
    var backlash_deg: Double?
    var bus_id: Int?
    var stall_torque_nm: Double?
    var no_load_speed_dps: Double?
    var voltage_v: Double?
}

struct AsmJoint: Codable, Identifiable, Equatable {
    var id: String
    var type: String?
    var parent: String
    var child: String
    var origin: [Double]
    var axis: [Double]
    var limits: AsmLimits?
    var motor: AsmMotor?
    var damping: Double?
    var friction: Double?

    var kind: String { type ?? "revolute" }
    var angular: Bool { kind != "prismatic" }
    var unit: String { angular ? "deg" : "mm" }
    var range: ClosedRange<Double>? {
        guard let l = limits else { return nil }
        let lo = angular ? l.lower_deg : l.lower_mm, hi = angular ? l.upper_deg : l.upper_mm
        guard let lo, let hi, hi >= lo else { return nil }
        return lo...hi
    }
    var title: String { id.replacingOccurrences(of: "_", with: " ").capitalized }
}

struct AsmPose: Codable, Equatable, Identifiable {
    var id: String
    var q_deg: [String: Double]
}

struct AsmDocument: Codable, Equatable {
    var name: String?
    var ground: String?
    var components: [AsmComponent]
    var joints: [AsmJoint]
    var poses: [AsmPose]?
    var grasps: [AsmGrasp]?
}

struct AsmGrasp: Codable, Equatable, Identifiable {
    struct Object: Codable, Equatable { var shape: String; var size_m: [Double] }
    struct Tip: Codable, Equatable { var frame: String; var point_m: [Double]; var normal: [Double]?; var priority: Int }
    var id: String
    var object: Object
    var fingertips: [Tip]
    var q_deg: [String: Double]?
    var actuators: [String: Double]?
}

/// One component pose from the engine: column-major 4x4, mm.
struct AsmComponentPose: Decodable {
    var component: String
    var matrix: [Double]
    var simd: simd_float4x4 {
        guard matrix.count == 16 else { return matrix_identity_float4x4 }
        let f = matrix.map(Float.init)
        return simd_float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                                       SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15])))
    }
}

struct AsmMassProps: Equatable {
    var totalKg: Double
    var comMM: SIMD3<Double>
    /// ixx iyy izz ixy ixz iyz, kg·mm²
    var inertia: [Double]
    var boughtKg: Double
    var perComponent: [(id: String, kg: Double)]
    var warnings: [String]

    static func == (a: Self, b: Self) -> Bool { a.totalKg == b.totalKg && a.comMM == b.comMM }
}

struct AsmInterference: Identifiable, Equatable {
    var a: String
    var b: String
    var volumeMM3: Double
    var regionMin: SIMD3<Double>
    var regionMax: SIMD3<Double>
    var id: String { a + "|" + b }
}

/// A motion study run: per step the time, every joint value and the component poses.
struct AsmMotionStudy: Equatable {
    struct Step: Equatable {
        var time: Double
        var q: [String: Double]
        var poses: [String: simd_float4x4]
        var collisions: [String]
        static func == (a: Self, b: Self) -> Bool { a.time == b.time && a.q == b.q && a.collisions == b.collisions }
    }
    struct Contact: Equatable { var a: String; var b: String; var time: Double }
    var id: String
    var title: String
    var steps: [Step]
    var firstContacts: [Contact]
    var duration: Double { steps.last?.time ?? 0 }
}

/// Joint values for display: rounded, never "-0".
enum AsmFormat {
    static func deg(_ v: Double, digits: Int = 0) -> String {
        let p = pow(10.0, Double(digits))
        let r = (v * p).rounded() / p
        return String(format: "%.\(digits)f°", r == 0 ? 0 : r)
    }
}
