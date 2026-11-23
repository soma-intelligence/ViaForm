import simd
import Charts
import SwiftUI

/// What the loads sheet hands to the Generate study: the picked instants of one run's wrench
/// history on one body, with the link back to the run (`viaform-loads` v1). The study turns
/// each into a load case; the file is also written next to the project's autosave so the Rust
/// G3 step (`loads_from_sim`) can read the same thing once it exists.
struct LoadsHandOff: Equatable {
    struct Case: Equatable, Identifiable {
        var id: Double { t }
        var t: Double
        var force: SIMD3<Double>
        var torque: SIMD3<Double>
        var at: SIMD3<Double>
    }
    var run: String
    var scenario: String
    var revision: String
    var body: String
    var pick: String
    var cases: [Case]

    var json: [String: Any] {
        ["format": "viaform-loads", "version": 1,
         "source": ["run": run, "scenario": scenario, "assembly_revision": revision],
         "body": body, "pick": pick, "units": ["force": "N", "torque": "N·m", "at": "m"],
         "cases": cases.map { c in
             ["t": c.t, "force_n": [c.force.x, c.force.y, c.force.z], "torque_nm": [c.torque.x, c.torque.y, c.torque.z], "at_m": [c.at.x, c.at.y, c.at.z]] as [String: Any]
         }]
    }

    /// Writes the hand-off to Application Support/ViaForm/loads; returns the file.
    @discardableResult
    func write() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("ViaForm/loads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(scenario)-\(run.replacingOccurrences(of: " ", with: "_"))-\(body).json")
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

/// "Loads from simulation" (VIAFORM-SPEC 7.10.2): runs of the current assembly on the left, the
/// wrench magnitude of the generated part over time with its peaks in the centre, the pick mode
/// and the resulting load cases on the right.
struct LoadsFromSimSheet: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var sim: ArmSimModel
    let assemble: AssembleModel
    /// "Stress here" preselects At time at this instant.
    var initialTime: Double?
    let revision: String
    var add: (LoadsHandOff) -> Void
    var cancel: () -> Void
    @State private var runID: Int?
    @State private var body_ = "forearm"
    @State private var mode = "Peaks"
    @State private var count = 4
    @State private var at = 0.0
    @State private var checked: Set<Double> = []

