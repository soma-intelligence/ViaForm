import SwiftUI

/// The Generate workspace: set up a 3D study (design space, material, goal, limits, and the
/// regions that hold, load, keep out and keep in, placed by number or by dragging them in the
/// preview), run it, compare its candidates coloured by stress, read their analysis, and build
/// the one picked into the design. The Mac and a regular-width iPad keep the setup in an
/// inspector on the right; iPhone opens it in a sheet over the preview, as Simulation does.
struct GenerateView: View {
    @Bindable var model: GenerateModel
    let design: DesignModel
    let theme: ViewportTheme
    var compact = false
    @State private var scene: GenerateScene?
    @State private var thumbnails: [Int: GenerateImage] = [:]
    @State private var showSheet = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    /// Inspector beside the preview, or in a sheet.
    private var sideBySide: Bool {
        #if os(iOS)
        return !compact || hSize == .regular
        #else
        return true
        #endif
    }

    var body: some View {
        Group {
            if let scene {
                if sideBySide { wide(scene) } else { narrow(scene) }
            } else {
                Color.clear.onAppear { scene = GenerateScene(theme: theme) }
            }
        }
        .onChange(of: model.study) { _, _ in scene?.update(model) }
        .onChange(of: model.selection) { _, _ in scene?.update(model) }
        .onChange(of: model.activeCase) { _, _ in scene?.update(model) }
        .onChange(of: model.display) { _, _ in scene?.update(model) }
        .onChange(of: model.selected) { _, _ in scene?.update(model) }
        .onChange(of: model.liveVersion) { _, _ in scene?.update(model) }
        .onChange(of: model.running) { _, _ in scene?.update(model) }
        .onChange(of: model.outcomeVersion) { _, _ in
            scene?.update(model)
            renderThumbnails()
        }
        .onChange(of: scene == nil) { _, _ in scene?.update(model) }
    }

