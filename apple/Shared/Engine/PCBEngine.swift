import Foundation
import ViaFormFFI

/// The PCBCraft engine (schematic, board, KiCad export) behind the C bridge.
///
/// The session is not thread safe, so every call holds `lock`, as `CADEngine` does. Code that
/// takes `session` for its own C calls (the board link) gets it on the main thread, which then
/// holds the lock until the end of the current run loop turn; a worker uses `withSession` (the
/// BOM's project save and open).
final class PCBEngine: @unchecked Sendable {
    private let raw: OpaquePointer
    private let lock = NSRecursiveLock()
    /// The main thread holds the lock for the rest of this run loop turn.
    private var mainHold = false

    /// The session pointer for direct C calls. On the main thread, waits for a worker's call and
    /// keeps the workers out until the run loop turns.
    var session: OpaquePointer {
        if Thread.isMainThread && !mainHold {
            lock.lock()
            mainHold = true
            DispatchQueue.main.async { [self] in
                mainHold = false
                lock.unlock()
            }
        }
        return raw
    }

    init(sample: Bool = false) {
        raw = pcb_session_new(sample)
    }

    deinit { pcb_session_free(raw) }

    /// Runs `body` with the session to itself, on any thread.
    func withSession<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(raw)
    }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> Data {
        guard let p else { return Data("null".utf8) }
        defer { sc_string_free(p) }
        return Data(String(cString: p).utf8)
    }

    /// Runs one command; throws the engine's message when it refuses.
    @discardableResult
    func execute(_ id: String, _ params: [String: Any] = [:]) throws -> Any {
        let body = (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let reply = try JSONSerialization.jsonObject(with: withSession { Self.take(pcb_execute($0, id, body)) }, options: [.fragmentsAllowed])
        guard let obj = reply as? [String: Any] else { throw EngineError(message: "no reply from the PCB engine") }
        if let e = obj["error"] as? String { throw EngineError(message: e) }
        switch id {
        case "undo": undoLabels.undid(nil)
        case "redo": undoLabels.redid(nil)
        case "file.open": undoLabels.reset()
        default: if let l = Self.stepNames[id] { undoLabels.ran(l) } else if !Self.reads(id) { undoLabels.ran("") }
        }
        return obj["ok"] ?? NSNull()
    }

    /// The names of the undo and redo steps: "Undo Move Footprint" in the Edit menu.
    let undoLabels = UndoLabels(limit: 200)

    /// The top undo and redo step names for the depths `inspect` reports.
    func undoNames(undo: Int, redo: Int) -> (undo: String?, redo: String?) { undoLabels.labels(undo: undo, redo: redo) }

    private static func reads(_ id: String) -> Bool {
        id.hasPrefix("file.") || id.hasSuffix(".list") || id.contains("inspect") || id.contains("check")
    }

    private static let stepNames: [String: String] = [
        "component.add": String(localized: "Add Component"),
        "component.move": String(localized: "Move Component"),
        "component.rotate": String(localized: "Rotate Component"),
        "footprint.move": String(localized: "Move Footprint"),
        "footprint.rotate": String(localized: "Rotate Footprint"),
        "object.delete": String(localized: "Delete"),
        "wire.connect": String(localized: "Connect Wire"),
        "track.route": String(localized: "Route Track"),
        "board.sync": String(localized: "Update Board"),
    ]

    func inspect() -> PCBInspect? {
        try? JSONDecoder().decode(PCBInspect.self, from: withSession { Self.take(pcb_inspect($0)) })
    }

    func checks() -> PCBChecks? {
        try? JSONDecoder().decode(PCBChecks.self, from: withSession { Self.take(pcb_checks($0)) })
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
