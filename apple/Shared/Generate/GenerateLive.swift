import Charts
import SwiftUI

// MARK: Live run

/// The running study as it converges: compliance, volume and peak stress per iteration, the
/// time left at the engine's pace, and pause, resume and stop.
struct LiveRunPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack(spacing: VFSpace.m) {
                VStack(alignment: .leading, spacing: VFSpace.xxs) {
                    Text(model.stopping ? "Stopping…" : model.paused ? "Paused" : "Solving").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                    if let p = model.progress {
                        Text(GenerateRunBar.describe(p)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    }
                }
                Spacer(minLength: VFSpace.m)
                VFIconButton(model.paused ? "play.fill" : "pause.fill",
                             label: model.paused ? String(localized: "Resume") : String(localized: "Pause after this iteration")) {
                    model.togglePause()
                }
                VFIconButton("stop.fill", label: String(localized: "Stop and keep the best so far"), role: .destructive) { model.requestStop() }
                    .vfDisabled(model.stopping, reason: String(localized: "Keeping the best design so far."))
            }
            HStack(spacing: VFSpace.l) {
                figure(String(localized: "Time left"), eta)
                figure(String(localized: "Per iteration"), model.progress?.perIteration.map { VFFormat.value($0, .time) } ?? "–")
                if let last = model.liveSteps.last {
                    figure(String(localized: "Volume"), VFFormat.value(last.volume * 100, .percent))
                }
            }
            let steps = model.liveSteps.filter { $0.variant == (model.progress?.variant ?? 0) }
            if steps.count > 1 {
                LiveChart(steps: steps, key: \.compliance, title: String(localized: "Compliance"), unit: "N·mm", color: theme.accent)
                LiveChart(steps: steps, key: \.volume, title: String(localized: "Volume fraction"), unit: "", color: theme.success)
                LiveChart(steps: steps, key: \.maxStress, title: String(localized: "Peak stress"), unit: "MPa", color: theme.warning)
            } else {
                VStack(alignment: .leading, spacing: VFSpace.s) {
                    ForEach(0..<3, id: \.self) { _ in SkeletonBlock().frame(height: 44) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Waiting for the first iterations")
            }
        }
        .frame(width: compact ? VFSize.inspectorMin - VFSpace.xl : VFSize.inspector)
        .padding(VFSpace.panelPadding)
        .vfSurface(.floating)
    }

