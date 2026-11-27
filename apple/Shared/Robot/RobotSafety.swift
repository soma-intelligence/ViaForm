import Foundation
import Observation
import SwiftUI

/// The software safety state of the Robot stage (VIAFORM-SPEC 6.4, FRONTEND-SPEC 7.9, R-8).
///
/// - E-stop: the button, Space, or Esc twice within 0.6 s latch it: torque off on every motor
///   (the link sends it once a robot is connected, task P7-2) and every motion verb is blocked
///   until a deliberate re-enable (hold 1 s).
/// - Limits: the teleop speed cap, the torque limit and the workspace fence are stored settings.
///   They are shown as "not applied" while no robot is connected.
/// - Motion: the first motion of a session needs a confirmation (`requireConfirm`) listing the
///   limits and what will run; `moving` drives the red `MotionFrame` and the e-stop pulse.
@MainActor
@Observable
final class RobotSafety {
    static let shared: RobotSafety = {
        // `--robot-selftest`: runs the checks below and exits (same pattern as `--flow-selftest`).
        if ProcessInfo.processInfo.arguments.contains("--robot-selftest") { RobotSafetySelfTest.run() }
        return RobotSafety()
    }()

    /// Where the e-stop was pressed. `stop(source:)` takes the raw value ("Button", "Space",
    /// "Esc twice") so the keyboard path in ProjectWindow stays a plain string.
    enum StopSource: String {
        case button = "Button"
        case space = "Space"
        case escTwice = "Esc twice"

        /// "Stopped with ..." words.
        var words: String {
            switch self {
            case .button: String(localized: "the button")
            case .space: String(localized: "Space")
            case .escTwice: String(localized: "Esc twice")
            }
        }
    }

    // MARK: E-stop

    private(set) var stopped = false
    /// What pressed it: "Button", "Space", "Esc twice" (raw `StopSource` values).
    private(set) var source = ""
    private(set) var at: Date?
    @ObservationIgnored private var lastEscape: Date?

    // MARK: Link and motion

    /// A robot is connected (simulated, bus adapter or bridge). Set by `connect` and `disconnect`.
    private(set) var connected = false
    /// The link every motion goes through. Only this gate commands it.
    @ObservationIgnored private(set) var link: (any RobotLink)?
    /// The link's last reported state, mirrored each tick so views observe it.
    private(set) var linkState: RobotState?
    /// The kind of the connected link, for the connection choice and the device rows.
    private(set) var linkKind: RobotLinkKind?
    /// What the robot is doing now ("Jog Elbow", "Demo 1"), nil at rest.
    private(set) var activity: String?
    /// The joint targets of the running motion, one frame per `planRate` tick.
    @ObservationIgnored private var plan: [[Double]] = []
    @ObservationIgnored private var planRate: Double = 50
    @ObservationIgnored private var planTime: Double = 0
    @ObservationIgnored private var driver: Task<Void, Never>?
    /// The control rate (VIAFORM-SPEC 6.4: 50 Hz default).
    static let controlRate: Double = 50
    /// The first motion of this session was confirmed (`requireConfirm`). Cleared by an e-stop,
    /// so motion after a stop needs a new confirmation.
    private(set) var sessionConfirmed = false
    /// A robot is moving under a path, a policy or teleop.
    private(set) var moving = false
    /// Counts motion starts; the e-stop pulses once on each change (not under Reduce Motion).
    private(set) var motionStarts = 0

    // MARK: Limits (stored settings)

    static let speedCapRange: ClosedRange<Double> = 5...100
    static let torqueLimitRange: ClosedRange<Double> = 10...100
    static let defaultSpeedCap: Double = 30
    static let defaultTorqueLimit: Double = 60

    @ObservationIgnored private let defaults: UserDefaults

    /// Teleop and playback speed cap, percent of the joint's rated speed.
    var speedCap: Double {
        didSet {
            let v = min(max(speedCap, Self.speedCapRange.lowerBound), Self.speedCapRange.upperBound)
            if v != speedCap { speedCap = v }
            defaults.set(v, forKey: Keys.speedCap)
        }
    }

