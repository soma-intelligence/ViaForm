import Foundation
import SolidCraftFFI

/// The PCBCraft engine (schematic, board, KiCad export) behind the C bridge.
final class PCBEngine {
    let session: OpaquePointer

    init(sample: Bool = false) {
        session = pcb_session_new(sample)
    }

    deinit { pcb_session_free(session) }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> Data {
        guard let p else { return Data("null".utf8) }
        defer { sc_string_free(p) }
        return Data(String(cString: p).utf8)
    }

    /// Runs one command; throws the engine's message when it refuses.
    @discardableResult
    func execute(_ id: String, _ params: [String: Any] = [:]) throws -> Any {
        let body = (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let reply = try JSONSerialization.jsonObject(with: Self.take(pcb_execute(session, id, body)), options: [.fragmentsAllowed])
        guard let obj = reply as? [String: Any] else { throw EngineError(message: "no reply from the PCB engine") }
        if let e = obj["error"] as? String { throw EngineError(message: e) }
        return obj["ok"] ?? NSNull()
    }

    func inspect() -> PCBInspect? {
        try? JSONDecoder().decode(PCBInspect.self, from: Self.take(pcb_inspect(session)))
    }

    func checks() -> PCBChecks? {
        try? JSONDecoder().decode(PCBChecks.self, from: Self.take(pcb_checks(session)))
    }
}

// MARK: Project data, as `pcb_inspect` serializes it

struct PCBPoint: Codable, Hashable {
    var x: Double
    var y: Double

    func rotated(_ degrees: Double) -> PCBPoint {
        let a = degrees * .pi / 180
        return PCBPoint(x: x * cos(a) - y * sin(a), y: x * sin(a) + y * cos(a))
    }

    static func + (a: PCBPoint, b: PCBPoint) -> PCBPoint { PCBPoint(x: a.x + b.x, y: a.y + b.y) }
    func distance(to p: PCBPoint) -> Double { hypot(x - p.x, y - p.y) }
}

struct PCBPin: Codable, Hashable {
    var number: String
    var name: String
    var net: Int?
    var offset: PCBPoint
}

struct PCBComponent: Codable, Identifiable, Hashable {
    var id: Int
    var reference: String
    var value: String
    var kind: String
    var position: PCBPoint
    var rotation: Double
    var pins: [PCBPin]

    func pinPosition(_ pin: PCBPin) -> PCBPoint { position + pin.offset.rotated(rotation) }
}

struct PCBPinRef: Codable, Hashable {
    var component: Int
    var pin: String
}

struct PCBWire: Codable, Identifiable, Hashable {
    var id: Int
    var net: Int
    var from: PCBPinRef
    var to: PCBPinRef
}

struct PCBNet: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
}

struct PCBPad: Codable, Hashable {
    var number: String
    var offset: PCBPoint
    var diameter: Double
    var net: Int?
}

struct PCBFootprint: Codable, Identifiable, Hashable {
    var id: Int
    var component: Int
    var position: PCBPoint
    var rotation: Double
    var pads: [PCBPad]

    func padPosition(_ pad: PCBPad) -> PCBPoint { position + pad.offset.rotated(rotation) }
}

struct PCBTrack: Codable, Identifiable, Hashable {
    var id: Int
    var net: Int
    var start: PCBPoint
    var end: PCBPoint
    var width: Double
    var layer: String
}

struct PCBCutout: Codable, Identifiable, Hashable {
    var id: Int
    var center: PCBPoint
    var radius: Double
}

struct PCBBoard: Codable, Hashable {
    var width: Double
    var height: Double
    var clearance: Double
    var cutouts: [PCBCutout]
    var footprints: [PCBFootprint]
    var tracks: [PCBTrack]
}

struct PCBProject: Codable, Hashable {
    var name: String?
    var components: [PCBComponent]
    var wires: [PCBWire]
    var nets: [PCBNet]
    var board: PCBBoard
}

struct PCBInspect: Decodable {
    struct History: Decodable { var undo: Int; var redo: Int }
    var revision: Int
    var project: PCBProject
    var history: History
}

struct PCBChecks: Decodable {
    struct Finding: Decodable, Hashable {
        var code: String
        var message: String
        var severity: String
        var objects: [Int]?
    }
    struct Airwire: Decodable, Hashable {
        var from: PCBPoint
        var to: PCBPoint
        var net: Int
        var from_object: Int?
        var to_object: Int?
    }
    var erc: [Finding]
    var drc: [Finding]
    var airwires: [Airwire]
}
