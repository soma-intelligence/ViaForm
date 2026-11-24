import SwiftUI

/// The one number field of the app (FRONTEND-SPEC 5 `NumberField`, 7.5):
/// - accepts `25`, `25 mm`, `1 in`, `25+3`, `2*12.5`, a unit after any number;
/// - shows the result before commit, and the error beside the field when the text does not parse;
/// - Return commits (one model change), Esc reverts, focus loss commits;
/// - arrow up and down step by `step` (Shift x10, Option x0.1) on the Mac;
/// - drag on the label scrubs the value (live, one commit on release);
/// - VoiceOver: label, value with unit, adjustable by `step`.
struct NumberField: View {
    @Environment(\.viaFormTheme) private var theme
    /// Shown before the field and used as the accessibility label. Empty hides it (the row labels it).
    var label: String = ""
    @Binding var value: Double
    var unit: VFUnit = .none
    var range: ClosedRange<Double>? = nil
    var step: Double = 1
    var width: CGFloat = 72
    /// Shows the unit after the field.
    var showsUnit = true
    /// Called once per commit (Return, focus loss, scrub release), after `value` is set.
    var onCommit: (() -> Void)? = nil
    /// False when the row already shows the label: the field keeps it for VoiceOver only.
    var labelVisible = true
    /// The return key's label on iPad ("Next" in a form of X, Y, Z fields).
    var submitLabel: SubmitLabel = .done
    /// Called after a Return commit: moves focus to the next field.
    var onSubmitNext: (() -> Void)? = nil
    /// Focus driven from outside: set it true to focus this field; the field writes it back.
    var focusRequest: Binding<Bool>? = nil

    @State private var text = ""
    @State private var error: String?
    @State private var scrubStart: Double?
    @FocusState private var focused: Bool
    // The reader's display units (P2-23): the field shows and takes a bare number in them.
    @AppStorage(UnitSettings.lengthKey) private var lengthPref = LengthDisplay.mm.rawValue
    @AppStorage(UnitSettings.angleKey) private var anglePref = AngleDisplay.deg.rawValue
    @AppStorage(UnitSettings.massKey) private var massPref = MassDisplay.g.rawValue
    @AppStorage(UnitSettings.decimalsKey) private var decimalsPref = -1

    init(_ label: String = "", value: Binding<Double>, unit: VFUnit = .none, range: ClosedRange<Double>? = nil,
         step: Double = 1, width: CGFloat = 72, showsUnit: Bool = true, onCommit: (() -> Void)? = nil) {
        self.label = label
        _value = value
        self.unit = unit
        self.range = range
        self.step = step
        self.width = width
        self.showsUnit = showsUnit
        self.onCommit = onCommit
    }

    /// The Generate inspector's older call shape.
    init(value: Binding<Double>, range: ClosedRange<Double>?, width: CGFloat = 72) {
        self.init("", value: value, range: range, width: width)
    }

    private var preview: Result<Double, VFExpression.Failure> { VFExpression(unit: unit).evaluate(text) }

    /// Base units per display unit (25.4 for inches); 1 for quantities that are not converted.
    private var factor: Double { UnitSettings.current.inputFactor(for: unit) }
    /// The editable text of a base value, in the display unit.
    private func editable(_ v: Double) -> String { VFFormat.editable(v / factor) }
    /// One arrow or scrub step in base units: `step` turned into a round display step.
    private var baseStep: Double { UnitSettings.current.displayStep(step, for: unit) * factor }
    private var unitToken: String { "\(lengthPref)|\(anglePref)|\(massPref)|\(decimalsPref)" }

