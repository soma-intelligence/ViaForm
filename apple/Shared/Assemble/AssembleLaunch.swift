import Foundation

/// Launch flags of the Assemble and Simulate stages, for screenshots and checks:
/// `--asm-tab=JOINTS|MOTION|CHECK|ASSEMBLY`, `--asm-tool=drag|grasp|rotate`, `--asm-joint=elbow`,
/// `--asm-q=elbow:80,wrist_pitch:-30`, `--ik-target=x,y,z` (mm), `--asm-check`,
/// `--asm-study=home_to_ready`, `--asm-scrub=1.2` (s). `--sim-run`, `--sim-demo` and
/// `--show-loads` are read by the Simulate stage itself (`ArmSimLaunch`).
enum AssembleLaunch {
    static func value(_ args: [String], _ flag: String) -> String? {
        args.first { $0.hasPrefix("--\(flag)=") }.map { String($0.dropFirst(flag.count + 3)) }
    }

    static func apply(_ args: [String], assemble: AssembleModel, sim: ArmSimModel, flow: FlowModel,
                      open: @escaping (Workspace) -> Void, showBottom: @escaping (Bool) -> Void) {
        guard assemble.isActive else { return }
        sim.flow = flow
        if let q = value(args, "asm-q") {
            var values: [String: Double] = [:]
            for pair in q.split(separator: ",") {
                let kv = pair.split(separator: ":")
                if kv.count == 2, let v = Double(kv[1]) { values[String(kv[0])] = v }
            }
            try? assemble.drive(values)
        }
        if let t = value(args, "asm-tab"), let tab = AssembleModel.Tab(rawValue: t.uppercased()) { assemble.tab = tab }
        if let j = value(args, "asm-joint") { assemble.selectedJoint = j }
        switch value(args, "asm-tool") {
        case "drag": assemble.tab = .motion; assemble.tool = .dragTip
        case "grasp": assemble.tab = .motion; assemble.tool = .grasp
        case "rotate": assemble.tool = .rotateJoint
        default: break
        }
        if let t = value(args, "ik-target") {
            let c = t.split(separator: ",").compactMap { Double($0) }
            if c.count == 3 {
                if assemble.tool != .dragTip { assemble.tab = .motion; assemble.tool = .dragTip }
                assemble.solveTo(target: SIMD3(c[0], c[1], c[2]), rpy: assemble.ik.rpy)
            }
        }
        if args.contains("--asm-check") {
            assemble.tab = .check
            assemble.checkInterference()
            let pairs = assemble.interference ?? []
            print("asm-check: \(pairs.count) pairs" + pairs.map { String(format: " %@/%@ %.0f mm3", $0.a, $0.b, $0.volumeMM3) }.joined())
        }
        if let s = value(args, "asm-study") {
            assemble.tab = .check
            assemble.studyID = s
            showBottom(true)
        }
        if let t = value(args, "asm-scrub").flatMap(Double.init) {
            showBottom(true)
            assemble.scrub(to: t)
        }
    }
}

/// `--sim-run`, `--sim-demo`, `--show-loads[=t]`: read by the Simulate stage when it appears.
enum ArmSimLaunch {
    static let args = ProcessInfo.processInfo.arguments
    static var run: Bool { args.contains("--sim-run") }
    static var demo: Bool { args.contains("--sim-demo") }
    static var loads: Double? {
        if let v = AssembleLaunch.value(args, "show-loads") { return Double(v) }
        return args.contains("--show-loads") ? -1 : nil
    }
    /// Consumed once per launch.
    nonisolated(unsafe) static var done = false
}
