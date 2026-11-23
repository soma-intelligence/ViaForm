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
                    EmptyState(String(localized: "Physics not linked"), systemImage: "atom",
                               message: String(localized: "This build has no physics engine. The arm simulation needs it."))
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
            let source = sim
            scene.poseSource = { [weak source] in source?.poses ?? [:] }
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
                .vfDisabled(sim.running, reason: String(localized: "Stop the run to change the scenario"))
            }
            Text(sim.scenario.detail).font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(2)
            AsmRow("Assembly", revision, warn: stale)
            AsmRow("Physics", String(localized: "1 kHz, servos at 50 Hz"))
            AsmRow("Randomise", String(localized: "mass \(VFFormat.value(sim.randomise.massPct, .percent)), friction \(VFFormat.value(sim.randomise.frictionPct, .percent))"))
            if stale, let e = sim.episode {
                Label("Last run used \(e.revision).", systemImage: "exclamationmark.triangle.fill").font(VFFont.small).foregroundStyle(theme.warning)
            }
            HStack(spacing: VFSpace.s) {
                if sim.running {
                    ProgressView(value: sim.progress)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("Simulating \(sim.scenario.title)"))
                        .accessibilityValue(Text("\(Int((sim.progress * 100).rounded())) percent"))
                    Text("\(Int((sim.progress * 100).rounded())) %").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                    Button("Stop") { sim.cancelRun() }
                        .buttonStyle(.vfSecondary)
                        .help("Stop the run and keep what ran (Command-.)")
                } else {
                    let reason = !sim.available ? String(localized: "Needs the physics engine") : String(localized: "Open an assembly first")
                    Button {
                        rerun()
                    } label: { Text("Re-run on \(revision)").lineLimit(1).fixedSize().frame(maxWidth: .infinity) }
                        .buttonStyle(.vfPrimary)
                        .vfDisabled(!sim.available || !assemble.isActive, reason: reason)
                    Button {
                        replayDemo()
                    } label: { Label("Replay Demo", systemImage: "play.rectangle") }
                        .buttonStyle(.vfSecondary)
                        .vfDisabled(!sim.available || !assemble.isActive, reason: reason)
                        .help("Replays a recorded demonstration on the servos and compares")
                }
            }
        }
        .padding(VFSpace.l)
        .frame(width: 330)
        .vfSurface(.floating, radius: VFRadius.floating)
    }

    private var hud: some View {
        HStack(spacing: VFSpace.l) {
            hudItem(String(localized: "Time"), VFFormat.value(sim.running ? (sim.live.last?.t ?? 0) : sim.playhead, .time))
            hudItem(String(localized: "Real time"), sim.realTimeFactor > 0 ? VFFormat.value(sim.realTimeFactor, .custom("x")) : String(localized: "n/a"))
            hudItem(String(localized: "Episodes"), "\(sim.episodes.count)")
        }
        .padding(.horizontal, VFSpace.l).frame(height: 40)
        .vfSurface(.floating, radius: VFRadius.card)
    }

    private func hudItem(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k).textCase(.uppercase).font(VFFont.micro.weight(.semibold)).foregroundStyle(theme.inkTertiary)
            Text(v).font(VFFont.hud).foregroundStyle(theme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var errorBanner: some View {
        if let e = sim.error {
            ErrorBanner(message: e, retry: sim.running || !sim.available ? nil : { sim.clearError(); rerun() },
                        dismiss: { sim.clearError() })
                .padding(.top, VFSpace.paletteTop)
                .padding(.horizontal, VFSpace.bannerInset)
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

    private var position: Bool { sim.channel == .position }

    var body: some View {
        HStack(alignment: .top, spacing: VFSpace.l) {
            VStack(alignment: .leading, spacing: VFSpace.s) {
                HStack(spacing: VFSpace.m) {
                    VFCaption("Telemetry")
                    Picker("Channel", selection: $sim.channel) {
                        ForEach(ArmSimModel.Channel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    VFIconButton(sim.playing ? "pause.fill" : "play.fill",
                                 label: sim.playing ? String(localized: "Pause") : String(localized: "Play the episode"), isOn: sim.playing) {
                        sim.togglePlay()
                    }
                    .vfDisabled(sim.episode == nil || sim.running,
                                reason: sim.running ? String(localized: "A run is going") : String(localized: "No episode yet"))
                    Text(VFFormat.value(sim.playhead, .time)).font(VFFont.row).foregroundStyle(theme.inkSecondary)
                        .accessibilityLabel(Text("Playhead"))
                    Spacer()
                    Button { stressHere(sim.playhead) } label: { Label("Stress Here", systemImage: "bolt.horizontal") }
                        .buttonStyle(.vfSecondary)
                        .vfDisabled(sim.episode == nil || sim.running || (sim.episode?.wrenches.isEmpty ?? true),
                                    reason: sim.running ? String(localized: "A run is going")
                                        : sim.episode == nil ? String(localized: "No episode yet") : String(localized: "This episode recorded no loads"))
                        .help("Loads at this instant as load cases for Generate")
                }
                .frame(minHeight: VFSize.minTarget)
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
        let names = position ? sim.jointNames : sim.actuatorNames
        var pts: [P] = []
        let stride = max(1, samples.count / 400)
        for (i, s) in samples.enumerated() where i % stride == 0 {
            let vals = position ? s.q : s.effort
            for (j, v) in vals.prefix(names.isEmpty ? 8 : names.count).enumerated() {
                pts.append(P(id: i * 16 + j, series: j < names.count ? AsmFormat.title(names[j]) : "J\(j + 1)", t: s.t, v: v))
            }
        }
        let demo = position && !sim.running ? (sim.episode?.demo ?? []) : []
        let dur = max(sim.running ? sim.scenario.duration : (sim.episode?.duration ?? 1), 0.01)
        let channel = sim.channel.title
        return Group {
            if pts.isEmpty {
                if sim.available {
                    EmptyState(String(localized: "No telemetry yet"), systemImage: "chart.xyaxis.line",
                               message: String(localized: "Run the scenario to see joint positions and efforts."))
                } else {
                    EmptyState(String(localized: "Physics not linked"), systemImage: "atom")
                }
            } else {
                Chart {
                    ForEach(pts) { p in
                        LineMark(x: .value("Time", p.t), y: .value(channel, p.v))
                            .foregroundStyle(by: .value("Joint", p.series))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .accessibilityLabel(Text(p.series))
                            .accessibilityValue(Text("\(position ? VFFormat.angle(p.v) : VFFormat.value(p.v, .custom("N·m"))) at \(VFFormat.value(p.t, .time))"))
                    }
                    ForEach(Array(demo.enumerated()).filter { $0.offset % 3 == 0 }, id: \.offset) { _, d in
                        ForEach(Array(d.q.prefix(6).enumerated()), id: \.offset) { _, v in
                            PointMark(x: .value("Time", d.t), y: .value(channel, v)).symbolSize(3).foregroundStyle(theme.inkTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    if !sim.running {
                        RuleMark(x: .value("Playhead", sim.playhead)).foregroundStyle(theme.accent).lineStyle(StrokeStyle(lineWidth: 1.5))
                            .accessibilityLabel(Text("Playhead"))
                            .accessibilityValue(Text(VFFormat.value(sim.playhead, .time)))
                    }
                }
                .chartForegroundStyleScale(range: MotionStudyPanel.palette(theme))
                .chartXScale(domain: 0...dur)
                .chartLegend(position: .trailing, alignment: .center)
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(theme.hairline)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(position ? String(format: "%.0f°", d) : String(format: "%.1f", d)) } }
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
                .accessibilityLabel(Text(position ? "Joint positions over time" : "Joint efforts over time"))
                .accessibilityHint(Text(demo.isEmpty ? "" : "Grey points are the demonstration"))
            }
        }
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            VFCaption("Episodes")
            if sim.episodes.isEmpty {
                EmptyState(String(localized: "No runs yet"), systemImage: "play.circle",
                           message: sim.running ? String(localized: "The first run is going.") : String(localized: "Each run of the scenario is kept here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: VFSpace.xxs) {
                        ForEach(sim.episodes.reversed()) { e in episodeRow(e) }
                    }
                }
            }
        }
    }
}

extension SimTelemetryPanel {
    fileprivate func episodeRow(_ e: ArmSimModel.Episode) -> some View {
        let selected = sim.episode?.id == e.id
        return Button { sim.select(e.id) } label: {
            HStack(spacing: VFSpace.s) {
                Image(systemName: e.demo != nil ? "play.rectangle" : "play.circle")
                    .foregroundStyle(theme.inkSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.title).font(VFFont.rowEmphasis).foregroundStyle(theme.ink).lineLimit(1)
                    Text("\(e.revision) · \(e.result)").font(VFFont.small).foregroundStyle(theme.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                // Passed or not: a shape and a word, not the colour alone.
                VFStatusDot(status: e.ok ? .current : .stale, reason: e.result)
            }
            .padding(.horizontal, VFSpace.s).frame(minHeight: max(36, VFSize.minTarget))
            .background(RoundedRectangle(cornerRadius: VFRadius.chip).fill(selected ? theme.selection : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(e.title): \(e.result)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                AsmRow("Duration", VFFormat.value(sim.scenario.duration, .time))
                AsmRow("Physics rate", "1000 Hz")
                AsmRow("Control rate", "50 Hz")
                AsmRow("Built on", flow.node("assemble.assembly")?.revisionName ?? "Assembly")
            }
            AsmSection("Randomise (sim to real)") {
                AsmNumberRow("Mass", sim.randomise.massPct, "%", range: 0...100) { sim.randomise.massPct = max(0, $0) }
                AsmNumberRow("Friction", sim.randomise.frictionPct, "%", range: 0...100) { sim.randomise.frictionPct = max(0, $0) }
                AsmNumberRow("Latency", sim.randomise.latencyMS, "ms", range: 0...1_000) { sim.randomise.latencyMS = max(0, $0) }
                AsmNumberRow("Backlash", sim.randomise.backlashDeg, "deg", range: 0...45, step: 0.1) { sim.randomise.backlashDeg = max(0, $0) }
                AsmNumberRow("Seed", Double(sim.randomise.seed), "", range: 0...1_000_000) { sim.randomise.seed = Int($0.rounded()) }
                Text("Same seed, same trajectory.").font(VFFont.small).foregroundStyle(theme.inkTertiary)
            }
            if let e = sim.episode {
                AsmSection("Episode") {
                    AsmRow("Run", e.title)
                    AsmRow("Assembly", e.revision)
                    AsmRow("Duration", VFFormat.value(e.duration, .time))
                    AsmRow("Samples", "\(e.samples.count)")
                    AsmRow("Loads recorded on", e.wrenches.map { AsmFormat.title($0.body) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", "))
                    Label(e.result, systemImage: e.ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .font(VFFont.small).foregroundStyle(e.ok ? theme.success : theme.warning)
                }
            }
            Button {} label: { Text("Use as Training Scenario").frame(maxWidth: .infinity) }
                .buttonStyle(.vfSecondary)
                .vfDisabled(true, reason: String(localized: "Comes with the Train stage"))
        }
    }
}
