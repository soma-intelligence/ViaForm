import SwiftUI

/// One editable value of a feature's definition, as `timeline.inspect` returns it.
/// `key` is dotted (`extent.distance`), the form `timeline.edit` takes in `set`.
struct FeatureField: Identifiable, Equatable {
    enum Value: Equatable {
        case text(String)
        case number(Double)
        case flag(Bool)
    }
    var key: String
    var value: Value
    var id: String { key }

    /// `extent.distance` reads "Extent distance".
    var label: String {
        let words = key.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The leaves of a definition: texts (expressions, enum choices), numbers and flags.
    /// Lists (profiles, edges, faces) are references to geometry and stay out of the form,
    /// as does `type`, which an edit cannot change.
    static func flatten(_ definition: [String: Any], prefix: String = "") -> [FeatureField] {
        var out: [FeatureField] = []
        for k in definition.keys.sorted() {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            if prefix.isEmpty, k == "type" { continue }
            switch definition[k] {
            case let o as [String: Any]: out += flatten(o, prefix: key)
            case let s as String: out.append(FeatureField(key: key, value: .text(s)))
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() {
                    out.append(FeatureField(key: key, value: .flag(n.boolValue)))
                } else {
                    out.append(FeatureField(key: key, value: .number(n.doubleValue)))
                }
            default: continue
            }
        }
        return out
    }

    /// The `set` object for `timeline.edit`: only the fields that changed, by dotted key.
    static func changes(from before: [FeatureField], to after: [FeatureField]) -> [String: Any] {
        var set: [String: Any] = [:]
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.key, $0.value) })
        for f in after where old[f.key] != f.value {
            switch f.value {
            case .text(let s): set[f.key] = s.trimmingCharacters(in: .whitespacesAndNewlines)
            case .number(let n): set[f.key] = n
            case .flag(let b): set[f.key] = b
            }
        }
        return set
    }
}

/// What the Edit Feature sheet opens on.
struct FeatureEditRequest: Identifiable {
    var feature: String
    var id: String { feature }
}

