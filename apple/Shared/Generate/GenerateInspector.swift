import SwiftUI

/// The study's setup and its results, one surface at a time: Study (space, goal, material,
/// limits, manufacturing, dynamics), Regions (supports, load cases, keep-out, keep-in) and
/// Results (the picked candidate's analysis).
struct GenerateInspector: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel
    let design: DesignModel

    /// The setup panes lock while a study runs; Project, Results and Variants stay usable.
    private var locked: Bool { model.running && [.study, .regions].contains(model.pane) }

    private var paneSegments: some View {
        VFSegmented(String(localized: "Pane"), selection: $model.pane, items: GenerateModel.Pane.allCases, title: { $0.title })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Five panes do not fit a 320 pt column as full segments: try the
            // segmented track, then a pill menu, so no title is cut.
            ViewThatFits(in: .horizontal) {
                paneSegments.fixedSize()
                VFMenuPicker(String(localized: "Pane"), selection: $model.pane, items: GenerateModel.Pane.allCases, title: { $0.title })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, VFSpace.xl)
            .padding(.vertical, VFSpace.m)
            if locked {
                HStack(spacing: VFSpace.m) {
                    Image(systemName: "lock.fill").foregroundStyle(theme.inkSecondary).accessibilityHidden(true)
                    Text("Locked while the study runs. Stop to edit.")
                        .font(VFFont.row)
                        .foregroundStyle(theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: VFSpace.s)
                    Button("Stop") { model.requestStop() }.buttonStyle(.vfSecondary)
                }
                .padding(VFSpace.m)
                .background(RoundedRectangle(cornerRadius: VFRadius.well, style: .continuous).fill(theme.well))
                .padding(.horizontal, VFSpace.xl)
                .accessibilityElement(children: .combine)
            }
            Group {
                switch model.pane {
                case .project: ProjectForm(model: model, design: design)
                case .study: StudyForm(model: model)
                case .regions: RegionsForm(model: model)
                case .results: GenerateResults(model: model, design: design)
                case .variants: VariantsForm(model: model, design: design)
                }
            }
            .vfDisabled(locked, reason: String(localized: "Locked while the study runs. Stop to edit."))
        }
    }
}

/// A whole number typed or stepped: the field for large ranges, the stepper for a nudge.
struct IntRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit: VFUnit = .none

    init(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: VFUnit = .none) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: VFSpace.xs) {
                NumberField(label, value: Binding(get: { Double(value) }, set: { value = min(max(Int($0.rounded()), range.lowerBound), range.upperBound) }),
                            unit: unit, range: Double(range.lowerBound)...Double(range.upperBound), step: Double(step), width: 56)
                    .labelHiddenVisually()
                VFIconButton("minus", label: String(localized: "Decrease \(label)")) {
                    value = max(value - step, range.lowerBound)
                }
                .disabled(value <= range.lowerBound)
                VFIconButton("plus", label: String(localized: "Increase \(label)")) {
                    value = min(value + step, range.upperBound)
                }
                .disabled(value >= range.upperBound)
            }
        }
    }
}

// MARK: Study