    /// Torque limit, percent of the motor's stall torque.
    var torqueLimit: Double {
        didSet {
            let v = min(max(torqueLimit, Self.torqueLimitRange.lowerBound), Self.torqueLimitRange.upperBound)
            if v != torqueLimit { torqueLimit = v }
            defaults.set(v, forKey: Keys.torqueLimit)
        }
    }

    /// The workspace fence from the Assemble joint limits.
    var fenceEnabled: Bool {
        didSet { defaults.set(fenceEnabled, forKey: Keys.fence) }
    }

    private enum Keys {
        static let speedCap = "robot.speedCapPercent"
        static let torqueLimit = "robot.torqueLimitPercent"
        static let fence = "robot.fenceEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let s = defaults.object(forKey: Keys.speedCap) as? Double ?? Self.defaultSpeedCap
        let t = defaults.object(forKey: Keys.torqueLimit) as? Double ?? Self.defaultTorqueLimit
        speedCap = min(max(s, Self.speedCapRange.lowerBound), Self.speedCapRange.upperBound)
        torqueLimit = min(max(t, Self.torqueLimitRange.lowerBound), Self.torqueLimitRange.upperBound)
        fenceEnabled = defaults.object(forKey: Keys.fence) as? Bool ?? true
    }

    // MARK: Derived words

    /// A motion verb may run: a robot is connected and the e-stop is not latched.
    var canMove: Bool { connected && !stopped }

    /// Why motion verbs are locked, or nil when they are not.
    var lockReason: String? {
        if stopped { return String(localized: "E-stop is latched. Hold Re-enable Motors first.") }
        if !connected { return String(localized: "No robot connected") }
        return nil
    }

    /// The speed cap as the safety bar shows it: the value with a robot, "not applied" without.
    var speedCapText: String { connected ? VFFormat.value(speedCap, .percent) : Self.notApplied }
    var torqueLimitText: String { connected ? VFFormat.value(torqueLimit, .percent) : Self.notApplied }
    var fenceText: String {
        guard connected else { return Self.notApplied }
        return fenceEnabled ? String(localized: "Armed, Assemble joint limits") : String(localized: "Off")
    }

    static var notApplied: String { String(localized: "Not applied, no robot") }

    /// "Stopped with the button at 10:42:01."
    var stopSentence: String {
        let who = StopSource(rawValue: source)?.words ?? (source.isEmpty ? StopSource.button.words : source)
        if let at {
            let time = at.formatted(date: .omitted, time: .standard)
            return String(localized: "Stopped with \(who) at \(time).")
        }
        return String(localized: "Stopped with \(who).")
    }

    // MARK: E-stop API (ProjectWindow calls `stop(source:)` and `escape()`)

    /// Latches the stop: torque goes off on the link now (not on the next tick), motion ends,
    /// the session needs a new confirmation.
    func stop(source: String) {
        link?.torqueOff()
        plan = []
        activity = nil
        linkState = link?.state
        stopped = true
        moving = false
        sessionConfirmed = false
        self.source = source
        at = Date()
    }

    /// Space in the Robot stage: stops, unless the stop is already latched. Then Space belongs
    /// to the focused control (Re-enable Motors is held with Space), so it is not taken and never
    /// re-latches the stop. True when the key was taken.
    @discardableResult
    func spaceKey() -> Bool {
        guard !stopped else { return false }
        stop(source: StopSource.space.rawValue)
        return true
    }

    /// One Esc: the second within 0.6 s stops. True when the key was taken.
    @discardableResult
    func escape(now: Date = Date()) -> Bool {
        if let last = lastEscape, now.timeIntervalSince(last) <= 0.6 {
            lastEscape = nil
            stop(source: StopSource.escTwice.rawValue)
            return true
        }
        lastEscape = now
        return false
    }

    /// After the hold: motors may be enabled again. Motion still needs a new confirmation.
    func reenable() {
        stopped = false
        source = ""
        at = nil
        link?.torqueOn()
        linkState = link?.state
    }

    // MARK: Motion confirmation

