import Charts
import SceneKit
import SwiftUI

/// The Simulation workspace: the drone flies the course in 3D, with its distance-sensor rays,
/// its trail and the planner's target, under a chosen weather and flight brain. The same layout
/// serves the Mac (inspector on the right) and iPad/iPhone (floating cards, setup in a sheet).
struct SimulationView: View {
    @Bindable var model: SimModel
    var compact = false
    @State private var scene = SimScene()
    @State private var showSetup = false
    @State private var keys: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if compact {
                ZStack {
                    viewport
                    VStack {
                        HStack(alignment: .top) {
                            SimMissionCard(model: model).frame(maxWidth: 240)
                            Spacer()
                            SimTelemetryCard(model: model).frame(width: 220)
                        }
                        Spacer()
                        if model.isManual {
                            HStack(alignment: .bottom) {
                                SimJoystick(label: "Throttle · yaw") { p in model.sticks.z = -p.y; model.sticks.yaw = -p.x }
                                Spacer()
                                SimJoystick(label: "Pitch · roll") { p in model.sticks.x = -p.y; model.sticks.y = -p.x }
                            }
                        }
                        SimTransportBar(model: model, showSetup: $showSetup)
                    }
                    .padding(12)
                }
                .sheet(isPresented: $showSetup) {
                    NavigationStack {
                        SimInspector(model: model)
                            .navigationTitle("Flight setup")
                            .toolbar { Button("Done") { showSetup = false } }
                    }
                    .presentationDetents([.medium, .large])
                }
            } else {
                HStack(spacing: 0) {
                    ZStack {
                        viewport
                        VStack {
                            HStack(alignment: .top) {
                                SimMissionCard(model: model).frame(maxWidth: 260)
                                Spacer()
                                SimTelemetryCard(model: model).frame(width: 230)
                            }
                            Spacer()
                            SimTransportBar(model: model, showSetup: nil)
                        }
                        .padding(14)
                    }
                    Divider()
                    SimInspector(model: model).frame(width: 320)
                }
            }
        }
        .onChange(of: model.tick) { _, _ in scene.update(model) }
        // Here, not in the inspector: on touch screens the inspector is a sheet, often closed.
        .onChange(of: model.options) { _, _ in model.reset() }
        .onChange(of: model.camera) { _, _ in scene.update(model) }
        .onAppear {
            scene.update(model)
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--sim-mission"), i + 1 < args.count { model.options.mission = args[i + 1] }
            if args.contains("--sim-realism") { model.options.realism = true }
            // The drone the generative design built: its frame file, then its sourced parts.
            if args.contains("--sim-generated-frame") { model.useGeneratedFrame = true }
            if args.contains("--sim-real-parts") { model.useRealParts = true }
            if args.contains("--fly") {
                // After the options' reset has gone through.
                Task { try? await Task.sleep(for: .milliseconds(400)); model.play() }
            }
            focused = true
        }
    }

    /// The keyboard as sticks: W/S forward and back, A/D left and right, R/F (or the up and down
    /// arrows) climb and descend, Q/E yaw. Held keys add up; letting go centres the stick.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard model.isManual else { return .ignored }
        let k: String = switch press.key {
        case .upArrow: "r"
        case .downArrow: "f"
        case .leftArrow: "q"
        case .rightArrow: "e"
        default: press.characters.lowercased()
        }
        guard ["w", "s", "a", "d", "r", "f", "q", "e"].contains(k) else { return .ignored }
        if press.phase == .up { keys.remove(k) } else { keys.insert(k) }
        let axis = { (plus: String, minus: String) in (keys.contains(plus) ? 1.0 : 0) - (keys.contains(minus) ? 1.0 : 0) }
        model.sticks = SimSticks(x: axis("w", "s"), y: axis("a", "d"), z: axis("r", "f"), yaw: axis("q", "e"))
        if !model.playing, model.status?.finished != true { model.play() }
        return .handled
    }

    private var viewport: some View {
        SceneView(scene: scene.scene, pointOfView: scene.cameraNode, options: [.rendersContinuously])
            // On touch screens the stage's top capsule is a safe-area inset: the scene starts
            // under it instead of drawing up behind it. The other edges still bleed.
            .ignoresSafeArea(edges: compact ? [.horizontal, .bottom] : .all)
            .clipped()
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .all, action: handle)
            .onTapGesture { focused = true }
            .overlay(alignment: .topLeading) {
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(14)
                }
            }
    }
}

