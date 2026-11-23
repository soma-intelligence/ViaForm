import SwiftUI

/// The study's setup and its results, one surface at a time: Study (space, goal, material,
/// limits, manufacturing, dynamics), Regions (supports, load cases, keep-out, keep-in) and
/// Results (the picked candidate's analysis).
struct GenerateInspector: View {
    @Bindable var model: GenerateModel
    let design: DesignModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Pane", selection: $model.pane) {
                ForEach(GenerateModel.Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            switch model.pane {
            case .project: ProjectForm(model: model, design: design)
            case .study: StudyForm(model: model)
            case .regions: RegionsForm(model: model)
            case .results: GenerateResults(model: model, design: design)
            case .variants: VariantsForm(model: model, design: design)
            }
        }
        .disabled(model.running && model.pane != .results && model.pane != .project && model.pane != .variants)
    }
}

// MARK: Study

struct StudyForm: View {
    @Bindable var model: GenerateModel

    private var materialName: Binding<String> {
        Binding(get: { model.study.material.name }, set: { name in
            if let m = StudyMaterial.presets.first(where: { $0.name == name }) { model.study.material = m }
        })
    }

    var body: some View {
        let s = model.study
        Form {
            Section {
                Menu {
                    ForEach(GenerateModel.Template.allCases) { t in
                        Button { model.apply(t) } label: { Label(t.rawValue, systemImage: t.symbol) }
                    }
                } label: {
                    Label("Start from a template", systemImage: "square.on.square")
                }
                TextField("Body name", text: $model.study.name)
            }
            Section {
                Vec3Row("Min", value: $model.study.min, unit: "mm")
                Vec3Row("Max", value: $model.study.max, unit: "mm")
                NumberRow("Voxel", value: $model.study.voxel, unit: "mm", range: 0.05...1000)
                let g = s.grid
                LabeledContent("Elements") {
                    Text("\(s.elementCount.formatted())  (\(g.n[0]) × \(g.n[1]) × \(g.n[2]))")
                        .monospacedDigit()
                        .foregroundStyle(s.elementCount > 2_000_000 ? .orange : .secondary)
                }
                LabeledContent("Estimated time") {
                    let t = GenerateModel.estimate(s)
                    Text("about \(readableDuration(t))").monospacedDigit().foregroundStyle(t > 600 ? .orange : .secondary)
                }
            } header: {
                Text("Design space")
            } footer: {
                Text("World millimetres, Z up. Each voxel is one hexahedral element.")
            }
            Section("Goal") {
                Picker("Method", selection: $model.study.method) {
                    ForEach(StudyMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Objective", selection: $model.study.objective) {
                    ForEach(StudyObjective.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(s.objective == .compliance ? "Volume fraction" : "Volume cap") {
                        Text(s.volumeFraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                    Slider(value: $model.study.volumeFraction, in: 0.03...0.9, step: 0.01)
                        .accessibilityLabel("Volume fraction")
                }
                Stepper("Variants  \(s.variants)", value: $model.study.variants, in: 1...8)
                Stepper("Iterations  \(s.iterations)", value: $model.study.iterations, in: 10...400, step: 10)
                NumberRow("Narrowest member", value: $model.study.minMember, unit: "mm", range: 0...1000)
                Stepper("Smoothing  \(s.smoothing)", value: $model.study.smoothing, in: 0...40)
                Stepper("Bodies allowed  \(s.maxBodies)", value: $model.study.maxBodies, in: 1...8)
                Toggle("Cut round keep-outs exactly", isOn: $model.study.exactKeepOuts)
            }
            Section {
                OptionalNumberRow("Target mass", value: $model.study.massTargetG, unit: "g", fallback: 0, label: "Target")
                Toggle("Robust (eroded, nominal, dilated)", isOn: Binding(get: { model.study.robustDelta != nil },
                                                                          set: { model.study.robustDelta = $0 ? (model.study.robustDelta ?? 0.15) : nil }))
                if s.robustDelta != nil {
                    NumberRow("Robust threshold shift", value: Binding(get: { model.study.robustDelta ?? 0.15 }, set: { model.study.robustDelta = $0 }), unit: "", range: 0.01...0.45)
                }
                NumberRow("Projection sharpness", value: $model.study.maxBeta, unit: "", range: 0...64)
                NumberRow("Stop below change", value: $model.study.tolerance, unit: "", range: 0...0.5)
                Stepper("Modes held by the floor  \(s.frequencyModes)", value: $model.study.frequencyModes, in: 1...8)
            } header: {
                Text("Engine")
            } footer: {
                Text("Written to the study file as mass_target_g, robust, max_beta, tolerance and frequency_modes. Empty target mass: the volume fraction rules.")
            }
            Section {
                Picker("Material", selection: materialName) {
                    ForEach(StudyMaterial.presets, id: \.name) { Text($0.name).tag($0.name) }
                    if !StudyMaterial.presets.contains(where: { $0.name == s.material.name }) {
                        Text(s.material.name).tag(s.material.name)
                    }
                }
                NumberRow("Young's modulus", value: $model.study.material.e, unit: "MPa", range: 1...1e7)
                NumberRow("Poisson's ratio", value: $model.study.material.nu, unit: "", range: 0...0.49)
                NumberRow("Density", value: Binding(get: { model.study.material.density * 1000 },
                                                    set: { model.study.material.density = $0 / 1000 }), unit: "g/cm³", range: 0.01...30)
                NumberRow("Allowable", value: $model.study.material.allowable, unit: "MPa", range: 0.01...1e5)
            } header: {
                Text("Material")
            }
            Section {
                NumberRow("Safety factor", value: $model.study.safetyFactor, unit: "", range: 1...20)
                OptionalNumberRow("Stress limit", value: $model.study.maxStress, unit: "MPa",
                                  fallback: s.material.allowable / max(s.safetyFactor, 1))
                OptionalNumberRow("Displacement limit", value: $model.study.maxDisplacement, unit: "mm", fallback: 0.5)
                OptionalNumberRow("Lowest frequency", value: $model.study.minFrequency, unit: "Hz", fallback: 200)
            } header: {
                Text("Limits")
            } footer: {
                Text(String(format: "Stress held at %.0f MPa.", s.stressLimit))
            }
            Section("Symmetry") {
                Toggle("Mirror across X", isOn: $model.study.symmetry[0])
                Toggle("Mirror across Y", isOn: $model.study.symmetry[1])
                Toggle("Mirror across Z", isOn: $model.study.symmetry[2])
            }
            Section("Manufacturing") {
                Picker("Process", selection: $model.study.manufacturing.process) {
                    ForEach(StudyManufacturing.Process.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if s.manufacturing.process != .free {
                    AxisPicker(label: s.manufacturing.process == .additive ? "Build direction" : (s.manufacturing.process == .milling ? "Tool direction" : "Direction"),
                               value: $model.study.manufacturing.direction)
                }
                if s.manufacturing.process == .additive {
                    NumberRow("Overhang", value: $model.study.manufacturing.overhang, unit: "°", range: 0...89)
                }
            }
            DynamicsSection(model: model)
        }
        .formStyle(.grouped)
    }
}

/// Natural modes and impacts.
struct DynamicsSection: View {
    @Bindable var model: GenerateModel

    var body: some View {
        Section {
            Stepper("Modes  \(model.study.dynamics.modes)", value: $model.study.dynamics.modes, in: 0...12)
            ForEach($model.study.dynamics.impacts) { $impact in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("Impact on", selection: $impact.caseIndex) {
                            ForEach(Array(model.study.cases.enumerated()), id: \.offset) { i, c in
                                Text(c.name.isEmpty ? "Case \(i + 1)" : c.name).tag(i)
                            }
                        }
                        RemoveButton { model.study.dynamics.impacts.removeAll { $0.id == impact.id } }
                    }
                    NumberRow("Pulse", value: Binding(get: { impact.duration * 1000 }, set: { impact.duration = $0 / 1000 }), unit: "ms", range: 0.001...10_000)
                    NumberRow("Window", value: Binding(get: { impact.window * 1000 }, set: { impact.window = $0 / 1000 }), unit: "ms", range: 0.001...10_000)
                    Stepper("Steps  \(impact.steps)", value: $impact.steps, in: 20...2000, step: 20)
                    NumberRow("Damping", value: Binding(get: { impact.damping * 100 }, set: { impact.damping = $0 / 100 }), unit: "%", range: 0...100)
                }
            }
            Button("Add impact", systemImage: "plus") {
                model.study.dynamics.impacts.append(StudyImpact(caseIndex: min(model.activeCase, max(model.study.cases.count - 1, 0))))
            }
            .disabled(model.study.cases.isEmpty)
        } header: {
            Text("Dynamics")
        } footer: {
            Text("An impact applies its load case as a half-sine pulse, then integrates the response over the window.")
        }
    }
}

// MARK: Regions

struct RegionsForm: View {
    @Bindable var model: GenerateModel

    var body: some View {
        Form {
            Section {
                ForEach($model.study.supports) { $sup in
                    let key = GenerateModel.RegionKey.support(sup.id)
                    RegionRow(model: model, key: key, title: "Support", detail: sup.label, color: GenerateScene.supportColor) {
                        HStack(spacing: 8) {
                            Text("Hold").foregroundStyle(.secondary)
                            Toggle("X", isOn: $sup.fix[0])
                            Toggle("Y", isOn: $sup.fix[1])
                            Toggle("Z", isOn: $sup.fix[2])
                        }
                        .toggleStyle(.button)
                        RegionFields(region: $sup.region)
                    }
                }
                Button("Add support", systemImage: "plus") { model.addSupport() }
            } header: {
                Text("Supports")
            } footer: {
                Text("Pick a region here or in the preview, then drag it there to move it.")
            }
            LoadCasesSection(model: model)
            Section("Keep out") {
                ForEach($model.study.keepOut) { $k in
                    RegionRow(model: model, key: .keepOut(k.id), title: "Keep out", detail: k.region.shape.label, color: GenerateScene.keepOutColor) {
                        RegionFields(region: $k.region)
                    }
                }
                Button("Add keep-out", systemImage: "plus") { model.addKeepOut() }
            }
            Section("Keep in") {
                ForEach($model.study.keepIn) { $k in
                    RegionRow(model: model, key: .keepIn(k.id), title: "Keep in", detail: k.region.shape.label, color: GenerateScene.keepInColor) {
                        RegionFields(region: $k.region)
                    }
                }
                Button("Add keep-in", systemImage: "plus") { model.addKeepIn() }
            }
        }
        .formStyle(.grouped)
    }
}

struct LoadCasesSection: View {
    @Bindable var model: GenerateModel

    var body: some View {
        Section {
            if model.study.cases.indices.contains(model.activeCase) {
                Picker("Case", selection: $model.activeCase) {
                    ForEach(Array(model.study.cases.enumerated()), id: \.offset) { i, c in
                        Text(c.name.isEmpty ? "Case \(i + 1)" : c.name).tag(i)
                    }
                }
                let c = $model.study.cases[model.activeCase]
                TextField("Name", text: c.name)
                NumberRow("Weight", value: c.weight, unit: "", range: 0...1000)
                OptionalVec3Row("Acceleration", value: c.acceleration, unit: "mm/s²", fallback: Vec3(0, 0, -9810))
                ForEach(c.loads) { $load in
                    RegionRow(model: model, key: .load(load.id), title: load.kind.label, detail: load.summary, color: GenerateScene.loadColor) {
                        LoadFields(load: $load)
                        RegionFields(region: $load.region)
                    }
                }
                Menu {
                    ForEach(StudyLoad.Kind.allCases, id: \.self) { k in
                        Button { model.addLoad(k) } label: { Label(k.label, systemImage: k.symbol) }
                    }
                } label: {
                    Label("Add load", systemImage: "plus")
                }
            }
            HStack {
                Button("Add case", systemImage: "plus.square.on.square") { model.addCase() }
                Spacer()
                Button("Remove case", systemImage: "trash", role: .destructive) { model.removeCase(model.activeCase) }
                    .disabled(model.study.cases.count < 2)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Load cases")
        } footer: {
            Text("Forces in N, torques in N·mm about an axis through their centre (right-hand rule), pressures in MPa. Gravity is 0, 0, -9810 mm/s².")
        }
    }
}

/// A region in a list: a tap picks it, and the picked one shows its fields.
struct RegionRow<Fields: View>: View {
    @Bindable var model: GenerateModel
    let key: GenerateModel.RegionKey
    let title: String
    let detail: String
    let color: SIMD3<Double>
    @ViewBuilder var fields: () -> Fields

    var body: some View {
        let picked = model.selection == key
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.select(picked ? nil : key)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: color.x, green: color.y, blue: color.z)).frame(width: 10, height: 10)
                        Text(title)
                        Text(detail).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                        Image(systemName: picked ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                RemoveButton { model.remove(key) }
            }
            if picked { fields() }
        }
    }
}

/// A region's shape and figures.
struct RegionFields: View {
    @Binding var region: StudyRegion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Shape", selection: Binding(get: { region.shape }, set: { region.convert(to: $0) })) {
                ForEach(StudyRegion.Shape.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch region.shape {
            case .box:
                Vec3Row("Min", value: $region.min, unit: "mm")
                Vec3Row("Max", value: $region.max, unit: "mm")
            case .cylinder:
                Vec3Row("Base", value: $region.base, unit: "mm")
                AxisPicker(label: "Axis", value: $region.axis)
                NumberRow("Radius", value: $region.radius, unit: "mm", range: 0.01...1e5)
                NumberRow("Length", value: $region.length, unit: "mm", range: 0.01...1e5)
            case .sphere:
                Vec3Row("Centre", value: $region.center, unit: "mm")
                NumberRow("Radius", value: $region.radius, unit: "mm", range: 0.01...1e5)
            case .tube:
                Vec3Row("Base", value: $region.base, unit: "mm")
                AxisPicker(label: "Axis", value: $region.axis)
                NumberRow("Bore radius", value: $region.inner, unit: "mm", range: 0...1e5)
                NumberRow("Outer radius", value: $region.radius, unit: "mm", range: 0.01...1e5)
                NumberRow("Length", value: $region.length, unit: "mm", range: 0.01...1e5)
            }
        }
    }
}

/// A load's kind and figures.
struct LoadFields: View {
    @Binding var load: StudyLoad

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: $load.kind) {
                ForEach(StudyLoad.Kind.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch load.kind {
            case .force:
                Vec3Row("Force", value: $load.force, unit: "N")
            case .torque:
                NumberRow("Moment", value: $load.moment, unit: "N·mm", range: -1e9...1e9)
                AxisPicker(label: "Axis", value: $load.axis)
                Vec3Row("Centre", value: $load.center, unit: "mm")
                Button("Centre on the region", systemImage: "scope") { load.center = load.region.middle }
                    .buttonStyle(.borderless)
            case .pressure:
                NumberRow("Pressure", value: $load.pressure, unit: "MPa", range: 0...1e5)
                AxisPicker(label: "Direction", value: $load.direction)
            }
        }
    }
}

