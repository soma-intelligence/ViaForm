import Charts
import SwiftUI

/// The picked candidate's analysis: its figures against the limits, every load case, how the
/// optimiser converged, its natural modes and its impacts in time.
struct GenerateResults: View {
    @Bindable var model: GenerateModel
    let design: DesignModel

    var body: some View {
        if let c = model.candidate, let s = model.studied {
            Form {
                Section {
                    HStack {
                        Text("Candidate \(c.id + 1)").font(.headline)
                        if model.selected == model.outcome?.best {
                            Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Best")
                        }
                        Spacer()
                        FeasibleBadge(feasible: c.feasible)
                    }
                    if model.stale {
                        Label("The setup changed since this run; Build uses the study as it was run.", systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    MetricGrid(candidate: c, study: s)
                    ForEach(Array(((model.outcome?.warnings ?? []) + c.issues).enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(c.feasible ? Color.secondary : Color.orange)
                    }
                    Button { model.build(into: design) } label: {
                        Label(model.building ? "Building…" : "Build into the design", systemImage: "hammer.fill")
                    }
                    .disabled(model.building || model.running || EngineGate.shared.shut)
                }
                CasesSection(candidate: c, study: s)
                if c.history.count > 1 {
                    Section("Convergence") {
                        Chart(Array(c.history.enumerated()), id: \.offset) { i, v in
                            LineMark(x: .value("Iteration", i + 1), y: .value("Objective", v))
                                .interpolationMethod(.monotone)
                        }
                        .chartXAxisLabel("Iteration")
                        .chartYAxisLabel(s.objective == .compliance ? "Weighted compliance, N·mm" : "Objective")
                        .frame(height: 160)
                        .accessibilityLabel("Objective per iteration")
                    }
                }
                if !c.analysis.modes.isEmpty { ModesSection(modes: c.analysis.modes, floor: s.minFrequency) }
                ForEach(Array(c.analysis.impacts.enumerated()), id: \.offset) { _, impact in
                    ImpactSection(impact: impact, study: s)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("No results yet", systemImage: "chart.xyaxis.line")
            } description: {
                Text(model.running ? "The study is running." : "Run the study, then pick a candidate.")
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// The headline figures, two to a row.
struct MetricGrid: View {
    let candidate: StudyCandidate
    let study: Study

    var body: some View {
        let a = candidate.analysis
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                metric("Mass", String(format: "%.1f g", candidate.massG))
                metric("Volume", String(format: "%.1f %%", candidate.volumeFraction * 100))
            }
            GridRow {
                metric("Safety factor", formatFactor(a.safetyFactor), warn: a.safetyFactor < study.safetyFactor)
                metric("Peak stress", String(format: "%.0f MPa", a.worstStress), warn: a.worstStress > study.stressLimit)
            }
            GridRow {
                metric("Displacement", String(format: "%.3g mm", a.worstDisplacement),
                       warn: study.maxDisplacement.map { a.worstDisplacement > $0 } ?? false)
                metric("First mode", a.firstFrequency.map { String(format: "%.0f Hz", $0) } ?? "–",
                       warn: (a.firstFrequency ?? .infinity) < (study.minFrequency ?? 0))
            }
        }
    }

    private func metric(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.light)).monospacedDigit().foregroundStyle(warn ? .orange : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Per load case: compliance, worst stress and largest displacement.
struct CasesSection: View {
    let candidate: StudyCandidate
    let study: Study

    var body: some View {
        let a = candidate.analysis
        let n = max(a.compliance.count, a.maxStress.count, a.maxDisplacement.count)
        if n > 0 {
            Section("Load cases") {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Case").gridColumnAlignment(.leading)
                        Text("N·mm")
                        Text("MPa")
                        Text("mm")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(0..<n, id: \.self) { i in
                        GridRow {
                            Text(study.cases[safe: i].map { $0.name.isEmpty ? "Case \(i + 1)" : $0.name } ?? "Case \(i + 1)")
                                .lineLimit(1)
                                .gridColumnAlignment(.leading)
                            Text(format(a.compliance[safe: i], "%.4g"))
                            Text(format(a.maxStress[safe: i], "%.0f"))
                                .foregroundStyle((a.maxStress[safe: i] ?? 0) > study.stressLimit ? .orange : .primary)
                            Text(format(a.maxDisplacement[safe: i], "%.3g"))
                        }
                        .monospacedDigit()
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func format(_ v: Double?, _ f: String) -> String {
        guard let v, v.isFinite else { return "–" }
        return String(format: f, v)
    }
}

/// Natural frequencies, lowest first, with the floor the study holds.
struct ModesSection: View {
    let modes: [StudyMode]
    let floor: Double?

    var body: some View {
        Section("Natural modes") {
            Chart {
                ForEach(Array(modes.enumerated()), id: \.offset) { i, m in
                    BarMark(x: .value("Mode", "\(i + 1)"), y: .value("Frequency", m.frequency.isFinite ? m.frequency : 0))
                        .foregroundStyle(floor.map { m.frequency < $0 } ?? false ? Color.orange : Color.accentColor)
                }
                if let floor {
                    RuleMark(y: .value("Floor", floor))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) { Text("floor").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .chartXAxisLabel("Mode")
            .chartYAxisLabel("Hz")
            .frame(height: 140)
            ForEach(Array(modes.enumerated()), id: \.offset) { i, m in
                LabeledContent {
                    Text(participation(m)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } label: {
                    Text("Mode \(i + 1)  ") + Text(m.frequency.isFinite ? String(format: "%.1f Hz", m.frequency) : "–").monospacedDigit()
                }
            }
        }
    }

    private func participation(_ m: StudyMode) -> String {
        guard m.participation.count == 3 else { return "" }
        return zip(["x", "y", "z"], m.participation).map { String(format: "%@ %.0f%%", $0, $1 * 100) }.joined(separator: "  ")
    }
}

/// One impact over time: the worst stress and the largest displacement.
struct ImpactSection: View {
    let impact: StudyImpactResponse
    let study: Study

    private struct Sample: Identifiable {
        let id: Int
        let ms: Double
        let stress: Double
        let displacement: Double
    }

    private var samples: [Sample] {
        let n = min(impact.time.count, impact.stress.count, impact.displacement.count)
        return (0..<n).compactMap { i in
            let t = impact.time[i], s = impact.stress[i], d = impact.displacement[i]
            guard t.isFinite, s.isFinite, d.isFinite else { return nil }
            return Sample(id: i, ms: t * 1000, stress: s, displacement: d)
        }
    }

    var body: some View {
        let name = study.cases[safe: impact.caseIndex].map { $0.name.isEmpty ? "Case \(impact.caseIndex + 1)" : $0.name } ?? "Case \(impact.caseIndex + 1)"
        Section {
            LabeledContent("Peak stress") {
                Text(String(format: "%.0f MPa", impact.peakStress)).monospacedDigit()
                    .foregroundStyle(impact.peakStress > study.stressLimit ? .orange : .primary)
            }
            LabeledContent("Peak displacement") { Text(String(format: "%.3g mm", impact.peakDisplacement)).monospacedDigit() }
            LabeledContent("Dynamic amplification") { Text(String(format: "%.2f×", impact.amplification)).monospacedDigit() }
            let data = samples
            if data.count > 1 {
                Chart {
                    ForEach(data) { LineMark(x: .value("Time", $0.ms), y: .value("Stress", $0.stress)) }
                    RuleMark(y: .value("Limit", study.stressLimit))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.orange)
                }
                .chartXAxisLabel("ms")
                .chartYAxisLabel("Von Mises, MPa")
                .frame(height: 140)
                .accessibilityLabel("Worst stress over time")
                Chart {
                    ForEach(data) { LineMark(x: .value("Time", $0.ms), y: .value("Displacement", $0.displacement)) }
                        .foregroundStyle(.teal)
                    if let limit = study.maxDisplacement {
                        RuleMark(y: .value("Limit", limit))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.orange)
                    }
                }
                .chartXAxisLabel("ms")
                .chartYAxisLabel("Displacement, mm")
                .frame(height: 140)
                .accessibilityLabel("Largest displacement over time")
            }
        } header: {
            Text("Impact on \(name)")
        }
    }
}