struct StudyForm: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel
    @State private var confirm: ConfirmRequest?

    private var materialName: Binding<String> {
        Binding(get: { model.study.material.name }, set: { name in
            if let m = StudyMaterial.presets.first(where: { $0.name == name }) { model.study.material = m }
        })
    }

    var body: some View {
        let _ = units
        let s = model.study
        Form {
            Section {
                Menu {
                    ForEach(GenerateModel.Template.allCases) { t in
                        Button { applyTemplate(t) } label: { Label(t.title, systemImage: t.symbol) }
                    }
                } label: {
                    Label("Start from a template", systemImage: "square.on.square").labelStyle(.titleAndIcon)
                }
                .menuStyle(.vfPill)
                TextField("Body name", text: $model.study.name)
                    .vfField()
            }
            InspectorSection(.designSpace, String(localized: "Design space"), status: s.status(.designSpace)) {
                Vec3Row("Min", value: $model.study.min, unit: "mm")
                Vec3Row("Max", value: $model.study.max, unit: "mm")
                NumberRow("Voxel", value: $model.study.voxel, unit: "mm", range: 0.05...1000)
                let g = s.grid
                LabeledContent("Elements") {
                    Text("\(s.elementCount.formatted()) (\(g.n[0]) × \(g.n[1]) × \(g.n[2]))")
                        .monospacedDigit()
                        .foregroundStyle(s.elementCount > 2_000_000 ? theme.warning : theme.inkSecondary)
                }
                LabeledContent("Estimated time") {
                    let t = GenerateModel.estimate(s)
                    Text("about \(readableDuration(t))").monospacedDigit().foregroundStyle(t > 600 ? theme.warning : theme.inkSecondary)
                }
            } footer: {
                Text("World coordinates in \(LengthDisplay.current.plural), Z up. Each voxel is one hexahedral element.")
            }
            InspectorSection(.goal, String(localized: "Goal"), status: s.status(.goal)) {
                LabeledContent("Method") {
                    VFMenuPicker(String(localized: "Method"), selection: $model.study.method, items: StudyMethod.allCases, title: { $0.label })
                }
                LabeledContent("Objective") {
                    VFMenuPicker(String(localized: "Objective"), selection: $model.study.objective, items: StudyObjective.allCases, title: { $0.label })
                }
                VStack(alignment: .leading, spacing: VFSpace.xs) {
                    LabeledContent(s.objective == .compliance ? "Volume fraction" : "Volume cap") {
                        Text(s.volumeFraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                    Slider(value: $model.study.volumeFraction, in: 0.03...0.9, step: 0.01)
                        .accessibilityLabel("Volume fraction")
                }
                IntRow(String(localized: "Variants"), value: $model.study.variants, range: 1...8)
                IntRow(String(localized: "Iterations"), value: $model.study.iterations, range: 10...400, step: 10)
                NumberRow(String(localized: "Narrowest member"), value: $model.study.minMember, unit: "mm", range: 0...1000)
                IntRow(String(localized: "Smoothing passes"), value: $model.study.smoothing, range: 0...40)
                IntRow(String(localized: "Bodies allowed"), value: $model.study.maxBodies, range: 1...8)
                Toggle("Cut round keep-outs exactly", isOn: $model.study.exactKeepOuts)
                    .toggleStyle(.vfSwitch)
            }
            InspectorSection(.solver, String(localized: "Solver"), status: s.status(.solver)) {
                OptionalNumberRow(String(localized: "Target mass"), value: $model.study.massTargetG, unit: "g", fallback: 0, label: String(localized: "Target"))
                Toggle("Hold up to thinner and thicker prints", isOn: Binding(get: { model.study.robustDelta != nil },
                                                                              set: { model.study.robustDelta = $0 ? (model.study.robustDelta ?? 0.15) : nil }))
                    .toggleStyle(.vfSwitch)
                    .help("Checks the shape as made a little thinner and a little thicker, so it stays strong when the print or the cut is off.")
                if s.robustDelta != nil {
                    NumberRow(String(localized: "Thickness margin"), value: Binding(get: { (model.study.robustDelta ?? 0.15) * 100 }, set: { model.study.robustDelta = $0 / 100 }), unit: "%", range: 1...45)
                        .help("How far thinner and thicker the shape is checked.")
                }
                NumberRow(String(localized: "Edge crispness"), value: $model.study.maxBeta, unit: "", range: 0...64)
                    .help("Higher values give cleaner solid-or-empty edges, and take longer.")
                NumberRow(String(localized: "Finish when change is under"), value: Binding(get: { model.study.tolerance * 100 }, set: { model.study.tolerance = $0 / 100 }), unit: "%", range: 0...50)
                    .help("The run ends early once the shape changes less than this between iterations.")
                IntRow(String(localized: "Modes kept above the frequency floor"), value: $model.study.frequencyModes, range: 1...8)
            } footer: {
                Text("Without a target mass, the volume fraction decides how much material stays.")
            }
            InspectorSection(.material, String(localized: "Material"), status: s.status(.material)) {
                LabeledContent("Material") {
                    // A custom material that is not a preset stays listed so the pill can show it.
                    let names = StudyMaterial.presets.map(\.name)
                        + (StudyMaterial.presets.contains(where: { $0.name == s.material.name }) ? [] : [s.material.name])
                    VFMenuPicker(String(localized: "Material"), selection: materialName, items: names, title: { $0 })
                }
                NumberRow(String(localized: "Stiffness (Young's modulus)"), value: $model.study.material.e, unit: "MPa", range: 1...1e7)
                NumberRow(String(localized: "Poisson's ratio"), value: $model.study.material.nu, unit: "", range: 0...0.49)
                NumberRow(String(localized: "Density"), value: Binding(get: { model.study.material.density * 1000 },
                                                                       set: { model.study.material.density = $0 / 1000 }), unit: "g/cm³", range: 0.01...30)
                NumberRow(String(localized: "Allowable stress"), value: $model.study.material.allowable, unit: "MPa", range: 0.01...1e5)
            }
            InspectorSection(.limits, String(localized: "Limits"), status: s.status(.limits)) {
                NumberRow(String(localized: "Safety factor"), value: $model.study.safetyFactor, unit: "", range: 1...20)
                OptionalNumberRow(String(localized: "Stress limit"), value: $model.study.maxStress, unit: "MPa",
                                  fallback: s.material.allowable / max(s.safetyFactor, 1))
                OptionalNumberRow(String(localized: "Displacement limit"), value: $model.study.maxDisplacement, unit: "mm", fallback: 0.5)
                OptionalNumberRow(String(localized: "Lowest frequency"), value: $model.study.minFrequency, unit: "Hz", fallback: 200)
            } footer: {
                Text("Stress held at \(Int(s.stressLimit.rounded())) MPa.")
            }
            InspectorSection(.symmetry, String(localized: "Symmetry"), status: s.status(.symmetry)) {
                Toggle("Mirror across X", isOn: $model.study.symmetry[0]).toggleStyle(.vfSwitch)
                Toggle("Mirror across Y", isOn: $model.study.symmetry[1]).toggleStyle(.vfSwitch)
                Toggle("Mirror across Z", isOn: $model.study.symmetry[2]).toggleStyle(.vfSwitch)
            }
            InspectorSection(.manufacturing, String(localized: "Manufacturing"), status: s.status(.manufacturing)) {
                LabeledContent("Process") {
                    VFMenuPicker(String(localized: "Process"), selection: $model.study.manufacturing.process,
                                 items: StudyManufacturing.Process.allCases, title: { $0.label })
                }
                if s.manufacturing.process != .free {
                    AxisPicker(label: s.manufacturing.process == .additive ? String(localized: "Build direction")
                                   : (s.manufacturing.process == .milling ? String(localized: "Tool direction") : String(localized: "Direction")),
                               value: $model.study.manufacturing.direction)
                }
                if s.manufacturing.process == .additive {
                    NumberRow(String(localized: "Steepest overhang"), value: $model.study.manufacturing.overhang, unit: "°", range: 0...89)
                }
            }
            DynamicsSection(model: model)
        }
        .formStyle(.grouped)
        .confirmSheet($confirm)
    }

    /// A template replaces the setup: asked first when the user edited it (undoable either way).
    private func applyTemplate(_ t: GenerateModel.Template) {
        guard model.studyEdited else { model.apply(t); return }
        confirm = ConfirmRequest(
            title: String(localized: "Replace the current study setup?"),
            message: String(localized: "The \(t.title) template replaces your regions, loads and limits. You can undo this."),
            verb: String(localized: "Replace"),
            destructive: true,
            perform: { model.apply(t) })
    }
}

/// Natural modes and impacts.
struct DynamicsSection: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: GenerateModel

    /// A load case's name in a menu, or its number when it has none.
    private func caseTitle(_ i: Int) -> String {
        let name = model.study.cases[safe: i]?.name ?? ""
        return name.isEmpty ? String(localized: "Case \(i + 1)") : name
    }

    var body: some View {
        InspectorSection(.dynamics, String(localized: "Dynamics"), status: model.study.status(.dynamics)) {
            IntRow(String(localized: "Natural modes to find"), value: $model.study.dynamics.modes, range: 0...12)
            ForEach($model.study.dynamics.impacts) { $impact in
                VStack(alignment: .leading, spacing: VFSpace.m) {
                    HStack {
                        LabeledContent("Impact on") {
                            VFMenuPicker(String(localized: "Impact on"), selection: $impact.caseIndex,
                                         items: Array(model.study.cases.indices), title: { caseTitle($0) })
                        }
                        RemoveButton(label: String(localized: "Remove Impact")) {
                            model.removeImpact(impact.id)
                            let step = model.lastUndoID
                            toasts?.show(String(localized: "Impact removed"), actionTitle: String(localized: "Undo")) { model.undo(step: step) }
                        }
                    }
                    NumberRow(String(localized: "Pulse length"), value: Binding(get: { impact.duration * 1000 }, set: { impact.duration = $0 / 1000 }), unit: "ms", range: 0.001...10_000)
                    NumberRow(String(localized: "Time window"), value: Binding(get: { impact.window * 1000 }, set: { impact.window = $0 / 1000 }), unit: "ms", range: 0.001...10_000)
                    IntRow(String(localized: "Time steps"), value: $impact.steps, range: 20...2000, step: 20)
                    NumberRow(String(localized: "Damping"), value: Binding(get: { impact.damping * 100 }, set: { impact.damping = $0 / 100 }), unit: "%", range: 0...100)
                }
            }
            Button("Add Impact", systemImage: "plus") { model.addImpact() }
                .buttonStyle(.vfGhost(tint: theme.accentText))
                .vfDisabled(model.study.cases.isEmpty, reason: String(localized: "Add a load case first."))
        } footer: {
            Text("An impact applies its load case as a half-sine pulse, then integrates the response over the window.")
        }
    }
}