    /// The words of the "Run on Robot" confirmation: limits, fence, what runs and its revision,
    /// and the simulated success rate when known.
    func motionSummary(target: String, revision: String?, simSuccessRate: Double? = nil) -> String {
        let speed = VFFormat.value(speedCap, .percent)
        let torque = VFFormat.value(torqueLimit, .percent)
        let fence = fenceEnabled ? String(localized: "on, from the Assemble joint limits") : String(localized: "off")
        let what = revision.map { String(localized: "\(target), \($0)") } ?? target
        var lines = [
            String(localized: "Runs \(what) on the connected robot."),
            String(localized: "Speed cap: \(speed)"),
            String(localized: "Torque limit: \(torque)"),
            String(localized: "Workspace fence: \(fence)"),
        ]
        if let r = simSuccessRate {
            let pct = VFFormat.value(r * 100, .percent)
            lines.append(String(localized: "Simulated success: \(pct)"))
        }
        lines.append(String(localized: "Space or Esc twice stops it at any time."))
        return lines.joined(separator: "\n")
    }

    /// The confirmation needed before the first motion of a session, or nil when this session
    /// already confirmed (run `perform` directly then). Confirming marks the session and runs
    /// `perform`. Returns nil and does nothing useful when motion is locked: check `canMove` first.
    func requireConfirm(target: String, revision: String?, simSuccessRate: Double? = nil,
                        perform: @escaping () -> Void) -> ConfirmRequest? {
        guard !sessionConfirmed else { return nil }
        return ConfirmRequest(
            title: String(localized: "Run on Robot?"),
            message: motionSummary(target: target, revision: revision, simSuccessRate: simSuccessRate),
            verb: String(localized: "Run on Robot"),
            destructive: false,
            perform: { [weak self] in
                self?.sessionConfirmed = true
                perform()
            })
    }

    /// Marks the session as confirmed without a sheet (the link replays a stored confirm token).
    func confirmSession() { sessionConfirmed = true }

    /// Starts motion when allowed: connected, not stopped, session confirmed. True when it started.
    @discardableResult
    func beginMotion() -> Bool {
        guard canMove, sessionConfirmed else { return false }
        if !moving {
            moving = true
            motionStarts += 1
        }
        return true
    }

    /// Motion ended normally (path done, teleop released).
    func endMotion() {
        moving = false
        activity = nil
        plan = []
    }

    // MARK: Link

