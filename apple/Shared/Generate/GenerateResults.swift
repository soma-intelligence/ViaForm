import Charts
import SwiftUI

/// The picked candidate's analysis: its figures against the limits, every load case, how the
/// optimiser converged, its natural modes and its impacts in time.
struct GenerateResults: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: GenerateModel
    let design: DesignModel

    var body: some View {
        if let c = model.candidate, let s = model.studied {
            Form {
                Section {
                    HStack {
                        Text("Candidate \(c.id + 1)").font(VFFont.title).foregroundStyle(theme.ink)
                        if model.selected == model.outcome?.best {
                            Label("Best", systemImage: "star.fill")
                                .font(VFFont.small)
                                .foregroundStyle(theme.accentText)
                        }
                        Spacer()
                        FeasibleBadge(feasible: c.feasible)
                    }
                    if !c.converged {
                        StoppedLine(candidate: c)
                    }
                    if model.stale {
                        Label("The setup changed since this run. Build uses the study as it was run.", systemImage: "exclamationmark.circle")
                            .font(VFFont.row)
                            .foregroundStyle(theme.warning)
                    }
                    MetricGrid(candidate: c, study: s)
                    ForEach(Array(((model.outcome?.warnings ?? []) + c.issues).enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(VFFont.row)
                            .foregroundStyle(c.feasible ? theme.inkSecondary : theme.warning)
                    }
                    Button { model.build(into: design) } label: { Label("Build into the Design", systemImage: "hammer.fill") }
                        .buttonStyle(.vfPrimary(loading: model.building))
                        .vfDisabled(buildBlocked != nil, reason: buildBlocked ?? "")
                    if let i = model.selected { OutcomeActions(model: model, candidate: i) }
                }
                if let i = model.selected {
                    MeshChecksSection(report: model.meshChecks[i], error: model.meshCheckErrors[i]) { model.focus($0) }
                }
                CasesSection(candidate: c, study: s)
                if c.history.count > 1 {
                    Section("Convergence") {
                        let first = c.history.first ?? 0, last = c.history.last ?? 0
                        Chart(Array(c.history.enumerated()), id: \.offset) { i, v in
                            LineMark(x: .value("Iteration", i + 1), y: .value("Objective", v))
                                .foregroundStyle(theme.accent)
                                .interpolationMethod(.monotone)
                        }
                        .chartXAxisLabel("Iteration")
                        .chartYAxisLabel(s.objective == .compliance ? "Weighted compliance, N·mm" : "Objective")
                        .frame(height: 160)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Objective per iteration")
                        .accessibilityValue(Text("\(c.history.count) iterations, from \(String(format: "%.4g", first)) to \(String(format: "%.4g", last))"))
                    }
                }
                if !c.analysis.modes.isEmpty { ModesSection(modes: c.analysis.modes, floor: s.minFrequency) }
                ForEach(Array(c.analysis.impacts.enumerated()), id: \.offset) { _, impact in
                    ImpactSection(impact: impact, study: s)
                }
            }
            .formStyle(.grouped)
        } else if model.running {
            VStack(alignment: .leading, spacing: VFSpace.l) {
                SkeletonBlock().frame(height: 28)
                SkeletonBlock().frame(height: 96)
                SkeletonBlock().frame(height: 160)
                Text("The study is running. Results show here when it ends.")
                    .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                Spacer()
            }
            .padding(VFSpace.xl)
        } else {
            EmptyState(String(localized: "No results yet"), systemImage: "chart.xyaxis.line",
                       message: model.outcome == nil ? (model.readiness ?? String(localized: "Run the study, then pick a candidate."))
                           : String(localized: "Pick a candidate below the preview."),
                       actionTitle: model.outcome == nil && model.readiness == nil ? String(localized: "Run") : nil,
                       action: model.outcome == nil && model.readiness == nil ? { model.run() } : nil)
                .frame(maxHeight: .infinity)
        }
    }

    private var buildBlocked: String? {
        if EngineGate.shared.shut { return EngineGate.reason }
        if model.running { return String(localized: "Wait for the study to finish, or stop it.") }
        if model.building { return String(localized: "Building the candidate now.") }
        return nil
    }
}