    private var episodes: [ArmSimModel.Episode] { sim.episodes.filter { !$0.wrenches.isEmpty } }
    private var run: ArmSimModel.Episode? { episodes.first { $0.id == runID } ?? episodes.last }
    private var wrench: ArmSimModel.Wrench? { run?.wrenches.first { $0.body == body_ } ?? run?.wrenches.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Loads from simulation").font(VFFont.heading).foregroundStyle(theme.ink)
                Spacer()
                VFIconButton("xmark", label: String(localized: "Close")) { cancel() }.keyboardShortcut(.cancelAction)
            }
            .padding(VFSpace.xl)
            VFHairline()
            HStack(alignment: .top, spacing: 0) {
                runs.frame(width: 220).padding(VFSpace.l)
                VFHairline(vertical: true)
                centre.frame(minWidth: 380).padding(VFSpace.l)
                VFHairline(vertical: true)
                picks.frame(width: 300).padding(VFSpace.l)
            }
            VFHairline()
            HStack {
                Text("Load cases keep a link to their run. When the assembly changes, they show as stale with Refresh.")
                    .font(VFFont.small).foregroundStyle(theme.inkTertiary)
                Spacer()
                Button("Cancel") { cancel() }
                Button("Add \(selectedCases.count) load case\(selectedCases.count == 1 ? "" : "s")") { handOff() }
                    .buttonStyle(.vfPrimary)
                    .vfDisabled(selectedCases.isEmpty, reason: String(localized: "Pick at least one instant."))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(VFSpace.l)
        }
        .frame(width: 980, height: 600)
        .background(theme.panel)
        .onAppear {
            runID = runID ?? episodes.last?.id
            if let t = initialTime { mode = "At time"; at = t } else if let r = run { at = r.duration / 2 }
            body_ = wrench?.body ?? body_
            checkAll()
        }
        .onChange(of: mode) { _, _ in checkAll() }
        .onChange(of: count) { _, _ in checkAll() }
        .onChange(of: runID) { _, _ in checkAll() }
        .onChange(of: body_) { _, _ in checkAll() }
        .onChange(of: at) { _, _ in if mode == "At time" { checkAll() } }
    }

    // MARK: Runs

    private var runs: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            VFCaption("Simulation runs")
            if episodes.isEmpty {
                EmptyState(String(localized: "No runs yet"), systemImage: "play.circle",
                           message: String(localized: "No run with force records on \(revision). Run a scenario in Simulate first."))
            }
            ForEach(episodes.reversed()) { e in
                Button { runID = e.id } label: {
                    HStack(spacing: VFSpace.s) {
                        Image(systemName: "play.circle").font(VFFont.glyph(18)).foregroundStyle(theme.accentText)
                        VStack(alignment: .leading, spacing: VFSpace.xxs / 2) {
                            Text(e.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                            if e.revision != revision {
                                Text("Built on \(e.revision)").font(VFFont.micro).foregroundStyle(theme.warning)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(VFSpace.s)
                    .background(RoundedRectangle(cornerRadius: VFRadius.card).fill(run?.id == e.id ? theme.accent.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: Chart

    private struct WP: Identifiable { let id: Int; let t: Double; let f: Double }

    private var centre: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            HStack {
                Text("\((wrench?.body ?? body_).replacingOccurrences(of: "_", with: " ").capitalized) forces").font(VFFont.title).foregroundStyle(theme.ink)
                Spacer()
                Picker("Body", selection: $body_) {
                    ForEach(run?.wrenches.map(\.body) ?? [], id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            if let w = wrench, !w.t.isEmpty {
                let pts = w.t.indices.map { WP(id: $0, t: w.t[$0], f: w.magnitude($0)) }
                let marks = selectedCases
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Time", p.t), y: .value("Force", p.f)).foregroundStyle(theme.accent).lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    ForEach(cases) { c in
                        PointMark(x: .value("Time", c.t), y: .value("Force", simd_length(c.force)))
                            .foregroundStyle(marks.contains(c) ? theme.danger : theme.inkTertiary).symbolSize(42)
                    }
                    RuleMark(x: .value("At", at)).foregroundStyle(theme.accent.opacity(mode == "At time" ? 1 : 0.35))
                }
                .chartXAxisLabel("Time (s)")
                .chartYAxisLabel("Force magnitude (N)")
                .chartOverlay { proxy in
                    GeometryReader { g in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { e in
                                guard let plot = proxy.plotFrame else { return }
                                if let t: Double = proxy.value(atX: e.location.x - g[plot].origin.x) { at = max(0, t); mode = "At time" }
                            })
                    }
                }
                .frame(minHeight: 300)
                HStack {
                    Slider(value: $at, in: 0...max(w.t.last ?? 1, 0.01))
                    Text(String(format: "%.2f s", at)).font(VFFont.row).foregroundStyle(theme.inkSecondary).frame(width: 60)
                }
            } else {
                EmptyState(String(localized: "No forces recorded"), systemImage: "waveform.path.ecg",
                           message: String(localized: "This run recorded no forces on the part."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Picks

    private var picks: some View {
        VStack(alignment: .leading, spacing: VFSpace.m) {
            Picker("Pick", selection: $mode) {
                Text("Peaks").tag("Peaks"); Text("Envelope").tag("Envelope"); Text("At time").tag("At time")
            }
            .pickerStyle(.segmented).labelsHidden()
            if mode != "At time" {
                IntRow(String(localized: "Instants"), value: $count, range: 1...12)
                    .font(VFFont.row)
            }
            VFCaption("Load cases")
            HStack {
                Text("").frame(width: 18)
                Text("Time").frame(width: 60, alignment: .leading)
                Text("Force").frame(width: 70, alignment: .trailing)
                Text("Moment").frame(width: 80, alignment: .trailing)
            }
            .font(VFFont.small).foregroundStyle(theme.inkSecondary)
            ScrollView {
                VStack(spacing: VFSpace.xxs) {
                    ForEach(cases) { c in
                        Toggle(isOn: Binding(get: { checked.contains(c.t) }, set: { on in if on { checked.insert(c.t) } else { checked.remove(c.t) } })) {
                            HStack {
                                Text(String(format: "t %.2f s", c.t)).frame(width: 60, alignment: .leading)
                                Text(String(format: "%.1f N", simd_length(c.force))).frame(width: 70, alignment: .trailing)
                                Text(String(format: "%.2f N·m", simd_length(c.torque))).frame(width: 80, alignment: .trailing)
                            }
                            .font(VFFont.row).foregroundStyle(theme.ink)
                        }
                        .frame(height: 28)
                    }
                }
            }
            Text(mode == "Envelope" ? "Envelope picks instants that cover the load directions, not only the largest." :
                 mode == "Peaks" ? "Peaks are the largest wrenches, merged when closer than 20 ms." :
                 "One instant, as picked on the Simulate timeline.")
                .font(VFFont.small).foregroundStyle(theme.inkTertiary)
        }
    }

    // MARK: Cases

    /// The picked instants (G3 `Pick` done here until `loads_from_sim` exists in Rust).
    private var cases: [LoadsHandOff.Case] {
        guard let w = wrench, !w.t.isEmpty else { return [] }
        func c(_ i: Int) -> LoadsHandOff.Case { .init(t: w.t[i], force: w.force[i], torque: w.torque[i], at: i < w.at.count ? w.at[i] : .zero) }
        switch mode {
        case "At time":
            let i = w.t.indices.min { abs(w.t[$0] - at) < abs(w.t[$1] - at) } ?? 0
            return [c(i)]
        case "Envelope":
            // Farthest-point picks on normalised wrench vectors: directions, then size.
            let scaleF = max(w.force.map(simd_length).max() ?? 1, 1e-9), scaleT = max(w.torque.map(simd_length).max() ?? 1, 1e-9)
            let v = w.t.indices.map { i in [w.force[i].x / scaleF, w.force[i].y / scaleF, w.force[i].z / scaleF, w.torque[i].x / scaleT, w.torque[i].y / scaleT, w.torque[i].z / scaleT] }
            func d(_ a: Int, _ b: Int) -> Double { zip(v[a], v[b]).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } }
            var picked = [w.t.indices.max { w.magnitude($0) < w.magnitude($1) } ?? 0]
            while picked.count < min(count, w.t.count) {
                guard let next = w.t.indices.max(by: { a, b in picked.map { d(a, $0) }.min()! < picked.map { d(b, $0) }.min()! }) else { break }
                if picked.contains(next) { break }
                picked.append(next)
            }
            return picked.sorted().map(c)
        default:
            var order = w.t.indices.sorted { w.magnitude($0) > w.magnitude($1) }
            var out: [Int] = []
            while let i = order.first, out.count < count {
                order.removeFirst()
                if out.allSatisfy({ abs(w.t[$0] - w.t[i]) >= 0.02 }) && isLocalPeak(w, i) { out.append(i) }
            }
            return out.sorted().map(c)
        }
    }

    private func isLocalPeak(_ w: ArmSimModel.Wrench, _ i: Int) -> Bool {
        let m = w.magnitude(i)
        let lo = max(0, i - 3), hi = min(w.t.count - 1, i + 3)
        return (lo...hi).allSatisfy { w.magnitude($0) <= m + 1e-12 }
    }

    private var selectedCases: [LoadsHandOff.Case] { cases.filter { checked.contains($0.t) } }

    private func checkAll() { checked = Set(cases.map(\.t)) }

    private func handOff() {
        guard let r = run else { return }
        let h = LoadsHandOff(run: r.title, scenario: r.scenario, revision: r.revision, body: wrench?.body ?? body_,
                             pick: mode == "At time" ? "at" : (mode == "Envelope" ? "envelope" : "peak"), cases: selectedCases)
        h.write()
        add(h)
    }
}

extension GenerateModel {
    /// Adds the picked instants as load cases of the open study: one case per instant with the
    /// wrench as a force (N) and a moment (N·mm) on the study's load region.
    func addSimulatedCases(_ h: LoadsHandOff) {
        asOneStep(String(localized: "Add Loads from Simulation")) { addCases(h) }
    }

    private func addCases(_ h: LoadsHandOff) {
        if study.cases.count == 1 && study.cases[0].loads.isEmpty { study.cases = [] }
        for c in h.cases {
            addCase()
            let i = study.cases.count - 1
            study.cases[i].name = "\(h.run) t \(String(format: "%.2f", c.t)) s"
            addLoad(.force)
            guard let last = study.cases[i].loads.indices.last else { continue }
            let r = study.cases[i].loads[last].region
            study.cases[i].loads[last].force = c.force
            let m = simd_length(c.torque) * 1000
            if m > 1e-6 {
                study.cases[i].loads.append(.torque(r, center: r.middle, axis: simd_normalize(c.torque), moment: m))
            }
        }
    }
}
