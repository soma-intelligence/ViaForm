#if os(iOS)
import SwiftUI

/// The Robot stage on the iPad and the iPhone (VIAFORM-SPEC 7.9). The iPad has no USB serial: it
/// reaches a robot only through the ViaForm bridge over Wi-Fi (task P7-7). Until then the stage
/// shows where the twin and the camera go, with the shared safety bar always in view.
struct TouchRobotStage: View {
    @Environment(\.viaFormTheme) private var theme
    let flow: FlowModel
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        VStack(spacing: VFSpace.xl) {
            // The real e-stop button (44 pt, Space on a hardware keyboard) with the limits.
            SafetyBar()
            if safety.stopped {
                RobotStoppedBanner().vfTransition(.move(edge: .top).combined(with: .opacity))
            }
            VStack(spacing: VFSpace.m) {
                Spacer(minLength: 0)
                Image(systemName: "figure.arms.open")
                    .font(VFFont.glyph(48, weight: .light))
                    .imageScale(.large)
                    .foregroundStyle(theme.inkTertiary)
                    .accessibilityHidden(true)
                Text(safety.connected ? "Robot connected" : "No robot connected")
                    .font(VFFont.heading).foregroundStyle(theme.ink)
                Text("On iPad the robot connects through the ViaForm bridge over Wi-Fi. The twin, the camera and the telemetry show here once it does.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .motionFrame()
        }
        .vfAnimation(.easeOut(duration: VFMotion.fast), value: safety.stopped)
        .padding(.horizontal, VFSpace.xl)
        .padding(.top, VFSpace.paletteTop)   // clears the floating top chrome
        .padding(.bottom, VFSpace.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        // Esc twice within 0.6 s stops (a hardware keyboard); Space is the e-stop's shortcut.
        .onKeyPress(.escape) { safety.escape() ? .handled : .ignored }
        .background(theme.viewportGradient.ignoresSafeArea())
    }
}
#endif