    /// Connects a link. Motion still needs this session's confirmation; a latched e-stop keeps
    /// torque off. `autoTick` runs the control loop at `controlRate` (tests tick by hand).
    func connect(_ link: any RobotLink, autoTick: Bool = true) {
        disconnect()
        self.link = link
        linkKind = link.kind
        connected = true
        sessionConfirmed = false
        if stopped { link.torqueOff() } else { link.hold() }
        linkState = link.state
        guard autoTick else { return }
        let dt = 1 / Self.controlRate
        driver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(dt))
                guard let self, !Task.isCancelled else { return }
                self.tick(dt: dt)
            }
        }
    }

    /// Holds the pose and drops the link. The next connection needs a new confirmation.
    func disconnect() {
        driver?.cancel()
        driver = nil
        link?.hold()
        if moving { endMotion() }
        link = nil
        linkKind = nil
        linkState = nil
        connected = false
        sessionConfirmed = false
    }

    /// The caps as the link receives them, read from the stored settings.
    var commandLimits: RobotCommandLimits {
        RobotCommandLimits(speed: speedCap / 100, torque: torqueLimit / 100)
    }

    /// The workspace fence: targets clamped to the joint limits while it is on.
    func fenced(_ targets: [Double]) -> [Double] {
        guard fenceEnabled, let joints = link?.joints, joints.count == targets.count else { return targets }
        return zip(targets, joints).map { min(max($0, $1.range.lowerBound), $1.range.upperBound) }
    }

    // MARK: Motion gate

    /// A motion verb. Every one goes through `submit` (or `request`, which asks first).
    enum Motion {
        /// Teleop: one joint by `delta` degrees from its commanded target.
        case jog(joint: Int, delta: Double)
        /// A pose committed from a drag (twin or Assemble IK), joint targets in degrees.
        case pose([Double], label: String)
        /// A path (demo replay, policy rollout), frames of joint targets at `rate` Hz.
        case trajectory([[Double]], rate: Double, label: String)
    }

    enum Refusal: Error, Equatable {
        case noRobot, stopped, unconfirmed, badRequest
    }

    /// Starts `motion` when the gate allows it: a link, no latched e-stop, this session confirmed.
    /// Targets pass the fence; the caps go with every command. Returns why it was refused, or nil.
    @discardableResult
    func submit(_ motion: Motion) -> Refusal? {
        guard let link else { return .noRobot }
        guard !stopped else { return .stopped }
        guard sessionConfirmed else { return .unconfirmed }
        let n = link.joints.count
        let frames: [[Double]]
        let rate: Double
        let label: String
        switch motion {
        case .jog(let j, let delta):
            guard link.joints.indices.contains(j) else { return .badRequest }
            var t = plan.last ?? link.state.targets
            t[j] += delta
            frames = [t]
            rate = Self.controlRate
            label = String(localized: "Jog \(link.joints[j].name)")
        case .pose(let p, let l):
            frames = [p]; rate = Self.controlRate; label = l
        case .trajectory(let f, let r, let l):
            frames = f; rate = r; label = l
        }
        guard !frames.isEmpty, rate > 0, frames.allSatisfy({ $0.count == n }) else { return .badRequest }
        plan = frames.map(fenced)
        planRate = rate
        planTime = 0
        activity = label
        guard beginMotion() else { plan = []; activity = nil; return .unconfirmed }
        link.command(targets: plan[0], limits: commandLimits)
        linkState = link.state
        return nil
    }

    /// From a view: runs `motion`, or hands `present` the "Run on Robot?" confirmation first
    /// when this session has not confirmed. Returns why it is locked, or nil.
    @discardableResult
    func request(_ motion: Motion, target: String, revision: String? = nil, simSuccessRate: Double? = nil,
                 present: (ConfirmRequest) -> Void) -> String? {
        if let reason = lockReason { return reason }
        if let c = requireConfirm(target: target, revision: revision, simSuccessRate: simSuccessRate,
                                  perform: { [weak self] in _ = self?.submit(motion) }) {
            present(c)
            return nil
        }
        submit(motion)
        return nil
    }

    /// One control cycle: the running plan's frame goes out with the current caps, the link
    /// steps, the state is mirrored. Motion ends once the last frame is reached and settled.
    func tick(dt: Double) {
        guard let link else { return }
        if moving, !stopped, !plan.isEmpty {
            planTime += dt
            let i = min(Int(planTime * planRate), plan.count - 1)
            link.command(targets: plan[i], limits: commandLimits)
            link.tick(dt: dt)
            let s = link.state
            let settled = zip(s.targets, s.positions).allSatisfy { abs($0 - $1) < 0.05 }
                && s.velocities.allSatisfy { abs($0) < 0.5 }
            if i == plan.count - 1, settled { endMotion() }
        } else {
            link.tick(dt: dt)
        }
        linkState = link.state
    }

    // MARK: Paths until phase 7

    /// A synthetic path (VIAFORM-SPEC P3-3: synthetic demo until phase 7): a smooth wave within
    /// half of each joint's range, `seconds` long at `rate` Hz, starting and ending at rest.
    static func syntheticPath(joints: [RobotJointSpec], seconds: Double = 3, rate: Double = controlRate,
                              phase: Double = 0) -> [[Double]] {
        let count = max(2, Int(seconds * rate))
        return (0..<count).map { k in
            let u = Double(k) / Double(count - 1)
            let envelope = sin(.pi * u)
            return joints.enumerated().map { i, j in
                let home = min(max(0, j.range.lowerBound), j.range.upperBound)
                let span = (j.range.upperBound - j.range.lowerBound) / 4
                let wave = sin(2 * .pi * u + Double(i) * 0.7 + phase)
                return min(max(home + envelope * span * wave, j.range.lowerBound), j.range.upperBound)
            }
        }
    }
}

