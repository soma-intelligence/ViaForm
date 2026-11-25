import SwiftUI
import simd

// The typed rows of the feature dialogs (B-7, M-4, M-5): one view for the Mac command dialog
// and the touch tool card, in Fusion's field order. Extrude: Profile, Direction, Extent,
// Distance (or the To Object pick), Distance 2, Taper Angle, Operation, Objects To Cut.
// Revolve: Profile, Axis, Type, Direction, Angle, Angle 2, Operation. Fillet: Edges, Type,
// Radius, Tangent Chain. Chamfer: Edges, Type, Distance, Distance 2 or Angle, Flip, Tangent
// Chain. Shell: Faces, Thickness, Direction, Tangent Chain.

/// A Fusion-style selection row: the label, then a button that reads "N selected" (accent while
/// the dialog waits for this pick) with a clear button once something is picked.
struct SelectionButtonRow: View {
    @Environment(\.viaFormTheme) private var theme
    let label: String
    let text: String
    var count: Int = 0
    /// The dialog waits for this pick (the button is lit).
    var active = false
    var touch = false
    var labelWidth: CGFloat = 70
    var activate: (() -> Void)? = nil
    var clear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: VFSpace.s) {
            Text(label).font(touch ? VFFont.row : .callout).foregroundStyle(theme.inkSecondary)
                .frame(width: touch ? nil : labelWidth, alignment: .leading)
            if touch { Spacer(minLength: 0) }
            Button { activate?() } label: {
                HStack(spacing: VFSpace.xs) {
                    Image(systemName: "cursorarrow.click").accessibilityHidden(true)
                    Text(text).lineLimit(1)
                }
                .font(touch ? VFFont.row : .callout)
                .foregroundStyle(active ? theme.onAccent : (count > 0 ? theme.ink : theme.accentText))
                .padding(.horizontal, VFSpace.m)
                .frame(minHeight: touch ? VFSize.touchTarget : 22)
                .background(RoundedRectangle(cornerRadius: VFRadius.control, style: .continuous)
                    .fill(active ? theme.accent : theme.accent.opacity(count > 0 ? 0.10 : 0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(activate == nil)
            .accessibilityLabel("\(label): \(text)")
            if count > 0, let clear {
                VFIconButton("xmark.circle.fill", label: String(localized: "Clear \(label)"), size: touch ? 15 : 11, action: clear)
            }
            if !touch { Spacer(minLength: 0) }
        }
        .frame(minHeight: touch ? VFSize.touchTarget : nil)
    }
}

/// The rows of the five typed feature dialogs, new or edited.
struct FeatureDialogFields: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: DesignModel
    @Bindable var session: FeatureSession
    var touch = false
    var labelWidth: CGFloat = 70
    /// The main value field's focus, so the dialog knows when Return belongs to the field.
    var valueFocus: Binding<Bool>? = nil
    /// Return in the main value field, after it committed.
    var onValueReturn: (() -> Void)? = nil

    private var tool: Tool { session.tool }
    private var editing: Bool { session.editing != nil }

    var body: some View {
        let _ = units
        VStack(alignment: .leading, spacing: touch ? VFSpace.s : VFSpace.m + VFSpace.xxs) {
            switch tool {
            case .extrude: extrude
            case .revolve: revolve
            case .fillet: blend(chamfer: false)
            case .chamfer: blend(chamfer: true)
            case .shell: shell
            default: EmptyView()
            }
            if let e = session.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(VFFont.small).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(FeatureSessionSync(model: model))
    }

    // MARK: Tools

    @ViewBuilder private var extrude: some View {
        // Fusion's Type row: Extrude or Thin Extrude. An edit keeps the type it was made with.
        if !editing {
            picker(String(localized: "Type"), [false, true], $session.options.thin) { $0 ? String(localized: "Thin Extrude") : String(localized: "Extrude") }
        }
        if !session.options.thin { profileRow }
        picker(String(localized: "Direction"), FeatureOptions.Direction.allCases, $session.options.direction) { $0.title }
        picker(String(localized: "Extent Type"), FeatureOptions.Extent.allCases, $session.options.extent) { $0.title(revolve: false) }
        switch session.options.extent {
        case .distance: valueRow
        case .toObject: toObjectRow
        case .all: EmptyView()
        }
        if session.options.direction == .twoSides, session.options.extent != .all {
            numberRow(String(localized: "Distance 2"), $session.options.second, unit: .length)
        }
        numberRow(String(localized: "Taper Angle"), $session.options.taper, unit: .angle, step: 1, range: -89...89)
        if session.options.thin {
            picker(String(localized: "Wall Location"), FeatureOptions.WallLocation.allCases, $session.options.wallLocation) { $0.title }
            numberRow(String(localized: "Wall Thickness"), $session.options.wallThickness, unit: .length, step: 0.5, range: 0.01...10_000)
        }
        operationRow
        objectsRow
    }

    @ViewBuilder private var revolve: some View {
        profileRow
        if !editing {
            picker(String(localized: "Axis"), ["x", "y", "X", "Y", "Z"], Binding(get: { model.revolveAxis }, set: {
                model.revolveAxis = $0
                if session.ownsPreview { session.sync() } else { model.applyPreview() }
            })) { a in a == "x" || a == "y" ? String(localized: "Sketch \(a)") : a }
        }
        picker(String(localized: "Type"), FeatureOptions.Extent.allCases, $session.options.extent) { e in
            e == .all ? String(localized: "Full") : e.title(revolve: true)
        }
        if session.options.extent != .all {
            picker(String(localized: "Direction"), FeatureOptions.Direction.allCases, $session.options.direction) { $0.title }
        }
        switch session.options.extent {
        case .distance: valueRow
        case .toObject: toObjectRow
        case .all: EmptyView()
        }
        if session.options.direction == .twoSides, session.options.extent == .distance {
            numberRow(String(localized: "Angle 2"), $session.options.second, unit: .angle, step: 15)
        }
        operationRow
        objectsRow
    }

    @ViewBuilder private func blend(chamfer: Bool) -> some View {
        picksRow(edges: true)
        if chamfer {
            picker(String(localized: "Type"), FeatureOptions.ChamferType.allCases, $session.options.chamferType) { $0.title }
            valueRow
            switch session.options.chamferType {
            case .equal: EmptyView()
            case .twoDistances: numberRow(String(localized: "Distance 2"), $session.options.chamferDistance2, unit: .length, step: 0.5)
            case .distanceAngle: numberRow(String(localized: "Angle"), $session.options.chamferAngle, unit: .angle, step: 5, range: 1...89)
            }
            toggle(String(localized: "Flip"), $session.options.flip)
        } else {
            picker(String(localized: "Type"), FeatureOptions.FilletType.allCases, $session.options.filletType) { $0.title }
            valueRow
        }
        toggle(String(localized: "Tangent Chain"), $session.options.tangentChain)
    }

    @ViewBuilder private var shell: some View {
        picksRow(edges: false)
        valueRow
        picker(String(localized: "Direction"), FeatureOptions.ShellDirection.allCases, $session.options.shellDirection) { $0.title }
        toggle(String(localized: "Tangent Chain"), $session.options.tangentChain)
    }

    // MARK: Rows

    @ViewBuilder private var profileRow: some View {
        if editing {
            SelectionButtonRow(label: String(localized: "Profile"), text: String(localized: "As defined"), count: 1, touch: touch, labelWidth: labelWidth)
        } else {
            let total = model.sketchInfo?.profiles.count ?? 0
            let picked = model.extrudeProfiles.count
            let text = model.sketchOpen ? String(localized: "Open sketch")
                : (picked == 0 ? String(localized: "All \(total)") : String(localized: "\(picked) of \(total)"))
            SelectionButtonRow(label: String(localized: "Profile"), text: text, count: picked, active: total > 1 && picked == 0,
                               touch: touch, labelWidth: labelWidth, activate: {},
                               clear: { model.extrudeProfiles = []; if session.ownsPreview { session.sync() } else { model.applyPreview() } })
        }
    }

    @ViewBuilder private func picksRow(edges: Bool) -> some View {
        let n = model.selection.filter { edges ? $0.isEdge : $0.isFace }.count
        let label = edges ? String(localized: "Edges") : String(localized: "Faces")
        if let e = session.editing, n == 0 {
            SelectionButtonRow(label: label, text: String(localized: "\(e.picks) kept"), count: 0, touch: touch, labelWidth: labelWidth, activate: {})
        } else {
            SelectionButtonRow(label: label, text: n == 0 ? String(localized: "Select") : String(localized: "\(n) selected"), count: n,
                               active: n == 0, touch: touch, labelWidth: labelWidth, activate: {},
                               clear: {
                                   model.selection = []
                                   if session.editing != nil { session.previewEdit() } else if session.ownsPreview { session.sync() } else { model.applyPreview() }
                               })
        }
    }

    private var toObjectRow: some View {
        let set = session.options.toPoint != nil
        return SelectionButtonRow(label: String(localized: "Object"),
                                  text: set ? String(localized: "1 face") : (session.pickingToObject ? String(localized: "Click a face") : String(localized: "Select")),
                                  count: set ? 1 : 0, active: session.pickingToObject || !set, touch: touch, labelWidth: labelWidth,
                                  activate: { session.beginToObjectPick() },
                                  clear: { session.options.toPoint = nil; session.pickingToObject = true })
    }

    @ViewBuilder private var valueRow: some View {
        if let v = tool.value {
            let binding = Binding(get: { session.value }, set: { session.value = $0 })
            let unit = VFUnit(symbol: v.unit)
            let step = v.unit == "deg" ? 15.0 : 1
            row(v.label) {
                if let valueFocus {
                    NumberField(v.label, value: binding, unit: unit, step: step, width: touch ? 82 : 82)
                        .labelHiddenVisually()
                        .focusBinding(valueFocus)
                        .submitNext(.done) { onValueReturn?() }
                } else {
                    NumberField(v.label, value: binding, unit: unit, step: step, width: 82)
                        .labelHiddenVisually()
                        .submitNext(.done) { onValueReturn?() }
                }
            }
            if touch {
                Slider(value: binding, in: Self.range(v.unit, v.initial, session.value)) { Text(v.label) }
                    .frame(minHeight: VFSize.touchTarget)
                    .accessibilityValue(VFFormat.value(session.value, unit))
            }
        }
    }

    @ViewBuilder private var operationRow: some View {
        let ops: [String] = editing ? ["new_body", "join", "cut", "intersect"] : ["auto", "new_body", "join", "cut", "intersect"]
        picker(String(localized: "Operation"), ops, Binding(get: { session.operation }, set: { session.operation = $0 })) { op in
            let name = Self.operationTitle(op)
            return op == "cut" && session.autoCut ? String(localized: "\(name) (auto)") : name
        }
    }

    /// Objects To Cut (or to join or intersect): every body, ticked when the feature changes it.
    @ViewBuilder private var objectsRow: some View {
        let op = session.operation
        let bodies = model.snapshot.bodies.map(\.name)
        if ["cut", "intersect", "join"].contains(op), bodies.count > 1 {
            let title = op == "cut" ? String(localized: "Objects To Cut") : (op == "join" ? String(localized: "Objects To Join") : String(localized: "Objects To Intersect"))
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                Text(title).font(touch ? VFFont.row : .callout).foregroundStyle(theme.inkSecondary)
                ForEach(bodies, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { session.options.targets.isEmpty || session.options.targets.contains(name) },
                        set: { on in session.options.targets = Self.targets(session.options.targets, all: bodies, name: name, on: on) }))
                        .toggleStyle(.vfCheck)
                        .font(touch ? VFFont.row : .callout)
                        .frame(minHeight: touch ? VFSize.touchTarget : nil)
                }
            }
        }
    }

    // MARK: Controls

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: VFSpace.s) {
            Text(label).font(touch ? VFFont.row : .callout).foregroundStyle(theme.inkSecondary)
                .frame(width: touch ? nil : labelWidth, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }
        .frame(minHeight: touch ? VFSize.touchTarget : nil)
    }

    private func numberRow(_ label: String, _ value: Binding<Double>, unit: VFUnit, step: Double = 1, range: ClosedRange<Double>? = nil) -> some View {
        row(label) {
            NumberField(label, value: value, unit: unit, range: range, step: step, width: 82).labelHiddenVisually()
        }
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.vfSwitch)
            .font(touch ? VFFont.row : .callout)
            .foregroundStyle(theme.ink)
            .frame(minHeight: touch ? VFSize.touchTarget : nil)
    }

    @ViewBuilder private func picker<T: Hashable>(_ label: String, _ items: [T], _ selection: Binding<T>, title: @escaping (T) -> String) -> some View {
        if touch && items.count <= 3 {
            VStack(alignment: .leading, spacing: VFSpace.xxs) {
                Text(label).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                VFSegmented(label, selection: selection, items: items, title: title)
                    .frame(minHeight: VFSize.touchTarget)
            }
        } else {
            row(label) {
                VFMenuPicker(label, selection: selection, items: items, title: title)
            }
        }
    }

    // MARK: Helpers

    static func operationTitle(_ op: String) -> String {
        switch op {
        case "auto": String(localized: "Automatic")
        case "new_body": String(localized: "New Body")
        case "join": String(localized: "Join")
        case "cut": String(localized: "Cut")
        case "intersect": String(localized: "Intersect")
        default: op
        }
    }

    /// The target list after ticking `name` on or off; every body ticked is the empty list.
    static func targets(_ current: [String], all: [String], name: String, on: Bool) -> [String] {
        var t = current.isEmpty ? all : current
        if on { if !t.contains(name) { t.append(name) } } else { t.removeAll { $0 == name } }
        if t.isEmpty { return current }
        return Set(t) == Set(all) ? [] : all.filter { t.contains($0) }
    }

    static func range(_ unit: String, _ initial: Double, _ current: Double) -> ClosedRange<Double> {
        if unit == "deg" { return 0...360 }
        if unit.isEmpty { return 3...24 }
        return min(0, current * 1.5)...max(100, initial * 4, current * 1.5)
    }
}

