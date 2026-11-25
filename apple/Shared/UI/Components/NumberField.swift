import SwiftUI

/// The one number field of the app (FRONTEND-SPEC 5 `NumberField`, 7.5):
/// - accepts `25`, `25 mm`, `1 in`, `25+3`, `2*12.5`, a unit after any number;
/// - shows the result before commit, and the error beside the field when the text does not parse;
/// - Return commits (one model change), Esc reverts, focus loss commits;
/// - arrow up and down step by `step` (Shift x10, Option x0.1) on the Mac;
/// - drag on the label scrubs the value (live, one commit on release);
/// - VoiceOver: label, value with unit, adjustable by `step`.
/// - parameters (B-10): with a `ParameterContext` in the environment the field completes
///   parameter names and evaluates expressions that use them through the engine. A field given
///   an expression binding (`.linked(_:)`) stores the expression, shows it with an fx marker and
///   follows the parameter; a field without one refuses a parameter name rather than copying its
///   value (always link, never a silent copy).
/// - keypad hook (T-15): with a `NumberKeypad` in the environment the iPad field opens that
///   keypad in a popover instead of the system keyboard; the keypad edits the same text and
///   commits through the same path.
struct NumberField: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfParameters) private var parameters
    @Environment(\.vfNumberKeypad) private var keypad
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
    /// The stored expression when the caller keeps one ("w * 2"); empty or a plain number is not
    /// linked. Set with `.linked(_:)`.
    var expression: Binding<String>? = nil

    @State private var text = ""
    @State private var suggestions: [ParametersModel.Suggestion] = []
    @State private var keypadOpen = false
    /// The keypad closed through its own Done or Cancel (a tap outside commits, as focus loss).
    @State private var keypadFinished = false
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

    /// What the text gives: a number, a value driven by parameters, or why it does not.
    private var preview: LinkedNumber.Parsed {
        LinkedNumber.parse(text, unit: unit, parameters: parameters)
    }

    /// The field follows a parameter: the caller keeps an expression that names one.
    private var isLinked: Bool {
        guard let e = expression?.wrappedValue, !e.isEmpty else { return false }
        if let parameters { return LinkedNumber.linked(e, names: parameters.names) }
        if case .failure = VFExpression(unit: unit).evaluate(e) { return true }
        return false
    }
    private var linkedNames: [String] {
        guard let e = expression?.wrappedValue else { return [] }
        return parameters?.references(in: e) ?? ParameterContext.identifiers(e)
    }
    /// The text the field shows at rest: the expression when linked, else the value.
    private var restingText: String { isLinked ? (expression?.wrappedValue ?? "") : editable(value) }

    /// Base units per display unit (25.4 for inches); 1 for quantities that are not converted.
    private var factor: Double { UnitSettings.current.inputFactor(for: unit) }
    /// The editable text of a base value, in the display unit.
    /// In a converted unit the text keeps one digit more than the display precision (4.7244 in,
    /// not 4.724409); an untouched field commits nothing, so the base value stays exact.
    private func editable(_ v: Double) -> String {
        guard factor != 1, let d = UnitSettings.current.display(for: unit) else { return VFFormat.editable(v / factor) }
        let p = pow(10.0, Double(d.digits + 1))
        return VFFormat.editable((v / factor * p).rounded() / p)
    }
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
                if isLinked { linkMarker }
                input
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
            } else if focused || keypadOpen, let v = preview.number, editable(v) != text.trimmingCharacters(in: .whitespaces) {
                Text("= \(VFFormat.value(clamped(v), unit))")
                    .font(VFFont.micro)
                    .foregroundStyle(theme.inkTertiary)
            }
            if focused, !suggestions.isEmpty { suggestionList }
        }
        .onAppear { text = restingText }
        .onChange(of: value) { _, _ in if !focused, !keypadOpen { text = restingText } }
        .onChange(of: expression?.wrappedValue ?? "") { _, _ in if !focused, !keypadOpen { text = restingText } }
        .onChange(of: unitToken) { _, _ in if !focused, !keypadOpen { text = restingText } }
        .onChange(of: focused) { _, f in if !f { commit() } }
        .onChange(of: text) { _, t in
            if error != nil, preview.number != nil { error = nil }
            suggestions = focused ? Self.completions(t, parameters) : []
        }
    }

    /// Parameter names that complete the word being typed (at most five).
    static func completions(_ text: String, _ parameters: ParameterContext?) -> [ParametersModel.Suggestion] {
        guard let parameters, let word = ParameterContext.trailingWord(text) else { return [] }
        let found = parameters.complete(text).filter { $0.kind == "parameter" && $0.text != word }
        return Array(found.prefix(5))
    }

    /// Replaces the word being typed with a completion.
    private func accept(_ s: ParametersModel.Suggestion) {
        if let word = ParameterContext.trailingWord(text) { text.removeLast(word.count) }
        text += s.text
        suggestions = []
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { s in
                Button { accept(s) } label: {
                    HStack(spacing: VFSpace.s) {
                        Image(systemName: "function").font(VFFont.glyph(9)).foregroundStyle(theme.accentText)
                            .accessibilityHidden(true)
                        Text(s.text).font(VFFont.row).foregroundStyle(theme.ink)
                        Spacer(minLength: VFSpace.m)
                        Text(s.detail).font(VFFont.micro).foregroundStyle(theme.inkSecondary).lineLimit(1)
                    }
                    .padding(.horizontal, VFSpace.s).padding(.vertical, VFSpace.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(s.detail)
                .accessibilityLabel(Text("Insert parameter \(s.text)"))
            }
        }
        .frame(minWidth: width * 1.6, alignment: .leading)
        .vfSurface(.floating)
    }

    /// The fx marker of a value driven by a parameter: names the parameter, offers to unlink.
    private var linkMarker: some View {
        let names = linkedNames.joined(separator: ", ")
        return Menu {
            Text("Driven by \(names)")
            Button(String(localized: "Unlink and keep \(VFFormat.value(value, unit))")) {
                expression?.wrappedValue = ""
                text = editable(value)
                onCommit?()
            }
        } label: {
            Image(systemName: "function")
                .font(VFFont.glyph(10, weight: .semibold))
                .foregroundStyle(theme.accentText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Driven by \(names)"))
        .accessibilityLabel(Text("Linked to \(names)"))
    }

    /// The text field, or on iPad with a keypad hook, a field-shaped button that opens it.
    @ViewBuilder private var input: some View {
        #if os(iOS)
        if let keypad {
            Button { keypadFinished = false; keypadOpen = true } label: {
                Text(text.isEmpty ? " " : text)
                    .font(VFFont.row).monospacedDigit()
                    .foregroundStyle(theme.ink)
                    .frame(minWidth: width * 1.2, maxWidth: width * 1.4, minHeight: VFSize.touchTarget, alignment: .trailing)
                    .padding(.horizontal, VFSpace.s)
                    .vfSurface(.well)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label.isEmpty ? String(localized: "Value") : label)
            .accessibilityValue(isLinked ? text : VFFormat.value(value, unit))
            .popover(isPresented: $keypadOpen) {
                keypad.content(keypadRequest)
            }
            // Focus driven from outside opens the keypad (a value chip turning into its field);
            // closing it hands focus back.
            .onAppear { if focusRequest?.wrappedValue == true { keypadFinished = false; keypadOpen = true } }
            .onChange(of: focusRequest?.wrappedValue ?? false) { _, v in if v, !keypadOpen { keypadFinished = false; keypadOpen = true } }
            .onChange(of: keypadOpen) { _, open in
                if !open, !keypadFinished { commit() }
                keypadFinished = false
                if let r = focusRequest, r.wrappedValue != open { r.wrappedValue = open }
            }
        } else {
            textField
        }
        #else
        textField
        #endif
    }

    /// What the keypad edits and how it finishes: the same text, preview and commit as typing.
    private var keypadRequest: NumberKeypadRequest {
        NumberKeypadRequest(
            label: label.isEmpty ? String(localized: "Value") : label,
            unit: unit,
            text: $text,
            preview: preview.number.map { VFFormat.value(clamped($0), unit) },
            error: error ?? preview.message(for: unit),
            parameterNames: parameters?.names ?? [],
            commit: {
                commit()
                // Stays open while the text is not stored (a parse error, a refused link).
                guard text == restingText else { return }
                keypadFinished = true
                keypadOpen = false
            },
            cancel: { revert(); keypadFinished = true; keypadOpen = false })
    }

    private var textField: some View {
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
                    .onKeyPress(.tab) {
                        guard focused, let first = suggestions.first else { return .ignored }
                        accept(first)
                        return .handled
                    }
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
                    .accessibilityValue(isLinked ? text : VFFormat.value(value, unit))
                    .accessibilityAdjustableAction { dir in
                        switch dir {
                        case .increment: nudge(1, modifiers: [])
                        case .decrement: nudge(-1, modifiers: [])
                        @unknown default: break
                        }
                    }
    }

    private func clamped(_ v: Double) -> Double {
        guard let range else { return v }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private func commit() {
        suggestions = []
        let typed = text.trimmingCharacters(in: .whitespaces)
        // The text still shows what is stored (rounded in a converted unit): nothing to change.
        if error == nil, typed == restingText.trimmingCharacters(in: .whitespaces) {
            onCommit?()
            return
        }
        switch preview {
        case .value(let v), .linked(let v):
            let isLink = preview.isLinked
            if isLink, expression == nil {
                // Never a silent copy: a field that keeps numbers only does not take a name.
                error = String(localized: "This value cannot follow a parameter here. Type a number.")
                return
            }
            let c = clamped(v)
            if let range, c != v {
                error = String(localized: "Between \(VFFormat.value(range.lowerBound, unit)) and \(VFFormat.value(range.upperBound, unit)).")
                if isLink { return }
            } else {
                error = nil
            }
            if let expression {
                let e = isLink ? typed : ""
                if expression.wrappedValue != e { expression.wrappedValue = e }
            }
            if c != value { value = c }
            text = isLink ? typed : editable(c)
            onCommit?()
        case .empty:
            revert()
        case .failure:
            error = preview.message(for: unit)
        }
    }

    private func revert() {
        error = nil
        suggestions = []
        text = restingText
    }

    private func nudge(_ sign: Double, modifiers: EventModifiers) {
        // A linked value moves with its parameter only; unlink it from the fx marker first.
        guard !isLinked, !preview.isLinked else { return }
        var d = baseStep
        if modifiers.contains(.shift) { d *= 10 }
        if modifiers.contains(.option) { d *= 0.1 }
        let base = preview.number ?? value
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
                guard !isLinked else { return }
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
                guard scrubStart != nil else { return }
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

    /// Keeps the typed expression (B-10): a text naming a parameter is stored in `expression`
    /// and sent to the engine as is, so the value follows the parameter; a plain number clears
    /// it. The caller sends `expression` when it is not empty, else `value`.
    func linked(_ expression: Binding<String>) -> NumberField {
        var f = self
        f.expression = expression
        return f
    }
}

/// How a value field reads its text when parameters are around (B-10).
enum LinkedNumber {
    enum Parsed: Equatable {
        case empty
        /// A plain number or arithmetic, in the field's base unit.
        case value(Double)
        /// An expression that names parameters, evaluated by the engine.
        case linked(Double)
        case failure(VFExpression.Failure?, String?)

        var number: Double? {
            switch self {
            case .value(let v), .linked(let v): v
            default: nil
            }
        }
        var isLinked: Bool { if case .linked = self { true } else { false } }

        func message(for unit: VFUnit) -> String? {
            guard case let .failure(f, m) = self else { return nil }
            return m ?? f?.message(for: unit)
        }
    }

    /// True when `text` names one of `names`: the value is driven, not typed.
    static func linked(_ text: String, names: [String]) -> Bool {
        ParameterContext.identifiers(text).contains { names.contains($0) }
    }

    static func parse(_ text: String, unit: VFUnit, parameters: ParameterContext?) -> Parsed {
        if let parameters, !parameters.references(in: text).isEmpty {
            switch parameters.evaluate(text, unit) {
            case .success(let v): return .linked(v)
            case .failure(let f): return .failure(nil, f.message)
            }
        }
        switch VFExpression(unit: unit).evaluate(text) {
        case .success(let v): return .value(v)
        case .failure(.empty): return .empty
        case .failure(let f):
            if case .syntax = f, let parameters, let w = ParameterContext.identifiers(text).first(where: { !parameters.names.contains($0) && VFUnit.lengthOrAngleWord($0) == false }) {
                return .failure(f, String(localized: "\(w) is not a parameter of this design."))
            }
            return .failure(f, nil)
        }
    }
}

private extension VFUnit {
    /// A unit word a value may carry (mm, in, deg): not a parameter name.
    static func lengthOrAngleWord(_ w: String) -> Bool {
        ["mm", "cm", "m", "in", "ft", "um", "deg", "rad", "g", "kg", "lb", "n", "mpa", "hz", "s", "ms", "pi"].contains(w.lowercased())
    }
}

/// What a custom keypad (T-15) edits: the field's own text, its preview and error, the
/// parameter names it can insert, and the two ways out. The keypad sets `text`; `commit` runs
/// the field's own commit (expression, range, link), `cancel` puts the old value back.
struct NumberKeypadRequest {
    var label: String
    var unit: VFUnit
    var text: Binding<String>
    /// The value the text gives, formatted, or nil while it does not parse.
    var preview: String?
    var error: String?
    var parameterNames: [String]
    var commit: () -> Void
    var cancel: () -> Void
}

/// A keypad the iPad number fields open instead of the system keyboard. Set it once high in
/// the touch tree: `.environment(\.vfNumberKeypad, NumberKeypad { AnyView(MyKeypad(request: $0)) })`.
struct NumberKeypad {
    var content: @MainActor (NumberKeypadRequest) -> AnyView
}

extension EnvironmentValues {
    /// The design's parameters, for linking and completion in every NumberField below.
    @Entry var vfParameters: ParameterContext? = nil
    /// The iPad keypad hook (T-15); nil keeps the system keyboard.
    @Entry var vfNumberKeypad: NumberKeypad? = nil
}
