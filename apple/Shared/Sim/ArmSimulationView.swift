import simd
import Charts
import SwiftUI

/// The Simulate stage of an articulated product (VIAFORM-SPEC 7.5): the viewport with its HUD,
/// the scenario card (what it was built on, "Re-run on Assembly vN"), the telemetry panel with
/// a shared playhead, the episodes, demo replay and "Stress here".
struct ArmSimulationView: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var sim: ArmSimModel
    @Bindable var assemble: AssembleModel
    let flow: FlowModel
    /// Opens Generate after load cases were handed over.
    var openGenerate: () -> Void = {}
    var addLoadCases: (LoadsHandOff) -> Void = { _ in }
    @State private var scene = AssembleScene()
    @State private var labels = AssembleLabels()
    @State private var loadsAt: Double?
    @State private var showLoads = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if sim.available {
                    AssembleSceneView(model: assemble, scene: scene, labels: labels, dark: theme.isDark, tick: sim.poseRevision)
                        .background(theme.viewportGradient)
                } else {
                    ContentUnavailableView("Physics not linked", systemImage: "atom",
                                           description: Text("This build has no viaform-phys. The arm simulation needs it."))
                        .background(theme.viewportGradient)
                }
                scenarioCard.padding(VFSpace.l)
            }
            .overlay(alignment: .topTrailing) { hud.padding(VFSpace.l) }
            .overlay(alignment: .top) { errorBanner }
            VFHairline()
            SimTelemetryPanel(sim: sim, stressHere: { t in loadsAt = t; showLoads = true })
        }
        .onAppear {
            sim.flow = flow
            scene.attach(assemble)
            scene.poseSource = { [weak sim] in sim?.poses ?? [:] }
            scene.addObject("cube", box: 30, at: SIMD3(260, 0, 15), hex: 0xD93025)
            launch()
        }
        .sheet(isPresented: $showLoads) {
            LoadsFromSimSheet(sim: sim, assemble: assemble, initialTime: loadsAt, revision: flow.node("assemble.assembly")?.revisionName ?? "Assembly",
                              add: { handOff in
                                  addLoadCases(handOff)
                                  showLoads = false
                                  openGenerate()
                              }, cancel: { showLoads = false })
        }
    }

    private var revision: String { flow.node("assemble.assembly")?.revisionName ?? "Assembly" }

    private var stale: Bool {
        guard let e = sim.episode else { return false }
        return e.revision != revision
    }

    private var scenarioCard: some View {
        VStack(alignment: .leading, spacing: VFSpace.s) {
            HStack {
                VFCaption("Scenario")
                Spacer()
                Picker("Scenario", selection: $sim.scenarioID) {
                    ForEach(sim.scenarios) { Text($0.title).tag($0.id) }
                }
                .labelsHidden().frame(width: 120)
            }
            Text(sim.scenario.detail).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
            AsmRow("Assembly", revision, warn: stale)
            AsmRow("Physics", "viaform-phys, 1 kHz, servos at 50 Hz")
            AsmRow("Randomise", String(format: "mass %.0f %%, friction %.0f %%", sim.randomise.massPct, sim.randomise.frictionPct))
            if stale, let e = sim.episode {
                Text("Last run used \(e.revision).").font(VFFont.small).foregroundStyle(theme.warning)
            }
            HStack(spacing: VFSpace.s) {
                if sim.running {
                    ProgressView(value: sim.progress).frame(maxWidth: .infinity)
                    Button("Stop") { sim.cancelRun() }
                } else {
                    Button {
                        rerun()
                    } label: { Text("Re-run on \(revision)").lineLimit(1).fixedSize().frame(maxWidth: .infinity) }
                        .buttonStyle(.vfPrimary)
                        .disabled(!sim.available || !assemble.isActive)
                    Button {
                        replayDemo()
                    } label: { Label("Replay Demo", systemImage: "play.rectangle") }
                        .disabled(!sim.available || !assemble.isActive)
                        .help("Replays the synthetic robot.demos episode on the servos and compares")
                }
            }
        }
        .padding(VFSpace.l)
        .frame(width: 330)
        .vfSurface(.floating, radius: VFRadius.floating)
    }

    private var hud: some View {
        HStack(spacing: VFSpace.l) {
            hudItem("t", String(format: "%.2f s", sim.running ? (sim.live.last?.t ?? 0) : sim.playhead))
            hudItem("Real time", sim.realTimeFactor > 0 ? String(format: "%.1fx", sim.realTimeFactor) : "n/a")
            hudItem("Episodes", "\(sim.episodes.count)")
        }
        .padding(.horizontal, VFSpace.l).frame(height: 40)
        .vfSurface(.floating, radius: VFRadius.card)
    }

    private func hudItem(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.inkTertiary)
            Text(v).font(VFFont.hud).foregroundStyle(theme.ink)
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let e = sim.error {
            HStack(spacing: VFSpace.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
                Text(e).font(VFFont.small).foregroundStyle(theme.ink).lineLimit(2)
                Button { sim.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.s)
            .vfSurface(.floating, radius: VFRadius.card)
            .padding(.top, 70)
        }
    }

    /// `--sim-run`, `--sim-demo`, `--show-loads`: run once, then open the loads sheet.
    private func launch() {
        guard !ArmSimLaunch.done, ArmSimLaunch.run || ArmSimLaunch.demo else { return }
        ArmSimLaunch.done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if ArmSimLaunch.run { rerun() }
            if ArmSimLaunch.demo {
                if ArmSimLaunch.run { waitIdle { replayDemo() } } else { replayDemo() }
            }
            if let t = ArmSimLaunch.loads {
                waitIdle { loadsAt = t < 0 ? nil : t; showLoads = true }
            }
        }
    }

    private func waitIdle(_ then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if sim.running { waitIdle(then) } else { then() }
        }
    }

    func rerun() {
        guard let a = (try? assemble.engine.call("get"))?["assembly"] as? [String: Any] else { return }
        sim.run(assembly: a, revision: revision)
    }

    func replayDemo() {
        guard let a = (try? assemble.engine.call("get"))?["assembly"] as? [String: Any] else { return }
        let demo = ArmSimModel.syntheticDemo(joints: assemble.joints.count)
        sim.run(assembly: a, revision: revision, demo: demo, title: "Demo 1 replay")
    }
}

