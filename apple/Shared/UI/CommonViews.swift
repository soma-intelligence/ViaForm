import SwiftUI

/// A number with its unit, typed or nudged; changes reach the model at once (live preview).
struct ValueField: View {
    let label: String
    let unit: String
    @Binding var value: Double
    var step: Double = 1

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 82)
                .focused($focused)
                .onSubmit(commit)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
            if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
            Stepper("", value: $value, step: step).labelsHidden()
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, v in if !focused { text = format(v) } }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.3g", v)
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        if let v = Double(cleaned) { value = v } else if let v = evaluate(cleaned) { value = v }
        text = format(value)
    }

    /// Simple arithmetic (`10*2`, `30/4+1`), as a CAD value field takes it.
    private func evaluate(_ s: String) -> Double? {
        let allowed = CharacterSet(charactersIn: "0123456789.+-*/() ")
        guard !s.isEmpty, s.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let e = NSExpression(format: s)
        return (e.expressionValue(with: nil, context: nil) as? NSNumber)?.doubleValue
    }
}

/// Any registry command, run from its parameter documentation and a JSON object.
struct GenericCommandForm: View {
    let model: DesignModel
    let command: CommandInfo
    @State private var json = "{}"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: CommandSymbol.of(command.icon, id: command.id))
                Text(command.label).font(.headline)
                Spacer()
                Text(command.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ScrollView {
                Text(command.params.isEmpty ? "No parameters." : command.params)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            Text("Parameters (JSON)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $json)
                .font(.body.monospaced())
                .frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !model.selection.isEmpty {
                Button("Insert selected points") {
                    let pts = model.selection.map { "[\(fmt($0.point.x)), \(fmt($0.point.y)), \(fmt($0.point.z))]" }.joined(separator: ", ")
                    json = json.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" ? "{\"faces\": [\(pts)]}" : json + " [\(pts)]"
                }
                .font(.caption)
            }
            HStack {
                Button("Cancel") { model.genericCommand = nil; dismiss() }
                Spacer()
                Button("OK") {
                    model.runJSON(command.id, json)
                    model.genericCommand = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.4g", v) }
}

/// The status line: the last error, or a result the user asked for.
struct MessageBanner: View {
    let model: DesignModel

    var body: some View {
        if let m = model.message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.messageIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(model.messageIsError ? .orange : .accentColor)
                Text(m).font(.callout).textSelection(.enabled).lineLimit(6)
                Button { model.flash(nil) } label: { Image(systemName: "xmark").font(.caption.bold()) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .frame(maxWidth: 520)
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