/// Keeps the feature session in step with the model: attach it to any view that is on screen
/// while a tool runs (the dialog, the tool card, the canvas overlay).
struct FeatureSessionSync: ViewModifier {
    let model: DesignModel

    private struct Key: Equatable {
        var tool: Tool
        var value: Double
        var operation: String
        var axis: String
        var profiles: Set<Int>
        var picks: [Pick]
        var revision: Int
        var preview: Bool
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: Key(tool: model.tool, value: model.toolValue, operation: model.toolOperation, axis: model.revolveAxis,
                              profiles: model.extrudeProfiles, picks: model.selection, revision: model.snapshot.revision,
                              preview: model.hasPreview), initial: true) { _, _ in
                let s = FeatureSession.of(model)
                s.sync()
                if s.editing != nil { s.previewEdit() }
            }
    }
}

/// Move's rows (B-13): the gizmo's translation as X, Y and Z fields, its turn, Copy, and a
/// switch that makes drags move the pivot. The gizmo on the canvas and these fields edit the
/// same state; OK runs one `solid.move`.
struct MoveDialogRows: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var session: FeatureSession
    var touch = false
    var labelWidth: CGFloat = 70

    var body: some View {
        let _ = units
        if session.move != nil {
            VStack(alignment: .leading, spacing: touch ? VFSpace.s : VFSpace.m) {
                ForEach(0..<3, id: \.self) { i in
                    let axis = ["X", "Y", "Z"][i]
                    HStack {
                        Text(String(localized: "\(axis) Distance")).font(touch ? VFFont.row : .callout).foregroundStyle(theme.inkSecondary)
                            .frame(width: touch ? nil : labelWidth + 10, alignment: .leading)
                        Spacer(minLength: 0)
                        NumberField(String(localized: "Move \(axis)"),
                                    value: Binding(get: { session.move?.translate[i] ?? 0 }, set: { session.move?.translate[i] = $0 }),
                                    unit: .length, width: 82)
                            .labelHiddenVisually()
                    }
                    .frame(minHeight: touch ? VFSize.touchTarget : nil)
                }
                if let g = session.move, abs(g.angle) > 1e-9 {
                    HStack {
                        Text("Angle").font(touch ? VFFont.row : .callout).foregroundStyle(theme.inkSecondary)
                        Spacer(minLength: 0)
                        Text(VFFormat.value(g.angle, .angle)).font(touch ? VFFont.row : .callout).monospacedDigit().foregroundStyle(theme.ink)
                        VFIconButton("arrow.counterclockwise", label: String(localized: "Reset Turn"), size: touch ? 14 : 11) {
                            session.move?.rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
                        }
                    }
                }
                Toggle("Set Pivot", isOn: Binding(get: { session.move?.editingPivot ?? false }, set: { session.move?.editingPivot = $0 }))
                    .toggleStyle(.vfSwitch)
                    .font(touch ? VFFont.row : .callout)
                    .frame(minHeight: touch ? VFSize.touchTarget : nil)
                Toggle("Create Copy", isOn: Binding(get: { session.move?.copy ?? false }, set: { session.move?.copy = $0 }))
                    .toggleStyle(.vfSwitch)
                    .font(touch ? VFFont.row : .callout)
                    .frame(minHeight: touch ? VFSize.touchTarget : nil)
            }
        }
    }
}
