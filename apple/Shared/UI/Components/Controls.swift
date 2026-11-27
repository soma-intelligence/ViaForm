import SwiftUI

// Small controls shared by every screen: icon buttons with a mandatory label and platform hit
// targets, the touch button style, the hold-to-confirm button, key-value rows, money and the
// "disabled, and why" modifier.

// MARK: - Icon button

/// An SF Symbol button. The label is required (VoiceOver and tooltip), the hit target is at least
/// 44 pt on iPad and 22 pt on the Mac, and it highlights under the pointer.
struct VFIconButton: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    let symbol: String
    let label: String
    var size: CGFloat = 12
    var tint: Color? = nil
    var isOn = false
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hovered = false

    init(_ symbol: String, label: String, size: CGFloat = 12, tint: Color? = nil, isOn: Bool = false,
         role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.tint = tint
        self.isOn = isOn
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(VFFont.glyph(size, weight: .medium))
                .foregroundStyle(tint ?? (isOn ? theme.accentText : theme.inkSecondary))
                .frame(minWidth: VFSize.minTarget, minHeight: VFSize.minTarget)
                .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                    .fill(theme.ink.opacity(hovered && enabled ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovered = $0 }
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Touch button style

/// Pressed and disabled feedback for touch chrome: a wash and a slight scale on press (no scale
/// under Reduce Motion), a pointer highlight, dimmed when disabled. Sizes never change.
struct VFTouchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TouchBody(configuration: configuration) }

    private struct TouchBody: View {
        @Environment(\.viaFormTheme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduce
        let configuration: Configuration

        var body: some View {
            configuration.label
                .frame(minWidth: VFSize.minTarget, minHeight: VFSize.minTarget)
                .background(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous)
                    .fill(theme.ink.opacity(configuration.isPressed ? 0.10 : 0)))
                .scaleEffect(configuration.isPressed && !reduce ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                #if os(iOS)
                .hoverEffect(.highlight)
                #endif
        }
    }
}

extension ButtonStyle where Self == VFTouchButtonStyle {
    static var vfTouch: VFTouchButtonStyle { VFTouchButtonStyle() }
}

// MARK: - Hold to confirm

/// A deliberate action: press and hold for `duration` (FRONTEND-SPEC 7.9, Re-enable after an
/// e-stop). A ring fills while held (a static ring under Reduce Motion); releasing early cancels.
/// Keyboard: focus and hold Space or Return. VoiceOver: the action asks once more before running.
struct HoldButton: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduce
    let title: String
    var systemImage: String = "hand.tap"
    var duration: Double = 1
    let action: () -> Void

    @State private var progress: Double = 0
    @State private var holding: Task<Void, Never>?
    @State private var confirmVoiceOver = false

    var body: some View {
        HStack(spacing: VFSpace.s) {
            ZStack {
                Circle().stroke(theme.hairline, lineWidth: 2.5)
                Circle().trim(from: 0, to: progress)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            Text(title).font(VFFont.rowEmphasis)
        }
        .foregroundStyle(theme.ink)
        .padding(.horizontal, VFSpace.l)
        .frame(minHeight: max(VFSize.buttonHeight, 32))
        .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(theme.ink.opacity(progress > 0 ? 0.12 : 0.07)))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 30) {
            finish()
        } onPressingChanged: { pressing in
            pressing ? begin() : cancel()
        }
        .focusable()
        .onKeyPress(keys: [.space, .return], phases: [.down, .up]) { press in
            press.phase == .down ? begin(fireAtEnd: true) : cancel()
            return .handled
        }
        .help(String(localized: "Press and hold for \(Int(duration)) s"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint(Text("Press and hold to confirm"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { confirmVoiceOver = true }
        .confirmSheet(Binding(get: {
            confirmVoiceOver ? ConfirmRequest(title: title, message: String(localized: "Confirm this action."), verb: title,
                                              destructive: false, perform: action) : nil
        }, set: { if $0 == nil { confirmVoiceOver = false } }))
    }

    private func begin(fireAtEnd: Bool = false) {
        guard holding == nil else { return }
        let steps = 20
        holding = Task { @MainActor in
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                if Task.isCancelled { return }
                if reduce { progress = i == steps ? 1 : 0.5 } else { progress = Double(i) / Double(steps) }
            }
            if fireAtEnd { finish() }
        }
    }

    private func cancel() {
        holding?.cancel()
        holding = nil
        progress = 0
    }

    private func finish() {
        holding?.cancel()
        holding = nil
        progress = 0
        action()
    }
}

// MARK: - Rows

/// Label left, value right in monospaced digits, optional unit; the value may wrap to two lines.
struct KVRow: View {
    @Environment(\.viaFormTheme) private var theme
    let label: String
    let value: String
    var unit: String? = nil
    var valueColor: Color? = nil

    init(_ label: String, _ value: String, unit: String? = nil, valueColor: Color? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VFSpace.m) {
            Text(label).foregroundStyle(theme.inkSecondary).lineLimit(1).layoutPriority(1)
            Spacer(minLength: VFSpace.m)
            Text(unit.map { "\(value) \($0)" } ?? value)
                .foregroundStyle(valueColor ?? theme.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .monospacedDigit()
                .help(value)
        }
        .font(VFFont.row)
        .frame(minHeight: VFSize.macRow - 8)
        .accessibilityElement(children: .combine)
    }
}

/// Money with two decimals, or "No price" in the secondary ink (never "0").
struct MoneyText: View {
    @Environment(\.viaFormTheme) private var theme
    let value: Double?
    var currency = "USD"

    var body: some View {
        Text(VFFormat.money(value, currency: currency))
            .monospacedDigit()
            .foregroundStyle(value == nil ? theme.inkTertiary : theme.ink)
    }
}

// MARK: - Disabled with a reason

private struct DisabledReason: ViewModifier {
    let disabled: Bool
    let reason: String

    func body(content: Content) -> some View {
        content
            .disabled(disabled)
            .help(disabled ? reason : "")
            .accessibilityHint(disabled ? Text(reason) : Text(""))
    }
}

extension View {
    /// Disables the control and says why in the tooltip and to VoiceOver (FRONTEND-SPEC 5).
    func vfDisabled(_ disabled: Bool, reason: String) -> some View {
        modifier(DisabledReason(disabled: disabled, reason: reason))
    }

    /// Disabled while the ViaForm core is stopped, with that reason.
    @MainActor func vfEngineGate() -> some View {
        vfDisabled(EngineGate.shared.shut, reason: EngineGate.reason)
    }
}