// MARK: - Self checks

/// `--robot-selftest`: one line per check, exit code 1 on any failure. The gate checks also run
/// in `ViaFormRobotTests`; this follows `FlowSelfTest`.
@MainActor
enum RobotSafetySelfTest {
    static func run() -> Never {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "PASS" : "FAIL", name)
            if !ok { failures += 1 }
        }
        let suite = "viaform-robot-selftest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        let s = RobotSafety(defaults: d)
        check("defaults: speed cap 30 %", s.speedCap == 30)
        check("defaults: torque limit 60 %", s.torqueLimit == 60)
        check("no robot: limits read not applied", s.speedCapText == RobotSafety.notApplied && s.torqueLimitText == RobotSafety.notApplied)
        check("no robot: cannot move", !s.canMove && s.lockReason != nil)
        check("no robot: beginMotion refused", !s.beginMotion() && !s.moving)

        s.speedCap = 500
        check("speed cap clamps to 100 %", s.speedCap == 100)
        s.speedCap = 25
        check("speed cap persists", RobotSafety(defaults: d).speedCap == 25)

        s.connect(SimulatedRobotLink(), autoTick: false)
        check("connected: limits shown", s.speedCapText == VFFormat.value(25, .percent))
        check("unconfirmed: beginMotion refused", !s.beginMotion())
        var ran = false
        let req = s.requireConfirm(target: "Pick and place", revision: "Policy v3", simSuccessRate: 0.92) { ran = true }
        check("first motion asks to confirm", req != nil && req?.verb == String(localized: "Run on Robot"))
        let msg = req?.message ?? ""
        check("confirmation lists speed cap, torque, fence, revision, success",
              msg.contains("25") && msg.contains("60") && msg.contains("Policy v3") && msg.contains("92"))
        req?.perform()
        check("confirming runs and marks the session", ran && s.sessionConfirmed)
        check("second motion needs no confirmation", s.requireConfirm(target: "x", revision: nil) {} == nil)
        check("beginMotion starts and counts", s.beginMotion() && s.moving && s.motionStarts == 1)
        check("beginMotion while moving does not pulse again", s.beginMotion() && s.motionStarts == 1)

        s.stop(source: "Space")
        check("e-stop ends motion and clears the session", s.stopped && !s.moving && !s.sessionConfirmed)
        check("stop sentence names the key", s.stopSentence.hasPrefix(String(localized: "Stopped with \(String(localized: "Space"))")))
        check("stopped: beginMotion refused", !s.beginMotion())
        s.reenable()
        check("re-enable clears the latch, keeps the session unconfirmed", !s.stopped && !s.sessionConfirmed)

        let t0 = Date()
        check("one Esc does not stop", !s.escape(now: t0) && !s.stopped)
        check("Esc twice within 0.6 s stops", s.escape(now: t0.addingTimeInterval(0.4)) && s.stopped && s.source == "Esc twice")
        s.reenable()
        _ = s.escape(now: t0)
        check("Esc twice 1 s apart does not stop", !s.escape(now: t0.addingTimeInterval(1.0)) && !s.stopped)

        // The gate with the simulated link.
        for (name, ok) in RobotGateChecks.run(defaults: d) { check(name, ok) }

        let k = RobotSafety(defaults: d)
        check("Space stops when running", k.spaceKey() && k.stopped && k.source == "Space")
        let latchedAt = k.at
        check("Space while latched is left to the focused control (Re-enable)", !k.spaceKey() && k.at == latchedAt)
        k.reenable()

        print(failures == 0 ? "robot selftest: all passed" : "robot selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: - Gate checks

/// The motion gate driven through `SimulatedRobotLink`, by hand ticks at the control rate. Shared
/// by `--robot-selftest` and the unit tests (`ViaFormRobotTests`).
@MainActor
enum RobotGateChecks {
    static func run(defaults: UserDefaults) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) { out.append(("gate: " + name, ok)) }
        let dt = 1 / RobotSafety.controlRate
        let g = RobotSafety(defaults: defaults)
        g.speedCap = RobotSafety.defaultSpeedCap
        g.torqueLimit = RobotSafety.defaultTorqueLimit
        g.fenceEnabled = true

        check("no link: motion refused", g.submit(.jog(joint: 0, delta: 10)) == (.noRobot))
        let link = SimulatedRobotLink()
        g.connect(link, autoTick: false)
        let rest = link.state.positions
        check("connect: connected, session not confirmed", g.connected && !g.sessionConfirmed && g.linkKind == .simulated)

        // No motion without confirmation.
        check("unconfirmed: submit refused", g.submit(.jog(joint: 2, delta: 10)) == (.unconfirmed))
        for _ in 0..<25 { g.tick(dt: dt) }
        check("unconfirmed: robot did not move", link.state.positions == rest && !g.moving)
        var sheet: ConfirmRequest?
        let locked = g.request(.jog(joint: 2, delta: 10), target: "Jog", present: { sheet = $0 })
        check("request asks to confirm first", locked == nil && sheet != nil && !g.moving)
        for _ in 0..<10 { g.tick(dt: dt) }
        check("unanswered confirmation: still no motion", link.state.positions == rest)
        sheet?.perform()
        check("confirming starts the jog", g.sessionConfirmed && g.moving && link.state.targets[2] == rest[2] + 10)

        // Caps come from RobotSafety.
        check("caps sent from the settings", link.lastLimits == RobotCommandLimits(speed: 0.30, torque: 0.60))
        var maxV = 0.0, maxE = 0.0
        for _ in 0..<150 {
            g.tick(dt: dt)
            maxV = max(maxV, link.state.velocities.map(abs).max() ?? 0)
            maxE = max(maxE, link.state.efforts.max() ?? 0)
        }
        check("jog reached its target and motion ended", abs(link.state.positions[2] - (rest[2] + 10)) < 0.1 && !g.moving && g.activity == nil)
        g.speedCap = 10
        g.torqueLimit = 20
        let far = link.joints.map { $0.range.upperBound }
        g.submit(.pose(far, label: "Far"))
        maxV = 0; maxE = 0
        for _ in 0..<50 {
            g.tick(dt: dt)
            for (i, j) in link.joints.enumerated() { maxV = max(maxV, abs(link.state.velocities[i]) / j.ratedSpeed) }
            maxE = max(maxE, link.state.efforts.max() ?? 0)
        }
        check("speed cap clamps joint speed", maxV <= 0.10 + 1e-9 && maxV > 0.05)
        check("torque limit clamps effort", maxE <= 20 + 1e-9 && maxE > 0)
        check("lowered caps reach the link", link.lastLimits == RobotCommandLimits(speed: 0.10, torque: 0.20))

        // Fence.
        g.submit(.pose(link.joints.map { $0.range.upperBound + 500 }, label: "Out"))
        check("fence clamps targets to the joint limits", link.state.targets == far)
        check("bad pose refused", g.submit(.pose([1, 2], label: "Short")) == (.badRequest))

        // E-stop latches and cuts within one tick.
        g.speedCap = 100
        g.torqueLimit = 100
        g.submit(.trajectory(RobotSafety.syntheticPath(joints: link.joints), rate: RobotSafety.controlRate, label: "Demo"))
        for _ in 0..<10 { g.tick(dt: dt) }
        let wasMoving = g.moving && (link.state.velocities.map(abs).max() ?? 0) > 1
        g.stop(source: RobotSafety.StopSource.button.rawValue)
        let held = link.state.positions
        check("e-stop: torque off at once", wasMoving && !link.state.torqueOn && link.state.velocities.allSatisfy { $0 == 0 })
        g.tick(dt: dt)
        check("e-stop: no motion on the next tick", link.state.positions == held && !g.moving)
        check("e-stop latches: motion refused", g.submit(.jog(joint: 0, delta: 5)) == (.stopped))
        var asked = false
        let reason = g.request(.jog(joint: 0, delta: 5), target: "Jog", present: { _ in asked = true })
        check("e-stop latches: request locked, no sheet", reason != nil && !asked)
        for _ in 0..<25 { g.tick(dt: dt) }
        check("e-stop latches: still no motion", link.state.positions == held)

        // Re-enable flow: torque back, holding; motion needs a new confirmation.
        g.reenable()
        check("re-enable: torque on, holding the pose", link.state.torqueOn && link.state.targets == held && !g.stopped)
        check("re-enable: motion needs a new confirmation", g.submit(.jog(joint: 0, delta: 5)) == (.unconfirmed))
        sheet = nil
        g.request(.jog(joint: 0, delta: 5), target: "Jog", present: { sheet = $0 })
        sheet?.perform()
        check("re-enable: confirmed again, motion runs", g.moving && link.state.targets[0] == held[0] + 5)
        _ = g.escape(now: Date(timeIntervalSince1970: 0))
        _ = g.escape(now: Date(timeIntervalSince1970: 0.3))
        check("Esc twice cuts motion", g.stopped && !g.moving && !link.state.torqueOn)
        g.reenable()

        let ik = RobotSafety.poseTargets([10, 20], for: link)
        check("IK pose maps in joint order, the rest keep their target",
              ik.count == link.joints.count && ik[0] == 10 && ik[1] == 20 && Array(ik.dropFirst(2)) == Array(link.state.targets.dropFirst(2)))
        g.disconnect()
        check("disconnect: no robot, session cleared", !g.connected && !g.sessionConfirmed && g.linkState == nil)
        check("disconnect: motion refused", g.submit(.jog(joint: 0, delta: 5)) == (.noRobot))
        return out
    }
}

