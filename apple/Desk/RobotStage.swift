#if os(macOS)
import SwiftUI

/// The Robot stage (VIAFORM-SPEC 7.9): the safety bar always in view, the connection choice
/// (the simulated robot until the hardware link, task P7-2), the live twin with the joints, and
/// the motion verbs. Every verb goes through `RobotSafety`: confirmed once per session, blocked
/// while the e-stop is latched, capped by the stored limits, framed in red while moving.
struct RobotStage: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let actions: StageActions
    @State private var confirm: ConfirmRequest?

    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        VStack(spacing: VFSpace.l) {
            SafetyBar()
            if safety.stopped {
                RobotStoppedBanner().vfTransition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: VFSpace.l) {
                if safety.connected {
                    RobotTwinView()
                        .padding(VFSpace.l)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous).fill(theme.panel.opacity(0.55)))
                    ScrollView {
                        VStack(alignment: .leading, spacing: VFSpace.l) {
                            RobotJointsPanel(confirm: $confirm)
                            RobotMotionVerbs(confirm: $confirm, policy: flow.revisionName(of: "train"))
                        }
                        .padding(VFSpace.l)
                    }
                    .frame(minWidth: 300, maxWidth: 380, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous).fill(theme.panel.opacity(0.55)))
                } else {
                    pane(title: String(localized: "Digital twin"), symbol: "figure.arms.open",
                         line: String(localized: "Measured pose as a solid, commanded pose as a ghost, at 50 Hz once a robot is connected."))
                    pane(title: String(localized: "Camera"), symbol: "video",
                         line: String(localized: "The robot's camera feed shows here, beside the twin, while you teleoperate and record."))
                }
            }
            .motionFrame()
            RobotConnectionCard(source: flow.revisionName(of: "assemble") ?? String(localized: "the assembly"))
        }
        .vfAnimation(.easeOut(duration: VFMotion.fast), value: safety.stopped)
        .padding(VFSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.viewportGradient)
        .confirmSheet($confirm)
    }

    private func pane(title: String, symbol: String, line: String) -> some View {
        VStack(spacing: VFSpace.m) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(VFFont.glyph(40, weight: .light))
                .foregroundStyle(theme.inkTertiary)
                .accessibilityHidden(true)
            Text(title).font(VFFont.title).foregroundStyle(theme.ink)
            Text(line).font(VFFont.row).foregroundStyle(theme.inkSecondary).multilineTextAlignment(.center)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .padding(VFSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous).fill(theme.panel.opacity(0.55)))
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.floating, style: .continuous)
                .strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .accessibilityElement(children: .combine)
    }
}

/// The Robot stage's bottom panel: telemetry per joint and the record control, empty until a
/// robot streams. Wells are flexible with a minimum size, so larger text never clips.
struct RobotTelemetryPanel: View {
    @Environment(\.viaFormTheme) private var theme
    private var safety: RobotSafety { RobotSafety.shared }

    private var channels: [String] {
        [String(localized: "Position"), String(localized: "Current"), String(localized: "Temperature")]
    }

    /// The peak over the joints, or "No data" before a robot streams.
    private func reading(_ channel: String) -> String {
        guard let s = safety.linkState else { return String(localized: "No data") }
        switch channel {
        case String(localized: "Position"):
            let err = zip(s.targets, s.positions).map { abs($0 - $1) }.max() ?? 0
            return String(localized: "Tracking error \(VFFormat.value(err, .angle))")
        case String(localized: "Current"):
            return String(localized: "Peak \(VFFormat.value(s.efforts.max() ?? 0, .percent))")
        default:
            return String(localized: "Not reported")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: VFSpace.xl) {
            VStack(alignment: .leading, spacing: VFSpace.s) {
                VFCaption("Telemetry")
                HStack(alignment: .top, spacing: VFSpace.l) {
                    ForEach(channels, id: \.self) { k in
                        VStack(alignment: .leading, spacing: VFSpace.xs) {
                            Text(k).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                            Text(reading(k))
                                .font(VFFont.micro)
                                .monospacedDigit()
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(safety.linkState == nil ? theme.inkTertiary : theme.ink)
                                .padding(VFSpace.s)
                                .frame(minWidth: 64, maxWidth: 200, minHeight: 54)
                                .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(theme.well))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(k), \(reading(k))"))
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: VFSpace.m)
            VStack(alignment: .leading, spacing: VFSpace.s) {
                VFCaption("Record")
                // Stacked so a narrow window never pushes the panel wider than the canvas.
                Button { } label: { Label("Record Demo", systemImage: "record.circle").lineLimit(1) }
                    .buttonStyle(.vfSecondary)
                    .vfDisabled(true, reason: safety.lockReason ?? String(localized: "Recording comes with the robot link"))
                Text("No demos yet").font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(VFSpace.l)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(theme.panel)
    }
}
#endif