    var body: some View {
        VStack(alignment: .trailing, spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.s) {
                if !label.isEmpty, labelVisible {
                    Text(label)
                        .font(VFFont.row)
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                        .gesture(scrub)
                        #if os(macOS)
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        #endif
                        .help(String(localized: "Drag to change the value"))
                        .accessibilityHidden(true)
                }
                TextField(label.isEmpty ? String(localized: "Value") : label, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .font(VFFont.row)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { commit(); onSubmitNext?() }
                    .onChange(of: focusRequest?.wrappedValue ?? false) { _, v in if v, !focused { focused = true } }
                    .onChange(of: focused) { _, v in if let r = focusRequest, r.wrappedValue != v { r.wrappedValue = v } }
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(submitLabel)
                    .frame(minWidth: width * 1.2, maxWidth: width * 1.4, minHeight: VFSize.touchTarget)
                    #else
                    .frame(minWidth: width * 0.75, idealWidth: width, maxWidth: width)
                    #endif
                    .onKeyPress(.escape) {
                        guard focused else { return .ignored }
                        revert()
                        return .handled
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        nudge(press.key == .upArrow ? 1 : -1, modifiers: press.modifiers)
                        return .handled
                    }
                    .overlay(alignment: .trailing) {
                        if error != nil {
                            RoundedRectangle(cornerRadius: VFRadius.control).strokeBorder(theme.danger, lineWidth: 1.5)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(label.isEmpty ? String(localized: "Value") : label)
                    .accessibilityValue(VFFormat.value(value, unit))
                    .accessibilityAdjustableAction { dir in
                        switch dir {
                        case .increment: nudge(1, modifiers: [])
                        case .decrement: nudge(-1, modifiers: [])
                        @unknown default: break
                        }
                    }
                if showsUnit, !VFFormat.symbol(unit).isEmpty {
                    Text(VFFormat.symbol(unit)).font(VFFont.row).foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                }
            }
            // While typing an expression, the result it will commit; or the error, beside the field.
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(VFFont.micro)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Error: \(error)"))
            } else if focused, case .success(let v) = preview, editable(v) != text.trimmingCharacters(in: .whitespaces) {
                Text("= \(VFFormat.value(clamped(v), unit))")
                    .font(VFFont.micro)
                    .foregroundStyle(theme.inkTertiary)
            }
        }
        .onAppear { text = editable(value) }
        .onChange(of: value) { _, v in if !focused { text = editable(v) } }
        .onChange(of: unitToken) { _, _ in if !focused { text = editable(value) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
        .onChange(of: text) { _, _ in if error != nil, case .success = preview { error = nil } }
    }

    private func clamped(_ v: Double) -> Double {
        guard let range else { return v }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private func commit() {
        switch preview {
        case .success(let v):
            let c = clamped(v)
            if let range, c != v {
                error = String(localized: "Between \(VFFormat.value(range.lowerBound, unit)) and \(VFFormat.value(range.upperBound, unit)).")
            } else {
                error = nil
            }
            if c != value { value = c }
            text = editable(c)
            onCommit?()
        case .failure(.empty):
            revert()
        case .failure(let f):
            error = f.message(for: unit)
        }
    }

    private func revert() {
        error = nil
        text = editable(value)
    }

    private func nudge(_ sign: Double, modifiers: EventModifiers) {
        var d = baseStep
        if modifiers.contains(.shift) { d *= 10 }
        if modifiers.contains(.option) { d *= 0.1 }
        let base: Double
        if case .success(let v) = preview { base = v } else { base = value }
        let next = clamped(base + sign * d)
        value = next
        text = editable(next)
        error = nil
        onCommit?()
    }

    /// Drag on the label: one `step` per 4 pt, Shift x10, Option x0.1; commits on release.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if scrubStart == nil { scrubStart = value }
                guard let s = scrubStart else { return }
                #if os(macOS)
                let flags = NSEvent.modifierFlags
                var d = baseStep
                if flags.contains(.shift) { d *= 10 }
                if flags.contains(.option) { d *= 0.1 }
                #else
                let d = baseStep
                #endif
                let next = clamped(s + (g.translation.width / 4).rounded() * d)
                if next != value { value = next; text = editable(next) }
            }
            .onEnded { _ in
                scrubStart = nil
                onCommit?()
            }
    }
}

/// A labelled number row for forms: label left, field and unit right.
struct NumberRow: View {
    let label: String
    @Binding var value: Double
    let unit: String
    var range: ClosedRange<Double>?
    var step: Double = 1

    init(_ label: String, value: Binding<Double>, unit: String, range: ClosedRange<Double>? = nil, step: Double = 1) {
        self.label = label
        _value = value
        self.unit = unit
        self.range = range
        self.step = step
    }

    var body: some View {
        LabeledContent(label) {
            NumberField(label, value: $value, unit: VFUnit(symbol: unit), range: range, step: step, width: 88)
                .labelHiddenVisually()
        }
    }
}

extension NumberField {
    /// Keeps the label for VoiceOver and drops the visible one (a row or a column shows it).
    func labelHiddenVisually() -> NumberField {
        var f = self
        f.labelVisible = false
        return f
    }

    /// Return commits, then runs `next` (focus the following field); the key reads `label`.
    func submitNext(_ label: SubmitLabel = .next, _ next: @escaping () -> Void) -> NumberField {
        var f = self
        f.submitLabel = label
        f.onSubmitNext = next
        return f
    }

    /// Ties the field's focus to `binding`, for focus order across fields (X, then Y, then Z).
    func focusBinding(_ binding: Binding<Bool>) -> NumberField {
        var f = self
        f.focusRequest = binding
        return f
    }
}
