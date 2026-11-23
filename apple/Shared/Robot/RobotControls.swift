import SwiftUI

// The Robot stage's controls, shared by the Mac and the iPad: the connection choice, the twin,
// the joints (jog and a dragged pose) and the motion verbs. Every verb goes through
// `RobotSafety.request`, which asks "Run on Robot?" once per session and refuses while the
// e-stop is latched; the caps and the fence come from `RobotSafety`.

/// Where the user picks a link. Only the simulated robot exists before the hardware link.
struct RobotConnectionCard: View {
    @Environment(\.viaFormTheme) private var theme
    /// The source of the joint map, for the hint ("the assembly", or its revision).
    var source: String
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack(alignment: .top, spacing: VFSpace.l) {
                Image(systemName: safety.connected ? "cpu" : "cable.connector")
                    .font(VFFont.glyph(20))
                    .foregroundStyle(theme.inkSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: VFSpace.xxs) {
                    Text(title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    Text(line)
                        .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: VFSpace.s) { choices }
                VStack(alignment: .leading, spacing: VFSpace.s) { choices }
            }
        }
        .padding(VFSpace.l)
        .frame(maxWidth: 720)
        .vfSurface(.floating, radius: VFRadius.floating)
    }

    private var title: String {
        guard let kind = safety.linkKind else { return String(localized: "No robot connected") }
        return String(localized: "\(kind.title) connected")
    }

    private var line: String {
        if safety.linkKind == .simulated {
            return String(localized: "Commands play on a servo model with the same safety gate. No hardware moves.")
        }
        return String(localized: "Connect a servo bus adapter over USB, or the ViaForm bridge over Wi-Fi. The joint map comes from \(source). Try the flow first with the simulated robot.")
    }

    @ViewBuilder private var choices: some View {
        if safety.connected {
            Button {
                safety.disconnect()
            } label: { Label("Disconnect", systemImage: "xmark.circle") }
                .buttonStyle(.vfSecondary)
                .vfDisabled(safety.moving, reason: String(localized: "Stop the robot to disconnect"))
        } else {
            ForEach(RobotLinkKind.allCases) { kind in
                Button {
                    if kind == .simulated { safety.connect(SimulatedRobotLink()) }
                } label: {
                    Label(String(localized: "Connect \(kind.title)"),
                          systemImage: kind == .simulated ? "cube.transparent" : (kind == .usb ? "cable.connector" : "wifi"))
                }
                .modifier(ChoiceStyle(primary: kind == .simulated))
                .vfDisabled(kind.unavailableReason != nil, reason: kind.unavailableReason ?? "")
            }
        }
    }

    private struct ChoiceStyle: ViewModifier {
        let primary: Bool
        func body(content: Content) -> some View {
            if primary { content.buttonStyle(.vfPrimary) } else { content.buttonStyle(.vfSecondary) }
        }
    }
}

/// The digital twin, side view of the arm's pitch joints: the measured pose solid, the
/// commanded pose as a ghost.
struct RobotTwinView: View {
    @Environment(\.viaFormTheme) private var theme
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        Canvas { ctx, size in
            guard let s = safety.linkState else { return }
            let base = CGPoint(x: size.width / 2, y: size.height * 0.85)
            let unit = min(size.width, size.height) * 0.28
            ctx.stroke(Path { $0.move(to: CGPoint(x: base.x - unit * 0.5, y: base.y)); $0.addLine(to: CGPoint(x: base.x + unit * 0.5, y: base.y)) },
                       with: .color(theme.inkTertiary), lineWidth: 3)
            draw(ctx, s.targets, base: base, unit: unit, color: theme.inkTertiary.opacity(0.6), width: 6, dash: [6, 5])
            draw(ctx, s.positions, base: base, unit: unit, color: theme.ink, width: 8, dash: [])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Digital twin"))
        .accessibilityValue(Text(safety.moving ? "Moving" : "At rest"))
    }

