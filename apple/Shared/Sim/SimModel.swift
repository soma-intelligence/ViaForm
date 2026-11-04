import Foundation
import Observation

/// One flight in the Simulation workspace: the options picked, the course, the latest frame and
/// the trail, played in real time (or faster) on the main thread.
@MainActor
@Observable
final class SimModel {
    enum Camera: String, CaseIterable { case follow = "Follow", overview = "Overview" }

    private let engine: SimEngine?
    let catalog: SimCatalog?
    let parts: SimParts?
    var options = SimOptions()
    var speed = 1.0
    var camera = Camera.follow
    private(set) var world: SimWorld?
    private(set) var frame: SimFrame?
    private(set) var status: SimStatus?
    private(set) var trail: [[Double]] = []
    private(set) var playing = false
    private(set) var error: String?
    /// Bumped on every new frame, so the 3D view knows when to move its nodes.
    private(set) var tick = 0
    /// Bumped when a new course is built.
    private(set) var worldVersion = 0
    private var loop: Task<Void, Never>?

    init() {
        let engine = SimEngine()
        self.engine = engine
        catalog = engine?.catalog()
        parts = engine?.parts(frameGrams: 32)
        if engine == nil { error = "The simulation bundle is missing: run scripts/build-sim.sh." }
        reset()
    }

    var waypointCount: Int { world?.waypoints.count ?? 0 }

    /// The run's outcome once it is over, in words.
    var outcome: String? {
        guard let s = status, let f = frame, s.finished else { return nil }
        if s.collided { return String(format: "Hit an obstacle at %.1f s", f.t) }
        if s.crashed { return String(format: "Crashed at %.1f s", f.t) }
        if f.planIndex >= waypointCount - 1 { return String(format: "Course complete in %.1f s", f.t) }
        return String(format: "Time out at %.1f s", f.t)
    }

    /// Builds the course and puts the drone on its start, paused.
    func reset() {
        pause()
        guard let engine else { return }
        guard let w = engine.start(options) else { error = engine.lastError; return }
        world = w
        frame = w.frame
        status = w.status
        trail = [w.frame.p]
        error = nil
        worldVersion += 1
        tick += 1
    }

    func play() {
        if status?.finished == true { reset() }
        guard engine != nil, !playing else { return }
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
        guard let engine, seconds > 0 else { return }
        guard let step = engine.advance(seconds: seconds) else {
            error = engine.lastError
            pause()
            return
        }
        frame = step.frame
        status = step.status
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
}
