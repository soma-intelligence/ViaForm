import Charts
import SceneKit
import SwiftUI

/// The Simulation workspace: the drone flies the course in 3D, with its distance-sensor rays,
/// its trail and the planner's target, under a chosen weather and flight brain. The same layout
/// serves the Mac (side panel on the right) and iPad/iPhone (floating cards, setup in a sheet).
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
                            SimMissionCard(model: model).frame(maxWidth: VFSize.inspectorMin - VFSpace.xl)
                            Spacer()
                            SimTelemetryCard(model: model).frame(width: VFSize.inspectorMin - VFSpace.xxl - VFSpace.xl)
                        }
                        Spacer()
                        if model.isManual {
                            HStack(alignment: .bottom) {
                                SimJoystick(label: String(localized: "Throttle and yaw"), vertical: String(localized: "Throttle"), horizontal: String(localized: "Yaw")) { p in
                                    model.sticks.z = -p.y; model.sticks.yaw = -p.x
                                }
                                Spacer()
                                SimJoystick(label: String(localized: "Pitch and roll"), vertical: String(localized: "Pitch"), horizontal: String(localized: "Roll")) { p in
                                    model.sticks.x = -p.y; model.sticks.y = -p.x
                                }
                            }
                        }
                        SimTransportBar(model: model, showSetup: $showSetup)
                    }
                    .padding(VFSpace.panelPadding)
                }
                .sheet(isPresented: $showSetup) {
                    NavigationStack {
                        SimInspector(model: model)
                            .navigationTitle("Flight setup")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { showSetup = false } }
                            }
                    }
                    .presentationDetents([.medium, .large])
                }
            } else {
                HStack(spacing: 0) {
                    ZStack {
                        viewport
                        VStack {
                            HStack(alignment: .top) {
                                SimMissionCard(model: model).frame(maxWidth: VFSize.inspectorMin)
                                Spacer()
                                SimTelemetryCard(model: model).frame(width: VFSize.inspectorMin - VFSpace.xxl - VFSpace.xs)
                            }
                            Spacer()
                            SimTransportBar(model: model, showSetup: nil)
                        }
                        .padding(VFSpace.overlayInset)
                    }
                    Divider()
                    SimInspector(model: model).frame(width: VFSize.sidePanel)
                }
            }
        }
        .onChange(of: model.tick) { _, _ in scene.update(model) }
        // Here, not in the inspector: on touch screens the inspector is a sheet, often closed.
        // The course is rebuilt once the options settle, not on every tick of a stepper.
        .onChange(of: model.options) { _, _ in model.optionsChanged() }
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
                // Play applies the pending option change first.
                Task { try? await Task.sleep(for: .milliseconds(100)); model.play() }
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
            .accessibilityLabel("Flight view")
            .accessibilityHint(model.isManual ? Text("Fly with W S A D, R F to climb and descend, Q E to yaw.") : Text(""))
            .overlay(alignment: .topLeading) {
                if let error = model.error {
                    ErrorBanner(message: error, retry: { model.reset() }) { model.clearError() }
                        .padding(VFSpace.overlayInset)
                }
            }
    }
}

/// Play, pause, back to the start, run to the end, speed and camera.
struct SimTransportBar: View {
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: SimModel
    var showSetup: Binding<Bool>?