// MARK: Regions

struct RegionsForm: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel

    var body: some View {
        Form {
            InspectorSection(.supports, String(localized: "Supports"), status: model.study.status(.supports)) {
                if model.study.supports.isEmpty {
                    Label("No support yet: the study needs at least one to run.", systemImage: "exclamationmark.circle")
                        .font(VFFont.row)
                        .foregroundStyle(theme.warning)
                }
                ForEach($model.study.supports) { $sup in
                    let key = GenerateModel.RegionKey.support(sup.id)
                    RegionRow(model: model, key: key, title: String(localized: "Support"), detail: sup.label, color: GenerateScene.supportColor) {
                        HStack(spacing: VFSpace.m) {
                            Text("Hold").foregroundStyle(theme.inkSecondary)
                            Toggle("X", isOn: $sup.fix[0])
                            Toggle("Y", isOn: $sup.fix[1])
                            Toggle("Z", isOn: $sup.fix[2])
                        }
                        .toggleStyle(.vfChip)
                        RegionFields(region: $sup.region)
                    }
                }
                Button("Add Support", systemImage: "plus") { model.addSupport() }
                    .buttonStyle(.vfGhost(tint: theme.accentText))
            } footer: {
                Text("Pick a region here or in the preview, then drag it there to move it.")
            }
            LoadCasesSection(model: model)
            InspectorSection(.keepOut, String(localized: "Keep out"), status: model.study.status(.keepOut)) {
                ForEach($model.study.keepOut) { $k in
                    RegionRow(model: model, key: .keepOut(k.id), title: String(localized: "Keep out"), detail: k.region.shape.label, color: GenerateScene.keepOutColor) {
                        RegionFields(region: $k.region)
                    }
                }
                Button("Add Keep-Out", systemImage: "plus") { model.addKeepOut() }
                    .buttonStyle(.vfGhost(tint: theme.accentText))
            }
            InspectorSection(.keepIn, String(localized: "Keep in"), status: model.study.status(.keepIn)) {
                ForEach($model.study.keepIn) { $k in
                    RegionRow(model: model, key: .keepIn(k.id), title: String(localized: "Keep in"), detail: k.region.shape.label, color: GenerateScene.keepInColor) {
                        RegionFields(region: $k.region)
                    }
                }
                Button("Add Keep-In", systemImage: "plus") { model.addKeepIn() }
                    .buttonStyle(.vfGhost(tint: theme.accentText))
            }
        }
        .formStyle(.grouped)
    }
}

