import Foundation
import Security
import ViaFormFFI

/// The side libraries through the C bridge (`vf_library_*`, crate `viaform-library`): one handle
/// on the user's library folder and one JSON call answering `{"ok": value}` or `{"error": message}`.
/// Calls block (searches reach the shops' APIs), so the actor runs them off the main thread, one
/// at a time.
actor LibraryEngine {
    /// Owns the handle and frees it with the last reference.
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ p: OpaquePointer) { pointer = p }
        deinit { vf_library_free(pointer) }
    }

    private let handle: Handle

    /// The library folder: Application Support, outside every project and Git repository.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ViaForm/Library", isDirectory: true)
    }

    init?(folder: URL = LibraryEngine.folder) {
        guard let h = vf_library_open(folder.path) else { return nil }
        handle = Handle(h)
    }

    /// Runs `method` and decodes the value of `ok` as `T`.
    func call<T: Decodable>(_ method: String, _ params: some Encodable, as: T.Type = T.self) throws -> T {
        let data = try Self.call(handle.pointer, method, Self.encoder.encode(params))
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Runs `method` when its answer does not matter.
    func run(_ method: String, _ params: some Encodable) throws {
        _ = try Self.call(handle.pointer, method, Self.encoder.encode(params))
    }

    private static func call(_ handle: OpaquePointer, _ method: String, _ params: Data) throws -> Data {
        let text = String(decoding: params, as: UTF8.self)
        guard let p = vf_library_call(handle, method, text) else { throw EngineError(message: "No reply from the library") }
        defer { sc_string_free(p) }
        let reply = Data(String(cString: p).utf8)
        guard let obj = try JSONSerialization.jsonObject(with: reply, options: .fragmentsAllowed) as? [String: Any] else {
            throw EngineError(message: "Unreadable library reply")
        }
        if let error = obj["error"] as? String { throw EngineError(message: error) }
        // Re-encode only the `ok` value, so each call decodes its own type.
        return try JSONSerialization.data(withJSONObject: obj["ok"] ?? NSNull(), options: .fragmentsAllowed)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

/// No answer worth decoding.
struct LibraryNothing: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

/// The API keys of the shops, in the macOS Keychain (generic passwords, this Mac only). They
/// never go to the library folder, a project or Git: the app reads them for each search.
enum LibraryKeychain {
    private static let service = "me.somalabs.viaform.library"

    private static func query(_ source: String, _ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(source).\(key)"]
    }

    static func get(_ source: String, _ key: String) -> String? {
        var q = query(source, key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ source: String, _ key: String, _ value: String) throws {
        SecItemDelete(query(source, key) as CFDictionary)
        var q = query(source, key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = "ViaForm library: \(source) \(key)"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EngineError(message: "Keychain refused the key (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))")
        }
    }

    static func remove(_ source: String, _ key: String) {
        SecItemDelete(query(source, key) as CFDictionary)
    }

    /// The keys of `source` that are set, by id.
    static func keys(_ source: LibrarySource) -> [String: String] {
        var out: [String: String] = [:]
        for k in source.keys ?? [] {
            if let v = get(source.id, k.id), !v.isEmpty { out[k.id] = v }
        }
        return out
    }

    /// Whether every required key of `source` is set.
    static func ready(_ source: LibrarySource) -> Bool {
        let have = keys(source)
        return (source.keys ?? []).allSatisfy { $0.optional || have[$0.id] != nil }
    }
}