/// The headline figures, two to a row; a figure past its limit says so in words and a shape.
struct MetricGrid: View {
    @Environment(\.viaFormTheme) private var theme
    let candidate: StudyCandidate
    let study: Study

    var body: some View {
        let a = candidate.analysis
        Grid(alignment: .leading, horizontalSpacing: VFSpace.xl, verticalSpacing: VFSpace.l) {
            GridRow {
                metric(String(localized: "Mass"), VFFormat.mass(candidate.massG))
                metric(String(localized: "Volume"), String(format: "%.1f %%", candidate.volumeFraction * 100))
            }
            GridRow {
                metric(String(localized: "Safety factor"), formatFactor(a.safetyFactor), warn: a.safetyFactor < study.safetyFactor)
                metric(String(localized: "Peak stress"), "\(Int(a.worstStress.rounded())) MPa", warn: a.worstStress > study.stressLimit)
            }
            GridRow {
                metric(String(localized: "Displacement"), "\(String(format: "%.3g", a.worstDisplacement)) mm",
                       warn: study.maxDisplacement.map { a.worstDisplacement > $0 } ?? false)
                metric(String(localized: "First mode"), a.firstFrequency.map { VFFormat.value($0, .frequency) } ?? "–",
                       warn: (a.firstFrequency ?? .infinity) < (study.minFrequency ?? 0))
            }
        }
    }