/// Edit Feature: loads the feature's definition with `timeline.inspect`, shows its values,
/// and sends only what changed to `timeline.edit` (one undo step). The engine checks the
/// values; a refused edit keeps the sheet open with the engine's message.
struct EditFeatureSheet: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: DesignModel
    let feature: String
    @State private var initial: [FeatureField] = []
    @State private var fields: [FeatureField] = []
    @State private var typeName = ""
    @State private var error: String?
    @State private var loaded = false
    /// A number field's typed expression (a parameter name or a formula, B-10), sent as is.
    @State private var expressions: [String: String] = [:]

    private var set: [String: Any] {
        var s = FeatureField.changes(from: initial, to: fields)
        for (k, e) in expressions {
            let t = e.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { s[k] = t }
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                Text("Edit \(feature)").font(VFFont.title).foregroundStyle(theme.ink)
                if !typeName.isEmpty {
                    Text(typeName).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
            if loaded && fields.isEmpty && error == nil {
                Text("This feature has no values to edit here.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary)
            }
            if !fields.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: VFSpace.m) {
                        ForEach($fields) { $f in row($f) }
                    }
                    .padding(.vertical, VFSpace.xs)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error { InlineError(error) }
            HStack(spacing: VFSpace.m) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.vfSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { apply() }
                    .buttonStyle(.vfPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(set.isEmpty)
                    .vfEngineGate()
            }
        }
        .padding(VFSpace.xl)
        .frame(minWidth: 440)
        .background(theme.panel)
        #if os(iOS)
        .interactiveDismissDisabled(!set.isEmpty)
        #endif
        .onAppear(perform: load)
    }

    @ViewBuilder private func row(_ f: Binding<FeatureField>) -> some View {
        let label = f.wrappedValue.label
        Group {
            switch f.wrappedValue.value {
            case .flag:
                Toggle(label, isOn: Binding(
                    get: { if case .flag(let b) = f.wrappedValue.value { return b }; return false },
                    set: { f.wrappedValue.value = .flag($0) }))
            case .number:
                let key = f.wrappedValue.key
                LabeledContent(label) {
                    NumberField(label, value: Binding(
                        get: { if case .number(let n) = f.wrappedValue.value { return n }; return 0 },
                        set: { f.wrappedValue.value = .number($0) }), width: 120)
                        .labelHiddenVisually()
                        .linked(Binding(get: { expressions[key] ?? "" }, set: { expressions[key] = $0 }))
                }
            case .text:
                LabeledContent(label) {
                    TextField(label, text: Binding(
                        get: { if case .text(let s) = f.wrappedValue.value { return s }; return "" },
                        set: { f.wrappedValue.value = .text($0) }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 200)
                }
            }
        }
        .font(VFFont.row)
        .foregroundStyle(theme.ink)
    }

    private func load() {
        do {
            let r = try model.engine.execute("timeline.inspect", ["feature": feature]) as? [String: Any] ?? [:]
            typeName = r["type_name"] as? String ?? ""
            let def = r["definition"] as? [String: Any] ?? [:]
            initial = FeatureField.flatten(def)
            fields = initial
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func apply() {
        let set = set
        guard !set.isEmpty else { return }
        do {
            _ = try model.engine.execute("timeline.edit", ["feature": feature, "set": set])
            model.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Edit Feature, Edit Sketch, Redefine Sketch Plane (M-2)

/// Entry points the timeline (a tile's double-click and context menu) and the browser call. They
/// take the model, so any view that has one can open a feature: features with a tool of their
/// own (Extrude, Revolve, Fillet, Chamfer, Shell) reopen that tool's dialog with their values
/// and a live preview, and commit through `timeline.edit`; others fall back to the sheet.
@MainActor
enum FeatureEditor {
    /// Opens `feature` (id or name) in its own dialog. `fallback` runs when the feature has
    /// none (show `EditFeatureSheet` then). A sketch opens for editing.
    static func edit(_ model: DesignModel, feature: String, fallback: () -> Void) {
        if let sketch = sketchID(model, feature: feature) {
            editSketch(model, sketch: sketch)
            return
        }
        if !FeatureSession.of(model).beginEdit(feature) { fallback() }
    }

    /// True when `feature` reopens in a tool dialog (no sheet needed).
    static func hasDialog(_ model: DesignModel, feature: String) -> Bool {
        guard let type = model.snapshot.timeline.first(where: { $0.name == feature || String($0.id) == feature })?.type else { return false }
        return FeatureSession.tool(forFeatureType: type) != nil
    }

    /// The sketch a timeline sketch feature stands for, or nil for other features.
    static func sketchID(_ model: DesignModel, feature: String) -> Int? {
        guard let f = model.snapshot.timeline.first(where: { $0.name == feature || String($0.id) == feature }), f.type.lowercased() == "sketch" else { return nil }
        if let s = model.snapshot.sketches.first(where: { $0.name == f.name }) { return s.id }
        let r = (try? model.engine.execute("timeline.inspect", ["feature": f.name])) as? [String: Any]
        return (r?["definition"] as? [String: Any])?["sketch"] as? Int
    }

    /// Edit Sketch: rolls the history to the sketch, opens it and looks at it; Finish Sketch
    /// rolls back to where the marker was (`restore_marker`).
    static func editSketch(_ model: DesignModel, sketch: Int) {
        if model.tool != .select { FeatureSession.of(model).cancel() }
        if model.sketchOpen { model.finishSketch() }
        let marker = model.snapshot.marker
        let atEnd = marker == 0 || marker >= model.snapshot.timeline.count
        guard model.run("sketch.edit", ["sketch": sketch, "restore_marker": atEnd ? NSNull() : marker as Any], quiet: true) != nil else { return }
        if let plane = model.sketchPlane { model.look(along: plane.normal) }
        model.tool = .select
    }

    /// Redefine Sketch Plane: moves the sketch to a standard plane ("XY", "XZ", "YZ") or a
    /// planar face (`["face": [x, y, z]]`), keeping its geometry and dimension names.
    @discardableResult
    static func redefineSketchPlane(_ model: DesignModel, sketch: Int, plane: Any) -> Bool {
        model.run("sketch.redefine", ["sketch": sketch, "plane": plane]) != nil
    }

    /// Redefine onto the picked face, when one is picked.
    @discardableResult
    static func redefineOnSelectedFace(_ model: DesignModel, sketch: Int) -> Bool {
        guard let f = model.selection.last(where: \.isFace) else {
            model.flash(String(localized: "Select a planar face first"), error: true)
            return false
        }
        return redefineSketchPlane(model, sketch: sketch, plane: ["face": f.points])
    }
}

/// The sketch items of a timeline tile's context menu: Edit Sketch, and Redefine Sketch Plane
/// with the standard planes and the picked face.
struct SketchTileMenuItems: View {
    let model: DesignModel
    let sketch: Int

    var body: some View {
        Button("Edit Sketch") { FeatureEditor.editSketch(model, sketch: sketch) }
        Menu("Redefine Sketch Plane") {
            ForEach(["XY", "XZ", "YZ"], id: \.self) { p in
                Button(String(localized: "\(p) Plane")) { FeatureEditor.redefineSketchPlane(model, sketch: sketch, plane: p) }
            }
            Divider()
            Button("Selected Face") { FeatureEditor.redefineOnSelectedFace(model, sketch: sketch) }
                .disabled(!model.selection.contains(where: \.isFace))
        }
    }
}
