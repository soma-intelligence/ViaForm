#if os(iOS)
import SwiftUI

// The value keypad of the iPad (gap T-15): a popover with the field's name, the typed value big,
// digits, the four operators, plus or minus, backspace and a tall check key. What is typed goes
// through `VFExpression`, as in every number field ("25+3*2", "1 in + 3").
//
// One hook: `NumberField` opens whatever `vfNumberKeypad` the environment holds. The Touch root
// sets it once with `.touchNumberKeypad()`: on a regular width (iPad) every NumberField opens
// this keypad in a popover; on a compact width (iPhone, narrow iPad window) the hook stays nil
// and the field keeps the system keyboard.

/// The keys and what they type.
enum TouchKey: String, CaseIterable, Identifiable {
    case d7 = "7", d8 = "8", d9 = "9", divide = "÷"
    case d4 = "4", d5 = "5", d6 = "6", multiply = "×"
    case d1 = "1", d2 = "2", d3 = "3", minus = "−"
    case sign = "±", d0 = "0", point = ".", plus = "+"
    case backspace = "⌫", clear = "C", commit = "✓"

    var id: String { rawValue }

    /// The grid, row by row (backspace, clear and commit sit in their own column).
    static let grid: [[TouchKey]] = [[.d7, .d8, .d9, .divide], [.d4, .d5, .d6, .multiply], [.d1, .d2, .d3, .minus], [.sign, .d0, .point, .plus]]

    /// What the key adds to the text (operators as `VFExpression` reads them).
    var typed: String? {
        switch self {
        case .divide: "/"
        case .multiply: "*"
        case .minus: "-"
        case .plus: "+"
        case .point: "."
        case .sign, .backspace, .clear, .commit: nil
        default: rawValue
        }
    }

    var isOperator: Bool { [.divide, .multiply, .minus, .plus].contains(self) }

    var spoken: String {
        switch self {
        case .divide: String(localized: "Divide")
        case .multiply: String(localized: "Multiply")
        case .minus: String(localized: "Minus")
        case .plus: String(localized: "Plus")
        case .sign: String(localized: "Change sign")
        case .point: String(localized: "Decimal point")
        case .backspace: String(localized: "Delete")
        case .clear: String(localized: "Clear")
        case .commit: String(localized: "Done")
        default: rawValue
        }
    }
}

/// The keypad's text and its value: plain string editing, evaluation by `VFExpression`.
struct TouchKeypadState: Equatable {
    var text: String
    var unit: VFUnit
    /// The first key replaces the shown value instead of adding to it.
    var fresh = true

    init(value: Double?, unit: VFUnit) {
        self.unit = unit
        text = value.map { VFFormat.editable(VFFormat.toDisplay($0, unit)) } ?? ""
    }

    /// `fresh`: the first digit replaces `text` (a keypad opened on a field's shown value).
    init(text: String, unit: VFUnit, fresh: Bool = false) {
        self.text = text
        self.unit = unit
        self.fresh = fresh
    }

    mutating func press(_ k: TouchKey) {
        switch k {
        case .backspace:
            if !text.isEmpty { text.removeLast() }
        case .clear:
            text = ""
        case .sign:
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-(") && t.hasSuffix(")") { text = String(t.dropFirst(2).dropLast()) }
            else if t.hasPrefix("-"), Double(t) != nil { text = String(t.dropFirst()) }
            else if Double(t) != nil { text = "-" + t }
            else if !t.isEmpty { text = "-(" + t + ")" }
        case .commit:
            break
        default:
            guard let s = k.typed else { break }
            // A digit after the shown value starts over; an operator carries on from it.
            if fresh, !k.isOperator { text = "" }
            if k.isOperator, let last = text.last, "+-*/".contains(last) { text.removeLast() }
            text += s
        }
        fresh = false
    }

    mutating func press(_ keys: [TouchKey]) { for k in keys { press(k) } }

    /// The value in the base unit, or why the text does not parse.
    var result: Result<Double, VFExpression.Failure> { VFExpression(unit: unit).evaluate(text) }

    /// The text as shown: `*` and `/` drawn as × and ÷.
    var shown: String { text.replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷") }
}

/// The keypad popover. It edits the field's own text (`request.text`) key by key; the field
/// parses it (units, parameters), shows the preview and error, and commits through its own path.
struct TouchValueKeypad: View {
    @Environment(\.viaFormTheme) private var theme
    let request: NumberKeypadRequest
    @State private var state: TouchKeypadState

    private let key: CGFloat = 58

