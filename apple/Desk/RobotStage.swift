#if os(macOS)
import SwiftUI

/// The Robot stage (VIAFORM-SPEC 7.9) before the hardware link exists: the canvas keeps the two
/// places the live twin and the camera feed will take, the safety bar is always in view, and the
/// bottom panel holds the telemetry and record controls. Every motion verb stays disabled until
/// a robot is connected (robot-protocol, task P7-2).
struct RobotStage: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    let actions: StageActions

    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        VStack(spacing: VFSpace.l) {
            SafetyBar()
            if safety.stopped {
                RobotStoppedBanner().vfTransition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: VFSpace.l) {
                pane(title: String(localized: "Digital twin"), symbol: "figure.arms.open",
                     line: String(localized: "Measured pose as a solid, commanded pose as a ghost, at 50 Hz once a robot is connected."))
                pane(title: String(localized: "Camera"), symbol: "video",
                     line: String(localized: "The robot's camera feed shows here, beside the twin, while you teleoperate and record."))
            }
            .motionFrame()
            if !safety.connected { connectCard }
        }
        .vfAnimation(.easeOut(duration: VFMotion.fast), value: safety.stopped)
        .padding(VFSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.viewportGradient)
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

    /// The connect hint. Its verb is the ribbon's primary action ("Connect Robot").
    private var connectCard: some View {
        let source = flow.revisionName(of: "assemble") ?? String(localized: "the assembly")
        return HStack(spacing: VFSpace.l) {
            Image(systemName: "cable.connector")
                .font(VFFont.glyph(20))
                .foregroundStyle(theme.inkSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                Text("No robot connected").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Text(String(localized: "Connect a servo bus adapter over USB, or the ViaForm bridge over Wi-Fi. The joint map comes from \(source)."))
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VFSpace.l)
        .frame(maxWidth: 720)
        .vfSurface(.floating, radius: VFRadius.floating)
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

    var body: some View {
        HStack(alignment: .top, spacing: VFSpace.xl) {
            VStack(alignment: .leading, spacing: VFSpace.s) {
                VFCaption("Telemetry")
                HStack(alignment: .top, spacing: VFSpace.l) {
                    ForEach(channels, id: \.self) { k in
                        VStack(alignment: .leading, spacing: VFSpace.xs) {
                            Text(k).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                            Text("No data")
                                .font(VFFont.micro)
                                .foregroundStyle(theme.inkTertiary)
                                .padding(VFSpace.s)
                                .frame(minWidth: 96, maxWidth: 200, minHeight: 54)
                                .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(theme.well))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(k), no data"))
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: VFSpace.l)
            VStack(alignment: .leading, spacing: VFSpace.s) {
                VFCaption("Record")
                HStack(spacing: VFSpace.s) {
                    Button { } label: { Label("Record Demo", systemImage: "record.circle") }
                        .buttonStyle(.vfSecondary)
                        .vfDisabled(true, reason: safety.lockReason ?? String(localized: "Recording comes with the robot link"))
                    Text("No demos yet").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
        }
        .padding(VFSpace.l)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(theme.panel)
    }
}
#endif
