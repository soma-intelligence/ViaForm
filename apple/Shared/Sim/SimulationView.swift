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

    var body: some View {
        Group {
            if compact {
                ZStack {
                    viewport
                    VStack {
                        HStack(alignment: .top) {
                            Spacer()
                            SimTelemetryCard(model: model).frame(width: 220)
                        }
                        Spacer()
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
                                Spacer()
                                SimTelemetryCard(model: model).frame(width: 230)
                            }
                            Spacer()
                            SimTransportBar(model: model, showSetup: nil)
                        }
                        .padding(14)
                    }
                    Divider()
                    SimInspector(model: model).frame(width: 300)
                }
            }
        }
        .onChange(of: model.tick) { _, _ in scene.update(model) }
        .onChange(of: model.camera) { _, _ in scene.update(model) }
        .onAppear {
            scene.update(model)
            if ProcessInfo.processInfo.arguments.contains("--fly") { model.play() }
        }
    }

    private var viewport: some View {
        SceneView(scene: scene.scene, pointOfView: scene.cameraNode, options: [.rendersContinuously])
            .ignoresSafeArea()
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

/// The flight setup (course, weather, brain) and the drone's parts.
struct SimInspector: View {
    @Bindable var model: SimModel

    var body: some View {
        Form {
            Section("Flight") {
                if let c = model.catalog {
                    Picker("Course", selection: $model.options.course) {
                        ForEach(c.courses, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    if model.options.course == "random" {
                        Stepper("Seed \(model.options.seed)", value: $model.options.seed, in: 1...999)
                    }
                    Picker("Weather", selection: $model.options.weather) {
                        ForEach(Array(c.weathers.enumerated()), id: \.offset) { i, w in Text(w.name).tag(i) }
                    }
                    Picker("Brain", selection: $model.options.brain) {
                        ForEach(c.brains, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
            }
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
        .onChange(of: model.options) { _, _ in model.reset() }
    }
}
