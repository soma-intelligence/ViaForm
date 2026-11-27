import Foundation
import ViaFormFFI

/// The physics engine as the Simulate stage sees it: JSON ops plus the 60 fps pose path. The
/// arm screen talks to this protocol only, so it runs against `RustPhys` (viaform-phys through
/// `vf_phys_*`) and against nothing else when the library is not linked.
protocol PhysEngine: AnyObject {
    func call(_ op: String, _ params: [String: Any]) throws -> [String: Any]
    /// Raw reply, for ops whose `ok` is an array (wrench_history).
    func callRaw(_ op: String, _ params: [String: Any]) throws -> Any
    /// Advances `steps` and writes up to `n` link poses `[x, y, z, qw, qx, qy, qz]` (m).
    func step(_ steps: Int, poses: inout [Double]) -> Int32
    func poses(_ out: inout [Double]) -> Int32
}

final class RustPhys: PhysEngine {
    private let h: OpaquePointer?

    init?() {
        guard let h = vf_phys_new() else { return nil }
        self.h = h
    }

    deinit { vf_phys_free(h) }

    func callRaw(_ op: String, _ params: [String: Any]) throws -> Any {
        let reply = RustFlow.take(vf_phys_call(h, op, AssembleEngine.encode(params)))
        guard let o = (try? JSONSerialization.jsonObject(with: Data(reply.utf8), options: [.fragmentsAllowed])) as? [String: Any] else {
            throw AssembleError("unreadable physics reply")
        }
        if let e = o["error"] as? String { throw AssembleError(e) }
        return o["ok"] ?? NSNull()
    }

    func call(_ op: String, _ params: [String: Any]) throws -> [String: Any] {
        try callRaw(op, params) as? [String: Any] ?? [:]
    }

    func step(_ steps: Int, poses: inout [Double]) -> Int32 {
        let n = Int32(poses.count / 7)
        return poses.withUnsafeMutableBufferPointer { vf_phys_step(h, Int32(steps), $0.baseAddress, n) }
    }

    func poses(_ out: inout [Double]) -> Int32 {
        let n = Int32(out.count / 7)
        return out.withUnsafeMutableBufferPointer { vf_phys_state_poses(h, $0.baseAddress, n) }
    }
}

/// Whether physics is there, asked once: `vf_phys_new` answers a handle.
final class PhysService {
    nonisolated(unsafe) static let shared = PhysService()
    let available: Bool

    private init() {
        available = RustPhys() != nil
    }

    func make() -> PhysEngine? { RustPhys() }
}
