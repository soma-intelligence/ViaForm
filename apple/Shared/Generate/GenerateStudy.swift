import Foundation
import simd

/// A point or a direction, world millimetres (z up), as the engine takes `[f64; 3]`.
typealias Vec3 = SIMD3<Double>

// MARK: Study (generative/src/solid/mod.rs, sent as JSON)

/// A region of space, world mm. Every shape's figures are kept so switching the shape while
/// editing loses nothing; only the shape's own are sent, tagged by "shape".
struct StudyRegion: Encodable, Hashable, Sendable {
    enum Shape: String, Encodable, CaseIterable, Sendable {
        case box, cylinder, sphere, tube
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .box: "cube"
            case .cylinder: "cylinder"
            case .sphere: "circle"
            case .tube: "circle.circle"
            }
        }
    }

    var shape = Shape.box
    var min = Vec3(0, 0, 0)
    var max = Vec3(10, 10, 10)
    /// Cylinder: the centre of its base, its axis (normalised by the engine) and length.
    var base = Vec3(0, 0, 0)
    var axis = Vec3(0, 0, 1)
    var length: Double = 10
    /// Cylinder and sphere.
    var radius: Double = 5
    /// Sphere.
    var center = Vec3(0, 0, 0)
    /// Tube: the bore's radius (`radius` is the outer one); a bearing seat or a pin's boss.
    var inner: Double = 0

    static func box(_ min: Vec3, _ max: Vec3) -> Self { Self(shape: .box, min: min, max: max) }
    static func cylinder(base: Vec3, axis: Vec3, radius: Double, length: Double) -> Self {
        Self(shape: .cylinder, base: base, axis: axis, length: length, radius: radius)
    }
    static func sphere(_ center: Vec3, radius: Double) -> Self { Self(shape: .sphere, radius: radius, center: center) }

    var unitAxis: Vec3 {
        let l = simd_length(axis)
        return l > 1e-12 ? axis / l : Vec3(0, 0, 1)
    }

    /// The region's middle.
    var middle: Vec3 {
        switch shape {
        case .box: (min + max) / 2
        case .cylinder, .tube: base + unitAxis * length / 2
        case .sphere: center
        }
    }

    /// The axis-aligned box around the region.
    var bounds: (min: Vec3, max: Vec3) {
        switch shape {
        case .box:
            return (simd_min(min, max), simd_max(min, max))
        case .cylinder, .tube:
            let a = unitAxis
            let half = simd_abs(a) * length / 2 + radius * Vec3(1 - a.x * a.x, 1 - a.y * a.y, 1 - a.z * a.z).squareRoot()
            return (middle - half, middle + half)
        case .sphere:
            return (center - radius, center + radius)
        }
    }

    /// The region moved by `d`.
    func translated(_ d: Vec3) -> Self {
        var r = self
        r.min += d
        r.max += d
        r.base += d
        r.center += d
        return r
    }

    /// Changes the shape, keeping the region where it was (the new shape fits the old bounds).
    mutating func convert(to s: Shape) {
        guard s != shape else { return }
        let (lo, hi) = bounds
        let size = hi - lo, mid = (lo + hi) / 2
        switch s {
        case .box:
            min = lo
            max = hi
        case .cylinder, .tube:
            // Along the box's longest side.
            let a = size.x >= size.y && size.x >= size.z ? 0 : (size.y >= size.z ? 1 : 2)
            var ax = Vec3.zero
            ax[a] = 1
            axis = ax
            length = Swift.max(size[a], 0.1)
            radius = Swift.max(0.1, (0..<3).filter { $0 != a }.map { size[$0] }.min()! / 2)
            base = mid - ax * length / 2
            if s == .tube { inner = radius / 2 }
        case .sphere:
            center = mid
            radius = Swift.max(0.1, size.min() / 2)
        }
        shape = s
    }

    private enum Keys: String, CodingKey { case shape, min, max, base, axis, radius, length, center, inner, outer }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(shape, forKey: .shape)
        switch shape {
        case .box:
            let (lo, hi) = bounds
            try c.encode(lo.array, forKey: .min)
            try c.encode(hi.array, forKey: .max)
        case .cylinder:
            try c.encode(base.array, forKey: .base)
            try c.encode(axis.array, forKey: .axis)
            try c.encode(radius, forKey: .radius)
            try c.encode(length, forKey: .length)
        case .sphere:
            try c.encode(center.array, forKey: .center)
            try c.encode(radius, forKey: .radius)
        case .tube:
            try c.encode(base.array, forKey: .base)
            try c.encode(axis.array, forKey: .axis)
            try c.encode(Swift.min(inner, radius), forKey: .inner)
            try c.encode(radius, forKey: .outer)
            try c.encode(length, forKey: .length)
        }
    }
}

