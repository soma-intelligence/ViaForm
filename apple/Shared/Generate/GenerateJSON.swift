import Foundation

/// A small JSON reader for the engine's study replies. They run to tens of megabytes, almost all
/// of it number arrays (mesh positions, indices, stress, densities); Foundation's decoder takes
/// seconds on them, this takes a fraction of one. Arrays of numbers stay packed as `[Double]`
/// (a null in them, serde's NaN, reads as NaN).
enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case numbers([Double])
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var double: Double? {
        if case .number(let v) = self { return v }
        return nil
    }

    var int: Int? { double.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubles: [Double] {
        switch self {
        case .numbers(let v): return v
        case .array(let a): return a.map { $0.double ?? .nan }
        default: return []
        }
    }

    var floats: [Float] { doubles.map(Float.init) }

    var uint32s: [UInt32] {
        doubles.map { $0.isFinite && $0 >= 0 && $0 <= Double(UInt32.max) ? UInt32($0) : 0 }
    }

    var array: [JSONValue] {
        switch self {
        case .array(let a): return a
        case .numbers(let v): return v.map { .number($0) }
        default: return []
        }
    }

    /// Parses `bytes`, or throws with the offset where it stopped.
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> JSONValue {
        var r = Reader(bytes: bytes)
        let v = try r.value()
        r.skipSpace()
        guard r.i == bytes.count else { throw r.fail("trailing text") }
        return v
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in try parse(raw.bindMemory(to: UInt8.self)) }
    }

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var i = 0
        var depth = 0

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        func fail(_ what: String) -> ParseError { ParseError(message: "JSON: \(what) at byte \(i)") }

        @inline(__always) mutating func skipSpace() {
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 { i += 1 } else { break }
            }
        }

        @inline(__always) mutating func peek() -> UInt8? {
            skipSpace()
            return i < bytes.count ? bytes[i] : nil
        }

        mutating func literal(_ word: StaticString, _ v: JSONValue) throws -> JSONValue {
            let n = word.utf8CodeUnitCount
            guard i + n <= bytes.count else { throw fail("truncated literal") }
            for k in 0..<n where bytes[i + k] != word.utf8Start[k] { throw fail("bad literal") }
            i += n
            return v
        }

        mutating func value() throws -> JSONValue {
            guard let c = peek() else { throw fail("unexpected end") }
            switch c {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return .number(try number())
            }
        }

        mutating func object() throws -> JSONValue {
            depth += 1
            guard depth < 256 else { throw fail("nested too deep") }
            defer { depth -= 1 }
            i += 1
            var o: [String: JSONValue] = [:]
            if peek() == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                guard peek() == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let k = try string()
                guard peek() == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                o[k] = try value()
                switch peek() {
                case UInt8(ascii: ","): i += 1
                case UInt8(ascii: "}"): i += 1; return .object(o)
                default: throw fail("expected ',' or '}'")
                }
            }
        }

        mutating func array() throws -> JSONValue {
            depth += 1
            guard depth < 256 else { throw fail("nested too deep") }
            defer { depth -= 1 }
            i += 1
            guard let first = peek() else { throw fail("unexpected end") }
            if first == UInt8(ascii: "]") { i += 1; return .numbers([]) }
            if first == UInt8(ascii: "-") || (first >= 0x30 && first <= 0x39) || first == UInt8(ascii: "n") {
                // A packed number array, unless something else turns up in it.
                var v: [Double] = []
                v.reserveCapacity(64)
                let start = i
                while true {
                    guard let c = peek() else { throw fail("unexpected end") }
                    if c == UInt8(ascii: "n") {
                        _ = try literal("null", .null)
                        v.append(.nan)
                    } else if c == UInt8(ascii: "-") || (c >= 0x30 && c <= 0x39) {
                        v.append(try number())
                    } else {
                        i = start
                        return try mixedArray()
                    }
                    switch peek() {
                    case UInt8(ascii: ","): i += 1
                    case UInt8(ascii: "]"): i += 1; return .numbers(v)
                    default: throw fail("expected ',' or ']'")
                    }
                }
            }
            return try mixedArray()
        }

        /// The rest of an array of any values, from just after its '['.
        mutating func mixedArray() throws -> JSONValue {
            var a: [JSONValue] = []
            while true {
                a.append(try value())
                switch peek() {
                case UInt8(ascii: ","): i += 1
                case UInt8(ascii: "]"): i += 1; return .array(a)
                default: throw fail("expected ',' or ']'")
                }
            }
        }

        mutating func string() throws -> String {
            i += 1
            let start = i
            var plain = true
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    if plain {
                        let s = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
                        i += 1
                        return s
                    }
                    break
                }
                if c == UInt8(ascii: "\\") { plain = false; i += 2 } else { i += 1 }
            }
            guard i < bytes.count else { throw fail("unterminated string") }
            // Escapes: let Foundation read the quoted text.
            let quoted = Data(UnsafeBufferPointer(rebasing: bytes[(start - 1)...i]))
            i += 1
            guard let s = try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed) as? String else {
                throw fail("bad string")
            }
            return s
        }

        private static let exact: [Double] = (0...22).map { pow(10, Double($0)) }

        /// A number: the exact fast path (at most 15 significant digits, a power of ten up to
        /// 22), else `strtod`.
        mutating func number() throws -> Double {
            let start = i
            var negative = false
            if bytes[i] == UInt8(ascii: "-") { negative = true; i += 1 }
            var mantissa: UInt64 = 0
            var digits = 0
            var scale = 0
            var sawDigit = false
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                if digits < 19 { mantissa = mantissa * 10 + UInt64(bytes[i] - 0x30); if mantissa > 0 { digits += 1 } } else { scale += 1 }
                sawDigit = true
                i += 1
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                    if digits < 19 { mantissa = mantissa * 10 + UInt64(bytes[i] - 0x30); if mantissa > 0 { digits += 1 }; scale -= 1 }
                    sawDigit = true
                    i += 1
                }
            }
            guard sawDigit else { throw fail("bad number") }
            var exponent = 0
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                var expNegative = false
                if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
                    expNegative = bytes[i] == UInt8(ascii: "-")
                    i += 1
                }
                var sawExp = false
                while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                    if exponent < 10_000 { exponent = exponent * 10 + Int(bytes[i] - 0x30) }
                    sawExp = true
                    i += 1
                }
                guard sawExp else { throw fail("bad exponent") }
                if expNegative { exponent = -exponent }
            }
            let e = scale + exponent
            if digits <= 15, abs(e) <= 22 {
                let m = Double(mantissa)
                let v = e >= 0 ? m * Self.exact[e] : m / Self.exact[-e]
                return negative ? -v : v
            }
            // Rare: long mantissas or large exponents.
            var text = Array(UnsafeBufferPointer(rebasing: bytes[start..<i]))
            text.append(0)
            return text.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) { strtod($0, nil) }
            }
        }
    }
}
