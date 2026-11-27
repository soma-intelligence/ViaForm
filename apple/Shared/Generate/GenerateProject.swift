import Foundation
import simd

// MARK: Sample projects (docs/generative/<name>)

/// A generative project on disk: its studies (`studies/*.json`, the engine's own study files)
/// and its assembly (`assembly.json`: the generated parts, every real component placed with its
/// `component_ref`, and the joints). `--sample hand` and `--sample drone` open the repository's.
struct GenerateProject: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable {
        var id: String { name }
        var name: String
        var url: URL
        /// The file as the engine reads it: what runs when the setup is left as it came.
        var raw: Data
        var study: Study
        /// The last generated result beside the study (`results/<name>.json`), when there is one.
        var result: [String: Double]
    }

    var name: String
    var dir: URL
    var studies: [Entry]
    var assembly: URL?

    static let samples = ["hand", "drone"]

    /// The study to open first: the first generated part of the assembly (studies are kept in
    /// the assembly's order), else the first.
    var firstStudy: Entry? {
        let parts = Self.generatedParts(assembly)
        return studies.first { parts.contains($0.name) } ?? studies.first
    }

    /// The names of the generated parts `assembly.json` places, in its order.
    static func generatedParts(_ assembly: URL?) -> [String] {
        guard let asm = assembly, let d = try? Data(contentsOf: asm), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        var seen = Set<String>()
        return (o["parts"] as? [[String: Any]] ?? []).compactMap { p -> String? in
            guard (p["kind"] as? String) == "generative", let n = p["name"] as? String, seen.insert(n).inserted else { return nil }
            return n
        }
    }

    /// The repository's docs/generative folder: `VIAFORM_REPO` when set, else the source tree
    /// this app was built from.
    static var docsRoot: URL? {
        let fm = FileManager.default
        var roots: [URL] = []
        if let r = ProcessInfo.processInfo.environment["VIAFORM_REPO"] { roots.append(URL(fileURLWithPath: r)) }
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        return roots.map { $0.appendingPathComponent("docs/generative", isDirectory: true) }.first { fm.fileExists(atPath: $0.path) }
    }

    /// The sample asked for at launch (`--sample hand`, `--sample drone`, `--sample=hand`).
    static var launchSample: String? {
        let args = ProcessInfo.processInfo.arguments
        if let a = args.first(where: { $0.hasPrefix("--sample=") }) {
            let v = String(a.dropFirst(9))
            return samples.contains(v) ? v : nil
        }
        if let i = args.firstIndex(of: "--sample"), i + 1 < args.count, samples.contains(args[i + 1]) { return args[i + 1] }
        return nil
    }

    /// Reads `docs/generative/<name>`; nil when it is not there.
    static func open(_ name: String) throws -> GenerateProject {
        guard let root = docsRoot else { throw EngineError(message: String(localized: "The sample projects are not available in this copy of ViaForm.")) }
        return try open(dir: root.appendingPathComponent(name, isDirectory: true))
    }

    static func open(dir: URL) throws -> GenerateProject {
        let fm = FileManager.default
        let studiesDir = dir.appendingPathComponent("studies", isDirectory: true)
        let files = ((try? fm.contentsOfDirectory(at: studiesDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entries: [Entry] = []
        for url in files {
            guard let data = try? Data(contentsOf: url), let v = try? JSONValue.parse(data), case .object = v, v["voxel"].double != nil else { continue }
            var result: [String: Double] = [:]
            let name = url.deletingPathExtension().lastPathComponent
            let resultURL = dir.appendingPathComponent("results/\(name).json")
            if let d = try? Data(contentsOf: resultURL), let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, x) in r { if let n = x as? Double { result[k] = n } }
            }
            entries.append(Entry(name: v["name"].string ?? name, url: url, raw: data, study: Study(engine: v), result: result))
        }
        let asm = dir.appendingPathComponent("assembly.json")
        // With an assembly, only the studies of its generated parts belong to the project
        // (left-over studies of parts it no longer places stay out), in the assembly's order.
        let parts = generatedParts(fm.fileExists(atPath: asm.path) ? asm : nil)
        if !parts.isEmpty {
            let order = Dictionary(parts.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            entries = entries.filter { order[$0.name] != nil }.sorted { order[$0.name]! < order[$1.name]! }
        }
        if entries.isEmpty && !fm.fileExists(atPath: asm.path) {
            throw EngineError(message: "\(dir.lastPathComponent): no studies and no assembly in \(dir.path)")
        }
        return GenerateProject(name: dir.lastPathComponent, dir: dir, studies: entries, assembly: fm.fileExists(atPath: asm.path) ? asm : nil)
    }
}

// MARK: Assembly joints (assembly.json)

/// One joint of a generated assembly, as `assembly.json` lists it, with the value it is driven to.
struct AssemblyJoint: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var type: String
    var parent: String
    var child: String
    /// Degrees.
    var limits: ClosedRange<Double>
    var value: Double = 0

    var movable: Bool { type != "rigid" }

    /// The finger or group the joint belongs to ("index", "thumb", "wrist", "palm").
    var group: String {
        let head = name.split(whereSeparator: { $0 == "/" || $0 == "_" || $0 == " " }).first.map(String.init) ?? name
        return head.isEmpty ? "Joints" : head
    }

    /// Closing a hand: a flexion goes to the end of its range that curls the finger (the larger
    /// one, flexion is positive), an abduction or deviation stays centred.
    var fistValue: Double {
        let n = name.lowercased()
        if n.contains("abd") || n.contains("dev") || n.contains("radial") || n.contains("ulnar") || n.contains("spread") { return min(max(0, limits.lowerBound), limits.upperBound) }
        if n.contains("wrist") { return min(max(0, limits.lowerBound), limits.upperBound) }
        if n.contains("arch") || n.contains("cmc") && !n.contains("flex") { return abs(limits.lowerBound) > abs(limits.upperBound) ? limits.lowerBound * 0.8 : limits.upperBound * 0.8 }
        return abs(limits.upperBound) >= abs(limits.lowerBound) ? limits.upperBound : limits.lowerBound
    }

    /// Reads the movable joints of `assembly.json`.
    static func read(_ url: URL) -> [AssemblyJoint] {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return (o["joints"] as? [[String: Any]] ?? []).compactMap { j in
            guard let name = j["name"] as? String, let type = j["type"] as? String, type != "rigid" else { return nil }
            let lim = (j["limits_deg"] as? [Double]) ?? [-90, 90]
            let lo = lim.first ?? -90, hi = lim.count > 1 ? lim[1] : 90
            return AssemblyJoint(name: name, type: type, parent: j["parent"] as? String ?? "", child: j["child"] as? String ?? "",
                                 limits: min(lo, hi)...max(lo, hi), value: min(max(0, min(lo, hi)), max(lo, hi)))
        }
    }

    /// What `assembly.json` holds besides the joints: parts, real components, mass.
    struct Summary: Sendable, Equatable {
        var parts = 0
        var generated = 0
        var components = 0
        var componentRefs: [String] = []
        var massG: Double?
        var quantitiesMatch: Bool?
    }

    static func summary(_ url: URL) -> Summary {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return Summary() }
        let parts = o["parts"] as? [[String: Any]] ?? []
        let refs = parts.compactMap { $0["component_ref"] as? String }
        let q = (o["quantities"] as? [[String: Any]])?.map { $0["matches"] as? Bool ?? false }
        return Summary(parts: parts.count, generated: parts.filter { ($0["kind"] as? String) == "generative" }.count, components: refs.count,
                       componentRefs: Array(Set(refs)).sorted(), massG: (o["mass_g"] as? [String: Any])?["total"] as? Double,
                       quantitiesMatch: q.map { $0.allSatisfy { $0 } })
    }
}