struct StudySupport: Encodable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var region: StudyRegion
    /// Held axes: x, y, z.
    var fix = [true, true, true]

    private enum Keys: String, CodingKey { case region, fix }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(region, forKey: .region)
        try c.encode(fix, forKey: .fix)
    }

    var label: String {
        switch (fix[0], fix[1], fix[2]) {
        case (true, true, true): "Fixed"
        case (false, false, false): "Free"
        default: "Holds " + zip(["X", "Y", "Z"], fix).filter(\.1).map(\.0).joined(separator: " ")
        }
    }
}

/// A force, a torque or a pressure on a region, tagged by "type"; all figures kept while editing.
struct StudyLoad: Encodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Encodable, CaseIterable, Sendable {
        case force, torque, pressure
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .force: "arrow.down"
            case .torque: "arrow.clockwise"
            case .pressure: "arrow.down.to.line"
            }
        }
    }

    var id = UUID()
    var kind = Kind.force
    var region: StudyRegion
    /// Force, N.
    var force = Vec3(0, 0, -100)
    /// Torque: a moment (N·mm) about `axis` through `center`.
    var center = Vec3.zero
    var axis = Vec3(0, 0, 1)
    var moment: Double = 1000
    /// Pressure, MPa, along `direction`.
    var direction = Vec3(0, 0, -1)
    var pressure: Double = 0.1

    static func force(_ region: StudyRegion, _ f: Vec3) -> Self { Self(kind: .force, region: region, force: f) }
    static func torque(_ region: StudyRegion, center: Vec3, axis: Vec3, moment: Double) -> Self {
        Self(kind: .torque, region: region, center: center, axis: axis, moment: moment)
    }
    static func pressure(_ region: StudyRegion, direction: Vec3, pressure: Double) -> Self {
        Self(kind: .pressure, region: region, direction: direction, pressure: pressure)
    }

    var summary: String {
        switch kind {
        case .force: String(format: "%.0f N", simd_length(force))
        case .torque: String(format: "%.0f N·mm", moment)
        case .pressure: String(format: "%.3g MPa", pressure)
        }
    }

    private enum Keys: String, CodingKey { case type, region, force, center, axis, moment, direction, pressure }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .type)
        try c.encode(region, forKey: .region)
        switch kind {
        case .force:
            try c.encode(force.array, forKey: .force)
        case .torque:
            try c.encode(center.array, forKey: .center)
            try c.encode(axis.array, forKey: .axis)
            try c.encode(moment, forKey: .moment)
        case .pressure:
            try c.encode(direction.array, forKey: .direction)
            try c.encode(pressure, forKey: .pressure)
        }
    }
}

/// Loads applied together.
struct StudyLoadCase: Encodable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = "Case"
    var loads: [StudyLoad] = []
    /// Body acceleration, mm/s² (gravity is `[0, 0, -9810]`).
    var acceleration: Vec3?
    /// Share of this case in the compliance objective.
    var weight: Double = 1

    private enum Keys: String, CodingKey { case name, loads, acceleration, weight }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(loads, forKey: .loads)
        try c.encode(acceleration?.array, forKey: .acceleration)
        try c.encode(weight, forKey: .weight)
    }
}