    private var eta: String {
        if model.paused { return String(localized: "paused") }
        guard let e = model.progress?.eta else { return "–" }
        return readableDuration(max(e, 0))
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            Text(label).font(VFFont.micro).foregroundStyle(theme.inkSecondary)
            Text(value).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One figure against the iteration, its title as the legend and its last value beside it.
struct LiveChart: View {
    @Environment(\.viaFormTheme) private var theme
    let steps: [GenerateJob.LiveStep]
    let key: KeyPath<GenerateJob.LiveStep, Double>
    let title: String
    let unit: String
    let color: Color

    private func format(_ v: Double) -> String {
        let n = v >= 100 ? String(format: "%.0f", v) : String(format: "%.3g", v)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    var body: some View {
        let points = steps.filter { $0[keyPath: key].isFinite }
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            HStack(spacing: VFSpace.xs) {
                Capsule().fill(color).frame(width: 10, height: 3).accessibilityHidden(true)
                Text(unit.isEmpty ? title : "\(title), \(unit)").font(VFFont.micro).foregroundStyle(theme.inkSecondary)
                Spacer()
                if let v = points.last?[keyPath: key] {
                    Text(format(v)).font(VFFont.micro.weight(.semibold)).foregroundStyle(theme.ink)
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(title) per iteration"))
            .accessibilityValue(Text(summary(points)))
        }
    }

    /// "12 iterations, from 340 N·mm to 120 N·mm".
    private func summary(_ points: [GenerateJob.LiveStep]) -> String {
        guard let first = points.first?[keyPath: key], let last = points.last?[keyPath: key] else { return "" }
        return String(localized: "\(points.count) iterations, from \(format(first)) to \(format(last))")
    }
}

// MARK: Variants

/// Outcome exploration: the study run at once over volume fractions, materials and
/// manufacturing routes (FDM, SLS, CNC 3-axis), compared side by side, and the one picked
/// pushed to the results and built into the design.
struct VariantsForm: View {
    @Environment(\.viaFormTheme) private var theme
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
                    Text("\(model.variantPlan.count) variants, one candidate each, run at once").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    Spacer()
                    if model.exploring {
                        Button(role: .destructive) { model.stopExploring() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.vfSecondary)
                    } else {
                        Button { model.explore() } label: { Label("Explore", systemImage: "square.grid.3x2") }
                            .buttonStyle(.vfPrimary)
                            .vfDisabled(exploreBlocked != nil, reason: exploreBlocked ?? "")
                    }
                }
            } header: {
                Text("Vary")
            }
            if model.variants.isEmpty {
                Section {
                    EmptyState(String(localized: "No variants yet"), systemImage: "square.grid.3x2",
                               message: String(localized: "Pick fractions, materials and routes, then Explore to compare them side by side."))
                }
            } else {
                Section {
                    VariantTable(model: model)
                } header: {
                    Text("Compare")
                } footer: {
                    VariantLegend()
                }
                if let i = model.pickedVariant, let v = model.variants[safe: i] {
                    Section {
                        Text("Picked: \(v.label)").font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                        Button { model.build(into: design) } label: { Label("Build into the Design", systemImage: "hammer.fill") }
                            .buttonStyle(.vfPrimary(loading: model.building))
                            .vfDisabled(buildBlocked != nil, reason: buildBlocked ?? "")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var exploreBlocked: String? {
        if model.running { return String(localized: "Wait for the study to finish, or stop it.") }
        if model.variantPlan.isEmpty { return String(localized: "Pick at least one fraction, material and route.") }
        return nil
    }

    private var buildBlocked: String? {
        if EngineGate.shared.shut { return EngineGate.reason }
        if model.running { return String(localized: "Wait for the study to finish, or stop it.") }
        if model.building { return String(localized: "Building the candidate now.") }
        return nil
    }

    private var fractionsRow: some View {
        HStack(spacing: VFSpace.s) {
            Text("Volume, %").fixedSize()
            Spacer(minLength: VFSpace.xs)
            ForEach([0.1, 0.15, 0.2, 0.25, 0.3], id: \.self) { f in
                Toggle("\(Int(f * 100))", isOn: Binding(get: { model.variantFractions.contains(f) }, set: { on in
                    if on { model.variantFractions.append(f); model.variantFractions.sort() } else { model.variantFractions.removeAll { $0 == f } }
                }))
                .toggleStyle(.button)
                .font(VFFont.small)
                .accessibilityLabel(Text("\(Int(f * 100)) percent volume"))
            }
        }
    }
}

/// What the marks beside a variant mean, always visible (not only on hover).
struct VariantLegend: View {
    @Environment(\.viaFormTheme) private var theme

    var body: some View {
        HStack(spacing: VFSpace.l) {
            Label("Picked", systemImage: "checkmark.circle.fill")
            Label("Lightest within the limits", systemImage: "scalemass")
            Label("Cheapest", systemImage: "dollarsign.circle")
        }
        .font(VFFont.micro)
        .foregroundStyle(theme.inkSecondary)
    }
}

/// Every variant's figures with their units; the lightest feasible and the cheapest are
/// marked (with words for VoiceOver), and a tap pushes one to the results.
struct VariantTable: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel

    var body: some View {
        let done = model.variants.compactMap { v in v.candidate.map { (v.id, $0) } }
        let feasible = done.filter { $0.1.feasible }
        let lightest = feasible.min { $0.1.massG < $1.1.massG }?.0
        let cheapest = done.min { ($0.1.cost ?? .infinity) < ($1.1.cost ?? .infinity) }?.0
        VStack(alignment: .leading, spacing: VFSpace.m) {
            ForEach(model.variants) { v in
                Button { model.pickVariant(v.id) } label: {
                    row(v, picked: model.pickedVariant == v.id, lightest: v.id == lightest, cheapest: v.id == cheapest)
                }
                .buttonStyle(.plain)
                .vfDisabled(v.outcome == nil || model.running,
                            reason: model.running ? String(localized: "Wait for the study to finish.") : String(localized: "This variant has no result yet."))
                .accessibilityLabel(Text(label(v, lightest: v.id == lightest, cheapest: v.id == cheapest)))
                .accessibilityAddTraits(model.pickedVariant == v.id ? .isSelected : [])
                if v.id != model.variants.last?.id { Divider() }
            }
        }
    }

    private func row(_ v: GenerateModel.VariantRun, picked: Bool, lightest: Bool, cheapest: Bool) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            HStack(spacing: VFSpace.xs) {
                if picked { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accentText) }
                if lightest { Image(systemName: "scalemass").foregroundStyle(theme.success).help("Lightest within the limits") }
                if cheapest { Image(systemName: "dollarsign.circle").foregroundStyle(theme.success).help("Cheapest") }
                Text(v.label).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).lineLimit(1)
            }
            if let c = v.candidate {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .leading)], alignment: .leading, spacing: VFSpace.xs) {
                    figure(String(localized: "Mass"), VFFormat.mass(c.massG))
                    figure(String(localized: "Safety factor"), formatFactor(c.analysis.safetyFactor), warn: !c.feasible)
                    figure(String(localized: "Max displacement"), "\(String(format: "%.3g", c.analysis.worstDisplacement)) mm")
                    figure(String(localized: "First mode"), c.analysis.firstFrequency.map { VFFormat.value($0, .frequency) } ?? "–")
                    figure(String(localized: "Cost estimate"), VFFormat.money(c.cost, currency: "USD"))
                }
            } else if let e = v.error {
                Label(e, systemImage: "xmark.octagon.fill").font(VFFont.small).foregroundStyle(theme.danger).lineLimit(2)
            } else {
                ProgressView(value: min(max(v.progress?.fraction ?? 0, 0), 1))
                    .accessibilityLabel(Text("\(v.label) progress"))
            }
        }
        .contentShape(Rectangle())
    }

    private func figure(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(VFFont.micro).foregroundStyle(theme.inkSecondary).lineLimit(1)
            HStack(spacing: VFSpace.xxs) {
                if warn { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
                Text(value).monospacedDigit()
            }
            .font(VFFont.small)
            .foregroundStyle(warn ? theme.warning : theme.ink)
        }
    }

    private func label(_ v: GenerateModel.VariantRun, lightest: Bool, cheapest: Bool) -> String {
        var parts = [v.label]
        if lightest { parts.append(String(localized: "lightest within the limits")) }
        if cheapest { parts.append(String(localized: "cheapest")) }
        if let c = v.candidate {
            parts.append(VFFormat.mass(c.massG))
            parts.append(String(localized: "safety factor \(formatFactor(c.analysis.safetyFactor))"))
            if !c.feasible { parts.append(String(localized: "over a limit")) }
            parts.append(VFFormat.money(c.cost, currency: "USD"))
        } else if v.error != nil {
            parts.append(String(localized: "failed"))
        } else {
            parts.append(String(localized: "running"))
        }
        return parts.joined(separator: ", ")
    }
}
