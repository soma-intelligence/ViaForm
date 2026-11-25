import SwiftUI
import ViaFormFFI

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

// MARK: Command schemas (UI-UX-AUDIT P1-5)

/// A value in a command schema (a field's default): a number, a flag, a text or a list of numbers.
enum FormValue: Hashable, Decodable {
    case number(Double)
    case bool(Bool)
    case text(String)
    case list([Double])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .list(try c.decode([Double].self)) }
    }

    var number: Double? { if case let .number(v) = self { v } else { nil } }
    var flag: Bool? { if case let .bool(v) = self { v } else { nil } }
    var text: String? { if case let .text(v) = self { v } else { nil } }
    var list: [Double]? { if case let .list(v) = self { v } else { nil } }
}

/// One field of a command's form, as the core describes it (`viaform_core::commands`): the key,
/// a label, what it holds (so which control), its unit, default and bounds.
struct CommandField: Decodable, Hashable, Identifiable {
    enum Kind: String, Decodable {
        case length, angle, number, integer, bool, `enum`, string, body, bodies, sketch, edges, faces, point, vector
    }
    let key: String
    let label: String
    let kind: Kind
    var unit: String?
    var `default`: FormValue?
    var min: Double?
    var max: Double?
    var help: String?
    var options: [String]?
    /// Sent only when changed from the default (or, with no default, once switched on).
    var optional: Bool
    var id: String { key }

    var isNumeric: Bool { [.length, .angle, .number, .integer].contains(kind) }
    var numberUnit: VFUnit {
        switch kind {
        case .length, .point: .length
        case .angle: .angle
        default: .none
        }
    }
    var range: ClosedRange<Double>? {
        guard min != nil || max != nil else { return nil }
        return (min ?? -1e9)...(max ?? 1e9)
    }
}

/// The typed form of every registry command the core describes, read once from `sc_commands`.
/// A command missing here (or with a field kind this build does not know) keeps the JSON form.
enum CommandSchemas {
    static let all: [String: [CommandField]] = {
        guard let p = sc_commands() else { return [:] }
        defer { sc_string_free(p) }
        guard let raw = try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [[String: Any]] else { return [:] }
        var out: [String: [CommandField]] = [:]
        for entry in raw {
            guard let id = entry["id"] as? String, let schema = entry["schema"], !(schema is NSNull),
                  let data = try? JSONSerialization.data(withJSONObject: schema),
                  let fields = try? JSONDecoder().decode([CommandField].self, from: data), !fields.isEmpty else { continue }
            out[id] = fields
        }
        return out
    }()

    static func fields(_ id: String) -> [CommandField]? { all[id] }
}

/// What a typed command form holds, kind by kind, and the parameters it sends.
struct CommandFormState: Equatable {
    var numbers: [String: Double] = [:]
    var flags: [String: Bool] = [:]
    /// Enum choices, texts and single body names.
    var texts: [String: String] = [:]
    /// Points and directions.
    var vectors: [String: [Double]] = [:]
    var names: [String: Set<String>] = [:]
    /// Sketch ids; absent means the open or last sketch.
    var sketches: [String: Int] = [:]
    /// Edge and face picks, as points on them.
    var picks: [String: [[Double]]] = [:]
    /// Optional numbers without a default that were switched on.
    var enabled: Set<String> = []
    /// A numeric field's typed expression (a parameter name or a formula, B-10), sent as is
    /// in place of the number when not empty, so the value follows the parameter.
    var expressions: [String: String] = [:]

    /// The defaults, with the model's selection where a field takes it (bodies, edges, faces).
    init(fields: [CommandField], model: DesignModel?) {
        for f in fields {
            switch f.kind {
            case .length, .angle, .number, .integer:
                numbers[f.key] = f.default?.number ?? Swift.max(f.min ?? 0, f.kind == .integer ? 1 : 10)
            case .bool: flags[f.key] = f.default?.flag ?? false
            case .enum: texts[f.key] = f.default?.text ?? f.options?.first ?? ""
            case .string: texts[f.key] = f.default?.text ?? ""
            case .body: texts[f.key] = f.optional ? "" : (model?.selectedBodies.sorted().first ?? "")
            case .bodies: names[f.key] = model?.selectedBodies ?? []
            case .sketch: break
            case .edges: picks[f.key] = model?.selection.filter(\.isEdge).map(\.points) ?? []
            case .faces: picks[f.key] = model?.selection.filter(\.isFace).map(\.points) ?? []
            case .point, .vector: vectors[f.key] = f.default?.list ?? [0, 0, 0]
            }
        }
    }