struct StudyImpact: Encodable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Index into the study's load cases.
    var caseIndex = 0
    /// Pulse length, s.
    var duration: Double = 0.002
    /// Time integrated after the pulse starts, s.
    var window: Double = 0.01
    var steps = 200
    /// Rayleigh damping ratio at the first mode.
    var damping: Double = 0.02

    private enum Keys: String, CodingKey { case `case`, duration, window, steps, damping }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(caseIndex, forKey: .case)
        try c.encode(duration, forKey: .duration)
        try c.encode(Swift.max(window, duration), forKey: .window)
        try c.encode(steps, forKey: .steps)
        try c.encode(damping, forKey: .damping)
    }
}

struct StudyDynamics: Encodable, Hashable, Sendable {
    var modes = 0
    var impacts: [StudyImpact] = []
}

struct StudyManufacturing: Encodable, Hashable, Sendable {
    enum Process: String, Encodable, CaseIterable, Sendable {
        case free, additive, extrusion, milling
        var label: String {
            switch self {
            case .free: "Unconstrained"
            case .additive: "Additive"
            case .extrusion: "Extrusion"
            case .milling: "Milling"
            }
        }
    }

    var process = Process.free
    /// Build direction (additive), extrusion direction or tool direction (milling).
    var direction = Vec3(0, 0, 1)
    /// Additive: steepest overhang from the build plate, degrees.
    var overhang: Double = 45

    private enum Keys: String, CodingKey { case process, build, direction, overhang }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(process, forKey: .process)
        switch process {
        case .free: break
        case .additive:
            try c.encode(direction.array, forKey: .build)
            try c.encode(overhang, forKey: .overhang)
        case .extrusion, .milling:
            try c.encode(direction.array, forKey: .direction)
        }
    }
}

struct StudyMaterial: Codable, Hashable, Sendable {
    var name: String
    /// Young's modulus, MPa.
    var e: Double
    var nu: Double
    /// g/mm³.
    var density: Double
    /// Allowable stress, MPa.
    var allowable: Double
    var color: String

    static let presets: [StudyMaterial] = [
        .init(name: "Aluminum 6061", e: 69_000, nu: 0.33, density: 2.70e-3, allowable: 180, color: "#b9c0c8"),
        .init(name: "Ti-6Al-4V", e: 113_800, nu: 0.34, density: 4.43e-3, allowable: 760, color: "#a9a6a0"),
        .init(name: "Steel 4140", e: 205_000, nu: 0.29, density: 7.85e-3, allowable: 415, color: "#7d848c"),
        .init(name: "PA12", e: 1_700, nu: 0.39, density: 1.01e-3, allowable: 30, color: "#e6e3dc"),
        .init(name: "PLA", e: 3_500, nu: 0.36, density: 1.24e-3, allowable: 35, color: "#e8e2d4"),
        .init(name: "Carbon T700 quasi-iso", e: 50_000, nu: 0.30, density: 1.55e-3, allowable: 350, color: "#3a3d42"),
    ]
}

enum StudyMethod: String, Encodable, CaseIterable, Sendable {
    case topology, frame
    var label: String { self == .topology ? "Topology" : "Space frame" }
}

enum StudyObjective: String, Encodable, CaseIterable, Sendable {
    case compliance, mass
    var label: String { self == .compliance ? "Stiffest" : "Lightest" }
}

