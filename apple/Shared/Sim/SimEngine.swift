import Foundation
import ViaFormFFI

/// The flight simulation, run by the Rust core (`sim/`, through the bridge's `vf_sim_*` calls).
/// It is the one copy of the flight model every front end and the training use, so a flight
/// behaves the same everywhere. Calls cross as JSON text and decode into the types below.
final class SimEngine {
    private var flight: OpaquePointer?
    private(set) var lastError: String?

    deinit { vf_sim_free(flight) }

    func catalog() -> SimCatalog? { decode("catalog", take(vf_sim_catalog())) }
    func parts(frameGrams: Double) -> SimParts? { decode("parts", take(vf_sim_parts(frameGrams))) }

    /// Starts a new flight (the old one ends) and returns its world.
    func start(_ options: SimOptions) -> SimWorld? {
        lastError = nil
        guard let json = Self.json(options) else { return nil }
        vf_sim_free(flight)
        flight = vf_sim_start(json)
        guard let flight else { lastError = "start: the options did not parse"; return nil }
        return decode("start", take(vf_sim_world(flight)))
    }

    func advance(seconds: Double) -> SimStep? {
        lastError = nil
        guard let flight else { lastError = "no flight"; return nil }
        return decode("advance", take(vf_sim_advance(flight, seconds)))
    }

    /// One disturbance now (kick, gust, tumble, payload, prop), or "timed" to toggle random ones.
    @discardableResult
    func disturb(_ kind: String) -> Bool {
        guard let flight else { return false }
        return vf_sim_disturb(flight, kind)
    }

    /// Runs a whole flight off to the side (the benchmark) and returns its result.
    func episode(_ options: SimOptions) -> SimEpisode? {
        lastError = nil
        guard let json = Self.json(options) else { return nil }
        return decode("episode", take(vf_sim_episode(json)))
    }

    /// The sticks of a manual flight, each -1...1.
    func pilot(_ sticks: SimSticks, mode: String) {
        guard let flight else { return }
        let text = String(format: #"{"x":%f,"y":%f,"z":%f,"yaw":%f,"mode":"%@"}"#, sticks.x, sticks.y, sticks.z, sticks.yaw, mode)
        _ = vf_sim_pilot(flight, text)
    }

    /// What a generated frame file builds, or why it does not.
    func airframe(_ text: String) -> Result<SimAirframe, SimFrameError> {
        let reply = take(vf_sim_airframe(text))
        if let f = try? JSONDecoder().decode(Failure.self, from: Data(reply.utf8)) { return .failure(SimFrameError(message: f.error)) }
        guard let a = try? JSONDecoder().decode(SimAirframe.self, from: Data(reply.utf8)) else { return .failure(SimFrameError(message: "unreadable reply")) }
        return .success(a)
    }

    /// What the sourced components build (texts of drone.json, and of assembly.json and the frame
    /// file when there are), or why they do not.
    func vehicle(components: String, assembly: String?, frame: String?) -> Result<SimVehicle, SimFrameError> {
        var req: [String: Any] = ["components": components]
        if let assembly { req["assembly"] = assembly }
        if let frame { req["frame"] = frame }
        guard let data = try? JSONSerialization.data(withJSONObject: req) else { return .failure(SimFrameError(message: "unreadable files")) }
        let reply = take(vf_sim_vehicle(String(decoding: data, as: UTF8.self)))
        if let f = try? JSONDecoder().decode(Failure.self, from: Data(reply.utf8)) { return .failure(SimFrameError(message: f.error)) }
        do { return .success(try JSONDecoder().decode(SimVehicle.self, from: Data(reply.utf8))) } catch {
            return .failure(SimFrameError(message: "\(error)"))
        }
    }

    /// The options as the core reads them: the trained brain goes in as JSON, not as text.
    static func json(_ options: SimOptions) -> String? {
        guard let data = try? JSONEncoder().encode(options),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        dict.removeValue(forKey: "customBrain")
        if let c = options.customBrain, let brain = try? JSONSerialization.jsonObject(with: Data(c.utf8)) { dict["custom"] = brain }
        guard let out = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    fileprivate func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "null" }
        defer { sc_string_free(p) }
        return String(cString: p)
    }

    fileprivate struct Failure: Decodable { let error: String }