    /// Shoulder, elbow and wrist pitch (joints 1 to 3) as a planar chain.
    private func draw(_ ctx: GraphicsContext, _ q: [Double], base: CGPoint, unit: CGFloat, color: Color, width: CGFloat, dash: [CGFloat]) {
        guard q.count >= 4 else { return }
        let lengths: [CGFloat] = [1, 0.85, 0.45]
        var p = base
        var angle = -Double.pi / 2
        var path = Path()
        path.move(to: p)
        for k in 0..<3 {
            angle += q[k + 1] * .pi / 180
            p = CGPoint(x: p.x + CGFloat(cos(angle)) * lengths[k] * unit, y: p.y + CGFloat(sin(angle)) * lengths[k] * unit)
            path.addLine(to: p)
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }
}

/// The joints: measured value, commanded target, jog buttons, and a drag that drafts a pose
/// committed with Move to Pose. All motion asks through the gate.
struct RobotJointsPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Binding var confirm: ConfirmRequest?
    @State private var draft: [Double] = []
    @State private var notice: String?
    private var safety: RobotSafety { RobotSafety.shared }
    /// Jog step, degrees.
    private let step: Double = 5

    var body: some View {
        let joints = safety.link?.joints ?? []
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack {
                VFCaption("Joints")
                Spacer()
                if let a = safety.activity {
                    Text(a).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                }
            }
            ForEach(Array(joints.enumerated()), id: \.offset) { i, j in
                row(i, j)
            }
            HStack(spacing: VFSpace.s) {
                Button { commitDraft() } label: { Label("Move to Pose", systemImage: "arrow.right.circle") }
                    .buttonStyle(.vfSecondary)
                    .vfDisabled(!safety.canMove || draft.count != joints.count,
                                reason: safety.lockReason ?? String(localized: "Drag a joint first"))
                Button { draft = safety.linkState?.positions ?? [] } label: { Text("Reset Pose") }
                    .buttonStyle(.vfSecondary)
                    .vfDisabled(draft.isEmpty, reason: String(localized: "Nothing dragged"))
            }
            if let notice {
                Text(notice).font(VFFont.small).foregroundStyle(theme.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { draft = safety.linkState?.positions ?? [] }
        .onChange(of: safety.linkKind) { draft = safety.linkState?.positions ?? [] }
    }

    private func row(_ i: Int, _ j: RobotJointSpec) -> some View {
        let measured = safety.linkState?.positions[robotAt: i] ?? 0
        let target = safety.linkState?.targets[robotAt: i] ?? 0
        return VStack(alignment: .leading, spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.s) {
                Text(j.name).font(VFFont.row).foregroundStyle(theme.ink).lineLimit(1).layoutPriority(1)
                Spacer(minLength: VFSpace.s)
                Text(VFFormat.value(measured, .angle))
                    .font(VFFont.row).monospacedDigit().foregroundStyle(theme.ink)
                Text(VFFormat.value(target, .angle))
                    .font(VFFont.small).monospacedDigit().foregroundStyle(theme.inkTertiary)
                    .help(String(localized: "Commanded"))
                jogButton(i, j, -step, "minus")
                jogButton(i, j, step, "plus")
            }
            Slider(value: Binding(get: { draft[robotAt: i] ?? measured },
                                  set: { v in
                                      if draft.count != (safety.link?.joints.count ?? 0) { draft = safety.linkState?.positions ?? [] }
                                      if draft.indices.contains(i) { draft[i] = v }
                                  }),
                   in: j.range)
                .controlSize(.small)
                .accessibilityLabel(Text("\(j.name) pose"))
                .vfDisabled(!safety.connected, reason: safety.lockReason ?? "")
        }
        .accessibilityElement(children: .contain)
    }

    private func jogButton(_ i: Int, _ j: RobotJointSpec, _ delta: Double, _ symbol: String) -> some View {
        Button {
            ask(.jog(joint: i, delta: delta), target: String(localized: "Jog \(j.name)"))
        } label: {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .buttonStyle(.vfSecondary)
        .accessibilityLabel(Text(delta < 0 ? "Jog \(j.name) down" : "Jog \(j.name) up"))
        .vfDisabled(!safety.canMove, reason: safety.lockReason ?? "")
    }

    private func commitDraft() {
        ask(.pose(draft, label: String(localized: "Move to pose")), target: String(localized: "The dragged pose"))
    }

    private func ask(_ m: RobotSafety.Motion, target: String) {
        notice = safety.request(m, target: target, present: { confirm = $0 })
    }
}

/// The motion verbs that play a path: demo replay and the trained policy.
struct RobotMotionVerbs: View {
    @Binding var confirm: ConfirmRequest?
    /// The trained policy revision, nil when there is none.
    var policy: String?
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: VFSpace.s) { verbs }
            VStack(alignment: .leading, spacing: VFSpace.s) { verbs }
        }
    }

    @ViewBuilder private var verbs: some View {
        Button { replayDemo() } label: { Label("Replay Demo on Robot", systemImage: "play.rectangle") }
            .buttonStyle(.vfSecondary)
            .vfDisabled(!safety.canMove, reason: safety.lockReason ?? "")
        RobotRunPolicyButton(confirm: $confirm, policy: policy)
    }

    private func replayDemo() {
        guard let joints = safety.link?.joints else { return }
        let path = RobotSafety.syntheticPath(joints: joints)
        safety.request(.trajectory(path, rate: RobotSafety.controlRate, label: String(localized: "Demo 1 replay")),
                       target: String(localized: "Demo 1 replay"), revision: String(localized: "synthetic demo"),
                       present: { confirm = $0 })
    }
}