/// Play, pause, reset, run to the end, speed and camera.
struct SimTransportBar: View {
    @Bindable var model: SimModel
    var showSetup: Binding<Bool>?

    var body: some View {
        HStack(spacing: 12) {
            Button { model.toggle() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(model.playing ? "Pause" : "Fly")
            Button { model.reset() } label: { Image(systemName: "backward.end.fill") }.help("Back to the start")
            Button { model.runToEnd() } label: { Image(systemName: "forward.end.fill") }.help("Run to the end")
            Divider().frame(height: 18)
            Picker("Speed", selection: $model.speed) {
                Text("¼×").tag(0.25)
                Text("1×").tag(1.0)
                Text("4×").tag(4.0)
            }
            .pickerStyle(.segmented).frame(width: 130).labelsHidden()
            Picker("Camera", selection: $model.camera) {
                ForEach(SimModel.Camera.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 160).labelsHidden()
            if let showSetup {
                Button { showSetup.wrappedValue = true } label: { Image(systemName: "slider.horizontal.3") }
            }
            if let outcome = model.outcome {
                Divider().frame(height: 18)
                Label(outcome, systemImage: model.status?.collided == true || model.status?.crashed == true ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .foregroundStyle(model.status?.collided == true || model.status?.crashed == true ? .red : .green)
                    .font(.callout.weight(.medium))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Live readings, as the flight controller and the battery would report them.
struct SimTelemetryCard: View {
    let model: SimModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TELEMETRY").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            if let f = model.frame {
                row("Time", String(format: "%.1f s", f.t))
                row("Altitude", String(format: "%.2f m", f.p[2]))
                row("Speed", String(format: "%.1f m/s", length(f.v)))
                row("Wind", String(format: "%.1f m/s", length(f.wind)))
                row("Battery", String(format: "%.0f %%  %.2f V", f.soc * 100, f.voltage))
                row("Waypoint", "\(min(f.planIndex + 1, model.waypointCount)) of \(model.waypointCount)")
                row("Sensors", "\(f.rays.filter(\.hit).count) echoes")
            }
            if let s = model.status {
                row("Closest", s.minClearance > 1e8 ? "–" : String(format: "%.2f m", s.minClearance))
                row("Energy", String(format: "%.2f Wh", s.energyWh))
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func length(_ a: [Double]) -> Double { (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot() }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }
}

/// The flight setup (mission, course, weather, brain, realism, frame), the stress test's
/// disturbances, the training and the drone's parts.
struct SimInspector: View {
    @Bindable var model: SimModel

    var body: some View {
        Form {
            Section("Flight") {
                if let c = model.catalog {
                    Picker("Mission", selection: $model.options.mission) {
                        ForEach(c.missions, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if model.options.mission == "course" {
                        Picker("Course", selection: $model.options.course) {
                            ForEach(c.courses, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        if model.options.course == "random" {
                            Stepper("Seed \(model.options.seed)", value: $model.options.seed, in: 1...999)
                        }
                    }
                    Picker("Weather", selection: $model.options.weather) {
                        ForEach(Array(c.weathers.enumerated()), id: \.offset) { i, w in Text(w.name).tag(i) }
                    }
                    Picker("Brain", selection: $model.options.brain) {
                        ForEach(c.brains, id: \.id) { Text($0.name).tag($0.id) }
                        if model.options.customBrain != nil { Text("Trained here").tag("custom") }
                    }
                    Toggle("Realistic plant and sensors", isOn: model.isStress ? .constant(true) : $model.options.realism)
                        .disabled(model.isStress)
                    if model.isManual {
                        Picker("Sticks", selection: $model.options.pilotMode) {
                            Text("Position hold").tag("position")
                            Text("Angle").tag("angle")
                        }
                    }
                }
            }
            if model.isManual {
                Section("Race") {
                    Text("Fly the three gates in order, then land on the pad. Mac: W S A D move, R F (or ↑ ↓) climb and descend, Q E (or ← →) yaw. iPad: the two sticks.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            SimDisturbanceSection(model: model)
            SimFrameSection(model: model)
            SimRealPartsSection(model: model)
            SimTrainingSection(model: model, training: model.training)
            Section {
                if let parts = model.parts {
                    ForEach(parts.parts) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(p.qty > 1 ? "\(p.qty) × \(p.role)" : p.role).font(.callout.weight(.medium))
                                Spacer()
                                Text(p.massG > 0 ? String(format: "%.1f g", p.massG * Double(p.qty)) : "CAD").foregroundStyle(.secondary)
                            }
                            Text(p.name).font(.caption).foregroundStyle(.secondary)
                            if let url = URL(string: p.url), !p.url.isEmpty {
                                Link("Listing", destination: url).font(.caption)
                            }
                        }
                    }
                }
            } header: {
                Text("Parts")
            } footer: {
                if let parts = model.parts {
                    Text(String(format: "All-up mass %.0f g with a 32 g frame. Prices and stock are not checked; nothing is ordered from here.", parts.massKg * 1000))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The stress test's keys: one blow of each kind now, or random ones every 1.5 to 3 s.
struct SimDisturbanceSection: View {
    let model: SimModel

    private static let kinds: [(id: String, name: String, icon: String)] = [
        ("kick", "Push", "hand.raised.fill"), ("gust", "Gust", "wind"), ("tumble", "Flip", "arrow.triangle.2.circlepath"),
        ("payload", "Payload", "shippingbox.fill"), ("prop", "Break a prop", "fanblades.slash.fill"),
    ]

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(Self.kinds, id: \.id) { k in
                    Button { model.disturb(k.id) } label: {
                        Label(k.name, systemImage: k.icon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.status?.finished == true)
                }
            }
            Toggle("Random hits every few seconds", isOn: Binding(get: { model.stabilization?.timed == true }, set: { _ in model.disturb("timed") }))
        } header: {
            Text("Disturbances")
        } footer: {
            Text("Wind comes from the weather; these act on top of it. The stabilization brains on the realistic plant (the Stress test mission) ride them out.")
        }
    }
}

/// The frame the generative design made: found or not, what it builds, flown or not.
struct SimFrameSection: View {
    @Bindable var model: SimModel

    var body: some View {
        Section {
            if let g = model.generatedFrame {
                switch g.airframe {
                case .success(let a):
                    Toggle("Build the drone from it", isOn: $model.useGeneratedFrame)
                    LabeledContent(a.name, value: String(format: "%.1f g frame, %.1f mm arm", a.frameG, a.armMm))
                    LabeledContent("All-up", value: String(format: "%.0f g, thrust to weight %.1f", a.massKg * 1000, a.thrustToWeight))
                case .failure(let e):
                    Text(e.message).font(.callout).foregroundStyle(.red)
                }
                Text(g.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.head)
            } else {
                Text("No generated frame yet (docs/generative/drone-frame.json): the nominal 60 mm frame flies.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Look again") { model.reloadGeneratedFrame() }
        } header: {
            Text("Generated frame")
        }
    }
}

/// The drone built from the sourced components: found or not, what it weighs and lifts.
struct SimRealPartsSection: View {
    @Bindable var model: SimModel

    var body: some View {
        Section {
            if let r = model.realParts {
                switch r.vehicle {
                case .success(let v):
                    Toggle("Build the drone from them", isOn: $model.useRealParts)
                    LabeledContent("All-up", value: String(format: "%.0f g, thrust to weight %.1f", v.massKg * 1000, v.thrustToWeight))
                    LabeledContent("Pack", value: String(format: "%.0fS %.0f mAh", v.battery.cells, v.battery.capacityAh * 1000))
                    LabeledContent("Placed", value: v.assembly ? "\(v.placed) by the assembly, the rest standard" : "standard positions")
                    ForEach(v.components, id: \.ref) { p in
                        HStack {
                            Text(p.qty > 1 ? "\(p.qty) × \(p.category)" : p.category).font(.callout)
                            Spacer()
                            Text(p.massG.map { String(format: "%.1f g", $0 * Double(p.qty)) } ?? "no mass").foregroundStyle(.secondary)
                        }
                    }
                    if !v.missing.isEmpty {
                        Text("Not in the file, catalogue used: " + v.missing.joined(separator: "; ")).font(.caption).foregroundStyle(.orange)
                    }
                case .failure(let e):
                    Text(e.message).font(.callout).foregroundStyle(.red)
                }
            } else {
                Text("No sourced components yet (docs/components/drone.json): the built-in parts list flies.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sourced components")
        }
    }
}

/// Training on the core's threads: what to train, the cost curve live, and flying the result.
struct SimTrainingSection: View {
    let model: SimModel
    @Bindable var training: SimTraining

    var body: some View {
        Section {
            Picker("Train", selection: $training.target) {
                ForEach(SimTraining.Target.allCases) { Text($0.name).tag($0) }
            }
            if training.target == .stabilize {
                Picker("Rate loop", selection: $training.rateLoop) {
                    Text("PID").tag("pid")
                    Text("INDI").tag("indi")
                }
            }
            Stepper("\(training.iterations) iterations", value: $training.iterations, in: 1...200)
            Stepper("\(training.population) candidates each", value: $training.population, in: 4...64, step: 4)
            HStack {
                if training.running {
                    ProgressView(value: Double(training.history.count), total: Double(max(training.total, 1)))
                    Button("Stop", role: .cancel) { training.cancel() }
                } else {
                    Button("Start training") { training.start() }
                }
            }
            if !training.history.isEmpty {
                Chart {
                    ForEach(training.history, id: \.self) { p in
                        LineMark(x: .value("Iteration", p.iteration), y: .value("Cost", p.cost), series: .value("", "best"))
                            .foregroundStyle(Color.accentColor)
                        LineMark(x: .value("Iteration", p.iteration), y: .value("Cost", p.baseline), series: .value("", "mean"))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxisLabel("cost")
                .frame(height: 120)
                Text("\(training.stage): \(training.history.count) of \(training.total)").font(.caption).foregroundStyle(.secondary)
            }
            if let h = training.heldOut {
                LabeledContent("Held-out cost", value: String(format: "%.3f → %.3f", h.before, h.after))
                    .foregroundStyle(h.after < h.before ? .green : .orange)
            }
            if let brain = training.brainJSON, !training.running {
                Button("Fly this brain") { model.flyTrained(brain) }
            }
            if let e = training.error { Text(e).foregroundStyle(.red) }
        } header: {
            Text("Training")
        } footer: {
            Text("Cross-entropy search over the gains, or evolution strategies for the neural residual, on randomized weather and drones. Scored on episodes it never trained on.")
        }
    }
}

/// What the mission is doing: the race's countdown and gates, or the stabilization readout.
struct SimMissionCard: View {
    let model: SimModel

    var body: some View {
        if let r = model.race {
            VStack(alignment: .leading, spacing: 4) {
                Text("RACE").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                if r.state == "countdown" {
                    Text(String(format: "%.0f", ceil(r.countdown))).font(.system(size: 40, weight: .bold).monospacedDigit())
                } else {
                    Text(String(format: "%.2f s", r.time)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                }
                Text(r.next < r.gates ? "Gate \(r.next + 1) of \(r.gates)" : "Land on the pad").font(.callout)
                ForEach(Array(r.splits.enumerated()), id: \.offset) { i, t in
                    Text(String(format: "Gate %d  %.2f s", i + 1, t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if let s = model.stabilization, model.isStress || !s.recoveries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("STABILIZATION").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                row("Attitude error", String(format: "%.1f°", s.attitudeError * 180 / .pi))
                row("Off the point", String(format: "%.2f m", s.deviation))
                row("Attitude RMS", String(format: "%.1f°", s.attitudeRms * 180 / .pi))
                if s.payloadKg > 0 { row("Payload", String(format: "%.0f g", s.payloadKg * 1000)) }
                ForEach(Array(s.recoveries.suffix(6).enumerated()), id: \.offset) { _, r in
                    HStack {
                        Image(systemName: r.recoveredAfter == nil ? "hourglass" : "checkmark.circle.fill")
                            .foregroundStyle(r.recoveredAfter == nil ? Color.orange : Color.green)
                        Text(r.kind.capitalized)
                        Spacer()
                        Text(r.recoveredAfter.map { String(format: "%.2f s", $0) } ?? String(format: "%.2f m", r.maxDeviation))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }
}

/// A thumb stick: drag inside the ring, let go to centre. Reports -1...1 on each axis, y down.
struct SimJoystick: View {
    let label: String
    let onChange: (CGPoint) -> Void
    @State private var knob = CGSize.zero
    private let radius: CGFloat = 60

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1)
                Circle().fill(Color.accentColor.opacity(0.85)).frame(width: 46, height: 46).offset(knob)
            }
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        var v = CGSize(width: g.location.x - radius, height: g.location.y - radius)
                        let d = (v.width * v.width + v.height * v.height).squareRoot()
                        if d > radius { v = CGSize(width: v.width / d * radius, height: v.height / d * radius) }
                        knob = v
                        onChange(CGPoint(x: v.width / radius, y: v.height / radius))
                    }
                    .onEnded { _ in
                        knob = .zero
                        onChange(.zero)
                    }
            )
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