    var body: some View {
        HStack(spacing: VFSpace.l) {
            VFIconButton(model.playing ? "pause.fill" : "play.fill",
                         label: model.playing ? String(localized: "Pause") : String(localized: "Fly"), size: 15) { model.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            VFIconButton("backward.end.fill", label: String(localized: "Back to the start"), size: 15) { model.reset() }
            if model.finishing {
                ProgressView().controlSize(.small)
                    .frame(minWidth: VFSize.minTarget, minHeight: VFSize.minTarget)
                    .accessibilityLabel("Running to the end")
            } else {
                VFIconButton("forward.end.fill", label: String(localized: "Run to the end"), size: 15) { model.finish() }
                    .vfDisabled(model.status?.finished == true, reason: String(localized: "The flight is over. Go back to the start first."))
            }
            Divider().frame(height: VFSize.chip)
            VFSegmented(String(localized: "Speed"), selection: $model.speed, items: [0.25, 1.0, 4.0]) { s in
                switch s {
                case 0.25: String(localized: "¼×")
                case 4.0: String(localized: "4×")
                default: String(localized: "1×")
                }
            }
            .fixedSize()
            VFSegmented(String(localized: "Camera"), selection: $model.camera) { $0.title }
                .fixedSize()
            if let showSetup {
                VFIconButton("slider.horizontal.3", label: String(localized: "Flight setup"), size: 15) { showSetup.wrappedValue = true }
            }
            if let outcome = model.outcome {
                let bad = model.status?.collided == true || model.status?.crashed == true
                Divider().frame(height: VFSize.chip)
                Label(outcome, systemImage: bad ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .foregroundStyle(bad ? theme.danger : theme.success)
                    .font(VFFont.rowEmphasis)
            }
        }
        .font(VFFont.rowEmphasis)
        .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.s)
        .vfSurface(.control)
    }
}

extension SimModel.Camera {
    var title: String {
        switch self {
        case .follow: String(localized: "Follow")
        case .overview: String(localized: "Overview")
        }
    }
}

/// Live readings, as the flight controller and the battery would report them.
struct SimTelemetryCard: View {
    @Environment(\.viaFormTheme) private var theme
    let model: SimModel

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            VFCaption(String(localized: "Telemetry"))
            if let f = model.frame {
                row(String(localized: "Time"), VFFormat.value(f.t, .custom("s")))
                row(String(localized: "Altitude"), String(format: "%.2f m", f.p[2]))
                row(String(localized: "Speed"), String(format: "%.1f m/s", length(f.v)))
                row(String(localized: "Wind"), String(format: "%.1f m/s", length(f.wind)))
                row(String(localized: "Battery"), String(format: "%.0f %%, %.2f V", f.soc * 100, f.voltage))
                row(String(localized: "Waypoint"), String(localized: "\(min(f.planIndex + 1, model.waypointCount)) of \(model.waypointCount)"))
                row(String(localized: "Sensors"), String(localized: "\(f.rays.filter(\.hit).count) echoes"))
            }
            if let s = model.status {
                row(String(localized: "Closest"), s.minClearance > 1e8 ? "–" : String(format: "%.2f m", s.minClearance))
                row(String(localized: "Energy"), String(format: "%.2f Wh", s.energyWh))
            }
        }
        .font(VFFont.small)
        .monospacedDigit()
        .padding(VFSpace.panelPadding)
        .vfSurface(.floating)
    }

    private func length(_ a: [Double]) -> Double { (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot() }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(theme.inkSecondary); Spacer(); Text(v).foregroundStyle(theme.ink) }
            .accessibilityElement(children: .combine)
    }
}