// MARK: - Stopped banner

/// After an e-stop: motors off, and re-enable needs a deliberate 1 s hold (`HoldButton`; its
/// VoiceOver action asks for a confirmation).
struct RobotStoppedBanner: View {
    @Environment(\.viaFormTheme) private var theme
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: VFSpace.l) {
                message
                Spacer(minLength: VFSpace.m)
                reenable
            }
            VStack(alignment: .leading, spacing: VFSpace.m) {
                message
                reenable
            }
        }
        .padding(VFSpace.l)
        .frame(maxWidth: 720)
        .background(RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous).fill(theme.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous)
            .strokeBorder(theme.danger.opacity(0.6), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }

    private var message: some View {
        HStack(alignment: .top, spacing: VFSpace.l) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(VFFont.glyph(20))
                .foregroundStyle(theme.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                Text("E-stop: motors off").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Text(String(localized: "\(safety.stopSentence) Motion verbs are blocked."))
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var reenable: some View {
        HoldButton(title: String(localized: "Re-enable Motors"), systemImage: "bolt.fill", duration: 1) {
            safety.reenable()
        }
    }
}

// MARK: - Motion frame

/// While a robot moves: a red frame around the canvas and a "Moving" label at its top
/// (FRONTEND-SPEC 7.9). Never takes hits.
struct MotionFrame: ViewModifier {
    @Environment(\.viaFormTheme) private var theme
    private var safety: RobotSafety { RobotSafety.shared }

    func body(content: Content) -> some View {
        content
            .overlay {
                if safety.moving {
                    RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous)
                        .strokeBorder(theme.dangerFill, lineWidth: 3)
                        .overlay(alignment: .top) {
                            Label("Moving", systemImage: "dot.radiowaves.left.and.right")
                                .font(VFFont.rowEmphasis)
                                .foregroundStyle(theme.onDanger)
                                .padding(.horizontal, VFSpace.l)
                                .padding(.vertical, VFSpace.xs)
                                .background(Capsule().fill(theme.dangerFill))
                                .offset(y: -VFSpace.m)
                                .accessibilityLabel(Text("Robot moving"))
                        }
                        .allowsHitTesting(false)
                        .vfTransition(.opacity)
                }
            }
            .vfAnimation(.easeOut(duration: VFMotion.fast), value: safety.moving)
    }
}

extension View {
    /// Red frame and "Moving" label while `RobotSafety.shared.moving`.
    func motionFrame() -> some View { modifier(MotionFrame()) }
}