struct LoadCasesSection: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: GenerateModel

    /// A load case's name in a menu, or its number when it has none.
    private func caseTitle(_ i: Int) -> String {
        let name = model.study.cases[safe: i]?.name ?? ""
        return name.isEmpty ? String(localized: "Case \(i + 1)") : name
    }

    var body: some View {
        InspectorSection(.loads, String(localized: "Load cases"), status: model.study.status(.loads)) {
            if model.study.cases.indices.contains(model.activeCase) {
                LabeledContent("Case") {
                    VFMenuPicker(String(localized: "Case"), selection: $model.activeCase,
                                 items: Array(model.study.cases.indices), title: { caseTitle($0) })
                }
                let c = $model.study.cases[model.activeCase]
                TextField("Name", text: c.name)
                    .vfField()
                NumberRow(String(localized: "Weight in the goal"), value: c.weight, unit: "", range: 0...1000)
                OptionalVec3Row(String(localized: "Acceleration"), value: c.acceleration, unit: "mm/s²", fallback: Vec3(0, 0, -9810))
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
                    Label("Add Load", systemImage: "plus")
                }
                .menuStyle(.vfPill)
            }
            HStack {
                Button("Add Case", systemImage: "plus.square.on.square") { model.addCase() }
                Spacer()
                Button("Remove Case", systemImage: "trash", role: .destructive) {
                    let name = model.study.cases[safe: model.activeCase]?.name ?? ""
                    model.removeCase(model.activeCase)
                    let step = model.lastUndoID
                    toasts?.show(String(localized: "Removed \(name)"), actionTitle: String(localized: "Undo")) { model.undo(step: step) }
                }
                .vfDisabled(model.study.cases.count < 2, reason: String(localized: "A study keeps at least one load case."))
            }
            .buttonStyle(.vfGhost(tint: theme.accentText))
        } footer: {
            Text("Forces in N, torques in N·mm about an axis through their centre (right-hand rule), pressures in MPa. Gravity is 0, 0, -9810 mm/s².")
        }
    }
}

