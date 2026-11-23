#if os(iOS)
import SwiftUI

/// The Robot stage on the iPad and the iPhone (VIAFORM-SPEC 7.9). The iPad has no USB serial: it
/// reaches a robot only through the ViaForm bridge over Wi-Fi (task P7-7). Until then the stage
/// shows where the twin and the camera go, with the safety bar always in view.
struct TouchRobotStage: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    @State private var safety = RobotSafety.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Button { safety.stop(source: "Button") } label: {
                    Label("E-STOP", systemImage: "stop.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 150, minHeight: VFSize.touchTarget)
                        .background(RoundedRectangle(cornerRadius: VFRadius.card).fill(theme.danger))
                }
                .buttonStyle(.plain)
                // A hardware keyboard: Space presses it, Esc twice within 0.6 s too.
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel("Emergency stop")
                .accessibilityHint("Turns torque off on every motor")
                VStack(alignment: .leading, spacing: 2) {
                    VFCaption("Torque limit")
                    Text("60 %").foregroundStyle(theme.ink)
                }
                VStack(alignment: .leading, spacing: 2) {
                    VFCaption("Speed cap")
                    Text("30 %").foregroundStyle(theme.ink)
                }
                Spacer(minLength: 0)
                Text("Not connected").font(.footnote).foregroundStyle(theme.inkSecondary)
            }
            .padding(12)
            .vfSurface(.floating, radius: VFRadius.floating)
            if safety.stopped { RobotStoppedBanner() }
            Spacer(minLength: 0)
            Image(systemName: "figure.arms.open").font(.system(size: 48, weight: .light)).foregroundStyle(theme.inkTertiary)
            Text("No robot connected").font(.title3.weight(.semibold)).foregroundStyle(theme.ink)
            Text("On iPad the robot connects through the ViaForm bridge over Wi-Fi. The twin, the camera and the telemetry show here once it does.")
                .font(.callout).foregroundStyle(theme.inkSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 76)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .onKeyPress(.escape) { safety.escape() ? .handled : .ignored }
        .background(
            LinearGradient(colors: [Color(vf: theme.palette.viewportTop), Color(vf: theme.palette.viewportBottom)],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
    }
}
#endif