/// Telemetry (joint positions or efforts over time, shared playhead) beside the episode list.
struct SimTelemetryPanel: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var sim: ArmSimModel
    var stressHere: (Double) -> Void
    @State private var channel = "Position"

    var body: some View {
        HStack(alignment: .top, spacing: VFSpace.l) {
            VStack(alignment: .leading, spacing: VFSpace.s) {
                HStack(spacing: VFSpace.m) {
                    VFCaption("Telemetry")
                    Picker("Channel", selection: $channel) {
                        Text("Position").tag("Position"); Text("Effort").tag("Effort")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    Button { sim.togglePlay() } label: { Image(systemName: sim.playing ? "pause.fill" : "play.fill") }
                        .disabled(sim.episode == nil || sim.running)
                        .accessibilityLabel(sim.playing ? "Pause" : "Play episode")
                    Text(String(format: "%.2f s", sim.playhead)).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    Spacer()
                    Button { stressHere(sim.playhead) } label: { Label("Stress Here", systemImage: "bolt.horizontal") }
                        .disabled(sim.episode == nil || sim.running || (sim.episode?.wrenches.isEmpty ?? true))
                        .help("Loads at this instant as load cases for Generate")
                }
                .frame(height: 24)
                chart
            }
            episodes.frame(width: 300)
        }
        .padding(.horizontal, VFSpace.l)
        .padding(.vertical, VFSpace.s)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220, alignment: .topLeading)
        .background(theme.panel)
    }

    private struct P: Identifiable { let id: Int; let series: String; let t: Double; let v: Double }

    private var chart: some View {
        let samples = sim.shownSamples
        let names = channel == "Position" ? sim.jointNames : sim.actuatorNames
        var pts: [P] = []
        let stride = max(1, samples.count / 400)
        for (i, s) in samples.enumerated() where i % stride == 0 {
            let vals = channel == "Position" ? s.q : s.effort
            for (j, v) in vals.prefix(names.isEmpty ? 8 : names.count).enumerated() { pts.append(P(id: i * 16 + j, series: j < names.count ? names[j] : "J\(j + 1)", t: s.t, v: v)) }
        }
        let demo = channel == "Position" && !sim.running ? (sim.episode?.demo ?? []) : []
        let dur = max(sim.running ? sim.scenario.duration : (sim.episode?.duration ?? 1), 0.01)
        return Group {
            if pts.isEmpty {
                Text(sim.available ? "Run the scenario to see joint positions and efforts." : "Physics not linked.")
                    .font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("t", p.t), y: .value(channel, p.v))
                            .foregroundStyle(by: .value("Joint", p.series))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    ForEach(Array(demo.enumerated()).filter { $0.offset % 3 == 0 }, id: \.offset) { _, d in
                        ForEach(Array(d.q.prefix(6).enumerated()), id: \.offset) { _, v in
                            PointMark(x: .value("t", d.t), y: .value(channel, v)).symbolSize(3).foregroundStyle(theme.inkTertiary)
                        }
                    }
                    if !sim.running {
                        RuleMark(x: .value("Playhead", sim.playhead)).foregroundStyle(theme.accent).lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartForegroundStyleScale(range: MotionStudyPanel.palette)
                .chartXScale(domain: 0...dur)
                .chartLegend(position: .trailing, alignment: .center)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(theme.hairline)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(channel == "Position" ? String(format: "%.0f°", d) : String(format: "%.1f", d)) } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { v in
                    AxisGridLine().foregroundStyle(theme.hairline)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f s", d)) } }
                } }
                .chartOverlay { proxy in
                    GeometryReader { g in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { e in
                                guard !sim.running, let plot = proxy.plotFrame else { return }
                                if let t: Double = proxy.value(atX: e.location.x - g[plot].origin.x) { sim.stop(); sim.scrub(to: t) }
                            })
                    }
                }
            }
        }
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            VFCaption("Episodes")
            if sim.episodes.isEmpty {
                Text("No runs yet.").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sim.episodes.reversed()) { e in
                        Button { sim.select(e.id) } label: {
                            HStack(spacing: VFSpace.s) {
                                Image(systemName: e.demo != nil ? "play.rectangle" : "play.circle")
                                    .foregroundStyle(e.ok ? theme.success : theme.warning)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).lineLimit(1)
                                    Text("\(e.revision) · \(e.result)").font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, VFSpace.s).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(sim.episode?.id == e.id ? theme.selection : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The Simulate inspector for an articulated product: scenario, sim-to-real parameters.
struct ArmSimInspector: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var sim: ArmSimModel
    let flow: FlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.l) {
            AsmSection("Scenario") {
                AsmRow("Scenario", sim.scenario.title)
                AsmRow("Duration", String(format: "%.1f s", sim.scenario.duration))
                AsmRow("Physics rate", "1000 Hz")
                AsmRow("Control rate", "50 Hz")
                AsmRow("Built on", flow.node("assemble.assembly")?.revisionName ?? "Assembly")
            }
            AsmSection("Randomise (sim to real)") {
                AsmNumberRow("Mass", sim.randomise.massPct, "%") { sim.randomise.massPct = max(0, $0) }
                AsmNumberRow("Friction", sim.randomise.frictionPct, "%") { sim.randomise.frictionPct = max(0, $0) }
                AsmNumberRow("Latency", sim.randomise.latencyMS, "ms") { sim.randomise.latencyMS = max(0, $0) }
                AsmNumberRow("Backlash", sim.randomise.backlashDeg, "deg") { sim.randomise.backlashDeg = max(0, $0) }
                AsmNumberRow("Seed", Double(sim.randomise.seed), "") { sim.randomise.seed = Int($0) }
                Text("Same seed, same trajectory.").font(VFFont.small).foregroundStyle(theme.inkTertiary)
            }
            if let e = sim.episode {
                AsmSection("Episode") {
                    AsmRow("Run", e.title)
                    AsmRow("Assembly", e.revision)
                    AsmRow("Duration", String(format: "%.2f s", e.duration))
                    AsmRow("Samples", "\(e.samples.count)")
                    AsmRow("Wrench bodies", e.wrenches.map(\.body).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", "))
                    Text(e.result).font(VFFont.small).foregroundStyle(e.ok ? theme.success : theme.warning)
                }
            }
            Button {} label: { Text("Use as Training Scenario").frame(maxWidth: .infinity) }
                .disabled(true)
                .help("Phase 4: Train")
        }
    }
}