/// A region in a list: a tap picks it, and the picked one shows its fields.
struct RegionRow<Fields: View>: View {
    @Environment(\.viaFormTheme) private var theme
    @Environment(\.vfToasts) private var toasts
    @Bindable var model: GenerateModel
    let key: GenerateModel.RegionKey
    let title: String
    let detail: String
    let color: SIMD3<Double>
    @ViewBuilder var fields: () -> Fields

    var body: some View {
        let picked = model.selection == key
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack(spacing: VFSpace.m) {
                Button {
                    model.select(picked ? nil : key)
                } label: {
                    HStack(spacing: VFSpace.m) {
                        Circle().fill(Color(scene: color)).frame(width: 10, height: 10).accessibilityHidden(true)
                        Text(title).foregroundStyle(theme.ink)
                        Text(detail).foregroundStyle(theme.inkSecondary).monospacedDigit().lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: picked ? "chevron.up" : "chevron.down").font(VFFont.micro).foregroundStyle(theme.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(title), \(detail)"))
                .accessibilityHint(picked ? Text("Hides its fields") : Text("Shows its fields"))
                RemoveButton(label: String(localized: "Remove \(title)"), action: removeWithUndo)
            }
            .contextMenu {
                Button(String(localized: "Remove \(title)"), systemImage: "trash", role: .destructive, action: removeWithUndo)
            }
            if picked { fields() }
        }
    }

    /// Removes the region, with Undo on the toast.
    private func removeWithUndo() {
        model.remove(key)
        let step = model.lastUndoID
        toasts?.show(String(localized: "\(title) removed"), actionTitle: String(localized: "Undo")) { model.undo(step: step) }
    }
}

/// A region's shape and figures.
struct RegionFields: View {
    @Binding var region: StudyRegion

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            VFSegmented(String(localized: "Shape"), selection: Binding(get: { region.shape }, set: { region.convert(to: $0) }),
                        items: StudyRegion.Shape.allCases, title: { $0.label }, symbol: { $0.symbol })
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
    @Environment(\.viaFormTheme) private var theme
    @Binding var load: StudyLoad

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            VFSegmented(String(localized: "Kind"), selection: $load.kind,
                        items: StudyLoad.Kind.allCases, title: { $0.label }, symbol: { $0.symbol })
            switch load.kind {
            case .force:
                Vec3Row("Force", value: $load.force, unit: "N")
            case .torque:
                NumberRow("Moment", value: $load.moment, unit: "N·mm", range: -1e9...1e9)
                AxisPicker(label: "Axis", value: $load.axis)
                Vec3Row("Centre", value: $load.center, unit: "mm")
                Button("Centre on the Region", systemImage: "scope") { load.center = load.region.middle }
                    .buttonStyle(.vfGhost(tint: theme.accentText))
            case .pressure:
                NumberRow("Pressure", value: $load.pressure, unit: "MPa", range: 0...1e5)
                AxisPicker(label: "Direction", value: $load.direction)
            }
        }
    }
}