    private func wide(_ scene: GenerateScene) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                stage(scene)
                if model.outcome != nil {
                    Divider()
                    CandidateStrip(model: model, thumbnails: thumbnails)
                        .padding(.vertical, 12)
                        .background(.background)
                }
            }
            Divider()
            GenerateInspector(model: model, design: design)
                .frame(width: 340)
        }
    }

    private func narrow(_ scene: GenerateScene) -> some View {
        stage(scene)
            .sheet(isPresented: $showSheet) {
                NavigationStack {
                    GenerateInspector(model: model, design: design)
                        .navigationTitle(model.pane.rawValue)
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar { Button("Done") { showSheet = false } }
                }
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
            }
    }

    /// The preview with its floating controls.
    private func stage(_ scene: GenerateScene) -> some View {
        ZStack {
            Group {
                if model.display == .assembly && model.assemblyLoaded {
                    // The design itself, where the assembly was inserted: its joints move here.
                    MetalViewport(model: design, theme: theme)
                } else {
                    GenerateViewport(model: model, scene: scene)
                }
            }
            .ignoresSafeArea(edges: sideBySide ? [] : .all)
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    if model.running && model.display != .assembly {
                        LiveRunPanel(model: model, compact: !sideBySide)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) {
                            Picker("Display", selection: $model.display) {
                                ForEach(GenerateModel.Display.allCases.filter { $0 != .assembly || model.assemblyLoaded }, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .disabled(model.outcome == nil && !model.assemblyLoaded)
                            Button {
                                if model.display == .assembly { design.zoomToFit() } else { scene.home(model.study) }
                            } label: { Image(systemName: "scope") }
                                .buttonStyle(.bordered)
                                .help("Frame the design space")
                                .accessibilityLabel("Frame the design space")
                        }
                        if model.display == .assembly, let p = model.project {
                            AssemblyBadge(model: model, project: p)
                        }
                        if model.display == .result, let i = model.selected, let p = model.previews[safe: i], let s = model.studied {
                            StressLegend(preview: p, study: s)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let holder = EngineGate.shared.holder {
                    Label { Text(holder + "…") } icon: { ProgressView().controlSize(.small) }
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                MessageBanner(model: design)
                if !sideBySide, model.outcome != nil, model.display == .result {
                    CandidateStrip(model: model, thumbnails: thumbnails, compact: true)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                GenerateRunBar(model: model, design: design, showSetup: sideBySide ? nil : $showSheet)
            }
            .padding(12)
        }
    }

    /// Stills of every candidate for the gallery, one per turn of the run loop.
    private func renderThumbnails() {
        thumbnails = [:]
        let previews = model.previews, version = model.outcomeVersion
        Task {
            for (i, p) in previews.enumerated() {
                await Task.yield()
                guard version == model.outcomeVersion else { return }
                thumbnails[i] = GenerateScene.thumbnail(p, size: CGSize(width: 320, height: 220), theme: theme)
            }
        }
    }
}

// MARK: Run bar

/// Run or cancel, how far the run is, the setup sheet on iPhone, and Build.
struct GenerateRunBar: View {
    @Bindable var model: GenerateModel
    let design: DesignModel
    var showSetup: Binding<Bool>?

    var body: some View {
        HStack(spacing: 12) {
            if model.running {
                Button(role: .cancel) { model.cancel() } label: { Label("Cancel", systemImage: "stop.fill") }
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                    .help("Stop waiting for this run")
            } else {
                Button { model.run() } label: { Label("Run", systemImage: model.outcome == nil ? "play.fill" : "arrow.clockwise") }
                    .fixedSize()
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Run the study")
            }
            if let showSetup {
                Button { showSetup.wrappedValue = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Study setup")
            }
            Divider().frame(height: 20)
            status.frame(minWidth: 60, maxWidth: 360, alignment: .leading)
            Divider().frame(height: 20)
            Button { model.build(into: design) } label: {
                if model.building { ProgressView().controlSize(.small) } else { Label("Build", systemImage: "hammer.fill") }
            }
            .fixedSize()
            .disabled(model.selected == nil || model.building || model.running || EngineGate.shared.shut)
            .help("Build the picked candidate into the design")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .font(.body.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    /// "About 40 s left" while the run is inside its estimate; past it, the time so far and
    /// the estimate it ran over, so the text never reads "24 s of about 2 s".
    static func timing(elapsed: Double, expected: Double, lower: Bool = false) -> String {
        let text = elapsed < expected
            ? "About \(readableDuration(max(expected - elapsed, 1))) left"
            : "\(readableDuration(elapsed)) so far, past the \(readableDuration(expected)) estimate"
        return lower ? text.prefix(1).lowercased() + text.dropFirst() : text
    }

    static func describe(_ p: GenerateJob.Progress) -> String {
        let variant = p.variants > 1 ? "Variant \(p.variant + 1) of \(p.variants), " : ""
        switch p.stage {
        case "analysing": return variant + "analysing"
        case "done": return "Surfacing"
        case "starting": return "Starting"
        default: return variant + "iteration \(p.iteration) of \(p.iterations)"
        }
    }

    @ViewBuilder private var status: some View {
        Group {
            if model.running, let started = model.startedAt {
                TimelineView(.periodic(from: started, by: 0.5)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(started)
                    VStack(alignment: .leading, spacing: 4) {
                        if let p = model.progress, p.iteration > 0 || p.stage != "optimising" {
                            // The engine's own count: iterations, variants, then the analysis.
                            Text(Self.describe(p) + ", " + Self.timing(elapsed: elapsed, expected: model.expected, lower: true))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            ProgressView(value: min(max(p.fraction, 0), 1))
                                .frame(minWidth: 120)
                        } else {
                            Text(Self.timing(elapsed: elapsed, expected: model.expected))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            ProgressView(value: min(elapsed / max(model.expected, 0.1), 0.97))
                                .frame(minWidth: 120)
                        }
                    }
                }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
            } else if let o = model.outcome {
                Text("\(o.candidates.count) candidates in \(readableDuration(o.seconds))")
                    + Text(model.stale ? ", setup changed" : "").foregroundStyle(.orange)
            } else if let notice = model.notice {
                Text(notice).foregroundStyle(.secondary)
            } else {
                Text("Set up the study, then run").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(2)
    }
}

// MARK: Gallery

/// The study's candidates side by side; a tap picks one to show, analyse and build.
struct CandidateStrip: View {
    @Bindable var model: GenerateModel
    let thumbnails: [Int: GenerateImage]
    var compact = false

    var body: some View {
        if let o = model.outcome, let s = model.studied {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(Array(o.candidates.enumerated()), id: \.offset) { i, c in
                        Button {
                            model.selected = i
                            model.display = .result
                        } label: {
                            CandidateCard(candidate: c, study: s, image: thumbnails[i], best: i == o.best,
                                          selected: model.selected == i, compact: compact)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Candidate \(i + 1)\(i == o.best ? ", best" : "")")
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// One candidate: its still, whether it keeps the limits, its mass and safety factor.
struct CandidateCard: View {
    let candidate: StudyCandidate
    let study: Study
    let image: GenerateImage?
    let best: Bool
    let selected: Bool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image {
                    Image(generate: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: compact ? 112 : 160, height: compact ? 76 : 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 4) {
                Text("#\(candidate.id + 1)").font(.footnote.weight(.semibold))
                if best { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).accessibilityLabel("Best") }
                Spacer(minLength: 4)
                FeasibleBadge(feasible: candidate.feasible)
            }
            Text(String(format: "%.1f g  ·  SF %@", candidate.massG, formatFactor(candidate.analysis.safetyFactor)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: compact ? 112 : 160)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct FeasibleBadge: View {
    let feasible: Bool

    var body: some View {
        Label(feasible ? "Feasible" : "Over a limit", systemImage: feasible ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(feasible ? .green : .orange)
            .background((feasible ? Color.green : Color.orange).opacity(0.15), in: Capsule())
    }
}

/// A safety factor as read: "2.4", or "∞" when nothing is stressed.
func formatFactor(_ f: Double) -> String {
    guard f.isFinite else { return "∞" }
    return f >= 100 ? String(format: "%.0f", f) : String(format: "%.2g", f)
}

// MARK: Legend

/// The stress colours against the material: blue at nothing, red at the allowable, with the
/// limit the study holds marked.
struct StressLegend: View {
    let preview: PreviewMesh
    let study: Study

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if preview.coloredByStress {
                Text("Von Mises stress, MPa").font(.caption.weight(.semibold))
                GeometryReader { g in
                    let allowable = max(study.material.allowable, 1e-9)
                    let x = min(max(study.stressLimit / allowable, 0), 1) * g.size.width
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(gradient: StressColors.gradient, startPoint: .leading, endPoint: .trailing))
                        Rectangle().fill(.primary).frame(width: 2, height: g.size.height + 6).offset(x: x - 1)
                    }
                }
                .frame(width: 200, height: 10)
                HStack {
                    Text("0")
                    Spacer()
                    Text("limit \(Int(study.stressLimit.rounded()))")
                    Spacer()
                    Text("\(Int(study.material.allowable.rounded()))")
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 200)
                Text("Peak \(Int(Double(preview.peakStress).rounded())) MPa")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Double(preview.peakStress) > study.stressLimit ? .orange : .primary)
            } else {
                Text(preview.voxels ? "Voxels (no surface from the engine)" : "No stress on this surface")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// What the inserted assembly is made of, over its view.
struct AssemblyBadge: View {
    let model: GenerateModel
    let project: GenerateProject

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(project.name.capitalized) assembly").font(.caption.weight(.semibold))
            if let s = model.assemblySummary {
                Text("\(s.generated) generated parts · \(s.components) real components")
                    .font(.caption2).foregroundStyle(.secondary)
                if let m = s.massG { Text(String(format: "%.0f g all up", m)).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
            }
            let moving = model.joints.filter(\.movable)
            if !moving.isEmpty {
                Text("\(moving.count) joints, Project pane to drive them").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