    /// What a required field still needs, or nil when the form can run.
    func missing(_ fields: [CommandField]) -> String? {
        for f in fields where !f.optional {
            let empty: Bool
            switch f.kind {
            case .body, .string: empty = (texts[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .bodies: empty = names[f.key]?.isEmpty ?? true
            case .edges, .faces: empty = picks[f.key]?.isEmpty ?? true
            default: empty = false
            }
            if empty {
                switch f.kind {
                case .edges: return String(localized: "Pick the edges in the viewport, then choose Use Selection.")
                case .faces: return String(localized: "Pick the faces in the viewport, then choose Use Selection.")
                case .bodies, .body: return String(localized: "Choose the \(f.label.lowercased()) first.")
                default: return String(localized: "\(f.label) is needed.")
                }
            }
        }
        return nil
    }

    /// The command's parameters: lengths and angles as unit expressions (`12.5 mm`, `30 deg`),
    /// so the design's units never change what was typed; optional fields at their default left
    /// out, so the engine's own default applies.
    func params(_ fields: [CommandField]) -> [String: Any] {
        var p: [String: Any] = [:]
        for f in fields {
            let k = f.key
            switch f.kind {
            case .length, .angle, .number, .integer:
                guard let v = numbers[k] else { continue }
                let e = (expressions[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !e.isEmpty {
                    if !(f.optional && f.default == nil && !enabled.contains(k)) { p[k] = e }
                    continue
                }
                if f.default == nil { if f.optional && !enabled.contains(k) { continue } }
                else if f.optional && v == f.default?.number { continue }
                switch f.kind {
                case .length: p[k] = Self.expression(v, "mm")
                case .angle: p[k] = Self.expression(v, "deg")
                case .integer: p[k] = Int(v.rounded())
                default: p[k] = v
                }
            case .bool:
                let v = flags[k] ?? false
                if f.optional && v == (f.default?.flag ?? false) { continue }
                p[k] = v
            case .enum:
                let v = texts[k] ?? ""
                if v.isEmpty || (f.optional && v == f.default?.text) { continue }
                p[k] = v
            case .string, .body:
                let v = (texts[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { p[k] = v }
            case .bodies:
                if let v = names[k], !v.isEmpty { p[k] = v.sorted() }
            case .sketch:
                if let v = sketches[k] { p[k] = v }
            case .edges, .faces:
                if let v = picks[k], !v.isEmpty { p[k] = v }
            case .point, .vector:
                guard let v = vectors[k] else { continue }
                if f.optional && v == f.default?.list { continue }
                p[k] = v
            }
        }
        return p
    }

    /// `12.5 mm`: a plain decimal (never an exponent), trailing zeros dropped.
    static func expression(_ v: Double, _ unit: String) -> String {
        var t = String(format: "%.6f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        if t == "-0" { t = "0" }
        return "\(t) \(unit)"
    }
}

/// Any registry command. A command the core describes gets typed fields (numbers with units and
/// expressions through `NumberField`, toggles, pickers for bodies and sketches, the viewport's
/// picks); any other keeps an Advanced form, its parameter documentation and a JSON object the
/// form checks before running. The button names the verb ("Run Fillet").
struct GenericCommandForm: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: DesignModel
    let command: CommandInfo
    @State private var json = "{}"
    @State private var error: String?
    @State private var confirm: ConfirmRequest?
    @State private var state: CommandFormState
    @State private var initial: CommandFormState
    private let fields: [CommandField]?

    init(model: DesignModel, command: CommandInfo) {
        self.model = model
        self.command = command
        let fields = CommandSchemas.fields(command.id)
        self.fields = fields
        let s = CommandFormState(fields: fields ?? [], model: model)
        _state = State(initialValue: s)
        _initial = State(initialValue: s)
    }

    private var edited: Bool {
        fields == nil ? json.trimmingCharacters(in: .whitespacesAndNewlines) != "{}" : state != initial
    }

    private var verb: String { StageLabels.command(command.label) }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            HStack(spacing: VFSpace.m) {
                CommandIcon(icon: command.icon, id: command.id, size: 16)
                Text(verb).font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
            }
            if let fields {
                ScrollView {
                    VStack(alignment: .leading, spacing: VFSpace.m) {
                        ForEach(fields) { f in fieldRow(f) }
                    }
                    .padding(.vertical, VFSpace.xs)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state) { _, _ in if error != nil, state.missing(fields) == nil { error = nil } }
            } else {
                advanced
            }
            if let error {
                InlineError(error)
            }
            HStack(spacing: VFSpace.m) {
                Button("Cancel", role: .cancel) { cancel() }
                    .buttonStyle(.vfSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Run \(verb)")) { runCommand() }
                    .buttonStyle(.vfPrimary)
                    .keyboardShortcut(.defaultAction)
                    .vfEngineGate()
            }
        }
        .padding(VFSpace.xl)
        .frame(minWidth: 440)
        .background(theme.panel)
        #if os(iOS)
        .interactiveDismissDisabled(edited)
        #endif
        .confirmSheet($confirm)
    }

    // MARK: Typed fields

    @ViewBuilder private func fieldRow(_ f: CommandField) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            control(f)
            if let h = f.help, !h.isEmpty {
                Text(h).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(VFFont.row)
        .foregroundStyle(theme.ink)
    }

    @ViewBuilder private func control(_ f: CommandField) -> some View {
        switch f.kind {
        case .length, .angle, .number, .integer:
            if f.optional && f.default == nil {
                HStack(spacing: VFSpace.m) {
                    Toggle(f.label, isOn: enabledBinding(f.key))
                        .toggleStyle(.vfCheck)
                    Spacer(minLength: VFSpace.m)
                    if state.enabled.contains(f.key) { numberField(f) }
                }
            } else {
                LabeledContent(f.label) { numberField(f) }
            }
        case .bool:
            Toggle(f.label, isOn: Binding(get: { state.flags[f.key] ?? false }, set: { state.flags[f.key] = $0 }))
                .toggleStyle(.vfSwitch)
        case .enum:
            LabeledContent(f.label) {
                VFMenuPicker(f.label, selection: textBinding(f.key), items: f.options ?? [], title: { optionLabel($0) })
            }
        case .string:
            LabeledContent(f.label) {
                TextField(f.label, text: textBinding(f.key))
                    .labelsHidden()
                    .vfField()
                    .frame(width: 200)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
            }
        case .body:
            LabeledContent(f.label) {
                VFMenuPicker(f.label, selection: textBinding(f.key), items: [""] + model.snapshot.bodies.map(\.name),
                             title: { $0.isEmpty ? (f.optional ? String(localized: "None") : String(localized: "Choose a Body")) : $0 })
            }
        case .bodies:
            LabeledContent(f.label) {
                Menu {
                    ForEach(model.snapshot.bodies) { b in
                        Toggle(b.name, isOn: Binding(get: { state.names[f.key]?.contains(b.name) ?? false },
                                                     set: { on in
                                                         var s = state.names[f.key] ?? []
                                                         if on { s.insert(b.name) } else { s.remove(b.name) }
                                                         state.names[f.key] = s
                                                     }))
                    }
                } label: {
                    Text(bodiesSummary(state.names[f.key] ?? []))
                }
                .menuStyle(.vfPill)
            }
        case .sketch:
            LabeledContent(f.label) {
                VFMenuPicker(f.label, selection: Binding(get: { state.sketches[f.key] ?? -1 },
                                                         set: { state.sketches[f.key] = $0 < 0 ? nil : $0 }),
                             items: [-1] + model.snapshot.sketches.map(\.id),
                             title: { id in id < 0 ? String(localized: "Open or Last Sketch")
                                 : (model.snapshot.sketches.first { $0.id == id }?.name ?? "") })
            }
        case .edges, .faces:
            let edges = f.kind == .edges
            let available = model.selection.filter { edges ? $0.isEdge : $0.isFace }.map(\.points)
            let n = state.picks[f.key]?.count ?? 0
            LabeledContent(f.label) {
                HStack(spacing: VFSpace.m) {
                    Text(edges ? String(localized: "\(n) edges picked") : String(localized: "\(n) faces picked"))
                        .foregroundStyle(n == 0 ? theme.inkSecondary : theme.ink)
                    Button("Use Selection") { state.picks[f.key] = available }
                        .buttonStyle(.vfSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .disabled(available.isEmpty)
                        .help(edges ? "Take the edges picked in the viewport" : "Take the faces picked in the viewport")
                }
            }
        case .point, .vector:
            LabeledContent(f.label) {
                HStack(spacing: VFSpace.xs) {
                    ForEach(0..<3, id: \.self) { i in
                        NumberField(["X", "Y", "Z"][i], value: vectorBinding(f.key, i), unit: f.kind == .point ? .length : .none,
                                    step: f.kind == .point ? 1 : 0.1, width: 58, showsUnit: false)
                            .labelHiddenVisually()
                    }
                    if f.kind == .point, let pick = model.selection.first {
                        VFIconButton("scope", label: String(localized: "Use the picked point"), size: 12) {
                            state.vectors[f.key] = pick.points
                        }
                    }
                }
            }
        }
    }

    private func numberField(_ f: CommandField) -> some View {
        NumberField(f.label, value: Binding(get: { state.numbers[f.key] ?? 0 }, set: { state.numbers[f.key] = $0 }),
                    unit: f.numberUnit, range: f.range, step: f.kind == .integer ? 1 : (f.kind == .angle ? 5 : 1), width: 88)
            .labelHiddenVisually()
            .linked(Binding(get: { state.expressions[f.key] ?? "" }, set: { state.expressions[f.key] = $0 }))
    }

    private func enabledBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { state.enabled.contains(key) },
                set: { if $0 { state.enabled.insert(key) } else { state.enabled.remove(key) } })
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { state.texts[key] ?? "" }, set: { state.texts[key] = $0 })
    }

    private func vectorBinding(_ key: String, _ i: Int) -> Binding<Double> {
        Binding(get: { state.vectors[key]?[i] ?? 0 },
                set: { v in
                    var a = state.vectors[key] ?? [0, 0, 0]
                    a[i] = v
                    state.vectors[key] = a
                })
    }

    private func optionLabel(_ o: String) -> String {
        switch o {
        case "": String(localized: "Automatic")
        case "auto": String(localized: "Automatic")
        case "XY", "XZ", "YZ", "X", "Y", "Z": o
        case "x": String(localized: "Sketch X")
        case "y": String(localized: "Sketch Y")
        default: o.prefix(1).uppercased() + o.dropFirst()
        }
    }

    private func bodiesSummary(_ names: Set<String>) -> String {
        switch names.count {
        case 0: String(localized: "Choose Bodies")
        case 1: names.first ?? ""
        default: String(localized: "\(names.count) bodies")
        }
    }

    // MARK: Advanced (no schema): parameters as JSON

    @ViewBuilder private var advanced: some View {
        ScrollView {
            Text(command.params.isEmpty ? String(localized: "This command takes no parameters.") : command.params)
                .font(VFFont.row)
                .foregroundStyle(theme.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
        VFCaption("Advanced: parameters (JSON object)")
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
        if !model.selection.isEmpty {
            Button("Insert Selected Points") {
                let pts = model.selection.map { "[\(fmt($0.point.x)), \(fmt($0.point.y)), \(fmt($0.point.z))]" }.joined(separator: ", ")
                json = edited ? json + " [\(pts)]" : "{\"faces\": [\(pts)]}"
            }
            .buttonStyle(.vfSecondary)
        }
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

    // MARK: Run

    private func runCommand() {
        guard let fields else {
            if let e = validate() { error = e; return }
            let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
            model.runJSON(command.id, text.isEmpty ? "{}" : text)
            close()
            return
        }
        if let m = state.missing(fields) { error = m; return }
        // A failure stays in the form, beside the fields, instead of the window's banner.
        if model.run(command.id, state.params(fields)) == nil {
            error = model.message ?? String(localized: "\(verb) did not run.")
            model.flash(nil)
            return
        }
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

// MARK: Body rename (UI-UX-AUDIT P1-12)

extension DesignModel {
    /// Renames body `old` to `name` (trimmed) through the core's `body.rename`, one undoable step.
    /// Answers nil when done (or when nothing changed), else why not, for an inline error.
    func renameBody(_ old: String, to name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == old { return nil }
        if name.isEmpty { return String(localized: "A body needs a name.") }
        guard run("body.rename", ["body": old, "name": name]) != nil else {
            let why = message ?? String(localized: "The body could not be renamed.")
            flash(nil)
            return why
        }
        if selectedBodies.contains(old) {
            selectedBodies.remove(old)
            selectedBodies.insert(name)
        }
        return nil
    }
}

/// `--selftest` checks for the typed command form and the body rename.
enum CommandFormSelfTest {
    static func checks() -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        let m = DesignModel()
        let box = CommandSchemas.fields("solid.box") ?? []
        let fillet = CommandSchemas.fields("solid.fillet") ?? []
        out.append((box.first?.kind == .length && box.first?.unit == "mm",
                    "P1-5 solid.box has a typed schema (length in mm)"))
        out.append((fillet.map(\.kind).prefix(2) == [.edges, .length], "P1-5 solid.fillet asks for edges and a radius"))
        out.append((CommandSchemas.all.count >= 25, "P1-5 \(CommandSchemas.all.count) commands have typed forms"))

        var s = CommandFormState(fields: box, model: m)
        s.numbers["length"] = 30
        let p = s.params(box)
        out.append((p["length"] as? String == "30 mm" && p["corner"] == nil && p["operation"] == nil,
                    "P1-5 the form sends lengths with units and leaves untouched options out"))
        m.run("solid.box", p)
        let v = m.snapshot.bodies.first?.volume_mm3 ?? 0
        out.append((m.snapshot.bodies.count == 1 && abs(v - 30 * 20 * 20) < 1, "P1-5 Run Box from the typed form (got \(v) mm³)"))
        out.append((CommandFormState(fields: fillet, model: m).missing(fillet) != nil, "P1-5 Run Fillet without edges says what is missing"))

        let old = m.snapshot.bodies.first?.name ?? ""
        out.append((m.renameBody(old, to: "  Lid ") == nil && m.snapshot.bodies.map(\.name) == ["Lid"], "P1-12 a body renames (trimmed)"))
        out.append((m.renameBody("Lid", to: "   ") != nil && m.snapshot.bodies.map(\.name) == ["Lid"], "P1-12 an empty name is refused inline"))
        m.undo()
        out.append((m.snapshot.bodies.map(\.name) == [old], "P1-12 undo gives the old name back"))
        m.run("solid.box", ["length": 5, "width": 5, "height": 5, "corner": [50, 0, 0], "operation": "new", "body_name": "Other"])
        let dup = m.renameBody(old, to: "Other")
        out.append((dup?.contains("Other") == true && m.message == nil, "P1-12 a taken name is refused with the reason (\(dup ?? "none"))"))

        // Edit Feature: the sheet's fields come from timeline.inspect and only changes go out.
        let e = DesignModel()
        e.run("solid.box", ["length": "30 mm", "width": "20 mm", "height": "20 mm"])
        let name = e.snapshot.timeline.first?.name ?? ""
        let def = ((try? e.engine.execute("timeline.inspect", ["feature": name])) as? [String: Any])?["definition"] as? [String: Any] ?? [:]
        let before = FeatureField.flatten(def)
        var after = before
        if let i = after.firstIndex(where: { $0.key.hasSuffix("length") }) { after[i].value = .text("45 mm") }
        let set = FeatureField.changes(from: before, to: after)
        out.append((set.count == 1, "Edit Feature sends only the changed field (\(set.keys.sorted()))"))
        let edited = (try? e.engine.execute("timeline.edit", ["feature": name, "set": set])) != nil
        e.refresh()
        let ev = e.snapshot.bodies.first?.volume_mm3 ?? 0
        out.append((edited && abs(ev - 45 * 20 * 20) < 1, "Edit Feature rebuilds the box at 45 mm (got \(ev) mm³)"))
        return out
    }
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