/// A 3D study, as `viaform_generative::solid::Study` takes it.
struct Study: Encodable, Hashable, Sendable {
    var method = StudyMethod.topology
    var objective = StudyObjective.compliance
    var name = "Generated"
    var min = Vec3(0, 0, 0)
    var max = Vec3(60, 20, 20)
    var voxel: Double = 1
    var material = StudyMaterial.presets[0]
    var supports: [StudySupport] = []
    var cases: [StudyLoadCase] = [StudyLoadCase(name: "Case 1")]
    var keepOut: [Keyed] = []
    var keepIn: [Keyed] = []
    var volumeFraction: Double = 0.2
    var maxStress: Double?
    var safetyFactor: Double = 1.5
    var maxDisplacement: Double?
    var minFrequency: Double?
    var symmetry = [false, false, false]
    var minMember: Double = 2
    var manufacturing = StudyManufacturing()
    var iterations = 80
    var dynamics = StudyDynamics()
    var variants = 1
    var seed: UInt64 = 1
    var smoothing = 12
    /// Robust formulation (eroded, nominal, dilated projections): the threshold shift, or nil.
    var robustDelta: Double?
    /// Lowest modes the frequency floor holds together (at least 1).
    var frequencyModes = 3
    /// Target part mass, g: sets the volume fraction instead of `volumeFraction`.
    var massTargetG: Double?
    /// Final Heaviside sharpness (0: plain SIMP with a density filter).
    var maxBeta: Double = 16
    /// Stop when no variable moves more than this (0: run every iteration).
    var tolerance: Double = 0
    /// Exact round holes cut into the surface after it is built.
    var bores: [Keyed] = []
    /// Cylinder keep-outs cut exactly too.
    var exactKeepOuts = true
    /// Separate bodies the result may have before it fails.
    var maxBodies = 1

    /// A keep-out or keep-in region with its identity for the editor.
    struct Keyed: Encodable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var region: StudyRegion
        init(_ region: StudyRegion) { self.region = region }
        func encode(to encoder: Encoder) throws { try region.encode(to: encoder) }
    }

    private enum Keys: String, CodingKey {
        case method, objective, name, min, max, voxel, material, supports, cases, dynamics, variants, seed, smoothing, symmetry, manufacturing, iterations
        case keepOut = "keep_out", keepIn = "keep_in", volumeFraction = "volume_fraction", maxStress = "max_stress"
        case safetyFactor = "safety_factor", maxDisplacement = "max_displacement", minFrequency = "min_frequency", minMember = "min_member"
        case robust, frequencyModes = "frequency_modes", massTargetG = "mass_target_g", maxBeta = "max_beta", tolerance, bores
        case exactKeepOuts = "exact_keep_outs", maxBodies = "max_bodies"
    }

    private struct RobustValue: Encodable { var delta: Double }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(method, forKey: .method)
        try c.encode(objective, forKey: .objective)
        try c.encode(name, forKey: .name)
        try c.encode(simd_min(min, max).array, forKey: .min)
        try c.encode(simd_max(min, max).array, forKey: .max)
        try c.encode(voxel, forKey: .voxel)
        try c.encode(material, forKey: .material)
        try c.encode(supports, forKey: .supports)
        try c.encode(cases, forKey: .cases)
        try c.encode(keepOut, forKey: .keepOut)
        try c.encode(keepIn, forKey: .keepIn)
        try c.encode(volumeFraction, forKey: .volumeFraction)
        try c.encode(maxStress, forKey: .maxStress)
        try c.encode(safetyFactor, forKey: .safetyFactor)
        try c.encode(maxDisplacement, forKey: .maxDisplacement)
        try c.encode(minFrequency, forKey: .minFrequency)
        try c.encode(symmetry, forKey: .symmetry)
        try c.encode(minMember, forKey: .minMember)
        try c.encode(manufacturing, forKey: .manufacturing)
        try c.encode(iterations, forKey: .iterations)
        try c.encode(dynamics, forKey: .dynamics)
        try c.encode(variants, forKey: .variants)
        try c.encode(seed, forKey: .seed)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(robustDelta.map(RobustValue.init), forKey: .robust)
        try c.encode(Swift.max(1, frequencyModes), forKey: .frequencyModes)
        try c.encode(massTargetG, forKey: .massTargetG)
        try c.encode(maxBeta, forKey: .maxBeta)
        try c.encode(tolerance, forKey: .tolerance)
        try c.encode(bores, forKey: .bores)
        try c.encode(exactKeepOuts, forKey: .exactKeepOuts)
        try c.encode(Swift.max(1, maxBodies), forKey: .maxBodies)
    }

    /// The stress limit the optimiser holds: the one given, else the allowable over the safety
    /// factor.
    var stressLimit: Double { maxStress ?? material.allowable / Swift.max(safetyFactor, 1e-6) }

    var size: Vec3 { simd_abs(max - min) }

    /// The voxel grid the engine will cut the design space into (`Grid::new`, same rounding).
    var grid: (n: [Int], h: Double) {
        let s = size
        guard voxel > 0, s.min() > 0 else { return ([1, 1, 1], 1) }
        let n0 = (0..<3).map { Swift.max(1, Int((s[$0] / voxel).rounded())) }
        // A thin side (8 voxels or fewer) sets the edge so a plate keeps its thickness.
        let thin = (0..<3).filter { n0[$0] <= 8 }.min { n0[$0] < n0[$1] }
        let h = thin.map { s[$0] / Double(n0[$0]) } ?? (0..<3).map { s[$0] / Double(n0[$0]) }.max() ?? voxel
        return ((0..<3).map { Swift.max(1, Int((s[$0] / h).rounded())) }, h)
    }

    var elementCount: Int { grid.n.reduce(1, *) }
}

