import SwiftUI

/// The Simulation stage of the hand product: a grasp test by joint drive on the generated hand
/// (the hand project's assembly inserted into the design), not the drone's flight. Every
/// movable joint is driven from rest to its fist value and back, the way the joint tool drives
/// it, and the joints are read back. It is kinematic: contacts, tendon loads and grip force are
/// not simulated (sim/ models the drone only), and the stage says so. Without a hand assembly it
/// shows an empty state that says what is missing.
///
/// Opening the hand here reads its project into a model of its own (assembly, joints, summary):
/// the Generate stage keeps its project, studies and setup as the user left them. When the
/// Generate stage already has the hand open, the grasp test uses that one.
struct HandGraspView: View {
    @Environment(\.viaFormTheme) private var palette
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
    /// The hand project read for the grasp test alone, when Generate has another project open.
    @State private var own: GenerateModel?

    /// One close-and-open cycle, seconds.
    static let cycle = 4.0

    /// Generate's model when it has the hand open, else the grasp test's own.
    private var model: GenerateModel { generate.project?.name == "hand" ? generate : (own ?? generate) }

    private var hand: GenerateProject? { model.project?.name == "hand" ? model.project : nil }

    var body: some View {
        Group {
            if let p = hand, p.assembly != nil {
                if model.assemblyLoaded { scenario } else { insert(p) }
            } else {
                empty
            }
        }
        .onAppear {
            if generate.project?.name != "hand", own == nil { own = GenerateModel(reading: "hand") }
        }
        .onDisappear {
            stop()
            model.flushDrives(design: design)
        }
    }

    // MARK: States

    private var empty: some View {
        EmptyState(String(localized: "No hand simulation yet"), systemImage: "hand.raised.slash",
                   message: String(localized: "The grasp test drives the generated hand's joints. Run the hand project's studies and its assembly step in Generate first. The drone's flight does not apply to the hand."))
    }

    private func insert(_ p: GenerateProject) -> some View {
        let s = model.assemblySummary
        let joints = model.joints.filter(\.movable).count
        return EmptyState(String(localized: "Grasp test"), systemImage: "hand.raised",
                          message: s.map { String(localized: "Drives every finger of the generated hand from open to a fist and back, by its joints. Insert the hand's assembly first: \($0.parts) parts, \(joints) movable joints.") }
                              ?? String(localized: "Drives every finger of the generated hand from open to a fist and back, by its joints. Insert the hand's assembly first."),
                          actionTitle: String(localized: "Insert the Hand Assembly")) { model.loadAssembly(into: design) }
            .vfDisabled(EngineGate.shared.shut || model.loadingAssembly,
                        reason: EngineGate.shared.shut ? EngineGate.reason : String(localized: "Inserting the assembly now."))
            .overlay(alignment: .bottom) {
                if model.loadingAssembly {
                    DelayedProgress(label: String(localized: "Inserting the assembly"))
                        .padding(.bottom, VFSpace.xxl)
                }
            }
    }

    private var scenario: some View {
        HStack(spacing: 0) {
            ZStack {
                MetalViewport(model: design, theme: theme)
                    .ignoresSafeArea(edges: compact ? [.horizontal, .bottom] : .all)
                VStack {
                    HStack(alignment: .top) {
                        missionCard.frame(maxWidth: VFSize.inspectorMin)
                        Spacer()
                        readout.frame(width: VFSize.inspectorMin - VFSpace.xxl - VFSpace.xs)
                    }
                    Spacer()
                    transport
                }
                .padding(compact ? VFSpace.panelPadding : VFSpace.overlayInset)
            }
            if !compact {
                Divider()
                jointList.frame(width: VFSize.sidePanel)
            }
        }
        // The slider starts where the joints are (a fist closed elsewhere reads 100 %).
        .onAppear { if !playing { closure = min(max(reached, 0), 1) } }
    }

    // MARK: Cards

    private var movable: [AssemblyJoint] { model.joints.filter(\.movable) }

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
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            VFCaption(String(localized: "Grasp test"))
            Text("Close to a fist, then open").font(VFFont.rowEmphasis).foregroundStyle(palette.ink)
            Text("Joint drive on the generated hand: \(movable.count) joints, \(Self.cycle.formatted()) s a cycle.")
                .font(VFFont.small).foregroundStyle(palette.inkSecondary)
            Label("Kinematic only: contact and grip force are not simulated.", systemImage: "info.circle")
                .font(VFFont.micro).foregroundStyle(palette.warning)
        }
        .padding(VFSpace.panelPadding)
        .vfSurface(.floating)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: VFSpace.xs) {
            VFCaption(String(localized: "Joints"))
            row(String(localized: "Closure"), VFFormat.value(reached * 100, .percent))
            row(String(localized: "Driven"), String(localized: "\(movable.count) joints"))
            row(String(localized: "Cycles"), "\(cycles)")
            row(String(localized: "Time"), String(format: "%.1f s", elapsed))
            if let s = model.assemblySummary, let m = s.massG { row(String(localized: "Hand mass"), VFFormat.mass(m)) }
        }
        .font(VFFont.small)
        .monospacedDigit()
        .padding(VFSpace.panelPadding)
        .vfSurface(.floating)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(palette.inkSecondary); Spacer(); Text(v).foregroundStyle(palette.ink) }
            .accessibilityElement(children: .combine)
    }

    private var transport: some View {
        HStack(spacing: VFSpace.l) {
            VFIconButton(playing ? "pause.fill" : "play.fill",
                         label: playing ? String(localized: "Pause") : String(localized: "Run the grasp test"), size: 15) {
                playing ? stop() : play()
            }
            VFIconButton("hand.raised", label: String(localized: "Open the hand"), size: 15) { stop(); set(0) }
            VFIconButton("hand.raised.fingers.spread.fill", label: String(localized: "Close the fist"), size: 15) { stop(); set(1) }
            Divider().frame(height: VFSize.chip)
            Slider(value: Binding(get: { closure }, set: { stop(); set($0) }), in: 0...1)
                .frame(width: compact ? 140 : 200)
                .accessibilityLabel("Closure")
                .accessibilityValue(VFFormat.value(closure * 100, .percent))
            Text(VFFormat.value(closure * 100, .percent))
                .font(VFFont.rowEmphasis)
                .monospacedDigit()
                .foregroundStyle(palette.ink)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .vfEngineGate()
        .padding(.horizontal, VFSpace.l).padding(.vertical, VFSpace.s)
        .vfSurface(.control)
    }

    private var jointList: some View {
        let groups = Dictionary(grouping: movable, by: \.group)
        return Form {
            Section {
                Text("Each joint is driven within its limits, the same drive as the joint tool. Rest is zero (or the nearest limit); the fist is the flexion end of each joint, with sideways joints centred.")
                    .font(VFFont.small).foregroundStyle(palette.inkSecondary)
            } header: { Text("Grasp test") }
            ForEach(groups.keys.sorted(), id: \.self) { g in
                Section(g.capitalized) {
                    ForEach(groups[g] ?? []) { j in
                        JointSlider(joint: j) { stop(); model.drive(j.name, to: $0, design: design) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Drive

    private func set(_ c: Double) {
        closure = c
        model.grasp(c, design: design)
    }

    /// The cycle advances at the display rate; the model sends the drives to the engine at most
    /// once a frame.
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
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stop() {
        playing = false
        loop?.cancel()
        loop = nil
    }
}
