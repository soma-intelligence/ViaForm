import SwiftUI

// The Robot stage's safety bar (FRONTEND-SPEC 5 `SafetyBar`, 7.9, R-8), shared by the Mac and
// the iPad: a real e-stop button, the speed cap, the torque limit, the fence and the link state.
// Limits read from `RobotSafety`; with no robot they read "Not applied, no robot".

/// Always in view wherever motion can start.
struct SafetyBar: View {
    @Environment(\.viaFormTheme) private var theme
    private var safety: RobotSafety { RobotSafety.shared }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: VFSpace.xl) {
                EStopButton().frame(minWidth: 168)
                limits
                Spacer(minLength: VFSpace.m)
                linkState
            }
            VStack(alignment: .leading, spacing: VFSpace.m) {
                HStack(spacing: VFSpace.l) {
                    EStopButton().frame(minWidth: 150)
                    Spacer(minLength: VFSpace.m)
                    linkState
                }
                limits
            }
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.vertical, VFSpace.s)
        .vfSurface(.floating, radius: VFRadius.floating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Safety"))
    }

    private var limits: some View {
        HStack(alignment: .top, spacing: VFSpace.xl) {
            item(String(localized: "Speed cap"), safety.speedCapText,
                 set: VFFormat.value(safety.speedCap, .percent))
            item(String(localized: "Torque limit"), safety.torqueLimitText,
                 set: VFFormat.value(safety.torqueLimit, .percent))
            item(String(localized: "Fence"), safety.fenceText,
                 set: safety.fenceEnabled ? String(localized: "On") : String(localized: "Off"))
        }
    }

    private func item(_ k: String, _ v: String, set: String) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            VFCaption(k)
            Text(v)
                .font(VFFont.row)
                .foregroundStyle(safety.connected ? theme.ink : theme.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(safety.connected ? v : String(localized: "Set to \(set). Applies once a robot is connected."))
        .accessibilityElement(children: .combine)
        .accessibilityValue(safety.connected ? Text("") : Text("Set to \(set)"))
    }

    private var linkState: some View {
        HStack(spacing: VFSpace.xs) {
            VFStatusDot(status: safety.connected ? .current : .empty,
                        reason: safety.connected ? String(localized: "Robot connected")
                                                 : String(localized: "No robot connected"))
            Text(safety.connected ? "Connected" : "No robot connected")
                .font(VFFont.small)
                .foregroundStyle(theme.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The software e-stop: "E-STOP" in `onDanger` on `dangerFill` (passes contrast in both themes),
/// at least 44 pt high, always live. Space and Esc twice press it too (the window's keys). It
/// latches `RobotSafety`; with a robot connected the latch turns torque off on every motor.
/// It pulses once when motion starts, unless Reduce Motion is on.
struct EStopButton: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    private var safety: RobotSafety { RobotSafety.shared }
    @State private var pulse = false

    var body: some View {
        Button {
            safety.stop(source: RobotSafety.StopSource.button.rawValue)
        } label: {
            HStack(spacing: VFSpace.s) {
                Image(systemName: "stop.circle.fill")
                    .font(VFFont.glyph(18, weight: .bold))
                    .accessibilityHidden(true)
                Text("E-STOP")
                    .font(VFFont.rowEmphasis.weight(.bold))
                    .tracking(0.8)
            }
            .foregroundStyle(theme.onDanger)
            .padding(.horizontal, VFSpace.l)
            .frame(maxWidth: .infinity, minHeight: VFSize.touchTarget)
            .background(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous).fill(theme.dangerFill))
            .overlay(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                .strokeBorder(theme.onDanger.opacity(pulse ? 0.9 : 0), lineWidth: 2))
            .scaleEffect(pulse ? 1.06 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect(.highlight)
        // A hardware keyboard: Space presses it; Esc twice is handled by the stage.
        .keyboardShortcut(.space, modifiers: [])
        #endif
        .help(safety.connected ? "Torque off on every motor (Space, Esc twice)"
                               : "No robot connected. Pressing it still blocks every motion verb (Space, Esc twice)")
        .accessibilityLabel(Text("Emergency stop"))
        .accessibilityHint(safety.connected ? Text("Turns torque off on every motor")
                                            : Text("No robot connected. Blocks every motion verb"))
        .onChange(of: safety.motionStarts) {
            guard !reduce else { return }
            vfWithAnimation(.easeOut(duration: VFMotion.fast)) { pulse = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(260))
                vfWithAnimation(.easeIn(duration: VFMotion.standard)) { pulse = false }
            }
        }
    }
}