/// The flight setup (mission, course, weather, brain, realism, frame), the stress test's
/// disturbances, the training and the drone's parts.
struct SimInspector: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: SimModel

    var body: some View {
        let _ = units
        Form {
            Section("Flight") {
                if let c = model.catalog {
                    LabeledContent("Mission") {
                        VFMenuPicker(String(localized: "Mission"), selection: $model.options.mission, items: c.missions.map(\.id)) { id in
                            c.missions.first { $0.id == id }?.name ?? id
                        }
                    }
                    if model.options.mission == "course" {
                        LabeledContent("Course") {
                            VFMenuPicker(String(localized: "Course"), selection: $model.options.course, items: c.courses.map(\.id)) { id in
                                c.courses.first { $0.id == id }?.name ?? id
                            }
                        }
                        if model.options.course == "random" {
                            IntRow(String(localized: "Course seed"), value: $model.options.seed, range: 1...999)
                        }
                    }
                    LabeledContent("Weather") {
                        VFMenuPicker(String(localized: "Weather"), selection: $model.options.weather, items: Array(c.weathers.indices)) { i in
                            c.weathers.indices.contains(i) ? c.weathers[i].name : "\(i)"
                        }
                    }
                    LabeledContent("Brain") {
                        VFMenuPicker(String(localized: "Brain"), selection: $model.options.brain,
                                     items: c.brains.map(\.id) + (model.options.customBrain != nil ? ["custom"] : [])) { id in
                            id == "custom" && model.options.customBrain != nil ? String(localized: "Trained here") : (c.brains.first { $0.id == id }?.name ?? id)
                        }
                    }
                    Toggle("Realistic plant and sensors", isOn: model.isStress ? .constant(true) : $model.options.realism)
                        .toggleStyle(.vfSwitch)
                        .vfDisabled(model.isStress, reason: String(localized: "The stress test always flies the realistic plant."))
                    if model.isManual {
                        LabeledContent("Sticks") {
                            VFMenuPicker(String(localized: "Sticks"), selection: $model.options.pilotMode, items: ["position", "angle"]) {
                                $0 == "angle" ? String(localized: "Angle") : String(localized: "Position hold")
                            }
                        }
                    }
                } else {
                    InlineError(String(localized: "The flight simulator did not load."))
                }
            }
            if model.isManual {
                Section("Race") {
                    Text("Fly the three gates in order, then land on the pad. Mac: W S A D move, R F (or ↑ ↓) climb and descend, Q E (or ← →) yaw. iPad: the two sticks.")
                        .font(VFFont.row).foregroundStyle(theme.inkSecondary)
                }
            }
            SimDisturbanceSection(model: model)
            SimFrameSection(model: model)
            SimRealPartsSection(model: model)
            SimTrainingSection(model: model, training: model.training)
            Section {
                if let parts = model.parts {
                    ForEach(parts.parts) { p in
                        VStack(alignment: .leading, spacing: VFSpace.xxs) {
                            HStack {
                                Text(p.qty > 1 ? "\(p.qty) × \(p.role)" : p.role).font(VFFont.rowEmphasis).foregroundStyle(theme.ink)
                                Spacer()
                                Text(p.massG > 0 ? VFFormat.mass(p.massG * Double(p.qty)) : String(localized: "Mass from the model"))
                                    .foregroundStyle(theme.inkSecondary)
                            }
                            Text(p.name).font(VFFont.small).foregroundStyle(theme.inkSecondary)
                            if let url = URL(string: p.url), !p.url.isEmpty {
                                Link("Listing", destination: url).font(VFFont.small)
                            }
                        }
                    }
                } else {
                    EmptyState(String(localized: "No parts list"), systemImage: "shippingbox")
                }
            } header: {
                Text("Parts")
            } footer: {
                if let parts = model.parts {
                    Text("All-up mass \(Int((parts.massKg * 1000).rounded())) g with a 32 g frame. Prices and stock are not checked; nothing is ordered from here.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The stress test's keys: one blow of each kind now, or random ones every 1.5 to 3 s.
struct SimDisturbanceSection: View {
    let model: SimModel

    private static var kinds: [(id: String, name: String, icon: String)] {
        [("kick", String(localized: "Push"), "hand.raised.fill"), ("gust", String(localized: "Gust"), "wind"),
         ("tumble", String(localized: "Flip"), "arrow.triangle.2.circlepath"),
         ("payload", String(localized: "Payload"), "shippingbox.fill"), ("prop", String(localized: "Break a Prop"), "fanblades.slash.fill")]
    }

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: VFSpace.m)], spacing: VFSpace.m) {
                ForEach(Self.kinds, id: \.id) { k in
                    Button { model.disturb(k.id) } label: {
                        Label(k.name, systemImage: k.icon).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.vfSecondary)
                    .vfDisabled(model.status?.finished == true, reason: String(localized: "The flight is over. Go back to the start first."))
                }
            }
            Toggle("Random hits every few seconds", isOn: Binding(get: { model.stabilization?.timed == true }, set: { _ in model.disturb("timed") }))
                .toggleStyle(.vfSwitch)
        } header: {
            Text("Disturbances")
        } footer: {
            Text("Wind comes from the weather; these act on top of it. The stabilization brains on the realistic plant (the Stress test mission) ride them out.")
        }
    }
}