extension SIMD3 where Scalar == Double {
    var array: [Double] { [x, y, z] }
}

// MARK: Outcome (read from the engine's reply with [`JSONValue`])

struct StudyGrid: Hashable, Sendable {
    var n: [Int] = [0, 0, 0]
    var h: Double = 1
    var origin = Vec3.zero

    init() {}

    init(_ v: JSONValue) {
        let n = v["n"].doubles.map { $0.isFinite ? max(0, Int($0)) : 0 }
        self.n = n.count == 3 ? n : [0, 0, 0]
        h = v["h"].double ?? 1
        let o = v["origin"].doubles
        origin = o.count == 3 ? Vec3(o[0], o[1], o[2]) : .zero
    }

    var elements: Int { n.reduce(1, *) }
}

/// A triangle mesh, world mm, with the von Mises stress per vertex (MPa) when computed.
struct StudyMesh: Hashable, Sendable {
    var positions: [Float] = []
    var indices: [UInt32] = []
    var stress: [Float] = []

    init() {}

    init(_ v: JSONValue) {
        positions = v["positions"].floats
        indices = v["indices"].uint32s
        stress = v["stress"].floats
    }

    var vertexCount: Int { positions.count / 3 }
    var triangleCount: Int { indices.count / 3 }
}

struct StudyMode: Hashable, Sendable {
    var frequency: Double
    /// Effective mass share per axis.
    var participation: [Double]

    init(_ v: JSONValue) {
        frequency = v["frequency"].double ?? .nan
        participation = v["participation"].doubles
    }
}

struct StudyImpactResponse: Hashable, Sendable {
    var caseIndex: Int
    var time: [Double]
    var stress: [Double]
    var displacement: [Double]
    var peakStress: Double
    var peakDisplacement: Double
    var amplification: Double

    init(_ v: JSONValue) {
        caseIndex = v["case"].int ?? 0
        time = v["time"].doubles
        stress = v["stress"].doubles
        displacement = v["displacement"].doubles
        peakStress = v["peak_stress"].double ?? stress.filter(\.isFinite).max() ?? 0
        peakDisplacement = v["peak_displacement"].double ?? displacement.filter(\.isFinite).max() ?? 0
        amplification = v["amplification"].double ?? 0
    }
}

struct StudyAnalysis: Hashable, Sendable {
    /// Per case: weighted compliance, N·mm.
    var compliance: [Double] = []
    /// Per case: worst von Mises over solid voxels, MPa.
    var maxStress: [Double] = []
    /// Per case: largest nodal displacement, mm.
    var maxDisplacement: [Double] = []
    /// Allowable over the worst static or dynamic stress (infinite when unloaded).
    var safetyFactor: Double = .infinity
    var modes: [StudyMode] = []
    var impacts: [StudyImpactResponse] = []
    /// As built: solid bodies a support holds, the solid's volume, what floated off (mm³), and
    /// the loads nothing carries.
    var bodies = 0
    var solidMM3: Double = 0
    var floatingMM3: Double = 0
    var unsupported: [String] = []