/// "Run on Robot": the trained policy through the gate (a synthetic rollout until phase 7).
struct RobotRunPolicyButton: View {
    @Binding var confirm: ConfirmRequest?
    var policy: String?
    var fullWidth = false
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        Button { run() } label: {
            Label("Run on Robot", systemImage: safety.canMove ? "play.fill" : "lock.fill")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.vfSecondary)
        .vfDisabled(!safety.canMove || policy == nil,
                    reason: safety.lockReason ?? String(localized: "Train a policy first"))
    }

    private func run() {
        guard let policy, let joints = safety.link?.joints else { return }
        let path = RobotSafety.syntheticPath(joints: joints, seconds: 4, phase: 1.3)
        safety.request(.trajectory(path, rate: RobotSafety.controlRate, label: policy),
                       target: String(localized: "The trained policy"), revision: policy,
                       present: { confirm = $0 })
    }
}

private extension Array {
    subscript(robotAt i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// "Send Pose to Robot" for the Assemble IK drag: the solved joint values go to the robot as one
/// pose through the gate (confirmed once per session, fenced, capped, blocked by the e-stop).
/// Values map in joint order onto the link's joints; missing ones keep their commanded target.
struct RobotSendPoseButton: View {
    /// The solved joint values in the assembly's joint order (degrees, mm for a slider).
    let values: () -> [Double]
    @State private var confirm: ConfirmRequest?
    @State private var notice: String?
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        Button {
            notice = safety.request(.pose(RobotSafety.poseTargets(values(), for: safety.link), label: String(localized: "IK pose")),
                                    target: String(localized: "The IK pose"), present: { confirm = $0 })
        } label: {
            Label("Send Pose to Robot", systemImage: safety.canMove ? "arrow.up.forward.circle" : "lock.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.vfSecondary)
        .vfDisabled(!safety.canMove, reason: safety.lockReason ?? "")
        .help(String(localized: "Moves the connected robot to this pose. Asks once per session."))
        .confirmSheet($confirm)
    }
}

extension RobotSafety {
    /// Assembly joint values onto the link's joints, in order; the rest keep their target.
    static func poseTargets(_ values: [Double], for link: (any RobotLink)?) -> [Double] {
        guard let link else { return values }
        var t = link.state.targets
        for i in t.indices where i < values.count { t[i] = values[i] }
        return t
    }
}