/// The frame the generative design made: found or not, what it builds, flown or not.
struct SimFrameSection: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: SimModel

    var body: some View {
        let _ = units
        Section {
            if let g = model.generatedFrame {
                switch g.airframe {
                case .success(let a):
                    Toggle("Build the drone from it", isOn: $model.useGeneratedFrame)
                        .toggleStyle(.vfSwitch)
                    LabeledContent(a.name, value: String(localized: "\(VFFormat.mass(a.frameG)) frame, \(VFFormat.length(a.armMm)) arm"))
                    LabeledContent("All-up", value: String(localized: "\(VFFormat.mass(a.massKg * 1000)), thrust to weight \(String(format: "%.1f", a.thrustToWeight))"))
                case .failure(let e):
                    InlineError(String(localized: "The generated frame could not be read."), details: e.message,
                                retryTitle: String(localized: "Check Again")) { model.reloadGeneratedFrame() }
                }
            } else {
                EmptyState(String(localized: "No generated frame yet"), systemImage: "airplane",
                           message: String(localized: "The nominal \(VFFormat.length(60)) frame flies until Generate makes one."),
                           actionTitle: String(localized: "Check Again")) { model.reloadGeneratedFrame() }
            }
            if model.generatedFrame != nil {
                Button("Check Again") { model.reloadGeneratedFrame() }
                    .buttonStyle(.vfSecondary)
                    .help("Looks for a newer generated frame")
            }
        } header: {
            Text("Generated frame")
        }
    }
}

/// The drone built from the sourced components: found or not, what it weighs and lifts.
struct SimRealPartsSection: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    @Bindable var model: SimModel

    var body: some View {
        let _ = units
        Section {
            if let r = model.realParts {
                switch r.vehicle {
                case .success(let v):
                    Toggle("Build the drone from them", isOn: $model.useRealParts)
                        .toggleStyle(.vfSwitch)
                    LabeledContent("All-up", value: String(localized: "\(VFFormat.mass(v.massKg * 1000)), thrust to weight \(String(format: "%.1f", v.thrustToWeight))"))
                    LabeledContent("Battery", value: String(localized: "\(Int(v.battery.cells))S, \(Int((v.battery.capacityAh * 1000).rounded())) mAh"))
                    LabeledContent("Placed", value: v.assembly ? String(localized: "\(v.placed) by the assembly, the rest standard") : String(localized: "standard positions"))
                    ForEach(v.components, id: \.ref) { p in
                        HStack {
                            Text(p.qty > 1 ? "\(p.qty) × \(p.category)" : p.category).font(VFFont.row).foregroundStyle(theme.ink)
                            Spacer()
                            Text(p.massG.map { VFFormat.mass($0 * Double(p.qty)) } ?? String(localized: "no mass")).foregroundStyle(theme.inkSecondary)
                        }
                    }
                    if !v.missing.isEmpty {
                        Label("Not in the parts list, catalogue values used: \(v.missing.joined(separator: "; "))", systemImage: "exclamationmark.triangle.fill")
                            .font(VFFont.small).foregroundStyle(theme.warning)
                    }
                case .failure(let e):
                    InlineError(String(localized: "The sourced components could not be read."), details: e.message,
                                retryTitle: String(localized: "Check Again")) { model.reloadGeneratedFrame() }
                }
            } else {
                EmptyState(String(localized: "No sourced components yet"), systemImage: "shippingbox",
                           message: String(localized: "The built-in parts list flies until the drone's parts are sourced."))
            }
        } header: {
            Text("Sourced components")
        }
    }
}

/// Training on the core's threads: what to train, the cost curve live, and flying the result.
struct SimTrainingSection: View {
    @Environment(\.viaFormTheme) private var theme
    let model: SimModel
    @Bindable var training: SimTraining