// MARK: Fields

/// A number typed in place, with its unit.
struct NumberField: View {
    @Binding var value: Double
    var range: ClosedRange<Double>?
    var width: CGFloat = 72

    var body: some View {
        TextField("", value: Binding(get: { value }, set: { v in
            guard v.isFinite else { return }
            value = range.map { min(max(v, $0.lowerBound), $0.upperBound) } ?? v
        }), format: .number.precision(.significantDigits(1...6)))
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .labelsHidden()
        #if os(iOS)
        // A fixed width on touch: a Form row would otherwise squeeze the field to its
        // minimum and cut the digits.
        .frame(width: width * 1.2)
        .keyboardType(.numbersAndPunctuation)
        .textFieldStyle(.roundedBorder)
        #else
        .frame(minWidth: width * 0.75, idealWidth: width, maxWidth: width)
        #endif
    }
}

struct NumberRow: View {
    let label: String
    @Binding var value: Double
    let unit: String
    var range: ClosedRange<Double>?

    init(_ label: String, value: Binding<Double>, unit: String, range: ClosedRange<Double>? = nil) {
        self.label = label
        _value = value
        self.unit = unit
        self.range = range
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                NumberField(value: $value, range: range, width: 88)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

/// x, y and z on one row.
struct Vec3Row: View {
    let label: String
    @Binding var value: Vec3
    let unit: String

    init(_ label: String, value: Binding<Vec3>, unit: String) {
        self.label = label
        _value = value
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(unit.isEmpty ? label : "\(label), \(unit)").foregroundStyle(.secondary).font(.callout)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { a in
                    Text(["x", "y", "z"][a]).font(.caption).foregroundStyle(.tertiary)
                    NumberField(value: Binding(get: { value[a] }, set: { value[a] = $0 }), width: 64)
                }
            }
        }
    }
}

