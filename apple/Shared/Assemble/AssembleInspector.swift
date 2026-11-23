import simd
import SwiftUI

/// The Assemble stage's inspector sections (VIAFORM-SPEC 7.3, 7.10.4, 7.10.5): the joints and
/// the selected joint's editor, mass properties and poses; the IK target, solver and live joint
/// list while dragging the tip; the grasp's object, fingers and actuators in the grasp editor;
/// interference results on CHECK.
struct AssembleInspector: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: AssembleModel
    /// Opens Simulate with a hold scenario ("Test in simulation").
    var testInSimulation: (() -> Void)?

    var body: some View {
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
            ForEach(Array(model.joints.enumerated()), id: \.element.id) { i, j in
                Button { model.selectedJoint = j.id } label: { jointRow(i, j, lockable: false) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, VFSpace.xs)
                    .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(model.selectedJoint == j.id ? theme.selection : .clear))
            }
        }
        if let j = model.selected { JointEditor(model: model, joint: j) }
        massSection
        AsmSection("Poses") {
            ForEach(model.doc?.poses ?? []) { p in
                AsmRow(p.id.replacingOccurrences(of: "_", with: " ").capitalized, "\(p.q_deg.count) joints") { model.pose(named: p.id) }
            }
            Button { model.savePose() } label: { Label("Save Pose", systemImage: "bookmark").frame(maxWidth: .infinity) }
                .help("Adds the current joint values as a named pose (asm.save_pose)")
        }
    }

    private func jointRow(_ i: Int, _ j: AsmJoint, lockable: Bool) -> some View {
        let v = model.q[j.id] ?? 0
        let state = model.limitState(j)
        let tint = state == .at ? theme.danger : (state == .near ? theme.warning : theme.success)
        return HStack(spacing: VFSpace.s) {
            if lockable {
                Button {
                    if model.ik.locked.contains(j.id) { model.ik.locked.remove(j.id) } else { model.ik.locked.insert(j.id) }
                } label: {
                    Image(systemName: model.ik.locked.contains(j.id) ? "lock.fill" : "lock.open")
                        .font(.system(size: 10)).frame(width: 14)
                        .foregroundStyle(model.ik.locked.contains(j.id) ? theme.ink : theme.inkTertiary)
                }
                .buttonStyle(.plain)
                .help(model.ik.locked.contains(j.id) ? "Unlock \(j.title)" : "Freeze \(j.title) during the drag")
            }
            Text("J\(i + 1)").font(VFFont.rowEmphasis).foregroundStyle(theme.ink).frame(width: 22, alignment: .leading)
            Text(AsmFormat.deg(v, digits: 1)).font(VFFont.row).foregroundStyle(state == .free ? theme.ink : tint)
                .frame(width: 52, alignment: .trailing)
            LimitBar(value: v, range: j.range, tint: tint)
                .frame(height: 6)
            if let r = j.range {
                Text("[\(Int(r.lowerBound)), \(Int(r.upperBound))]").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .help(j.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(j.title), \(Int(v)) degrees" + (state == .at ? ", at its limit" : state == .near ? ", near its limit" : ""))
    }

    @ViewBuilder private var massSection: some View {
        if let m = model.mass {
            AsmSection("Mass properties") {
                AsmRow("Total mass", m.totalKg < 1 ? String(format: "%.0f g", m.totalKg * 1000) : String(format: "%.2f kg", m.totalKg))
                AsmRow("Bought parts", String(format: "%.0f g", m.boughtKg * 1000))
                AsmRow("Centre of mass", "")
                AsmRow("    x", String(format: "%.1f mm", m.comMM.x))
                AsmRow("    y", String(format: "%.1f mm", m.comMM.y))
                AsmRow("    z", String(format: "%.1f mm", m.comMM.z))
                if m.inertia.count >= 3 {
                    AsmRow("Ixx, Iyy, Izz", String(format: "%.0f, %.0f, %.0f", m.inertia[0], m.inertia[1], m.inertia[2]))
                        .help("Inertia about the centre of mass, kg·mm²")
                }
                ForEach(m.warnings, id: \.self) { w in Text(w).font(VFFont.small).foregroundStyle(theme.warning) }
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
                        AsmRow("\(title(p.a)) / \(title(p.b))", String(format: "%.0f mm³", p.volumeMM3), warn: true)
                    }
                }
            } else {
                Text("Not checked at this pose.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            Button { model.checkInterference() } label: { Label("Check Interference", systemImage: "square.on.square.intersection.dashed").frame(maxWidth: .infinity) }
        }
        if let s = model.study {
            AsmSection("Motion study") {
                AsmRow("Study", s.title)
                AsmRow("Steps", "\(s.steps.count)")
                if s.firstContacts.isEmpty {
                    Label("No collisions over the study", systemImage: "checkmark.circle").font(VFFont.small).foregroundStyle(theme.success)
                }
                ForEach(s.firstContacts, id: \.a) { c in
                    AsmRow("\(title(c.a)) / \(title(c.b))", String(format: "first at %.2f s", c.time), warn: true) { model.scrub(to: c.time) }
                }
            }
        }
        massSection
    }

    private func title(_ id: String) -> String { model.components.first { $0.id == id }?.title ?? id }

    // MARK: IK

    @ViewBuilder private var ikSections: some View {
        AsmSection("IK target") {
            AsmNumberRow("x", model.ik.target.x, "mm") { v in var t = model.ik.target; t.x = v; model.solveTo(target: t, rpy: model.ik.rpy) }
            AsmNumberRow("y", model.ik.target.y, "mm") { v in var t = model.ik.target; t.y = v; model.solveTo(target: t, rpy: model.ik.rpy) }
            AsmNumberRow("z", model.ik.target.z, "mm") { v in var t = model.ik.target; t.z = v; model.solveTo(target: t, rpy: model.ik.rpy) }
            AsmNumberRow("roll", model.ik.rpy.x, "deg") { v in var r = model.ik.rpy; r.x = v; model.ik.keepOrientation = true; model.solveTo(target: model.ik.target, rpy: r) }
            AsmNumberRow("pitch", model.ik.rpy.y, "deg") { v in var r = model.ik.rpy; r.y = v; model.ik.keepOrientation = true; model.solveTo(target: model.ik.target, rpy: r) }
            AsmNumberRow("yaw", model.ik.rpy.z, "deg") { v in var r = model.ik.rpy; r.z = v; model.ik.keepOrientation = true; model.solveTo(target: model.ik.target, rpy: r) }
            if !model.ik.reached {
                Label(String(format: "%.0f mm out of reach", model.ik.shortBy), systemImage: "exclamationmark.triangle")
                    .font(VFFont.small).foregroundStyle(theme.warning)
            }
        }
        AsmSection("Solver") {
            HStack {
                Text("Solver").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                Spacer()
                Text(model.ik.solver).font(VFFont.small.weight(.medium)).foregroundStyle(theme.accentText)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                    .help(model.ik.solver == "Analytic" ? "Closed form: a 6-axis arm with a spherical wrist" : "Damped least squares; the arm has \(model.dof) joints")
            }
        }
        AsmSection("Joints") {
            ForEach(Array(model.joints.enumerated()), id: \.element.id) { i, j in jointRow(i, j, lockable: true) }
        }
        Toggle("Keep orientation", isOn: $model.ik.keepOrientation).font(VFFont.row).toggleStyle(.switch).controlSize(.small)
        HStack {
            Text("Posture").font(VFFont.row).foregroundStyle(theme.inkSecondary)
            Spacer()
            Picker("Posture", selection: $model.ik.posture) {
                ForEach(AssembleModel.Posture.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 130)
        }
        Button { model.savePose() } label: { Text("Save Pose").frame(maxWidth: .infinity) }
            .buttonStyle(.vfPrimary)
            .help("Adds this pose to the assembly (asm.save_pose); Robot and paths use it")
    }

    // MARK: Grasp

    @ViewBuilder private var graspSections: some View {
        if model.product != .hand {
            AsmSection("Grasp") {
                Text("The arm's gripper has one joint. The grasp editor places fingertips of a hand: open the Robotic hand template.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
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
                AsmNumberRow(model.grasp.shape == "box" ? "x" : "Diameter", model.grasp.size.x, "mm") { v in var s = model.grasp.size; s.x = max(5, v); model.setObjectSize(s) }
                if model.grasp.shape != "sphere" {
                    AsmNumberRow(model.grasp.shape == "box" ? "y" : "Height", model.grasp.size.y, "mm") { v in var s = model.grasp.size; s.y = max(5, v); model.setObjectSize(s) }
                }
                if model.grasp.shape == "box" {
                    AsmNumberRow("z", model.grasp.size.z == 0 ? 40 : model.grasp.size.z, "mm") { v in var s = model.grasp.size; s.z = max(5, v); model.setObjectSize(s) }
                }
            }
            AsmSection("Fingers") {
                ForEach(model.grasp.fingers) { f in fingerRow(f) }
            }
            AsmSection("Actuators") {
                ForEach(model.grasp.actuators, id: \.name) { a in
                    AsmRow(a.name.replacingOccurrences(of: "_", with: " ").capitalized + (a.tendon ? " (tendon)" : ""),
                           a.tendon ? String(format: "%.1f mm", a.value) : String(format: "%.1f°", a.value))
                }
            }
            HStack(spacing: VFSpace.s) {
                Button { model.saveGrasp() } label: { Text("Save Grasp").frame(maxWidth: .infinity) }
                    .buttonStyle(.vfPrimary)
                    .help("Stores the object, fingertip targets, joints and actuators (asm.save_grasp)")
                Button { testInSimulation?() } label: { Text("Test in Simulation").frame(maxWidth: .infinity) }
                    .disabled(!PhysAvailability.available || testInSimulation == nil)
                    .help(PhysAvailability.available ? "Opens Simulate with a hold scenario" : "Needs the physics engine (phase 3)")
            }
            if let id = model.grasp.savedID {
                Text("Saved as \(id) in \(model.committed ?? "the assembly").").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        }
    }

    private func fingerRow(_ f: AssembleModel.GraspFinger) -> some View {
        HStack(alignment: .top, spacing: VFSpace.s) {
            Menu {
                ForEach(1...5, id: \.self) { p in Button("Priority \(p)") { model.setPriority(f.frame, p) } }
            } label: {
                Text("\(f.priority)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(Circle().fill(Color(platform: AssembleScene.fingerColour(f.priority))))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Priority: 1 is solved first")
            Text(f.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).frame(width: 52, alignment: .leading)
            HStack(spacing: 4) {
                Circle().fill(f.reached ? theme.success : theme.warning).frame(width: 6, height: 6)
                Text(f.reached ? "reached" : String(format: "%.1f mm", f.distanceMM)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            .frame(width: 70, alignment: .leading)
            Spacer(minLength: 0)
            Text(f.drive).font(VFFont.micro.weight(.semibold))
                .foregroundStyle(f.drive == "Tendon" ? theme.accentText : theme.stageLabel(.assemble))
                .padding(.horizontal, 6).frame(height: 16)
                .background(Capsule().fill(f.drive == "Tendon" ? theme.accent.opacity(0.14) : theme.stageFill(.assemble)))
                .fixedSize()
        }
        .frame(minHeight: 24)
        .help(f.joints.isEmpty ? f.title : f.title + ": " + f.joints.map { AsmFormat.deg($0) }.joined(separator: ", "))
    }
}

/// The editor of one joint: type, the parts it joins, axis, limits, motor, damping, friction,
/// and a drive slider. Edits are undo steps in the assembly and recommit it to the flow.
struct JointEditor: View {
    @Environment(\.viaFormTheme) private var theme
    let model: AssembleModel
    let joint: AsmJoint

    var body: some View {
        AsmSection("Joint: \(joint.title)") {
            AsmRow("Type", joint.kind.capitalized)
            AsmRow("Joins", "\(name(joint.parent)) to \(name(joint.child))")
            AsmRow("Axis", joint.axis.map { String(format: "%.0f", $0) }.joined(separator: ", "))
            if let r = joint.range {
                Slider(value: Binding(get: { model.q[joint.id] ?? 0 }, set: { model.setJoint(joint.id, value: $0) }), in: r)
                    .controlSize(.small)
                    .accessibilityLabel("Drive \(joint.title)")
            }
            AsmNumberRow("Lower limit", joint.range?.lowerBound ?? 0, joint.unit) { v in setLimit(lower: v) }
            AsmNumberRow("Upper limit", joint.range?.upperBound ?? 0, joint.unit) { v in setLimit(upper: v) }
            if let l = joint.limits {
                if let v = l.velocity_dps { AsmRow("Velocity", String(format: "%.0f deg/s", v)) }
                if let e = l.effort_nm { AsmRow("Effort", String(format: "%.2f N·m", e)) }
            }
        }
        if let m = joint.motor {
            AsmSection("Motor") {
                AsmRow("Model", m.part.split(separator: "/").last.map(String.init) ?? m.part)
                if let t = m.stall_torque_nm { AsmRow("Torque", String(format: "%.0f kg·cm", t / 0.0980665)) }
                if let v = m.voltage_v { AsmRow("Voltage", String(format: "%.0f V", v)) }
                AsmNumberRow("Gear ratio", m.gear_ratio ?? 1, ":1") { v in model.editJoint(joint.id, ["motor": motor(m, ["gear_ratio": v])]) }
                AsmNumberRow("Backlash", m.backlash_deg ?? 0, "deg") { v in model.editJoint(joint.id, ["motor": motor(m, ["backlash_deg": v])]) }
                if let b = m.bus_id { AsmRow("Bus id", "\(b)") }
            }
        }
        AsmSection("Dynamics") {
            AsmNumberRow("Damping", joint.damping ?? 0, "N·m·s") { v in model.editJoint(joint.id, ["damping": v]) }
            AsmNumberRow("Friction", joint.friction ?? 0, "N·m") { v in model.editJoint(joint.id, ["friction": v]) }
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

/// A capped bar of a value inside its limits.
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
                Capsule().fill(tint).frame(width: max(4, g.size.width * CGFloat(min(max(f, 0), 1))))
                if let r = range, r.lowerBound < 0, r.upperBound > 0 {
                    Rectangle().fill(theme.inkTertiary).frame(width: 1)
                        .offset(x: g.size.width * CGFloat(-r.lowerBound / (r.upperBound - r.lowerBound)))
                }
            }
        }
    }
}

// MARK: - Small pieces shared by the Assemble and Simulate inspectors

struct AsmSection<C: View>: View {
    let title: String
    let content: C
    init(_ title: String, @ViewBuilder _ content: () -> C) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            VFCaption(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AsmRow: View {
    @Environment(\.viaFormTheme) private var theme
    let key: String
    let value: String
    var warn = false
    var action: (() -> Void)?

    init(_ key: String, _ value: String, warn: Bool = false, action: (() -> Void)? = nil) {
        self.key = key
        self.value = value
        self.warn = warn
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(theme.inkSecondary).lineLimit(1)
            Spacer(minLength: VFSpace.m)
            if let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(value).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(warn ? theme.warning : theme.accentText)
                }
                .buttonStyle(.plain)
            } else {
                Text(value).foregroundStyle(warn ? theme.warning : theme.ink).lineLimit(1)
            }
        }
        .font(VFFont.row)
        .frame(minHeight: 22)
    }
}

/// A labelled number with its unit, committed on Return.
struct AsmNumberRow: View {
    @Environment(\.viaFormTheme) private var theme
    let key: String
    let value: Double
    let unit: String
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    init(_ key: String, _ value: Double, _ unit: String, commit: @escaping (Double) -> Void) {
        self.key = key
        self.value = value
        self.unit = unit
        self.commit = commit
    }

    var body: some View {
        HStack {
            Text(key).font(VFFont.row).foregroundStyle(theme.inkSecondary).lineLimit(1)
            Spacer(minLength: VFSpace.m)
            TextField(key, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(VFFont.row)
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
                .focused($focused)
                .onSubmit { if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { commit(v) } else { text = Self.format(value) } }
                .accessibilityLabel("\(key) in \(unit)")
            Text(unit).font(VFFont.small).foregroundStyle(theme.inkTertiary).frame(width: 40, alignment: .leading)
        }
        .frame(minHeight: 24)
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
    }

    static func format(_ v: Double) -> String { abs(v) >= 100 ? String(format: "%.1f", v) : String(format: "%.2f", v) }
}

/// Whether the physics engine is linked (viaform_phys.h declares vf_phys_*). Switched on by the
/// Simulate stage's physics service once the C ABI exists.
enum PhysAvailability {
    static var available: Bool { PhysService.shared.available }
}