    var body: some View {
        Section {
            LabeledContent("Train") {
                VFMenuPicker(String(localized: "Train"), selection: $training.target, items: SimTraining.Target.allCases) { $0.name }
            }
            if training.target == .stabilize {
                LabeledContent("Rate loop") {
                    VFMenuPicker(String(localized: "Rate loop"), selection: $training.rateLoop, items: ["pid", "indi"]) {
                        $0 == "indi" ? String(localized: "INDI") : String(localized: "PID")
                    }
                }
            }
            IntRow(String(localized: "Iterations"), value: $training.iterations, range: 1...200)
            IntRow(String(localized: "Candidates per iteration"), value: $training.population, range: 4...64, step: 4)
            HStack(spacing: VFSpace.m) {
                if training.running {
                    ProgressView(value: Double(training.history.count), total: Double(max(training.total, 1)))
                        .accessibilityLabel("Training progress")
                        .accessibilityValue(Text("\(training.history.count) of \(training.total) iterations"))
                    if training.stopping {
                        Text("Stopping…").font(VFFont.row).foregroundStyle(theme.inkSecondary)
                    } else {
                        Button(role: .destructive) { training.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.vfSecondary)
                            .help("Stops after the current iteration and keeps the best brain so far")
                    }
                } else {
                    Button("Start Training") { training.start() }.buttonStyle(.vfPrimary)
                }
            }
            if !training.history.isEmpty {
                let best = String(localized: "Best"), mean = String(localized: "Mean")
                Chart {
                    ForEach(training.history, id: \.self) { p in
                        LineMark(x: .value("Iteration", p.iteration), y: .value("Cost", p.cost), series: .value("Series", best))
                            .foregroundStyle(by: .value("Series", best))
                        LineMark(x: .value("Iteration", p.iteration), y: .value("Cost", p.baseline), series: .value("Series", mean))
                            .foregroundStyle(by: .value("Series", mean))
                    }
                }
                .chartForegroundStyleScale([best: theme.accent, mean: theme.inkTertiary])
                .chartXAxisLabel("Iteration")
                .chartYAxisLabel("Cost (lower is better)")
                .frame(height: 120)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Training cost per iteration")
                .accessibilityValue(Text(costSummary))
                Text("\(stageName): \(training.history.count) of \(training.total) iterations").font(VFFont.small).foregroundStyle(theme.inkSecondary)
            } else if training.running {
                SkeletonBlock().frame(height: 120)
            }
            if let h = training.heldOut {
                let better = h.after < h.before
                LabeledContent("Cost on unseen flights") {
                    Label(String(format: "%.3f to %.3f", h.before, h.after), systemImage: better ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(better ? theme.success : theme.warning)
                        .monospacedDigit()
                }
                .accessibilityValue(Text(better ? "improved" : "not improved"))
            }
            if let brain = training.brainJSON, !training.running {
                Button("Fly This Brain") { model.flyTrained(brain) }.buttonStyle(.vfSecondary)
            }
            if let e = training.error, !training.running {
                InlineError(String(localized: "The training stopped with an error."), details: e,
                            retryTitle: String(localized: "Start Again")) { training.start() }
            }
        } header: {
            Text("Training")
        } footer: {
            Text("Searches the gains (or evolves the neural residual) on randomized weather and drones, then scores the result on flights it never trained on.")
        }
    }

    private var stageName: String {
        switch training.stage {
        case "starting": String(localized: "Starting")
        case "done": String(localized: "Done")
        case "": String(localized: "Training")
        default: training.stage.prefix(1).uppercased() + training.stage.dropFirst()
        }
    }

    private var costSummary: String {
        guard let first = training.history.first, let last = training.history.last else { return "" }
        return String(localized: "\(training.history.count) iterations, best cost from \(String(format: "%.3f", first.cost)) to \(String(format: "%.3f", last.cost))")
    }
}

/// What the mission is doing: the race's countdown and gates, or the stabilization readout.
struct SimMissionCard: View {
    @ObservedUnits private var units
    @Environment(\.viaFormTheme) private var theme
    let model: SimModel

