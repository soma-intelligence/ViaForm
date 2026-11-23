import SwiftUI

/// A number with its unit, typed or nudged; changes reach the model at once (live preview).
/// A thin wrapper over `NumberField`: units (`25 mm`, `1 in`), expressions that never crash
/// (`2*` is an error beside the field, not an exception), Esc reverts, the arrows step.
struct ValueField: View {
    let label: String
    let unit: String
    @Binding var value: Double
    var step: Double = 1
    var range: ClosedRange<Double>? = nil
    var onCommit: (() -> Void)? = nil

    init(label: String, unit: String, value: Binding<Double>, step: Double = 1,
         range: ClosedRange<Double>? = nil, onCommit: (() -> Void)? = nil) {
        self.label = label
        self.unit = unit
        _value = value
        self.step = step
        self.range = range
        self.onCommit = onCommit
    }

    var body: some View {
        NumberField(label, value: $value, unit: VFUnit(symbol: unit), range: range, step: step, width: 82, onCommit: onCommit)
    }
}

/// Any registry command, run from its parameter documentation and a JSON object. The parameter
/// text of a command is free-form documentation, so the parameters stay a JSON object; the form
/// checks it before running and says what is wrong beside the field.
struct GenericCommandForm: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: DesignModel
    let command: CommandInfo
    @State private var json = "{}"
    @State private var error: String?
    @State private var confirm: ConfirmRequest?

    private var edited: Bool { json.trimmingCharacters(in: .whitespacesAndNewlines) != "{}" }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            HStack(spacing: VFSpace.m) {
                CommandIcon(icon: command.icon, id: command.id, size: 16)
                Text(StageLabels.command(command.label)).font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
            }
            ScrollView {
                Text(command.params.isEmpty ? String(localized: "This command takes no parameters.") : command.params)
                    .font(VFFont.row)
                    .foregroundStyle(theme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            VFCaption("Parameters (JSON object)")
            TextEditor(text: $json)
                .font(VFFont.mono)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous).fill(theme.well))
                .overlay(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                    .strokeBorder(error == nil ? theme.hairline : theme.danger, lineWidth: error == nil ? VFSize.hairline : 1.5))
                .accessibilityLabel(Text("Parameters as a JSON object"))
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: json) { _, _ in if error != nil, validate() == nil { error = nil } }
            if let error {
                InlineError(error)
            }
            if !model.selection.isEmpty {
                Button("Insert Selected Points") {
                    let pts = model.selection.map { "[\(fmt($0.point.x)), \(fmt($0.point.y)), \(fmt($0.point.z))]" }.joined(separator: ", ")
                    json = edited ? json + " [\(pts)]" : "{\"faces\": [\(pts)]}"
                }
                .buttonStyle(.vfSecondary)
            }
            HStack(spacing: VFSpace.m) {
                Button("Cancel", role: .cancel) { cancel() }
                    .buttonStyle(.vfSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Run \(StageLabels.command(command.label))")) { runCommand() }
                    .buttonStyle(.vfPrimary)
                    .keyboardShortcut(.defaultAction)
                    .vfEngineGate()
            }
        }
        .padding(VFSpace.xl)
        .frame(minWidth: 420)
        .background(theme.panel)
        #if os(iOS)
        .interactiveDismissDisabled(edited)
        #endif
        .confirmSheet($confirm)
    }

    /// Nil when the text is a JSON object; otherwise what to fix.
    private func validate() -> String? {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return String(localized: "The parameters are not valid JSON. Check the brackets, quotes and commas.")
        }
        guard parsed is [String: Any] else {
            return String(localized: "The parameters must be one object in braces, for example {\"distance\": 10}.")
        }
        return nil
    }

    private func runCommand() {
        if let e = validate() { error = e; return }
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        model.runJSON(command.id, text.isEmpty ? "{}" : text)
        close()
    }

    private func cancel() {
        guard edited else { close(); return }
        confirm = ConfirmRequest(title: String(localized: "Discard these parameters?"),
                                 message: String(localized: "The command does not run and the parameters you typed are lost."),
                                 verb: String(localized: "Discard"), destructive: true, perform: close)
    }

    private func close() {
        model.genericCommand = nil
        dismiss()
    }

    private func fmt(_ v: Double) -> String { String(format: "%.4g", v) }
}

/// The status line: the last error, or a result the user asked for. Errors use the shared
/// ErrorBanner; results a short floating line with the theme's accent.
struct MessageBanner: View {
    @Environment(\.viaFormTheme) private var theme
    let model: DesignModel

    var body: some View {
        if let m = model.message {
            if model.messageIsError {
                ErrorBanner(message: m) { model.flash(nil) }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: VFSpace.m) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(theme.accentText)
                        .accessibilityHidden(true)
                    Text(m)
                        .font(VFFont.row)
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                        .lineLimit(6)
                    Spacer(minLength: 0)
                    VFIconButton("xmark", label: String(localized: "Dismiss"), size: 10) { model.flash(nil) }
                }
                .padding(.horizontal, VFSpace.l)
                .padding(.vertical, VFSpace.xs)
                .vfSurface(.floating)
                .frame(maxWidth: 520)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Feature type to a symbol, for timelines.
enum FeatureSymbol {
    static func of(_ type: String) -> String {
        let t = type.lowercased()
        if t.contains("sketch") { return "pencil.and.outline" }
        if t.contains("extrude") { return "square.stack.3d.up" }
        if t.contains("revolve") { return "arrow.triangle.2.circlepath" }
        if t.contains("fillet") { return "square.dashed.inset.filled" }
        if t.contains("chamfer") { return "skew" }
        if t.contains("shell") { return "cube.transparent" }
        if t.contains("box") || t.contains("primitive") { return "cube" }
        if t.contains("cylinder") { return "cylinder" }
        if t.contains("sphere") { return "circle.circle" }
        if t.contains("hole") { return "circle.bottomhalf.filled" }
        if t.contains("pattern") { return "square.grid.3x3" }
        if t.contains("mirror") { return "arrow.left.and.right" }
        if t.contains("combine") { return "square.on.square" }
        if t.contains("move") { return "move.3d" }
        if t.contains("import") { return "square.and.arrow.down" }
        if t.contains("plane") { return "square.3.layers.3d" }
        if t.contains("press") { return "arrow.up.and.down.square" }
        if t.contains("remove") || t.contains("delete") { return "trash" }
        return "gearshape"
    }
}
