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

    @State private var safety = RobotSafety.shared

    var body: some View {
        VStack(spacing: VFSpace.l) {
            RobotSafetyBar(connected: false)
            if safety.stopped { RobotStoppedBanner() }
            HStack(spacing: VFSpace.l) {
                pane(title: "Digital twin", symbol: "figure.arms.open",
                     line: "Measured pose as a solid, commanded pose as a ghost, at 50 Hz once a robot is connected.")
                pane(title: "Camera", symbol: "video",
                     line: "The robot's camera feed shows here, beside the twin, while you teleoperate and record.")
            }
            connectCard
        }
        .padding(VFSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(vf: theme.palette.viewportTop), Color(vf: theme.palette.viewportBottom)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func pane(title: String, symbol: String, line: String) -> some View {
        VStack(spacing: VFSpace.m) {
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(theme.inkTertiary)
            Text(title).font(VFFont.title).foregroundStyle(theme.ink)
            Text(line).font(VFFont.row).foregroundStyle(theme.inkSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: VFRadius.floating).fill(theme.panel.opacity(0.55)))
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.floating)
                .strokeBorder(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .accessibilityElement(children: .combine)
    }

    /// The connect hint. Its verb is the ribbon's primary action ("Connect Robot").
    private var connectCard: some View {
        HStack(spacing: VFSpace.l) {
            Image(systemName: "cable.connector").font(.system(size: 20)).foregroundStyle(theme.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No robot connected").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Text("Connect a servo bus adapter over USB, or the ViaForm bridge over Wi-Fi. The joint map comes from "
                     + (flow.revisionName(of: "assemble") ?? "the assembly") + ".")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VFSpace.l)
        .frame(maxWidth: 720)
        .vfSurface(.floating, radius: VFRadius.floating)
        .accessibilityElement(children: .combine)
    }
}

/// Always in view in the Robot stage: the e-stop, the torque limit and the fence state.
struct RobotSafetyBar: View {
    @Environment(\.viaFormTheme) private var theme
    let connected: Bool

    var body: some View {
        HStack(spacing: VFSpace.xl) {
            RobotEStopButton(enabled: true) { RobotSafety.shared.stop(source: "Button") }
                .frame(width: 168)
            item("Torque limit", "60 %")
            item("Fence", connected ? "Armed" : "Joint limits from Assemble")
            item("Speed cap", "30 %")
            Spacer()
            HStack(spacing: VFSpace.xs) {
                Circle().strokeBorder(theme.inkTertiary, lineWidth: 1.25).frame(width: 8, height: 8)
                Text(connected ? "Connected" : "Not connected").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.vertical, VFSpace.s)
        .vfSurface(.floating, radius: VFRadius.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Safety")
    }

    private func item(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            VFCaption(k)
            Text(v).font(VFFont.row).foregroundStyle(theme.ink)
        }
    }
}

/// The software e-stop: red, 44 points high, always visible in the Robot stage and always live:
/// Space and Esc twice press it too. It latches `RobotSafety`; with a robot connected the
/// latch turns torque off on every motor.
struct RobotEStopButton: View {
    @Environment(\.viaFormTheme) private var theme
    var enabled: Bool
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: VFSpace.s) {
                Image(systemName: "stop.circle.fill").font(.system(size: 18, weight: .bold))
                Text("E-STOP").font(.system(size: 13, weight: .bold)).tracking(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
            .background(RoundedRectangle(cornerRadius: VFRadius.card).fill(theme.danger))
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "Torque off on every motor (Space, Esc twice)" : "No robot connected")
        .accessibilityLabel("Emergency stop")
        .accessibilityHint(enabled ? "Turns torque off on every motor" : "No robot connected")
    }
}

/// The Robot stage's bottom panel: telemetry per joint and the record control, empty until a
/// robot streams.
struct RobotTelemetryPanel: View {
    @Environment(\.viaFormTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: VFSpace.xl) {
            VStack(alignment: .leading, spacing: VFSpace.s) {
                VFCaption("Telemetry")
                HStack(spacing: VFSpace.l) {
                    ForEach(["Position", "Current", "Temperature"], id: \.self) { k in
                        VStack(alignment: .leading, spacing: VFSpace.xs) {
                            Text(k).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                            RoundedRectangle(cornerRadius: VFRadius.control)
                                .fill(theme.well)
                                .frame(width: 150, height: 54)
                                .overlay(Text("No data").font(VFFont.micro).foregroundStyle(theme.inkTertiary))
                        }
                    }
                }
            }
            Spacer(minLength: VFSpace.l)
            VStack(alignment: .leading, spacing: VFSpace.s) {
                VFCaption("Record")
                HStack(spacing: VFSpace.s) {
                    Button { } label: { Label("Record Demo", systemImage: "record.circle") }.disabled(true)
                    Text("0 demos").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
        }
        .padding(VFSpace.l)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .clipped()
        .background(theme.panel)
    }
}
#endif
