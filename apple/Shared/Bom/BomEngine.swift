import Foundation
import ViaFormFFI

/// The bill of materials through the C bridge (`vf_bom_*`, crate `viaform-bom`): one handle
/// and one JSON call. Calls that read the design or the board take their sessions.
///
/// Every call runs on one serial queue, in the order it was asked for, so the handle is never
/// used from two threads at once. `run` answers off the main actor (imports, exports, edits,
/// price checks, and the calls that read the design or the board: the project file's save and
/// open, bringing in design parts and PCB components), holding those engines' sessions for the
/// whole call. `call` waits for its turn on the caller's thread (the BOM's first state, and the
/// Generate self-test's assembly import).
final class BomEngine: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "me.somalabs.viaform.bom", qos: .userInitiated)

    init() {
        guard let h = vf_bom_new() else { fatalError("The bill of materials could not start") }
        handle = h
    }

    deinit { vf_bom_free(handle) }

    /// Runs `method` and answers the `ok` value as JSON data, waiting for the calls before it.
    func call(_ method: String, _ params: [String: Any] = [:], design: OpaquePointer? = nil, pcb: OpaquePointer? = nil) throws -> Data {
        let body = Self.body(params)
        return try queue.sync { try perform(method, body, design: design, pcb: pcb) }
    }

    /// Runs `method` off the caller's thread, after the calls asked for before it. `json` is the
    /// parameters as JSON text (`BomEngine.json(_:)`), made on the caller's side.
    func run(_ method: String, json body: String) async throws -> Data {
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            queue.async { c.resume(with: Result { try self.perform(method, body, design: nil, pcb: nil) }) }
        }
    }

    /// Runs `method` off the caller's thread with the design and the board sessions held for the
    /// whole call (`CADEngine.withSession`, `PCBEngine.withSession`, always in that order, the
    /// order the board link takes them on the main thread). The main thread waits for these
    /// sessions only if it touches the design or the board while the call runs.
    func run(_ method: String, json body: String, design: CADEngine?, pcb: PCBEngine?) async throws -> Data {
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            queue.async {
                c.resume(with: Result {
                    func board(_ sc: OpaquePointer?) throws -> Data {
                        guard let pcb else { return try self.perform(method, body, design: sc, pcb: nil) }
                        return try pcb.withSession { try self.perform(method, body, design: sc, pcb: $0) }
                    }
                    guard let design else { return try board(nil) }
                    return try design.withSession { try board($0) }
                })
            }
        }
    }

    /// Parameters as the JSON text a call takes.
    static func json(_ params: [String: Any]) -> String { body(params) }

    private static func body(_ params: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func perform(_ method: String, _ body: String, design: OpaquePointer?, pcb: OpaquePointer?) throws -> Data {
        guard let p = vf_bom_call(handle, design, pcb, method, body) else { throw EngineError(message: "No reply from the bill of materials") }
        defer { sc_string_free(p) }
        let reply = Data(String(cString: p).utf8)
        guard let obj = try JSONSerialization.jsonObject(with: reply, options: .fragmentsAllowed) as? [String: Any] else {
            throw EngineError(message: "Unreadable bill of materials reply")
        }
        if let e = obj["error"] as? String { throw EngineError(message: e) }
        return try JSONSerialization.data(withJSONObject: obj["ok"] ?? NSNull(), options: .fragmentsAllowed)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