    private func decode<T: Decodable>(_ name: String, _ text: String) -> T? {
        let data = Data(text.utf8)
        if let f = try? JSONDecoder().decode(Failure.self, from: data) {
            lastError = "\(name): \(f.error)"
            return nil
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
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
    /// course, hover or stress (the stress test always runs the realistic plant).
    var mission = "course"
    /// The realistic plant and sensors: rotor drag, vortex ring, motor spread, IMU and filter.
    var realism = false
    /// position or angle, for a manual flight.
    var pilotMode = "position"
    /// The text of the generated frame file when the drone is built from it.
    var frame: String?
    /// The texts of the sourced components list and of the assembly that places them.
    var components: String?
    var assembly: String?
    /// A trained brain (JSON), flown when `brain` is "custom".
    var customBrain: String?
}

/// The sticks: forward, left, up and yaw to the left, each -1...1.
struct SimSticks: Equatable {
    var x = 0.0, y = 0.0, z = 0.0, yaw = 0.0
}

/// Why a generated frame file does not build a drone.
struct SimFrameError: Error, Equatable { let message: String }

struct SimAirframe: Decodable, Equatable {
    let name: String
    let frameG: Double
    let armMm: Double
    let massKg: Double
    let inertia: [Double]
    let thrustToWeight: Double
}

/// The drone the sourced components build, and what each figure came from.
struct SimVehicle: Decodable, Equatable {
    struct Battery: Decodable, Equatable { let cells: Double; let capacityAh: Double }
    struct Part: Decodable, Equatable { let ref: String; let qty: Int; let category: String; let mpn: String; let massG: Double? }
    let massKg: Double
    let inertia: [Double]
    let armMm: Double
    let thrustToWeight: Double
    let maxThrustN: Double
    let battery: Battery
    let components: [Part]
    let placed: Int
    /// The component refs the assembly placed (the first instance of each).
    var placedRefs: [String] = []
    /// How many placements the assembly file gave.
    var placements: Int = 0
    let assembly: Bool
    /// The generated frame the drone is built on, when a frame file was given.
    var frame: Frame?
    let missing: [String]

    struct Frame: Decodable, Equatable { let name: String; let frameG: Double; let armMm: Double }

    enum CodingKeys: String, CodingKey { case massKg, inertia, armMm, thrustToWeight, maxThrustN, battery, components, placed, placedRefs, placements, assembly, frame, missing }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        massKg = try c.decode(Double.self, forKey: .massKg)
        inertia = try c.decode([Double].self, forKey: .inertia)
        armMm = try c.decode(Double.self, forKey: .armMm)
        thrustToWeight = try c.decode(Double.self, forKey: .thrustToWeight)
        maxThrustN = try c.decode(Double.self, forKey: .maxThrustN)
        battery = try c.decode(Battery.self, forKey: .battery)
        components = try c.decode([Part].self, forKey: .components)
        placed = try c.decode(Int.self, forKey: .placed)
        placedRefs = (try? c.decode([String].self, forKey: .placedRefs)) ?? []
        placements = (try? c.decode(Int.self, forKey: .placements)) ?? 0
        assembly = try c.decode(Bool.self, forKey: .assembly)
        frame = try? c.decode(Frame.self, forKey: .frame)
        missing = try c.decode([String].self, forKey: .missing)
    }
}

struct SimRecovery: Decodable, Hashable {
    let kind: String
    let t: Double
    let maxDeviation: Double
    let maxTilt: Double
    let recoveredAfter: Double?
}

struct SimStabilization: Decodable {
    let w: [Double]
    let attitudeError: Double
    let deviation: Double
    let attitudeRms: Double
    let recoveries: [SimRecovery]
    let timed: Bool
    let payloadKg: Double
}

struct SimRace: Decodable {
    let state: String
    let countdown: Double
    let next: Int
    let gates: Int
    let splits: [Double]
    let time: Double
    let target: [Double]
}

/// One training on the core's threads: started, polled, cancelled, freed with the object.
final class SimTrainJob {
    struct Point: Decodable, Hashable { let iteration: Int; let cost: Double; let baseline: Double }
    struct Result: Decodable { struct Held: Decodable { let before: Double; let after: Double }; let heldOut: Held }
    struct Progress: Decodable {
        let running: Bool
        let stage: String
        let iteration: Int
        let total: Int
        let history: [Point]
        let result: Result?
        let error: String?
    }

    private let job: OpaquePointer
    private(set) var brainJSON: String?

    init?(options: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: options),
              let job = vf_train_start(String(decoding: data, as: UTF8.self)) else { return nil }
        self.job = job
    }

    deinit { vf_train_free(job) }

    func cancel() { vf_train_cancel(job) }

    func progress() -> Progress? {
        guard let p = vf_train_progress(job) else { return nil }
        defer { sc_string_free(p) }
        let data = Data(String(cString: p).utf8)
        if brainJSON == nil, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let result = obj["result"] as? [String: Any], let brain = result["brain"],
           let b = try? JSONSerialization.data(withJSONObject: brain) {
            brainJSON = String(decoding: b, as: UTF8.self)
        }
        return try? JSONDecoder().decode(Progress.self, from: data)
    }
}

struct SimEpisode: Decodable {
    let crashed: Bool
    let collided: Bool
    let completed: Bool
    let time: Double
    let rmsError: Double
    let attitudeRms: Double
}

struct SimCatalog: Decodable {
    struct Weather: Decodable, Hashable { let name: String; let temperatureC: Double; let wind: Double; let fog: Double }
    struct Item: Decodable, Hashable { let id: String; let name: String }
    let weathers: [Weather]
    let brains: [Item]
    let courses: [Item]
    let missions: [Item]
    let disturbances: [String]
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
    let race: SimRace?
    let airframe: SimAirframe?
    /// The sourced drone the session flies (components, placements, frame), when it is one.
    var vehicle: SimVehicle?
}

struct SimStep: Decodable {
    let frame: SimFrame
    let trail: [[Double]]
    let status: SimStatus
    let stabilization: SimStabilization?
    let race: SimRace?
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