// MARK: Fields

/// x, y and z on one row.
struct Vec3Row: View {
    @Environment(\.viaFormTheme) private var theme
    @ObservedUnits private var units
    let label: String
    @Binding var value: Vec3
    let unit: String

    init(_ label: String, value: Binding<Vec3>, unit: String) {
        self.label = label
        _value = value
        self.unit = unit
    }

    var body: some View {
        let _ = units
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            Text(unit.isEmpty ? label : "\(label), \(VFFormat.symbol(VFUnit(symbol: unit)))").foregroundStyle(theme.inkSecondary).font(VFFont.row)
            HStack(spacing: VFSpace.xs) {
                ForEach(0..<3, id: \.self) { a in
                    Text(["x", "y", "z"][a]).font(VFFont.micro).foregroundStyle(theme.inkTertiary).accessibilityHidden(true)
                    NumberField("\(label) \(["x", "y", "z"][a])", value: Binding(get: { value[a] }, set: { value[a] = $0 }), unit: VFUnit(symbol: unit), width: 64, showsUnit: false)
                        .labelHiddenVisually()
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
            .toggleStyle(.vfSwitch)
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
            .toggleStyle(.vfSwitch)
        if value != nil {
            Vec3Row(String(localized: "Body acceleration"), value: Binding(get: { value ?? fallback }, set: { value = $0 }), unit: unit)
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
        guard l > 0 else { return "other" }
        return Self.axes.first { (value / l - $0.1).max() < 1e-9 && ($0.1 - value / l).max() < 1e-9 }?.0 ?? "other"
    }

    var body: some View {
        LabeledContent(label) {
            VFMenuPicker(label, selection: Binding(get: { current }, set: { name in
                if let a = Self.axes.first(where: { $0.0 == name }) { value = a.1 } else if current != "other" { value = Vec3(1, 1, 1) / Double(3).squareRoot() }
            }), items: Self.axes.map(\.0) + ["other"], title: { $0 == "other" ? String(localized: "Other") : $0 })
        }
        if current == "other" {
            Vec3Row(label, value: $value, unit: "")
        }
    }
}

/// The minus button of a list row: labelled for VoiceOver and the tooltip, 44 pt on iPad.
struct RemoveButton: View {
    var label = String(localized: "Remove")
    let action: () -> Void

    var body: some View {
        VFIconButton("minus.circle.fill", label: label, size: 14, role: .destructive, action: action)
    }
}
