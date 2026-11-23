import SwiftUI

/// The Simulation stage of the hand product: a grasp test by joint drive on the generated hand
/// (docs/generative/hand/assembly.json inserted into the design), not the drone's flight. Every
/// movable joint is driven from rest to its fist value and back, the way the joint tool drives
/// it, and the joints are read back. It is kinematic: contacts, tendon loads and grip force are
/// not simulated (sim/ models the drone only), and the stage says so. Without a hand assembly it
/// shows an empty state that says what is missing.
struct HandGraspView: View {
    @Bindable var generate: GenerateModel
    let design: DesignModel
    let theme: ViewportTheme
    var compact = false
    @State private var closure = 0.0
    @State private var playing = false
    @State private var loop: Task<Void, Never>?
    @State private var cycles = 0
    @State private var startedAt: Date?
    @State private var elapsed = 0.0

    /// One close-and-open cycle, seconds.
    static let cycle = 4.0

    private var hand: GenerateProject? { generate.project?.name == "hand" ? generate.project : nil }

    var body: some View {
        Group {
            if let p = hand, p.assembly != nil {
                if generate.assemblyLoaded { scenario } else { insert(p) }
            } else {
                empty
            }
        }
        .onAppear {
            if generate.project?.name != "hand", !generate.running { generate.openSample("hand") }
        }
        .onDisappear { stop() }
    }

    // MARK: States

    private var empty: some View {
        ContentUnavailableView {
            Label("No hand simulation yet", systemImage: "hand.raised.slash")
        } description: {
            Text("The grasp test drives the generated hand's joints. It needs docs/generative/hand/assembly.json, which the generative design writes. The drone's flight does not apply to the hand.")
        }
    }

    private func insert(_ p: GenerateProject) -> some View {
        ContentUnavailableView {
            Label("Grasp test", systemImage: "hand.raised")
        } description: {
            let s = generate.assemblySummary
            Text("Drives every finger of the generated hand from open to a fist and back, by its joints. Insert the hand's assembly first\(s.map { ": \($0.parts) parts, \(generate.joints.filter(\.movable).count) movable joints" } ?? "").")
        } actions: {
            Button {
                generate.loadAssembly(into: design)
            } label: {
                if generate.loadingAssembly { ProgressView().controlSize(.small) } else { Label("Insert the Hand Assembly", systemImage: "square.stack.3d.down.right") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(generate.loadingAssembly || EngineGate.shared.shut)
        }
    }

    private var scenario: some View {
        HStack(spacing: 0) {
            ZStack {
                MetalViewport(model: design, theme: theme)
                    .ignoresSafeArea(edges: compact ? [.horizontal, .bottom] : .all)
                VStack {
                    HStack(alignment: .top) {
                        missionCard.frame(maxWidth: 260)
                        Spacer()
                        readout.frame(width: 230)
                    }
                    Spacer()
                    transport
                }
                .padding(compact ? 12 : 14)
            }
            if !compact {
                Divider()
                jointList.frame(width: 320)
            }
        }
        // The slider starts where the joints are (a fist closed elsewhere reads 100 %).
        .onAppear { if !playing { closure = min(max(reached, 0), 1) } }
    }

    // MARK: Cards

    private var movable: [AssemblyJoint] { generate.joints.filter(\.movable) }

    /// How far the joints are from rest toward the fist, as driven (not as asked).
    private var reached: Double {
        let js = movable
        guard !js.isEmpty else { return 0 }
        let parts = js.map { j -> Double in
            let rest = min(max(0, j.limits.lowerBound), j.limits.upperBound)
            let span = j.fistValue - rest
            return abs(span) < 1e-6 ? 1 : (j.value - rest) / span
        }
        return parts.reduce(0, +) / Double(parts.count)
    }

    private var missionCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GRASP TEST").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Text("Close to a fist, then open").font(.callout.weight(.medium))
            Text("Joint drive on the generated hand: \(movable.count) joints, \(Self.cycle.formatted()) s a cycle.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Kinematic only: contact and grip force are not simulated.")
                .font(.caption2).foregroundStyle(.orange)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("JOINTS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            row("Closure", String(format: "%.0f %%", reached * 100))
            row("Driven", "\(movable.count) joints")
            row("Cycles", "\(cycles)")
            row("Time", String(format: "%.1f s", elapsed))
            if let s = generate.assemblySummary, let m = s.massG { row("Hand mass", String(format: "%.0f g", m)) }
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { playing ? stop() : play() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 22) }
                .help(playing ? "Pause" : "Run the grasp test")
            Button { stop(); set(0) } label: { Image(systemName: "hand.raised") }.help("Open the hand")
            Button { stop(); set(1) } label: { Image(systemName: "hand.raised.fingers.spread.fill") }.help("Close the fist")
            Divider().frame(height: 18)
            Slider(value: Binding(get: { closure }, set: { stop(); set($0) }), in: 0...1)
                .frame(width: compact ? 140 : 200)
                .accessibilityLabel("Closure")
            Text(String(format: "%.0f %%", closure * 100)).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .semibold))
        .disabled(EngineGate.shared.shut)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
    }

    private var jointList: some View {
        let groups = Dictionary(grouping: movable, by: \.group)
        return Form {
            Section {
                Text("Each joint is driven within its limits from assembly.json, the same drive as the joint tool. Rest is zero (or the nearest limit); the fist is the flexion end of each joint, abduction centred.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Grasp test") }
            ForEach(groups.keys.sorted(), id: \.self) { g in
                Section(g.capitalized) {
                    ForEach(groups[g] ?? []) { j in
                        JointSlider(joint: j) { stop(); generate.drive(j.name, to: $0, design: design) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Drive

    private func set(_ c: Double) {
        closure = c
        generate.grasp(c, design: design)
    }

    private func play() {
        guard !playing else { return }
        playing = true
        startedAt = Date().addingTimeInterval(-elapsed)
        loop = Task { @MainActor in
            while !Task.isCancelled, playing {
                let t = Date().timeIntervalSince(startedAt ?? Date())
                elapsed = t
                cycles = Int(t / Self.cycle)
                // Close over the first half of the cycle, open over the second, eased.
                let phase = t.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
                let x = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                set(0.5 - 0.5 * cos(.pi * x))
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func stop() {
        playing = false
        loop?.cancel()
        loop = nil
    }
}
