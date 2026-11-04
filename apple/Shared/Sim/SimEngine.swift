import Foundation
import JavaScriptCore

/// The flight simulation, run through JavaScriptCore from the bundle `scripts/build-sim.sh`
/// makes of `apple/Sim/entry.ts`. It is the same TypeScript the Electron app runs, so a flight
/// behaves the same in every front end. Calls cross as JSON text and decode into the types below.
final class SimEngine {
    private let context: JSContext
    private let api: JSValue
    private(set) var lastError: String?

    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "viaform-sim", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        self.context = context
        context.name = "ViaForm simulation"
        context.evaluateScript(source)
        guard let api = context.objectForKeyedSubscript("ViaSim"), api.isObject else { return nil }
        self.api = api
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastError = exception?.toString() ?? "JavaScript error"
        }
    }

    func catalog() -> SimCatalog? { call("catalog", []) }
    func parts(frameGrams: Double) -> SimParts? { call("parts", [frameGrams]) }

    func start(_ options: SimOptions) -> SimWorld? {
        guard let json = try? String(data: JSONEncoder().encode(options), encoding: .utf8) else { return nil }
        return call("start", [json])
    }

    func advance(seconds: Double) -> SimStep? { call("advance", [seconds]) }

    private func call<T: Decodable>(_ name: String, _ args: [Any]) -> T? {
        lastError = nil
        guard let text = api.invokeMethod(name, withArguments: args)?.toString(), lastError == nil else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            lastError = "\(name): \(error)"
            return nil
        }
    }
}

struct SimOptions: Codable, Equatable {
    var course = "obstacle"
    var seed = 1
    var weather = 0
    var brain = "trained"
}

struct SimCatalog: Decodable {
    struct Weather: Decodable, Hashable { let name: String; let temperatureC: Double; let wind: Double; let fog: Double }
    struct Item: Decodable, Hashable { let id: String; let name: String }
    let weathers: [Weather]
    let brains: [Item]
    let courses: [Item]
}

struct SimObstacle: Decodable {
    let kind: String
    let min: [Double]?
    let max: [Double]?
    let c: [Double]?
    let r: Double?
    let z0: Double?
    let z1: Double?
    let color: String
}

struct SimFrame: Decodable {
    struct Ray: Decodable { let point: [Double]; let hit: Bool }
    let t: Double
    let p: [Double]
    /// Orientation as a quaternion, w first.
    let q: [Double]
    let v: [Double]
    let omega: [Double]
    let wind: [Double]
    let target: [Double]
    let rays: [Ray]
    let voltage: Double
    let soc: Double
    let planIndex: Int
}

struct SimStatus: Decodable {
    let finished: Bool
    let crashed: Bool
    let collided: Bool
    let minClearance: Double
    let energyWh: Double
}

struct SimWorld: Decodable {
    struct Bounds: Decodable { let min: [Double]; let max: [Double] }
    let name: String
    let start: [Double]
    let waypoints: [[Double]]
    let obstacles: [SimObstacle]
    let hidden: [Int]
    let bounds: Bounds
    let frame: SimFrame
    let status: SimStatus
}

struct SimStep: Decodable {
    let frame: SimFrame
    let trail: [[Double]]
    let status: SimStatus
}

struct SimParts: Decodable {
    struct Part: Decodable, Identifiable {
        let role: String
        let name: String
        let qty: Int
        let massG: Double
        let url: String
        let specs: String
        let source: String
        var id: String { role + name }
    }
    let parts: [Part]
    let massKg: Double
}
