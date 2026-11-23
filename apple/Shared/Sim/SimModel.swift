import Foundation
import Observation

/// One flight in the Simulation workspace: the options picked, the course, the latest frame and
/// the trail, played in real time (or faster) on the main thread. Also the stress test's
/// disturbances, the sticks of a manual race, the generated frame and the training.
@MainActor
@Observable
final class SimModel {
    enum Camera: String, CaseIterable { case follow = "Follow", overview = "Overview" }

    private let engine: SimEngine
    let catalog: SimCatalog?
    let parts: SimParts?
    var options = SimOptions() {
        didSet {
            // The stress test is for the stabilization brains, tuned on the realistic plant.
            if options.mission == "stress", oldValue.mission != "stress", !["stable", "indi", "custom"].contains(options.brain) {
                options.brain = "indi"
            }
        }
    }
    var speed = 1.0
    var camera = Camera.follow
    private(set) var world: SimWorld?
    private(set) var frame: SimFrame?
    private(set) var status: SimStatus?
    private(set) var stabilization: SimStabilization?
    private(set) var race: SimRace?
    private(set) var trail: [[Double]] = []
    private(set) var playing = false
    private(set) var error: String?
    /// Bumped on every new frame, so the 3D view knows when to move its nodes.
    private(set) var tick = 0
    /// Bumped when a new course is built.
    private(set) var worldVersion = 0
    private var loop: Task<Void, Never>?

    /// The sticks of a manual flight (keyboard on the Mac, joysticks on touch screens).
    var sticks = SimSticks() {
        didSet { if sticks != oldValue { engine.pilot(sticks, mode: options.pilotMode) } }
    }

    /// The generated frame found on disk (docs/generative/drone-frame.json), what it builds, and
    /// whether the drone is built from it.
    private(set) var generatedFrame: (url: URL, text: String, airframe: Result<SimAirframe, SimFrameError>)?
    var useGeneratedFrame = false { didSet { applyFrame() } }

    /// The sourced components (docs/components/drone.json) and their assembly
    /// (docs/generative/drone/assembly.json), what they build, and whether the drone is built from them.
    private(set) var realParts: (url: URL, text: String, assembly: String?, frame: String?, vehicle: Result<SimVehicle, SimFrameError>)?
    var useRealParts = false { didSet { applyFrame() } }

    let training = SimTraining()

    init() {
        let engine = SimEngine()
        self.engine = engine
        catalog = engine.catalog()
        parts = engine.parts(frameGrams: 32)
        reloadGeneratedFrame()
        reset()
    }

    var waypointCount: Int { world?.waypoints.count ?? 0 }
    var isManual: Bool { options.mission == "manual" }
    var isStress: Bool { options.mission == "stress" }

    /// The run's outcome once it is over, in words.
    var outcome: String? {
        guard let s = status, let f = frame, s.finished else { return nil }
        if let r = race {
            if r.state == "finished" { return String(format: "Race won in %.1f s", r.time) }
            if r.state == "crashed" || s.collided || s.crashed { return String(format: "Crashed at %.1f s, %d of %d gates", f.t, r.next, r.gates) }
            return String(format: "Time out, %d of %d gates", r.next, r.gates)
        }
        if s.collided { return String(format: "Hit an obstacle at %.1f s", f.t) }
        if s.crashed { return String(format: "Crashed at %.1f s", f.t) }
        if isStress || options.mission == "hover" {
            let back = stabilization?.recoveries.filter { $0.recoveredAfter != nil }.count ?? 0
            return "Held on, \(back) of \(stabilization?.recoveries.count ?? 0) recovered"
        }
        if f.planIndex >= waypointCount - 1 { return String(format: "Course complete in %.1f s", f.t) }
        return String(format: "Time out at %.1f s", f.t)
    }

    /// Builds the course and puts the drone on its start, paused.
    func reset() {
        pause()
        sticks = SimSticks()
        guard let w = engine.start(options) else { error = engine.lastError; return }
        world = w
        frame = w.frame
        status = w.status
        race = w.race
        stabilization = nil
        trail = [w.frame.p]
        error = nil
        worldVersion += 1
        tick += 1
    }