    private func metric(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: VFSpace.xxs) {
            Text(label).font(VFFont.small).foregroundStyle(theme.inkSecondary)
            Text(value).font(VFFont.heading.weight(.light)).monospacedDigit().foregroundStyle(warn ? theme.warning : theme.ink)
            if warn {
                Label("Over limit", systemImage: "exclamationmark.triangle.fill")
                    .font(VFFont.micro)
                    .foregroundStyle(theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Per load case: compliance, worst stress and largest displacement, each column named with
/// its unit.
struct CasesSection: View {
    @Environment(\.viaFormTheme) private var theme
    let candidate: StudyCandidate
    let study: Study

    var body: some View {
        let a = candidate.analysis
        let n = max(a.compliance.count, a.maxStress.count, a.maxDisplacement.count)
        if n > 0 {
            Section("Load cases") {
                Grid(alignment: .trailing, horizontalSpacing: VFSpace.l, verticalSpacing: VFSpace.m) {
                    GridRow {
                        Text("Case").gridColumnAlignment(.leading)
                        Text("Compliance\nN·mm")
                        Text("Peak stress\nMPa")
                        Text("Displacement\nmm")
                    }
                    .font(VFFont.micro)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(theme.inkSecondary)
                    ForEach(0..<n, id: \.self) { i in
                        let name = study.cases[safe: i].map { $0.name.isEmpty ? String(localized: "Case \(i + 1)") : $0.name } ?? String(localized: "Case \(i + 1)")
                        let over = (a.maxStress[safe: i] ?? 0) > study.stressLimit
                        GridRow {
                            Text(name)
                                .lineLimit(2)
                                .gridColumnAlignment(.leading)
                            Text(format(a.compliance[safe: i], "%.4g"))
                            HStack(spacing: VFSpace.xxs) {
                                if over { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
                                Text(format(a.maxStress[safe: i], "%.0f"))
                            }
                            .foregroundStyle(over ? theme.warning : theme.ink)
                            Text(format(a.maxDisplacement[safe: i], "%.3g"))
                        }
                        .monospacedDigit()
                        .font(VFFont.row)
                        .foregroundStyle(theme.ink)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(name): compliance \(format(a.compliance[safe: i], "%.4g")) N·mm, peak stress \(format(a.maxStress[safe: i], "%.0f")) MPa\(over ? String(localized: ", over the limit") : ""), displacement \(format(a.maxDisplacement[safe: i], "%.3g")) mm"))
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
    @Environment(\.viaFormTheme) private var theme
    let modes: [StudyMode]
    let floor: Double?

    var body: some View {
        let below = String(localized: "Below the floor"), above = String(localized: "Above the floor")
        Section("Natural modes") {
            Chart {
                ForEach(Array(modes.enumerated()), id: \.offset) { i, m in
                    BarMark(x: .value("Mode", "\(i + 1)"), y: .value("Frequency", m.frequency.isFinite ? m.frequency : 0))
                        .foregroundStyle(by: .value("Against the floor", floor.map { m.frequency < $0 } ?? false ? below : above))
                }
                if let floor {
                    RuleMark(y: .value("Floor", floor))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(theme.inkSecondary)
                        .annotation(position: .top, alignment: .leading) { Text("floor").font(VFFont.micro).foregroundStyle(theme.inkSecondary) }
                }
            }
            .chartForegroundStyleScale([above: theme.accent, below: theme.warning])
            .chartLegend(floor == nil ? .hidden : .visible)
            .chartXAxisLabel("Mode")
            .chartYAxisLabel("Frequency, Hz")
            .frame(height: 140)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Natural frequencies")
            .accessibilityValue(Text(modes.enumerated().map { "\(String(localized: "mode \($0.offset + 1)")) \(String(format: "%.0f", $0.element.frequency)) Hz" }.joined(separator: ", ")))
            ForEach(Array(modes.enumerated()), id: \.offset) { i, m in
                LabeledContent {
                    Text(participation(m)).font(VFFont.small).monospacedDigit().foregroundStyle(theme.inkSecondary)
                } label: {
                    Text("Mode \(i + 1)  \(m.frequency.isFinite ? VFFormat.value(m.frequency, .frequency) : "–")").monospacedDigit()
                }
            }
        }
    }

    private func participation(_ m: StudyMode) -> String {
        guard m.participation.count == 3 else { return "" }
        return zip(["x", "y", "z"], m.participation).map { String(format: "%@ %.0f %%", $0, $1 * 100) }.joined(separator: "  ")
    }
}

/// One impact over time: the worst stress and the largest displacement, each with its limit.
struct ImpactSection: View {
    @Environment(\.viaFormTheme) private var theme
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
        let name = study.cases[safe: impact.caseIndex].map { $0.name.isEmpty ? String(localized: "Case \(impact.caseIndex + 1)") : $0.name }
            ?? String(localized: "Case \(impact.caseIndex + 1)")
        let over = impact.peakStress > study.stressLimit
        let response = String(localized: "Response"), limit = String(localized: "Limit")
        Section {
            LabeledContent("Peak stress") {
                HStack(spacing: VFSpace.xxs) {
                    if over { Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true) }
                    Text(over ? "\(Int(impact.peakStress.rounded())) MPa, over limit" : "\(Int(impact.peakStress.rounded())) MPa").monospacedDigit()
                }
                .foregroundStyle(over ? theme.warning : theme.ink)
            }
            LabeledContent("Peak displacement") { Text("\(String(format: "%.3g", impact.peakDisplacement)) mm").monospacedDigit() }
            LabeledContent("Dynamic amplification") { Text("\(String(format: "%.2f", impact.amplification))×").monospacedDigit() }
            let data = samples
            if data.count > 1 {
                Chart {
                    ForEach(data) {
                        LineMark(x: .value("Time", $0.ms), y: .value("Stress", $0.stress))
                            .foregroundStyle(by: .value("Series", response))
                    }
                    RuleMark(y: .value("Limit", study.stressLimit))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(by: .value("Series", limit))
                }
                .chartForegroundStyleScale([response: theme.accent, limit: theme.warning])
                .chartXAxisLabel("Time, ms")
                .chartYAxisLabel("Von Mises stress, MPa")
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Worst stress over time")
                .accessibilityValue(Text("Peak \(Int(impact.peakStress.rounded())) MPa, limit \(Int(study.stressLimit.rounded())) MPa"))
                Chart {
                    ForEach(data) {
                        LineMark(x: .value("Time", $0.ms), y: .value("Displacement", $0.displacement))
                            .foregroundStyle(by: .value("Series", response))
                    }
                    if let limit = study.maxDisplacement {
                        RuleMark(y: .value("Limit", limit))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(by: .value("Series", String(localized: "Limit")))
                    }
                }
                .chartForegroundStyleScale([response: theme.accent, limit: theme.warning])
                .chartXAxisLabel("Time, ms")
                .chartYAxisLabel("Displacement, mm")
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Largest displacement over time")
                .accessibilityValue(Text("Peak \(String(format: "%.3g", impact.peakDisplacement)) mm"))
            }
        } header: {
            Text("Impact on \(name)")
        }
    }
}
