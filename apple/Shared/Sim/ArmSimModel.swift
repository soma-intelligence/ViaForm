import Foundation
import Observation
import simd

/// Simulate for an articulated product (VIAFORM-SPEC 7.5, P3-2 to P3-4): the assembly of the
/// Assemble stage in a `viaform-scenario` world on viaform-phys (1 kHz, servos tracking the
/// scenario's drives), live telemetry, the list of episodes, replay of a recorded demonstration
/// (P3-3, a synthetic one until the robot records real ones) and the wrench histories that
/// "Stress here" and the loads sheet hand to Generate (P3-4).
@Observable
final class ArmSimModel: @unchecked Sendable {
    struct Scenario: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        var artifact: String
        var detail: String
        var duration: Double
    }

    struct Randomise: Equatable {
        var massPct = 10.0
        var frictionPct = 20.0
        var latencyMS = 15.0
        var backlashDeg = 0.3
        var seed = 7
    }

    struct Sample: Equatable, Sendable {
        var t: Double
        var q: [Double]
        var effort: [Double]
    }

    struct Wrench: Equatable, Sendable {
        var body: String
        var t: [Double]
        var force: [SIMD3<Double>]
        var torque: [SIMD3<Double>]
        var at: [SIMD3<Double>]
        func magnitude(_ i: Int) -> Double { simd_length(force[i]) }
    }

    struct Episode: Identifiable, Equatable, Sendable {
        var id: Int
        var title: String
        var scenario: String
        /// "Assembly v3": the revision the run was built on.
        var revision: String
        var date: Date
        var duration: Double
        var samples: [Sample]
        var frames: [(t: Double, poses: [String: simd_float4x4])]
        var wrenches: [Wrench]
        var demo: [Sample]?
        var result: String
        var ok: Bool
        static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.samples.count == b.samples.count && a.result == b.result }
    }

    /// What the telemetry chart plots.
    enum Channel: String, CaseIterable, Identifiable {
        case position, effort
        var id: String { rawValue }
        var title: String {
            switch self {
            case .position: String(localized: "Position")
            case .effort: String(localized: "Effort")
            }
        }
    }

    /// Computed so the cube's size follows the reader's length unit (P2-23).
    var scenarios: [Scenario] { [
        Scenario(id: "reach", title: String(localized: "Reach"), artifact: "simulate.reach",
                 detail: String(localized: "Home, ready, reach over the cube and back"), duration: 7),
        Scenario(id: "pick", title: String(localized: "Pick cube"), artifact: "simulate.pick",
                 detail: String(localized: "Down to the \(VFFormat.length(30)) cube, close the jaw, lift"), duration: 8),
    ] }

    var scenarioID = "reach"
    var randomise = Randomise()
    /// The telemetry channel (kept here so it survives a stage switch).
    var channel = Channel.position
    private(set) var running = false
    private(set) var progress = 0.0
    private(set) var episodes: [Episode] = []
    var selectedEpisode: Int?
    private(set) var playhead = 0.0
    private(set) var playing = false
    /// Live samples of the running episode (30 Hz).
    private(set) var live: [Sample] = []
    private(set) var jointNames: [String] = []
    private(set) var actuatorNames: [String] = []
    private(set) var error: String?
    private(set) var realTimeFactor = 0.0
    /// Bumped when the canvas should move to `poses`.
    private(set) var poseRevision = 0
    @ObservationIgnored private(set) var poses: [String: simd_float4x4] = [:]
    @ObservationIgnored private let queue = DispatchQueue(label: "viaform.phys", qos: .userInitiated)
    @ObservationIgnored private var engine: PhysEngine?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The flow job of the running scenario (progress in the job capsule, Command-. stops it).
    @ObservationIgnored private var job: Int?
    @ObservationIgnored private var player: Timer?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored weak var flow: FlowModel?

    var available: Bool { PhysService.shared.available }
    /// A run is going: Stop (Command-.) ends it. Esc never does.
    var isBusy: Bool { running }
    func stopWork() { cancelRun() }
    var scenario: Scenario { scenarios.first { $0.id == scenarioID } ?? scenarios[0] }
    var episode: Episode? { episodes.first { $0.id == selectedEpisode } ?? episodes.last }

    // MARK: Scenario file

    /// The `viaform-scenario` v1 file of a scenario on this assembly.
    func scenarioJSON(_ s: Scenario, assembly: [String: Any], demo: [Sample]? = nil) -> [String: Any] {
        let joints = (assembly["joints"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let poses = (assembly["poses"] as? [[String: Any]] ?? [])
        let ready = (poses.first { ($0["id"] as? String) == "ready" }?["q_deg"] as? [String: Double]) ?? [:]
        var drives: [[String: Any]] = []
        if let demo {
            for (i, j) in joints.enumerated() {
                drives.append(["joint": j, "kind": "servo", "timeline": demo.map { [$0.t, i < $0.q.count ? $0.q[i] : 0] }])
            }
        } else {
            // Keyframes per joint (deg): home, ready, the scenario's reach, back.
            let reach: [String: Double] = s.id == "pick"
                ? ["shoulder_pan": 0, "shoulder_lift": 52, "elbow": 58, "wrist_pitch": 62, "wrist_roll": 0, "gripper": 40]
                : ["shoulder_pan": 25, "shoulder_lift": 40, "elbow": 45, "wrist_pitch": 45, "wrist_roll": 30, "gripper": 10]
            for j in joints {
                let r = ready[j] ?? 0, a = reach[j] ?? r
                var tl: [[Double]] = [[0, 0], [1.2, r], [2.8, a], [4.0, a]]
                if s.id == "pick" {
                    let close = j == "gripper" ? 0.0 : a
                    let lift = j == "shoulder_lift" ? a - 20 : (j == "gripper" ? 0 : a)
                    tl += [[4.6, close], [6.0, lift], [7.5, lift]]
                } else {
                    tl += [[5.4, r], [6.8, 0]]
                }
                drives.append(["joint": j, "kind": "servo", "timeline": tl])
            }
        }
        return [
            "format": "viaform-scenario", "version": 1, "id": s.id, "engine": "phys",
            "world": ["ground": true, "table": ["size_m": [0.8, 0.6], "height_m": 0.0],
                      "objects": [["id": "cube", "shape": "box", "size_m": 0.03, "mass_kg": 0.02, "pose": [0.26, 0.0, 0.015]]]],
            "sensors": ["joint_pos", "joint_vel", "motor_current"],
            "randomise": ["mass_pct": randomise.massPct, "friction_pct": randomise.frictionPct,
                          "latency_ms": randomise.latencyMS, "backlash_deg": randomise.backlashDeg],
            "seed": randomise.seed,
            "drives": drives,
            "record": ["bodies": ["upper_arm", "forearm", "gripper"], "every": 10],
            "duration_s": demo.map { ($0.last?.t ?? 6) + 0.5 } ?? s.duration, "rate_hz": 1000, "control_hz": 50,
        ]
    }

    // MARK: Run

    /// What the run task takes with it: the engine and the JSON objects, used on that task only.
    private struct RunInputs: @unchecked Sendable {
        let engine: PhysEngine
        let assembly: [String: Any]
        let file: [String: Any]
    }

    /// Runs the scenario on the assembly as it is now ("Re-run on Assembly vN"), in real time,
    /// off the main thread. Stop (`cancelRun`) keeps what ran as a stopped episode.
    @MainActor func run(assembly: [String: Any], revision: String, demo: [Sample]? = nil, title: String? = nil) {
        guard !running else { return }
        guard let engine = engine ?? PhysService.shared.make() else {
            error = String(localized: "The physics engine is not linked in this build.")
            return
        }
        self.engine = engine
        stop()
        running = true
        progress = 0
        live = []
        error = nil
        let s = scenario
        let inputs = RunInputs(engine: engine, assembly: assembly, file: scenarioJSON(s, assembly: assembly, demo: demo))
        let id = nextID
        nextID += 1
        let name = title ?? "\(s.title) \(id)"
        // A demo replay compares and builds nothing: it gets no flow job (Stop still ends it).
        job = demo == nil ? flow?.startJob(s.artifact, verb: String(localized: "Simulating"), label: name,
                                           controls: .init(cancel: { [weak self] in self?.cancelRun() })) : nil
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.simulate(inputs, scenario: s, id: id, name: name, revision: revision, demo: demo)
        }
    }

    /// The run loop: 60 Hz chunks of physics, never ahead of the wall clock.
    private func simulate(_ inputs: RunInputs, scenario s: Scenario, id: Int, name: String, revision: String, demo: [Sample]?) async {
        let engine = inputs.engine
        do {
            let info = try engine.call("world_new", ["assembly": inputs.assembly, "scenario": inputs.file])
            let links = info["links"] as? [String] ?? []
            let joints = (info["joints"] as? [[String: Any]] ?? []).filter { j in !["fixed", "floating"].contains(j["kind"] as? String ?? "") }.compactMap { $0["name"] as? String }
            let acts = info["actuators"] as? [String] ?? []
            let dt = info["dt"] as? Double ?? 0.001
            let duration = (info["scenario"] as? [String: Any])?["duration_s"] as? Double ?? s.duration
            _ = try engine.call("episode_record", ["every": 10])
            var buf = Array(repeating: 0.0, count: links.count * 7)
            _ = engine.poses(&buf)
            let home = Self.matrices(buf, links)
            let homeInv = home.mapValues { simd_inverse($0) }
            DispatchQueue.main.async {
                self.jointNames = joints
                self.actuatorNames = acts
            }
            let chunk = max(1, Int((1.0 / 60) / dt))
            let t0 = Date()
            var t = 0.0
            var frames: [(Double, [String: simd_float4x4])] = []
            var lastLive = -1.0
            var lastJobProgress = -1.0
            while t < duration, !Task.isCancelled {
                let r = engine.step(chunk, poses: &buf)
                if r == -2 { throw AssembleError(String(localized: "The simulation diverged at \(VFFormat.value(t, .time)).")) }
                t += Double(chunk) * dt
                let mats = Self.matrices(buf, links)
                var comp: [String: simd_float4x4] = [:]
                for (k, m) in mats { comp[k] = m * (homeInv[k] ?? matrix_identity_float4x4) }
                frames.append((t, comp))
                var sample: Sample?
                if t - lastLive >= 1.0 / 30 {
                    lastLive = t
                    let st = try engine.call("world_state", [:])
                    let q = (st["q"] as? [Double] ?? []).map { $0 * 180 / .pi }
                    sample = Sample(t: t, q: q, effort: st["efforts"] as? [Double] ?? [])
                }
                let wall = Date().timeIntervalSince(t0)
                let (tNow, posesNow, sampleNow) = (t, comp, sample)
                let reportJob = tNow / duration - lastJobProgress >= 0.02
                if reportJob { lastJobProgress = tNow / duration }
                DispatchQueue.main.async {
                    self.poses = posesNow
                    self.poseRevision += 1
                    self.progress = tNow / duration
                    self.realTimeFactor = wall > 0 ? tNow / wall : 0
                    if let sampleNow { self.live.append(sampleNow) }
                    if reportJob, let job = self.job { self.flow?.progress(job: job, fraction: min(tNow / duration, 1)) }
                }
                // Real time: never ahead of the wall clock (a task sleep, not a thread sleep).
                let ahead = t - Date().timeIntervalSince(t0)
                if ahead > 0 { try? await Task.sleep(for: .seconds(ahead)) }
            }
            let stopped = Task.isCancelled && t < duration
            let ep = try engine.call("episode_record", ["get": true])
            let et = ep["t"] as? [Double] ?? []
            let eq = ep["q"] as? [[Double]] ?? []
            let ef = ep["effort"] as? [[Double]] ?? []
            let samples = et.indices.map { i in
                Sample(t: et[i], q: (i < eq.count ? eq[i] : []).map { $0 * 180 / .pi }, effort: i < ef.count ? ef[i] : [])
            }
            let raw = try engine.callRaw("wrench_history", ["pick": "envelope"]) as? [[String: Any]] ?? []
            let wrenches = raw.map(Self.wrench)
            let maxEffort = samples.flatMap { $0.effort.map(abs) }.max() ?? 0
            var result = String(localized: "\(VFFormat.value(t, .time)), peak effort \(VFFormat.value(maxEffort, .custom("N·m")))")
            var ok = true
            if let demo {
                let err = Self.tracking(demo, samples)
                result = String(localized: "Tracks the demo within \(VFFormat.angle(err)) RMS")
                ok = err < 5
            }
            if stopped {
                result = String(localized: "Stopped at \(VFFormat.value(t, .time))")
                ok = false
            }
            let episode = Episode(id: id, title: name, scenario: s.id, revision: revision, date: Date(), duration: t, samples: samples,
                                  frames: frames.enumerated().filter { $0.offset % 2 == 0 }.map { (t: $0.element.0, poses: $0.element.1) },
                                  wrenches: wrenches, demo: demo, result: result, ok: ok)
            let summary = "\(s.title), \(result)"
            DispatchQueue.main.async {
                self.running = false
                self.progress = 1
                self.runTask = nil
                self.episodes.append(episode)
                self.selectedEpisode = episode.id
                self.playhead = episode.duration
                let job = self.job
                self.job = nil
                guard let flow = self.flow, demo == nil else { return }
                if stopped {
                    if let job { flow.cancel(job: job) }
                } else if let job {
                    // Ends the job and builds the artifact, as a run (same as `produce` below).
                    flow.command(["op": "job_end", "job": job, "summary": summary, "source": "run"])
                } else {
                    flow.produce(s.artifact, summary: summary, source: "run")
                }
            }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async {
                self.running = false
                self.runTask = nil
                self.error = message
                if let job = self.job { self.flow?.end(job: job, error: message) }
                self.job = nil
            }
        }
    }

    /// Stops the run (the Stop button, Command-.). What ran stays as a stopped episode.
    func cancelRun() { runTask?.cancel() }

    // MARK: Replay

    func select(_ id: Int) {
        stop()
        selectedEpisode = id
        scrub(to: 0)
    }

    func scrub(to t: Double) {
        guard let e = episode, !e.frames.isEmpty else { return }
        playhead = min(max(t, 0), e.duration)
        let i = e.frames.lastIndex { $0.t <= playhead + 1e-9 } ?? 0
        poses = e.frames[i].poses
        poseRevision += 1
    }

    func togglePlay() { playing ? stop() : play() }

    func play() {
        guard let e = episode, e.duration > 0, !running else { return }
        if playhead >= e.duration - 0.01 { playhead = 0 }
        playing = true
        let start = Date().addingTimeInterval(-playhead)
        player = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }
            let now = Date().timeIntervalSince(start)
            if now >= e.duration { self.scrub(to: e.duration); self.stop() } else { self.scrub(to: now) }
        }
    }

    func stop() {
        player?.invalidate()
        player = nil
        playing = false
    }

    /// The samples the telemetry shows: the running episode, else the selected one.
    var shownSamples: [Sample] { running ? live : (episode?.samples ?? []) }

    // MARK: Demo (P3-3)

    /// A synthetic teleoperation demo of the arm's six joints at 30 Hz (`robot.demos` until the
    /// robot records real ones in phase 7): a reach to the cube and back with hand tremor.
    static func syntheticDemo(joints: Int = 6, seconds: Double = 6) -> [Sample] {
        var out: [Sample] = []
        let keys: [[Double]] = [[0, 0, 0, 0, 0, 0], [0, -30, 90, -60, 0, 0], [10, 35, 50, 55, 15, 35], [10, 45, 55, 60, 15, 0], [0, 20, 60, 40, 0, 0], [0, -30, 90, -60, 0, 0]]
        let n = Int(seconds * 30)
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 11) % 1000) / 1000.0
        }
        for i in 0...n {
            let t = Double(i) / 30
            let s = t / seconds * Double(keys.count - 1)
            let k = min(Int(s), keys.count - 2)
            let f = s - Double(k)
            let e = f * f * (3 - 2 * f)
            let q = (0..<joints).map { j in keys[k][j] + (keys[k + 1][j] - keys[k][j]) * e + (noise() - 0.5) * 0.8 }
            out.append(Sample(t: t, q: q, effort: []))
        }
        return out
    }

    /// The demo as a `robot.demos` episode file (JSON).
    static func demoFile(_ demo: [Sample], joints: [String]) -> [String: Any] {
        ["format": "viaform-demo", "version": 1, "id": "demo_001", "source": "synthetic", "rate_hz": 30,
         "joints": joints, "t": demo.map(\.t), "q_deg": demo.map(\.q)]
    }

    static func tracking(_ demo: [Sample], _ sim: [Sample]) -> Double {
        guard !sim.isEmpty else { return .infinity }
        var sum = 0.0, n = 0.0
        for d in demo {
            guard let s = sim.min(by: { abs($0.t - d.t) < abs($1.t - d.t) }) else { continue }
            for j in 0..<min(d.q.count, s.q.count) {
                sum += (d.q[j] - s.q[j]) * (d.q[j] - s.q[j])
                n += 1
            }
        }
        return n > 0 ? sqrt(sum / n) : 0
    }

    // MARK: Pieces

    private static func matrices(_ buf: [Double], _ links: [String]) -> [String: simd_float4x4] {
        var out: [String: simd_float4x4] = [:]
        for (i, name) in links.enumerated() where (i + 1) * 7 <= buf.count {
            let b = i * 7
            let r = simd_quatf(ix: Float(buf[b + 4]), iy: Float(buf[b + 5]), iz: Float(buf[b + 6]), r: Float(buf[b + 3]))
            var m = simd_float4x4(r)
            m.columns.3 = SIMD4(Float(buf[b] * 1000), Float(buf[b + 1] * 1000), Float(buf[b + 2] * 1000), 1)
            out[name] = m
        }
        return out
    }

    private static func wrench(_ d: [String: Any]) -> Wrench {
        func v(_ k: String) -> [SIMD3<Double>] { (d[k] as? [[Double]] ?? []).map { SIMD3($0[0], $0[1], $0[2]) } }
        return Wrench(body: d["body"] as? String ?? "", t: d["t"] as? [Double] ?? [], force: v("force"), torque: v("torque"), at: v("at"))
    }

    func clearError() { error = nil }
}
