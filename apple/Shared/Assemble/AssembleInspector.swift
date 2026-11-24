import simd
import SwiftUI

/// The Assemble stage's inspector sections (VIAFORM-SPEC 7.3, 7.10.4, 7.10.5): the joints and
/// the selected joint's editor, mass properties and poses; the IK target, solver and live joint
/// list while dragging the tip; the grasp's object, fingers and actuators in the grasp editor;
/// interference results on CHECK.
struct AssembleInspector: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: AssembleModel
    /// Opens Simulate with a hold scenario ("Test in simulation").
    var testInSimulation: (() -> Void)?

    var body: some View {
        let _ = units
        VStack(alignment: .leading, spacing: VFSpace.l) {
            switch model.tool {
            case .dragTip: ikSections
            case .grasp: graspSections
            default:
                if model.tab == .check { checkSections } else { jointSections }
            }
        }
    }

    // MARK: Joints

    @ViewBuilder private var jointSections: some View {
        AsmSection("Joints (\(model.joints.count))") {
            if model.joints.isEmpty {
                Text("This assembly has no joints yet.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            ForEach(Array(model.joints.enumerated()), id: \.element.id) { i, j in
                Button { model.selectedJoint = j.id } label: { jointRow(i, j, lockable: false) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, VFSpace.xs)
                    .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(model.selectedJoint == j.id ? theme.selection : .clear))
                    .accessibilityAddTraits(model.selectedJoint == j.id ? .isSelected : [])
            }
        }
        if let j = model.selected { JointEditor(model: model, joint: j) }
        massSection
        AsmSection("Poses") {
            if (model.doc?.poses ?? []).isEmpty {
                Text("No saved poses yet.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            ForEach(model.doc?.poses ?? []) { p in
                AsmRow(verbatim: AsmFormat.title(p.id), String(localized: "\(p.q_deg.count) joints")) { model.pose(named: p.id) }
                    .accessibilityHint(Text("Moves the joints to this pose"))
            }
            Button { model.savePose() } label: { Label("Save Pose", systemImage: "bookmark").frame(maxWidth: .infinity) }
                .buttonStyle(.vfSecondary)
                .help("Adds the current joint values as a named pose")
        }
    }

    private func jointRow(_ i: Int, _ j: AsmJoint, lockable: Bool) -> some View {
        let v = model.q[j.id] ?? 0
        let state = model.limitState(j)
        let tint = state == .at ? theme.danger : (state == .near ? theme.warning : theme.success)
        let locked = model.ik.locked.contains(j.id)
        return HStack(spacing: VFSpace.s) {
            if lockable {
                VFIconButton(locked ? "lock.fill" : "lock.open",
                             label: locked ? String(localized: "Unlock \(j.title)") : String(localized: "Freeze \(j.title) during the drag"),
                             size: 10, isOn: locked) {
                    if locked { model.ik.locked.remove(j.id) } else { model.ik.locked.insert(j.id) }
                }
            }
            Text("J\(i + 1)").font(VFFont.rowEmphasis).foregroundStyle(theme.ink).frame(width: 22, alignment: .leading)
            Text(AsmFormat.value(v, j, digits: 1)).font(VFFont.row).foregroundStyle(state == .free ? theme.ink : tint)
                .frame(width: 56, alignment: .trailing)
            // Near or at a limit: a mark, not only the colour.
            Image(systemName: state == .at ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(VFFont.glyph(9, weight: .semibold))
                .foregroundStyle(tint)
                .opacity(state == .free ? 0 : 1)
                .accessibilityHidden(true)
            LimitBar(value: v, range: j.range, tint: tint)
                .frame(height: VFSpace.s)
            if let r = j.range {
                Text("[\(Int(r.lowerBound)), \(Int(r.upperBound))]").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .frame(minHeight: VFSize.minTarget)
        .contentShape(Rectangle())
        .help(state == .free ? j.title : String(localized: "\(j.title): \(Self.limitWord(state))"))
        .accessibilityElement(children: lockable ? .contain : .ignore)
        .accessibilityLabel(Text("J\(i + 1) \(j.title)"))
        .accessibilityValue(Text(Self.spoken(v, j, state)))
    }

    static func limitWord(_ s: AssembleModel.LimitState) -> String {
        switch s {
        case .free: ""
        case .near: String(localized: "near its limit")
        case .at: String(localized: "at its limit")
        }
    }

    /// "42 degrees, near its limit": the value VoiceOver reads for a joint.
    static func spoken(_ v: Double, _ j: AsmJoint, _ s: AssembleModel.LimitState) -> String {
        let value = VFFormat.value(v, j.angular ? .angle : .length)
        return s == .free ? value : String(localized: "\(value), \(limitWord(s))")
    }

    @ViewBuilder private var massSection: some View {
        if let m = model.mass {
            AsmSection("Mass properties") {
                AsmRow("Total mass", VFFormat.mass(m.totalKg * 1000))
                AsmRow("Bought parts", VFFormat.mass(m.boughtKg * 1000))
                AsmRow("Centre of mass x", VFFormat.length(m.comMM.x))
                AsmRow("Centre of mass y", VFFormat.length(m.comMM.y))
                AsmRow("Centre of mass z", VFFormat.length(m.comMM.z))
                if m.inertia.count >= 3 {
                    AsmRow("Ixx, Iyy, Izz", VFFormat.inertia(Array(m.inertia.prefix(3))))
                        .help("Inertia about the centre of mass, \(VFFormat.inertiaSymbol())")
                }
                ForEach(m.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(VFFont.small).foregroundStyle(theme.warning)
                }
            }
        }
    }

    // MARK: Check

    @ViewBuilder private var checkSections: some View {
        AsmSection("Interference") {
            if let pairs = model.interference {
                if pairs.isEmpty {
                    Label("No interference at this pose", systemImage: "checkmark.circle").font(VFFont.row).foregroundStyle(theme.success)
                } else {
                    ForEach(pairs) { p in
                        AsmRow(verbatim: "\(title(p.a)) / \(title(p.b))", VFFormat.volume(p.volumeMM3), warn: true)
                    }
                }
            } else {
                Text("Not checked at this pose.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            Button { model.checkInterference() } label: { Label("Check Interference", systemImage: "square.on.square.intersection.dashed").frame(maxWidth: .infinity) }
                .buttonStyle(.vfSecondary)
        }
        if let p = model.studyProgress {
            AsmSection("Motion study") {
                StudyProgressRow(progress: p) { model.stopWork() }
            }
        } else if let s = model.study {
            AsmSection("Motion study") {
                AsmRow("Study", s.title)
                AsmRow("Steps", "\(s.steps.count)")
                if s.firstContacts.isEmpty {
                    Label("No collisions over the study", systemImage: "checkmark.circle").font(VFFont.small).foregroundStyle(theme.success)
                }
                ForEach(s.firstContacts, id: \.self) { c in
                    AsmRow(verbatim: "\(title(c.a)) / \(title(c.b))", String(localized: "first at \(VFFormat.value(c.time, .time))"), warn: true) { model.scrub(to: c.time) }
                        .accessibilityHint(Text("Moves the playhead to the first contact"))
                }
            }
        }
        massSection
    }

    private func title(_ id: String) -> String { model.components.first { $0.id == id }?.title ?? id }

    // MARK: IK

    @ViewBuilder private var ikSections: some View {
        AsmSection("IK target") {
            AsmNumberRow("X", model.ik.target.x, "mm") { v in var t = model.ik.target; t.x = v; model.solveTo(target: t, rpy: model.ik.rpy) }
            AsmNumberRow("Y", model.ik.target.y, "mm") { v in var t = model.ik.target; t.y = v; model.solveTo(target: t, rpy: model.ik.rpy) }
            AsmNumberRow("Z", model.ik.target.z, "mm") { v in var t = model.ik.target; t.z = v; model.solveTo(target: t, rpy: model.ik.rpy) }
            AsmNumberRow("Roll", model.ik.rpy.x, "deg", range: -180...180) { v in var r = model.ik.rpy; r.x = v; model.ik.keepOrientation = true; model.solveTo(target: model.ik.target, rpy: r) }
            AsmNumberRow("Pitch", model.ik.rpy.y, "deg", range: -180...180) { v in var r = model.ik.rpy; r.y = v; model.ik.keepOrientation = true; model.solveTo(target: model.ik.target, rpy: r) }
            AsmNumberRow("Yaw", model.ik.rpy.z, "deg", range: -180...180) { v in var r = model.ik.rpy; r.z = v; model.ik.keepOrientation = true; model.solveTo(target: model.ik.target, rpy: r) }
            if !model.ik.reached {
                Label(String(localized: "\(VFFormat.length(model.ik.shortBy)) out of reach"), systemImage: "exclamationmark.triangle.fill")
                    .font(VFFont.small).foregroundStyle(theme.warning)
            } else {
                Label("Tip on target", systemImage: "scope").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        }
        AsmSection("Solver") {
            HStack {
                Text("Solver").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                Spacer()
                Text(model.ik.solver == "Analytic" ? String(localized: "Analytic") : String(localized: "Numerical"))
                    .font(VFFont.small.weight(.medium)).foregroundStyle(theme.accentText)
                    .padding(.horizontal, VFSpace.m).frame(height: VFSize.chip)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                    .help(model.ik.solver == "Analytic" ? String(localized: "Closed form: a 6-axis arm with a spherical wrist")
                                                        : String(localized: "Damped least squares; the arm has \(model.dof) joints"))
            }
            .accessibilityElement(children: .combine)
        }
        AsmSection("Joints") {
            ForEach(Array(model.joints.enumerated()), id: \.element.id) { i, j in jointRow(i, j, lockable: true) }
        }
        Toggle("Keep orientation", isOn: $model.ik.keepOrientation).font(VFFont.row).toggleStyle(.switch).controlSize(.small)
        HStack {
            Text("Posture").font(VFFont.row).foregroundStyle(theme.inkSecondary)
            Spacer()
            Picker("Posture", selection: $model.ik.posture) {
                ForEach(AssembleModel.Posture.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().frame(width: 130)
        }
        Button { model.savePose() } label: { Text("Save Pose").frame(maxWidth: .infinity) }
            .buttonStyle(.vfPrimary)
            .help("Adds this pose to the assembly; Robot and paths use it")
        // The IK drag committed to the robot, through RobotSafety (UI-UX-AUDIT P0-14).
        RobotSendPoseButton { model.joints.map { model.q[$0.id] ?? 0 } }
    }

    // MARK: Grasp

    @ViewBuilder private var graspSections: some View {
        if model.product != .hand {
            AsmSection("Grasp") {
                Text("The arm's gripper has one joint. The grasp editor places fingertips of a hand: open the Robotic hand template.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            AsmSection("Grasp") {
                HStack {
                    Text("Object").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    Spacer()
                    Picker("Object", selection: Binding(get: { model.grasp.shape }, set: { model.grasp.shape = $0; model.setUpGrasp() })) {
                        Text("Cylinder").tag("cylinder"); Text("Box").tag("box"); Text("Sphere").tag("sphere")
                    }
                    .labelsHidden().frame(width: 110)
                }
                let box = model.grasp.shape == "box"
                AsmNumberRow(verbatim: box ? String(localized: "X") : String(localized: "Diameter"), model.grasp.size.x, "mm", range: 5...500) { v in
                    var s = model.grasp.size; s.x = v; model.setObjectSize(s)
                }
                if model.grasp.shape != "sphere" {
                    AsmNumberRow(verbatim: box ? String(localized: "Y") : String(localized: "Height"), model.grasp.size.y, "mm", range: 5...500) { v in
                        var s = model.grasp.size; s.y = v; model.setObjectSize(s)
                    }
                }
                if box {
                    AsmNumberRow("Z", model.grasp.size.z == 0 ? 40 : model.grasp.size.z, "mm", range: 5...500) { v in
                        var s = model.grasp.size; s.z = v; model.setObjectSize(s)
                    }
                }
            }
            AsmSection("Fingers") {
                ForEach(model.grasp.fingers) { f in fingerRow(f) }
            }
            AsmSection("Actuators") {
                ForEach(model.grasp.actuators, id: \.name) { a in
                    let name = AsmFormat.title(a.name)
                    AsmRow(verbatim: a.tendon ? String(localized: "\(name) (tendon)") : name,
                           a.tendon ? VFFormat.length(a.value) : VFFormat.angle(a.value))
                }
            }
            HStack(spacing: VFSpace.s) {
                Button { model.saveGrasp() } label: { Text("Save Grasp").frame(maxWidth: .infinity) }
                    .buttonStyle(.vfPrimary)
                    .help("Stores the object, fingertip targets, joints and actuators")
                Button { testInSimulation?() } label: { Text("Test in Simulation").frame(maxWidth: .infinity) }
                    .buttonStyle(.vfSecondary)
                    .vfDisabled(!PhysAvailability.available || testInSimulation == nil,
                                reason: PhysAvailability.available ? String(localized: "Simulate is not open for this product")
                                                                   : String(localized: "Needs the physics engine"))
                    .help(PhysAvailability.available ? "Opens Simulate with a hold scenario" : "Needs the physics engine")
            }
            if let id = model.grasp.savedID {
                Text("Saved as \(id) in \(model.committed ?? String(localized: "the assembly")).").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        }
    }

    private func fingerRow(_ f: AssembleModel.GraspFinger) -> some View {
        HStack(alignment: .center, spacing: VFSpace.s) {
            Menu {
                ForEach(1...5, id: \.self) { p in Button("Priority \(p)") { model.setPriority(f.frame, p) } }
            } label: {
                Text("\(f.priority)").font(VFFont.micro.weight(.bold)).foregroundStyle(theme.onAccent)
                    .frame(width: 18, height: 18).background(Circle().fill(Color(platform: AssembleScene.fingerColour(f.priority))))
                    .frame(minWidth: VFSize.minTarget, minHeight: VFSize.minTarget)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Priority: 1 is solved first")
            .accessibilityLabel(Text("Priority of \(f.title)"))
            .accessibilityValue(Text("\(f.priority)"))
            Text(f.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).frame(width: 52, alignment: .leading)
            HStack(spacing: VFSpace.xs) {
                VFStatusDot(status: f.reached ? .current : .stale,
                            reason: f.reached ? String(localized: "Reached") : String(localized: "\(VFFormat.length(f.distanceMM)) short"))
                Text(f.reached ? String(localized: "Reached") : VFFormat.length(f.distanceMM)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            .frame(width: 76, alignment: .leading)
            Spacer(minLength: 0)
            Text(f.drive == "Tendon" ? String(localized: "Tendon") : String(localized: "Motor")).font(VFFont.micro.weight(.semibold))
                .foregroundStyle(f.drive == "Tendon" ? theme.accentText : theme.stageLabel(.assemble))
                .padding(.horizontal, VFSpace.s).frame(height: 16)
                .background(Capsule().fill(f.drive == "Tendon" ? theme.accent.opacity(0.14) : theme.stageFill(.assemble)))
                .fixedSize()
        }
        .frame(minHeight: VFSize.minTarget)
        .help(f.joints.isEmpty ? f.title : String(localized: "\(f.title): \(f.joints.map { VFFormat.angle($0) }.joined(separator: ", "))"))
        .accessibilityElement(children: .contain)
    }
}

/// Sampling a motion study: progress and Stop (Command-. does the same; Esc does not).
struct StudyProgressRow: View {
    @Environment(\.viaFormTheme) private var theme
    let progress: Double
    let stop: () -> Void

    var body: some View {
        HStack(spacing: VFSpace.s) {
            ProgressView(value: progress)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("Sampling the motion study"))
                .accessibilityValue(Text("\(Int((progress * 100).rounded())) percent"))
            Text("\(Int((progress * 100).rounded())) %").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                .frame(minWidth: 36, alignment: .trailing)
            Button("Stop", action: stop)
                .buttonStyle(.vfSecondary)
                .help("Stop sampling (Command-.)")
        }
    }
}

/// The editor of one joint: type, the parts it joins, axis, limits, motor, damping, friction,
/// and a drive slider. Edits are undo steps in the assembly and recommit it to the flow.
struct JointEditor: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: AssembleModel
    let joint: AsmJoint

    private var unit: VFUnit { joint.angular ? .angle : .length }

    var body: some View {
        let _ = units
        AsmSection("Joint: \(joint.title)") {
            AsmRow("Type", Self.kindTitle(joint.kind))
            AsmRow("Joins", String(localized: "\(name(joint.parent)) to \(name(joint.child))"))
            AsmRow("Axis", joint.axis.map { VFFormat.value($0, .none) }.joined(separator: ", "))
            let value = Binding(get: { model.q[joint.id] ?? 0 }, set: { model.setJoint(joint.id, value: $0) })
            HStack {
                Text("Value").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                Spacer(minLength: VFSpace.m)
                NumberField(String(localized: "\(joint.title) value"), value: value, unit: unit, range: joint.range, step: 1, width: 84)
                    .labelHiddenVisually()
            }
            if let r = joint.range {
                Slider(value: value, in: r)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Drive \(joint.title)"))
                    .accessibilityValue(Text(AssembleInspector.spoken(model.q[joint.id] ?? 0, joint, model.limitState(joint))))
            }
            AsmNumberRow("Lower limit", joint.range?.lowerBound ?? 0, joint.unit) { v in setLimit(lower: v) }
            AsmNumberRow("Upper limit", joint.range?.upperBound ?? 0, joint.unit) { v in setLimit(upper: v) }
            if let l = joint.limits {
                if let v = l.velocity_dps { AsmRow("Velocity", VFFormat.rate(v, .angle)) }
                if let e = l.effort_nm { AsmRow("Effort", VFFormat.value(e, .custom("N·m"))) }
            }
        }
        if let m = joint.motor {
            AsmSection("Motor") {
                AsmRow("Model", m.part.split(separator: "/").last.map(String.init) ?? m.part)
                if let t = m.stall_torque_nm { AsmRow("Torque", VFFormat.value(t / 0.0980665, .custom("kg·cm"))) }
                if let v = m.voltage_v { AsmRow("Voltage", VFFormat.value(v, .custom("V"))) }
                AsmNumberRow("Gear ratio", m.gear_ratio ?? 1, ":1", range: 0.01...10_000, step: 0.1) { v in model.editJoint(joint.id, ["motor": motor(m, ["gear_ratio": v])]) }
                AsmNumberRow("Backlash", m.backlash_deg ?? 0, "deg", range: 0...45, step: 0.1) { v in model.editJoint(joint.id, ["motor": motor(m, ["backlash_deg": v])]) }
                if let b = m.bus_id { AsmRow("Bus ID", "\(b)") }
            }
        }
        AsmSection("Dynamics") {
            AsmNumberRow("Damping", joint.damping ?? 0, "N·m·s", range: 0...1_000, step: 0.01) { v in model.editJoint(joint.id, ["damping": v]) }
            AsmNumberRow("Friction", joint.friction ?? 0, "N·m", range: 0...1_000, step: 0.01) { v in model.editJoint(joint.id, ["friction": v]) }
        }
    }

    static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "revolute": String(localized: "Revolute")
        case "prismatic": String(localized: "Prismatic")
        case "fixed": String(localized: "Fixed")
        case "continuous": String(localized: "Continuous")
        default: kind.capitalized
        }
    }

    private func name(_ id: String) -> String { model.components.first { $0.id == id }?.title ?? id }

    private func setLimit(lower: Double? = nil, upper: Double? = nil) {
        guard var l = joint.limits.flatMap({ try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as? [String: Any] }) else { return }
        let key = joint.angular ? "deg" : "mm"
        if let lower { l["lower_" + key] = lower }
        if let upper { l["upper_" + key] = upper }
        model.editJoint(joint.id, ["limits": l])
    }

    private func motor(_ m: AsmMotor, _ patch: [String: Any]) -> [String: Any] {
        var d = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any]) ?? [:]
        for (k, v) in patch { d[k] = v }
        if let full = model.doc?.joints.first(where: { $0.id == joint.id }), full.motor != nil {
            // Keep fields the screen does not show (kp, bom line): the engine merges the object whole.
            if let raw = (try? model.engine.call("joints"))?["joints"] as? [[String: Any]],
               let row = raw.first(where: { ($0["id"] as? String) == joint.id }), let mm = row["motor"] as? [String: Any] {
                var merged = mm
                for (k, v) in d { merged[k] = v }
                return merged
            }
        }
        return d
    }
}

/// A capped bar of a value inside its limits (the row says the value and the limit state).
struct LimitBar: View {
    @Environment(\.viaFormTheme) private var theme
    let value: Double
    let range: ClosedRange<Double>?
    let tint: Color

    var body: some View {
        GeometryReader { g in
            let f: Double = range.map { r in (value - r.lowerBound) / max(r.upperBound - r.lowerBound, 1e-6) } ?? 0.5
            ZStack(alignment: .leading) {
                Capsule().fill(theme.well)
                Capsule().fill(tint).frame(width: max(VFSpace.xs, g.size.width * CGFloat(min(max(f, 0), 1))))
                if let r = range, r.lowerBound < 0, r.upperBound > 0 {
                    Rectangle().fill(theme.inkTertiary).frame(width: VFSize.hairline)
                        .offset(x: g.size.width * CGFloat(-r.lowerBound / (r.upperBound - r.lowerBound)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Small pieces shared by the Assemble and Simulate inspectors

struct AsmSection<C: View>: View {
    let title: String
    let content: C

    init(_ title: LocalizedStringResource, @ViewBuilder _ content: () -> C) {
        self.init(verbatim: String(localized: title), content)
    }

    init(verbatim title: String, @ViewBuilder _ content: () -> C) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            VFCaption(title)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A key and its value. With `warn`, the value is in the warning colour with a warning mark (never
/// the colour alone); with an action, the row is a button with a chevron.
struct AsmRow: View {
    @Environment(\.viaFormTheme) private var theme
    let key: String
    let value: String
    var warn = false
    var action: (() -> Void)?

    init(_ key: LocalizedStringResource, _ value: String, warn: Bool = false, action: (() -> Void)? = nil) {
        self.init(verbatim: String(localized: key), value, warn: warn, action: action)
    }

    init(verbatim key: String, _ value: String, warn: Bool = false, action: (() -> Void)? = nil) {
        self.key = key
        self.value = value
        self.warn = warn
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(theme.inkSecondary).lineLimit(2)
            Spacer(minLength: VFSpace.m)
            if let action {
                Button(action: action) {
                    HStack(spacing: VFSpace.xs) {
                        valueText
                        Image(systemName: "chevron.right").font(VFFont.glyph(8, weight: .bold)).accessibilityHidden(true)
                    }
                    .foregroundStyle(warn ? theme.warning : theme.accentText)
                    .frame(minHeight: VFSize.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                valueText.foregroundStyle(warn ? theme.warning : theme.ink)
            }
        }
        .font(VFFont.row)
        .frame(minHeight: VFSize.chip)
        .help(value)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var valueText: some View {
        HStack(spacing: VFSpace.xs) {
            if warn {
                Image(systemName: "exclamationmark.triangle.fill").font(VFFont.glyph(10, weight: .semibold))
                    .accessibilityLabel(Text("Warning"))
            }
            Text(value).lineLimit(1).monospacedDigit()
        }
    }
}

/// A labelled number with its unit (NumberField: expressions, units, arrows, scrub on the Mac,
/// error beside the field). `commit` runs once per committed change.
struct AsmNumberRow: View {
    @Environment(\.viaFormTheme) private var theme
    let key: String
    let value: Double
    let unit: String
    var range: ClosedRange<Double>?
    var step: Double
    let commit: (Double) -> Void
    @State private var draft = 0.0

    init(_ key: LocalizedStringResource, _ value: Double, _ unit: String, range: ClosedRange<Double>? = nil, step: Double = 1,
         commit: @escaping (Double) -> Void) {
        self.init(verbatim: String(localized: key), value, unit, range: range, step: step, commit: commit)
    }

    init(verbatim key: String, _ value: Double, _ unit: String, range: ClosedRange<Double>? = nil, step: Double = 1,
         commit: @escaping (Double) -> Void) {
        self.key = key
        self.value = value
        self.unit = unit
        self.range = range
        self.step = step
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        HStack {
            Text(key).font(VFFont.row).foregroundStyle(theme.inkSecondary).lineLimit(1)
            Spacer(minLength: VFSpace.m)
            NumberField(key, value: $draft, unit: VFUnit(symbol: unit), range: range, step: step, width: 84) {
                if draft != value { commit(draft) }
            }
            .labelHiddenVisually()
        }
        .frame(minHeight: VFSize.chip)
        .onChange(of: value) { _, v in draft = v }
    }
}

/// Whether the physics engine is linked (viaform_phys.h declares vf_phys_*). Switched on by the
/// Simulate stage's physics service once the C ABI exists.
enum PhysAvailability {
    static var available: Bool { PhysService.shared.available }
}