    init(request: NumberKeypadRequest) {
        self.request = request
        _state = State(initialValue: TouchKeypadState(text: request.text.wrappedValue, unit: request.unit, fresh: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack {
                Text(request.label).font(VFFont.rowEmphasis).foregroundStyle(theme.inkSecondary).lineLimit(1)
                Spacer()
                Button(action: request.cancel) {
                    Image(systemName: "xmark").font(VFFont.glyph(14, weight: .semibold)).foregroundStyle(theme.inkSecondary)
                        .frame(width: VFSize.touchTarget, height: VFSize.touchTarget).contentShape(Rectangle())
                }
                .buttonStyle(.vfTouch)
                .accessibilityLabel(Text("Cancel"))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(state.shown.isEmpty ? " " : state.shown).font(VFFont.hud).foregroundStyle(state.fresh ? theme.inkSecondary : theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                if !VFFormat.symbol(state.unit).isEmpty {
                    Text(VFFormat.symbol(state.unit)).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Value"))
            .accessibilityValue(state.shown)
            Text(previewText).font(VFFont.small).foregroundStyle(request.error != nil ? theme.danger : theme.inkSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !request.parameterNames.isEmpty { parameterRow }
            HStack(alignment: .top, spacing: VFSpace.s) {
                Grid(horizontalSpacing: VFSpace.s, verticalSpacing: VFSpace.s) {
                    ForEach(Array(TouchKey.grid.enumerated()), id: \.offset) { _, row in
                        GridRow { ForEach(row) { k in keyButton(k) } }
                    }
                }
                VStack(spacing: VFSpace.s) {
                    keyButton(.backspace)
                    keyButton(.clear)
                    Button(action: request.commit) {
                        Image(systemName: "checkmark").font(VFFont.glyph(22, weight: .bold)).foregroundStyle(theme.onAccent)
                            .frame(width: key, height: key * 2 + VFSpace.s)
                            .background(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous).fill(theme.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.vfTouch)
                    .vfDisabled(request.preview == nil && !state.text.trimmingCharacters(in: .whitespaces).isEmpty,
                                reason: String(localized: "Type a number"))
                    .accessibilityLabel(TouchKey.commit.spoken)
                }
            }
        }
        .padding(VFSpace.xl)
        .frame(width: 4 * key + 5 * VFSpace.s + key + 2 * VFSpace.xl)
        .background(theme.panel)
    }

    /// The design's parameters: a tap types the name (the field links the value to it).
    private var parameterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VFSpace.s) {
                ForEach(request.parameterNames, id: \.self) { name in
                    Button { type(name) } label: {
                        Label(name, systemImage: "function").font(VFFont.row).foregroundStyle(theme.accentText)
                            .padding(.horizontal, VFSpace.m).frame(minHeight: VFSize.touchTarget)
                            .background(Capsule().fill(theme.well))
                    }
                    .buttonStyle(.vfTouch)
                    .accessibilityLabel(Text("Insert parameter \(name)"))
                }
            }
        }
    }

    private func keyButton(_ k: TouchKey) -> some View {
        Button { press(k) } label: {
            Group {
                if k == .backspace { Image(systemName: "delete.left").font(VFFont.glyph(19, weight: .medium)) }
                else { Text(k.rawValue).font(VFFont.heading) }
            }
            .foregroundStyle(k.isOperator ? theme.accentText : theme.ink)
            .frame(width: key, height: key)
            .background(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous).fill(k.isOperator ? theme.accent.opacity(0.12) : theme.well))
            .contentShape(Rectangle())
        }
        .buttonStyle(.vfTouch)
        .accessibilityLabel(k.spoken)
    }

    private func press(_ k: TouchKey) {
        state.press(k)
        request.text.wrappedValue = state.text
    }

    private func type(_ word: String) {
        state.type(word)
        request.text.wrappedValue = state.text
    }

    private var previewText: String {
        if let e = request.error { return e }
        if let p = request.preview { return "= " + p }
        return state.text.trimmingCharacters(in: .whitespaces).isEmpty ? " " : String(localized: "Not a number yet")
    }
}

extension TouchKeypadState {
    /// Types a word (a parameter name): replaces a fresh value, else follows the text.
    mutating func type(_ word: String) {
        if fresh { text = "" }
        text += word
        fresh = false
    }
}

/// The keypad behind every NumberField on the iPad (T-15): the one `vfNumberKeypad` hook.
@MainActor
enum TouchNumberKeypad {
    static var hook: NumberKeypad {
        NumberKeypad { request in
            AnyView(TouchValueKeypad(request: request)
                .presentationCompactAdaptation(.popover)
                .viaFormTheme())
        }
    }
}

/// Sets the keypad hook on a regular width only: the iPhone keeps the system keyboard.
private struct TouchNumberKeypadModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize

    func body(content: Content) -> some View {
        content.environment(\.vfNumberKeypad, hSize == .regular ? TouchNumberKeypad.hook : nil)
    }
}

extension View {
    /// Set once at the Touch root: on the iPad every NumberField below opens the value keypad.
    func touchNumberKeypad() -> some View { modifier(TouchNumberKeypadModifier()) }
}
#endif
