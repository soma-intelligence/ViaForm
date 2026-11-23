import Foundation

// The link between the app and a robot (VIAFORM-SPEC 6.4, robot-protocol, task P7-2). Every
// motion goes through `RobotSafety`, which is the only caller of `command`, `hold` and
// `torqueOff`. A real link (servo bus adapter, ViaForm bridge) implements the same protocol;
// until the hardware exists `SimulatedRobotLink` plays the commands back as a servo model so the
// safety gate can be tried and tested.

/// One joint of the connected robot, in the app's units (degrees).
struct RobotJointSpec: Equatable, Sendable {
    var id: String
    var name: String
    /// The workspace fence for this joint (the Assemble joint limits).
    var range: ClosedRange<Double>
    /// Rated speed, degrees per second (100 % speed cap).
    var ratedSpeed: Double
    /// Rated acceleration at stall torque, degrees per second squared (100 % torque).
    var ratedAccel: Double
}

/// What the safety gate allows on this command: fractions of rated speed and stall torque.
/// Read from `RobotSafety`, never from literals.
struct RobotCommandLimits: Equatable, Sendable {
    var speed: Double
    var torque: Double
}

/// What the robot reports each control tick.
struct RobotState: Equatable, Sendable {
    /// Measured joint positions, degrees.
    var positions: [Double]
    /// Measured joint velocities, degrees per second.
    var velocities: [Double]
    /// Joint effort, percent of stall torque.
    var efforts: [Double]
    /// The targets last commanded (the twin's ghost pose).
    var targets: [Double]
    /// Torque is on (false after an e-stop until re-enable).
    var torqueOn: Bool
    /// Control ticks since connect.
    var tick: Int

    static func resting(_ joints: [RobotJointSpec]) -> RobotState {
        let home = joints.map { min(max(0, $0.range.lowerBound), $0.range.upperBound) }
        let zero = Array(repeating: 0.0, count: joints.count)
        return RobotState(positions: home, velocities: zero, efforts: zero, targets: home, torqueOn: true, tick: 0)
    }
}

/// The kinds of link a user can pick in the Robot stage.
enum RobotLinkKind: String, CaseIterable, Identifiable, Sendable {
    case simulated, usb, bridge
    var id: String { rawValue }

    var title: String {
        switch self {
        case .simulated: String(localized: "Simulated robot")
        case .usb: String(localized: "USB bus adapter")
        case .bridge: String(localized: "ViaForm bridge")
        }
    }

    /// Why the kind cannot be picked yet, or nil when it can.
    var unavailableReason: String? {
        switch self {
        case .simulated: nil
        case .usb, .bridge: String(localized: "Comes with the hardware link")
        }
    }
}

/// A connection to a robot. The safety gate drives it one control tick at a time.
@MainActor
protocol RobotLink: AnyObject {
    var kind: RobotLinkKind { get }
    var joints: [RobotJointSpec] { get }
    var state: RobotState { get }
    /// The limits sent with the last command (the gate's caps as the robot received them).
    var lastLimits: RobotCommandLimits? { get }

    /// Sets the joint targets with the gate's caps. Does nothing while torque is off.
    func command(targets: [Double], limits: RobotCommandLimits)
    /// Holds the measured pose (targets become positions), torque stays on.
    func hold()
    /// E-stop: torque off on every motor at once. Motion ends now, not on the next tick.
    func torqueOff()
    /// After the deliberate re-enable: torque on, holding the measured pose.
    func torqueOn()
    /// One control cycle of `dt` seconds: send the command, read the state.
    func tick(dt: Double)
}

/// A loopback robot: a first-order position servo per joint with a velocity cap (the speed cap)
/// and an acceleration cap (the torque limit). Honours `torqueOff` at once: velocity drops to
/// zero and the joints stay where they are.
@MainActor
final class SimulatedRobotLink: RobotLink {
    let kind: RobotLinkKind = .simulated
    let joints: [RobotJointSpec]
    private(set) var state: RobotState
    private(set) var lastLimits: RobotCommandLimits?
    /// Servo time constant, seconds.
    var timeConstant: Double = 0.12

    /// A six joint desktop arm (base, shoulder, elbow, wrist pitch, wrist roll, gripper), the
    /// shape of the starter arm until a device profile (`robot/device.json`) gives the joint map.
    static let defaultArm: [RobotJointSpec] = [
        RobotJointSpec(id: "base", name: String(localized: "Base"), range: -150...150, ratedSpeed: 180, ratedAccel: 900),
        RobotJointSpec(id: "shoulder", name: String(localized: "Shoulder"), range: -100...100, ratedSpeed: 180, ratedAccel: 900),
        RobotJointSpec(id: "elbow", name: String(localized: "Elbow"), range: -110...110, ratedSpeed: 180, ratedAccel: 900),
        RobotJointSpec(id: "wrist_pitch", name: String(localized: "Wrist pitch"), range: -100...100, ratedSpeed: 240, ratedAccel: 1200),
        RobotJointSpec(id: "wrist_roll", name: String(localized: "Wrist roll"), range: -150...150, ratedSpeed: 240, ratedAccel: 1200),
        RobotJointSpec(id: "gripper", name: String(localized: "Gripper"), range: 0...90, ratedSpeed: 240, ratedAccel: 1200),
    ]

    init(joints: [RobotJointSpec] = SimulatedRobotLink.defaultArm) {
        self.joints = joints
        state = .resting(joints)
    }

    func command(targets: [Double], limits: RobotCommandLimits) {
        guard state.torqueOn, targets.count == joints.count else { return }
        lastLimits = limits
        state.targets = targets
    }

    func hold() {
        state.targets = state.positions
    }

    func torqueOff() {
        state.torqueOn = false
        state.targets = state.positions
        state.velocities = Array(repeating: 0, count: joints.count)
        state.efforts = Array(repeating: 0, count: joints.count)
    }

    func torqueOn() {
        state.torqueOn = true
        state.targets = state.positions
    }

    func tick(dt: Double) {
        guard dt > 0 else { return }
        state.tick += 1
        guard state.torqueOn else { return }
        let limits = lastLimits ?? RobotCommandLimits(speed: 0, torque: 0)
        for i in joints.indices {
            let j = joints[i]
            let vMax = j.ratedSpeed * limits.speed
            let aMax = j.ratedAccel * limits.torque
            let error = state.targets[i] - state.positions[i]
            let want = min(max(error / timeConstant, -vMax), vMax)
            let v0 = state.velocities[i]
            let accel = min(max((want - v0) / dt, -aMax), aMax)
            var v = v0 + accel * dt
            v = min(max(v, -vMax), vMax)
            // Never step past the target in one tick.
            if abs(v * dt) > abs(error) { v = error / dt }
            state.positions[i] += v * dt
            state.velocities[i] = v
            state.efforts[i] = j.ratedAccel > 0 ? abs(accel) / j.ratedAccel * 100 : 0
        }
    }
}