    func play() {
        if status?.finished == true { reset() }
        guard !playing else { return }
        playing = true
        loop = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.playing else { return }
                let now = Date()
                // At most a tenth of a second per frame, so a stalled UI never jumps the drone.
                self.advance(min(now.timeIntervalSince(last), 0.1) * self.speed)
                last = now
            }
        }
    }

    func pause() {
        playing = false
        loop?.cancel()
        loop = nil
    }

    func toggle() { playing ? pause() : play() }

    /// Advances the flight by `seconds` of simulated time.
    func advance(_ seconds: Double) {
        guard seconds > 0 else { return }
        guard let step = engine.advance(seconds: seconds) else {
            error = engine.lastError
            pause()
            return
        }
        frame = step.frame
        status = step.status
        stabilization = step.stabilization
        race = step.race
        trail.append(contentsOf: step.trail)
        tick += 1
        if step.status.finished { pause() }
    }

    /// Runs the whole flight at once (for tests and the "Run to end" button).
    func runToEnd(limit: Double = 60) {
        pause()
        var t = 0.0
        while status?.finished != true, t < limit {
            advance(0.5)
            t += 0.5
        }
    }

    /// One disturbance now: kick, gust, tumble, payload or prop; "timed" toggles random ones.
    func disturb(_ kind: String) {
        if !engine.disturb(kind) { error = "Unknown disturbance \(kind)" }
    }

    /// Flies the brain a training ended with.
    func flyTrained(_ brainJSON: String) {
        options.customBrain = brainJSON
        options.brain = "custom"
    }

    // MARK: Generated frame

    /// Where the generative design writes the drone's frame. An app run from the repo finds it
    /// next to its sources; `VIAFORM_DRONE_FRAME` points elsewhere; a copy in the app's documents
    /// (iPad file sharing) comes first.
    static func docsURLs(_ relative: String, env: String, fileName: String) -> [URL] {
        var urls: [URL] = []
        if let e = ProcessInfo.processInfo.environment[env] { urls.append(URL(fileURLWithPath: e)) }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(docs.appendingPathComponent(fileName))
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        urls.append(repo.appendingPathComponent(relative))
        return urls
    }

    private static func firstText(_ urls: [URL]) -> (URL, String)? {
        for url in urls { if let t = try? String(contentsOf: url, encoding: .utf8) { return (url, t) } }
        return nil
    }

    static func generatedFrameURLs() -> [URL] {
        var urls: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VIAFORM_DRONE_FRAME"] { urls.append(URL(fileURLWithPath: env)) }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(docs.appendingPathComponent("drone-frame.json"))
        }
        // apple/Shared/Sim/SimModel.swift -> the repo root.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        urls.append(repo.appendingPathComponent("docs/generative/drone-frame.json"))
        return urls
    }

    /// Looks for the generated frame again; the drone falls back to the nominal one without it.
    func reloadGeneratedFrame() {
        generatedFrame = nil
        for url in Self.generatedFrameURLs() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            generatedFrame = (url, text, engine.airframe(text))
            break
        }
        realParts = nil
        if let (url, text) = Self.firstText(Self.docsURLs("docs/components/drone.json", env: "VIAFORM_DRONE_COMPONENTS", fileName: "drone.json")) {
            let assembly = Self.firstText(Self.docsURLs("docs/generative/drone/assembly.json", env: "VIAFORM_DRONE_ASSEMBLY", fileName: "assembly.json"))?.1
            let frame: String? = if let g = generatedFrame, case .success = g.airframe { g.text } else { nil }
            realParts = (url, text, assembly, frame, engine.vehicle(components: text, assembly: assembly, frame: frame))
        }
        applyFrame()
    }

    private func applyFrame() {
        let real: (String, String?)? = if useRealParts, let r = realParts, case .success = r.vehicle { (r.text, r.assembly) } else { nil }
        // The sourced drone is built on the generated frame it was read with, as its summary says.
        let text: String? = if useGeneratedFrame, let g = generatedFrame, case .success = g.airframe { g.text }
            else if real != nil { realParts?.frame } else { nil }
        if options.frame != text { options.frame = text }
        if options.components != real?.0 { options.components = real?.0 }
        if options.assembly != real?.1 { options.assembly = real?.1 }
    }

    var airframe: SimAirframe? { world?.airframe }

    /// The sourced drone the running session flies (its placements and frame), when it is one.
    var vehicle: SimVehicle? { world?.vehicle }
}

/// A training on the core's threads, polled while it runs: its cost curve, then the brain it found
/// and the held-out cost before and after.
@MainActor
@Observable
final class SimTraining {
    enum Target: String, CaseIterable, Identifiable {
        case tracking, stabilize, policy
        var id: String { rawValue }
        var name: String {
            switch self {
            case .tracking: "PID gains, tracking"
            case .stabilize: "Gains, realistic stabilization"
            case .policy: "Neural residual"
            }
        }
    }

    var target = Target.tracking
    var rateLoop = "pid"
    var iterations = 12
    var population = 16
    var episodes = 6
    private(set) var history: [SimTrainJob.Point] = []
    private(set) var stage = ""
    private(set) var running = false
    private(set) var total = 0
    private(set) var heldOut: (before: Double, after: Double)?
    private(set) var brainJSON: String?
    private(set) var error: String?
    private var job: SimTrainJob?
    private var poll: Task<Void, Never>?

    func start() {
        cancel()
        history = []
        heldOut = nil
        brainJSON = nil
        error = nil
        let opts: [String: Any] = [
            "target": target.rawValue, "rateLoop": rateLoop, "iterations": iterations, "population": population, "episodes": episodes,
        ]
        guard let job = SimTrainJob(options: opts) else { error = "The training options were refused."; return }
        self.job = job
        running = true
        total = iterations
        stage = "starting"
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.refresh() else { return }
            }
        }
    }

    /// Reads the job's progress; false once it has ended.
    @discardableResult
    func refresh() -> Bool {
        guard let job, let p = job.progress() else { return false }
        history = p.history
        stage = p.stage
        total = p.total
        error = p.error
        if !p.running {
            running = false
            if let r = p.result { heldOut = (r.heldOut.before, r.heldOut.after) }
            brainJSON = job.brainJSON
            return false
        }
        return true
    }

    func cancel() {
        job?.cancel()
        poll?.cancel()
        poll = nil
        if running {
            // The job stops after its current iteration; wait for it so its brain is kept.
            while job?.progress()?.running == true { Thread.sleep(forTimeInterval: 0.05) }
            refresh()
        }
        running = false
    }

    /// Runs a training to its end (the self-test).
    func runToEnd() {
        start()
        poll?.cancel()
        while refresh() { Thread.sleep(forTimeInterval: 0.05) }
    }
}