    init() {}

    init(_ v: JSONValue) {
        compliance = v["compliance"].doubles
        maxStress = v["max_stress"].doubles
        maxDisplacement = v["max_displacement"].doubles
        // serde writes a non-finite number as null.
        safetyFactor = v["safety_factor"].double ?? .infinity
        modes = v["modes"].array.map(StudyMode.init)
        impacts = v["impacts"].array.map(StudyImpactResponse.init)
        bodies = v["bodies"].int ?? 0
        solidMM3 = v["solid_mm3"].double ?? 0
        floatingMM3 = v["floating_mm3"].double ?? 0
        unsupported = v["unsupported"].array.compactMap(\.string)
    }

    var worstStress: Double { maxStress.filter(\.isFinite).max() ?? 0 }
    var worstDisplacement: Double { maxDisplacement.filter(\.isFinite).max() ?? 0 }
    var firstFrequency: Double? { modes.first?.frequency }
}

struct StudyCandidate: Identifiable, Hashable, Sendable {
    var id: Int
    var method: String
    var massG: Double
    var volumeFraction: Double
    /// Every limit kept: stress (with the safety factor), displacement, frequency, impacts.
    var feasible: Bool
    var analysis: StudyAnalysis
    /// Objective per iteration.
    var history: [Double]
    var grid: StudyGrid
    /// Physical density per element, 0..1.
    var density: [Float]
    var mesh: StudyMesh
    /// Volume the surface encloses, mm³, and why it fails or what to check.
    var meshMM3: Double = 0
    var issues: [String] = []
    /// Rough cost index, USD (the engine's summary only): material plus machine time.
    var cost: Double?
    /// False for the best design so far of a run that was stopped: analysed and surfaced like
    /// the others, but its optimisation did not settle.
    var converged = true
    /// When the run was stopped: the iterations it had run, and the iteration this keeps.
    var stoppedAt: Int?
    var keptIteration: Int?

    init(_ v: JSONValue, index: Int) {
        id = v["id"].int ?? index
        method = v["method"].string ?? "topology"
        massG = v["mass_g"].double ?? 0
        volumeFraction = v["volume_fraction"].double ?? 0
        feasible = v["feasible"].bool ?? false
        analysis = StudyAnalysis(v["analysis"])
        history = v["history"].doubles.filter(\.isFinite)
        grid = StudyGrid(v["grid"])
        density = v["density"].floats
        mesh = StudyMesh(v["mesh"])
        meshMM3 = v["mesh_mm3"].double ?? 0
        issues = v["issues"].array.compactMap(\.string)
        cost = v["cost"].double
        stoppedAt = v["stopped_at"].int
        keptIteration = v["kept_iteration"].int
        converged = v["converged"].bool ?? (stoppedAt == nil)
    }
}

struct StudyOutcome: Hashable, Sendable {
    var candidates: [StudyCandidate]
    /// The lightest feasible candidate, else the safest.
    var best: Int
    /// Wall time, s.
    var seconds: Double
    /// About the study itself (the grid not matching the box asked for).
    var warnings: [String] = []
    /// The run was stopped before its end; its candidates are what it had (see
    /// `StudyCandidate.converged`).
    var stopped = false

    init(_ v: JSONValue) {
        candidates = v["candidates"].array.enumerated().map { StudyCandidate($1, index: $0) }
        best = v["best"].int ?? 0
        seconds = v["seconds"].double ?? 0
        warnings = v["warnings"].array.compactMap(\.string)
        stopped = v["stopped"].bool ?? (candidates.contains { !$0.converged } || warnings.contains { $0.hasPrefix("stopped ") })
    }

    /// The stopped candidate, if any (the one whose optimisation was cut short).
    var stoppedCandidate: StudyCandidate? { candidates.first { !$0.converged } }
}