/// A limit that may be off: a switch, and the number when on.
struct OptionalNumberRow: View {
    let label: String
    @Binding var value: Double?
    let unit: String
    let fallback: Double
    /// The number's own label when on.
    let numberLabel: String

    init(_ label: String, value: Binding<Double?>, unit: String, fallback: Double, label numberLabel: String = "Limit") {
        self.label = label
        _value = value
        self.unit = unit
        self.fallback = fallback
        self.numberLabel = numberLabel
    }

    var body: some View {
        Toggle(label, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? fallback) : nil }))
        if value != nil {
            NumberRow(numberLabel, value: Binding(get: { value ?? fallback }, set: { value = $0 }), unit: unit, range: 0...1e9)
        }
    }
}

struct OptionalVec3Row: View {
    let label: String
    @Binding var value: Vec3?
    let unit: String
    let fallback: Vec3

    init(_ label: String, value: Binding<Vec3?>, unit: String, fallback: Vec3) {
        self.label = label
        _value = value
        self.unit = unit
        self.fallback = fallback
    }

    var body: some View {
        Toggle(label, isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? fallback) : nil }))
        if value != nil {
            Vec3Row("Body acceleration", value: Binding(get: { value ?? fallback }, set: { value = $0 }), unit: unit)
        }
    }
}