// MARK: Reading the engine's study files

extension Vec3 {
    init?(engine v: JSONValue) {
        let d = v.doubles
        guard d.count == 3 else { return nil }
        self.init(d[0], d[1], d[2])
    }
}

extension StudyRegion {
    init?(engine v: JSONValue) {
        let vec = { (k: String) in Vec3(engine: v[k]) }
        switch v["shape"].string {
        case "box":
            guard let lo = vec("min"), let hi = vec("max") else { return nil }
            self = .box(lo, hi)
        case "cylinder":
            guard let b = vec("base"), let a = vec("axis") else { return nil }
            self = .cylinder(base: b, axis: a, radius: v["radius"].double ?? 1, length: v["length"].double ?? 1)
        case "sphere":
            guard let c = vec("center") else { return nil }
            self = .sphere(c, radius: v["radius"].double ?? 1)
        case "tube":
            guard let b = vec("base"), let a = vec("axis") else { return nil }
            self = .cylinder(base: b, axis: a, radius: v["outer"].double ?? 1, length: v["length"].double ?? 1)
            shape = .tube
            inner = v["inner"].double ?? 0
        default:
            return nil
        }
    }
}

extension StudyLoad {
    init?(engine v: JSONValue) {
        guard let r = StudyRegion(engine: v["region"]) else { return nil }
        switch v["type"].string {
        case "force": self = .force(r, Vec3(engine: v["force"]) ?? .zero)
        case "torque": self = .torque(r, center: Vec3(engine: v["center"]) ?? r.middle, axis: Vec3(engine: v["axis"]) ?? Vec3(0, 0, 1), moment: v["moment"].double ?? 0)
        case "pressure": self = .pressure(r, direction: Vec3(engine: v["direction"]) ?? Vec3(0, 0, -1), pressure: v["pressure"].double ?? 0)
        default: return nil
        }
    }
}

