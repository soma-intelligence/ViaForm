import Foundation
import Observation
import SwiftUI

/// The software e-stop of the Robot stage (VIAFORM-SPEC 6.4, FRONTEND-SPEC 7.9). The button,
/// Space, or Esc twice within 0.6 s latch it: torque off on every motor (the link sends it
/// once a robot is connected, task P7-2) and every motion verb is blocked until a deliberate
/// re-enable (hold 1 s).
@MainActor
@Observable
final class RobotSafety {
    static let shared = RobotSafety()

    private(set) var stopped = false
    /// What pressed it: "Button", "Space", "Esc twice".
    private(set) var source = ""
    private(set) var at: Date?
    @ObservationIgnored private var lastEscape: Date?

    /// Latches the stop.
    func stop(source: String) {
        stopped = true
        self.source = source
        at = Date()
    }

    /// One Esc: the second within 0.6 s stops. True when the key was taken.
    @discardableResult
    func escape(now: Date = Date()) -> Bool {
        if let last = lastEscape, now.timeIntervalSince(last) <= 0.6 {
            lastEscape = nil
            stop(source: "Esc twice")
            return true
        }
        lastEscape = now
        return false
    }

    /// After the hold: motors may be enabled again.
    func reenable() {
        stopped = false
        source = ""
        at = nil
    }
}

/// After an e-stop: motors off, and re-enable needs a deliberate 1 s hold.
struct RobotStoppedBanner: View {
    @Environment(\.viaFormTheme) private var theme
    @State private var safety = RobotSafety.shared
    @State private var holding = false

    var body: some View {
        HStack(spacing: VFSpace.l) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 20)).foregroundStyle(theme.danger)
            VStack(alignment: .leading, spacing: 1) {
                Text("E-stop: motors off").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                Text("Stopped by \(safety.source.isEmpty ? "the button" : safety.source)\(safety.at.map { " at " + $0.formatted(date: .omitted, time: .standard) } ?? ""). Motion verbs are blocked.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            Spacer()
            Text(holding ? "Keep holding" : "Hold to Re-enable")
                .font(VFFont.row.weight(.medium))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, VFSpace.l).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: VFRadius.control).fill(theme.well))
                .overlay(RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(holding ? theme.accent : theme.hairline))
                .onLongPressGesture(minimumDuration: 1.0, pressing: { holding = $0 }) { safety.reenable() }
                .accessibilityLabel("Re-enable motors")
                .accessibilityHint("Press and hold for one second")
                .accessibilityAction { safety.reenable() }
        }
        .padding(VFSpace.l)
        .frame(maxWidth: 720)
        .background(RoundedRectangle(cornerRadius: VFRadius.floating).fill(theme.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: VFRadius.floating).strokeBorder(theme.danger.opacity(0.6), lineWidth: 1.5))
    }
}
