import Foundation
import ViaFormFFI

/// The bill of materials through the C bridge (`vf_bom_*`, crate `viaform-bom`): one handle
/// and one JSON call. Calls that read the design or the board take their sessions.
final class BomEngine {
    private let handle: OpaquePointer

    init() {
        guard let h = vf_bom_new() else { fatalError("The bill of materials could not start") }
        handle = h
    }

    deinit { vf_bom_free(handle) }

    /// Runs `method` and answers the `ok` value as JSON data.
    func call(_ method: String, _ params: [String: Any] = [:], design: OpaquePointer? = nil, pcb: OpaquePointer? = nil) throws -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
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