extension Study {
    /// A study file as the engine reads it (`viaform_generative::solid::Study`); fields left out
    /// keep the engine's defaults.
    init(engine v: JSONValue) {
        self.init()
        // The engine's defaults where they differ from the editor's.
        cases = []
        safetyFactor = 1.5
        if let m = StudyMethod(rawValue: v["method"].string ?? "") { method = m }
        if let o = StudyObjective(rawValue: v["objective"].string ?? "") { objective = o }
        name = v["name"].string ?? name
        min = Vec3(engine: v["min"]) ?? min
        max = Vec3(engine: v["max"]) ?? max
        voxel = v["voxel"].double ?? voxel
        let m = v["material"]
        if case .object = m {
            material = StudyMaterial(name: m["name"].string ?? "Material", e: m["e"].double ?? 70_000, nu: m["nu"].double ?? 0.33,
                                     density: m["density"].double ?? 2.7e-3, allowable: m["allowable"].double ?? 200, color: m["color"].string ?? "#b9c0c8")
        }
        supports = v["supports"].array.compactMap { s in
            guard let r = StudyRegion(engine: s["region"]) else { return nil }
            let fix = s["fix"].array.compactMap(\.bool)
            return StudySupport(region: r, fix: fix.count == 3 ? fix : [true, true, true])
        }
        cases = v["cases"].array.map { c in
            StudyLoadCase(name: c["name"].string ?? "Case", loads: c["loads"].array.compactMap(StudyLoad.init(engine:)),
                          acceleration: Vec3(engine: c["acceleration"]), weight: c["weight"].double ?? 1)
        }
        keepOut = v["keep_out"].array.compactMap { StudyRegion(engine: $0).map(Keyed.init) }
        keepIn = v["keep_in"].array.compactMap { StudyRegion(engine: $0).map(Keyed.init) }
        volumeFraction = v["volume_fraction"].double ?? volumeFraction
        maxStress = v["max_stress"].double
        safetyFactor = v["safety_factor"].double ?? safetyFactor
        maxDisplacement = v["max_displacement"].double
        minFrequency = v["min_frequency"].double
        let sym = v["symmetry"].array.compactMap(\.bool)
        if sym.count == 3 { symmetry = sym }
        minMember = v["min_member"].double ?? minMember
        let mf = v["manufacturing"]
        switch mf["process"].string {
        case "additive": manufacturing = StudyManufacturing(process: .additive, direction: Vec3(engine: mf["build"]) ?? Vec3(0, 0, 1), overhang: mf["overhang"].double ?? 45)
        case "extrusion": manufacturing = StudyManufacturing(process: .extrusion, direction: Vec3(engine: mf["direction"]) ?? Vec3(0, 0, 1))
        case "milling": manufacturing = StudyManufacturing(process: .milling, direction: Vec3(engine: mf["direction"]) ?? Vec3(0, 0, 1))
        default: manufacturing = StudyManufacturing()
        }
        iterations = v["iterations"].int ?? iterations
        let d = v["dynamics"]
        dynamics = StudyDynamics(modes: d["modes"].int ?? 0, impacts: d["impacts"].array.map { i in
            StudyImpact(caseIndex: i["case"].int ?? 0, duration: i["duration"].double ?? 0.002, window: i["window"].double ?? 0.01,
                        steps: i["steps"].int ?? 200, damping: i["damping"].double ?? 0.02)
        })
        variants = v["variants"].int ?? variants
        seed = UInt64(Swift.max(0, v["seed"].int ?? 1))
        smoothing = v["smoothing"].int ?? smoothing
        if case .object = v["robust"] { robustDelta = v["robust"]["delta"].double ?? 0.15 }
        frequencyModes = v["frequency_modes"].int ?? frequencyModes
        massTargetG = v["mass_target_g"].double
        maxBeta = v["max_beta"].double ?? maxBeta
        tolerance = v["tolerance"].double ?? tolerance
        bores = v["bores"].array.compactMap { StudyRegion(engine: $0).map(Keyed.init) }
        exactKeepOuts = v["exact_keep_outs"].bool ?? exactKeepOuts
        maxBodies = v["max_bodies"].int ?? maxBodies
    }
}
