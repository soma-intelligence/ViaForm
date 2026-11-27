import XCTest
@testable import ViaForm

/// The robot safety gate (UI-UX-AUDIT P0-14, VIAFORM-SPEC R-8) through the simulated link.
@MainActor
final class RobotGateTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let dt = 1 / RobotSafety.controlRate

    override func setUp() async throws {
        suite = "viaform-robot-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func connected() -> (RobotSafety, SimulatedRobotLink) {
        let g = RobotSafety(defaults: defaults)
        let link = SimulatedRobotLink()
        g.connect(link, autoTick: false)
        return (g, link)
    }

    private func confirm(_ g: RobotSafety, _ m: RobotSafety.Motion) {
        var sheet: ConfirmRequest?
        XCTAssertNil(g.request(m, target: "Test", present: { sheet = $0 }))
        XCTAssertNotNil(sheet)
        sheet?.perform()
    }

    func testNoMotionWithoutConfirmation() {
        let (g, link) = connected()
        let rest = link.state.positions
        XCTAssertEqual(g.submit(.jog(joint: 1, delta: 10)), .unconfirmed)
        XCTAssertEqual(g.submit(.pose(rest.map { $0 + 5 }, label: "p")), .unconfirmed)
        var sheet: ConfirmRequest?
        g.request(.jog(joint: 1, delta: 10), target: "Jog", present: { sheet = $0 })
        XCTAssertNotNil(sheet)
        for _ in 0..<50 { g.tick(dt: dt) }
        XCTAssertEqual(link.state.positions, rest)
        XCTAssertFalse(g.moving)
        sheet?.perform()
        XCTAssertTrue(g.moving)
        XCTAssertEqual(link.state.targets[1], rest[1] + 10)
    }

    func testNoRobotRefuses() {
        let g = RobotSafety(defaults: defaults)
        XCTAssertEqual(g.submit(.jog(joint: 0, delta: 1)), .noRobot)
        var asked = false
        XCTAssertNotNil(g.request(.jog(joint: 0, delta: 1), target: "Jog", present: { _ in asked = true }))
        XCTAssertFalse(asked)
    }

    func testEStopLatchesAndCutsWithinOneTick() {
        let (g, link) = connected()
        g.speedCap = 100
        g.torqueLimit = 100
        confirm(g, .trajectory(RobotSafety.syntheticPath(joints: link.joints), rate: RobotSafety.controlRate, label: "Demo"))
        for _ in 0..<10 { g.tick(dt: dt) }
        XCTAssertTrue(g.moving)
        g.stop(source: RobotSafety.StopSource.space.rawValue)
        XCTAssertFalse(link.state.torqueOn)
        XCTAssertTrue(link.state.velocities.allSatisfy { $0 == 0 })
        let held = link.state.positions
        g.tick(dt: dt)
        XCTAssertEqual(link.state.positions, held)
        XCTAssertFalse(g.moving)
        XCTAssertEqual(g.submit(.jog(joint: 0, delta: 5)), .stopped)
        XCTAssertNotNil(g.request(.jog(joint: 0, delta: 5), target: "Jog", present: { _ in XCTFail("no sheet while latched") }))
        for _ in 0..<50 { g.tick(dt: dt) }
        XCTAssertEqual(link.state.positions, held)
        XCTAssertTrue(g.stopped)
    }

    func testEscTwiceStopsMotion() {
        let (g, link) = connected()
        confirm(g, .jog(joint: 0, delta: 30))
        g.tick(dt: dt)
        let t0 = Date()
        XCTAssertFalse(g.escape(now: t0))
        XCTAssertTrue(g.escape(now: t0.addingTimeInterval(0.3)))
        XCTAssertTrue(g.stopped)
        XCTAssertFalse(link.state.torqueOn)
    }

    func testCapsClampFromSettings() {
        let (g, link) = connected()
        g.speedCap = 20
        g.torqueLimit = 30
        confirm(g, .pose(link.joints.map { $0.range.upperBound }, label: "Far"))
        XCTAssertEqual(link.lastLimits, RobotCommandLimits(speed: 0.20, torque: 0.30))
        var peakSpeed = 0.0, peakEffort = 0.0
        for _ in 0..<100 {
            g.tick(dt: dt)
            for (i, j) in link.joints.enumerated() {
                peakSpeed = max(peakSpeed, abs(link.state.velocities[i]) / j.ratedSpeed)
            }
            peakEffort = max(peakEffort, link.state.efforts.max() ?? 0)
        }
        XCTAssertLessThanOrEqual(peakSpeed, 0.20 + 1e-9)
        XCTAssertGreaterThan(peakSpeed, 0.1)
        XCTAssertLessThanOrEqual(peakEffort, 30 + 1e-9)
        g.speedCap = 500
        XCTAssertEqual(g.commandLimits.speed, 1.0)
    }

    func testFenceClampsTargets() {
        let (g, link) = connected()
        confirm(g, .pose(link.joints.map { $0.range.upperBound + 400 }, label: "Out"))
        XCTAssertEqual(link.state.targets, link.joints.map { $0.range.upperBound })
        XCTAssertEqual(g.submit(.pose([1], label: "Short")), .badRequest)
    }

    func testReenableNeedsNewConfirmation() {
        let (g, link) = connected()
        confirm(g, .jog(joint: 2, delta: 10))
        g.stop(source: RobotSafety.StopSource.button.rawValue)
        XCTAssertFalse(g.sessionConfirmed)
        g.reenable()
        XCTAssertFalse(g.stopped)
        XCTAssertTrue(link.state.torqueOn)
        XCTAssertEqual(link.state.targets, link.state.positions)
        XCTAssertEqual(g.submit(.jog(joint: 2, delta: 10)), .unconfirmed)
        confirm(g, .jog(joint: 2, delta: 10))
        XCTAssertTrue(g.moving)
    }

    func testMotionEndsAndFrameClears() {
        let (g, _) = connected()
        confirm(g, .jog(joint: 3, delta: 5))
        XCTAssertTrue(g.moving)
        XCTAssertEqual(g.motionStarts, 1)
        for _ in 0..<200 where g.moving { g.tick(dt: dt) }
        XCTAssertFalse(g.moving)
        XCTAssertNil(g.activity)
    }

    func testSelfTestChecksAllPass() {
        let failed = RobotGateChecks.run(defaults: defaults).filter { !$0.1 }.map(\.0)
        XCTAssertEqual(failed, [])
    }
}