/// A direction: one of the six axes, or the numbers when it is none of them.
struct AxisPicker: View {
    let label: String
    @Binding var value: Vec3

    private static let axes: [(String, Vec3)] = [
        ("+X", Vec3(1, 0, 0)), ("-X", Vec3(-1, 0, 0)), ("+Y", Vec3(0, 1, 0)),
        ("-Y", Vec3(0, -1, 0)), ("+Z", Vec3(0, 0, 1)), ("-Z", Vec3(0, 0, -1)),
    ]

    private var current: String {
        let l = (value.x * value.x + value.y * value.y + value.z * value.z).squareRoot()
        guard l > 0 else { return "Other" }
        return Self.axes.first { (value / l - $0.1).max() < 1e-9 && ($0.1 - value / l).max() < 1e-9 }?.0 ?? "Other"
    }

    var body: some View {
        Picker(label, selection: Binding(get: { current }, set: { name in
            if let a = Self.axes.first(where: { $0.0 == name }) { value = a.1 } else if current != "Other" { value = Vec3(1, 1, 1) / Double(3).squareRoot() }
        })) {
            ForEach(Self.axes, id: \.0) { Text($0.0).tag($0.0) }
            Text("Other").tag("Other")
        }
        if current == "Other" {
            Vec3Row(label, value: $value, unit: "")
        }
    }
}

struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove")
    }
}
