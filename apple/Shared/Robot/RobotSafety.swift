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

    /// A robot is connected over the bus adapter or the bridge. Set by the link (task P7-2).
    var connected = false
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

    /// Latches the stop: motion ends, torque goes off, the session needs a new confirmation.
    func stop(source: String) {
        stopped = true
        moving = false
        sessionConfirmed = false
        self.source = source
        at = Date()
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
    func endMotion() { moving = false }
}

// MARK: - Self checks

/// `--robot-selftest`: one line per check, exit code 1 on any failure. The app has no unit test
/// target for model code; this follows `FlowSelfTest`.
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

        s.connected = true
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

        print(failures == 0 ? "robot selftest: all passed" : "robot selftest: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
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
