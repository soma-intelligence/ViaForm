import Foundation
import ViaFormFFI

/// The bill of materials through the C bridge (`vf_bom_*`, crate `viaform-bom`): one handle
/// and one JSON call. Calls that read the design or the board take their sessions.
///
/// Every call runs on one serial queue, in the order it was asked for: `run` answers off the main
/// actor (imports, exports, edits, price checks), `call` waits for its turn (the project file's
/// save and open, which read the design and board sessions on the main actor).
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