    var body: some View {
        let _ = units
        if let r = model.race {
            VStack(alignment: .leading, spacing: VFSpace.xs) {
                VFCaption(String(localized: "Race"))
                if r.state == "countdown" {
                    Text(String(format: "%.0f", ceil(r.countdown))).font(VFFont.hud).foregroundStyle(theme.ink)
                        .accessibilityLabel(Text("Starts in \(Int(ceil(r.countdown))) seconds"))
                } else {
                    Text(String(format: "%.2f s", r.time)).font(VFFont.hud).foregroundStyle(theme.ink)
                }
                Text(r.next < r.gates ? String(localized: "Gate \(r.next + 1) of \(r.gates)") : String(localized: "Land on the pad"))
                    .font(VFFont.row).foregroundStyle(theme.ink)
                ForEach(Array(r.splits.enumerated()), id: \.offset) { i, t in
                    Text("Gate \(i + 1)  \(String(format: "%.2f s", t))").font(VFFont.small).foregroundStyle(theme.inkSecondary)
                }
            }
            .monospacedDigit()
            .padding(VFSpace.panelPadding)
            .vfSurface(.floating)
        } else if let s = model.stabilization, model.isStress || !s.recoveries.isEmpty {
            VStack(alignment: .leading, spacing: VFSpace.xs) {
                VFCaption(String(localized: "Stabilization"))
                row(String(localized: "Attitude error"), VFFormat.angle(s.attitudeError * 180 / .pi))
                row(String(localized: "Off the point"), String(format: "%.2f m", s.deviation))
                row(String(localized: "Attitude RMS"), VFFormat.angle(s.attitudeRms * 180 / .pi))
                if s.payloadKg > 0 { row(String(localized: "Payload"), VFFormat.mass(s.payloadKg * 1000)) }
                ForEach(Array(s.recoveries.suffix(6).enumerated()), id: \.offset) { _, r in
                    HStack {
                        Image(systemName: r.recoveredAfter == nil ? "hourglass" : "checkmark.circle.fill")
                            .foregroundStyle(r.recoveredAfter == nil ? theme.warning : theme.success)
                            .accessibilityLabel(r.recoveredAfter == nil ? Text("Recovering") : Text("Recovered"))
                        Text(r.kind.capitalized)
                        Spacer()
                        Text(r.recoveredAfter.map { String(format: "%.2f s", $0) } ?? String(format: "%.2f m", r.maxDeviation))
                    }
                    .font(VFFont.small)
                    .foregroundStyle(theme.ink)
                }
            }
            .font(VFFont.small)
            .monospacedDigit()
            .padding(VFSpace.panelPadding)
            .vfSurface(.floating)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(theme.inkSecondary); Spacer(); Text(v).foregroundStyle(theme.ink) }
            .accessibilityElement(children: .combine)
    }
}

/// A thumb stick: drag inside the ring, let go to centre. Reports -1...1 on each axis, y down.
/// VoiceOver adjusts it (swipe up and down for the vertical axis, actions for the other and for
/// centring); on a keyboard the flight keys do the same (W S A D, R F, Q E).
struct SimJoystick: View {
    @Environment(\.viaFormTheme) private var theme
    let label: String
    /// What the vertical and horizontal axes do, for VoiceOver.
    var vertical = ""
    var horizontal = ""
    let onChange: (CGPoint) -> Void
    @State private var knob = CGSize.zero
    @State private var position = CGPoint.zero
    private let radius: CGFloat = 60

    var body: some View {
        VStack(spacing: VFSpace.xs) {
            ZStack {
                Circle().fill(theme.floating)
                Circle().strokeBorder(theme.hairline, lineWidth: 1)
                Circle().fill(theme.accent.opacity(0.85)).frame(width: 46, height: 46).offset(knob)
            }
            .frame(width: radius * 2, height: radius * 2)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        var v = CGSize(width: g.location.x - radius, height: g.location.y - radius)
                        let d = (v.width * v.width + v.height * v.height).squareRoot()
                        if d > radius { v = CGSize(width: v.width / d * radius, height: v.height / d * radius) }
                        set(CGPoint(x: v.width / radius, y: v.height / radius))
                    }
                    .onEnded { _ in set(.zero) }
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Text("\(vertical) \(Int((-position.y * 100).rounded())) %, \(horizontal) \(Int((-position.x * 100).rounded())) %"))
            .accessibilityHint(Text("Swipe up or down to change \(vertical). Use the actions for \(horizontal) and to centre."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(CGPoint(x: position.x, y: max(position.y - 0.25, -1)))
                case .decrement: set(CGPoint(x: position.x, y: min(position.y + 0.25, 1)))
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("\(horizontal) left")) { set(CGPoint(x: max(position.x - 0.25, -1), y: position.y)) }
            .accessibilityAction(named: Text("\(horizontal) right")) { set(CGPoint(x: min(position.x + 0.25, 1), y: position.y)) }
            .accessibilityAction(named: Text("Centre")) { set(.zero) }
            Text(label).font(VFFont.micro).foregroundStyle(theme.inkSecondary)
        }
    }

    private func set(_ p: CGPoint) {
        position = p
        knob = CGSize(width: p.x * radius, height: p.y * radius)
        onChange(p)
    }
}
