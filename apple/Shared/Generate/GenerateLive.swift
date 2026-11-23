import Charts
import SwiftUI

// MARK: Live run

/// The running study as it converges: compliance, volume and peak stress per iteration, the
/// time left at the engine's pace, and pause, resume and stop.
struct LiveRunPanel: View {
    @Bindable var model: GenerateModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.paused ? "Paused" : "Solving").font(.caption.weight(.semibold))
                if let p = model.progress {
                    Text(GenerateRunBar.describe(p)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                Button { model.togglePause() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                }
                .help(model.paused ? "Resume the study" : "Pause after this iteration")
                .accessibilityLabel(model.paused ? "Resume" : "Pause")
                Button(role: .cancel) { model.cancel() } label: { Image(systemName: "stop.fill") }
                    .help("Stop the study")
                    .accessibilityLabel("Stop")
            }
            .buttonStyle(.borderless)
            HStack(spacing: 12) {
                figure("ETA", eta)
                figure("Per iteration", model.progress?.perIteration.map { String(format: "%.2f s", $0) } ?? "–")
                if let last = model.liveSteps.last {
                    figure("Volume", String(format: "%.1f %%", last.volume * 100))
                }
            }
            if model.liveSteps.count > 1 {
                let steps = model.liveSteps.filter { $0.variant == (model.progress?.variant ?? 0) }
                LiveChart(steps: steps, key: \.compliance, title: "Compliance, N·mm", color: .blue)
                LiveChart(steps: steps, key: \.volume, title: "Volume fraction", color: .green)
                LiveChart(steps: steps, key: \.maxStress, title: "Peak stress, MPa", color: .orange)
            } else {
                Text("Waiting for the first iterations").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: compact ? 240 : 280)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var eta: String {
        if model.paused { return "paused" }
        guard let e = model.progress?.eta else { return "–" }
        return readableDuration(max(e, 0))
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }
}

/// One figure against the iteration.
struct LiveChart: View {
    let steps: [GenerateJob.LiveStep]
    let key: KeyPath<GenerateJob.LiveStep, Double>
    let title: String
    let color: Color

    var body: some View {
        let points = steps.filter { $0[keyPath: key].isFinite }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let v = points.last?[keyPath: key] {
                    Text(v >= 100 ? String(format: "%.0f", v) : String(format: "%.3g", v)).font(.caption2.weight(.semibold)).monospacedDigit()
                }
            }
            Chart(points) { s in
                LineMark(x: .value("Iteration", s.iteration), y: .value(title, s[keyPath: key]))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 44)
            .accessibilityLabel("\(title) per iteration")
        }
    }
}

// MARK: Variants

/// Outcome exploration: the study run at once over volume fractions, materials and
/// manufacturing routes (FDM, SLS, CNC 3-axis), compared side by side, and the one picked
/// pushed to the results and built into the design.
struct VariantsForm: View {
    @Bindable var model: GenerateModel
    let design: DesignModel

    var body: some View {
        Form {
            Section {
                fractionsRow
                ForEach(StudyMaterial.presets.map(\.name), id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { model.variantMaterials.contains(name) }, set: { on in
                        if on { if !model.variantMaterials.contains(name) { model.variantMaterials.append(name) } } else { model.variantMaterials.removeAll { $0 == name } }
                    }))
                }
                HStack {
                    ForEach(GenerateModel.Route.allCases) { r in
                        Toggle(r.rawValue, isOn: Binding(get: { model.variantRoutes.contains(r) }, set: { on in
                            if on { model.variantRoutes.insert(r) } else { model.variantRoutes.remove(r) }
                        }))
                        .toggleStyle(.button)
                    }
                }
                HStack {
                    Text("\(model.variantPlan.count) variants, one candidate each, run at once").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if model.exploring {
                        Button("Stop", role: .cancel) { model.stopExploring() }
                    } else {
                        Button { model.explore() } label: { Label("Explore", systemImage: "square.grid.3x2") }
                            .disabled(model.variantPlan.isEmpty || model.running)
                    }
                }
            } header: {
                Text("Vary")
            }
            if !model.variants.isEmpty {
                Section("Compare") {
                    VariantTable(model: model)
                }
                if let i = model.pickedVariant, let v = model.variants[safe: i] {
                    Section {
                        Text("Picked: \(v.label)").font(.callout.weight(.semibold))
                        Button { model.build(into: design) } label: {
                            Label(model.building ? "Building…" : "Build into the design", systemImage: "hammer.fill")
                        }
                        .disabled(model.building || model.running || EngineGate.shared.shut)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var fractionsRow: some View {
        HStack(spacing: 6) {
            Text("Volume %").fixedSize()
            Spacer(minLength: 4)
            ForEach([0.1, 0.15, 0.2, 0.25, 0.3], id: \.self) { f in
                Toggle("\(Int(f * 100))", isOn: Binding(get: { model.variantFractions.contains(f) }, set: { on in
                    if on { model.variantFractions.append(f); model.variantFractions.sort() } else { model.variantFractions.removeAll { $0 == f } }
                }))
                .toggleStyle(.button)
                .font(.caption)
            }
        }
    }
}

/// Every variant's figures side by side; the lightest feasible, safest, stiffest and cheapest
/// are marked, and a tap pushes one to the results.
struct VariantTable: View {
    @Bindable var model: GenerateModel

    var body: some View {
        let done = model.variants.compactMap { v in v.candidate.map { (v.id, $0) } }
        let feasible = done.filter { $0.1.feasible }
        let lightest = feasible.min { $0.1.massG < $1.1.massG }?.0
        let cheapest = done.min { ($0.1.cost ?? .infinity) < ($1.1.cost ?? .infinity) }?.0
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Variant")
                Text("Mass").gridColumnAlignment(.trailing)
                Text("SF").gridColumnAlignment(.trailing)
                Text("δ max").gridColumnAlignment(.trailing)
                Text("f1").gridColumnAlignment(.trailing)
                Text("Cost").gridColumnAlignment(.trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(model.variants) { v in
                GridRow {
                    Button { model.pickVariant(v.id) } label: {
                        HStack(spacing: 4) {
                            if model.pickedVariant == v.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            if v.id == lightest { Image(systemName: "scalemass").foregroundStyle(.green).help("Lightest feasible") }
                            if v.id == cheapest { Image(systemName: "dollarsign.circle").foregroundStyle(.green).help("Cheapest") }
                            Text(v.label).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(v.outcome == nil || model.running)
                    if let c = v.candidate {
                        Text(String(format: "%.1f g", c.massG))
                        Text(formatFactor(c.analysis.safetyFactor)).foregroundStyle(c.feasible ? Color.primary : Color.orange)
                        Text(String(format: "%.3f", c.analysis.worstDisplacement))
                        Text(c.analysis.firstFrequency.map { String(format: "%.0f", $0) } ?? "–")
                        Text(c.cost.map { String(format: "$%.0f", $0) } ?? "–")
                    } else if let e = v.error {
                        Text(e).foregroundStyle(.orange).lineLimit(1).gridCellColumns(5)
                    } else {
                        let p = v.progress
                        ProgressView(value: min(max(p?.fraction ?? 0, 0), 1)).gridCellColumns(5)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
    }
}
